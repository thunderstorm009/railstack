#!/usr/bin/env bash
#
# E2b — why did no restart policy revive the killed container?
#
# E2 observed that `docker kill` leaves the container exited under every
# policy, including `always`. Two competing explanations:
#
#   H1: the restart policy is broken / not applied at all.
#   H2: `docker kill` is treated as a MANUAL stop, and Docker suppresses the
#       restart policy for manually stopped containers. The container would
#       restart fine if the process died on its own.
#
# This script distinguishes them by varying only HOW the container dies:
#
#   A  process exits by itself with code 1     (natural failure)
#   B  process exits by itself with code 0     (natural success)
#   C  SIGKILL delivered from INSIDE the container
#   D  `docker kill` from outside              (external kill)
#   E  `docker stop` from outside              (explicit stop)
#
set -euo pipefail

INSPECT='status={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}} policy={{.HostConfig.RestartPolicy.Name}}'

probe() {
  local label="$1" name="$2" method="$3" cmd="$4"

  echo
  echo "=============================================================="
  echo "### $label"
  echo "=============================================================="

  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --restart always alpine:3.20 sh -c "$cmd" >/dev/null
  sleep 2
  echo "policy on the container: $(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$name")"
  echo "before:  $(docker inspect --format "$INSPECT" "$name")"

  case "$method" in
    kill-inside) docker exec "$name" sh -c 'kill -9 1' >/dev/null 2>&1 || true ;;
    kill-outside) docker kill "$name" >/dev/null 2>&1 || true ;;
    stop-outside) docker stop "$name" >/dev/null 2>&1 || true ;;
  esac

  sleep 6
  echo "after:   $(docker inspect --format "$INSPECT" "$name")"

  docker rm -f "$name" >/dev/null 2>&1 || true
}

probe "A) process exits by itself with code 1" "e2b-a" "self" 'exit 1'
probe "B) process exits by itself with code 0" "e2b-b" "self" 'exit 0'
probe "C) SIGKILL sent from INSIDE the container" "e2b-c" "kill-inside" 'sleep 3600'
probe "D) docker kill from OUTSIDE" "e2b-d" "kill-outside" 'sleep 3600'
probe "E) docker stop from OUTSIDE" "e2b-e" "stop-outside" 'sleep 3600'

echo
echo "=== interpretation ==="
cat <<'EOF'
restarts>0 after a death  -> the policy DOES act, and the container was revived.
restarts=0 after a death  -> Docker considered the stop "manual" and suppressed
                             the policy. Manual = stopped through the CLI/API by
                             an operator, as opposed to the process dying on its own.
EOF
