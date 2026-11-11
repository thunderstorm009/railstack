#!/usr/bin/env bash
#
# E1 — stop vs kill: SIGTERM vs SIGKILL.
#
# Hypothesis:
#   `docker compose stop` sends SIGTERM and lets the process shut down cleanly,
#   producing exit code 0 (or 143 if the process is killed by the signal
#   itself). `docker kill` sends SIGKILL, which the process cannot intercept,
#   producing exit code 137 (128 + 9).
#
# While the API is down, the NGINX proxy must return 502 Bad Gateway.
#
set -euo pipefail

COMPOSE="${COMPOSE:-docker compose}"
API="relistack-api"
INSPECT='{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} error={{.State.Error}}'

echo "### baseline"
docker inspect --format "$INSPECT" "$API"
curl -s -o /dev/null -w "proxy /api/hello -> HTTP %{http_code}\n" http://localhost:8080/api/hello

echo
echo "### A) docker compose stop api   (SIGTERM, graceful)"
$COMPOSE stop api
docker inspect --format "$INSPECT" "$API"
curl -s -o /dev/null -w "proxy /api/hello -> HTTP %{http_code}\n" http://localhost:8080/api/hello

echo
echo "### B) docker compose start api  (bring it back)"
$COMPOSE start api
sleep 8
docker inspect --format "$INSPECT" "$API"
curl -s -o /dev/null -w "proxy /api/hello -> HTTP %{http_code}\n" http://localhost:8080/api/hello

echo
echo "### C) docker kill $API   (SIGKILL, forced)"
docker kill "$API"
docker inspect --format "$INSPECT" "$API"
curl -s -o /dev/null -w "proxy /api/hello -> HTTP %{http_code}\n" http://localhost:8080/api/hello

echo
echo "### D) waiting 10s to see whether the restart policy revives it"
sleep 10
docker inspect --format "$INSPECT" "$API"
curl -s -o /dev/null -w "proxy /api/hello -> HTTP %{http_code}\n" http://localhost:8080/api/hello
