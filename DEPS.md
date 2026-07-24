# Pinned dependencies

`uruquim-board` is the Phase-8 proof-by-use application. It depends **only on
pinned public contracts** — no friend import, no core internal, no build flag
that a normal consumer could not set (Phase-8 exit gate G8-1). Every dependency
is a **fixed commit SHA**, never a branch-relative reference (E8-3).

**This branch (`corrective-repin`) pins the CORRECTIVE core + crystals** — the
Corrective Program (C1–C7) that resolved the eight Phase-8 friction findings. It
is the deployment-#5 candidate: `master` keeps the pre-corrective pins until this
is deployed and re-verified live.

| Collection | Repository | Pin | Notes |
|---|---|---|---|
| `uruquim` (→ `web`) | `jpierreribeiro/uruquim` | branch `phase8` HEAD (Closure + Hardening + **corrective C1–C7**; public ledger 80+2=82) | clean release step: merge `phase8` → a release SHA on `main` and re-pin to it |
| `crystals` | `jpierreribeiro/uruquim-crystals` | branch `corrective` HEAD (`36db55c` + **C5**: `arg_timestamptz` + `validate.rfc3339`) | frozen composition + data Crystals, plus the C5 timestamp additions |
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
