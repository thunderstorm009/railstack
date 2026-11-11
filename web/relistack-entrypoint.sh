#!/bin/sh
# Fail-fast NGINX entrypoint.
#
# What it does : validates the configuration with `nginx -t` before handing
#                control to the official NGINX entrypoint.
# Why we need it: without it a broken nginx.conf makes the container exit with
#                an opaque error and, under a restart policy, produce an
#                endless crash loop that hides the real message.
# How it works  : `nginx -t` parses the config and exits non-zero on any
#                syntax or reference error. `set -e` makes that exit the
#                container immediately, and `exec` replaces this shell with
#                NGINX so NGINX becomes PID 1 and receives SIGTERM directly.
set -e

echo "[relistack] validating nginx configuration..."
nginx -t

echo "[relistack] configuration OK, starting nginx"
exec /docker-entrypoint.sh "$@"
