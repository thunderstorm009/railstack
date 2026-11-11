# syntax=docker/dockerfile:1
#
# ReliStack API — single-stage image for a pure-Python service.
#
# Why single-stage? There is nothing to compile and no build-time artefact to
# keep, so a builder stage would only add layers and download the dependencies
# twice. That trade-off flips for compiled languages (see docs/03).

FROM python:3.12-slim

# PYTHONUNBUFFERED=1 makes stdout unbuffered, so Flask's logs reach
# `docker compose logs` immediately instead of sitting in a buffer.
# PYTHONDONTWRITEBYTECODE=1 stops .pyc files being written into the layer.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    REDIS_HOST=cache \
    REDIS_PORT=6379

WORKDIR /app

# Copy requirements first: as long as this file is unchanged, pip's layer is
# reused from the build cache on rebuild. Copying the app code first would
# invalidate the dependency layer on every source edit.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as a non-root user.
#
# The `python:3.12-slim` base image ships NO regular user account (only
# `nobody`, uid 65534, with a nologin shell and no home). Attempting
# `USER appuser` therefore fails at container start with:
#   unable to find user appuser: no matching entries in passwd file
# So we create a dedicated account with a fixed uid/gid. A fixed uid matters:
# a random uid would make the mounted volume's file ownership unpredictable.
RUN groupadd --gid 1000 reli \
    && useradd --uid 1000 --gid 1000 --create-home --shell /usr/sbin/nologin reli \
    && chown -R reli:reli /app

USER reli

EXPOSE 8000

# Image-level healthcheck. It survives `docker run` without Compose, so the
# image is self-describing. Compose also defines a healthcheck — the two must
# stay in sync (see docs/02, "Healthcheck").
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz')" || exit 1

# Gunicorn with one worker: the restart-policy experiments need the process
# that receives SIGTERM to be PID 1. `python app.py` would also work, but
# Gunicorn handles signals properly and is what a real deployment would use.
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "1", "--access-logfile", "-", "app:app"]
