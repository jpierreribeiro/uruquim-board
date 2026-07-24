-- 0001 rollback.
DROP INDEX IF EXISTS sessions_expires_at_idx;
DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS accounts;
