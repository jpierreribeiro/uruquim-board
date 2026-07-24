package identity

// WP104 — password storage. The threat model (planning/phase-8-wp102-spec.md §5)
// requires a memory-hard KDF; the pinned Odin toolchain ships `core:crypto/
// argon2id`, so argon2id is the choice and the documented bcrypt-class fallback
// is not needed. Parameters are OWASP's small profile (7 MiB / 5 passes / 1
// lane), a deliberate memory-for-CPU trade on the 1.6 GiB test VPS.
//
// A stored hash is SELF-DESCRIBING so a future parameter change can re-hash on
// next login without a migration:
//
//     argon2id$m=<KiB>,t=<passes>,p=<lanes>$<salt-b64>$<tag-b64>
//
// Everything here is pure (no database, no framework) and is unit-tested in
// tests/wp104-identity without a live PostgreSQL.

import "core:crypto"
import "core:crypto/argon2id"
import "core:encoding/base64"
import "core:fmt"
import "core:strconv"
import "core:strings"

// The KDF cost. OWASP small profile (as of 2026/02) — equivalent strength to the
// 19 MiB profile, trading memory for CPU, which suits the memory-constrained
// test host. Changing these does not invalidate stored hashes: each hash records
// the parameters it was made with, so verify re-derives with the STORED cost.
PASSWORD_PARAMS := argon2id.Parameters {
	memory_size = 7 * 1024,
	passes      = 5,
	parallelism = 1,
}

PASSWORD_SALT_LEN :: 16
PASSWORD_TAG_LEN :: 32

// hash_password derives an argon2id tag over a fresh random salt and returns the
// self-describing encoding. The returned string is allocator-owned by the
// caller's context.allocator. ok is false only on a CSPRNG or allocation
// failure — never on a "weak" password (length policy is enforced at the
// handler boundary, not here).
hash_password :: proc(plain: string, allocator := context.allocator) -> (encoded: string, ok: bool) {
	salt: [PASSWORD_SALT_LEN]byte
	crypto.rand_bytes(salt[:])

	tag: [PASSWORD_TAG_LEN]byte
	params := PASSWORD_PARAMS
	if derr := argon2id.derive(&params, transmute([]byte)plain, salt[:], tag[:]); derr != nil {
		return "", false
	}
	defer crypto.zero_explicit(&tag, size_of(tag))

	return encode_hash(params, salt[:], tag[:], allocator), true
}

// verify_password re-derives the tag from the presented password using the
// parameters and salt recorded IN the stored encoding, then compares in
// constant time. A malformed encoding, or any mismatch, returns false. It never
// panics and never allocates a result the caller must free (scratch is
// temp_allocator).
verify_password :: proc(encoded: string, plain: string) -> bool {
	params, salt, want, ok := decode_hash(encoded)
	if !ok {
		return false
	}

	got: [PASSWORD_TAG_LEN]byte
	// The stored tag length bounds what we re-derive; a stored encoding with a
	// non-standard tag length is rejected by decode_hash below.
	p := params
	if derr := argon2id.derive(&p, transmute([]byte)plain, salt, got[:]); derr != nil {
		return false
	}
	defer crypto.zero_explicit(&got, size_of(got))

	// constant-time: 1 when equal, so the boolean does not branch on content.
	return len(want) == PASSWORD_TAG_LEN && crypto.compare_constant_time(got[:], want) == 1
}

@(private)
encode_hash :: proc(
	params: argon2id.Parameters,
	salt: []byte,
	tag: []byte,
	allocator := context.allocator,
) -> string {
	salt_b64 := base64.encode(salt, base64.ENC_TABLE, context.temp_allocator)
	tag_b64 := base64.encode(tag, base64.ENC_TABLE, context.temp_allocator)
	// argon2id$m=7168,t=5,p=1$<salt>$<tag>
	return fmt.aprintf(
		"argon2id$m=%d,t=%d,p=%d$%s$%s",
		params.memory_size,
		params.passes,
		params.parallelism,
		salt_b64,
		tag_b64,
		allocator = allocator,
	)
}

// decode_hash parses the self-describing encoding back into its parameters, salt
// and expected tag. Any structural deviation returns ok=false — verify treats
// that exactly like a password mismatch, so a corrupted column can never
// authenticate. Scratch decodes use temp_allocator.
@(private)
decode_hash :: proc(
	encoded: string,
) -> (
	params: argon2id.Parameters,
	salt: []byte,
	tag: []byte,
	ok: bool,
) {
	parts := strings.split(encoded, "$", context.temp_allocator)
	// ["argon2id", "m=..,t=..,p=..", "<salt>", "<tag>"]
	if len(parts) != 4 || parts[0] != "argon2id" {
		return {}, nil, nil, false
	}

	m, t, p, pok := parse_params(parts[1])
	if !pok {
		return {}, nil, nil, false
	}
	params = argon2id.Parameters {
		memory_size = m,
		passes      = t,
		parallelism = p,
	}

	salt_bytes, serr := base64.decode(parts[2], base64.DEC_TABLE, nil, context.temp_allocator)
	if serr != nil || len(salt_bytes) == 0 {
		return {}, nil, nil, false
	}
	tag_bytes, terr := base64.decode(parts[3], base64.DEC_TABLE, nil, context.temp_allocator)
	if terr != nil || len(tag_bytes) != PASSWORD_TAG_LEN {
		return {}, nil, nil, false
	}
	return params, salt_bytes, tag_bytes, true
}

@(private)
parse_params :: proc(s: string) -> (m: u32, t: u32, p: u32, ok: bool) {
	fields := strings.split(s, ",", context.temp_allocator)
	if len(fields) != 3 {
		return 0, 0, 0, false
	}
	mv, mok := kv_u32(fields[0], "m=")
	tv, tok := kv_u32(fields[1], "t=")
	pv, pkk := kv_u32(fields[2], "p=")
	if !mok || !tok || !pkk {
		return 0, 0, 0, false
	}
	return mv, tv, pv, true
}

@(private)
kv_u32 :: proc(field: string, prefix: string) -> (u32, bool) {
	if !strings.has_prefix(field, prefix) {
		return 0, false
	}
	n, nok := strconv.parse_int(field[len(prefix):], 10)
	if !nok || n <= 0 {
		return 0, false
	}
	return u32(n), true
}
