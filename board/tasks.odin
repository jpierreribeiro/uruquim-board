package board

// WP105 — the relational core: tasks, comments, the status machine, optimistic
// concurrency and a persistent audit trail. Built on the WP104 identity/RBAC
// foundation; every handler resolves the caller and their project role first.
//
// The interesting framework/Crystal surfaces exercised here:
//   - explicit named SQL with bound params (never interpolation);
//   - a transaction spanning several writes (mutation + audit row commit together);
//   - OPTIMISTIC conflict detection: UPDATE ... WHERE version = $read; zero rows
//     affected on a task that exists means a concurrent edit won — answered 409;
//   - unique/foreign-key violations mapped to domain errors;
//   - nullable columns (body, assignee_id) distinct from zero/empty;
//   - query NAMES in diagnostics, bound VALUES never logged.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import pg "crystals:db/postgres"
import "crystals:validate"
import vh "crystals:web/validate"
import web "uruquim:web"
import "board:identity"
import tf "board:taskflow"
import tp "board:taskpatch"

TASK_TITLE_MAX :: 200
TASK_BODY_MAX :: 20_000
COMMENT_BODY_MAX :: 20_000
TASK_LIST_LIMIT :: 100

// The task's text column is `description` (renamed from `body` via the
// expand/contract migrations 0006/0007). The JSON API field stays `body` for a
// stable external contract — the rename is physical only, scanned back into the
// Task_View.body field at the same position.
TASK_COLUMNS ::
	"id, project_id, title, description, status, assignee_id, created_at::text, updated_at::text, version, comment_count"

Create_Task :: struct {
	title:       string        `json:"title"`,
	body:        Maybe(string) `json:"body"`,
	assignee_id: Maybe(i64)    `json:"assignee_id"`,
}

// The three-state PATCH intent (Task_Patch) and its parser live in the pure
// `board:taskpatch` sub-package, unit-tested without a database. This handler
// consumes taskpatch.parse's result.

Task_View :: struct {
	id:          i64           `json:"id"`,
	project_id:  i64           `json:"project_id"`,
	title:       string        `json:"title"`,
	body:        Maybe(string) `json:"body"`,       // JSON null when the column is NULL
	status:      string        `json:"status"`,
	assignee_id: Maybe(i64)    `json:"assignee_id"`, // JSON null when unassigned
	created_at:    string        `json:"created_at"`,
	updated_at:    string        `json:"updated_at"`,
	version:       i64           `json:"version"`,
	comment_count: i64           `json:"comment_count"`,
}

Task_List :: struct {
	tasks:      []Task_View `json:"tasks"`,
	next_after: i64         `json:"next_after"`, // 0 when there is no next page
}

Create_Comment :: struct {
	body: string `json:"body"`,
}

Comment_View :: struct {
	id:         i64    `json:"id"`,
	task_id:    i64    `json:"task_id"`,
	author_id:  i64    `json:"author_id"`,
	body:       string `json:"body"`,
	created_at: string `json:"created_at"`,
}

Comment_List :: struct {
	comments: []Comment_View `json:"comments"`,
}

// ---------------------------------------------------------------------------
// tasks
// ---------------------------------------------------------------------------

@(private)
create_task :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	project_id, pok := web.path_int(ctx, "id")
	if !pok {
		web.bad_request(ctx, "project id must be an integer")
		return
	}

	input: Create_Task
	if !web.body(ctx, &input) {
		return
	}
	v := validate.validator()
	defer validate.destroy(&v)
	validate.not_empty(&v, "title", input.title)
	validate.string_length(&v, "title", input.title, min = 1, max = TASK_TITLE_MAX)
	if b, has := input.body.?; has {
		validate.string_length(&v, "body", b, max = TASK_BODY_MAX)
	}
	if vh.respond_if_invalid(ctx, &v) {
		return
	}

	actor, ok := authorize(ctx, st, i64(project_id), .Member)
	if !ok {
		return
	}

	tx, te := pg.begin(&st.db)
	if pg.is_err(te) {
		respond_db_error(ctx, te)
		return
	}
	defer pg.rollback_if_open(&tx)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	body_param := pg.arg_null()
	if b, has := input.body.?; has {
		body_param = pg.arg_text(b)
	}
	assignee_param := pg.arg_null()
	if a, has := input.assignee_id.?; has {
		assignee_param = pg.arg_i64(a)
	}

	r, qe := pg.tx_query_one(
		&tx,
		"tasks.insert",
		"INSERT INTO tasks (project_id, title, description, assignee_id) VALUES ($1, $2, $3, $4) RETURNING " +
		TASK_COLUMNS,
		{pg.arg_i64(i64(project_id)), pg.arg_text(input.title), body_param, assignee_param},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		task_db_error(ctx, qe)
		return
	}
	task := scan_task(&r, ally)

	if ae := audit_write(&tx, i64(project_id), actor.account_id, "task.create", "task", task.id); pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	if ce := pg.commit(&tx); pg.is_err(ce) {
		respond_db_error(ctx, ce)
		return
	}
	notify(st.hub, i64(project_id), "task.create", "task", task.id)
	web.created(ctx, task)
}

@(private)
list_tasks :: proc(ctx: ^web.Context) {
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

	// Keyset (cursor) pagination: `after` is the last id the client saw; the page
	// is the next `limit` rows with a greater id. Stable under concurrent inserts
	// — a new task with a higher id never shifts an earlier page (unlike OFFSET).
	after, _ := web.query_int_or(ctx, "after", 0)
	limit, _ := web.query_int_or(ctx, "limit", TASK_LIST_LIMIT)
	if limit <= 0 || limit > TASK_LIST_LIMIT {
		limit = TASK_LIST_LIMIT
	}

	// Dynamic filters, built with BOUND params (never interpolation). Optional
	// status and assignee narrow the set; absent filters match everything via a
	// NULL-guarded predicate, so one prepared shape serves every combination.
	status_filter := pg.arg_null()
	if s, has := web.query(ctx, "status"); has && s != "" {
		if _, sok := tf.status_parse(s); !sok {
			web.bad_request(ctx, "unknown status filter")
			return
		}
		status_filter = pg.arg_text(s)
	}
	assignee_filter := pg.arg_null()
	// `assignee` is an OPTIONAL typed filter. web.query_int cannot serve it: it is
	// the REQUIRED-parameter reader and commits a 400 when the param is absent.
	// web.query_int_or does not commit on absence, but its ok=true for both
	// absent (default) and present-valid, so it cannot tell "filter" from "no
	// filter". The optional-typed read is therefore two calls: web.query for
	// presence, then query_int_or for a present-but-malformed 400 (friction F8-6).
	if _, has := web.query(ctx, "assignee"); has {
		a, aok := web.query_int_or(ctx, "assignee", 0)
		if !aok {
			return // present but malformed: query_int_or committed the 400
		}
		assignee_filter = pg.arg_i64(i64(a))
	}

	rows, qe := pg.query(
		&c,
		"tasks.list",
		"SELECT " + TASK_COLUMNS + " FROM tasks " +
		"WHERE project_id = $1 AND id > $2 " +
		"AND ($3::text IS NULL OR status = $3) " +
		"AND ($4::bigint IS NULL OR assignee_id = $4) " +
		"ORDER BY id LIMIT $5",
		{
			pg.arg_i64(i64(project_id)),
			pg.arg_i64(i64(after)),
			status_filter,
			assignee_filter,
			pg.arg_i64(i64(limit)),
		},
	)
	defer pg.rows_close(&rows)
	if pg.is_err(qe) {
		respond_db_error(ctx, qe)
		return
	}

	list := make([dynamic]Task_View, 0, 0, ally)
	for pg.rows_next(&rows) {
		append(&list, scan_task(&rows, ally))
	}

	// next_after is the last id of a FULL page, else 0 (no more rows). A short
	// page means the client has reached the end.
	next_after: i64 = 0
	if len(list) == limit && len(list) > 0 {
		next_after = list[len(list) - 1].id
	}
	web.ok(ctx, Task_List{tasks = list[:], next_after = next_after})
}

@(private)
get_task :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	task_id, tok := web.path_int(ctx, "id")
	if !tok {
		web.bad_request(ctx, "task id must be an integer")
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	project_id, _, found := task_project(&c, i64(task_id))
	if !found {
		// Do not reveal existence to a non-member: a missing task and a task in a
		// project you cannot see both answer 404 after the auth check below. But
		// we still need SOME project to check against; an absent task is a plain
		// 404 once the caller is authenticated.
		id, ok := require_session(ctx, &c)
		if !ok {
			return
		}
		_ = id
		web.not_found(ctx, "task")
		return
	}

	id, ok := require_session(ctx, &c)
	if !ok {
		return
	}
	if !require_role(ctx, &c, project_id, id.account_id, .Viewer) {
		return
	}

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	r, qe := pg.query_one(
		&c,
		"tasks.by_id",
		"SELECT " + TASK_COLUMNS + " FROM tasks WHERE id = $1",
		{pg.arg_i64(i64(task_id))},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		if qe.kind == .Row_Not_Found {
			web.not_found(ctx, "task")
			return
		}
		respond_db_error(ctx, qe)
		return
	}
	web.ok(ctx, scan_task(&r, ally))
}

// patch_task edits a task under OPTIMISTIC concurrency. The client sends the
// version it read; the UPDATE matches on that version, so a concurrent edit that
// already bumped it affects zero rows and the caller gets 409 — never a silent
// last-write. The mutation and its audit row commit together.
@(private)
patch_task :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	task_id, tok := web.path_int(ctx, "id")
	if !tok {
		web.bad_request(ctx, "task id must be an integer")
		return
	}

	input, parse_ok := tp.parse(ctx.request.body)
	if !parse_ok {
		web.bad_request(ctx, "invalid patch body (unknown field, wrong type, or missing version)")
		return
	}
	if input.version <= 0 {
		web.bad_request(ctx, "version is required and must be positive")
		return
	}
	// title and status map to NOT NULL columns: an explicit JSON null is invalid
	// (distinct from absent, which keeps the current value).
	if validate.patch_is_null(input.title) {
		web.bad_request(ctx, "title may not be null")
		return
	}
	if validate.patch_is_null(input.status) {
		web.bad_request(ctx, "status may not be null")
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}

	project_id, cur_status_str, found := task_project(&c, i64(task_id))
	if !found {
		id, ok := require_session(ctx, &c)
		pg.release(&st.db, &c)
		if !ok {
			return
		}
		_ = id
		web.not_found(ctx, "task")
		return
	}

	actor, ok := require_session(ctx, &c)
	if !ok {
		pg.release(&st.db, &c)
		return
	}
	if !require_role(ctx, &c, project_id, actor.account_id, .Member) {
		pg.release(&st.db, &c)
		return
	}
	pg.release(&st.db, &c) // done with the auth connection; the write opens its own tx

	// Resolve the requested status against the machine BEFORE any write.
	new_status_str := cur_status_str
	if s, has := validate.patch_get(input.status); has {
		to, sok := tf.status_parse(s)
		if !sok {
			web.bad_request(ctx, "status must be one of open, in_progress, blocked, closed")
			return
		}
		from, _ := tf.status_parse(cur_status_str)
		if to != from {
			if !tf.status_can_transition(from, to) {
				respond_conflict(ctx, "illegal status transition")
				return
			}
			new_status_str = tf.status_string(to)
		}
	}

	tx, te := pg.begin(&st.db)
	if pg.is_err(te) {
		respond_db_error(ctx, te)
		return
	}
	defer pg.rollback_if_open(&tx)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	// True three-state application. title: set|keep (null already rejected).
	// body and assignee: set|null|keep, encoded as a mode string the SQL branches
	// on, so an explicit JSON null CLEARS the column while an absent field leaves
	// it untouched — the distinction Maybe cannot carry.
	title_present := validate.patch_is_set(input.title)
	title_param := pg.arg_null()
	if v, has := validate.patch_get(input.title); has {
		title_param = pg.arg_text(v)
	}

	body_mode := tp.patch_mode(input.body)
	body_param := pg.arg_null()
	if v, has := validate.patch_get(input.body); has {
		body_param = pg.arg_text(v)
	}

	assignee_mode := tp.patch_mode(input.assignee_id)
	assignee_param := pg.arg_null()
	if v, has := validate.patch_get(input.assignee_id); has {
		assignee_param = pg.arg_i64(v)
	}

	cmd, ue := pg.tx_execute(
		&tx,
		"tasks.update",
		"UPDATE tasks SET " +
		"title = CASE WHEN $1 THEN $2 ELSE title END, " +
		"description = CASE $3 WHEN 'set' THEN $4 WHEN 'null' THEN NULL ELSE description END, " +
		"status = $5, " +
		"assignee_id = CASE $6 WHEN 'set' THEN $7 WHEN 'null' THEN NULL ELSE assignee_id END, " +
		"updated_at = now(), version = version + 1 " +
		"WHERE id = $8 AND version = $9",
		{
			pg.arg_bool(title_present),
			title_param,
			pg.arg_text(body_mode),
			body_param,
			pg.arg_text(new_status_str),
			pg.arg_text(assignee_mode),
			assignee_param,
			pg.arg_i64(i64(task_id)),
			pg.arg_i64(input.version),
		},
	)
	if pg.is_err(ue) {
		task_db_error(ctx, ue)
		return
	}
	if cmd.rows_affected == 0 {
		// The task exists (task_project found it) but the version did not match:
		// a concurrent edit won. This is the optimistic-conflict 409.
		respond_conflict(ctx, "the task was modified by someone else; refetch and retry")
		return
	}

	detail := status_detail(cur_status_str, new_status_str)
	if wae := audit_write(&tx, project_id, actor.account_id, "task.update", "task", i64(task_id), detail);
	   pg.is_err(wae) {
		respond_db_error(ctx, wae)
		return
	}
	if ce := pg.commit(&tx); pg.is_err(ce) {
		respond_db_error(ctx, ce)
		return
	}
	notify(st.hub, project_id, "task.update", "task", i64(task_id))

	// Read the fresh row back to return the new version.
	rc, rae := pg.acquire(&st.db)
	if pg.is_err(rae) {
		web.no_content(ctx) // the write succeeded; only the read-back failed
		return
	}
	defer pg.release(&st.db, &rc)
	r, qe := pg.query_one(
		&rc,
		"tasks.by_id",
		"SELECT " + TASK_COLUMNS + " FROM tasks WHERE id = $1",
		{pg.arg_i64(i64(task_id))},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		web.no_content(ctx)
		return
	}
	web.ok(ctx, scan_task(&r, ally))
}

// ---------------------------------------------------------------------------
// comments
// ---------------------------------------------------------------------------

@(private)
add_comment :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	task_id, tok := web.path_int(ctx, "id")
	if !tok {
		web.bad_request(ctx, "task id must be an integer")
		return
	}

	input: Create_Comment
	if !web.body(ctx, &input) {
		return
	}
	v := validate.validator()
	defer validate.destroy(&v)
	validate.not_empty(&v, "body", input.body)
	validate.string_length(&v, "body", input.body, min = 1, max = COMMENT_BODY_MAX)
	if vh.respond_if_invalid(ctx, &v) {
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}

	project_id, _, found := task_project(&c, i64(task_id))
	if !found {
		id, ok := require_session(ctx, &c)
		pg.release(&st.db, &c)
		if !ok {
			return
		}
		_ = id
		web.not_found(ctx, "task")
		return
	}

	actor, ok := require_session(ctx, &c)
	if !ok {
		pg.release(&st.db, &c)
		return
	}
	if !require_role(ctx, &c, project_id, actor.account_id, .Member) {
		pg.release(&st.db, &c)
		return
	}
	pg.release(&st.db, &c)

	tx, te := pg.begin(&st.db)
	if pg.is_err(te) {
		respond_db_error(ctx, te)
		return
	}
	defer pg.rollback_if_open(&tx)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	r, qe := pg.tx_query_one(
		&tx,
		"comments.insert",
		"INSERT INTO comments (task_id, author_id, body) VALUES ($1, $2, $3) " +
		"RETURNING id, task_id, author_id, body, created_at::text",
		{pg.arg_i64(i64(task_id)), pg.arg_i64(actor.account_id), pg.arg_text(input.body)},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		task_db_error(ctx, qe)
		return
	}
	comment := scan_comment(&r, ally)

	// Maintain the denormalized counter (migration 0005) in the SAME transaction,
	// so the count can never drift from the comment rows.
	if _, ce := pg.tx_execute(
		&tx,
		"tasks.bump_comment_count",
		"UPDATE tasks SET comment_count = comment_count + 1 WHERE id = $1",
		{pg.arg_i64(i64(task_id))},
	); pg.is_err(ce) {
		respond_db_error(ctx, ce)
		return
	}

	if wae := audit_write(&tx, project_id, actor.account_id, "comment.create", "comment", comment.id);
	   pg.is_err(wae) {
		respond_db_error(ctx, wae)
		return
	}
	if ce := pg.commit(&tx); pg.is_err(ce) {
		respond_db_error(ctx, ce)
		return
	}
	notify(st.hub, project_id, "comment.create", "comment", comment.id)
	web.created(ctx, comment)
}

@(private)
list_comments :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	task_id, tok := web.path_int(ctx, "id")
	if !tok {
		web.bad_request(ctx, "task id must be an integer")
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	project_id, _, found := task_project(&c, i64(task_id))
	if !found {
		id, ok := require_session(ctx, &c)
		if !ok {
			return
		}
		_ = id
		web.not_found(ctx, "task")
		return
	}

	id, ok := require_session(ctx, &c)
	if !ok {
		return
	}
	if !require_role(ctx, &c, project_id, id.account_id, .Viewer) {
		return
	}

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	rows, qe := pg.query(
		&c,
		"comments.list",
		"SELECT id, task_id, author_id, body, created_at::text FROM comments " +
		"WHERE task_id = $1 ORDER BY id LIMIT $2",
		{pg.arg_i64(i64(task_id)), pg.arg_i64(TASK_LIST_LIMIT)},
	)
	defer pg.rows_close(&rows)
	if pg.is_err(qe) {
		respond_db_error(ctx, qe)
		return
	}

	list := make([dynamic]Comment_View, 0, 0, ally)
	for pg.rows_next(&rows) {
		append(&list, scan_comment(&rows, ally))
	}
	web.ok(ctx, Comment_List{comments = list[:]})
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// authorize resolves the caller and checks a project role using a short-lived
// pooled connection, then releases it — for handlers whose write happens in a
// separate transaction. It answers 401/403 itself; ok=false means already
// answered.
@(private)
authorize :: proc(
	ctx: ^web.Context,
	st: ^App_State,
	project_id: i64,
	need: identity.Role,
) -> (
	Identity,
	bool,
) {
	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return {}, false
	}
	defer pg.release(&st.db, &c)

	id, ok := require_session(ctx, &c)
	if !ok {
		return {}, false
	}
	if !require_role(ctx, &c, project_id, id.account_id, need) {
		return {}, false
	}
	return id, true
}

// task_project resolves a task's project and current status. found=false when no
// such task. Used to authorize /tasks/:id handlers, whose route carries only the
// task id.
@(private)
task_project :: proc(c: ^pg.Conn, task_id: i64) -> (project_id: i64, status: string, found: bool) {
	r, qe := pg.query_one(
		c,
		"tasks.project_of",
		"SELECT project_id, status FROM tasks WHERE id = $1",
		{pg.arg_i64(task_id)},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		return 0, "", false
	}
	pid, _ := pg.row_i64(&r, 0)
	// status is copied into temp_allocator; it is consumed immediately by the
	// caller (transition check) within the same request.
	sstr, _ := pg.row_text(&r, 1, context.temp_allocator)
	return pid, sstr, true
}

@(private)
scan_task :: proc(r: ^pg.Rows, ally: mem.Allocator) -> Task_View {
	id, _ := pg.row_i64(r, 0)
	project_id, _ := pg.row_i64(r, 1)
	title, _ := pg.row_text(r, 2, ally)
	body, _ := pg.row_opt_text(r, 3, ally)
	status, _ := pg.row_text(r, 4, ally)
	assignee, _ := pg.row_opt_i64(r, 5)
	created, _ := pg.row_text(r, 6, ally)
	updated, _ := pg.row_text(r, 7, ally)
	version, _ := pg.row_i64(r, 8)
	comment_count, _ := pg.row_i64(r, 9)
	return Task_View {
		id = id,
		project_id = project_id,
		title = title,
		body = body,
		status = status,
		assignee_id = assignee,
		created_at = created,
		updated_at = updated,
		version = version,
		comment_count = comment_count,
	}
}

@(private)
scan_comment :: proc(r: ^pg.Rows, ally: mem.Allocator) -> Comment_View {
	id, _ := pg.row_i64(r, 0)
	task_id, _ := pg.row_i64(r, 1)
	author_id, _ := pg.row_i64(r, 2)
	body, _ := pg.row_text(r, 3, ally)
	created, _ := pg.row_text(r, 4, ally)
	return Comment_View {
		id = id,
		task_id = task_id,
		author_id = author_id,
		body = body,
		created_at = created,
	}
}

// task_db_error maps the integrity violations tasks/comments can raise to domain
// responses; everything else falls through to the generic mapping.
@(private)
task_db_error :: proc(ctx: ^web.Context, e: pg.Error) {
	#partial switch e.kind {
	case .Foreign_Key_Violation:
		// e.g. an assignee_id or task_id that does not exist.
		web.bad_request(ctx, "a referenced project, task or account does not exist")
	case .Check_Violation:
		web.bad_request(ctx, "a field is outside its allowed set")
	case:
		respond_db_error(ctx, e)
	}
}

// status_detail builds the audit detail JSON for a task update from the CLOSED
// status vocabulary — no user free-text ever enters the audit document.
@(private)
status_detail :: proc(from: string, to: string) -> string {
	if from == to {
		return "{}"
	}
	// from/to are always status_string outputs (a closed set), so this is safe to
	// interpolate — no quoting hazard, no injection.
	return fmt.aprintf(`{{"from":"%s","to":"%s"}}`, from, to, allocator = context.temp_allocator)
}
