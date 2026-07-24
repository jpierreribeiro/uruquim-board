package board

// Shared handler support: the error envelope the board returns, the database-
// error mapping, a per-handler arena for decoded row strings, and audit-safe
// logging. Kept in one place so every handler answers failures the same way.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import pg "crystals:db/postgres"
import web "uruquim:web"

// The board's error body. A code the client can branch on plus a human message
// that is always safe to expose (never an internal diagnostic).
Message :: struct {
	error: Message_Body `json:"error"`,
}

Message_Body :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
}

// respond_db_error maps a postgres error to a client response. Saturation and
// connectivity failures are a fast 503 (the pool rule: database work fails
// quickly while liveness stays live); anything else is a logged 500 with no
// detail on the wire.
//
// FRICTION F8-1: 503 has no named member in the public `web.Status` enum, so it
// is spelled `web.Status(503)` — the same cast the framework's own reference app
// (crystals examples/notes) is forced to make. Recorded in the ledger.
@(private)
respond_db_error :: proc(ctx: ^web.Context, e: pg.Error) {
	#partial switch e.kind {
	case .Pool_Exhausted, .Timeout, .Canceled, .Connection_Lost:
		web.json(
			ctx,
			web.Status(503),
			Message{Message_Body{code = "unavailable", message = "The service is temporarily unavailable"}},
		)
	case:
		web.internal_error(ctx)
	}
}

// respond_conflict is the 409 for a unique-constraint violation. 409, like 503,
// has no named member in the public enum (F8-1) — the cast is the workaround.
@(private)
respond_conflict :: proc(ctx: ^web.Context, message: string) {
	web.json(ctx, web.Status(409), Message{Message_Body{code = "conflict", message = message}})
}

// handler_arena is a growing arena the caller frees at handler end. Row strings
// decoded for the response are allocated here and live until the response is
// rendered (web.json marshals synchronously before the handler returns).
@(private)
handler_arena :: proc(arena: ^virtual.Arena) -> mem.Allocator {
	_ = virtual.arena_init_growing(arena)
	return virtual.arena_allocator(arena)
}

// audit records a security-relevant identity event to stderr, which under the
// systemd unit is captured by the journal. It logs the ACTOR ID and the ACTION
// only — never an email, token, password or request body — upholding the
// redaction budget the framework's own observability keeps (E8-6, WP102 §5).
// A failed lookup logs actor=0, so an unauthenticated attempt is still recorded
// without inventing an identity.
@(private)
audit :: proc(action: string, actor_id: i64) {
	fmt.eprintfln("audit action=%s actor=%d", action, actor_id)
}
