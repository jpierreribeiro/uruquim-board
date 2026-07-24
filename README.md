# uruquim-board

A small collaborative operations/project board, built on the
[Uruquim](https://github.com/jpierreribeiro/uruquim) web framework and its
[Crystals](https://github.com/jpierreribeiro/uruquim-crystals). It is the
**Phase-8 proof-by-use reference system**: the point is to run the framework
under real, multi-user, data-backed load — deployed, evolved and faulted — not
to add framework features.

It depends **only on pinned public contracts** (see `DEPS.md`): no friend
import, no core internal, no build flag a normal consumer could not set. That
constraint is the evidence — a friction that would need an internal becomes a
recorded framework finding, never a quiet reach-through.

## Status

**WP105 delivered** (planning/phase-8-plan.md in the core repo).

WP103 — lifecycle and delivery:

- the composition root — a typed `App_State` owning the bounded PostgreSQL pool,
  `application_init`/`destroy`, explicit config from the environment;
- a boring health surface before any domain feature: `/` (up), `/health/live`
  (the health Crystal), and `/ready` (readiness that acquires a pooled
  connection and runs `SELECT 1`, failing fast with 503 while liveness stays up);
- the first migration (`0001_accounts`), applied as a **deploy step** — the
  server never migrates on boot;
- a portable build gate (`build/check.sh`) that typechecks against the pinned
  public core+Crystals and forbids any internal import (G8-1).

WP104 — identity, sessions and authorization:

- **password storage** with argon2id (`core:crypto/argon2id`, OWASP small
  profile), self-describing hashes so the cost can change without a migration;
- **opaque bearer-token sessions** — login returns the token in the JSON body;
  only its SHA-256 hash is stored; the client sends `Authorization: Bearer …`.
  The framework's public surface has **no way to set a response header**, so
  cookies (and the CSRF they need) are inexpressible — a recorded framework
  finding, **F8-2**, not an application choice. Bearer tokens make CSRF moot;
- **session expiry and revocation** — liveness checked in SQL (the database
  clock is authoritative); `/logout` revokes the presented token;
- **per-project role membership** (`owner > maintainer > member > viewer`) with
  `require_session` / `require_role` guarding each protected handler. That the
  auth prologue repeats in every handler — ADR-028 forbids a `Context` extension
  bag — is **measured**, not hidden: friction **F8-3**;
- routes: `POST /register`, `POST /login`, `POST /logout`, `GET /me`,
  `POST /projects` (project + owner membership in one **transaction**),
  `GET /projects/:id`, `POST /projects/:id/members`;
- migration `0002_projects` (projects + memberships, closed role set enforced by
  a CHECK), applied as a deploy step;
- the security-critical logic (hashing, tokens, roles) lives in a pure
  `identity/` sub-package that depends only on Odin core — **unit-tested in the
  build gate with no PostgreSQL** (`tests/wp104-identity`). The DB-touching
  handlers are exercised against a live PostgreSQL on the VPS.

WP105 — relational workflows and transactions:

- **tasks, comments and assignment** over explicit named SQL (bound params, never
  interpolation); routes `POST/GET /projects/:id/tasks`, `GET/PATCH /tasks/:id`,
  `POST/GET /tasks/:id/comments`;
- a **task status machine** (`open → in_progress/blocked/closed`, closed is
  terminal except reopen) in the pure `taskflow/` sub-package, unit-tested
  (`tests/wp105-taskflow`) and enforced by the PATCH handler before any write;
- **optimistic concurrency**: PATCH matches on the version the client read
  (`UPDATE … WHERE version = $read`); a concurrent edit that already bumped it
  affects zero rows → **409**, never a silent last-write (corroborates F8-1: 409
  is another `web.Status(409)` cast);
- a **transaction spanning several writes** on every mutation — the change and its
  **persistent `audit_log` row commit together**, so the history cannot drift from
  the data;
- integrity violations mapped to domain errors (foreign-key / check → 400);
- nullable columns (`body`, `assignee_id`) kept distinct from empty/zero;
- migration `0003_tasks` (tasks + comments + audit_log, status CHECK), a deploy
  step. Full cursor pagination and three-state PATCH are WP106.

## Layout

```
board/        the application package (App_State, config, routes, auth, authz)
identity/     pure security logic (password/token/role) — no framework, no libpq
cmd/          the deployable server (package main)
migrations/   immutable, numbered up/down SQL — applied by `migrate up` at deploy
tests/        pure unit tests run by the build gate (identity)
build/        the build gate
DEPS.md       the pinned dependency SHAs
```

## Build

```
env URUQUIM_CORE=<uruquim@closure> \
    CRYSTALS_ROOT=<uruquim-crystals@36db55c> \
    URUQUIM_ODIN_BIN=<pinned odin> \
    bash build/check.sh
```

Typecheck runs anywhere; producing the linked binary needs `libpq-dev` on the
build host (`BOARD_LINK=1`), which is a deploy concern.

## License

Application code; see the framework repositories for their licenses.
