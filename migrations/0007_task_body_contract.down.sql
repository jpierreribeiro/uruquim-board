-- 0007 rollback: re-add `body` and backfill it from `description`, restoring the
-- dual-column expand state so a body-reading binary can run again.
ALTER TABLE tasks ADD COLUMN body TEXT;
UPDATE tasks SET body = description;
