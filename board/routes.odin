package board

// The board's own routes. WP103 delivers the boring-but-honest lifecycle
// surface — a health page, liveness, and a readiness check that actually
// touches the database — before any domain feature. Domain routes (accounts,
// projects, tasks, ...) mount here in later WPs.

import pg "crystals:db/postgres"
import web "uruquim:web"

// register mounts the board's application routes. The app owns these, so it
// registers them itself rather than mounting a detached Crystal router.
register :: proc(app: ^web.App) {
	// Lifecycle (WP103).
	web.get(app, "/", index)
	web.get(app, "/ready", ready)

	// Identity (WP104). Register and login are public; the token is a bearer
	// credential (friction F8-2: no public Set-Cookie), returned by login and
	// sent as `Authorization: Bearer <token>` thereafter.
	web.post(app, "/register", register_account)
	web.post(app, "/login", login)
	web.post(app, "/logout", logout)
	web.get(app, "/me", me)

	// Projects and per-project role membership (WP104 authorization).
	web.post(app, "/projects", create_project)
	web.get(app, "/projects/:id", get_project)
	web.post(app, "/projects/:id/members", invite_member)

	// Relational workflows (WP105): tasks, comments, the status machine,
	// optimistic conflict detection (version -> 409) and a persistent audit log.
	web.post(app, "/projects/:id/tasks", create_task)
	web.get(app, "/projects/:id/tasks", list_tasks)
	web.get(app, "/tasks/:id", get_task)
	web.patch(app, "/tasks/:id", patch_task)
	web.post(app, "/tasks/:id/comments", add_comment)
	web.get(app, "/tasks/:id/comments", list_comments)

	// Attachments (WP106): buffered + spool upload, metadata list/get. Byte
	// download is not expressible through the public surface (friction F8-4) —
	// only metadata is served. Task listing gains keyset pagination + filters.
	web.post(app, "/tasks/:id/attachments", upload_attachment)
	web.get(app, "/tasks/:id/attachments", list_attachments)
	web.get(app, "/attachments/:id", get_attachment)

	// Live board (WP107): an SSE subscription per project. Mutations publish
	// "what changed"; the client refetches through the authorized routes.
	web.get(app, "/projects/:id/events", subscribe_events)

	// Observability (WP109): the human admin's JSON stats view (server counters +
	// pool gauges), session-gated. The Prometheus /metrics surface is mounted
	// from the metrics Crystal in cmd/main.odin.
	web.get(app, "/admin/stats", admin_stats)
}

// index is the boring health page: it proves lifecycle and delivery before any
// domain feature exists (plan §WP103). No database, no auth — just "the process
// is up and serving".
@(private)
index :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "uruquim-board: up")
}

// ready is READINESS, distinct from liveness. Liveness (`/health/live`, the
// health Crystal) says the process runs; readiness says it can serve traffic —
// which for this app means the database pool has capacity and the database
// answers. It acquires one connection and runs a trivial query under the pool's
// own acquire timeout, so a saturated pool or an unreachable database makes
// readiness fail FAST with 503 while liveness stays 200 (the WP105 pool rule,
// exercised here at its simplest).
@(private)
ready :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	// FRICTION F8-1 (see planning/phase-8-friction-ledger.md in the core repo):
	// the public `web.Status` enum has no 503. Readiness — a universal deploy
	// pattern — needs it, so this casts the raw int `web.Status(503)`, exactly as
	// the framework's own reference app (crystals examples/notes) is forced to.
	// Kept as the workaround; the ledger proposes adding 503 (and 429) to the enum.
	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		// Pool exhausted or database unreachable within the acquire timeout.
		web.text(ctx, web.Status(503), "not ready: database")
		return
	}
	defer pg.release(&st.db, &c)

	r, qe := pg.query_one(&c, "board.ready", "SELECT 1")
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		web.text(ctx, web.Status(503), "not ready: query")
		return
	}

	web.text(ctx, .OK, "ready")
}
