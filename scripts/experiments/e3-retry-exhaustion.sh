#!/usr/bin/env bash
#
# E3 — retry exhaustion with `on-failure:5`.
#
# Hypothesis:
#   A container with `--restart on-failure:5` whose process keeps failing with a
#   non-zero exit code will be restarted at most 5 times. After that Docker
#   gives up and the container stays in `exited` state with RestartCount 5.
#   An infinite crash loop would otherwise hide the real error.
#
set -euo pipefail

NAME="e3-crashloop"
INSPECT='{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}'

docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "### starting a container that always exits 1, with --restart on-failure:5"
docker run -d --name "$NAME" --restart on-failure:5 alpine:3.20 sh -c 'echo "simulated crash" >&2; exit 1' >/dev/null
sleep 1
docker inspect --format "$INSPECT" "$NAME"

echo
echo "### watching the restart counter climb (15s window)"
for i in $(seq 1 15); do
  printf 't=%02ds  %s\n' "$i" "$(docker inspect --format "$INSPECT" "$NAME" 2>/dev/null || echo 'container gone')"
  sleep 1
done

echo
echo "### final state"
docker inspect --format "$INSPECT" "$NAME"
echo "### exit code (1 = the process failed on purpose)"
docker inspect --format '{{.State.ExitCode}}' "$NAME"

echo
echo "### container logs (the crash message repeats once per attempt)"
docker logs "$NAME" 2>&1 | tail -20

echo
echo "### restarting it manually resets the retry budget"
docker start "$NAME" >/dev/null
sleep 2
docker inspect --format "$INSPECT" "$NAME"

docker rm -f "$NAME" >/dev/null 2>&1 || true
