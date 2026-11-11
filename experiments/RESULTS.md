# Experiment Results

Every row below is backed by a verbatim terminal capture in
[`docs/results/`](../docs/results/). No result is reconstructed from memory.

**Environment:** Docker 29.6.2 · Compose v5.3.1 · Darwin 25.6.0 arm64 (Docker
Desktop, linux/aarch64 containers)

**How to reproduce any row:**

```bash
./scripts/capture.sh <EXPERIMENT-ID> "./scripts/experiments/<script>.sh"
```

---

## Summary

| ID | Hypothesis | Result | Verdict |
|---|---|---|---|
| E1 | `stop` exits cleanly, `kill` exits 137 | `stop` → exit 0, proxy **504**; `kill` → exit 137, proxy **502** | **Confirmed, with a correction** |
| E2 | `always`/`unless-stopped` revive a killed container | No policy revived it — `restarts=0` everywhere | **Refuted** |
| E2b | An operator stop is what suppresses the policy | Natural death → restarts climb; `docker kill` → `restarts=0` | **Confirmed** |
| E2c | The event stream shows why | Natural death = `die`→`start`; `docker kill` = `kill`→`die` (no `start`) | **Confirmed** |
| E3 | `on-failure:5` caps at 5 restarts | Counter stopped at exactly 5, then `exited` | **Confirmed** |
| E4 | OOM → exit 137, `OOMKilled=true`, policy fires | exit 137, `oom=true`; container survives when only a child died | **Confirmed** |
| E5 | A broken config fails fast with a readable error | `[emerg] unknown directive` printed, container exits 1 | **Confirmed** |
| E6 | `service_healthy` avoids startup races | `service_started` → 3×503; `service_healthy` → 0 failures | **Confirmed** |
| E7 | The volume survives `down` but not `down -v` | 37 → 38 across `down`; back to 1 after `down -v` | **Confirmed** |
| E8 | A graceful reload drops zero requests | reload 0/751 failed; restart 16/838 failed | **Confirmed** |

---

## E1 — `stop` vs `kill`

**Hypothesis.** `docker compose stop` sends SIGTERM and lets the process shut
down cleanly (exit 0). `docker kill` sends SIGKILL, which cannot be
intercepted (exit 137).

**Command.** `./scripts/experiments/e1-stop-vs-kill.sh`
**Capture.** [`E1-stop-vs-kill-20261111-212736.txt`](../docs/results/E1-stop-vs-kill-20261111-212736.txt)

**Observed (verbatim):**

```
### baseline
running exit=0 oom=false restarts=0 error=
proxy /api/hello -> HTTP 200

### A) docker compose stop api   (SIGTERM, graceful)
exited exit=0 oom=false restarts=0 error=
proxy /api/hello -> HTTP 504

### B) docker compose start api  (bring it back)
running exit=0 oom=false restarts=0 error=
proxy /api/hello -> HTTP 502

### C) docker kill relistack-api   (SIGKILL, forced)
exited exit=137 oom=false restarts=0 error=
proxy /api/hello -> HTTP 502

### D) waiting 10s to see whether the restart policy revives it
exited exit=137 oom=false restarts=0 error=
proxy /api/hello -> HTTP 502
```

**Conclusion.** The exit codes behave exactly as predicted: SIGTERM → 0,
SIGKILL → 137. The *proxy status codes* were not what the plan expected, and
the reason turned out to matter (see E2b/E2c). The nginx error log explains
both:

```
[error] upstream timed out (110: Operation timed out) while connecting to upstream, ... upstream: "http://172.18.0.3:8000/api/hello"
[error] no live upstreams while connecting to upstream, ... upstream: "http://reli_api/api/hello"
```

* **504** — nginx still had the API's IP in its upstream pool and tried to
  connect; the TCP connect timed out (`proxy_connect_timeout 2s`).
* **502** — the upstream pool had no live members left, so nginx answered
  immediately with "no live upstreams".

**Correction to the plan.** The plan predicted 502 in both cases. The real
distinction is *timeout vs. no-upstream*, not *502 vs. 502* — and it is a
network-level detail, not a Docker one.

---

## E2 — The restart-policy matrix

**Hypothesis.** `no` stays dead; `on-failure`, `always` and `unless-stopped`
all revive a killed container.

**Command.** `./scripts/experiments/e2-restart-matrix.sh`
**Capture.** [`E2-restart-matrix-20261111-213112.txt`](../docs/results/E2-restart-matrix-20261111-213112.txt)

**Observed (verbatim, condensed — all four policies behaved identically):**

```
### policy: no
started:  running exit=0 restarts=0
-- SIGKILL (docker kill)
after kill: exited exit=137 restarts=0

### policy: on-failure
after kill: exited exit=137 restarts=0

### policy: always
after kill: exited exit=137 restarts=0

### policy: unless-stopped
after kill: exited exit=137 restarts=0
```

**Conclusion.** **Refuted.** Not one policy revived the container after
`docker kill` — not even `always`. The policy was demonstrably present
(`policy=always` in the container's `HostConfig`), so this was not a
misconfiguration. E2b isolated the cause.

---

## E2b — Why did no policy revive the container?

**Hypothesis.** Two candidates: (H1) the policy is broken, (H2) `docker kill`
counts as a *manual* stop, and Docker suppresses the restart policy for
manually stopped containers.

**Command.** `./scripts/experiments/e2b-why-no-restart.sh`
**Capture.** [`E2b-why-no-restart-20261111-213236.txt`](../docs/results/E2b-why-no-restart-20261111-213236.txt)

**Observed (verbatim):**

```
### A) process exits by itself with code 1
policy on the container: always
before:  status=restarting exit=1 restarts=5 policy=always
after:   status=restarting exit=1 restarts=7 policy=always

### B) process exits by itself with code 0
before:  status=restarting exit=0 restarts=5 policy=always
after:   status=restarting exit=0 restarts=7 policy=always

### C) SIGKILL sent from INSIDE the container
before:  status=running exit=0 restarts=0 policy=always
after:   status=running exit=0 restarts=0 policy=always

### D) docker kill from OUTSIDE
before:  status=running exit=0 restarts=0 policy=always
after:   status=exited exit=137 restarts=0 policy=always

### E) docker stop from OUTSIDE
before:  status=running exit=0 restarts=0 policy=always
after:   status=exited exit=137 restarts=0 policy=always
```

**Conclusion.** **H2 confirmed, H1 rejected.** When the process dies on its
own, the policy acts and `restarts` climbs (5 → 7). When an *operator* stops
the container from outside, `restarts` stays at 0 — Docker treats it as a
manual stop and does not apply the policy.

Case C is a separate mechanism: `kill -9 1` from *inside* the container does
nothing at all, because the kernel protects PID 1 of a PID namespace from
signals it has not explicitly handled.

---

## E2c — `docker events` ground truth

**Hypothesis.** The daemon's event stream shows exactly which lifecycle
transition caused the policy to be skipped.

**Command.** `./scripts/experiments/e2c-events-trace.sh`
**Capture.** [`E2c-events-trace-20261111-215853.txt`](../docs/results/E2c-events-trace-20261111-215853.txt)

**Observed (verbatim):**

```
# A) process exits by itself (exit 1), policy=always
--- docker events ---
1794412734 die
1794412734 start
1794412734 die
1794412734 start
...
final: status=restarting exit=1 restarts=8

# B) docker kill from outside, policy=always
--- docker events ---
1794412752 kill
1794412752 die
final: status=exited exit=137 restarts=0

# C) docker stop from outside, policy=always
--- docker events ---
1794412768 kill
1794412778 kill
1794412778 stop
1794412778 die
final: status=exited exit=137 restarts=0

# D) PID-1 signal protection: kill -9 1 from inside
after SIGTERM from inside: status=running exit=0 restarts=0
after SIGKILL from inside: status=running exit=0 restarts=0
```

**Conclusion.** The event stream is the decisive evidence:

| Death | Events | Policy applied? |
|---|---|---|
| Process dies on its own | `die` → `start` → `die` → `start` … | **Yes** |
| `docker kill` | `kill` → `die` | **No** |
| `docker stop` | `kill` → `stop` → `die` | **No** |

The `kill` event is the marker. When the daemon records a `kill` event, the
stop was operator-initiated and the restart policy is suppressed.

---

## E3 — Retry exhaustion (`on-failure:5`)

**Hypothesis.** A container that keeps exiting 1 will be restarted at most 5
times, then left `exited` with `RestartCount=5`.

**Command.** `./scripts/experiments/e3-retry-exhaustion.sh`
**Capture.** [`E3-retry-exhaustion-20261111-220027.txt`](../docs/results/E3-retry-exhaustion-20261111-220027.txt)

**Observed (verbatim):**

```
### watching the restart counter climb (15s window)
t=01s  restarting exit=1 restarts=4
t=02s  restarting exit=1 restarts=5
t=03s  restarting exit=1 restarts=5
t=04s  exited exit=1 restarts=5
t=05s  exited exit=1 restarts=5
...
t=15s  exited exit=1 restarts=5

### container logs (the crash message repeats once per attempt)
simulated crash
simulated crash
simulated crash
simulated crash
simulated crash
simulated crash

### restarting it manually resets the retry budget
restarting exit=1 restarts=5
```

**Conclusion.** Confirmed exactly. The counter rose 4 → 5 and stopped; the
container transitioned `restarting` → `exited` and stayed there. The logs
show six "simulated crash" lines (the initial start plus five restarts). A
manual `docker start` re-arms the budget.

---

## E4 — OOM kill

**Hypothesis.** Exceeding the memory limit gives exit 137, `OOMKilled=true`,
and the restart policy fires. Additionally: the OOM killer kills a *process*,
so a container whose PID 1 survives keeps running.

**Command.** `./scripts/experiments/e4-oom-kill.sh`
**Capture.** [`E4-oom-kill-20261111-220153.txt`](../docs/results/E4-oom-kill-20261111-220153.txt)

**Observed (verbatim):**

```
# A) PID 1 is the memory hog, 64 MB limit, --restart always
state: status=restarting exit=137 oom=true restarts=7 mem_limit=67108864

# B) the real compose api service (256M limit, on-failure:5)
before: status=running exit=0 oom=false restarts=0 mem_limit=268435456
after the child process allocated too much:
  status=running exit=0 oom=true restarts=0 mem_limit=268435456
  container still serving? 200

>>> KEY OBSERVATION: the container is still running.
>>> The OOM killer killed the child python process, NOT PID 1 (gunicorn).
>>> A container only exits when PID 1 dies.

# C) same 256M limit, but the hog IS PID 1 -> container exits 137
state: status=exited exit=137 oom=true restarts=5 mem_limit=268435456
exit code detail:
exit=137  oom=true  error=
```

**Conclusion.** Confirmed, and it revealed a distinction that the plan did not
anticipate:

* A **kernel-initiated** OOM death **does** trigger the restart policy —
  `restarts=7` in case A, `restarts=5` in case C. This is the opposite of the
  operator-initiated death in E2/E2b.
* In case B the container kept serving (`HTTP 200`) even though `oom=true`:
  the OOM killer took the child `python` process, not gunicorn (PID 1). Only
  the death of PID 1 ends a container.

**Bug found in the first run of this script** (kept in
[`first-run-errors/E4-oom-kill-20261111-220057.txt`](../docs/results/first-run-errors/E4-oom-kill-20261111-220057.txt)):
`import bytearray` fails — `bytearray` is a **builtin**, not a module:

```
ModuleNotFoundError: No module named 'bytearray'
```

---

## E5 — Broken NGINX configuration

**Hypothesis.** The fail-fast entrypoint turns a broken config into an
immediate, readable failure instead of a silent crash loop.

**Command.** `./scripts/experiments/e5-broken-config.sh`
**Capture.** [`E5-broken-config-20261111-220237.txt`](../docs/results/E5-broken-config-20261111-220237.txt)

**Observed (verbatim):**

```
### breaking nginx.conf inside the container
--- tail of the broken config ---
}

this_is_not_a_valid_directive;

### container logs (the [emerg] line is the real error)
[relistack] validating nginx configuration...
2026/11/11 16:02:38 [emerg] 7#7: unknown directive "this_is_not_a_valid_directive" in /etc/nginx/nginx.conf:82
nginx: [emerg] unknown directive "this_is_not_a_valid_directive" in /etc/nginx/nginx.conf:82
[relistack] validating nginx configuration...

### container state
status=restarting exit=1 restarts=5
proxy /healthz -> HTTP 000
```

**Conclusion.** Confirmed. The `[emerg]` line names the exact file and line
number, and the container exits 1 immediately rather than serving traffic
with a half-loaded config. Because the proxy has `restart: unless-stopped`,
the failure turns into a visible crash loop (`restarts=5`) rather than a
silent hang — the container is down and `curl` gets `HTTP 000`.

Recovery note: an in-container edit is **ephemeral**. `docker compose up -d
--force-recreate web` restored the correct config from the image.

---

## E6 — Dependency ordering

**Hypothesis.** `condition: service_started` lets the API start before Redis
is ready (→ 503s); `condition: service_healthy` waits for a real healthcheck
(→ no failures).

**Command.** `./scripts/experiments/e6-dependency-ordering.sh`
**Capture.** [`E6-dependency-ordering-20261111-220330.txt`](../docs/results/E6-dependency-ordering-20261111-220330.txt)

**Observed (verbatim):**

```
# A) condition: service_started   (Redis slow-starts by 8s)
t=01s    /api/count -> HTTP 503
t=02s    /api/count -> HTTP 503
t=03s    /api/count -> HTTP 503
t=04s    /api/count -> HTTP 200
t=05s    /api/count -> HTTP 200
...

# B) condition: service_healthy   (Redis slow-starts by 8s)
t=01s    /api/count -> HTTP 200
t=02s    /api/count -> HTTP 200
t=03s    /api/count -> HTTP 200
...
```

**Conclusion.** Confirmed. Both runs used the same slow-starting Redis; the
only difference was the `depends_on` condition.

* `service_started` → **3 failed requests (503)** during the startup window.
* `service_healthy` → **0 failed requests**.

This is the single most important reason to use health-gated dependencies:
without it, a slow dependency produces a window of 5xx errors that looks like
an outage even though every container is "running".

---

## E7 — Data persistence

**Hypothesis.** A named volume survives `docker compose down`; it does not
survive `down -v`.

**Command.** `./scripts/experiments/e7-persistence.sh`
**Capture.** [`E7-persistence-20261111-220502.txt`](../docs/results/E7-persistence-20261111-220502.txt)

**Observed (verbatim):**

```
### 1) set a known value
  /api/count -> {"container":"4d65f85ed150","count":37}
  redis key   -> 37

### 2) docker compose down  (containers removed, volumes KEPT)
  volume still present? relistack-redis-data

### 3) docker compose up   (containers recreated, volume reattached)
  /api/count -> {"container":"d3f1f22f655e","count":38}
  redis key   -> 38

### 4) docker compose down -v   (volumes REMOVED too)
  volume still present? []

### 5) docker compose up again (a brand new, empty volume)
  /api/count -> {"container":"5b634d9b060d","count":1}
  redis key   -> 1
```

**Conclusion.** Confirmed. The counter went 37 → 38 across a full `down`/`up`
cycle (the container id changed, proving the container really was replaced),
and reset to 1 only after `down -v`.

---

## E8 — Graceful reload vs hard restart

**Hypothesis.** `nginx -s reload` (SIGHUP) is invisible to clients;
`docker compose restart web` produces a window of failed requests.

**Command.** `./scripts/experiments/e8-reload-vs-restart.sh`
**Capture.** [`E8-reload-vs-restart-20261111-220659.txt`](../docs/results/E8-reload-vs-restart-20261111-220659.txt)

**Observed (verbatim):**

```
# A) graceful reload: docker compose exec web nginx -s reload
sending SIGHUP to the nginx master...
2026/11/11 16:07:02 [notice] 55#55: signal process started
requests: 751   failed: 0

# B) hard restart: docker compose restart web
restarting the container...
 Container relistack-web Restarting 
 Container relistack-web Started 
requests: 838   failed: 16

# summary
reload   : 0 failed out of 751
restart  : 16 failed out of 838
```

**Conclusion.** Confirmed. A graceful reload dropped **0 of 751** requests; a
hard restart dropped **16 of 838** (~1.9%).

**Bug found in the first run of this script** (kept in
[`first-run-errors/E8-reload-vs-restart-20261111-220610.txt`](../docs/results/first-run-errors/E8-reload-vs-restart-20261111-220610.txt)):
the summary printed the restart numbers for both cases because `read` reused
the same variable. The first run therefore *looked* like the reload had also
dropped 11 requests — which contradicted the raw per-case output above it.
The fix was to use separate variables.

---

## Smoke test baseline

```
$ ./scripts/smoke-test.sh
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
