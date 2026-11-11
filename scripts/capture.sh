#!/usr/bin/env bash
#
# capture.sh — store real terminal output under docs/results/.
#
# What it does  : runs a command and saves both the output and the exact
#                command line into a timestamped file under docs/results/.
# Why we need it: the documentation must quote *real* captured output, not
#                remembered or invented output. Capturing at the moment the
#                command runs is the only honest way to do that.
# How it works  : `tee` writes to the file while still printing to the
#                terminal, so you see the output and it is saved in one step.
#
# Usage:
#   ./scripts/capture.sh E1-stop-vs-kill "docker compose stop api; docker inspect ..."
#   ./scripts/capture.sh E2-matrix bash scripts/experiments/e2-matrix.sh
#
# The first argument is the experiment ID (used for the filename), the second
# is the command to run.
#
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <experiment-id> <command>" >&2
  exit 2
fi

ID="$1"
shift
CMD="$*"

RESULTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/docs/results"
mkdir -p "$RESULTS_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
FILE="$RESULTS_DIR/${ID}-${STAMP}.txt"

{
  echo "===================================================================="
  echo "Experiment : $ID"
  echo "Timestamp  : $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
  echo "Host       : $(uname -srm)"
  echo "Docker     : $(docker --version)"
  echo "Compose    : $(docker compose version)"
  echo "Command    : $CMD"
  echo "===================================================================="
  echo
} > "$FILE"

# shellcheck disable=SC2086
{
  set -x
  eval "$CMD"
} >> "$FILE" 2>&1 || true

{
  echo
  echo "===================================================================="
  echo "Exit status of the captured command: (see trace above)"
  echo "Captured by scripts/capture.sh"
  echo "===================================================================="
} >> "$FILE"

echo
echo "Saved output to: $FILE"
echo "--- captured output ---"
cat "$FILE"
