package taskflow

// WP105 — the task status machine.
//
// The status set is CLOSED (mirrored by the CHECK constraint in migration
// 0003_tasks). Legal TRANSITIONS are a domain rule enforced here and checked by
// the PATCH handler before any write, so an illegal move is a 400, never a
// silent state the database would happily store.
//
// Pure and unit-tested (tests/wp105-taskflow) without a database.

Status :: enum u8 {
	Open,
	In_Progress,
	Blocked,
	Closed,
}

status_string :: proc(s: Status) -> string {
	switch s {
	case .Open:
		return "open"
	case .In_Progress:
		return "in_progress"
	case .Blocked:
		return "blocked"
	case .Closed:
		return "closed"
	}
	return "open"
}

// status_parse maps a stored/received string to a Status. An unknown string is
// ok=false — never a silent default, so a corrupted column or a bad request
// cannot smuggle in an out-of-set status.
status_parse :: proc(s: string) -> (Status, bool) {
	switch s {
	case "open":
		return .Open, true
	case "in_progress":
		return .In_Progress, true
	case "blocked":
		return .Blocked, true
	case "closed":
		return .Closed, true
	}
	return .Open, false
}

// status_can_transition reports whether moving `from` → `to` is legal.
//
//   - a no-op (from == to) is NOT a transition — the handler treats an unchanged
//     status as "no status change", not as an error;
//   - open / in_progress / blocked interconvert freely, and any of them may
//     close;
//   - closed is terminal except REOPEN to open — you cannot jump a closed task
//     straight back to in_progress or blocked.
status_can_transition :: proc(from: Status, to: Status) -> bool {
	if from == to {
		return false
	}
	switch from {
	case .Open, .In_Progress, .Blocked:
		return true
	case .Closed:
		return to == .Open
	}
	return false
}
