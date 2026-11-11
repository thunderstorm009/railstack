# 07 — Troubleshooting

> **What this chapter covers:** symptom → cause → fix, including the errors
> actually hit while building this project, with their real output.

---

## 1. The general procedure

When something is wrong, work **outside in** and **top down**:

```bash
# 1. What does Compose think the state is?
docker compose ps

# 2. What did the container say? (always first)
docker compose logs --tail=50 <service>

# 3. What does the daemon think happened to it?
./scripts/check-lifecycle.sh
# or
docker inspect --format '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' <container>

# 4. What does the application say?
docker compose exec <service> <command>
```

**The single most important habit:** look at the **logs before the inspect
output**. `docker inspect` tells you *that* the container died; the logs tell
you *why*. A container that exited with code 1 and the logs
`nginx: [emerg] unknown directive ...` is a five-second diagnosis. The same
exit code with no logs is a mystery.

---

## 2. Symptom → cause → fix

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| Container exits immediately | Bad config or bad command | `docker compose logs --tail=50 <svc>` | Fix the error the log names |
| Container exits immediately, code 1, no logs | Process crashed before logging | `docker inspect --format '{{.State.ExitCode}}' <c>` | Run the command manually: `docker compose run --rm <svc> <cmd>` |
| `unable to find user appuser` | The base image has no such user | `docker run --rm --entrypoint sh <base> -c "getent passwd appuser"` | Create the user in the Dockerfile |
| Container unhealthy | The healthcheck fails | `docker inspect --format '{{json .State.Health}}' <c>` | Read the `Log` entries — they contain the probe's actual output |
| HTTP 502 from the proxy | The upstream is down or has no live members | `docker compose logs web \| grep "no live upstreams"` | `docker compose up -d api` |
| HTTP 504 from the proxy | The upstream did not answer in time | `docker compose logs web \| grep "upstream timed out"` | Check the API's health; raise `proxy_read_timeout` |
| HTTP 503 from `/api/count` | Redis is unreachable | `docker compose exec cache redis-cli ping` | `docker compose up -d cache` |
| `port is already allocated` | Another process or container owns the port | `docker ps --filter publish=8080` | Stop the other container, or change the host port |
| Container restarting in a loop | Crash or bad config | `docker inspect --format '{{.RestartCount}}' <c>` | Fix the root cause; the loop is a symptom |
| Exit code 137 | SIGKILL — `docker kill` **or** an OOM kill | `docker inspect --format '{{.State.OOMKilled}}' <c>` | `true` → raise the memory limit; `false` → someone killed it |
| Exit code 143 | SIGTERM that the process did not handle | `docker compose logs --tail=20 <svc>` | Make PID 1 handle SIGTERM (use `exec` in the entrypoint) |
| Data vanished | `down -v` removed the volume | `docker volume ls \| grep relistack` | Restore from a backup — there is no undo |
| `nginx -t` fails but nginx "works" | The config was edited inside the container | `docker compose up -d --force-recreate web` | Rebuild from the image; in-container edits are ephemeral |
| Changes to `app.py` have no effect | The image was not rebuilt | `docker images relistack-api` timestamp | `docker compose up -d --build` |
| `docker compose` command not found | Compose v1 binary only | `docker-compose version` | Use `docker-compose` or install the v2 plugin |

---

## 3. Errors hit while building this project

These are real, with their real output.

### 3.1 `unable to find user appuser`

```
Error response from daemon: unable to find user appuser: no matching entries in passwd file
```

**Cause.** The `python:3.12-slim` base image ships **no regular user
account**. `appuser` exists in the non-slim `python` image only.

Confirming it:

```bash
$ docker run --rm --entrypoint sh python:3.12-slim -c "getent passwd nobody"
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
```

**Fix.** Create a dedicated user with a fixed uid:

```dockerfile
RUN groupadd --gid 1000 reli \
    && useradd --uid 1000 --gid 1000 --create-home --shell /usr/sbin/nologin reli \
    && chown -R reli:reli /app
USER reli
```

A *fixed* uid matters: a random uid would make the ownership of a mounted
volume unpredictable.

---

### 3.2 `ModuleNotFoundError: No module named 'bytearray'`

```
  File "<string>", line 2, in <module>
ModuleNotFoundError: No module named 'bytearray'
```

**Cause.** `bytearray` is a **builtin**, not a module. `import bytearray`
cannot work.

**Fix.** Just use it — no import needed:

```python
chunks = []
while True:
    chunks.append(bytearray(16 * 1024 * 1024))
```

**Lesson.** The symptom was misleading: the container restarted 7 times with
`oom=false`, which looks like "the OOM experiment did not work". Reading the
actual log was the only way to see the real cause.

---

### 3.3 `unknown flag: --timeout`

```
unknown flag: --timeout

Usage:  docker events [OPTIONS]
```

**Cause.** `docker events` in Docker 29.x has no `--timeout` option.

**Fix.** Background the event stream and stop it by PID:

```bash
docker events --filter "container=$name" --format '{{.Time}} {{.Action}}' > "$outfile" 2>&1 &
pid=$!
# ... do the thing ...
kill "$pid"
```

---

### 3.4 `timeout: command not found`

```
line 30: timeout: command not found
```

**Cause.** GNU `timeout` is a Linux coreutils binary. macOS has no `timeout`
by default.

**Fix.** As above — background the process and kill it by PID. This is also
why the project's scripts avoid Linux-only utilities: they have to run on
macOS, where Docker Desktop runs the Linux containers.

---

### 3.5 `tail` on the nginx error log hangs forever

**Symptom.** `docker compose exec web tail -20 /var/log/nginx/error.log`
never returns.

**Cause.** The official nginx image symlinks its log files to `/dev/stdout`
and `/dev/stderr`:

```dockerfile
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log
```

So `/var/log/nginx/error.log` is not a file — it is a live stream. `tail` on
it waits for more input forever.

**Fix.** Use `docker compose logs` instead:

```bash
docker compose logs web --no-log-prefix | grep "no live upstreams"
```

---

### 3.6 A summary that printed the wrong numbers

```
reload   : 11 failed out of 679
restart  : 11 failed out of 679
```

**Cause.** Both lines came from the same shell variable — `read` reused it,
so the second read overwrote the first.

**Symptom.** The summary contradicted the per-case output directly above it,
which already showed `requests: 681   failed: 0`.

**Fix.** One variable per measurement:

```bash
read -r reload_total reload_failed  < /tmp/e8-reload.txt
read -r restart_total restart_failed < /tmp/e8-restart.txt
```

**Lesson.** Always make a summary read its inputs from distinct names.

---

### 3.7 The proxy returned 504 instead of the expected 502

**Symptom.** After `docker compose stop api`, the proxy returned **504**,
not the 502 the plan predicted.

**Cause.** Not a bug — a network-timing distinction. nginx still had the
API's IP in its upstream pool and tried to connect; the TCP connect timed
out. Once the pool had no live members, nginx answered immediately with
502 ("no live upstreams").

**Confirmation:**

```bash
docker compose logs web --no-log-prefix | grep -E "upstream timed out|no live upstreams"
```

```
[error] upstream timed out (110: Operation timed out) while connecting to upstream, ... upstream: "http://172.18.0.3:8000/api/hello"
[error] no live upstreams while connecting to upstream, ... upstream: "http://reli_api/api/hello"
```

**Fix.** Nothing to fix — but the lesson is that 504 and 502 are different
diagnoses. 504 = "tried, timed out". 502 = "did not try, nothing to try".

---

### 3.8 A container that would not die

**Symptom.** `docker exec <c> sh -c 'kill -9 1'` returned exit 0, but the
container kept running.

**Cause.** The kernel protects **PID 1 of a PID namespace** from signals it
has not explicitly handled. A container's PID 1 ignores SIGTERM and SIGKILL
sent *from inside its own namespace*.

**Confirmation:**

```bash
docker exec <c> sh -c 'tr "\0" " " < /proc/1/cmdline; echo'
docker exec <c> sh -c 'kill -KILL 1' && echo "no error, and the container is still alive"
```

**Fix.** Kill it from outside — `docker kill <c>` — which arrives from a
different namespace and is not protected.

**Lesson.** This is also why an entrypoint should `exec` its final process,
so the real server (not a wrapper shell) is PID 1 and receives SIGTERM
directly.

---

## 4. Diagnostic cheat sheet

```bash
# What is the state of everything?
docker compose ps -a

# What did it say?
docker compose logs --tail=100 <service>

# What does the daemon think happened?
docker inspect --format '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' <container>

# Why is it unhealthy? (the probe's actual output is in the Log array)
docker inspect --format '{{range .State.Health.Log}}{{.ExitCode}} {{.Output}}{{end}}' <container>

# What did the daemon do, in order?
docker events --filter "container=<container>" --format '{{.Time}} {{.Action}}'

# What is bound to the port?
docker ps --filter publish=8080
lsof -i :8080

# What is the merged config Compose will use?
docker compose config

# Did the image actually get rebuilt?
docker images relistack-api --format '{{.Repository}} {{.Tag}} {{.CreatedAt}}'
```

---

## 5. When to reset everything

Last resort, in increasing order of destruction:

```bash
docker compose restart <service>       # 1. restart one service
docker compose up -d --force-recreate <service>   # 2. rebuild one from the image
docker compose down && docker compose up -d --build   # 3. recreate the stack
docker compose down -v && docker compose up -d --build # 4. reset state too
```

Step 4 destroys the volume and therefore the Redis counter. Prefer steps
1–3.

---

**Next:** [08 — Lessons learned](08-lessons-learned.md).
