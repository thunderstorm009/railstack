#!/usr/bin/env bash
#
# E7 — data persistence across a named volume.
#
# Hypothesis:
#   A named volume survives `docker compose down` and `up` — the Redis counter
#   keeps its value. It does NOT survive `docker compose down -v`, because the
#   `-v` flag removes the volumes as well.
#
#   The same volume also survives a container being recreated, because the
#   volume is attached by name, not by container.
#
set -euo pipefail

COMPOSE="${COMPOSE:-docker compose}"

count() {
  curl -s --max-time 5 http://localhost:8080/api/count || echo '{"error":"unreachable"}'
}

redis_key() {
  $COMPOSE exec -T cache redis-cli GET reli:count 2>/dev/null || echo "(unavailable)"
}

echo "### the volume we are testing"
docker volume ls --filter "name=relistack" --format '{{.Name}}'

echo
echo "### 1) set a known value"
for i in 1 2 3; do count >/dev/null; done
echo "  /api/count -> $(count)"
echo "  redis key   -> $(redis_key)"

echo
echo "### 2) docker compose down  (containers removed, volumes KEPT)"
$COMPOSE down
echo "  volume still present? $(docker volume ls --filter 'name=relistack-redis-data' --format '{{.Name}}')"

echo
echo "### 3) docker compose up   (containers recreated, volume reattached)"
$COMPOSE up -d >/dev/null 2>&1
sleep 12
echo "  /api/count -> $(count)"
echo "  redis key   -> $(redis_key)"

echo
echo "### 4) docker compose down -v   (volumes REMOVED too)"
$COMPOSE down -v
echo "  volume still present? [$(docker volume ls --filter 'name=relistack-redis-data' --format '{{.Name}}')]"

echo
echo "### 5) docker compose up again (a brand new, empty volume)"
$COMPOSE up -d >/dev/null 2>&1
sleep 12
echo "  /api/count -> $(count)"
echo "  redis key   -> $(redis_key)"
echo
echo ">>> The counter restarted from 1: the old volume was destroyed by -v."
