# 02 — Docker concepts

> **What this chapter covers:** the primitives ReliStack is built from. Each
> section follows the same shape: **What it does → Why we need it → How it
> works → Expected output → What we observed → Common mistakes**.

---

## 1. Images vs containers

**What it does.** An **image** is an immutable blueprint; a **container** is a
running instance of that blueprint.

**Why we need it.** The distinction explains why `docker images` shows three
entries while `docker ps` shows three *different* things, and why killing a
container never damages an image.

**How it works.** `docker run image` = create a container from the image +
start it. `docker rm` deletes the container; the image stays. `docker rmi`
deletes the image.

**Expected output:**

```bash
$ docker images --format '{{.Repository}}:{{.Tag}}'
relistack-api:1.0.0
relistack-web:1.0.0
redis:7-alpine
nginx:1.29-alpine
python:3.12-slim
alpine:3.20

$ docker ps --format '{{.Names}} {{.Image}}'
relistack-api     relistack-api:1.0.0
relistack-cache   redis:7-alpine
relistack-web     relistack-web:1.0.0
```

**What we observed.** Exactly this — the two built images carry the explicit
`:1.0.0` tag we set in `docker-compose.yml`, the third-party images carry
their upstream tags, and `alpine:3.20` was pulled by the E2 experiment.

**Common mistakes.** Running `docker rm` when you meant `docker rmi` (or the
other way round); expecting `docker run` to reuse a container — it always
creates a new one.

---

## 2. Layers and the build cache

**What it does.** A Dockerfile is a sequence of instructions; each becomes an
image **layer**. Layers are cached and only rebuilt when their inputs change.

**Why we need it.** Understanding the cache explains why a 3-second rebuild
is possible after editing one line of Python — and why copying the source
*before* the dependencies destroys that speed.

**How it works.** Each `RUN`/`COPY`/`ADD` produces a layer. On rebuild,
Docker reuses any layer whose instruction and inputs are unchanged. A layer
is invalidated by a change to itself or to anything above it.

**Expected output.** The API build from a cold cache:

```
#22 12.86 Successfully installed Jinja2-3.1.6 MarkupSafe-2.1.5 ... flask-3.0.3 gunicorn-22.0.0 redis-5.0.8
#23 [api 5/5] COPY app.py .
#23 DONE 0.0s
#24 [api] exporting to image
```

Note `#22` is the `pip install` step and `#23` is the `COPY app.py`. They are
separate layers on purpose.

**What we observed.** On the rebuild after the `appuser` fix, the dependency
layer was reused — the build went straight to copying `app.py` and exporting
the image, without re-running `pip install`.

**Common mistakes.** The classic mistake is ordering:

```dockerfile
# WRONG — every source edit reinstalls every dependency
COPY . .
RUN pip install -r requirements.txt

# RIGHT — dependencies are installed in their own cached layer
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
```

Also: `COPY . .` copies everything in the context, including `.git` and
local secrets. Use a `.dockerignore` (see [03](03-build-and-run.md)).

---

## 3. Registries and layers

**What it does.** A registry stores images so other machines can pull them.
Docker Hub is the default.

**Why we need it.** `redis:7-alpine` and `nginx:1.29-alpine` are pulled from
Docker Hub; only `api` and `web` are built locally.

**How it works.** `docker pull` downloads the image's layers. `docker push`
uploads yours.

**Expected output:**

```bash
$ docker pull redis:7-alpine
7.4.1-alpine: Pulling from library/redis
Digest: sha256:...
Status: Downloaded newer image for redis:7-alpine
```

**What we observed.** During E2, `alpine:3.20` was pulled on first use:

```
Unable to find image 'alpine:3.20' locally
3.20: Pulling from library/alpine
Status: Downloaded newer image for alpine:3.20
```

**Common mistakes.** Using `:latest` for anything you care about — it is a
moving target, so two machines can run different code under the same name.
ReliStack pins `redis:7-alpine`, `nginx:1.29-alpine`, `python:3.12-slim` and
tags its own images `1.0.0`.

---

## 4. Volumes vs bind mounts

**What it does.** Both persist data outside the container's writable layer;
they differ in who owns the storage.

**Why we need it.** The Redis counter must survive the container being
replaced. Without persistent storage the counter would reset every time the
API or cache container was recreated — which would make experiment E7
impossible and the stack useless.

**How it works.**

| | Named volume | Bind mount |
|---|---|---|
| Storage location | Docker-managed (under `/var/lib/docker/volumes`) | A path you choose on the host |
| Path in the container | You choose | Always the same host path |
| Permissions | Docker handles them | You handle them |
| Good for | Databases, queues, anything stateful | Live-editing code, logs, config |
| Survives `docker compose down` | Yes | Yes (the host path is untouched) |

ReliStack uses a **named volume** (`relistack-redis-data`) mounted at `/data`
in the Redis container.

**Expected output:**

```bash
$ docker volume ls --filter 'name=relistack'
relistack-redis-data
```

**What we observed.** E7 showed the full lifecycle:

```
### 2) docker compose down  (containers removed, volumes KEPT)
  volume still present? relistack-redis-data

### 4) docker compose down -v   (volumes REMOVED too)
  volume still present? []
```

**Common mistakes.** Believing `docker compose down` deletes your data — it
does not; only `down -v` does. Conversely, expecting `down -v` to be
reversible — it is not. And on macOS, bind mounts are slow because they
cross a virtualisation boundary; named volumes are noticeably faster, which
is another reason to prefer them for databases.

---

## 5. Networks and embedded DNS

**What it does.** Containers on the same user-defined network can reach each
other by service name.

**Why we need it.** `nginx.conf` says `proxy_pass http://api:8000`. That
name has to resolve to the API container's current IP.

**How it works.** Docker runs a DNS server at `127.0.0.11` inside every
user-defined network. Compose registers each service under its service name
and the network's aliases.

**Expected output:**

```bash
$ docker compose exec web cat /etc/resolv.conf
nameserver 127.0.0.11
options ndots:0

$ docker compose exec web getent hosts api
172.18.0.3    api
```

**What we observed.** In the E1 nginx error log the upstream was addressed
by IP (`http://172.18.0.3:8000/api/hello`) in one line and by name
(`http://reli_api/api/hello`) in another — nginx resolved the name once and
then worked with the address internally.

**Common mistakes.** Hard-coding container IPs in configuration; assuming the
default bridge network gives you DNS (it does not — you must use a
user-defined network); using `localhost` inside a container to reach another
container (that is the container itself).

---

## 6. Healthchecks

**What it does.** Docker periodically runs a command inside the container and
records the result as `healthy`, `unhealthy` or `starting`.

**Why we need it.** "The container is running" and "the container is ready"
are different facts. Healthchecks let Docker measure the second one, and
let Compose order startup on it.

**How it works.** A healthcheck is defined by four knobs:

```yaml
healthcheck:
  test: ["CMD", "redis-cli", "ping"]   # what to run
  interval: 5s                          # how often
  timeout: 3s                           # how long to wait for it
  retries: 5                            # failures before "unhealthy"
  start_period: 3s                      # grace period while booting
```

`start_period` matters: without it, a service that needs 10 seconds to boot
would be marked unhealthy before it ever had a chance. During the start
period, a failing check does **not** count toward `retries`.

**Expected output:**

```bash
$ docker compose ps
NAME              IMAGE                 SERVICE   STATUS
relistack-api     relistack-api:1.0.0   api       Up 11 seconds (healthy)
relistack-cache   redis:7-alpine        cache     Up 58 seconds (healthy)
relistack-web     relistack-web:1.0.0   web       Up 6 seconds (healthy)
```

**What we observed.** All three services reached `healthy` within ~10
seconds of start, and `docker compose up -d` blocked on `Waiting` →
`Healthy` transitions in dependency order.

**Common mistakes.** Writing a healthcheck that checks a *dependency* rather
than the service itself (see [01 §5](01-architecture.md#5-healthcheck-design));
omitting `start_period`; using a command that does not exist in the image
(Alpine has BusyBox `wget`; a Debian image may not have `wget` at all).

**A note on two places to define it.** The API image defines `HEALTHCHECK` in
the Dockerfile *and* `docker-compose.yml` defines one. The image-level check
is what a bare `docker run` uses; the Compose-level one overrides it inside
Compose. Both are kept in sync deliberately — if they drift, the image
behaves differently outside Compose, which is a classic source of
"works in Compose, breaks in CI" bugs.

---

## 7. Restart policies

**What it does.** Decides whether Docker restarts a container after it exits.

**Why we need it.** Without a policy, a crashed container stays dead until
somebody notices. With one, the stack recovers by itself — provided you
understand exactly *when* it applies.

**How it works.** The four policies:

| Policy | Restarts when | After `docker stop` | After host reboot |
|---|---|---|---|
| `no` | never | no | no |
| `on-failure[:N]` | exit code ≠ 0 | no | only if it failed |
| `always` | always | **no** | yes |
| `unless-stopped` | always | **no** | yes (if not manually stopped) |

**Expected output:**

```bash
$ docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' relistack-api
on-failure
```

**What we observed.** This is where the project produced its most important
correction. **A restart policy does not fire when an operator stops the
container.** E2b proved it:

```
### A) process exits by itself with code 1
before:  status=restarting exit=1 restarts=5 policy=always
after:   status=restarting exit=1 restarts=7 policy=always

### D) docker kill from OUTSIDE
before:  status=running exit=0 restarts=0 policy=always
after:   status=exited exit=137 restarts=0 policy=always
```

And `docker events` showed the mechanism exactly:

```
# A) process exits by itself (exit 1)
1794412734 die
1794412734 start
1794412734 die
1794412734 start

# B) docker kill from outside
1794412752 kill
1794412752 die
```

The `kill` event marks an operator-initiated stop, and Docker suppresses the
policy for it.

**Common mistakes.** Believing `always` means "always comes back". It means
"always comes back *unless a human stopped it*". Also: `on-failure` without
a limit means an infinite crash loop, which is worse than a visible outage.

---

## 8. Exit codes

**What it does.** A container's exit code is how it reports *why* it died.

**Why we need it.** "The container stopped" is not an answer. "It exited 137
with OOMKilled=true" tells you the kernel ran out of memory and killed it.

**How it works.** The common codes in this project:

| Code | Meaning | How it is produced |
|---|---|---|
| `0` | Clean success | The process exited normally |
| `1` | Generic error | The process chose to fail (e.g. `nginx -t` rejecting a config) |
| `137` | Killed by SIGKILL | `docker kill`, **or** the OOM killer |
| `143` | Terminated by SIGTERM | The process was SIGTERMed and did not handle it |

The rule of thumb: **128 + signal number**. SIGKILL is 9 → 128 + 9 = 137.
SIGTERM is 15 → 128 + 15 = 143.

**Expected output:**

```bash
$ docker inspect --format '{{.State.ExitCode}} {{.State.OOMKilled}}' relistack-api
0 false
```

**What we observed.** Across the experiments:

| Scenario | Exit code | `OOMKilled` |
|---|---|---|
| `docker compose stop api` | **0** | false |
| `docker kill relistack-api` | **137** | false |
| OOM kill (PID 1 victim) | **137** | **true** |
| Broken NGINX config | **1** | false |
| Crashing API (E3) | **1** | false |

**Common mistakes.** Reading 137 as "only OOM". `docker kill` produces the
same 137 — you must check `.State.OOMKilled` to tell them apart. That is
exactly what `scripts/check-lifecycle.sh` prints on one line.

---

## 9. Memory limits and the OOM killer

**What it does.** Caps how much memory a container may use. When it exceeds
the cap, the kernel kills the process.

**Why we need it.** Without a limit, one misbehaving container can consume
the whole host's RAM and take everything else down with it.

**How it works.** The limit is enforced by the kernel's **cgroup** subsystem.
When the limit is exceeded, the cgroup OOM killer terminates the offending
process with SIGKILL — the same signal `docker kill` sends, which is why both
produce exit code 137.

**Expected output:**

```bash
$ docker inspect --format '{{.HostConfig.Memory}}' relistack-api
268435456        # 256 MiB
```

**What we observed.** E4 produced the definitive result:

```
# A) PID 1 is the memory hog, 64 MB limit, --restart always
state: status=restarting exit=137 oom=true restarts=7 mem_limit=67108864

# C) same 256M limit, but the hog IS PID 1 -> container exits 137
state: status=exited exit=137 oom=true restarts=5 mem_limit=268435456
```

And an important subtlety, from case B:

```
after the child process allocated too much:
  status=running exit=0 oom=true restarts=0 mem_limit=268435456
  container still serving? 200
```

**The OOM killer kills a process, not a container.** When the victim was a
child `python` process rather than gunicorn (PID 1), the container survived
and kept serving. Only the death of PID 1 ends a container.

**Common mistakes.** Assuming `oom=true` means the container died — it only
means *something* in the container was OOM-killed. Also: setting the limit
equal to what the application normally uses guarantees a crash under load;
leave headroom.

---

## 10. Logging

**What it does.** Docker captures stdout and stderr of every container into
a log.

**Why we need it.** Logs are the only evidence of what happened inside a
container that has already exited.

**How it works.** The default `json-file` driver stores logs per container.
`docker logs` reads them; `docker compose logs` aggregates across services.

**Expected output:**

```bash
$ docker compose logs --tail=5 api
relistack-api-1  | 10.0.0.1 - - [11/Nov/2026:16:07:02 +0000] "GET /api/count HTTP/1.1" 200 -
```

**What we observed.** E5's failure was readable purely from the log:

```
[relistack] validating nginx configuration...
nginx: [emerg] unknown directive "this_is_not_a_valid_directive" in /etc/nginx/nginx.conf:82
```

**Common mistakes.** Forgetting `PYTHONUNBUFFERED=1` in a Python image, so
logs appear in chunks minutes late; assuming logs survive `docker compose
down` (they do not — the container and its log file are removed together).

---

**Next:** [03 — Build and run](03-build-and-run.md).
