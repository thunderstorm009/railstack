#!/usr/bin/env bash
#
# E2 — the restart-policy matrix.
#
# Hypothesis:
#   no              : a killed container stays dead.
#   on-failure      : restarts only if the exit code is non-zero (SIGKILL -> 137).
#   always          : restarts on any exit.
#   unless-stopped  : restarts like `always`, except after an explicit stop.
#
# Second half of the experiment: after an explicit `docker stop`, `always`
# and `unless-stopped` must NOT bring the container back.
#
set -euo pipefail

INSPECT='{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}'

run_case() {
  local policy="$1" name="e2-$1"
  echo
  echo "=============================================================="
  echo "### policy: $policy"
  echo "=============================================================="

  docker rm -f "$name" >/dev/null 2>&1 || true

  # A container that ignores SIGTERM would muddy the exit codes, so we use a
  # long sleep that dies immediately on SIGTERM.
  docker run -d --name "$name" --restart "$policy" alpine:3.20 sleep 3600 >/dev/null
  sleep 1
  echo "started:  $(docker inspect --format "$INSPECT" "$name")"

  echo "-- SIGKILL (docker kill)"
  docker kill "$name" >/dev/null
  sleep 5
  echo "after kill: $(docker inspect --format "$INSPECT" "$name")"

  echo "-- explicit stop (docker stop)"
  docker stop "$name" >/dev/null 2>&1 || true
  sleep 5
  echo "after stop: $(docker inspect --format "$INSPECT" "$name")"

  docker rm -f "$name" >/dev/null 2>&1 || true
}

echo "restart policies under test: no | on-failure | always | unless-stopped"
run_case no
run_case on-failure
run_case always
run_case unless-stopped

echo
echo "=== summary ==="
printf '%-16s %-10s %-8s %-10s\n' POLICY STATUS EXIT RESTARTS
for p in no on-failure always unless-stopped; do
  echo "(see per-case output above for $p)"
done
