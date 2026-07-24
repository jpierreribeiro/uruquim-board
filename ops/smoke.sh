#!/usr/bin/env bash
# Smoke-test the uruquim-board WP104–109 surface against a running server.
# Exercises the happy paths plus the optimistic-conflict 409, and checks the
# observability endpoints. Run on the VPS after deployment #2 (see
# ops/deploy-runbook.md). Requires: curl, jq.
#
#   BASE=http://127.0.0.1:18080 bash ops/smoke.sh
set -uo pipefail

BASE="${BASE:-http://127.0.0.1:18080}"
EMAIL="smoke+$(date +%s)@example.com"
PASS="smoke-password-123"
pass=0 fail=0

say()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  OK   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }

# expect <description> <actual-status> <expected-status>
expect() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (got $2, want $3)"; fi; }

# code_of does a request and prints the HTTP status; body goes to $BODY.
BODY=""
req() { # req METHOD PATH [DATA] [AUTH] [EXTRA_HEADER]
  local m="$1" p="$2" data="${3:-}" auth="${4:-}" xh="${5:-}"
  local args=(-sS -o /tmp/smoke_body -w '%{http_code}' -X "$m" "$BASE$p")
  [ -n "$auth" ] && args+=(-H "Authorization: Bearer $auth")
  [ -n "$xh" ]   && args+=(-H "$xh")
  [ -n "$data" ] && args+=(-H "Content-Type: application/json" -d "$data")
  local code; code="$(curl "${args[@]}")"; BODY="$(cat /tmp/smoke_body)"; echo "$code"
}

say "liveness / readiness"
expect "GET /health/live" "$(req GET /health/live)" 200
expect "GET /ready"       "$(req GET /ready)"       200

say "register + login (WP104)"
expect "POST /register" "$(req POST /register "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}")" 201
code="$(req POST /login "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}")"
expect "POST /login" "$code" 201
TOKEN="$(printf '%s' "$BODY" | jq -r '.token')"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && ok "got session token" || bad "no session token"
expect "POST /login (wrong password)" "$(req POST /login "{\"email\":\"$EMAIL\",\"password\":\"nope\"}")" 401
expect "GET /me (no token)" "$(req GET /me)" 401
expect "GET /me (token)"    "$(req GET /me '' "$TOKEN")" 200

say "projects + RBAC (WP104)"
code="$(req POST /projects '{"name":"Smoke Project"}' "$TOKEN")"
expect "POST /projects" "$code" 201
PID="$(printf '%s' "$BODY" | jq -r '.id')"
expect "GET /projects/:id" "$(req GET "/projects/$PID" '' "$TOKEN")" 200

say "tasks + optimistic conflict (WP105)"
code="$(req POST "/projects/$PID/tasks" '{"title":"first task"}' "$TOKEN")"
expect "POST tasks" "$code" 201
TID="$(printf '%s' "$BODY" | jq -r '.id')"
VER="$(printf '%s' "$BODY" | jq -r '.version')"
expect "PATCH task (correct version)" "$(req PATCH "/tasks/$TID" "{\"version\":$VER,\"status\":\"in_progress\"}" "$TOKEN")" 200
expect "PATCH task (stale version -> 409)" "$(req PATCH "/tasks/$TID" "{\"version\":$VER,\"title\":\"racing\"}" "$TOKEN")" 409
expect "POST comment" "$(req POST "/tasks/$TID/comments" '{"body":"a comment"}' "$TOKEN")" 201

say "pagination + filters (WP106)"
expect "GET tasks (limit=1)" "$(req GET "/projects/$PID/tasks?limit=1" '' "$TOKEN")" 200
expect "GET tasks (filter status)" "$(req GET "/projects/$PID/tasks?status=in_progress" '' "$TOKEN")" 200

say "attachments (WP106; buffered path — a >4MiB file for spool is a manual step)"
code="$(req POST "/tasks/$TID/attachments?filename=note.txt" 'hello attachment' "$TOKEN" 'Content-Type: text/plain')"
expect "POST attachment (buffered)" "$code" 201
AID="$(printf '%s' "$BODY" | jq -r '.id')"
expect "GET attachment metadata" "$(req GET "/attachments/$AID" '' "$TOKEN")" 200
expect "GET task attachments" "$(req GET "/tasks/$TID/attachments" '' "$TOKEN")" 200

say "observability (WP109)"
expect "GET /admin/stats (token)" "$(req GET /admin/stats '' "$TOKEN")" 200
expect "GET /admin/stats (no token)" "$(req GET /admin/stats)" 401
expect "GET /obs/metrics" "$(req GET /obs/metrics)" 200

printf '\n=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
