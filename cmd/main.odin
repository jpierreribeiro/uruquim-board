package main

// The deployable uruquim-board server. Migrations are NOT run here — they are a
// separate deploy step (`migrate up`) that must complete before this process
// starts (plan hypothesis 4: no server-boot schema coupling). This program only
// opens the pool, mounts the routes and serves.
//
// Environment:
//   BOARD_PORT              (default 8080)
//   BOARD_DB_HOST           (default 127.0.0.1)
//   BOARD_DB_PORT           (default 5432)
//   BOARD_DB_USER
//   BOARD_DB_PASSWORD
//   BOARD_DB_NAME
//   BOARD_DB_SSLMODE        (verify-full|verify-ca|require|disable; default verify-full)
//   BOARD_ALLOW_PLAINTEXT   (=1 to allow a plaintext DB connection — dev only)
//   BOARD_STORAGE_DIR       (attachment storage; default /var/lib/uruquim-board/storage)
//   BOARD_SPOOL_DIR         (large-upload spool; default <storage>/spool)
//   BOARD_MAX_ATTACHMENT    (per-attachment byte cap; default 52428800 = 50 MiB)

import "core:fmt"
import "core:os"
import "core:strconv"
import board "board:board"
import pg "crystals:db/postgres"
import health "crystals:web/health"
import metrics "crystals:web/metrics"
import web "uruquim:web"

env :: proc(key: string, def := "") -> string {
	v := os.get_env(key, context.temp_allocator)
	return v if v != "" else def
}

main :: proc() {
	db_port, _ := strconv.parse_int(env("BOARD_DB_PORT", "5432"), 10)

	ssl: pg.Ssl_Mode = .Verify_Full
	switch env("BOARD_DB_SSLMODE", "verify-full") {
	case "verify-ca":
		ssl = .Verify_Ca
	case "require":
		ssl = .Require
	case "disable":
		ssl = .Disable
	}

	storage_dir := env("BOARD_STORAGE_DIR", "/var/lib/uruquim-board/storage")
	spool_dir := env("BOARD_SPOOL_DIR", "")
	if spool_dir == "" {
		spool_dir = fmt.tprintf("%s/spool", storage_dir)
	}
	max_attachment, _ := strconv.parse_i64(env("BOARD_MAX_ATTACHMENT", "52428800"))

	cfg := board.Config {
		database = pg.Config {
			host                 = env("BOARD_DB_HOST", "127.0.0.1"),
			port                 = u16(db_port),
			user                 = env("BOARD_DB_USER"),
			password             = env("BOARD_DB_PASSWORD"),
			database             = env("BOARD_DB_NAME"),
			ssl_mode             = ssl,
			allow_plaintext      = env("BOARD_ALLOW_PLAINTEXT") == "1",
			statement_timeout_ms = 30_000,
			// Bound an established connection under a silent network partition, so a
			// readiness probe fails promptly instead of hanging until the OS default
			// TCP timeout (WP110 network-interruption drill; needs the C5-branch
			// tcp_user_timeout support in db/postgres).
			tcp_user_timeout_ms  = 3_000,
		},
		// Pool capacity stays below the framework's handler-lane capacity so a
		// saturated pool fails fast for database work while health and shutdown
		// stay live (the WP105 rule; C-05 measured the lane binds first).
		pool = pg.Pool_Config{min_conns = 1, max_conns = 8, acquire_timeout_ms = 2_000},
		storage_dir = storage_dir,
		spool_dir = spool_dir,
		max_attachment_bytes = max_attachment,
	}

	st, ok := board.application_init(cfg)
	if !ok {
		fmt.eprintln("board: could not open the database pool or create the storage directory")
		os.exit(1)
	}
	defer board.application_destroy(&st)

	app := web.app_with_state(&st)
	defer web.destroy(&app)

	// WP106 — spooled large-body ingestion. A request body over max_body (4 MiB
	// default) is spooled to disk under spool_dir instead of refused, so an
	// attachment larger than the buffered limit takes the Phase-7 spool path
	// (web.upload/upload_persist in board/attachments.odin). Must be set before
	// serving (fail-closed ordering). The spool directory is created by the
	// framework's ingest substrate under the configured dir.
	web.enable_upload(
		&app,
		web.Upload_Config {
			dir = spool_dir,
			per_upload_quota = max_attachment,
			process_quota = max_attachment * 8,
			max_concurrent = 4,
			memory_prefix_max = 64 * 1024,
		},
	)

	// Liveness from the health Crystal, mounted under /health → /health/live.
	liveness := health.routes()
	web.mount(&app, "/health", &liveness)
	web.destroy(&liveness)

	// Observability (WP109). Point the framework-error observer at the metrics
	// Crystal (before serve) and mount its Prometheus exposition. The Crystal's
	// route is already `/metrics`, and web.mount forbids a root ("/") prefix, so
	// the scrape endpoint is `/obs/metrics` (prefix + the Crystal's own path),
	// exactly as the Crystal's own test mounts it. It carries only closed-enum
	// error kinds and refused-connection totals — no request bytes — so it is safe
	// to expose; a deployment still restricts it to an internal hop at the proxy.
	metrics.install(&app)
	metrics_routes := metrics.routes()
	web.mount(&app, "/obs", &metrics_routes)
	web.destroy(&metrics_routes)

	board.register(&app)

	serve_port, _ := strconv.parse_int(env("BOARD_PORT", "8080"), 10)
	fmt.printfln("board: serving on :%d", serve_port)
	web.serve(&app, serve_port)
}
