package board

// The composition root's data: a typed App_State the application owns. The
// framework never opens, migrates or closes the database — the application does,
// here, explicitly and visibly (the examples/notes canonical shape, extended as
// the board grows).
//
// Uruquim board — the Phase-8 proof-by-use reference system. It depends ONLY on
// pinned public Uruquim (`uruquim:web`) and Crystals (`crystals:*`) contracts:
// no friend import, no internal, no core exception. See DEPS.md for the pins.

import "core:os"
import pg "crystals:db/postgres"

App_State :: struct {
	db: pg.Pool,

	// WP106 — attachment storage. `storage_dir` is where persisted attachment
	// bytes live (the DB row's storage_path is under here). `max_attachment_bytes`
	// is the application's own size cap, refused with 413 before persistence.
	storage_dir:          string,
	max_attachment_bytes: i64,
}

Config :: struct {
	database:             pg.Config,
	pool:                 pg.Pool_Config,
	storage_dir:          string,
	spool_dir:            string,
	max_attachment_bytes: i64,
}

// application_init opens the bounded pool and ensures the attachment storage
// directory exists. It returns before any listener opens, so a bad database
// configuration or an uncreatable storage directory is a clean startup failure —
// log and exit before serving, never mid-request. The mirror of
// application_destroy.
application_init :: proc(cfg: Config) -> (App_State, bool) {
	// The storage directory must exist before the first upload; create it now so
	// a missing directory fails at boot, not on a request. make_directory is
	// idempotent-enough here: an already-existing directory is fine.
	if cfg.storage_dir != "" {
		if err := os.make_directory(cfg.storage_dir); err != nil && !os.exists(cfg.storage_dir) {
			return App_State{}, false
		}
	}

	pc := cfg.pool
	pc.conn = cfg.database
	pool, err := pg.pool_open(pc)
	if pg.is_err(err) {
		return App_State{}, false
	}
	return App_State {
			db = pool,
			storage_dir = cfg.storage_dir,
			max_attachment_bytes = cfg.max_attachment_bytes,
		},
		true
}

// application_destroy closes the pool, after serving has stopped.
application_destroy :: proc(st: ^App_State) {
	pg.pool_close(&st.db)
}
