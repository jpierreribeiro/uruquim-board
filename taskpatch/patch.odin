package taskpatch

// WP105/106 — the task PATCH parser, isolated as pure logic.
//
// A PATCH body carries THREE-STATE intent per field: absent (keep), JSON null
// (clear a nullable column), or a value (set). `web.body`'s struct decode into
// Maybe collapses absent and null, so the board parses the raw JSON here into
// validate.Patch values instead. This package depends only on `core:encoding/
// json` and the pure `crystals:validate` — no framework, no PostgreSQL — so the
// parser's subtle rules (unknown-field rejection, wrong-type rejection, the
// required version, null-vs-absent) are unit-tested without a database
// (tests/wp106-taskpatch).

import "core:encoding/json"
import "crystals:validate"

// Task_Patch is the parsed three-state edit intent. `version` is required (the
// optimistic-concurrency token); the rest are per-field patches.
Task_Patch :: struct {
	version:     i64,
	title:       validate.Patch(string), // null is invalid downstream (title NOT NULL)
	body:        validate.Patch(string), // null clears the body
	status:      validate.Patch(string), // null is invalid downstream (status NOT NULL)
	assignee_id: validate.Patch(i64),    // null unassigns
	due_date:    validate.Patch(string), // null clears the due date; a value is an ISO-8601 string
}

// parse reads the three-state intent from a raw JSON body. ok=false for a
// non-object body, an unknown key, a wrong-typed value, or a missing version —
// the PATCH surface is strict. Parsed in the temp allocator.
parse :: proc(body: []u8) -> (out: Task_Patch, ok: bool) {
	if len(body) == 0 {
		return {}, false
	}
	value, perr := json.parse(body, allocator = context.temp_allocator)
	if perr != .None {
		return {}, false
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return {}, false
	}

	version_seen := false
	for key, v in obj {
		switch key {
		case "version":
			#partial switch n in v {
			case json.Integer:
				out.version = i64(n)
			case json.Float:
				out.version = i64(n)
			case:
				return {}, false
			}
			version_seen = true
		case "title":
			p, e := read_string_patch(v)
			if e {return {}, false}
			out.title = p
		case "body":
			p, e := read_string_patch(v)
			if e {return {}, false}
			out.body = p
		case "status":
			p, e := read_string_patch(v)
			if e {return {}, false}
			out.status = p
		case "assignee_id":
			p, e := read_int_patch(v)
			if e {return {}, false}
			out.assignee_id = p
		case "due_date":
			p, e := read_string_patch(v)
			if e {return {}, false}
			out.due_date = p
		case:
			return {}, false // unknown field
		}
	}
	if !version_seen {
		return {}, false
	}
	return out, true
}

// patch_mode encodes a three-state field for the SQL CASE: "set", "null" or the
// default "keep". Generic over the patch payload type.
patch_mode :: proc(p: validate.Patch($T)) -> string {
	if validate.patch_is_set(p) {
		return "set"
	}
	if validate.patch_is_null(p) {
		return "null"
	}
	return "keep"
}

@(private)
read_string_patch :: proc(v: json.Value) -> (validate.Patch(string), bool) {
	#partial switch t in v {
	case json.Null:
		return validate.patch_null(string), false
	case json.String:
		return validate.patch_set(string(t)), false
	}
	return {}, true // neither null nor a string is invalid
}

@(private)
read_int_patch :: proc(v: json.Value) -> (validate.Patch(i64), bool) {
	#partial switch t in v {
	case json.Null:
		return validate.patch_null(i64), false
	case json.Integer:
		return validate.patch_set(i64(t)), false
	case json.Float:
		return validate.patch_set(i64(t)), false
	}
	return {}, true
}
