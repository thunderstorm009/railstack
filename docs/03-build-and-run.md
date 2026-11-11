# 03 — Build and run

> **What this chapter covers:** every line of both Dockerfiles, the build
> context, layer caching, and the `docker compose` commands that bring the
> stack up and let you look inside it.

---

## 1. The API Dockerfile

```dockerfile
# syntax=docker/dockerfile:1
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    REDIS_HOST=cache \
    REDIS_PORT=6379

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN groupadd --gid 1000 reli \
    && useradd --uid 1000 --gid 1000 --create-home --shell /usr/sbin/nologin reli \
    && chown -R reli:reli /app

USER reli

EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz')" || exit 1

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "1", "--access-logfile", "-", "app:app"]
```

### Instruction by instruction

| Instruction | What it does | Why it is here |
|---|---|---|
| `# syntax=` | Selects the BuildKit frontend version | Pins the Dockerfile dialect; BuildKit is the default in modern Docker |
| `FROM python:3.12-slim` | Base image | Slim = Debian without the compilers we do not need |
| `ENV PYTHONUNBUFFERED=1` | stdout is unbuffered | Without it, Flask logs arrive in chunks minutes late |
| `ENV PYTHONDONTWRITEBYTECODE=1` | no `.pyc` files | Keeps the image clean and avoids stale bytecode |
| `ENV REDIS_HOST=cache` | Default config | Overridable at runtime via `docker compose` |
| `WORKDIR /app` | Sets the working directory | All later relative paths resolve here |
| `COPY requirements.txt .` | Copies **only** the dependency list | Its own cached layer — see below |
| `RUN pip install --no-cache-dir` | Installs the dependencies | `--no-cache-dir` avoids baking pip's cache into the image |
| `COPY app.py .` | Copies the source | Separate layer, so editing `app.py` does not reinstall deps |
| `RUN groupadd/useradd` | Creates a non-root user | See the failure below |
| `USER reli` | Runs as that user from here on | Least privilege |
| `EXPOSE 8000` | Documents the port | Metadata only — it does **not** publish the port |
| `HEALTHCHECK` | Image-level health probe | Survives `docker run` without Compose |
| `CMD [...]` | The default command | Gunicorn, not `python app.py` |

### Why single-stage

There is nothing to compile. A multi-stage build (`FROM python AS builder` →
`FROM python` → copy artifacts) exists to avoid shipping build tools that
are only needed at build time. With pure-Python dependencies, that would add
layers and download everything twice for no benefit. The trade-off flips for
compiled languages — see [02 §2](02-docker-concepts.md#2-layers-and-the-build-cache).

### Why the layer order matters

```dockerfile
COPY requirements.txt .          # layer 1 — cached until requirements.txt changes
RUN pip install -r requirements.txt   # layer 2 — cached with layer 1
COPY app.py .                    # layer 3 — changes on every code edit
```

Swap the two `COPY`s and every one-character edit to `app.py` invalidates
the `pip install` layer and forces a full reinstall.

### The real error this Dockerfile hit

The first version ended with:

```dockerfile
USER appuser
```

That failed at container start:

```
Error response from daemon: unable to find user appuser: no matching entries in passwd file
```

**Why.** The `python:3.12-slim` base image ships **no regular user account**
at all. Only `nobody` (uid 65534) exists, and it has a nologin shell:

```bash
$ docker run --rm --entrypoint sh python:3.12-slim -c "getent passwd nobody"
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
```

`appuser` is a convenience that exists in the **non-slim** `python` image, not
in the slim one. The fix was to create a dedicated account with a **fixed
uid/gid** — a random uid would make the ownership of any mounted volume
unpredictable.

### Why Gunicorn and not `python app.py`

`python app.py` uses the Flask development server, which is explicitly "not
for production". Gunicorn also handles **signals properly**: it is PID 1, it
receives SIGTERM from `docker stop`, and it stops accepting new connections
while finishing in-flight requests. That graceful path is exactly what
experiment E1 measures.

The `--workers 1` setting is deliberate. This project is about the container
lifecycle, not about load balancing — and one worker makes the process tree
predictable, which matters when experimenting with OOM kills and signals.

---

## 2. The web Dockerfile

```dockerfile
FROM nginx:1.29-alpine

COPY nginx.conf /etc/nginx/nginx.conf
COPY static/ /usr/share/nginx/html/
COPY relistack-entrypoint.sh /usr/local/bin/relistack-entrypoint.sh

RUN chmod +x /usr/local/bin/relistack-entrypoint.sh \
    && rm -f /etc/nginx/conf.d/default.conf

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/relistack-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
```

| Instruction | Why |
|---|---|
| `FROM nginx:1.29-alpine` | The official image already contains nginx, mime types and entrypoint helpers |
| `COPY nginx.conf ...` | Replaces the stock config wholesale — simpler to reason about than patching the image's multi-file layout |
| `COPY static/ ...` | The landing page |
| `RUN chmod +x ...` | Scripts copied from a build context are not executable |
| `rm -f /etc/nginx/conf.d/default.conf` | The stock vhost listens on port 80 and would conflict with ours |
| `HEALTHCHECK ... wget` | Alpine ships BusyBox `wget`, so no extra package is needed |
| `ENTRYPOINT` | Our fail-fast wrapper — see below |
| `CMD ["nginx", "-g", "daemon off;"]` | `daemon off` keeps nginx in the foreground as PID 1 |

### The fail-fast entrypoint

```sh
#!/bin/sh
set -e

echo "[relistack] validating nginx configuration..."
nginx -t

echo "[relistack] configuration OK, starting nginx"
exec /docker-entrypoint.sh "$@"
```

Three details that each matter:

1. **`nginx -t` before anything else.** nginx validates the configuration and
   exits non-zero on any syntax or reference error.
2. **`set -e`.** That non-zero exit ends the container immediately, with the
   error message already printed.
3. **`exec`.** It *replaces* the shell with nginx, so nginx becomes PID 1 and
   receives SIGTERM directly on `docker stop`. Without `exec`, the shell
   would be PID 1 and would need to forward the signal itself.

The whole point is diagnosability. E5 showed the difference: without the
guard, a broken config becomes a silent crash loop; with it, you get one
line naming the file and line number.

### Why `nginx.conf` uses `resolve`

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;

upstream reli_api {
    zone reli_api 64k;
    server api:8000 resolve;
    keepalive 16;
}
```

* `resolver 127.0.0.11` — Docker's embedded DNS.
* `server api:8000 resolve` — re-resolve the name instead of pinning the IP.
  Without this, nginx keeps the address it saw at startup and returns 502
  forever after the API container is replaced with a new IP.
* `zone` — mandatory with `resolve`; nginx needs shared memory to store the
  resolved addresses.
* `keepalive 16` — reuse upstream connections instead of opening a new TCP
  connection per request.

---

## 3. The build context and `.dockerignore`

**What it does.** The **build context** is the directory sent to the Docker
daemon when you build. Everything in it is uploaded, whether or not the
Dockerfile uses it.

**Why it matters.** A large context slows every build, and a careless one
leaks secrets into an image layer.

**How it works.** `.dockerignore` in the context root excludes paths, using
the same pattern syntax as `.gitignore`.

```dockerignore
# api/.dockerignore
__pycache__/
*.pyc
.venv/
.env
.git/
```

**Expected output:**

```bash
$ docker build -t relistack-api:1.0.0 ./api
```

**What we observed.** The `api/.dockerignore` keeps the context tiny — only
`app.py` and `requirements.txt` are relevant, so the `COPY` steps have
nothing extra to consider.

**Common mistakes.** Committing a `.env` file and then building — the file
is excluded here, but the habit is worth breaking. Also: `COPY . .` in a
directory containing a `.git` folder ships the entire repository history into
the image.

---

## 4. Building and running

### Build

```bash
# Build both images
docker compose build

# Build and start in one step
docker compose up -d --build
```

**What it does.** `docker compose build` builds the `api` and `web` images.
`--build` on `up` forces a rebuild even if an image with the same tag
already exists.

**Expected output (real):**

```
#22 12.86 Successfully installed Jinja2-3.1.6 MarkupSafe-2.1.5 ... flask-3.0.3 gunicorn-22.0.0 redis-5.0.8
#23 [api 5/5] COPY app.py .
#23 DONE 0.0s
#24 [api] exporting to image
#24 naming to docker.io/library/relistack-api:1.0.0 done
 Image relistack-api:1.0.0 Built 
 Image relistack-web:1.0.0 Built 
```

### Start

```bash
docker compose up -d
```

**What it does.** Creates the network, creates the volume, creates and starts
the containers, and waits for health-gated dependencies.

**Expected output (real):**

```
 Network relistack-relinet Creating 
 Network relistack-relinet Created 
 Volume relistack-redis-data Creating 
 Volume relistack-redis-data Created 
 Container relistack-cache Creating 
 Container relistack-cache Created 
 Container relistack-cache Starting 
 Container relistack-cache Started 
 Container relistack-cache Waiting 
 Container relistack-cache Healthy 
 Container relistack-api Starting 
 Container relistack-api Started 
 Container relistack-api Waiting 
 Container relistack-api Healthy 
 Container relistack-web Starting 
 Container relistack-web Started 
```

`Waiting` → `Healthy` is Compose blocking on the healthcheck. See
[01 §7](01-architecture.md#7-startup-order-observed).

### The `-d` flag

Without `-d`, `docker compose up` stays in the foreground and streams all
logs. With `-d` it detaches and returns. Use `-d` for normal work; drop it
when you want to watch the startup sequence live.

---

## 5. Inspecting a running stack

```bash
docker compose ps                 # one row per service
docker compose ps --format '{{.Service}} {{.Health}}'
docker compose logs -f api        # follow one service
docker compose logs --tail=50 web
docker compose top                # processes running inside each container
docker compose config             # the fully resolved config, after merging
```

**Expected output (real):**

```
$ docker compose ps
NAME              IMAGE                 COMMAND                  SERVICE   STATUS
relistack-api     relistack-api:1.0.0   "gunicorn --bind 0.0…"   api       Up 11 seconds (healthy)
relistack-cache   redis:7-alpine        "docker-entrypoint.s…"   cache     Up 58 seconds (healthy)
relistack-web     relistack-web:1.0.0   "/usr/local/bin/reli…"   web       Up 6 seconds (healthy)    0.0.0.0:8080->8080/tcp
```

### `docker compose config`

Worth knowing about: it renders the *merged* configuration, including
environment interpolation and defaults. It is the fastest way to answer
"what does Compose actually think this file says?".

```bash
$ docker compose config --quiet && echo "COMPOSE FILE VALID"
COMPOSE FILE VALID
```

---

## 6. `exec` vs `run`

This trips people up regularly, so it is worth being precise.

| | `docker compose exec` | `docker compose run` |
|---|---|---|
| Creates a new container | **No** — runs in the running one | **Yes** |
| Needs the service running | Yes | No |
| Shares the service's network | Yes | Yes (by default) |
| Publishes ports | No | Only with `--service-ports` |
| Typical use | Look around, run a one-off command | Run a migration, a shell for debugging |

**Examples:**

```bash
# Look inside the running API container
docker compose exec api sh
docker compose exec api env | grep REDIS

# Talk to Redis directly
docker compose exec cache redis-cli GET reli:count

# Run a one-off container in the same network
docker compose run --rm api python -c "print('one-off')"
```

**Common mistake.** `docker compose run api ...` creates a *second* API
container that fights over the same port mapping and looks like a bug. E3
originally tried this; it was rewritten to use `docker run` with an explicit
name instead, so the experiment's container is obvious and removable.

---

## 7. Stopping and cleaning up

```bash
docker compose stop              # stop containers, keep them
docker compose start             # start them again
docker compose down              # remove containers + network, KEEP the volume
docker compose down -v           # also remove the volume -> data is gone
docker compose down --rmi local # also remove the locally built images
```

| Command | Containers | Network | Volume | Images |
|---|---|---|---|---|
| `stop` | kept (stopped) | kept | kept | kept |
| `down` | removed | removed | **kept** | kept |
| `down -v` | removed | removed | **removed** | kept |
| `down --rmi local` | removed | removed | kept | local ones removed |

**What we observed.** E7 walked exactly this table, and the difference is
visible in the data:

```
### 2) docker compose down  (containers removed, volumes KEPT)
  volume still present? relistack-redis-data
  /api/count -> {"container":"d3f1f22f655e","count":38}     <-- survived

### 4) docker compose down -v   (volumes REMOVED too)
  volume still present? []
  /api/count -> {"container":"5b634d9b060d","count":1}       <-- reset
```

**Common mistakes.** Running `down -v` reflexively as "clean everything up"
and silently deleting a database. Read the flag before you type it.

---

**Next:** [04 — Lifecycle and restart](04-lifecycle-and-restart.md).
