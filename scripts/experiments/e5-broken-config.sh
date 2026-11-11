#!/usr/bin/env bash
#
# E5 — a broken NGINX configuration.
#
# Hypothesis:
#   With the fail-fast entrypoint, a syntactically invalid nginx.conf makes the
#   container exit immediately, printing the `nginx: [emerg] ...` error. Without
#   the `nginx -t` guard the failure would be less obvious and, under a restart
#   policy, would turn into an endless crash loop.
#
#   We also show the difference between a CONFIG error and a CODE error:
#     - config error -> the container never serves a single request
#     - code error   -> the container serves traffic and then breaks
#
set -euo pipefail

COMPOSE="${COMPOSE:-docker compose}"
WEB="relistack-web"
INSPECT='status={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}'

echo "### baseline"
docker inspect --format "$INSPECT" "$WEB"
curl -s -o /dev/null -w "proxy /healthz -> HTTP %{http_code}\n" http://localhost:8080/healthz

echo
echo "### breaking nginx.conf inside the container"
$COMPOSE exec -T web sh -c '
  cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
  printf "\nthis_is_not_a_valid_directive;\n" >> /etc/nginx/nginx.conf
  echo "--- tail of the broken config ---"
  tail -3 /etc/nginx/nginx.conf
'

echo
echo "### restarting the proxy so it re-reads the file"
$COMPOSE restart web || true

echo
echo "### container logs (the [emerg] line is the real error)"
$COMPOSE logs --tail=15 web --no-log-prefix 2>&1 | grep -E "emerg|validating|configuration OK" || true

echo
echo "### container state"
sleep 3
docker inspect --format "$INSPECT" "$WEB"
curl -s -o /dev/null -w "proxy /healthz -> HTTP %{http_code}\n" --max-time 5 http://localhost:8080/healthz

echo
echo "### what nginx itself says about the config"
docker run --rm --entrypoint sh \
  -v relistack-relinet-web:/tmp/nothing 2>/dev/null || true
docker cp "$WEB:/etc/nginx/nginx.conf" /tmp/relistack-broken-nginx.conf 2>/dev/null \
  && echo "(copied the broken config out for inspection)" || true

echo
echo "### restoring the config and bringing the proxy back"
$COMPOSE exec -T web sh -c 'if [ -f /etc/nginx/nginx.conf.bak ]; then mv /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf; echo restored; fi' 2>/dev/null || true
$COMPOSE up -d --force-recreate web 2>&1 | tail -3
sleep 10
docker inspect --format "$INSPECT" "$WEB"
curl -s -o /dev/null -w "proxy /healthz -> HTTP %{http_code}\n" http://localhost:8080/healthz
