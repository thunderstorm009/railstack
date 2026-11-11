#!/usr/bin/env bash
#
# E6 — dependency ordering: service_started vs service_healthy.
#
# Hypothesis:
#   `depends_on: cache: {condition: service_started}` only waits for the cache
#   CONTAINER to be created. If Redis is not yet accepting connections, the API
#   starts anyway and the first requests that touch Redis fail.
#
#   `depends_on: cache: {condition: service_healthy}` waits until the cache
#   actually passes its healthcheck, so the API only starts when Redis is
#   genuinely usable.
#
# To make the difference visible we slow Redis down by 8 seconds in both runs.
# The ONLY difference between the two runs is the depends_on condition.
#
set -euo pipefail

COMPOSE="${COMPOSE:-docker compose}"
HERE="$(cd "$(dirname "$0")" && pwd)"

probe_api() {
  # Hit the API's Redis-backed endpoint and report the status code.
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8080/api/count || echo 000)"
  echo "  /api/count -> HTTP $code"
}

echo "############################################################"
echo "# A) condition: service_started   (Redis slow-starts by 8s)"
echo "############################################################"
$COMPOSE down >/dev/null 2>&1 || true
$COMPOSE -f docker-compose.yml -f "$HERE/compose.slow-cache-started.yml" up -d 2>&1 | tail -3
echo
echo "polling the API as soon as the proxy answers:"
for i in $(seq 1 14); do
  printf 't=%02ds  ' "$i"
  probe_api
  sleep 1
done

echo
echo "############################################################"
echo "# B) condition: service_healthy   (Redis slow-starts by 8s)"
echo "############################################################"
$COMPOSE down >/dev/null 2>&1 || true
$COMPOSE -f docker-compose.yml -f "$HERE/compose.slow-cache-healthy.yml" up -d 2>&1 | tail -3
echo
echo "polling the API as soon as the proxy answers:"
for i in $(seq 1 14); do
  printf 't=%02ds  ' "$i"
  probe_api
  sleep 1
done

echo
echo "### restoring the production configuration"
$COMPOSE down >/dev/null 2>&1 || true
$COMPOSE up -d 2>&1 | tail -3
sleep 12
$COMPOSE ps --format '{{.Service}} {{.Health}}'
