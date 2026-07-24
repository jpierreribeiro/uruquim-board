-- Dataset generator for the Phase-8 pre-registered thresholds (WP102 §8):
--   ≥ 5 projects, ≥ 500 tasks, ≥ 2000 comments — a non-trivial persistent
--   dataset, generated and OWNED for the test. Synthetic data only.
--
-- Run on the VPS against the isolated board database AFTER migrations 0001–0004
-- are applied (ops/deploy-runbook.md), e.g.:
--
--   PGPASSWORD=board_dev_pw psql -h 127.0.0.1 -p 55432 -U board -d board \
--       -v ON_ERROR_STOP=1 -f ops/seed.sql
--
-- Idempotent-ish: it keys accounts/projects on fixed synthetic emails/names, so
-- re-running appends another generation of tasks/comments rather than
-- duplicating the owners. The attachment threshold (≥50, ≥1 spooled > max_body)
-- is exercised through the upload PATH, not bulk SQL — see ops/smoke.sh and the
-- runbook's manual large-file step — because an attachment row must point at
-- real bytes on disk.
--
-- NOTE ON HASHES: seeded accounts carry a NON-LOGIN placeholder password_hash.
-- They exist to own bulk data and to be assignees; they are not meant to log in.
-- A real, loginable account is created via POST /register (smoke.sh).

BEGIN;

-- 5 owner accounts. The placeholder hash is deliberately NOT a valid argon2id
-- encoding, so verify_password can never accept it — these accounts cannot log
-- in, by construction.
INSERT INTO accounts (email, password_hash)
SELECT format('seed+owner%s@example.com', g), '!seed-nonlogin!'
FROM generate_series(1, 5) AS g
ON CONFLICT (email) DO NOTHING;

-- 5 projects, each owned by one seed account, each with the owner as a member.
WITH owners AS (
    SELECT id, row_number() OVER (ORDER BY id) AS n
    FROM accounts WHERE email LIKE 'seed+owner%@example.com'
),
new_projects AS (
    INSERT INTO projects (name, owner_id)
    SELECT format('Seed Project %s', n), id FROM owners
    RETURNING id, owner_id
)
INSERT INTO memberships (project_id, account_id, role)
SELECT id, owner_id, 'owner' FROM new_projects
ON CONFLICT (project_id, account_id) DO NOTHING;

-- 600 tasks spread across the seed projects (>= the 500 threshold), each with a
-- rotating status from the closed set.
WITH proj AS (
    SELECT id, row_number() OVER (ORDER BY id) AS n
    FROM projects WHERE name LIKE 'Seed Project %'
),
ins_tasks AS (
    INSERT INTO tasks (project_id, title, status)
    SELECT
        p.id,
        format('Seed task %s', g),
        (ARRAY['open','in_progress','blocked','closed'])[1 + (g % 4)]
    FROM generate_series(1, 600) AS g
    JOIN proj p ON p.n = 1 + (g % (SELECT count(*) FROM proj))
    RETURNING id
)
SELECT count(*) AS tasks_created FROM ins_tasks;

-- 4 comments per seed task (>= the 2000 threshold), authored by a seed owner.
WITH seed_task AS (
    SELECT t.id AS task_id,
           (SELECT id FROM accounts WHERE email LIKE 'seed+owner%@example.com' ORDER BY id LIMIT 1) AS author
    FROM tasks t
    WHERE t.title LIKE 'Seed task %'
),
ins_comments AS (
    INSERT INTO comments (task_id, author_id, body)
    SELECT st.task_id, st.author, format('Seed comment %s', g)
    FROM seed_task st, generate_series(1, 4) AS g
    RETURNING id
)
SELECT count(*) AS comments_created FROM ins_comments;

COMMIT;

-- Report the totals so the operator can confirm the thresholds are met.
SELECT
    (SELECT count(*) FROM projects WHERE name LIKE 'Seed Project %') AS projects,
    (SELECT count(*) FROM tasks    WHERE title LIKE 'Seed task %')   AS tasks,
    (SELECT count(*) FROM comments WHERE body  LIKE 'Seed comment %') AS comments;
