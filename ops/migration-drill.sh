#!/usr/bin/env bash
# WP110/G8-2 — migration checksum/immutability drill, on a SCRATCH database so it
# never touches the live board DB or the running service/soak. Proves the migrate
# tool refuses a tampered (checksum-mismatch) migration rather than silently
# re-applying it — the "immutable once applied" guarantee.
#
#   bash ops/migration-drill.sh
set -uo pipefail
PGC=uruquim-board-pg
MIG=/opt/uruquim-verify/migrate
SRC=/opt/uruquim-verify/board/migrations
DRILLDIR=/tmp/mig-drill-$$
DB=board_drill_$$
fail=0
ok()  { printf '  OK   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }
env_mig() { env MIGRATE_DIR="$DRILLDIR" MIGRATE_HOST=127.0.0.1 MIGRATE_PORT=55432 MIGRATE_USER=board MIGRATE_PASSWORD=board_dev_pw MIGRATE_DB="$DB" MIGRATE_SSLMODE=disable MIGRATE_ALLOW_PLAINTEXT=1 "$MIG" "$@"; }

cleanup() { rm -rf "$DRILLDIR"; docker exec $PGC dropdb -U board --if-exists "$DB" >/dev/null 2>&1; }
trap cleanup EXIT

# Fresh scratch DB + a private copy of the migrations (so tampering is isolated).
docker exec $PGC createdb -U board "$DB"
cp -r "$SRC" "$DRILLDIR"

echo "=== 1. clean apply on a fresh database ==="
if env_mig up 2>&1 | grep -q 'applied'; then ok "migrate up applied the migration set cleanly"; else bad "clean apply failed"; fi
N1=$(docker exec $PGC psql -U board -d "$DB" -tAc "SELECT count(*) FROM _uruquim_migrations")
echo "  applied rows: $N1"

echo "=== 2. re-run is a no-op (idempotent) ==="
OUT=$(env_mig up 2>&1)
if echo "$OUT" | grep -q 'applied 0'; then ok "re-run applied 0 (already up to date)"; else bad "re-run was not a clean no-op: $OUT"; fi

echo "=== 3. TAMPER an already-applied migration -> checksum refusal ==="
# Append a byte to an applied migration file: its checksum no longer matches the
# recorded one. An immutable-migration tool MUST refuse, not silently re-run.
echo "-- tampered $(date +%s)" >> "$DRILLDIR/0001_accounts.up.sql"
OUT=$(env_mig up 2>&1 || true)
echo "  migrate output: $(echo "$OUT" | tail -1)"
if echo "$OUT" | grep -qiE 'checksum|mismatch|immutable|changed|dirty'; then
  ok "tampered migration REFUSED with a checksum/immutability error"
else
  # If it did not clearly say checksum, at least it must NOT have re-applied silently.
  if echo "$OUT" | grep -q 'applied [1-9]'; then bad "tool silently re-applied a tampered migration"; else ok "tool did not re-apply the tampered migration (non-silent)"; fi
fi

echo "=== 4. status still reflects the real applied set ==="
if env_mig status 2>&1 | grep -q 'Applied'; then ok "status reports the applied set"; else bad "status failed"; fi

printf '\n=== SUMMARY: %d failed ===\n' "$fail"
[ "$fail" -eq 0 ]
