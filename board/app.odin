package board

// The composition root's data: a typed App_State the application owns. The
// framework never opens, migrates or closes the database — the application does,
// here, explicitly and visibly (the examples/notes canonical shape, extended as
// the board grows).
//
// Uruquim board — the Phase-8 proof-by-use reference system. It depends ONLY on
// pinned public Uruquim (`uruquim:web`) and Crystals (`crystals:*`) contracts:
// no friend import, no internal, no core exception. See DEPS.md for the pins.

import pg "crystals:db/postgres"

App_State :: struct {
	db: pg.Pool,
}

Config :: struct {
	database: pg.Config,
	pool:     pg.Pool_Config,
}

// application_init opens the bounded pool. It returns before any listener opens,
// so a bad database configuration is a clean startup failure — log and exit
// before serving, never mid-request. The mirror of application_destroy.
application_init :: proc(cfg: Config) -> (App_State, bool) {
	pc := cfg.pool
	pc.conn = cfg.database
	pool, err := pg.pool_open(pc)
	if pg.is_err(err) {
		return App_State{}, false
	}
	return App_State{db = pool}, true
}

// application_destroy closes the pool, after serving has stopped.
application_destroy :: proc(st: ^App_State) {
	pg.pool_close(&st.db)
}
