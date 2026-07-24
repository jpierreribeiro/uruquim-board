package wp106_sanitize_test

// WP106 — pure unit tests for filename validation, a security boundary (path
// traversal / control-character rejection). Imports only `board:sanitize`
// (core:strings), so it runs in the build gate with no PostgreSQL.

import "core:strings"
import "core:testing"
import "board:sanitize"

@(test)
accepts_ordinary_names :: proc(t: ^testing.T) {
	for name in ([]string{"note.txt", "normal-file_123.PNG", "résumé.pdf", "a.tar.gz"}) {
		testing.expect(t, sanitize.valid_filename(name), "an ordinary filename is accepted")
	}
}

@(test)
rejects_traversal_and_separators :: proc(t: ^testing.T) {
	for name in ([]string{"../etc/passwd", "a/b.txt", "a\\b.txt", "..", "dir/..", "foo/../bar"}) {
		testing.expect(t, !sanitize.valid_filename(name), "path separators / traversal are rejected")
	}
}

@(test)
rejects_header_hostile_chars :: proc(t: ^testing.T) {
	// A filename goes into a Content-Disposition header value on download, so a
	// double-quote or semicolon (which would break out of filename="...") is
	// rejected at upload.
	for name in ([]string{"in\"jection.txt", "a;b.txt", "\"quoted\".pdf"}) {
		testing.expect(t, !sanitize.valid_filename(name), "quotes/semicolons are rejected (header safety)")
	}
}

@(test)
rejects_control_chars_and_bounds :: proc(t: ^testing.T) {
	testing.expect(t, !sanitize.valid_filename(""), "empty is rejected")
	testing.expect(t, !sanitize.valid_filename("with\nnewline"), "newline is rejected")
	testing.expect(t, !sanitize.valid_filename("tab\there"), "tab is rejected")
	testing.expect(t, !sanitize.valid_filename("nul\x00byte"), "NUL is rejected")

	over := strings.repeat("a", sanitize.FILENAME_MAX + 1, context.temp_allocator)
	testing.expect(t, !sanitize.valid_filename(over), "an over-long name is rejected")

	at_limit := strings.repeat("a", sanitize.FILENAME_MAX, context.temp_allocator)
	testing.expect(t, sanitize.valid_filename(at_limit), "a name at the limit is accepted")
}
