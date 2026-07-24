# Pinned dependencies

`uruquim-board` is the Phase-8 proof-by-use application. It depends **only on
pinned public contracts** — no friend import, no core internal, no build flag
that a normal consumer could not set (Phase-8 exit gate G8-1). Every dependency
is a **fixed commit SHA**, never a branch-relative reference (E8-3).

| Collection | Repository | Pin | Notes |
|---|---|---|---|
| `uruquim` (→ `web`) | `jpierreribeiro/uruquim` | branch `closure` HEAD (Closure C-01..C-08 + Hardening H-1..H-5; production-ready, full gate green bar the environmental wp41 flake) | clean release step: merge `closure` → `main` and re-pin to the merge SHA |
| `crystals` | `jpierreribeiro/uruquim-crystals` | `main` `36db55c` | frozen composition + data Crystals: `db/postgres`, `db/migrate`, `web/health`, `web/sse`, `http_client`, `web/metrics`, `validate`, `web/validate` |
| toolchain | Odin | `dev-2026-07a` / `819fdc7` | see `odin-version.txt` |

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
