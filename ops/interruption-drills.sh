#!/usr/bin/env bash
# WP110 deferred drills — network interruption + upload interruption. Run on the
# VPS AFTER the soak (they perturb connections, so they waited). Root: iptables +
# docker. Only against the isolated board stack.
#
#   BASE=http://127.0.0.1:18080 bash ops/interruption-drills.sh
set -uo pipefail
BASE="${BASE:-http://127.0.0.1:18080}"
PGC=uruquim-board-pg
PGPORT=55432
fail=0
hdr()  { printf '\n########## %s ##########\n' "$*"; }
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }
code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 4 "$@" 2>/dev/null || echo 000; }

# A committed task whose survival we assert across the interruptions.
E="intr+$(date +%s)@x.com"
curl -sS -X POST $BASE/register -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" >/dev/null
T=$(curl -sS -X POST $BASE/login -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" | jq -r .token)
P=$(curl -sS -X POST $BASE/projects -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"Interrupt"}' | jq -r .id)
TID=$(curl -sS -X POST $BASE/projects/$P/tasks -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"title":"durable"}' | jq -r .id)
echo "setup: project=$P task=$TID"

# =====================================================================
hdr "DRILL — NETWORK INTERRUPTION: block the DB port, then restore"
# expected: while the DB is unreachable, /health/live stays 200 and /ready is a
# bounded 503 (never a hang); after restore, /ready returns to 200. Committed
# data survives.
echo "  blocking 127.0.0.1:$PGPORT with iptables (OUTPUT REJECT)..."
iptables -I OUTPUT -p tcp -d 127.0.0.1 --dport $PGPORT -j REJECT
sleep 2
LIVE=$(code "$BASE/health/live"); READY=$(code "$BASE/ready")
echo "  during block: /health/live=$LIVE /ready=$READY"
if [ "$LIVE" = 200 ]; then ok "liveness stayed 200 during the network cut"; else bad "liveness degraded ($LIVE)"; fi
if [ "$READY" = 503 ]; then ok "readiness was a bounded 503 (never hung)"; else bad "readiness was $READY (expected a bounded 503)"; fi
echo "  restoring the DB port..."
iptables -D OUTPUT -p tcp -d 127.0.0.1 --dport $PGPORT -j REJECT
recovered=0
for i in $(seq 1 20); do sleep 1; if [ "$(code "$BASE/ready")" = 200 ]; then recovered=1; break; fi; done
if [ "$recovered" = 1 ]; then ok "readiness recovered to 200 after the network was restored"; else bad "readiness did not recover"; fi
SURV=$(curl -sS "$BASE/tasks/$TID" -H "Authorization: Bearer $T" | jq -r .id 2>/dev/null)
if [ "$SURV" = "$TID" ]; then ok "INVARIANT: committed task survived the network interruption"; else bad "task lost (got '$SURV')"; fi

# =====================================================================
hdr "DRILL — UPLOAD INTERRUPTION: abort a large upload mid-body"
# expected: a client that declares a large Content-Length but aborts partway does
# NOT desynchronize the server or leak a partial attachment; the server stays
# healthy and serves the next request.
dd if=/dev/urandom of=/tmp/big_intr.bin bs=1M count=8 2>/dev/null
echo "  starting an 8 MiB upload and killing curl after 0.3s..."
# --limit-rate makes the body take long enough to abort mid-stream.
timeout 0.3 curl -sS -X POST "$BASE/tasks/$TID/attachments?filename=partial.bin" \
  -H "Authorization: Bearer $T" -H "Content-Type: application/octet-stream" \
  --limit-rate 2M --data-binary @/tmp/big_intr.bin >/dev/null 2>&1
echo "  upload aborted (curl killed mid-body)."
sleep 1
# The server must still be healthy and serve a normal request.
H=$(code "$BASE/health/live"); L=$(code "$BASE/projects/$P/tasks" -H "Authorization: Bearer $T")
if [ "$H" = 200 ]; then ok "server healthy after the aborted upload"; else bad "server unhealthy ($H)"; fi
if [ "$L" = 200 ]; then ok "next request served normally (no desync)"; else bad "next request failed ($L)"; fi
# A normal upload still works after the interruption.
GOOD=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/tasks/$TID/attachments?filename=ok.txt" \
  -H "Authorization: Bearer $T" -H "Content-Type: text/plain" --data-binary "recovered")
if [ "$GOOD" = 201 ]; then ok "a normal upload succeeds after the interruption"; else bad "post-interruption upload failed ($GOOD)"; fi
rm -f /tmp/big_intr.bin

printf '\n########## SUMMARY: %d failed ##########\n' "$fail"
[ "$fail" -eq 0 ]
