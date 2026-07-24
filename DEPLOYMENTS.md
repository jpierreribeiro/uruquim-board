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
