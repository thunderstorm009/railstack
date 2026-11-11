# 08 — Lessons learned

> **What this chapter covers:** the mental models that survived contact with a
> real daemon, the two predictions that turned out to be wrong, the mistakes
> made along the way, and what I would do differently.

---

## 1. The five lab concepts, mapped onto a real stack

The original labs taught the mechanics. This project is where they became
decisions.

| Lab | Lab mechanic | The real decision | Why the decision changed |
|---|---|---|---|
| Running NGINX in a container | `docker run -p 8080:80 nginx` | NGINX as a **reverse proxy** with a named upstream, `resolve`, and keepalive | A proxy has a config surface of its own — and therefore its own failure modes |
| Container lifecycle management | `docker start/stop/restart` | `stop` vs `kill` as a *design choice* per failure type | E1 showed the exit codes and the proxy's differing responses (504 vs 502) |
| `docker stop` vs `docker kill` | SIGTERM vs SIGKILL | Use `stop` for graceful shutdowns, `kill` only to simulate a crash | `kill` is indistinguishable from an OOM kill by exit code alone |
| Restart policies | `--restart always` | `on-failure:5` for the API, `unless-stopped` for the proxy | E2/E2b proved the policy does **not** fire on an operator stop |
| Automatic container restart | watch it come back | A **bounded** retry budget | E3: an unbounded policy is an infinite crash loop |

The conceptual jump in every row: from *"this command does X"* to *"this is
the right setting for this service, and here is what it does when it
fails"*.

---

## 2. The two predictions that were wrong

This is the most valuable part of the project. Both corrections came from
measuring instead of assuming.

### Correction 1 — A restart policy does not fire on an operator stop

**What I expected.** `docker kill` on a container with `--restart always`
would bring it back. The plan's E2 row predicted: "`always` → restarts".

**What actually happened.**

```
### policy: always
after kill: exited exit=137 restarts=0
```

Not one policy revived it — not even `always`.

**How I found out.** The first hypothesis was that the policy had not been
applied. E2b ruled that out by varying *how* the container died while
holding the policy at `always`:

```
### A) process exits by itself with code 1
after:   status=restarting exit=1 restarts=7 policy=always     <-- policy acted
### D) docker kill from OUTSIDE
after:   status=exited exit=137 restarts=0 policy=always        <-- policy suppressed
```

E2c then proved the mechanism with the daemon's own event stream:

```
# natural death:  die -> start -> die -> start     (policy applies)
# docker kill:    kill -> die                      (policy suppressed)
```

The `kill` event is the marker for "a human did this".

**Why it matters.** It completely changes how you think about `always`. It
does not mean "always comes back". It means "always comes back **unless
somebody stopped it**". Which is correct behaviour — you do not want a
service fighting an operator who deliberately took it down — but it is
nothing like the mental model most people carry.

### Correction 2 — 504 and 502 are different diagnoses

**What I expected.** The plan predicted 502 from the proxy whenever the API
was down.

**What actually happened.** 504 first, then 502.

**How I found out.** The nginx error log explained it: the first request
timed out connecting to the API's IP (504), and later requests hit an
upstream pool with no live members (502).

**Why it matters.** "502 = API is down" is a useful shortcut, but it
collapses two different failure modes into one. The accurate reading is:

| Code | nginx's meaning | What to check |
|---|---|---|
| **502** | "no live upstreams" — the pool is empty | Is the API container running at all? |
| **504** | "upstream timed out" — the pool had a member that did not answer | Is the API running but wedged / overloaded? |

### The meta-lesson

Both corrections were found by **writing down a hypothesis and then testing
it**, not by reading more documentation. In both cases my prior belief was
reasonable and wrong. The experiment that corrected me was also the one
that produced the most quotable finding in the project — the `docker events`
trace.

If I had "tested" only what I already believed, both corrections would have
become wrong documentation.

---

## 3. Mental models that survived

### "The container is running" ≠ "the container is ready"

`docker compose ps` showing `Up` means a process exists. It says nothing
about whether that process can serve traffic. E6 measured the difference:
**3 HTTP 503 responses** during startup with `service_started`, and **zero**
with `service_healthy`.

This is the concept I would put first in any Docker onboarding, because it
causes a 5xx window on *every single deploy*.

### The healthcheck should test the service, not its dependencies

The API's `/healthz` deliberately does not touch Redis. If it did, a cache
outage would mark the API unhealthy, and Compose would refuse to start the
proxy — turning a partial outage into a total one, and deleting your
diagnostic signal.

A healthcheck answers: *"can this process do its job?"* — not *"is the whole
world healthy?"*

### Exit codes are the cheapest diagnosis in Docker

`docker inspect --format '{{.State.ExitCode}} {{.State.OOMKilled}}' <c>`
answers "what happened?" in one call. Exit 137 + `OOMKilled=true` is an
out-of-memory kill; exit 137 + `OOMKilled=false` is somebody ran
`docker kill`.

### A bounded retry is better than an infinite one

`on-failure:5` converts an invisible infinite crash loop into a container
sitting at `exited` with `RestartCount=5` — visible in `docker compose ps`,
with the error in the logs.

### `exec` in the entrypoint is not optional

Without `exec`, the wrapper shell stays PID 1 and the real server never
receives SIGTERM. Then `docker stop` escalates to SIGKILL after the grace
period, and your graceful shutdown becomes a hard kill. With `exec`, nginx
is PID 1 and gets the signal directly — the same reason the API uses
gunicorn rather than `python app.py`.

### The OOM killer kills a process, not a container

E4 case B: the container kept serving (`HTTP 200`) while `oom=true`,
because the victim was a child process and gunicorn (PID 1) survived. Only
PID 1's death ends a container.

---

## 4. Mistakes I made

### Mistakes in the code

| Mistake | Symptom | Fix |
|---|---|---|
| `USER appuser` on a slim base image | `unable to find user appuser` | Create the user with a fixed uid |
| `import bytearray` | `ModuleNotFoundError` | It is a builtin, not a module |
| `docker events --timeout` | `unknown flag` | No such flag in v29 — background and kill by PID |
| `timeout 20 docker events` | `command not found` | GNU coreutils only; macOS has none |
| `read` into one variable twice | The summary printed the restart numbers for both cases | One variable per measurement |
| `tail` on the nginx error log | The command hung forever | The log is a symlink to `/dev/stderr`; use `docker compose logs` |

### Mistakes in my reasoning

| Mistake | How I corrected it |
|---|---|
| Assuming `always` always restarts | E2b/E2c isolated the real rule |
| Assuming the API would be auto-restarted after `docker kill` in E1 | E1's own output showed `restarts=0` |
| Predicting 502 where the real answer was 504 then 502 | Read the nginx error log |
| Expecting the OOM experiment to kill the compose service | Realised the victim was a child process, not PID 1 |

**The pattern.** Every single one of these was caught by looking at real
output instead of reasoning from the documentation. Not one was caught by
reading more docs — which is the strongest argument for the chaos-lab
approach in the first place.

---

## 5. What I would do differently

### Keep the first-run captures

I nearly deleted the failed captures to keep `docs/results/` tidy. I kept
them in `docs/results/first-run-errors/` instead, and that turned out to be
worth more than tidiness: the `ModuleNotFoundError` capture is the clearest
possible illustration of "the container restarted 7 times but the experiment
never actually ran".

**A failed experiment is evidence too.** Deleting it hides a real mistake.

### Test the hypothesis before the experiment

E2 was written with the expectation baked in ("`always` restarts"). It came
back with all four policies identical, and I had to spend two more
experiments (E2b, E2c) working out why.

If E2 had been written as *"run all four policies and record the outcome"*
without a predicted result baked into the script, the surprise would have
shown up in the first run rather than the third.

### Write the documentation as you go

The documentation in `docs/` quotes output that was captured hours earlier.
Anything I could not quote, I did not claim. The chapters were written from
`docs/results/`, not from memory — which is exactly why they contain
specific numbers (0 of 751, 16 of 838, 37 → 38) rather than vague ones
("almost none failed").

### Budget for the surprises

The two corrections cost roughly 40 minutes of the 5-hour budget. That is
exactly the kind of time that must come *out of* the documentation block,
not out of the testing block. The schedule's rule — "if block 6 would
overrun, shorten chapters 02 and 04" — exists for this reason.

### Use `docker events` more often

`docker events` was the single most useful diagnostic tool in the project.
It is the daemon's own account of what it did, in order, with no
interpretation from me. Every time I reached for it instead of reasoning
about Docker's behaviour, I got the answer in one step.

---

## 6. If I had five hours again

**What I would keep unchanged:**

- The three-service shape. It is the minimum that produces two independent
  failure surfaces.
- Health-gated dependencies. Highest measured value of any single decision
  (3 failures → 0).
- The fail-fast NGINX entrypoint. Four lines of shell that turned a silent
  crash loop into one readable line.
- Capturing real output into `docs/results/` from the start.
- The chaos-lab structure: one script per experiment, each with a printed
  hypothesis.

**What I would change:**

- **Write E2 without a baked-in expectation.** It would have found the
  manual-stop rule in one run instead of three.
- **Use `docker events` from the first experiment.** It is the ground truth
  and it costs nothing.
- **Add a ninth experiment: `docker update --restart`.** Changing a policy
  on a running container without downtime is a genuinely useful operation
  that I only read about.
- **Spend ten minutes on `docker compose config`** at the start. It renders
  the merged configuration and would have shown the exact healthcheck
  commands before the first build.
- **Keep a running clock in `experiments/RESULTS.md`.** The plan asked for
  actual elapsed times per block, and I did not record them — the one
  deliverable I dropped.

---

## 7. The ten sentences I would say to another engineer

If someone asked "what did you learn?", this is the summary:

1. A restart policy fires for crashes and OOM kills — **not** for operator
   stops. `docker events` shows `die`→`start` versus `kill`→`die`.
2. `docker stop` → exit 0, `docker kill` → exit 137, OOM → 137 plus
   `OOMKilled=true`. That last flag is the only way to tell the two apart.
3. `depends_on: service_healthy` eliminated every startup 503. Plain
   `depends_on` only waits for the container to exist.
4. A healthcheck must not depend on the service's own dependencies, or one
   outage cascades.
5. The OOM killer kills a process. Only PID 1's death ends a container.
6. `on-failure:5` beats an infinite retry loop: the container ends up
   visibly `exited` instead of spinning.
7. `exec` in an entrypoint keeps your server as PID 1, so `docker stop` is
   actually graceful.
8. A named volume survives `down` and dies with `down -v`. The counter went
   37 → 38, then back to 1.
9. `nginx -s reload` dropped 0 of 751 requests; a container restart dropped
   16 of 838.
10. Write the hypothesis down before you run the experiment. Twice my
    expectation was wrong, and both times the correction was the most useful
    thing I learned.

---

**Back to:** [README](../README.md) ·
[Experiments summary](../experiments/RESULTS.md) ·
[Architecture](01-architecture.md)
