#!/usr/bin/env bash
#
# check-lifecycle.sh — probe container lifecycle state.
#
# What it does  : prints the lifecycle-relevant fields of every ReliStack
#                container: status, health, exit code, OOM flag, restart count,
#                and how long the container has been running.
# Why we need it: every experiment in docs/05 needs the same facts about a
#                container, and reading them off `docker inspect` by hand is
#                error-prone. This script is the standard probe.
# How it works  : `docker inspect --format` renders the JSON fields into one
#                readable line per container.
#
# Usage:
#   ./scripts/check-lifecycle.sh            # all ReliStack containers
#   ./scripts/check-lifecycle.sh relistack-api   # just one
#
set -euo pipefail

FORMAT='{{.Name}}  status={{.State.Status}}  health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}  exit={{.State.ExitCode}}  oom={{.State.OOMKilled}}  restarts={{.RestartCount}}  started={{.State.StartedAt}}'

if [ $# -gt 0 ]; then
  for c in "$@"; do
    if docker inspect "$c" >/dev/null 2>&1; then
      docker inspect --format "$FORMAT" "$c"
    else
      echo "container not found: $c"
    fi
  done
  exit 0
fi

found=0
for c in $(docker ps -a --filter "name=relistack-" --format '{{.Names}}'); do
  docker inspect --format "$FORMAT" "$c"
  found=1
done

if [ "$found" -eq 0 ]; then
  echo "No ReliStack containers found. Start the stack with: docker compose up -d --build"
  exit 1
fi
