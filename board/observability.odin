package board

// WP109 — operational observability, consumed by the application's own admin
// view. Two surfaces, split by audience:
//
//   - GET /metrics (mounted from the crystals `metrics` Crystal in cmd/main.odin)
//     is the Prometheus exposition: framework-error counts by closed-enum kind
//     and refused-connection totals. Machine-scraped, redaction by construction
//     (no route string, path, or request byte), so it is UNAUTHENTICATED — but a
//     deployment should still restrict it to an internal hop at the proxy.
//   - GET /admin/stats (here) is the human admin's JSON view: the framework's
//     server counters (web.stats) plus the database pool's state (pg.pool_stats),
//     so an operator can see responses/sent, write-deadline aborts, stream
//     refusals, and pool open/idle/in-use/waiters. It requires a valid session:
//     it is operational internals, not public.
//
// Neither carries per-request cardinality or any bound value (E6/E6-6): the
// server counters are process-wide totals and the pool stats are gauges.

import pg "crystals:db/postgres"
import web "uruquim:web"

Admin_Stats :: struct {
	// web.Server_Stats — process-wide totals since start.
	refused_connections:   int `json:"refused_connections"`,
	responses_sent:        int `json:"responses_sent"`,
	response_bytes:        i64 `json:"response_bytes"`,
	send_errors:           int `json:"send_errors"`,
	write_deadline_aborts: int `json:"write_deadline_aborts"`,
	stream_refused_full:   int `json:"stream_refused_full"`,
	stream_refused_budget: int `json:"stream_refused_budget"`,
	stream_aborted_slow:   int `json:"stream_aborted_slow"`,
	// pg.Pool_Stats — current gauges.
	pool_open:             int `json:"pool_open"`,
	pool_idle:             int `json:"pool_idle"`,
	pool_in_use:           int `json:"pool_in_use"`,
	pool_waiters:          int `json:"pool_waiters"`,
}

@(private)
admin_stats :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	// Any authenticated account may read operational stats (synthetic data, no
	// PII, counters only). A finer ops-role gate is a later refinement.
	id, ok := require_session(ctx, &c)
	if !ok {
		return
	}
	_ = id

	ss := web.stats()
	ps := pg.pool_stats(&st.db)
	web.ok(
		ctx,
		Admin_Stats {
			refused_connections = ss.refused_connections,
			responses_sent = ss.responses_sent,
			response_bytes = ss.response_bytes,
			send_errors = ss.send_errors,
			write_deadline_aborts = ss.write_deadline_aborts,
			stream_refused_full = ss.stream_refused_full,
			stream_refused_budget = ss.stream_refused_budget,
			stream_aborted_slow = ss.stream_aborted_slow,
			pool_open = ps.open,
			pool_idle = ps.idle,
			pool_in_use = ps.in_use,
			pool_waiters = ps.waiters,
		},
	)
}
