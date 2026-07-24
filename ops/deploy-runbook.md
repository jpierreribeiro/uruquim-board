# Deployment #2 runbook — uruquim-board WP104–109

Deployment #1 (WP103, the boring health page) is recorded in `DEPLOYMENTS.md`.
This runbook is the **ready-to-execute procedure for deployment #2**, which ships
the WP104–109 code (identity, relational workflows, files/spool, SSE, and the
observability wiring) and applies migrations `0002`–`0004`. It is written so the
owner — or the next session, once VPS access is available — can run it top to
bottom without rediscovery.

Everything stays **isolated under `/opt/uruquim-verify`**. Do NOT touch the box's
CI runner (`dalivim-runner`) or the Caddy on 80/443/2019.

## 0. Prerequisites (already in place from deployment #1)

- VPS `45.32.215.234`, root over SSH (password is chat-only; consider switching
  to an SSH key).
- PostgreSQL container `uruquim-board-pg` on `127.0.0.1:55432`
  (`board`/`board_dev_pw`/`board`, dev loopback, `sslmode=disable`).
- Toolchain at `/opt/uruquim-odin` (commit `819fdc7`) → `ODIN_ROOT=/opt/uruquim-odin`.
- Pinned checkouts: core `/opt/uruquim-verify/repo` (@`closure`), crystals
  `/opt/uruquim-verify/crystals` (@`36db55c`), board `/opt/uruquim-verify/board`.
- `libpq-dev` installed on the host.
- systemd unit `ops/uruquim-board.service` (`:18080`, `LimitMEMLOCK=infinity`,
  `EnvironmentFile=/opt/uruquim-verify/board.env`).

## 1. Sync the pinned checkouts

```sh
cd /opt/uruquim-verify/board && git fetch origin && git checkout master && git pull
# core/crystals only if the pins moved (they did not for WP104–109) — see DEPS.md
```

## 2. Build the server + migrate binaries (needs libpq-dev; BOARD_LINK=1)

```sh
cd /opt/uruquim-verify/board
env BOARD_LINK=1 \
    URUQUIM_CORE=/opt/uruquim-verify/repo \
    CRYSTALS_ROOT=/opt/uruquim-verify/crystals \
    URUQUIM_ODIN_BIN=/opt/uruquim-odin/odin \
    bash build/check.sh
# check.sh links build/board when BOARD_LINK=1; also build the migrate tool:
env ODIN_ROOT=/opt/uruquim-odin /opt/uruquim-odin/odin build /opt/uruquim-verify/crystals/cmd/migrate \
    -collection:crystals=/opt/uruquim-verify/crystals \
    -collection:uruquim=/opt/uruquim-verify/repo \
    -out:/opt/uruquim-verify/migrate
```

## 3. Apply migrations 0002–0004 as a DEPLOY STEP (the server never migrates on boot)

`0001_accounts` was applied in deployment #1. Apply the rest, in order, BEFORE
restarting the server. Migrations are immutable and checksum-guarded.

```sh
env MIGRATE_DIR=/opt/uruquim-verify/board/migrations \
    MIGRATE_HOST=127.0.0.1 MIGRATE_PORT=55432 \
    MIGRATE_USER=board MIGRATE_PASSWORD=board_dev_pw MIGRATE_DB=board \
    MIGRATE_SSLMODE=disable MIGRATE_ALLOW_PLAINTEXT=1 \
    /opt/uruquim-verify/migrate up
# expect: 0002_projects, 0003_tasks, 0004_attachments applied; 0001 already done
```

## 4. Update the env file for the new WP106 storage config

Append to `/opt/uruquim-verify/board.env` (attachment storage + spool dir):

```
BOARD_STORAGE_DIR=/opt/uruquim-verify/storage
BOARD_SPOOL_DIR=/opt/uruquim-verify/storage/spool
BOARD_MAX_ATTACHMENT=52428800
```

`application_init` creates `BOARD_STORAGE_DIR`; the framework's ingest substrate
creates the spool dir. Ensure the service user can write both.

## 5. Install the new binary and restart under systemd

```sh
install -m0755 /opt/uruquim-verify/board/build/board /opt/uruquim-verify/board-server
systemctl restart uruquim-board.service
systemctl status uruquim-board.service --no-pager   # Active: running, serving on :18080
journalctl -u uruquim-board.service -n 30 --no-pager
```

`LimitMEMLOCK=infinity` is REQUIRED — without it the io_uring ring setup fails on
the 8 MiB default and `web.serve` exits cleanly (F-C03-2 / patch 30). It is baked
into the unit.

## 6. Smoke-test the new surface

Run `ops/smoke.sh` (below) against `http://127.0.0.1:18080`. It exercises the
WP104–109 happy paths and the optimistic-conflict 409, and checks `/admin/stats`
and `/obs/metrics`. A large (> 4 MiB) attachment to prove the spool path is a
separate manual step (generate a file, POST it, confirm `spooled=true`).

## 7. Record the deployment

Append a `## #2` section to `DEPLOYMENTS.md`: date, pins (board SHA, core, crystals,
toolchain), what shipped (WP104–109 + migrations 0002–0004), the smoke-test
result table, and anything learned. Deployment #2 counts toward the
≥10-deployment threshold (WP102 §8).

## What this deployment does NOT yet cover (operational, multi-session)

- WP108 concurrency/backpressure tests (two-client conflict, slow consumer,
  pool-at-cap) — run against this live server.
- The ≥4 h soak (session-expiry + connection-recycle boundaries).
- WP110 failure/recovery drills; WP111 the ≥5th migration (a real backfill +
  expand/contract evolution); WP112 human/AI usability; WP113 verdict.
- The dataset generation (≥5 projects, ≥500 tasks, ≥2000 comments, ≥50
  attachments incl. ≥1 spooled).
