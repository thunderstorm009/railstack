"""ReliStack API — minimal Flask service backed by Redis.

Three endpoints, each with a distinct purpose in the chaos lab:

  GET /healthz    liveness probe. Deliberately does NOT touch Redis, so a Redis
                  outage cannot mark the API unhealthy (see docs/02).
  GET /api/hello  returns the container hostname, proving the request really
                  reached a container and not the host.
  GET /api/count  increments a Redis counter; also the persistence probe for
                  the named-volume experiment (E7).
"""

import os
import socket

import redis
from flask import Flask, jsonify

REDIS_HOST = os.getenv("REDIS_HOST", "cache")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
COUNTER_KEY = os.getenv("COUNTER_KEY", "reli:count")

app = Flask(__name__)

# Decode responses so the value comes back as str, not bytes.
redis_client = redis.Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    decode_responses=True,
    socket_connect_timeout=2,
    socket_timeout=2,
)


@app.get("/healthz")
def healthz():
    """Liveness only — no dependency checks. See module docstring."""
    return jsonify({"status": "ok"}), 200


@app.get("/api/hello")
def hello():
    """Echo the container hostname so callers can identify the instance."""
    return (
        jsonify(
            {
                "message": "hello from reli-api",
                "container": socket.gethostname(),
                "service": "api",
            }
        ),
        200,
    )


@app.get("/api/count")
def count():
    """Increment and return the Redis-backed counter.

    A Redis failure is translated into a 503 so the failure is visible at the
    proxy as a 503 rather than an opaque 500.
    """
    try:
        value = redis_client.incr(COUNTER_KEY)
    except redis.RedisError as exc:
        return jsonify({"error": "cache_unavailable", "detail": str(exc)}), 503
    return jsonify({"count": value, "container": socket.gethostname()}), 200


if __name__ == "__main__":
    # Bind 0.0.0.0 so the container is reachable from outside its namespace.
    app.run(host="0.0.0.0", port=8000)
