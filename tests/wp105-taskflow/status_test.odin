package wp105_taskflow_test

// WP105 — pure unit tests for the task status machine. Imports only
// `board:taskflow` (no framework, no PostgreSQL), so it runs in the build gate
// on any host. The relational workflows themselves run against a live PostgreSQL
// on the VPS.

import "core:testing"
import tf "board:taskflow"

@(test)
status_round_trips :: proc(t: ^testing.T) {
	for name in ([]string{"open", "in_progress", "blocked", "closed"}) {
		s, ok := tf.status_parse(name)
		testing.expect(t, ok, "known status parses")
		testing.expect(t, tf.status_string(s) == name, "status_string round-trips status_parse")
	}
	_, bad := tf.status_parse("archived")
	testing.expect(t, !bad, "unknown status does not parse")
}

@(test)
transitions_follow_the_machine :: proc(t: ^testing.T) {
	// A no-op is not a transition.
	testing.expect(t, !tf.status_can_transition(.Open, .Open), "same status is not a transition")

	// The three live states interconvert and may close.
	testing.expect(t, tf.status_can_transition(.Open, .In_Progress), "open -> in_progress")
	testing.expect(t, tf.status_can_transition(.In_Progress, .Blocked), "in_progress -> blocked")
	testing.expect(t, tf.status_can_transition(.Blocked, .Open), "blocked -> open")
	testing.expect(t, tf.status_can_transition(.In_Progress, .Closed), "in_progress -> closed")

	// Closed is terminal except reopen.
	testing.expect(t, tf.status_can_transition(.Closed, .Open), "closed -> open (reopen) allowed")
	testing.expect(t, !tf.status_can_transition(.Closed, .In_Progress), "closed -> in_progress forbidden")
	testing.expect(t, !tf.status_can_transition(.Closed, .Blocked), "closed -> blocked forbidden")
}
