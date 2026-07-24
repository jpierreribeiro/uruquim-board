#!/usr/bin/env bash
# WP110 failure/recovery drills, run on the VPS (needs root: systemd + docker).
# Each drill records expected / observed / detection / recovery / the retained-
# data invariant. Runs only against the isolated board deployment; never touches
# the box's CI runner or Caddy.
#
#   BASE=http://127.0.0.1:18080 bash ops/drills.sh
set -uo pipefail
BASE="${BASE:-http://127.0.0.1:18080}"
SVC=uruquim-board.service
PGC=uruquim-board-pg
fail=0
hdr()  { printf '\n########## %s ##########\n' "$*"; }
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }
code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$@" 2>/dev/null || echo 000; }

# --- setup: a committed task whose survival we assert across the drills ---
E="drill+$(date +%s)@x.com"
curl -sS -X POST $BASE/register -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" >/dev/null
T=$(curl -sS -X POST $BASE/login -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" | jq -r .token)
P=$(curl -sS -X POST $BASE/projects -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"Drill"}' | jq -r .id)
TID=$(curl -sS -X POST $BASE/projects/$P/tasks -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"title":"survive me"}' | jq -r .id)
echo "setup: project=$P task=$TID (committed before the drills)"

# =====================================================================
hdr "DRILL 1 — hard process kill (SIGKILL) + supervisor recovery"
# expected: systemd (Restart=always) brings the process back; the committed task
# survives (durability); detection: the pre-kill PID is gone, a new one serves.
PID_BEFORE=$(systemctl show -p MainPID --value $SVC)
echo "  main PID before: $PID_BEFORE"
kill -9 "$PID_BEFORE" 2>/dev/null
echo "  sent SIGKILL; waiting for supervisor restart..."
recovered=0
for i in $(seq 1 15); do
  sleep 1
  c=$(code "$BASE/health/live")
  if [ "$c" = 200 ]; then recovered=1; break; fi
done
PID_AFTER=$(systemctl show -p MainPID --value $SVC)
if [ "$recovered" = 1 ] && [ "$PID_AFTER" != "$PID_BEFORE" ] && [ -n "$PID_AFTER" ]; then
  ok "supervisor restarted the service (new PID $PID_AFTER) and it serves again"
else
  bad "service did not recover after SIGKILL (recovered=$recovered pid_after=$PID_AFTER)"
fi
# invariant: the committed task is still there.
SURV=$(curl -sS "$BASE/tasks/$TID" -H "Authorization: Bearer $T" | jq -r .id 2>/dev/null)
if [ "$SURV" = "$TID" ]; then ok "INVARIANT held: committed task $TID survived the kill"; else bad "committed task lost after kill (got '$SURV')"; fi

# =====================================================================
hdr "DRILL 2 — PostgreSQL restart: liveness stays up, readiness flips, pool recovers"
# expected: during the DB outage /health/live stays 200 (liveness != readiness)
# and /ready returns 503; after PG is back, /ready returns 200 (pool reconnects).
echo "  /health/live before: $(code "$BASE/health/live"), /ready before: $(code "$BASE/ready")"
docker restart $PGC >/dev/null 2>&1 &
# Immediately probe during the restart window.
sleep 1
LIVE_DURING=$(code "$BASE/health/live")
READY_DURING=$(code "$BASE/ready")
echo "  during restart: /health/live=$LIVE_DURING /ready=$READY_DURING"
if [ "$LIVE_DURING" = 200 ]; then ok "liveness stayed 200 while the database was down"; else bad "liveness degraded during DB outage ($LIVE_DURING)"; fi
if [ "$READY_DURING" = 503 ] || [ "$READY_DURING" = 200 ]; then ok "readiness answered a bounded status ($READY_DURING), never hung"; else bad "readiness hung/errored during outage ($READY_DURING)"; fi
wait
# Poll for the pool to recover.
recovered=0
for i in $(seq 1 20); do
  sleep 1
  if [ "$(code "$BASE/ready")" = 200 ]; then recovered=1; break; fi
done
if [ "$recovered" = 1 ]; then ok "readiness returned to 200 — the pool reconnected after PG restart"; else bad "pool did not recover after PG restart"; fi
# invariant: committed data survived the DB restart (it is durable in PG).
SURV=$(curl -sS "$BASE/tasks/$TID" -H "Authorization: Bearer $T" | jq -r .id 2>/dev/null)
if [ "$SURV" = "$TID" ]; then ok "INVARIANT held: task $TID survived the PostgreSQL restart"; else bad "task lost after PG restart (got '$SURV')"; fi

# =====================================================================
hdr "DRILL 3 — graceful supervisor restart (systemctl restart)"
# expected: clean stop within TimeoutStopSec, clean start, serves again.
systemctl restart $SVC
sleep 3
if [ "$(code "$BASE/health/live")" = 200 ]; then ok "service serves after a graceful restart"; else bad "service did not come back after graceful restart"; fi

printf '\n########## SUMMARY: %d failed ##########\n' "$fail"
[ "$fail" -eq 0 ]
