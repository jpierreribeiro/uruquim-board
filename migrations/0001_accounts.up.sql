-- 0001 — identity foundation: accounts and sessions.
--
-- Migrations are a deploy STEP, applied by `migrate up` before any server
-- process starts. The server never migrates on boot (plan hypothesis 4).
-- Immutable once applied: a later change is a NEW migration, never an edit
-- (WP111 / the checksum guard).

CREATE TABLE accounts (
    id            BIGSERIAL PRIMARY KEY,
    email         TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
    id         BIGSERIAL PRIMARY KEY,
    account_id BIGINT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ
);

-- Session lookup is by token hash (unique above); expiry sweeps scan by
-- expires_at among the still-live rows.
CREATE INDEX sessions_expires_at_idx ON sessions (expires_at) WHERE revoked_at IS NULL;
