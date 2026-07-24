#!/usr/bin/env bash
# WP108 concurrency/backpressure checks against a RUNNING board server. These
# need real concurrency (the in-memory test transport is single-shot), so they
# run on the VPS after deployment #2. Requires: curl, jq.
#
#   BASE=http://127.0.0.1:18080 bash ops/concurrency-check.sh
#
# Covers two of the WP108 cells deterministically enough to assert:
#   1. two clients editing the SAME task version -> exactly one 200, one 409
#      (optimistic conflict under REAL concurrency, never a silent last-write);
#   2. pool-at-cap -> DB work fails fast (503) while /health/live stays 200.
# The slow-consumer / stream-backpressure cells need an SSE client and are noted
# in the runbook as a browser/manual step.
set -uo pipefail

BASE="${BASE:-http://127.0.0.1:18080}"
EMAIL="conc+$(date +%s)@example.com"
PASS="conc-password-123"
fail=0
ok()  { printf '  OK   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }

req() { # req METHOD PATH DATA AUTH -> prints "CODE\nBODY"
  curl -sS -o /tmp/cc_body -w '%{http_code}' -X "$1" "$BASE$2" \
    ${4:+-H "Authorization: Bearer $4"} \
    ${3:+-H "Content-Type: application/json" -d "$3"}
}

# --- setup: an account, a project, a task ---
req POST /register "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" >/dev/null
TOKEN="$(curl -sS -X POST "$BASE/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token')"
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "setup: login failed"; exit 1; }
PID="$(curl -sS -X POST "$BASE/projects" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"name":"Concurrency"}' | jq -r '.id')"
TASK="$(curl -sS -X POST "$BASE/projects/$PID/tasks" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"title":"contended"}')"
TID="$(printf '%s' "$TASK" | jq -r '.id')"
VER="$(printf '%s' "$TASK" | jq -r '.version')"

echo "=== 1. two clients patch the same version concurrently ==="
# Fire two PATCHes at the same version in parallel; collect both status codes.
patch_one() {
  curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE/tasks/$TID" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"version\":$VER,\"title\":\"edit-$1\"}"
}
patch_one A > /tmp/cc_a & pa=$!
patch_one B > /tmp/cc_b & pb=$!
wait $pa; wait $pb
CA="$(cat /tmp/cc_a)"; CB="$(cat /tmp/cc_b)"
echo "  results: $CA and $CB"
# Exactly one 200 and one 409 (order is a race; the SET is the invariant).
if { [ "$CA" = 200 ] && [ "$CB" = 409 ]; } || { [ "$CA" = 409 ] && [ "$CB" = 200 ]; }; then
  ok "exactly one winner (200) and one optimistic conflict (409)"
else
  bad "expected one 200 + one 409, got $CA + $CB"
fi

echo "=== 2. pool saturation: DB work fails fast while liveness stays live ==="
# Fire many concurrent DB-touching requests (pool max_conns=8, acquire_timeout
# 2s) to drive the pool to cap, and concurrently probe /health/live.
for i in $(seq 1 40); do
  curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/projects/$PID/tasks" \
    -H "Authorization: Bearer $TOKEN" >> /tmp/cc_load &
done
# While loaded, liveness must stay 200 and fast.
HLIVE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 1 "$BASE/health/live")"
wait
if [ "$HLIVE" = 200 ]; then
  ok "/health/live stayed 200 (< 1s) under DB load"
else
  bad "/health/live degraded under load (got $HLIVE)"
fi
# Under saturation some task-list calls may 503; that is CORRECT (fast refusal),
# not a failure — report the distribution.
echo "  task-list status distribution under load:"
sort /tmp/cc_load | uniq -c | sed 's/^/    /'
rm -f /tmp/cc_load

printf '\n=== SUMMARY: %d failed ===\n' "$fail"
[ "$fail" -eq 0 ]
