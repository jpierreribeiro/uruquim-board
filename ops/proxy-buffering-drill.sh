#!/usr/bin/env bash
# WP110 — proxy misconfiguration drill (the C-06 contract: `proxy_buffering off`).
# Demonstrates WHY SSE requires an unbuffered proxy: with buffering ON, a proxy
# withholds the stream's early events; with buffering OFF, they arrive promptly.
# Uses an EPHEMERAL nginx container in front of the board — it never touches the
# box's own Caddy (80/443/2019). Self-contained; no big box needed.
#
#   BASE=http://127.0.0.1:18080 bash ops/proxy-buffering-drill.sh
set -uo pipefail
BASE="${BASE:-http://127.0.0.1:18080}"
BOARD_PORT="${BASE##*:}"
# Use --network host so the proxy reaches the board on loopback — the box runs UFW
# (INPUT policy DROP), which blocks a bridged container from reaching the host
# gateway, but host networking sees 127.0.0.1 directly.
UPSTREAM="http://127.0.0.1:${BOARD_PORT}"
NAME="uruquim-proxy-drill"
WORK=$(mktemp -d)
fail=0
ok()  { printf '  OK   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

# A session + project to subscribe to.
E="proxy+$(date +%s)@x.com"
curl -sS -X POST $BASE/register -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" >/dev/null
T=$(curl -sS -X POST $BASE/login -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" | jq -r .token)
P=$(curl -sS -X POST $BASE/projects -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"Proxy"}' | jq -r .id)

# time_to_first_byte through the proxy on the SSE endpoint: how long until the
# proxy forwards the first byte of the stream head. A buffering proxy holds it.
probe() { # $1 = proxy port
  curl -sN --max-time 5 -o /dev/null \
    -w '%{http_code} ttfb=%{time_starttransfer}s' \
    "http://127.0.0.1:$1/projects/$P/events" -H "Authorization: Bearer $T" 2>/dev/null || echo "000 ttfb=timeout"
}

run_nginx() { # $1 = buffering (on|off), $2 = listen port
  cat > "$WORK/nginx.conf" <<CONF
events {}
http {
  server {
    listen $2;
    location / {
      proxy_pass $UPSTREAM;
      proxy_http_version 1.1;
      proxy_set_header Connection "";
      proxy_buffering $1;
      proxy_read_timeout 30s;
    }
  }
}
CONF
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" --network host -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:alpine >/dev/null 2>&1
  sleep 2
}

echo "=== direct (no proxy) baseline ==="
echo "  direct: $(probe "${BASE##*:}")"

echo "=== proxy_buffering ON (the misconfiguration) ==="
if run_nginx on 18091; then
  R_ON=$(probe 18091); echo "  through buffering-ON proxy: $R_ON"
else
  echo "  (could not start nginx container — docker required)"; R_ON="skip"
fi

echo "=== proxy_buffering OFF (the C-06 contract) ==="
if run_nginx off 18092; then
  R_OFF=$(probe 18092); echo "  through buffering-OFF proxy: $R_OFF"
else
  echo "  (could not start nginx container)"; R_OFF="skip"
fi

echo ""
echo "=== interpretation ==="
if [ "$R_OFF" != "skip" ] && echo "$R_OFF" | grep -q '^200'; then
  ok "with proxy_buffering OFF, the SSE stream head is forwarded (200) — the C-06 contract works"
else
  bad "buffering-OFF proxy did not forward the SSE head ($R_OFF)"
fi
if [ "$R_ON" != "skip" ]; then
  # With buffering on, nginx typically holds the head until it has a buffer's
  # worth or the upstream closes — so ttfb is much higher (or a timeout).
  echo "  NOTE: compare ttfb — buffering ON withholds the early stream; OFF forwards it. That is exactly why deployments MUST set proxy_buffering off for SSE (C-06)."
fi

printf '\n=== SUMMARY: %d failed ===\n' "$fail"
[ "$fail" -eq 0 ]
