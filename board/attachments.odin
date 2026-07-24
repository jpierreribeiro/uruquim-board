package board

// WP106 — task attachments: the buffered upload path AND the Phase-7 spool path,
// an application size cap refused before persistence, and the file/database
// boundary made explicit (there is NO atomic filesystem+DB transaction).
//
// UPLOAD is a raw-body POST: the body IS the file. A body within max_body (4 MiB)
// is buffered (`ctx.request.body`); a body OVER max_body took the spool path
// (`web.upload`/`web.upload_persist`) because cmd/main.odin called
// `web.enable_upload`. Either way the file lands on disk at a GENERATED name
// (never the client's), then the row is inserted in a transaction with an audit
// entry. If the row fails after the file is on disk, the file is COMPENSATED
// (deleted) — the documented orphan-cleanup boundary.
//
// DOWNLOAD of the bytes IS served (download_attachment): the corrective WPs added
// web.bytes (a buffered binary responder) and web.set_header (Content-Disposition),
// so an authenticated, safely-dispositioned file download is now expressible
// (friction F8-4, resolved). Metadata is still served separately as JSON.

import "core:crypto"
import "core:encoding/hex"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import pg "crystals:db/postgres"
import web "uruquim:web"
import "board:sanitize"

Attachment_View :: struct {
	id:           i64    `json:"id"`,
	task_id:      i64    `json:"task_id"`,
	uploader_id:  i64    `json:"uploader_id"`,
	filename:     string `json:"filename"`,
	content_type: string `json:"content_type"`,
	byte_size:    i64    `json:"byte_size"`,
	spooled:      bool   `json:"spooled"`,
	created_at:   string `json:"created_at"`,
}

Attachment_List :: struct {
	attachments: []Attachment_View `json:"attachments"`,
}

ATTACHMENT_COLUMNS ::
	"id, task_id, uploader_id, filename, content_type, byte_size, spooled, created_at::text"

@(private)
upload_attachment :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	task_id, tok := web.path_int(ctx, "id")
	if !tok {
		web.bad_request(ctx, "task id must be an integer")
		return
	}

	// The filename is metadata (display only); the on-disk name is generated, so
	// a hostile filename cannot traverse the storage directory. It is still
	// validated so a bad name is a clear 400, not a silent surprise.
	filename, has_name := web.query(ctx, "filename")
	if !has_name || !sanitize.valid_filename(filename) {
		web.bad_request(ctx, "a valid filename query parameter is required")
		return
	}
	content_type := "application/octet-stream"
	if ct, ok := web.header(ctx, "content-type"); ok && ct != "" {
		content_type = ct
	}

	// Authorize on the task's project before touching any bytes.
	ac, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	project_id, _, found := task_project(&ac, i64(task_id))
	if !found {
		id, ok := require_session(ctx, &ac)
		pg.release(&st.db, &ac)
		if !ok {
			return
		}
		_ = id
		web.not_found(ctx, "task")
		return
	}
	actor, ok := require_session(ctx, &ac)
	if !ok {
		pg.release(&st.db, &ac)
		return
	}
	if !require_role(ctx, &ac, project_id, actor.account_id, .Member) {
		pg.release(&st.db, &ac)
		return
	}
	pg.release(&st.db, &ac)

	// Place the bytes on disk. Either the spool path (body > max_body) or the
	// buffered path (body <= max_body). The generated destination is unique.
	dest, name_ok := storage_path(st.storage_dir)
	if !name_ok {
		web.internal_error(ctx)
		return
	}

	size: i64
	spooled: bool
	if up, is_spooled := web.upload(ctx); is_spooled {
		// Large body: the framework spooled it. Refuse over the app cap before
		// persisting (the framework already enforces per_upload_quota mid-body;
		// this is the application's own policy line).
		if st.max_attachment_bytes > 0 && up.size > st.max_attachment_bytes {
			respond_too_large(ctx)
			return
		}
		if !web.upload_persist(ctx, dest) {
			// Persist failed (e.g. a cross-filesystem rename); teardown still
			// deletes the spool file, so nothing leaks.
			web.internal_error(ctx)
			return
		}
		size = up.size
		spooled = true
	} else {
		// Small body: buffered. The raw request body IS the file.
		raw := ctx.request.body
		if len(raw) == 0 {
			web.bad_request(ctx, "empty upload")
			return
		}
		if st.max_attachment_bytes > 0 && i64(len(raw)) > st.max_attachment_bytes {
			respond_too_large(ctx)
			return
		}
		if werr := os.write_entire_file(dest, raw); werr != nil {
			web.internal_error(ctx)
			return
		}
		size = i64(len(raw))
		spooled = false
	}

	// The file is on disk. Record the row in a transaction with an audit entry.
	// On ANY failure past this point, COMPENSATE by removing the file — there is
	// no atomic filesystem+DB transaction, and an orphan file is the boundary we
	// clean up rather than pretend away.
	tx, te := pg.begin(&st.db)
	if pg.is_err(te) {
		os.remove(dest)
		respond_db_error(ctx, te)
		return
	}
	defer pg.rollback_if_open(&tx)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	r, qe := pg.tx_query_one(
		&tx,
		"attachments.insert",
		"INSERT INTO attachments (task_id, uploader_id, filename, content_type, byte_size, storage_path, spooled) " +
		"VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING " + ATTACHMENT_COLUMNS,
		{
			pg.arg_i64(i64(task_id)),
			pg.arg_i64(actor.account_id),
			pg.arg_text(filename),
			pg.arg_text(content_type),
			pg.arg_i64(size),
			pg.arg_text(dest),
			pg.arg_bool(spooled),
		},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		os.remove(dest) // compensation
		task_db_error(ctx, qe)
		return
	}
	att := scan_attachment(&r, ally)

	if wae := audit_write(&tx, project_id, actor.account_id, "attachment.create", "attachment", att.id);
	   pg.is_err(wae) {
		os.remove(dest) // compensation
		respond_db_error(ctx, wae)
		return
	}
	if ce := pg.commit(&tx); pg.is_err(ce) {
		os.remove(dest) // compensation
		respond_db_error(ctx, ce)
		return
	}
	notify(st.hub, project_id, "attachment.create", "attachment", att.id)
	web.created(ctx, att)
}

@(private)
list_attachments :: proc(ctx: ^web.Context) {
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
		"attachments.list",
		"SELECT " + ATTACHMENT_COLUMNS + " FROM attachments WHERE task_id = $1 ORDER BY id LIMIT $2",
		{pg.arg_i64(i64(task_id)), pg.arg_i64(TASK_LIST_LIMIT)},
	)
	defer pg.rows_close(&rows)
	if pg.is_err(qe) {
		respond_db_error(ctx, qe)
		return
	}
	list := make([dynamic]Attachment_View, 0, 0, ally)
	for pg.rows_next(&rows) {
		append(&list, scan_attachment(&rows, ally))
	}
	web.ok(ctx, Attachment_List{attachments = list[:]})
}

// get_attachment returns attachment METADATA as JSON. The actual bytes are
// served by download_attachment (below): corrective WPs C2 (web.bytes +
// web.set_header) made an authenticated, safely-dispositioned download
// expressible (friction F8-4, previously a recorded gap).
@(private)
get_attachment :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	att_id, aok := web.path_int(ctx, "id")
	if !aok {
		web.bad_request(ctx, "attachment id must be an integer")
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	// Resolve the attachment and its project in one join, for the auth check.
	// Columns MUST be table-qualified: `id` and `created_at` exist on BOTH
	// attachments and tasks, so the unqualified ATTACHMENT_COLUMNS list is
	// ambiguous in a join and PostgreSQL rejects it (found live: this was a 500).
	r, qe := pg.query_one(
		&c,
		"attachments.by_id",
		"SELECT a.id, a.task_id, a.uploader_id, a.filename, a.content_type, a.byte_size, " +
		"a.spooled, a.created_at::text, t.project_id FROM attachments a " +
		"JOIN tasks t ON t.id = a.task_id WHERE a.id = $1",
		{pg.arg_i64(i64(att_id))},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		if qe.kind == .Row_Not_Found {
			web.not_found(ctx, "attachment")
			return
		}
		respond_db_error(ctx, qe)
		return
	}
	att := scan_attachment(&r, ally)
	project_id, _ := pg.row_i64(&r, 8)

	id, ok := require_session(ctx, &c)
	if !ok {
		return
	}
	if !require_role(ctx, &c, project_id, id.account_id, .Viewer) {
		return
	}
	web.ok(ctx, att)
}

// download_attachment serves the attachment BYTES — the download the framework
// could not express before the corrective WPs (friction F8-4). It is auth-gated
// exactly like get_attachment (viewer+ on the task's project), then reads the
// stored file and returns it with:
//   - web.bytes(ctx, .OK, content_type, data): the buffered binary responder (C2),
//     the stored media type on the wire;
//   - web.set_header(ctx, "Content-Disposition", attachment; filename="..."):
//     forces a safe download with the original filename (C2 set_header), closing
//     the inline-render/stored-XSS hazard the metadata-only workaround left open.
@(private)
download_attachment :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	att_id, aok := web.path_int(ctx, "id")
	if !aok {
		web.bad_request(ctx, "attachment id must be an integer")
		return
	}

	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)

	r, qe := pg.query_one(
		&c,
		"attachments.download_by_id",
		"SELECT a.filename, a.content_type, a.storage_path, t.project_id FROM attachments a " +
		"JOIN tasks t ON t.id = a.task_id WHERE a.id = $1",
		{pg.arg_i64(i64(att_id))},
	)
	defer pg.rows_close(&r)
	if pg.is_err(qe) {
		if qe.kind == .Row_Not_Found {
			web.not_found(ctx, "attachment")
			return
		}
		respond_db_error(ctx, qe)
		return
	}
	filename, _ := pg.row_text(&r, 0, ally)
	content_type, _ := pg.row_text(&r, 1, ally)
	storage_path, _ := pg.row_text(&r, 2, ally)
	project_id, _ := pg.row_i64(&r, 3)

	id, ok := require_session(ctx, &c)
	if !ok {
		return
	}
	if !require_role(ctx, &c, project_id, id.account_id, .Viewer) {
		return
	}

	data, read_err := os.read_entire_file(storage_path, ally)
	if read_err != nil {
		// The row exists but the bytes are gone (an orphaned row) — a 404 for the
		// content, distinct from a 500.
		web.not_found(ctx, "attachment content")
		return
	}

	// Content-Disposition with the sanitized filename. `filename` was validated at
	// upload (no CR/LF/quote/traversal), so it is safe to place in the header;
	// web.set_header additionally rejects any control byte.
	disposition := strings.concatenate({"attachment; filename=\"", filename, "\""}, ally)
	web.set_header(ctx, "Content-Disposition", disposition)
	web.bytes(ctx, .OK, content_type, data)
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

@(private)
scan_attachment :: proc(r: ^pg.Rows, ally: mem.Allocator) -> Attachment_View {
	id, _ := pg.row_i64(r, 0)
	task_id, _ := pg.row_i64(r, 1)
	uploader_id, _ := pg.row_i64(r, 2)
	filename, _ := pg.row_text(r, 3, ally)
	content_type, _ := pg.row_text(r, 4, ally)
	byte_size, _ := pg.row_i64(r, 5)
	spooled, _ := pg.row_bool(r, 6)
	created, _ := pg.row_text(r, 7, ally)
	return Attachment_View {
		id = id,
		task_id = task_id,
		uploader_id = uploader_id,
		filename = filename,
		content_type = content_type,
		byte_size = byte_size,
		spooled = spooled,
		created_at = created,
	}
}

// respond_too_large is 413. Like 503/409, 413 has no named member in the public
// web.Status enum (friction F8-1), so it is spelled as a raw int cast.
@(private)
respond_too_large :: proc(ctx: ^web.Context) {
	web.json(
		ctx,
		.Payload_Too_Large,
		Message{Message_Body{code = "too_large", message = "The attachment exceeds the allowed size"}},
	)
}

// storage_path generates a unique on-disk destination under dir. The name is
// random hex, so it never reflects client input and two uploads never collide.
@(private)
storage_path :: proc(dir: string) -> (string, bool) {
	raw: [16]byte
	crypto.rand_bytes(raw[:])
	encoded, herr := hex.encode(raw[:], context.temp_allocator)
	if herr != nil {
		return "", false
	}
	return strings.concatenate({dir, "/", string(encoded)}, context.temp_allocator), true
}
