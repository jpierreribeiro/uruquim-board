package board

// WP104 — authorization: per-project role membership and the checks that gate
// mutations. Projects and memberships (migration 0002) exist here so role checks
// have something real to guard; the full task/comment workflows build on them in
// WP105.
//
// The authorization primitive is member_role + require_role. Like
// require_session, require_role takes the connection the handler already holds
// and answers 403 itself, so a guarded handler reads top-to-bottom with no
// hidden control flow.

import "core:mem/virtual"
import pg "crystals:db/postgres"
import "crystals:validate"
import vh "crystals:web/validate"
import web "uruquim:web"
import "board:identity"

PROJECT_NAME_MAX :: 200

Create_Project :: struct {
	name: string `json:"name"`,
}

Invite :: struct {
	account_id: i64    `json:"account_id"`,
	role:       string `json:"role"`,
}

Project_View :: struct {
	id:         i64    `json:"id"`,
	name:       string `json:"name"`,
	owner_id:   i64    `json:"owner_id"`,
	version:    i64    `json:"version"`,
	created_at: string `json:"created_at"`,
}

// member_role returns the caller's role in a project, or ok=false when they are
// not a member. A non-member and a role that fails to parse are both ok=false —
// authorization never proceeds on an unrecognized role.
member_role :: proc(c: ^pg.Conn, project_id: i64, account_id: i64) -> (identity.Role, bool) {
	r, qe := pg.query_one(
		c,
		"memberships.role",
		"SELECT role FROM memberships WHERE project_id = $1 AND account_id = $2",
		{pg.arg_i64(project_id), pg.arg_i64(account_id)},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		return .Viewer, false
	}
	role_str, _ := pg.row_text(&r, 0, context.temp_allocator)
	return identity.role_parse(role_str)
}

// require_role gates a mutation: the caller must be a member whose role ranks at
// least `need`. On failure it commits a 403 and returns false. A caller that is
// not a member gets the same 403 as one whose role is too low — the response
// does not disclose membership.
require_role :: proc(
	ctx: ^web.Context,
	c: ^pg.Conn,
	project_id: i64,
	account_id: i64,
	need: identity.Role,
) -> bool {
	role, ok := member_role(c, project_id, account_id)
	if !ok || !identity.role_allows(role, need) {
		web.forbidden(ctx, "You do not have permission for this project")
		return false
	}
	return true
}

// create_project makes a project AND the owner's membership atomically. A
// project without an owner membership would be an orphan nobody can administer,
// so the two writes are one transaction: either both land or neither does. This
// is WP104's transaction evidence, extended in WP105.
@(private)
create_project :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	input: Create_Project
	if !web.body(ctx, &input) {
		return
	}
	v := validate.validator()
	defer validate.destroy(&v)
	validate.not_empty(&v, "name", input.name)
	validate.string_length(&v, "name", input.name, min = 1, max = PROJECT_NAME_MAX)
	if vh.respond_if_invalid(ctx, &v) {
		return
	}

	// Resolve the caller on a pooled connection, then release it before opening
	// the transaction (begin acquires its own connection), so the handler holds
	// only one connection at a time.
	ac, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	id, ok := require_session(ctx, &ac)
	if !ok {
		pg.release(&st.db, &ac)
		return
	}
	pg.release(&st.db, &ac)

	tx, te := pg.begin(&st.db)
	if pg.is_err(te) {
		respond_db_error(ctx, te)
		return
	}
	defer pg.rollback_if_open(&tx)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	pr, pe := pg.tx_query_one(
		&tx,
		"projects.insert",
		"INSERT INTO projects (name, owner_id) VALUES ($1, $2) RETURNING id, version, created_at::text",
		{pg.arg_text(input.name), pg.arg_i64(id.account_id)},
	)
	defer pg.rows_close(&pr)
	if pg.is_err(pe) {
		respond_db_error(ctx, pe)
		return
	}
	project_id, _ := pg.row_i64(&pr, 0)
	version, _ := pg.row_i64(&pr, 1)
	created, _ := pg.row_text(&pr, 2, ally)

	_, me := pg.tx_execute(
		&tx,
		"memberships.insert_owner",
		"INSERT INTO memberships (project_id, account_id, role) VALUES ($1, $2, 'owner')",
		{pg.arg_i64(project_id), pg.arg_i64(id.account_id)},
	)
	if pg.is_err(me) {
		respond_db_error(ctx, me)
		return
	}

	if ce := pg.commit(&tx); pg.is_err(ce) {
		respond_db_error(ctx, ce)
		return
	}

	audit("project.create", id.account_id)
	web.created(
		ctx,
		Project_View{
			id = project_id,
			name = input.name,
			owner_id = id.account_id,
			version = version,
			created_at = created,
		},
	)
}

// invite_member adds another account to a project with a role. Only a member who
// ranks maintainer-or-higher may invite; a viewer or non-member is refused.
@(private)
invite_member :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	project_id, pok := web.path_int(ctx, "id")
	if !pok {
		web.bad_request(ctx, "project id must be an integer")
		return
	}

	input: Invite
	if !web.body(ctx, &input) {
		return
	}
	role, role_ok := identity.role_parse(input.role)
	if !role_ok {
		web.bad_request(ctx, "role must be one of owner, maintainer, member, viewer")
		return
	}

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
	if !require_role(ctx, &c, i64(project_id), id.account_id, .Maintainer) {
		return
	}

	_, qe := pg.execute(
		&c,
		"memberships.insert",
		"INSERT INTO memberships (project_id, account_id, role) VALUES ($1, $2, $3)",
		{pg.arg_i64(i64(project_id)), pg.arg_i64(input.account_id), pg.arg_text(identity.role_string(role))},
	)
	if pg.is_err(qe) {
		#partial switch qe.kind {
		case .Unique_Violation:
			respond_conflict(ctx, "That account is already a member")
		case .Foreign_Key_Violation:
			web.bad_request(ctx, "no such project or account")
		case:
			respond_db_error(ctx, qe)
		}
		return
	}

	audit("project.invite", id.account_id)
	web.no_content(ctx)
}

// get_project is a role-gated read: any member (viewer or above) may see the
// project. It demonstrates the read side of the authorization check.
@(private)
get_project :: proc(ctx: ^web.Context) {
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
	defer pg.release(&st.db, &c)

	id, ok := require_session(ctx, &c)
	if !ok {
		return
	}
	if !require_role(ctx, &c, i64(project_id), id.account_id, .Viewer) {
		return
	}

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	r, qe := pg.query_one(
		&c,
		"projects.by_id",
		"SELECT id, name, owner_id, version, created_at::text FROM projects WHERE id = $1",
		{pg.arg_i64(i64(project_id))},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		if qe.kind == .Row_Not_Found {
			web.not_found(ctx, "project")
			return
		}
		respond_db_error(ctx, qe)
		return
	}

	pid, _ := pg.row_i64(&r, 0)
	name, _ := pg.row_text(&r, 1, ally)
	owner_id, _ := pg.row_i64(&r, 2)
	version, _ := pg.row_i64(&r, 3)
	created, _ := pg.row_text(&r, 4, ally)
	web.ok(
		ctx,
		Project_View{id = pid, name = name, owner_id = owner_id, version = version, created_at = created},
	)
}
