package board

// WP104 — identity: registration, login, logout and the per-request session
// resolver. Sessions are opaque bearer tokens (identity.new_session_token);
// see identity/token.odin and friction F8-2 for why bearer, not cookies.
//
// The framework gives a handler no request-scoped typed state and no
// authentication middleware hook (ADR-028: the app must not smuggle an extension
// bag into Context). So authentication is resolved EXPLICITLY at the top of each
// protected handler by require_session, which reuses the connection the handler
// already holds. That repetition is deliberate and MEASURED (friction F8-3): it
// is the evidence ADR-028 asks for, not a workaround hidden in a side table.

import "core:mem/virtual"
import "core:strings"
import pg "crystals:db/postgres"
import "crystals:validate"
import vh "crystals:web/validate"
import web "uruquim:web"
import "board:identity"

// A session lives one day. The soak (WP102 §8) is pre-registered to cross this
// boundary, so expiry is exercised, not just declared.
SESSION_TTL_SECONDS :: 24 * 60 * 60

EMAIL_MAX :: 254
PASSWORD_MIN :: 8
PASSWORD_MAX :: 200

Credentials :: struct {
	email:    string `json:"email"`,
	password: string `json:"password"`,
}

// Account_View is the safe projection returned to clients: never the hash.
Account_View :: struct {
	id:    i64    `json:"id"`,
	email: string `json:"email"`,
}

Session_View :: struct {
	token:      string `json:"token"`,
	expires_at: string `json:"expires_at"`,
}

// Identity is who the current request is, resolved from the bearer token. It is
// returned by value from require_session and lives on the handler's stack — the
// deliberate alternative to stashing it in Context.
Identity :: struct {
	account_id: i64,
	email:      string,
}

@(private)
register_account :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	input: Credentials
	if !web.body(ctx, &input) {
		return
	}
	if !valid_credentials(ctx, input) {
		return
	}

	// argon2id derive allocates ~7 MiB transiently and frees it; the encoded
	// hash is owned by temp_allocator and copied into the SQL param below.
	hash, hok := identity.hash_password(input.password, context.temp_allocator)
	if !hok {
		web.internal_error(ctx)
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	r, qe := pg.query_one(
		&c,
		"accounts.insert",
		"INSERT INTO accounts (email, password_hash) VALUES ($1, $2) RETURNING id",
		{pg.arg_text(input.email), pg.arg_text(hash)},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		if qe.kind == .Unique_Violation {
			respond_conflict(ctx, "That email is already registered")
			return
		}
		respond_db_error(ctx, qe)
		return
	}

	id, _ := pg.row_i64(&r, 0)
	audit("account.register", id)
	web.created(ctx, Account_View{id = id, email = input.email})
}

@(private)
login :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	input: Credentials
	if !web.body(ctx, &input) {
		return
	}
	// No field validation on login: an invalid email simply fails to match. The
	// response is the same 401 whether the email is unknown or the password is
	// wrong, so login does not disclose which accounts exist.

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	lr, le := pg.query_one(
		&c,
		"accounts.by_email",
		"SELECT id, password_hash FROM accounts WHERE email = $1",
		{pg.arg_text(input.email)},
	)
	defer pg.rows_close(&lr)
	if pg.is_err(le) {
		if le.kind == .Row_Not_Found {
			invalid_login(ctx)
			return
		}
		respond_db_error(ctx, le)
		return
	}
	account_id, _ := pg.row_i64(&lr, 0)
	stored_hash, _ := pg.row_text(&lr, 1, ally)

	if !identity.verify_password(stored_hash, input.password) {
		audit("login.reject", account_id)
		invalid_login(ctx)
		return
	}

	// Mint the session. Only the hash is persisted; the token is returned once.
	token, token_hash := identity.new_session_token(ally)
	sr, se := pg.query_one(
		&c,
		"sessions.insert",
		"INSERT INTO sessions (account_id, token_hash, expires_at) " +
		"VALUES ($1, $2, now() + make_interval(secs => $3)) RETURNING expires_at::text",
		{pg.arg_i64(account_id), pg.arg_text(token_hash), pg.arg_i64(SESSION_TTL_SECONDS)},
	)
	defer pg.rows_close(&sr)
	if pg.is_err(se) {
		respond_db_error(ctx, se)
		return
	}
	expires, _ := pg.row_text(&sr, 0, ally)

	audit("login.accept", account_id)
	web.json(ctx, .Created, Session_View{token = token, expires_at = expires})
}

@(private)
logout :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	id, ok := require_session(ctx, &c)
	if !ok {
		return // require_session already answered 401
	}

	// Revoke the presented session. The token is the bearer credential; hash it
	// the same way the lookup does and mark the row revoked. Idempotent: a second
	// logout of an already-revoked token affects zero rows and still returns 204.
	token, _ := web.bearer_token(ctx)
	th := identity.hash_token(token, context.temp_allocator)
	_, qe := pg.execute(
		&c,
		"sessions.revoke",
		"UPDATE sessions SET revoked_at = now() WHERE token_hash = $1 AND revoked_at IS NULL",
		{pg.arg_text(th)},
	)
	if pg.is_err(qe) {
		respond_db_error(ctx, qe)
		return
	}
	audit("logout", id.account_id)
	web.no_content(ctx)
}

// me returns the current account — the smallest protected handler, and the
// canonical demonstration of the require_session boilerplate.
@(private)
me :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	id, ok := require_session(ctx, &c)
	if !ok {
		return
	}
	web.ok(ctx, Account_View{id = id.account_id, email = id.email})
}

// require_session resolves the bearer token to an Identity using the connection
// the caller already holds. On any failure it commits a 401 and returns
// ok=false, so a handler's whole auth check is:
//
//     id, ok := require_session(ctx, &c); if !ok { return }
//
// A live session is one whose token hash matches, is not revoked, and has not
// expired — all three checked in SQL so the database clock, not the app's, is
// authoritative. The email is read for the request's own use (audit, response)
// without a second round trip.
require_session :: proc(ctx: ^web.Context, c: ^pg.Conn) -> (Identity, bool) {
	token, has := web.bearer_token(ctx)
	if !has || token == "" {
		web.unauthorized(ctx, "Authentication required")
		return {}, false
	}

	th := identity.hash_token(token, context.temp_allocator)
	r, qe := pg.query_one(
		c,
		"sessions.resolve",
		"SELECT a.id, a.email FROM sessions s " +
		"JOIN accounts a ON a.id = s.account_id " +
		"WHERE s.token_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > now()",
		{pg.arg_text(th)},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		if qe.kind == .Row_Not_Found {
			// Unknown, revoked or expired — indistinguishable to the client.
			audit("session.reject", 0)
			web.unauthorized(ctx, "Invalid or expired session")
			return {}, false
		}
		respond_db_error(ctx, qe)
		return {}, false
	}

	account_id, _ := pg.row_i64(&r, 0)
	// The email is copied into temp_allocator; it stays valid for the handler.
	email, _ := pg.row_text(&r, 1, context.temp_allocator)
	return Identity{account_id = account_id, email = email}, true
}

// invalid_login and invalid_credentials keep the two failure shapes uniform.
@(private)
invalid_login :: proc(ctx: ^web.Context) {
	web.unauthorized(ctx, "Invalid email or password")
}

@(private)
valid_credentials :: proc(ctx: ^web.Context, input: Credentials) -> bool {
	v := validate.validator()
	defer validate.destroy(&v)

	validate.not_empty(&v, "email", input.email)
	validate.string_length(&v, "email", input.email, min = 3, max = EMAIL_MAX)
	if !strings.contains(input.email, "@") {
		validate.add(&v, "email", "invalid")
	}
	validate.string_length(&v, "password", input.password, min = PASSWORD_MIN, max = PASSWORD_MAX)

	return !vh.respond_if_invalid(ctx, &v)
}
