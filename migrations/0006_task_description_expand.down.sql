-- 0006 rollback (expand half). Dropping `description` returns to a body-only
-- schema; safe only if the app has been rolled back to the body-using binary.
ALTER TABLE tasks DROP COLUMN IF EXISTS description;
