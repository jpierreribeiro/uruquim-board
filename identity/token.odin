package identity

// WP104 — opaque session tokens.
//
// A session token is a random, high-entropy OPAQUE string. It carries no claims
// and is not a JWT: the server stores only the token's SHA-256 hash and looks a
// session up by that hash, so a leak of the database does not leak usable
// tokens, and there is nothing in the token for a client to tamper with.
//
// ARCHITECTURE NOTE (see planning/phase-8-friction-ledger.md F8-2). The public
// framework surface has no way to set a response header — `web.text`/`web.json`
// take no headers and the commit path is private — so an application CANNOT emit
// `Set-Cookie`. The board therefore uses BEARER tokens: login returns the token
// in the JSON body, the client sends it as `Authorization: Bearer <token>`
// (read via the public `web.bearer_token`), and CSRF (a cookie/ambient-credential
// attack) does not apply. That is a framework finding, recorded in the ledger,
// not an application preference.
//
// Everything here is pure and unit-tested without a database.

import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/hex"

// 32 bytes = 256 bits of CSPRNG entropy. Ample against guessing; the hash stored
// is the same width.
SESSION_TOKEN_BYTES :: 32

// new_session_token returns the opaque token to hand to the client and the hash
// to store. Only the hash is persisted; the token exists in memory once, in the
// login response. Both strings are owned by the caller's context.allocator.
new_session_token :: proc(allocator := context.allocator) -> (token: string, token_hash: string) {
	raw: [SESSION_TOKEN_BYTES]byte
	crypto.rand_bytes(raw[:])
	defer crypto.zero_explicit(&raw, size_of(raw))

	// URL-safe base64 without padding: the token travels in an Authorization
	// header, so a header-safe alphabet avoids any transport ambiguity.
	token = base64.encode(raw[:], base64.ENC_URL_TABLE, allocator)
	token_hash = hash_token(token, allocator)
	return token, token_hash
}

// hash_token maps a presented token to the value stored in sessions.token_hash.
// It hashes the token STRING (not the pre-encoding bytes) so the lookup needs
// only what the client sent — no base64 round-trip. Lowercase hex, so it is a
// stable TEXT column value.
hash_token :: proc(token: string, allocator := context.allocator) -> string {
	sum: [sha2.DIGEST_SIZE_256]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)token)
	sha2.final(&ctx, sum[:])

	encoded, _ := hex.encode(sum[:], allocator)
	return string(encoded)
}
