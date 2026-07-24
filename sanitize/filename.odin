package sanitize

// WP106 — filename validation, isolated as pure security-relevant logic.
//
// An uploaded attachment's stored bytes go to a GENERATED on-disk name, so a
// hostile filename cannot traverse the storage directory regardless. But the
// client-supplied name is kept as display metadata and echoed back, so it is
// validated: a name that could confuse a downstream that treats it as a path,
// or that carries control characters, is rejected with a clear 400 rather than
// stored. Pure — no filesystem, no framework — and unit-tested
// (tests/wp106-sanitize).

import "core:strings"

FILENAME_MAX :: 255

// valid_filename rejects empties, over-long names, path separators and traversal
// sequences, and control characters. It is deliberately strict: the cost of a
// false reject is a clear error the client fixes; the cost of a false accept is
// a name that surprises something downstream.
valid_filename :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > FILENAME_MAX {
		return false
	}
	if strings.contains(name, "/") || strings.contains(name, "\\") || strings.contains(name, "..") {
		return false
	}
	for b in transmute([]byte)name {
		if b < 0x20 {
			return false // control characters (includes NUL, CR, LF, TAB)
		}
		// A double-quote or semicolon would break out of a
		// `Content-Disposition: attachment; filename="<name>"` header value, so a
		// filename that is placed there unescaped must not contain them. Rejecting
		// at upload keeps every stored filename header-safe by construction.
		if b == '"' || b == ';' {
			return false
		}
	}
	return true
}
