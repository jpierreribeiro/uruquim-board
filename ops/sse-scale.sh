#!/usr/bin/env bash
# Intermediate SSE scale probe — graduated concurrent SSE subscribers against the
# LIVE board, on the current host. Not the owed 3,000-socket round (that needs the
# big box); this finds where THIS host's stream admission falls and gives a real
# capacity data point on the curve, plus proves the SSE wire path at scale live.
#
# Conservative by design: the 1.6 GiB box is known to fall over near ~500 real
# sockets, so we RAMP and stop at the first level that does not fully admit,
# rather than hammering. Each subscriber is a backgrounded curl holding an SSE
# stream open for HOLD seconds; we count how many received the initial 200 head.
#
#   BASE=http://127.0.0.1:18080 bash ops/sse-scale.sh
set -uo pipefail
BASE="${BASE:-http://127.0.0.1:18080}"
HOLD="${HOLD:-6}"
LEVELS="${LEVELS:-50 100 200 300}"

E="sse+$(date +%s)@x.com"
curl -sS -X POST $BASE/register -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" >/dev/null
T=$(curl -sS -X POST $BASE/login -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" | jq -r .token)
P=$(curl -sS -X POST $BASE/projects -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"SSEScale"}' | jq -r .id)
echo "project=$P  hold=${HOLD}s  levels: $LEVELS"
rss() { local p; p=$(systemctl show -p MainPID --value uruquim-board.service 2>/dev/null); [ -n "$p" ] && [ "$p" != 0 ] && awk '/VmRSS/{print $2}' /proc/$p/status 2>/dev/null || echo "?"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; pkill -P $$ curl 2>/dev/null || true' EXIT

for N in $LEVELS; do
  echo ""
  echo "=== level: $N concurrent SSE subscribers ==="
  rm -f "$WORK"/code.*
  # Launch N subscribers. -N = no buffering; --max-time bounds the hold; we write
  # the HTTP code each one got (200 = admitted stream) to a per-sub file.
  for i in $(seq 1 "$N"); do
    ( curl -sN --max-time "$HOLD" -o /dev/null -w '%{http_code}' \
        "$BASE/projects/$P/events" -H "Authorization: Bearer $T" > "$WORK/code.$i" 2>/dev/null ) &
  done
  # Give them ~1.5s to connect, sample health + RSS while they are held open.
  sleep 2
  HLIVE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "$BASE/health/live" 2>/dev/null || echo 000)
  HREADY=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$BASE/ready" -H "Authorization: Bearer $T" 2>/dev/null || echo 000)
  echo "  while $N held: /health/live=$HLIVE /ready=$HREADY rss=$(rss)kB"
  # Wait for the hold to elapse and all subscriber curls to finish.
  wait 2>/dev/null
  admitted=$(grep -l '^200' "$WORK"/code.* 2>/dev/null | wc -l)
  other=$(( N - admitted ))
  echo "  admitted (200): $admitted / $N   (non-200 or dropped: $other)"
  # Recovery check: after they all leave, the server must serve normally again.
  sleep 1
  REC=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$BASE/health/live" 2>/dev/null || echo 000)
  echo "  after release: /health/live=$REC rss=$(rss)kB"
  if [ "$REC" != 200 ]; then echo "  STOP: server did not recover at level $N — not ramping further."; break; fi
  if [ "$admitted" -lt "$N" ]; then echo "  NOTE: admission fell below the offered load at $N — this is the capacity knee on THIS host."; fi
done
echo ""
echo "=== done. The knee (where admitted < offered) is this host's live SSE capacity point. ==="
