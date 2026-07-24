# Pinned dependencies

`uruquim-board` is the Phase-8 proof-by-use application. It depends **only on
pinned public contracts** — no friend import, no core internal, no build flag
that a normal consumer could not set (Phase-8 exit gate G8-1). Every dependency
is a **fixed commit SHA**, never a branch-relative reference (E8-3).

**Pinned to the RELEASE SHAs on `main` — the controlled-pilot release** (the
Corrective Program C1–C7 + C5, merged to `main`/`master` 2026-07-24). The board's
own `master` is the release line; these are fixed commit SHAs on `main`.

| Collection | Repository | Pin | Notes |
|---|---|---|---|
| `uruquim` (→ `web`) | `jpierreribeiro/uruquim` | `main` `693d378c` (Closure + Hardening + **corrective C1–C7**; public ledger 80+2=82) | merged from `phase8`; the pilot release SHA |
| `crystals` | `jpierreribeiro/uruquim-crystals` | `main` `2176357f` (`36db55c` + **C5** `arg_timestamptz`/`rfc3339` + `tcp_user_timeout_ms`) | merged from `corrective` |
| toolchain | Odin | `dev-2026-07a` / `819fdc7` | see `odin-version.txt` |

**Corrective APIs this branch now uses** (workarounds dropped): named `web.Status`
members (`.Service_Unavailable`/`.Conflict`/`.Payload_Too_Large`, C1);
`web.query_int_opt` for the optional `assignee` filter (C3); `pg.arg_timestamptz`
+ `validate.rfc3339` for `due_date` (C5); `web.bytes` + `web.set_header` for the
new authenticated attachment **download** with `Content-Disposition` (C2, F8-4).
Bearer sessions remain (cookies are now *possible* via `set_header` but not
adopted). No `Expect:`-stripping needed for large uploads (C6).

## Building

The build points the collections at LOCAL checkouts pinned to the SHAs above:

```
env URUQUIM_CORE=<path to uruquim@closure> \
    CRYSTALS_ROOT=<path to uruquim-crystals@36db55c> \
    URUQUIM_ODIN_BIN=<path to pinned odin> \
    bash build/check.sh
```

No dependency is vendored into this repository. The pins move only through a
recorded upgrade step (WP111).
