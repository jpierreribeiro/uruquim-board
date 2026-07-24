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

import "core:fmt"
import "core:os"
import "core:strconv"
import board "board:board"
import pg "crystals:db/postgres"
import health "crystals:web/health"
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
		},
		// Pool capacity stays below the framework's handler-lane capacity so a
		// saturated pool fails fast for database work while health and shutdown
		// stay live (the WP105 rule; C-05 measured the lane binds first).
		pool = pg.Pool_Config{min_conns = 1, max_conns = 8, acquire_timeout_ms = 2_000},
	}

	st, ok := board.application_init(cfg)
	if !ok {
		fmt.eprintln("board: could not open the database pool; check the configuration")
		os.exit(1)
	}
	defer board.application_destroy(&st)

	app := web.app_with_state(&st)
	defer web.destroy(&app)

	// Liveness from the health Crystal, mounted under /health → /health/live.
	liveness := health.routes()
	web.mount(&app, "/health", &liveness)
	web.destroy(&liveness)

	board.register(&app)

	serve_port, _ := strconv.parse_int(env("BOARD_PORT", "8080"), 10)
	fmt.printfln("board: serving on :%d", serve_port)
	web.serve(&app, serve_port)
}
