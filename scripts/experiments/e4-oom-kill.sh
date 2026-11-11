#!/usr/bin/env bash
#
# E4 — OOM kill: what does an out-of-memory death look like?
#
# Hypothesis:
#   When the process inside a container exceeds the container's memory limit,
#   the kernel's cgroup OOM killer terminates it. The container exits with
#   code 137 (128 + 9 = SIGKILL), `.State.OOMKilled` is true, and — because
#   this is a KERNEL-initiated death and not an operator action — the restart
#   policy DOES apply. This is the classic "silent death" that a restart
#   policy exists to handle, and the opposite of E1/E2b.
#
#   Second, subtler point this experiment proves:
#   The OOM killer kills a PROCESS, not a container. If the victim is not
#   PID 1, the container keeps running. Only when PID 1 itself is killed does
#   the container exit and the restart policy fire.
#
set -euo pipefail

INSPECT='status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} mem_limit={{.HostConfig.Memory}}'

echo "############################################################"
echo "# A) PID 1 is the memory hog, 64 MB limit, --restart always"
echo "############################################################"
docker rm -f e4-oom >/dev/null 2>&1 || true
docker run -d --name e4-oom --memory=64m --restart=always relistack-api:1.0.0 \
  python -c "
chunks = []
while True:
    chunks.append(bytearray(16 * 1024 * 1024))
" >/dev/null
sleep 12
echo "state: $(docker inspect --format "$INSPECT" e4-oom)"
echo "container log (last 3 lines):"
docker logs e4-oom 2>&1 | tail -3

echo
echo "############################################################"
echo "# B) the real compose api service (256M limit, on-failure:5)"
echo "############################################################"
echo "before: $(docker inspect --format "$INSPECT" relistack-api)"

# `bytearray` is a BUILTIN, not a module — importing it raises
# ModuleNotFoundError. That was the mistake the first run of this script made.
# Allocating from a child process is enough to trip the cgroup limit:
docker compose exec -T api python -c "
chunks = []
try:
    while True:
        chunks.append(bytearray(32 * 1024 * 1024))
except MemoryError:
    print('MemoryError raised inside the container')
" 2>&1 | tail -3 || true

sleep 5
echo "after the child process allocated too much:"
echo "  $(docker inspect --format "$INSPECT" relistack-api)"
echo "  container still serving? $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8080/api/hello)"
echo
echo ">>> KEY OBSERVATION: the container is still running."
echo ">>> The OOM killer killed the child python process, NOT PID 1 (gunicorn)."
echo ">>> A container only exits when PID 1 dies."

echo
echo "############################################################"
echo "# C) same 256M limit, but the hog IS PID 1 -> container exits 137"
echo "############################################################"
docker rm -f e4-pid1 >/dev/null 2>&1 || true
docker run -d --name e4-pid1 --memory=256m --restart=on-failure:5 \
  relistack-api:1.0.0 \
  python -c "
chunks = []
while True:
    chunks.append(bytearray(32 * 1024 * 1024))
" >/dev/null
sleep 14
echo "state: $(docker inspect --format "$INSPECT" e4-pid1)"
echo "exit code detail:"
docker inspect --format 'exit={{.State.ExitCode}}  oom={{.State.OOMKilled}}  error={{.State.Error}}' e4-pid1

echo
echo "### cleaning up the scratch containers"
docker rm -f e4-oom e4-pid1 >/dev/null 2>&1 || true
echo "done"
