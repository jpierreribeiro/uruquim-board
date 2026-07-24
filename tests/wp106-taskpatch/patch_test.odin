package wp106_taskpatch_test

// WP106 — pure unit tests for the three-state PATCH parser. Imports only
// `board:taskpatch` (which depends on `core:encoding/json` + the pure
// `crystals:validate`), so it runs in the build gate with no PostgreSQL. This is
// the subtle logic the DB-touching patch_task handler relies on: distinguishing
// absent / JSON null / set, rejecting unknown keys and wrong types, and
// requiring version.

import "core:testing"
import "crystals:validate"
import tp "board:taskpatch"

@(test)
parses_a_valid_patch :: proc(t: ^testing.T) {
	p, ok := tp.parse(transmute([]byte)string(`{"version":3,"title":"hello","status":"closed"}`))
	testing.expect(t, ok, "a well-formed patch parses")
	testing.expect_value(t, p.version, 3)
	tv, tset := validate.patch_get(p.title)
	testing.expect(t, tset && tv == "hello", "title is set to hello")
	sv, sset := validate.patch_get(p.status)
	testing.expect(t, sset && sv == "closed", "status is set to closed")
	// unmentioned fields are absent
	testing.expect(t, validate.patch_is_absent(p.body), "body absent when not mentioned")
	testing.expect(t, validate.patch_is_absent(p.assignee_id), "assignee absent when not mentioned")
}

@(test)
due_date_is_three_state :: proc(t: ^testing.T) {
	// set
	set, ok1 := tp.parse(transmute([]byte)string(`{"version":1,"due_date":"2026-08-01T00:00:00Z"}`))
	testing.expect(t, ok1, "parses")
	dv, dset := validate.patch_get(set.due_date)
	testing.expect(t, dset && dv == "2026-08-01T00:00:00Z", "due_date set to the ISO string")
	// null clears
	cleared, ok2 := tp.parse(transmute([]byte)string(`{"version":1,"due_date":null}`))
	testing.expect(t, ok2 && validate.patch_is_null(cleared.due_date), "explicit null due_date is Null (clear)")
	// absent keeps
	kept, ok3 := tp.parse(transmute([]byte)string(`{"version":1}`))
	testing.expect(t, ok3 && validate.patch_is_absent(kept.due_date), "unmentioned due_date is Absent (keep)")
	// wrong type rejected
	_, ok4 := tp.parse(transmute([]byte)string(`{"version":1,"due_date":123}`))
	testing.expect(t, !ok4, "a non-string, non-null due_date is rejected")
}

@(test)
distinguishes_null_from_absent_from_set :: proc(t: ^testing.T) {
	// body explicitly null (clear); assignee set; title absent
	p, ok := tp.parse(transmute([]byte)string(`{"version":1,"body":null,"assignee_id":42}`))
	testing.expect(t, ok, "parses")
	testing.expect(t, validate.patch_is_null(p.body), "explicit null body is Null (clear), not Absent")
	av, aset := validate.patch_get(p.assignee_id)
	testing.expect(t, aset && av == 42, "assignee set to 42")
	testing.expect(t, validate.patch_is_absent(p.title), "unmentioned title is Absent (keep)")
}

@(test)
patch_mode_encodes_three_states :: proc(t: ^testing.T) {
	testing.expect(t, tp.patch_mode(validate.patch_set("x")) == "set", "set -> set")
	testing.expect(t, tp.patch_mode(validate.patch_null(string)) == "null", "null -> null")
	testing.expect(t, tp.patch_mode(validate.patch_absent(string)) == "keep", "absent -> keep")
	// generic over the payload type
	testing.expect(t, tp.patch_mode(validate.patch_set(i64(7))) == "set", "i64 set -> set")
}

@(test)
rejects_malformed_patches :: proc(t: ^testing.T) {
	_, no_version := tp.parse(transmute([]byte)string(`{"title":"x"}`))
	testing.expect(t, !no_version, "missing version is rejected")

	_, unknown := tp.parse(transmute([]byte)string(`{"version":1,"nope":true}`))
	testing.expect(t, !unknown, "unknown field is rejected")

	_, wrong_type := tp.parse(transmute([]byte)string(`{"version":1,"title":5}`))
	testing.expect(t, !wrong_type, "wrong-typed title is rejected")

	_, not_object := tp.parse(transmute([]byte)string(`[1,2,3]`))
	testing.expect(t, !not_object, "a non-object body is rejected")

	_, empty := tp.parse(transmute([]byte)string(``))
	testing.expect(t, !empty, "an empty body is rejected")

	_, bad_version := tp.parse(transmute([]byte)string(`{"version":"soon"}`))
	testing.expect(t, !bad_version, "a non-numeric version is rejected")
}
