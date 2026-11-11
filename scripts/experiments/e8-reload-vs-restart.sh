#!/usr/bin/env bash
#
# E8 — graceful reload vs hard restart of the proxy.
#
# Hypothesis:
#   `nginx -s reload` sends SIGHUP to the master process. The master keeps
#   accepting connections and replaces its workers one by one, so clients see
#   ZERO failed requests.
#
#   `docker compose restart web` destroys and recreates the container. During
#   that window the port is closed, so a client sees connection-refused
#   errors (curl exit code 7, HTTP 000).
#
# We measure both by hammering the proxy with requests in the background and
# counting failures.
#
set -euo pipefail

COMPOSE="${COMPOSE:-docker compose}"

# Runs curl in a loop for N seconds, counting failures. Writes the count to a
# file. A failure is either a non-200 status or a connection error.
hammer() {
  local seconds="$1" outfile="$2"
  local end=$((SECONDS + seconds))
  local total=0 failed=0
  while [ $SECONDS -lt $end ]; do
    total=$((total + 1))
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://localhost:8080/api/hello 2>/dev/null || echo 000)"
    if [ "$code" != "200" ]; then
      failed=$((failed + 1))
    fi
  done
  echo "$total $failed" > "$outfile"
}

echo "############################################################"
echo "# A) graceful reload: docker compose exec web nginx -s reload"
echo "############################################################"
hammer 12 /tmp/e8-reload.txt &
HAMMER_PID=$!
sleep 3
echo "sending SIGHUP to the nginx master..."
$COMPOSE exec -T web nginx -s reload
wait $HAMMER_PID || true
read -r reload_total reload_failed < /tmp/e8-reload.txt
echo "requests: $reload_total   failed: $reload_failed"

echo
echo "############################################################"
echo "# B) hard restart: docker compose restart web"
echo "############################################################"
hammer 12 /tmp/e8-restart.txt &
HAMMER_PID=$!
sleep 3
echo "restarting the container..."
$COMPOSE restart web
wait $HAMMER_PID || true
read -r restart_total restart_failed < /tmp/e8-restart.txt
echo "requests: $restart_total   failed: $restart_failed"

echo
echo "############################################################"
echo "# summary"
echo "############################################################"
echo "reload   : $reload_failed failed out of $reload_total"
echo "restart  : $restart_failed failed out of $restart_total"
echo
if [ "$reload_failed" -eq 0 ] && [ "$restart_failed" -gt 0 ]; then
  echo ">>> zero-downtime confirmed: the reload was invisible to clients,"
  echo ">>> while the hard restart dropped $restart_failed requests."
elif [ "$reload_failed" -eq 0 ]; then
  echo ">>> the reload was invisible to clients."
else
  echo ">>> reload dropped $reload_failed requests, restart dropped $restart_failed."
fi

rm -f /tmp/e8-reload.txt /tmp/e8-restart.txt
$COMPOSE up -d >/dev/null 2>&1 || true
sleep 8
