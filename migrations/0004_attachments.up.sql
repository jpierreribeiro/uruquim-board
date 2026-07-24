-- 0004 — task attachments (files, validation, the spool path).
--
-- The row is the source of truth for an attachment; the bytes live on disk at
-- storage_path. There is NO atomic filesystem+database transaction (plan §WP106):
-- the file is persisted first, then the row is inserted, and on a failed insert
-- the file is compensated (deleted). A crash between the two leaves an orphan
-- file that the orphan-cleanup procedure reconciles (a file under the storage
-- dir with no attachments.storage_path pointing at it — see board/attachments.odin).
--
-- Migrations are a deploy STEP, immutable once applied (WP111 / checksum guard).

CREATE TABLE attachments (
    id           BIGSERIAL PRIMARY KEY,
    task_id      BIGINT NOT NULL REFERENCES tasks (id) ON DELETE CASCADE,
    uploader_id  BIGINT NOT NULL REFERENCES accounts (id) ON DELETE RESTRICT,
    filename     TEXT NOT NULL,                     -- the client-supplied name, sanitized
    content_type TEXT NOT NULL DEFAULT 'application/octet-stream',
    byte_size    BIGINT NOT NULL,
    storage_path TEXT NOT NULL UNIQUE,              -- a generated name; never the client's
    -- spooled = true when the body arrived over max_body and took the Phase-7
    -- spool path (web.upload/upload_persist); false when it was buffered.
    spooled      BOOLEAN NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX attachments_task_id_idx ON attachments (task_id, id);
