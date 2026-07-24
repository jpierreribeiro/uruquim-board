package wp104_identity_test

// WP104 — pure unit tests for the identity primitives: password hashing, opaque
// session tokens, and role ranking. These import ONLY `board:identity`, which
// depends on nothing but the Odin core crypto/encoding packages, so they compile
// and run with `odin test` on any host — no PostgreSQL, no libpq link. The
// database-touching handlers (register/login/authz) are exercised against a live
// PostgreSQL on the VPS (WP108 concurrency tests / deployment records).

import "core:strings"
import "core:testing"
import id "board:identity"

@(test)
password_verifies_correct_and_rejects_wrong :: proc(t: ^testing.T) {
	encoded, ok := id.hash_password("correct horse battery staple")
	defer delete(encoded)
	testing.expect(t, ok, "hashing should succeed")
	testing.expect(t, strings.has_prefix(encoded, "argon2id$"), "hash is self-describing")
	testing.expect(
		t,
		!strings.contains(encoded, "correct horse"),
		"the plaintext must not appear in the stored hash",
	)

	testing.expect(t, id.verify_password(encoded, "correct horse battery staple"), "correct password verifies")
	testing.expect(t, !id.verify_password(encoded, "wrong password"), "wrong password is rejected")
}

@(test)
password_salt_is_random :: proc(t: ^testing.T) {
	a, aok := id.hash_password("same-password")
	defer delete(a)
	b, bok := id.hash_password("same-password")
	defer delete(b)
	testing.expect(t, aok && bok, "both hashes succeed")
	testing.expect(t, a != b, "two hashes of one password differ (random salt)")
	// ...yet both verify.
	testing.expect(t, id.verify_password(a, "same-password"), "first still verifies")
	testing.expect(t, id.verify_password(b, "same-password"), "second still verifies")
}

@(test)
password_rejects_malformed_encoding :: proc(t: ^testing.T) {
	testing.expect(t, !id.verify_password("", "x"), "empty encoding never authenticates")
	testing.expect(t, !id.verify_password("not-a-hash", "x"), "garbage encoding never authenticates")
	testing.expect(t, !id.verify_password("argon2id$m=7168,t=5,p=1$$", "x"), "truncated encoding is rejected")
}

@(test)
token_hash_is_stable_and_hides_token :: proc(t: ^testing.T) {
	token, token_hash := id.new_session_token()
	defer delete(token)
	defer delete(token_hash)
	testing.expect(t, len(token) > 0 && len(token_hash) > 0, "token and hash are non-empty")
	testing.expect(t, token != token_hash, "the stored hash is not the token")

	// Hashing the same token again reproduces the stored value (the lookup path).
	again := id.hash_token(token)
	defer delete(again)
	testing.expect(t, again == token_hash, "hash_token is deterministic for lookup")

	// A different token hashes to a different value.
	other, other_hash := id.new_session_token()
	defer delete(other)
	defer delete(other_hash)
	testing.expect(t, other_hash != token_hash, "distinct tokens hash distinctly")
}

@(test)
roles_parse_and_rank :: proc(t: ^testing.T) {
	for name in ([]string{"owner", "maintainer", "member", "viewer"}) {
		r, ok := id.role_parse(name)
		testing.expect(t, ok, "known role parses")
		testing.expect(t, id.role_string(r) == name, "role_string round-trips role_parse")
	}
	_, bad := id.role_parse("superuser")
	testing.expect(t, !bad, "unknown role does not parse")

	// Ranking: owner > maintainer > member > viewer.
	testing.expect(t, id.role_allows(.Owner, .Maintainer), "owner may do a maintainer action")
	testing.expect(t, id.role_allows(.Maintainer, .Member), "maintainer may do a member action")
	testing.expect(t, id.role_allows(.Member, .Viewer), "member may do a viewer action")
	testing.expect(t, id.role_allows(.Viewer, .Viewer), "a role satisfies its own level")
	testing.expect(t, !id.role_allows(.Viewer, .Member), "viewer may NOT do a member action")
	testing.expect(t, !id.role_allows(.Member, .Owner), "member may NOT do an owner action")
}
