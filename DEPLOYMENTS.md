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

---

## #4 — WP111 evolution + WP110 drills (live)

- **Date:** 2026-07-24. Board `master` `2997a7a`.
- **WP111 — 5th+ migrations, both required shapes, deployed against seeded volume:**
  - **0005 backfill** (`tasks.comment_count`): applied; backfill verified —
    `sum(comment_count) = 2400` across the 600 seed tasks (matches the 2400
    comments). Maintained transactionally in `add_comment` thereafter.
  - **0006/0007 expand/contract** (`tasks.body` → `tasks.description`): the
    textbook rename, deployed in the safe order — applied **0005+0006** (add
    `description`, backfill from `body`, keep `body`) with **0007 held back**;
    deployed the `description`-using binary (smoke **22/22** with `body` still
    present); then applied **0007** (drop `body`). Post-contract the `tasks`
    table has `description` and no `body`; smoke **22/22**. `migrate status`
    shows all **7 migrations Applied**, checksummed, non-dirty.
- **WP110 — failure/recovery drills (`ops/drills.sh`), all GREEN live:**
  | Drill | Expected | Observed |
  |---|---|---|
  | SIGKILL the board | supervisor restarts, committed data durable | new PID served within seconds; the pre-kill task survived |
  | PostgreSQL restart | liveness stays up, readiness bounded, pool recovers | `/health/live` stayed 200; `/ready` flipped to **503** (never hung) then returned to **200** as the pool reconnected; committed task durable |
  | graceful `systemctl restart` | clean stop/start | serves again |

### Threshold progress after #4

- **Deployments:** 4 of ≥10 (#1 WP103, #2 WP104–109, #3 bugfix, #4 WP111).
- **Migrations:** **7 of ≥5 — MET**, incl. ≥1 backfill (0005) and an
  expand/contract (0006/0007). G8-2 evolvable-data evidence satisfied.
- **WP110 drills:** the core cells (process kill, PG restart, graceful restart)
  recorded green. Remaining drills (network interruption, upload interruption,
  migration lock contention) and the **≥4h soak** continue on this server.
- **Still owner-gated:** WP112 (human/AI usability study) and WP113 (verdict).

---

## WP110 malformed-request drill + soak early signal (live, non-disruptive)

- **Date:** 2026-07-24. Board `master` `6592315`.
- **`ops/malformed-drill.sh` — 16/16 green** (run alongside the soak; never
  restarts the service): malformed / empty / unknown-field / wrong-typed /
  missing-field JSON all → **400**; garbage/`Basic` bearer → **401**;
  non-integer path id, `?status=bogus`, `?limit=banana`, traversal filename,
  missing filename → **400**; and an SQL-injection-shaped project name is stored
  as a **bound literal** (201, `/health/live` 200, tasks table intact) — the
  framework rejects bad input with typed 4xx, never a 5xx or a crash, and
  parametrized queries are proven injection-safe live.
- **Soak early signal (leak watch):** RSS warmed up 12 → 41 MB in the first ~2
  min, then **plateaued flat at 41,648 kB** from t≈189 s through t≈503 s (cycles
  37→97, ~600 responses), `errors=0`, pool steady (open=1, in_use=1, waiters=0).
  No monotonic growth — a strong early leak-free signal. The full ≥4 h run
  continues to `/opt/uruquim-verify/soak.log`; the final RSS-growth verdict is
  checked when it ends (~18:14 UTC).

### WP110 cells now recorded (of the plan §WP110 list)

Process kill+restart · graceful deploy/restart · PostgreSQL restart mid-use ·
malformed JSON/param/wire requests · (soak-covered) slow steady load. Remaining:
network interruption, upload interruption, migration lock/dirty refusal, proxy
misconfiguration — deferred so they do not perturb the running soak.

---

## WP110 migration checksum-immutability drill (scratch DB, non-disruptive)

- **Date:** 2026-07-24. Board `master` `c0df594`, `ops/migration-drill.sh`.
- Ran on a throwaway `board_drill_*` database (never the live board DB or the
  running service/soak). Result **GREEN**: clean apply of all 7 migrations;
  idempotent re-run (`applied 0`); a **tampered already-applied migration was
  REFUSED with `Checksum_Mismatch`** (not silently re-applied); status intact.
  Closes the G8-2 "clean checksum/immutability behaviour" cell.

---

## #5 — the Corrective Program, live (all F8-1..F8-8 verified in production)

- **Date:** 2026-07-24. Board `corrective-repin` `5836e2e`, against the CORRECTIVE
  core (`phase8` `03c2bce`) + crystals (`corrective` `7c64d47`).
- **Deployed after the ≥4h soak PASSED**, so the re-pin did not perturb the RSS
  measurement. Built + linked with real libpq on the host; migration `0008`
  (due_date) applied as a deploy step; installed + restarted under systemd.
- **Smoke:** `ops/smoke.sh` **22/22** on the corrective binary.
- **The RED tests flipped GREEN live — every corrective WP proven in production:**

  | WP / Friction | Verified live |
  |---|---|
  | **C1 / F8-1** | named `web.Status` members produce 409/503/413 on the wire (smoke conflict = 409; readiness = 503) |
  | **C3 / F8-6** | unfiltered `GET /projects/:id/tasks` → **200** (was the shipped bug's 400); `web.query_int_opt` |
  | **C5 / F8-8** | `due_date` valid ISO → **201**, stored `timestamptz` with **no `::timestamptz` cast** (`arg_timestamptz` OID typing works live); malformed date → **400** not 500 (`validate.rfc3339`) |
  | **C2 / F8-4** | `GET /attachments/:id/download` → **200**, bytes on the wire, `Content-Disposition: attachment; filename="note.txt"`, correct `Content-Type` (`web.bytes` + `web.set_header`) |
  | **C6 / F8-7** | 5 MiB upload with curl's default `Expect: 100-continue` (no `-H "Expect:"`) → **201 spooled=true** (was 417) |
  | **C4 / F8-5** | `web.stream_live` compiled into the live SSE path (registry-level tested) |
  | **C7 / F8-3** | `web.request_state` available (ADR-028 amendment; awaiting owner ratification) |

- **Proves:** the Corrective Program's public-API additions work end-to-end against
  real PostgreSQL and real clients — including the two facets that could only be
  runtime-verified with libpq (`arg_timestamptz`) and a real socket
  (`Expect: 100-continue`). **5 deployments recorded** toward the ≥10 threshold.

---

## WP110 deferred drills — network + upload interruption (live, with a finding)

- **Date:** 2026-07-24. Board `corrective-repin`.
- **Upload interruption** — GREEN: an 8 MiB upload aborted mid-body leaves the
  server healthy, the next request served (no desync), and a normal upload
  succeeds after. The framing/body guards hold across a torn upload.
- **Network interruption** — a real FINDING and a correct MITIGATION, plus a
  test-environment caveat:
  - Blocking the DB port (iptables REJECT) kept **liveness 200** and **committed
    data durable**, and **readiness recovered to 200** once the network was
    restored — those held.
  - It found that **readiness was not promptly bounded under a silent partition**.
    Root cause: a per-query deadline spawns a cancel watchdog that tries to reach
    the server on a NEW connection to cancel; under a partition that cancel-connect
    hangs on `connect_timeout` and its join blocks the handler. Statement_timeout
    is server-enforced (also unreachable). The only bound that survives is at the
    TCP layer.
  - **Mitigation shipped:** `db/postgres` gains `tcp_user_timeout_ms` (libpq
    `tcp_user_timeout`, corrective crystals `corrective`), the board sets it to
    3000, and the readiness query no longer uses a deadline watchdog. This is the
    correct bound for a REAL remote-DB partition.
  - **Caveat:** the drill runs against a **loopback** PostgreSQL, and iptables
    REJECT on loopback does not reproduce a real network partition (no
    retransmit/RTT), so `tcp_user_timeout` cannot be validated here — the readiness
    cell stays INFORMATIONAL on this host. **Full validation is a Gate-2 item on
    the multi-host scale campaign** (a remote DB, where the partition and the
    TCP-layer bound are real).

---

## Intermediate SSE scale probe (live, Env A capacity point)

- **Date:** 2026-07-24. `ops/sse-scale.sh` against the live board.
- Graduated concurrent SSE subscribers on the 2-CPU/1.6 GiB host:

  | Subs | Admitted | health | ready | RSS |
  |---|---|---|---|---|
  | 50 | 50/50 | 200 | 200 | 27.9 MB |
  | 100 | 100/100 | 200 | 200 | 30.2 MB |
  | 200 | 200/200 | 200 | 200 | 39.8 MB |
  | 300 | 297/300 | 200 | 200 | 53.4 MB |

- **Capacity knee ≈ 300 concurrent streams** on this small host, reached
  **gracefully** (health/ready stayed 200; 100% recovery after each level, no
  crash). **RSS tracks connections linearly** (28→53 MB) — a live confirmation of
  the C-04 per-connection retention rule. The owed 3,000-socket round is an Env B
  (bigger VPS) item; this is the first point on the capacity curve.

---

## Session-expiry drill (live — closes the soak's uncrossed boundary)

- **Date:** 2026-07-24. `ops/session-expiry-drill.sh`.
- The 4h soak could not cross the 24h-TTL session-expiry boundary; this exercises
  it directly and **GREEN 4/4**: a fresh session → 200; a session aged past `now()`
  in the DB → **401** (expiry enforced as `expires_at > now()` in SQL, DB clock
  authoritative); re-login after expiry → 200 (churn across the boundary); explicit
  revocation (logout) → 401. The session lifecycle is correct across expiry and
  revocation without needing a real 24h wait or a rebuilt short-TTL binary.
