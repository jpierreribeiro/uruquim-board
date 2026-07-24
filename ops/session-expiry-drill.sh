#!/usr/bin/env bash
# Session-expiry drill — the boundary the 4h soak could not cross (24h TTL). Rather
# than rebuild the product with a short TTL, it exercises expiry directly: mint a
# real session, use it (200), then age its row past now() in the DB and confirm the
# server rejects it (401) — because require_session checks `expires_at > now()` in
# SQL, the DB clock is authoritative. Also confirms revocation. Live, deterministic,
# no big box.
#
#   BASE=http://127.0.0.1:18080 bash ops/session-expiry-drill.sh
set -uo pipefail
BASE="${BASE:-http://127.0.0.1:18080}"
PGC=uruquim-board-pg
psqldo() { docker exec "$PGC" psql -U board -d board -tAc "$1"; }
fail=0
ok()  { printf '  OK   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }
st()  { curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || echo 000; }

E="expiry+$(date +%s)@x.com"
curl -sS -X POST $BASE/register -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" >/dev/null
T=$(curl -sS -X POST $BASE/login -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" | jq -r .token)
[ -n "$T" ] && [ "$T" != null ] || { echo "login failed"; exit 1; }

echo "=== a fresh session is accepted ==="
C1=$(st "$BASE/me" -H "Authorization: Bearer $T")
if [ "$C1" = 200 ]; then ok "fresh session -> 200"; else bad "fresh session -> $C1 (expected 200)"; fi

echo "=== age the session past now() in the DB (simulate TTL expiry) ==="
# The account's most recent session row -> set expires_at into the past.
AID=$(psqldo "SELECT id FROM accounts WHERE email='$E'")
psqldo "UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE account_id=$AID" >/dev/null
C2=$(st "$BASE/me" -H "Authorization: Bearer $T")
if [ "$C2" = 401 ]; then ok "EXPIRED session -> 401 (expires_at > now() enforced in SQL, DB clock authoritative)"; else bad "expired session -> $C2 (expected 401)"; fi

echo "=== a NEW login after expiry works (mint + use a fresh session) ==="
T2=$(curl -sS -X POST $BASE/login -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" | jq -r .token)
C3=$(st "$BASE/me" -H "Authorization: Bearer $T2")
if [ "$C3" = 200 ]; then ok "re-login after expiry -> 200 (session churn works across the boundary)"; else bad "re-login -> $C3 (expected 200)"; fi

echo "=== explicit revocation is honored live ==="
st -X POST "$BASE/logout" -H "Authorization: Bearer $T2" >/dev/null
C4=$(st "$BASE/me" -H "Authorization: Bearer $T2")
if [ "$C4" = 401 ]; then ok "revoked (logout) session -> 401"; else bad "revoked session -> $C4 (expected 401)"; fi

printf '\n=== SUMMARY: %d failed ===\n' "$fail"
[ "$fail" -eq 0 ]
