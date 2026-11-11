#!/usr/bin/env bash
#
# E2c — authoritative restart-policy trace using `docker events`.
#
# E2b showed that `docker kill` from outside does NOT revive a container under
# any policy, while a process that dies on its own IS revived. `docker events`
# is the ground truth: it records every lifecycle event the daemon emits.
#
# Three scenarios, each traced with `docker events`:
#   A) the process exits by itself          -> expect: die + restart
#   B) `docker kill` from outside           -> expect: die + kill (no restart)
#   C) the container is stopped explicitly  -> expect: die + stop (no restart)
#
# It also documents the PID-1 signal rule:
#   `kill -9 1` from INSIDE the container is ignored by the kernel, because
#   PID 1 of a PID namespace only receives signals it has explicitly handled.
#   That is why `docker kill` (which comes from another namespace) can kill
#   it, while an in-container kill cannot.
#
set -euo pipefail

INSPECT='status={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}'

trace() {
  local name="$1"; shift
  local outfile
  outfile="$(mktemp)"
  # `docker events` has no --timeout flag in v29, and macOS has no `timeout`
  # binary, so we background the event stream and stop it by PID.
  docker events --filter "container=$name" --format '{{.Time}} {{.Action}}' > "$outfile" 2>&1 &
  local pid=$!
  sleep 2
  "$@"
  sleep 12
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
  echo "--- docker events ---"
  cat "$outfile"
  rm -f "$outfile"
}

echo "############################################################"
echo "# A) process exits by itself (exit 1), policy=always"
echo "############################################################"
docker rm -f e2c-a >/dev/null 2>&1 || true
docker run -d --name e2c-a --restart always alpine:3.20 sh -c 'exit 1' >/dev/null
trace e2c-a true
echo "final: $(docker inspect --format "$INSPECT" e2c-a)"

echo
echo "############################################################"
echo "# B) docker kill from outside, policy=always"
echo "############################################################"
docker rm -f e2c-b >/dev/null 2>&1 || true
docker run -d --name e2c-b --restart always alpine:3.20 sh -c 'sleep 3600' >/dev/null
sleep 2
trace e2c-b docker kill e2c-b
echo "final: $(docker inspect --format "$INSPECT" e2c-b)"

echo
echo "############################################################"
echo "# C) docker stop from outside, policy=always"
echo "############################################################"
docker rm -f e2c-c >/dev/null 2>&1 || true
docker run -d --name e2c-c --restart always alpine:3.20 sh -c 'sleep 3600' >/dev/null
sleep 2
trace e2c-c docker stop e2c-c
echo "final: $(docker inspect --format "$INSPECT" e2c-c)"

echo
echo "############################################################"
echo "# D) PID-1 signal protection: kill -9 1 from inside"
echo "############################################################"
docker rm -f e2c-d >/dev/null 2>&1 || true
docker run -d --name e2c-d --restart always alpine:3.20 sh -c 'sleep 3600' >/dev/null
sleep 2
echo "PID 1 inside the container:"
docker exec e2c-d sh -c 'ls -l /proc/1/exe; tr "\0" " " < /proc/1/cmdline; echo'
echo "sending SIGTERM to PID 1 from inside (should be ignored):"
docker exec e2c-d sh -c 'kill -TERM 1' && echo "  kill command returned 0 (no error)"
sleep 2
echo "after SIGTERM from inside: $(docker inspect --format "$INSPECT" e2c-d)"
echo "sending SIGKILL to PID 1 from inside (also ignored by the kernel):"
docker exec e2c-d sh -c 'kill -KILL 1' && echo "  kill command returned 0 (no error)"
sleep 2
echo "after SIGKILL from inside: $(docker inspect --format "$INSPECT" e2c-d)"

docker rm -f e2c-a e2c-b e2c-c e2c-d >/dev/null 2>&1 || true
