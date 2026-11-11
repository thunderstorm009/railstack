#!/usr/bin/env bash
#
# smoke-test.sh — automated assertions for the ReliStack.
#
# What it does  : runs five checks against a running stack and prints PASS/FAIL
#                for each. Exits 0 only if every check passed.
# Why we need it: manual curl calls prove a single request works; this script
#                proves the whole contract (proxy -> API -> Redis) holds, and
#                it is the regression test you re-run after every change.
# How it works  : plain bash with `set -euo pipefail`. Only `curl` and
#                `docker` are required. No test framework, no Python.
#
# Usage:
#   ./scripts/smoke-test.sh              # test the stack on localhost:8080
#   BASE_URL=http://localhost:8080 ./scripts/smoke-test.sh
#
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
COMPOSE="${COMPOSE:-docker compose}"
PROJECT_NAME="${PROJECT_NAME:-relistack}"

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------- helpers ---
green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
bold()  { printf '\033[1m%s\033[0m\n' "$1"; }

pass() { green "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { red   "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

bold "ReliStack smoke test — target: $BASE_URL"
echo

# 1. Proxy liveness.
#    Proves: NGINX is running and serving on the published port.
if body="$(curl -fsS --max-time 5 "$BASE_URL/healthz" 2>&1)"; then
  pass "proxy /healthz returns 200 ($body)"
else
  fail "proxy /healthz failed: $body"
fi

# 2. API reached through the proxy.
#    Proves: the reverse proxy forwards /api/* to the Flask container, and the
#    response carries the container hostname — i.e. we really hit a container.
if body="$(curl -fsS --max-time 5 "$BASE_URL/api/hello" 2>&1)"; then
  if printf '%s' "$body" | grep -q '"container"'; then
    pass "proxy /api/hello returns 200 with container id ($body)"
  else
    fail "proxy /api/hello returned 200 but no container field: $body"
  fi
else
  fail "proxy /api/hello failed: $body"
fi

# 3. Counter increments — proves the API can talk to Redis.
#    Two calls, the second must be exactly one higher than the first.
first="$(curl -fsS --max-time 5 "$BASE_URL/api/count" 2>/dev/null | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
second="$(curl -fsS --max-time 5 "$BASE_URL/api/count" 2>/dev/null | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"

if [ -n "$first" ] && [ -n "$second" ] && [ "$second" -eq "$((first + 1))" ]; then
  pass "api -> redis round trip works (count $first -> $second)"
else
  fail "api -> redis counter did not increment as expected (first='$first' second='$second')"
fi

# 4. Counter persists across requests — proves the value lives in Redis,
#    not in a process-local variable.
third="$(curl -fsS --max-time 5 "$BASE_URL/api/count" 2>/dev/null | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
if [ -n "$third" ] && [ "$third" -eq "$((second + 1))" ]; then
  pass "counter persists across requests (count $second -> $third)"
else
  fail "counter did not persist (second='$second' third='$third')"
fi

# 5. All three services report healthy.
#    Proves: healthchecks are wired up and the dependency ordering held.
if ps_out="$($COMPOSE -p "$PROJECT_NAME" ps --format '{{.Service}} {{.Health}}' 2>&1)"; then
  unhealthy="$(printf '%s\n' "$ps_out" | grep -v -E 'healthy' | grep -E 'cache|api|web' || true)"
  if [ -z "$unhealthy" ]; then
    pass "all services report healthy"
    printf '%s\n' "$ps_out" | sed 's/^/        /'
  else
    fail "some services are not healthy: $unhealthy"
  fi
else
  fail "could not query compose ps: $ps_out"
fi

# --------------------------------------------------------------- summary ---
echo
bold "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
