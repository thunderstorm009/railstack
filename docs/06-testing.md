# 06 — Testing

> **What this chapter covers:** the automated smoke test, what each assertion
> actually proves, the real output of a run, and how to add a check.

---

## 1. Why a smoke test

**What it does.** `scripts/smoke-test.sh` runs five assertions against a
running stack and exits non-zero if any of them fail.

**Why we need it.** Manual `curl` calls prove that *one* request worked
once. A smoke test proves the **contract** holds:

> the proxy is up → it forwards to the API → the API reaches Redis → the
> counter increments → every container reports healthy.

It is also the regression test you re-run after every change. Without it,
"did I break something?" is answered by clicking around in a browser.

**How it works.** Plain bash, `set -euo pipefail`, no test framework. Only
`curl` and `docker` are required.

---

## 2. Running it

```bash
./scripts/smoke-test.sh
```

```
ReliStack smoke test — target: http://localhost:8080

PASS  proxy /healthz returns 200 (ok)
PASS  proxy /api/hello returns 200 with container id ({"container":"5b634d9b060d","message":"hello from reli-api","service":"api"})
PASS  api -> redis round trip works (count 3 -> 4)
PASS  counter persists across requests (count 4 -> 5)
PASS  all services report healthy
        api healthy
        cache healthy
        web healthy

Summary: 5 passed, 0 failed
EXIT=0
```

The exit code is the important part — `0` means everything passed, `1` means
at least one assertion failed:

```bash
./scripts/smoke-test.sh > /dev/null && echo "green" || echo "red"
```

### Options

| Variable | Default | Purpose |
|---|---|---|
| `BASE_URL` | `http://localhost:8080` | Point at a different host or port |
| `COMPOSE` | `docker compose` | Use `docker-compose` on older setups |
| `PROJECT_NAME` | `relistack` | Match the Compose project name |

```bash
BASE_URL=http://localhost:9090 ./scripts/smoke-test.sh
```

---

## 3. What each assertion proves

| # | Assertion | What it proves | What it does **not** prove |
|---|---|---|---|
| 1 | `GET /healthz` → 200 | The proxy container is running and serving on the published port | That the API works |
| 2 | `GET /api/hello` → 200 with a `container` field | The reverse proxy forwards to the API, **and** the response came from a container (the hostname proves it) | That Redis works |
| 3 | Two `/api/count` calls increase by exactly 1 | The full path works: proxy → API → **Redis** → back | That the value persists |
| 4 | A third call continues from the previous value | The value lives in **Redis**, not in a process-local variable | — |
| 5 | All three services report `healthy` | The healthchecks are wired up and the dependency ordering held | That the app is correct |

Assertion 3 is the one that does the real work. It is the only check that
touches Redis, so it is the only one that can catch a broken cache, a wrong
`REDIS_HOST`, or a missing volume mount.

Assertion 2's `container` field matters more than it looks: it proves the
response came from the `relistack-api` container and not from something
running on the host that happens to be listening on 8080.

---

## 4. The script

```bash
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
COMPOSE="${COMPOSE:-docker compose}"
PROJECT_NAME="${PROJECT_NAME:-relistack}"

PASS_COUNT=0
FAIL_COUNT=0

pass() { green "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { red   "FAIL  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
```

Two details worth understanding:

**Why `set -euo pipefail`**

| Flag | Effect | Why here |
|---|---|---|
| `-e` | Exit on the first failing command | A broken prerequisite should stop the run, not produce 5 confusing failures |
| `-u` | Error on an unset variable | Catches typos in variable names |
| `-o pipefail` | A pipeline fails if *any* stage fails | Without it, `curl ... \| grep ...` masks curl's exit code |

**Why failures are counted instead of aborting.** With `set -e`, the first
failed `if` condition would end the script. Each check is therefore written
as `if ... ; then pass ... ; else fail ... ; fi` — the `if` context disables
`errexit` for that command, so the script records every failure and reports
them all at once. That is much more useful than stopping at the first
problem.

---

## 5. Adding a check

The pattern is: compute a value, compare it, report.

```bash
# --- new check: the proxy must forward the client's real IP ---
client_ip="$(curl -fsS --max-time 5 "$BASE_URL/api/hello" 2>/dev/null | sed -n 's/.*"container":"\([^"]*\)".*/\1/p')"

if [ -n "$client_ip" ]; then
  pass "proxy /api/hello returns the container id"
else
  fail "proxy /api/hello did not return a container id"
fi
```

Then update the expected count in the summary. The script prints
`Summary: $PASS_COUNT passed, $FAIL_COUNT failed` and exits 1 if
`FAIL_COUNT > 0`, so no other change is needed.

### Two rules

1. **Assert on the response, not on the exit code alone.** `curl -f` alone
   would pass for any 2xx. Parsing the body is what makes the check
   meaningful.
2. **Never let a check hang.** Always pass `--max-time` to `curl`. A smoke
   test that blocks forever is worse than no smoke test.

---

## 6. Testing the failure paths

The smoke test proves the happy path. The chaos lab proves the unhappy
paths. Both are needed: a stack that only works when everything is fine is
not resilient, and a stack that fails unpredictably is not usable.

| Scenario | How to test it | Where |
|---|---|---|
| API is down | `docker kill relistack-api` then `curl` → 502 | E1 |
| API is stopped gracefully | `docker compose stop api` then `curl` → 504 | E1 |
| Cache is down | `docker compose stop cache` then `curl /api/count` → 503 | `chaos.sh stop-cache` |
| Proxy is down | `docker compose stop web` then `curl` → no response | `chaos.sh status` |
| Config is broken | `chaos.sh bad-config` → `[emerg]` in the logs | E5 |
| Memory exhausted | allocate past the limit → exit 137 | E4 |
| Data lost | `docker compose down -v` → counter resets | E7 |

A useful pattern: run the smoke test **while** something is broken, and
confirm it fails for the right reason.

```bash
docker compose stop cache
./scripts/smoke-test.sh
# FAIL  api -> redis round trip works (count= -> second=)
docker compose start cache
```

This is the difference between a test suite and a health check — one proves
the system works, the other proves your monitoring would notice when it
does not.

---

## 7. The full verification sequence

What "done" looks like for this project, as a single script:

```bash
# 1. Clean slate
docker compose down -v
docker compose up -d --build

# 2. All three healthy
docker compose ps

# 3. The automated checks
./scripts/smoke-test.sh

# 4. The experiments still produce the documented results
for e in scripts/experiments/e*.sh; do
  echo "=== $e ==="
  "$e" || echo "FAILED"
done

# 5. The stack is green again
docker compose up -d
./scripts/smoke-test.sh
```

Step 4 is the one people skip. It is also the one that catches an
accidental change — for example, if someone edits `nginx.conf` to remove
`resolve`, E1's 502 would silently become a permanent failure and nothing
else would notice.

---

**Next:** [07 — Troubleshooting](07-troubleshooting.md).
