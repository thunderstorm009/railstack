#!/usr/bin/env bash
#
# chaos.sh — one-shot failure injector for the ReliStack chaos lab.
#
# What it does  : deliberately breaks one part of the stack so you can observe
#                how Docker reacts, then (optionally) repairs it.
# Why we need it: restart policies and healthchecks are only meaningful once
#                you have seen a container actually die. This script makes that
#                reproducible with one command.
# How it works  : each subcommand performs one specific, documented failure
#                mode. Every subcommand prints what it is about to do, runs
#                the destructive action, and tells you which command to use
#                next to observe the result.
#
# Usage:
#   ./scripts/chaos.sh <subcommand>
#
# Subcommands:
#   kill-api       SIGKILL the api container          -> exit 137
#   stop-api       SIGTERM the api container          -> graceful exit
#   crash-api      make the api crash-loop            -> retry exhaustion
#   oom-api        exceed the api memory limit        -> exit 137, OOMKilled
#   bad-config     break the nginx config              -> fail-fast exit
#   stop-cache     stop Redis                          -> api returns 503
#   reload-web     graceful nginx reload               -> zero downtime
#   restart-web    hard restart of the proxy           -> brief downtime
#   status         show the current state of the stack
#   recover        restore the stack to a healthy state
#
set -euo pipefail

COMPOSE="${COMPOSE:-docker compose}"
PROJECT_NAME="${PROJECT_NAME:-relistack}"
API="relistack-api"
WEB="relistack-web"
CACHE="relistack-cache"

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
cyan()  { printf '\033[36m%s\033[0m\n' "$1"; }

need_stack() {
  if ! $COMPOSE -p "$PROJECT_NAME" ps --status running --quiet | grep -q .; then
    red "No running stack found. Start it with: $COMPOSE -p $PROJECT_NAME up -d --build"
    exit 1
  fi
}

cmd_kill_api() {
  need_stack
  bold "E1 — sending SIGKILL to $API"
  cyan "docker kill sends SIGKILL (9): the process cannot clean up and is gone instantly."
  docker kill "$API"
  echo
  cyan "Observe it:"
  echo "  docker inspect --format '{{.State.ExitCode}} {{.State.OOMKilled}} {{.RestartCount}}' $API"
  cyan "  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/api/hello"
}

cmd_stop_api() {
  need_stack
  bold "E1 — sending SIGTERM to $API via docker compose stop"
  cyan "docker compose stop sends SIGTERM (15) and waits up to --timeout for a graceful exit."
  $COMPOSE -p "$PROJECT_NAME" stop api
  echo
  cyan "Observe it:"
  echo "  docker inspect --format '{{.State.ExitCode}} {{.State.OOMKilled}} {{.RestartCount}}' $API"
}

cmd_crash_api() {
  need_stack
  bold "E3 — making $API crash-loop"
  cyan "We replace the container's command with one that exits immediately with code 1."
  cyan "restart: on-failure:5 means Docker will retry 5 times, then give up."
  $COMPOSE -p "$PROJECT_NAME" stop api >/dev/null 2>&1 || true
  # `docker compose run` would create a second container; instead we recreate
  # the api service with a crashing command.
  $COMPOSE -p "$PROJECT_NAME" run -d --name "${API}-crash" \
    --entrypoint "sh" api -c "echo 'simulated crash' >&2; exit 1" >/dev/null
  echo "Crash container started: ${API}-crash"
  echo
  cyan "Observe it:"
  echo "  docker logs -f ${API}-crash"
  echo "  docker inspect --format '{{.RestartCount}} {{.State.Status}}' ${API}-crash"
}

cmd_oom_api() {
  need_stack
  bold "E4 — forcing an OOM kill on $API"
  cyan "We ask for far more memory than the container limit allows."
  cyan "The cgroup OOM killer terminates the process: exit code 137, OOMKilled=true."
  $COMPOSE -p "$PROJECT_NAME" exec -T api python -c "
import bytearray
chunks = []
while True:
    chunks.append(bytearray(64 * 1024 * 1024))
" || true
  echo
  cyan "Observe it:"
  echo "  docker inspect --format '{{.State.ExitCode}} {{.State.OOMKilled}} {{.RestartCount}}' $API"
}

cmd_bad_config() {
  need_stack
  bold "E5 — breaking the NGINX configuration"
  cyan "We write a syntactically invalid directive into the live nginx.conf."
  cyan "The fail-fast entrypoint runs 'nginx -t' first, so the container exits"
  cyan "immediately with a clear error instead of looping silently."
  $COMPOSE -p "$PROJECT_NAME" exec -T web sh -c \
    "cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak && printf 'this_is_not_a_valid_directive;\n' >> /etc/nginx/nginx.conf"
  echo "Config broken. Restarting the proxy to make it re-read the file..."
  $COMPOSE -p "$PROJECT_NAME" restart web || true
  echo
  cyan "Observe it:"
  echo "  $COMPOSE -p $PROJECT_NAME logs --tail=20 web"
  echo "  $COMPOSE -p $PROJECT_NAME ps"
  red "  Recovery: ./scripts/chaos.sh recover"
}

cmd_stop_cache() {
  need_stack
  bold "Dependency failure — stopping $CACHE"
  cyan "Redis is down but the API is still running. The API must return 503"
  cyan "rather than crash — that is a dependency failure, not a process failure."
  $COMPOSE -p "$PROJECT_NAME" stop cache
  echo
  cyan "Observe it:"
  echo "  curl -s -w '\n%{http_code}\n' http://localhost:8080/api/count"
  echo "  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/api/hello"
}

cmd_reload_web() {
  need_stack
  bold "E8 — graceful reload of $WEB"
  cyan "nginx -s reload sends SIGHUP: the master keeps serving and workers"
  cyan "are replaced one by one. Expect zero failed requests."
  $COMPOSE -p "$PROJECT_NAME" exec -T web nginx -s reload
  echo "Reload signal sent."
}

cmd_restart_web() {
  need_stack
  bold "E8 — hard restart of $WEB"
  cyan "Unlike a reload, this kills the container entirely. Expect a short"
  cyan "window of connection-refused errors from clients."
  $COMPOSE -p "$PROJECT_NAME" restart web
}

cmd_status() {
  bold "Stack status"
  $COMPOSE -p "$PROJECT_NAME" ps
  echo
  bold "Restart counts and exit codes"
  for c in "$API" "$WEB" "$CACHE"; do
    if docker inspect "$c" >/dev/null 2>&1; then
      docker inspect --format '{{.Name}}  status={{.State.Status}}  health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}  exit={{.State.ExitCode}}  oom={{.State.OOMKilled}}  restarts={{.RestartCount}}' "$c"
    fi
  done
}

cmd_recover() {
  bold "Recovering the stack"
  # Restore a possibly broken nginx.conf before recreating anything.
  $COMPOSE -p "$PROJECT_NAME" exec -T web sh -c \
    "if [ -f /etc/nginx/nginx.conf.bak ]; then mv /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf; echo 'nginx.conf restored'; fi" \
    2>/dev/null || true
  # Remove any crash-loop experiment containers.
  docker rm -f "${API}-crash" >/dev/null 2>&1 || true
  $COMPOSE -p "$PROJECT_NAME" up -d --build
  echo
  bold "Waiting for healthchecks..."
  for i in $(seq 1 30); do
    unhealthy="$($COMPOSE -p "$PROJECT_NAME" ps --format '{{.Service}} {{.Health}}' 2>/dev/null | grep -v healthy | grep -E 'cache|api|web' || true)"
    if [ -z "$unhealthy" ]; then
      green "All services healthy."
      break
    fi
    sleep 2
  done
  cmd_status
}

case "${1:-}" in
  kill-api)     cmd_kill_api ;;
  stop-api)     cmd_stop_api ;;
  crash-api)    cmd_crash_api ;;
  oom-api)      cmd_oom_api ;;
  bad-config)   cmd_bad_config ;;
  stop-cache)   cmd_stop_cache ;;
  reload-web)   cmd_reload_web ;;
  restart-web)  cmd_restart_web ;;
  status)       cmd_status ;;
  recover)      cmd_recover ;;
  *)
    sed -n 's/^#   //p' "$0" | sed -n '1,20p'
    exit 1
    ;;
esac
