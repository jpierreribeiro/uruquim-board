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

**WP103 in progress** (planning/phase-8-plan.md in the core repo). Delivered:

- the composition root — a typed `App_State` owning the bounded PostgreSQL pool,
  `application_init`/`destroy`, explicit config from the environment;
- a boring health surface before any domain feature: `/` (up), `/health/live`
  (the health Crystal), and `/ready` (readiness that acquires a pooled
  connection and runs `SELECT 1`, failing fast with 503 while liveness stays up);
- the first migration (`0001_accounts`), applied as a **deploy step** — the
  server never migrates on boot;
- a portable build gate (`build/check.sh`) that typechecks against the pinned
  public core+Crystals and forbids any internal import (G8-1).

## Layout

```
board/        the application package (App_State, config, routes)
cmd/          the deployable server (package main)
migrations/   immutable, numbered up/down SQL — applied by `migrate up` at deploy
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
