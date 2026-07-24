package board

// WP107 — the board's live view: an SSE subscription per project, plus the
// publish calls the mutation handlers make. Two browsers watching one project
// see each other's task changes as server-pushed notifications; each says WHAT
// changed and the client refetches through the ordinary authorized routes (the
// framework prescribes no DOM/rendering policy).

import pg "crystals:db/postgres"
import sse "crystals:web/sse"
import web "uruquim:web"

// subscribe_events opens an SSE stream for a project after the SAME authorization
// every other project route requires (viewer+). Authorization is rechecked here
// on connect (and on reconnect), so a revoked session or lost membership cannot
// keep receiving events. The pooled connection is released BEFORE the stream
// opens: a stream is long-lived and must never pin a database connection.
@(private)
subscribe_events :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	project_id, pok := web.path_int(ctx, "id")
	if !pok {
		web.bad_request(ctx, "project id must be an integer")
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	id, ok := require_session(ctx, &c)
	if !ok {
		pg.release(&st.db, &c)
		return
	}
	if !require_role(ctx, &c, i64(project_id), id.account_id, .Viewer) {
		pg.release(&st.db, &c)
		return
	}
	pg.release(&st.db, &c)

	s, sok := sse.open(ctx)
	if !sok {
		// No connection to detach (the in-memory test transport) or the open-
		// stream cap is reached — fall back to an ordinary response. 503 has no
		// named member in the public enum (friction F8-1).
		web.text(ctx, .Service_Unavailable, "streaming unavailable")
		return
	}

	// A reconnecting client sends Last-Event-ID; nudge it to refetch so it
	// resynchronizes through the authorized routes rather than replaying an event
	// log the board deliberately does not keep.
	if _, reconnecting := sse.last_event_id(ctx); reconnecting {
		hub_resync(s)
	}

	hub_subscribe(st.hub, i64(project_id), id.account_id, s)
	// The handler returns now; the response outlives the Context and mutation
	// lanes push to this stream through the hub.
}
