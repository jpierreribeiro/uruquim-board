-- 0003 — the relational core: tasks, comments and a persistent audit log.
--
-- WP105 builds the board's real workflows on the WP104 identity/RBAC foundation.
-- Migrations are a deploy STEP, immutable once applied (WP111 / checksum guard).

CREATE TABLE tasks (
    id          BIGSERIAL PRIMARY KEY,
    project_id  BIGINT NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    body        TEXT,                                    -- nullable: absent body is NULL, not ''
    -- The status machine is a CLOSED set; legal TRANSITIONS are enforced in the
    -- handler (board/tasks.odin), the set membership here.
    status      TEXT NOT NULL DEFAULT 'open'
                CHECK (status IN ('open', 'in_progress', 'blocked', 'closed')),
    assignee_id BIGINT REFERENCES accounts (id) ON DELETE SET NULL,  -- nullable: unassigned
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- version carries OPTIMISTIC concurrency: an edit reads a version and writes
    -- WHERE version = $read; a concurrent edit that already bumped it matches
    -- zero rows and the handler answers 409 (WP105/108).
    version     BIGINT NOT NULL DEFAULT 1
);

-- Listing a project's tasks scans by project_id and pages by id; the composite
-- index serves both the filter and the keyset order (WP106 pagination).
CREATE INDEX tasks_project_id_idx ON tasks (project_id, id);

CREATE TABLE comments (
    id         BIGSERIAL PRIMARY KEY,
    task_id    BIGINT NOT NULL REFERENCES tasks (id) ON DELETE CASCADE,
    author_id  BIGINT NOT NULL REFERENCES accounts (id) ON DELETE RESTRICT,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX comments_task_id_idx ON comments (task_id, id);

-- Persistent audit history. Every project-scoped mutation writes a row here in
-- the SAME transaction as the change, so the log cannot drift from the data. It
-- records the ACTOR and the ACTION and a small structured detail — never a
-- password, token or request body (the redaction budget, E8-6).
CREATE TABLE audit_log (
    id          BIGSERIAL PRIMARY KEY,
    project_id  BIGINT NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    actor_id    BIGINT NOT NULL REFERENCES accounts (id) ON DELETE RESTRICT,
    action      TEXT NOT NULL,
    target_kind TEXT NOT NULL,
    target_id   BIGINT NOT NULL,
    at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    detail      JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX audit_log_project_id_idx ON audit_log (project_id, id);
