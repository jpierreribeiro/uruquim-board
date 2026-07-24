#!/usr/bin/env bash
# WP110/WP102 soak — a sustained gentle run that watches for leaks and drift.
# Start it DETACHED on the VPS so it survives an SSH disconnect:
#
#   SOAK_SECONDS=14400 BASE=http://127.0.0.1:18080 \
#     nohup bash ops/soak.sh > /opt/uruquim-verify/soak.log 2>&1 &
#
# Pass criteria (WP102 §8): no monotonic RSS growth beyond the C-04 threshold,
# and every counter returns to baseline after the load stops. The load is
# deliberately light (one cycle every INTERVAL seconds) so a 1.6 GiB box is never
# stressed — this is a stability/leak soak, not a load test.
#
# NOTE on session-expiry: the app's SESSION_TTL is 24 h, so a 4 h soak does NOT
# cross a session-expiry boundary. Crossing it inside the soak needs a shortened
# TTL (a parameter decision) — flagged, not faked. This soak re-logs-in every
# cycle so session CHURN (mint + resolve + let lapse) happens regardless.
set -uo pipefail
BASE="${BASE:-http://127.0.0.1:18080}"
SECS="${SOAK_SECONDS:-14400}"      # default 4 hours
INTERVAL="${SOAK_INTERVAL:-5}"
SVC=uruquim-board.service

rss() { local p; p=$(systemctl show -p MainPID --value $SVC); [ -n "$p" ] && [ "$p" != 0 ] && awk '/VmRSS/{print $2}' /proc/$p/status 2>/dev/null || echo 0; }
now() { date +%s; }

start=$(now); end=$((start + SECS))
rss0=$(rss)
echo "soak start: $(date -u) rss0=${rss0}kB duration=${SECS}s interval=${INTERVAL}s"
cycle=0; errors=0; last_log=$start

# Register one durable account/project for the whole soak.
E="soak+$(now)@x.com"
curl -sS -X POST $BASE/register -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" >/dev/null
PID_PROJ=""

while [ "$(now)" -lt "$end" ]; do
  cycle=$((cycle+1))
  # Re-login each cycle: mints a session (churns the sessions table).
  T=$(curl -sS --max-time 5 -X POST $BASE/login -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" | jq -r .token 2>/dev/null)
  if [ -z "$T" ] || [ "$T" = null ]; then errors=$((errors+1)); sleep "$INTERVAL"; continue; fi
  if [ -z "$PID_PROJ" ]; then
    PID_PROJ=$(curl -sS --max-time 5 -X POST $BASE/projects -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"Soak"}' | jq -r .id 2>/dev/null)
  fi
  # A representative mix: readiness, a write, a read, a patch, the admin view.
  curl -sS -o /dev/null --max-time 5 "$BASE/ready"
  TK=$(curl -sS --max-time 5 -X POST $BASE/projects/$PID_PROJ/tasks -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "{\"title\":\"soak $cycle\"}" | jq -r .id 2>/dev/null)
  curl -sS -o /dev/null --max-time 5 "$BASE/projects/$PID_PROJ/tasks?limit=10" -H "Authorization: Bearer $T"
  [ -n "$TK" ] && [ "$TK" != null ] && curl -sS -o /dev/null --max-time 5 -X POST "$BASE/tasks/$TK/comments" -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"body":"soak comment"}'
  curl -sS -o /dev/null --max-time 5 "$BASE/admin/stats" -H "Authorization: Bearer $T"

  # Sample RSS + pool once a minute.
  if [ $(( $(now) - last_log )) -ge 60 ]; then
    last_log=$(now)
    STATS=$(curl -sS --max-time 5 "$BASE/admin/stats" -H "Authorization: Bearer $T")
    POOL=$(printf '%s' "$STATS" | jq -c '{pool_open,pool_idle,pool_in_use,pool_waiters,responses_sent}' 2>/dev/null)
    printf 'soak t=%ds cycle=%d rss=%skB errors=%d pool=%s\n' "$(( $(now) - start ))" "$cycle" "$(rss)" "$errors" "$POOL"
  fi
  sleep "$INTERVAL"
done

# Cool-down: let in-flight work settle, then read final RSS/counters.
sleep 10
rss1=$(rss)
echo "soak end: $(date -u) cycles=$cycle errors=$errors rss0=${rss0}kB rss1=${rss1}kB"
growth=$(( rss1 - rss0 ))
echo "rss growth over soak: ${growth}kB"
# Heuristic pass: RSS did not grow by more than 64 MiB (leak guard; C-04 sizing
# is per-connection response retention, not steady-state growth).
if [ "$growth" -lt 65536 ]; then echo "SOAK PASS: no runaway RSS growth (${growth}kB < 64MiB)"; else echo "SOAK FAIL: RSS grew ${growth}kB"; fi
echo "note: session-expiry boundary NOT crossed (24h TTL vs ${SECS}s soak) — needs a shortened TTL to exercise; connection churn and leak-watch DID run."
