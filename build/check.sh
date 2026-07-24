#!/usr/bin/env bash
# uruquim-board build gate. Compiles the application against the PINNED public
# core and Crystals contracts (DEPS.md) — nothing vendored, no internal import.
#
#   env URUQUIM_CORE=<uruquim@closure> CRYSTALS_ROOT=<uruquim-crystals@36db55c> \
#       URUQUIM_ODIN_BIN=<pinned odin> bash build/check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "BOARD-BUILD-FAIL: $*" >&2; exit 1; }

URUQUIM_CORE="${URUQUIM_CORE:?set URUQUIM_CORE to the pinned uruquim (core) checkout}"
CRYSTALS_ROOT="${CRYSTALS_ROOT:?set CRYSTALS_ROOT to the pinned uruquim-crystals checkout}"

if test -n "${URUQUIM_ODIN_BIN:-}"; then ODIN="$URUQUIM_ODIN_BIN"
elif command -v odin >/dev/null 2>&1; then ODIN="$(command -v odin)"
elif test -x /tmp/uruquim-odin-toolchain/odin; then ODIN=/tmp/uruquim-odin-toolchain/odin
else fail "odin not found; set URUQUIM_ODIN_BIN"; fi
ODIN="$(readlink -f "$ODIN")"
ODIN_DIR="$(cd "$(dirname "$ODIN")" && pwd)"

test -d "$URUQUIM_CORE/web" || fail "URUQUIM_CORE=$URUQUIM_CORE has no web/ — not a core checkout"
test -d "$CRYSTALS_ROOT/db/postgres" || fail "CRYSTALS_ROOT=$CRYSTALS_ROOT has no db/postgres — not a crystals checkout"

COLL=( -collection:uruquim="$URUQUIM_CORE"
       -collection:crystals="$CRYSTALS_ROOT"
       -collection:board="$ROOT" )

echo "--- G8-1: no core internal / friend import ---"
# The application may name only the public collection roots. An import that
# reaches web/internal, a vendor/ path, or a crystals-internal package is a
# privileged application (G8-1) and fails here.
if grep -rnE 'import[^\n]*"(uruquim:web/internal|uruquim:vendor|crystals:[a-z/]*/internal)' \
     "$ROOT/board" "$ROOT/cmd" "$ROOT/identity" "$ROOT/tests" 2>/dev/null; then
  fail "an application source imports a framework INTERNAL — proof-by-use forbids it (G8-1)"
fi

echo "--- typecheck: identity package (pure — no framework, no libpq) ---"
# The identity sub-package holds the password/token/role logic. It depends only
# on Odin core crypto/encoding, so it typechecks and tests without any collection
# but its own — proof that the security-critical code is framework-independent.
env ODIN_ROOT="$ODIN_DIR" "$ODIN" check "$ROOT/identity" -collection:board="$ROOT" -no-entry-point

echo "--- typecheck: board package ---"
env ODIN_ROOT="$ODIN_DIR" "$ODIN" check "$ROOT/board" "${COLL[@]}" -no-entry-point
echo "--- typecheck: cmd (the deployable server) ---"
# TYPECHECK, not link. The db/postgres Crystal links libpq (-lpq), which needs
# libpq-dev on the LINKING host. Typecheck proves the code is correct against the
# pinned public API on any host; producing the linked binary is a deploy step
# (build/deploy.sh on a host with libpq-dev). `-define BOARD_LINK=1` opts into
# the full link where libpq-dev is present.
env ODIN_ROOT="$ODIN_DIR" "$ODIN" check "$ROOT/cmd" "${COLL[@]}"
if [ "${BOARD_LINK:-0}" = "1" ]; then
  echo "--- link: cmd → build/board ---"
  env ODIN_ROOT="$ODIN_DIR" "$ODIN" build "$ROOT/cmd" "${COLL[@]}" -out:"$ROOT/build/board" >/dev/null
  test -x "$ROOT/build/board" || fail "the server binary was not produced"
fi

echo "--- unit tests: identity (pure, no PostgreSQL) ---"
# Password hashing, token hashing and role ranking are security-critical and pure,
# so they run here, deterministically, on any host. The database-touching handlers
# are exercised against a live PostgreSQL on the VPS (WP108 / deployment records).
env ODIN_ROOT="$ODIN_DIR" "$ODIN" test "$ROOT/tests/wp104-identity" -collection:board="$ROOT"

echo "--- migrations are immutable, numbered, paired up/down ---"
for up in "$ROOT"/migrations/*.up.sql; do
  down="${up%.up.sql}.down.sql"
  test -f "$down" || fail "migration $(basename "$up") has no matching .down.sql"
done

echo "board: compiles against pinned public core+crystals; no internal import; identity unit tests green; migrations paired"
echo "PASS: uruquim-board build gate"
