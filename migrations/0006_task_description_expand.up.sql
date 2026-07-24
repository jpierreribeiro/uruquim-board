-- 0006 — EXPAND half of an expand/contract rename: tasks.body -> tasks.description
-- (WP111 evidence: the "≥1 expand/contract" transition, G8-2).
--
-- "body" is a vague name; "description" is what the product means. A rename that
-- cannot take downtime is done as EXPAND then CONTRACT across two deploys:
--
--   0006 (this, EXPAND): add `description`, backfill it from `body`, and KEEP
--         `body`. Both columns now exist. The app is deployed to read/write
--         `description` (board/tasks.odin) while `body` still stands, so a
--         rollback to the previous binary — which reads `body` — is still safe.
--   0007 (CONTRACT): once the description-using app is confirmed healthy, drop
--         `body`. Only then is the old column gone.
--
-- The backfill runs over real seeded volume (600 tasks). Immutable once applied.

ALTER TABLE tasks ADD COLUMN description TEXT;

-- Backfill the new column from the old one (a NULL body stays NULL — the
-- nullable semantics are preserved across the rename).
UPDATE tasks SET description = body;
