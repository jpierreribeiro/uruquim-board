# Deployment log

Phase 8 pre-registers **≥ 10 recorded deployments** (planning/phase-8-plan.md
§4, WP102 spec §8). Each is logged here with what was deployed, where, the
outcome, and anything learned. Synthetic data only.

---

## #1 — first deployment: the boring health page (WP103)

- **Date:** 2026-07-24
- **Host:** `45.32.215.234` (owner's test VPS), isolated under `/opt/uruquim-verify`; the box's existing CI runner and Caddy were not touched.
- **Pins:** core `uruquim@closure` (`e92c0cf`), crystals `main` (`36db55c`), toolchain `dev-2026-07a` (`819fdc7`). Board `f94c0df`.
- **Stack:** systemd (`uruquim-board.service`, Restart=always, TimeoutStopSec=30, LimitMEMLOCK=infinity) → board-server on `:18080` → isolated PostgreSQL 16 container (`127.0.0.1:55432`).
- **Steps:** `libpq-dev` installed on the host (client lib, non-disruptive); board + migrate binaries built against the pinned public core+Crystals and **linked against real libpq** (the postgres-Crystal FFI proven end-to-end); migration `0001_accounts` applied as a **deploy step** (`migrate up`, before the server started — the server never migrates on boot); service started under systemd.
- **Result — GREEN:**

  | Request | Result |
  |---|---|
  | `GET /` | `200 uruquim-board: up` |
  | `GET /health/live` | `200 ok` (the health Crystal) |
  | `GET /ready` | `200 ready` — readiness **acquired a pooled connection and ran `SELECT 1`** against PostgreSQL |

- **Proves:** lifecycle and delivery, independently of any domain feature — the whole stack (core + Crystals via pinned public contracts, bounded pool, migrations-as-a-deploy-step, supervision) runs on real hardware.

- **LEARNED — the F-C03-2 fix validated in a real deployment.** The first start
  did **not** stay up: the server printed `serving on :18080` and then exited
  cleanly every ~1 s (systemd "Deactivated successfully", restart-looping). The
  cause is exactly the Hardening finding F-C03-2: the VPS default
  `RLIMIT_MEMLOCK` is 8 MiB, the io_uring ring setup fails against it, and
  **Hardening patch 30 makes `web.serve` fail gracefully (a clean exit) instead
  of the pre-patch process crash.** The remedy the patch-29 diagnostic names —
  raise the locked-memory limit — is `LimitMEMLOCK=infinity` in the unit; adding
  it made the service serve. So a diagnosis + fix made in the framework's own
  Hardening phase was validated, unprompted, by the first real deployment: the
  failure was clean and the recorded remedy worked. This requirement is now
  baked into `ops/uruquim-board.service`.

---

## #2 — WP104–109: identity, relational, files/spool, SSE, observability

- **Date:** 2026-07-24
- **Host:** `45.32.215.234`, isolated under `/opt/uruquim-verify`.
- **Pins:** board `master` (`46ff710` → the WP104–109 code), core `uruquim@closure`, crystals `main` `36db55c`, toolchain `819fdc7`.
- **Steps:** synced the board; built + linked against real libpq (`BOARD_LINK=1`, gate green incl. 14 pure tests on the deploy host); built the `migrate` tool; applied migrations **0002_projects, 0003_tasks, 0004_attachments** as a deploy step (`migrate up` — 0001 already applied in #1; the `_uruquim_migrations` tracker shows all 4 clean, non-dirty, checksummed); added the WP106 storage env (`BOARD_STORAGE_DIR`/`BOARD_SPOOL_DIR`/`BOARD_MAX_ATTACHMENT`); installed the binary; `systemctl restart`.
- **Result:** service `active`, `serving on :18080`, no restart loop (`LimitMEMLOCK=infinity`). Smoke test **found 2 real bugs** (below).

## #3 — bugfix redeploy (found by deployment #2 proof-by-use)

- **Date:** 2026-07-24. Board `master` `a830b4d`.
- **Two bugs the smoke test surfaced against live PostgreSQL, both fixed:**
  1. the task-list optional `assignee` filter used `web.query_int` (the
     REQUIRED-param reader, which commits a 400 on absence) → every unfiltered
     list 400'd. Fixed to `web.query` (presence) + `web.query_int_or`. → **F8-6**.
  2. `GET /attachments/:id` selected the unqualified `ATTACHMENT_COLUMNS` in a
     `attachments JOIN tasks` where `id`/`created_at` are ambiguous → PostgreSQL
     500. Fixed with `a.`-qualified columns.
- **Result after redeploy — GREEN:**

  | Suite | Result |
  |---|---|
  | `ops/smoke.sh` (WP104–109) | **22 / 22 passed** |
  | `ops/concurrency-check.sh` (WP108) | two-client same-version PATCH → **one 200 + one 409**; pool-at-cap → `/health/live` stays 200 while a task-list gets a fast 503 (39×200, 1×503) |
  | `ops/seed.sql` dataset | **5 projects, 600 tasks, 2400 comments** (≥ the pre-registered ≥5/≥500/≥2000) |
  | large attachment (5 MiB > `max_body`) | **spooled=true**, 201 — the Phase-7 spool path proven live end-to-end |

- **LEARNED — a third framework finding, F8-7:** a 5 MiB upload with curl's
  default `Expect: 100-continue` header returned **HTTP 417** (empty body); the
  framework does not honor/ignore the universal `100-continue` expectation, so
  large uploads from default clients (curl, python-requests) fail until the
  header is stripped (`-H "Expect:"`). Recorded in the core friction ledger.

### Deployment threshold progress

3 of the pre-registered ≥10 deployments recorded (#1 WP103, #2 WP104–109, #3
bugfix). Remaining deploys, the ≥4h soak, WP110 drills, and WP111's ≥5th
migration (backfill + expand/contract) continue on this live server.
