-- 0002 — projects and per-project role membership (RBAC foundation).
--
-- WP104 delivers identity (0001: accounts, sessions) AND authorization. Role
-- checks need something to be a member OF, so projects and memberships land
-- here. The full task/comment relational workflows build on this in WP105.
--
-- Migrations are a deploy STEP, applied by `migrate up` before any server
-- process starts. Immutable once applied: a later change is a NEW migration,
-- never an edit (WP111 / the checksum guard).

CREATE TABLE projects (
    id         BIGSERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    owner_id   BIGINT NOT NULL REFERENCES accounts (id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- version carries optimistic concurrency: a concurrent edit that reads an
    -- older version and writes back is rejected (WP105/108 exercise the 409).
    version    BIGINT NOT NULL DEFAULT 1
);

-- Per-project role membership. The role set is CLOSED and enforced by a CHECK
-- so an unknown role is a write-time failure, never a silent authorization
-- gap. Ranking (owner > maintainer > member > viewer) lives in the application
-- (board/authz.odin) — the database stores the fact, the app ranks it.
CREATE TABLE memberships (
    project_id BIGINT NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
    account_id BIGINT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    role       TEXT NOT NULL CHECK (role IN ('owner', 'maintainer', 'member', 'viewer')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, account_id)
);

-- Authorization looks a membership up by (project, account); the primary key
-- above already indexes that. Listing a project's members scans by project_id,
-- which the composite PK's leading column also serves.
