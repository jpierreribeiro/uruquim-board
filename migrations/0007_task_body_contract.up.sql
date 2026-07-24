-- 0007 — CONTRACT half of the tasks.body -> tasks.description rename (WP111).
--
-- Applied ONLY after the description-using app (deployed between 0006 and here)
-- is confirmed healthy. Dropping `body` is the irreversible commit of the
-- rename: after this, a rollback to a body-reading binary would fail, which is
-- why the expand/contract order matters — the column outlives the last binary
-- that needed it. Immutable once applied.

ALTER TABLE tasks DROP COLUMN body;
