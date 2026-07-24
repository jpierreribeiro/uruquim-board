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

**WP104 delivered** (planning/phase-8-plan.md in the core repo).

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
