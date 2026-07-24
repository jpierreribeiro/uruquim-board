-- 0008 — optional task due date (the WP112 usability-study feature, merged).
--
-- Three independent coding agents converged byte-identically on this shape from
-- the public API alone (planning/phase-8-wp112-usability-study.md); it is merged
-- here as a real feature. Nullable: a task without a due date is NULL, distinct
-- from any sentinel. Immutable once applied.

ALTER TABLE tasks ADD COLUMN due_date TIMESTAMPTZ;
