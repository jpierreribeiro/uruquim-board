-- 0005 — denormalized tasks.comment_count, WITH A BACKFILL (WP111 evidence).
--
-- A board sorts and displays tasks with their comment counts; counting comments
-- per task on every list is O(comments). A denormalized counter, maintained in
-- the same transaction as a comment insert (board/tasks.odin add_comment), is
-- the ordinary optimization. This migration adds the column and BACKFILLS it
-- from the real comment rows — the "≥1 backfill" the phase pre-registers (WP102
-- §8 / G8-2), run against the seeded volume (600 tasks, 2400 comments).
--
-- Migrations are a deploy STEP, immutable once applied (checksum-guarded).

ALTER TABLE tasks ADD COLUMN comment_count INTEGER NOT NULL DEFAULT 0;

-- Backfill: set each task's counter to its actual comment count. A single
-- correlated UPDATE over the whole table — the classic backfill shape.
UPDATE tasks t
SET comment_count = (
    SELECT count(*) FROM comments c WHERE c.task_id = t.id
);
