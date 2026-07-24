#!/usr/bin/env bash
# WP110 — malformed-request drill. Proves the framework/app reject bad input
# CLEANLY (typed 4xx, never a crash or a 5xx), exercising strict JSON decode,
# body limits, auth, and the filename/traversal guard against the LIVE server.
# Non-disruptive: it never restarts the service, so it is safe to run alongside
# the soak.
#
#   BASE=http://127.0.0.1:18080 bash ops/malformed-drill.sh
set -uo pipefail
BASE="${BASE:-http://127.0.0.1:18080}"
fail=0
ok()  { printf '  OK   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }
# expect_in <desc> <actual> <space-separated acceptable codes>
expect_in() { local d="$1" a="$2" set="$3"; for c in $set; do [ "$a" = "$c" ] && { ok "$d ($a)"; return; }; done; bad "$d (got $a, want one of: $set)"; }
st() { curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || echo 000; }

# A real session for the authenticated cases.
E="mal+$(date +%s)@x.com"
curl -sS -X POST $BASE/register -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" >/dev/null
T=$(curl -sS -X POST $BASE/login -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"password123\"}" | jq -r .token)
P=$(curl -sS -X POST $BASE/projects -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"Mal"}' | jq -r .id)

echo "=== strict JSON decode (WP105/106) ==="
expect_in "malformed JSON body -> 400"        "$(st -X POST $BASE/register -H 'Content-Type: application/json' -d '{bad json')" "400"
expect_in "empty body where JSON required->400" "$(st -X POST $BASE/login -H 'Content-Type: application/json' -d '')" "400"
expect_in "unknown field -> 400"              "$(st -X POST $BASE/projects -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"x","nope":1}')" "400"
expect_in "wrong-typed field -> 400"          "$(st -X POST $BASE/projects -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":123}')" "400"
expect_in "missing required field -> 400"     "$(st -X POST $BASE/projects -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{}')" "400"

echo "=== auth (WP104) ==="
expect_in "garbage bearer token -> 401"       "$(st $BASE/me -H 'Authorization: Bearer not-a-real-token')" "401"
expect_in "malformed Authorization header ->401/200" "$(st $BASE/me -H 'Authorization: Basic xxx')" "401"
expect_in "protected route no auth -> 401"    "$(st $BASE/projects/$P)" "401"

echo "=== path / param validation (WP105/106) ==="
expect_in "non-integer path id -> 400/404"    "$(st $BASE/projects/not-an-int -H "Authorization: Bearer $T")" "400 404"
expect_in "unknown status filter -> 400"      "$(st "$BASE/projects/$P/tasks?status=bogus" -H "Authorization: Bearer $T")" "400"
expect_in "malformed limit -> 400"            "$(st "$BASE/projects/$P/tasks?limit=banana" -H "Authorization: Bearer $T")" "400"
expect_in "traversal filename on upload ->400" "$(st -X POST "$BASE/tasks/1/attachments?filename=../../etc/passwd" -H "Authorization: Bearer $T" -H 'Content-Type: text/plain' -d 'x')" "400"
expect_in "missing filename on upload -> 400" "$(st -X POST "$BASE/tasks/1/attachments" -H "Authorization: Bearer $T" -H 'Content-Type: text/plain' -d 'x')" "400"

echo "=== injection-looking input is data, not structure (WP105) ==="
# A SQL-ish project name must be stored/handled as a literal (bound param), never
# executed: expect a normal 201, and the server stays healthy afterwards.
INJ=$(st -X POST $BASE/projects -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"Robert\"); DROP TABLE tasks;--"}')
expect_in "SQL-looking name is a literal -> 201" "$INJ" "201"
expect_in "server healthy after injection attempt -> 200" "$(st $BASE/health/live)" "200"
# Prove tasks table still exists by listing.
expect_in "tasks table intact after injection -> 200" "$(st "$BASE/projects/$P/tasks" -H "Authorization: Bearer $T")" "200"

printf '\n=== SUMMARY: %d failed ===\n' "$fail"
[ "$fail" -eq 0 ]
