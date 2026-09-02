#!/usr/bin/env bash
# Ensure a CI Postgres is available on CI_PG_PORT (default 5433).
#
# Usage:
#   ./ensure-ci-db.sh             # bring up CI Postgres (idempotent)
#   ./ensure-ci-db.sh --cleanup   # remove any container this script created
#
# Env (all optional):
#   CI_PG_PORT        host port (default 5433)
#   CI_PG_CONTAINER   container name (default ci-postgres)
#   CI_PG_IMAGE       image (default postgres:18-alpine)
#   CI_PG_DB          POSTGRES_DB (default ci)
#   CI_PG_USER        POSTGRES_USER (default ci)
#   CI_PG_PASSWORD    POSTGRES_PASSWORD (default ci)
#   CT                container runtime (default: docker, then podman)
#
# Detection order (--ensure mode):
#   0. Port held by a *different* container → if it looks like a stray CI
#      Postgres, remove it and re-create ours; otherwise fail loudly rather
#      than destroy somebody else's service.
#   1. Port already accepting connections → use it (self-hosted runners leave
#      the container running between jobs).
#   2. Port free → force-remove any stale named container and run a fresh one.

set -euo pipefail

PORT="${CI_PG_PORT:-5433}"
CONTAINER="${CI_PG_CONTAINER:-ci-postgres}"
PG_IMAGE="${CI_PG_IMAGE:-postgres:18-alpine}"
PG_DB="${CI_PG_DB:-ci}"
PG_USER="${CI_PG_USER:-ci}"
PW="${CI_PG_PASSWORD:-ci}"

_CT="$("$(dirname "$0")/container-runtime.sh")" || {
  echo "Error: no container runtime — install Docker, OrbStack, or Podman" >&2
  exit 1
}
_ct() { "$_CT" "$@"; }

_port_open() {
  (exec 3<>/dev/tcp/localhost/"${PORT}") 2>/dev/null
}

_pg_ready() {
  pg_isready -h localhost -p "${PORT}" -t 2 -q 2>/dev/null
}

if [[ "${1:-}" == "--cleanup" ]]; then
  _ct rm -f "$CONTAINER" 2>/dev/null || true
  exit 0
fi

_container_publishing_port() {
  _ct ps --filter "publish=${PORT}" --format '{{.Names}}' 2>/dev/null | head -1
}

if _port_open; then
  _holder="$(_container_publishing_port)"
  if [[ -n "$_holder" && "$_holder" != "$CONTAINER" ]]; then
    if [[ "$_holder" == *ci-postgres* ]]; then
      echo "ensure-ci-db: port ${PORT} is held by '${_holder}', not '${CONTAINER}' —" \
        "reclaiming a stray CI Postgres" >&2
      _ct rm -f "$_holder" >/dev/null 2>&1 || true
    else
      echo "ensure-ci-db: port ${PORT} is held by container '${_holder}', which is not" \
        "'${CONTAINER}' and does not look like a CI Postgres — refusing to remove it." >&2
      echo "ensure-ci-db: stop that container, or set CI_PG_PORT to a free port." >&2
      exit 1
    fi
  elif [[ "$_holder" == "$CONTAINER" ]]; then
    _img="$(_ct inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)"
    if [[ -n "$_img" && "$_img" != "$PG_IMAGE" ]]; then
      echo "ensure-ci-db: '${CONTAINER}' is running ${_img}, expected ${PG_IMAGE} —" \
        "recreating (the CI DB is ephemeral, so there is nothing to migrate)" >&2
      _ct rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
  fi
fi

if _port_open; then
  if ! command -v pg_isready >/dev/null 2>&1; then
    exit 0
  fi
  for i in $(seq 1 10); do
    if _pg_ready; then
      exit 0
    fi
    sleep 1
  done
  echo "ensure-ci-db: port ${PORT} is open but Postgres is NOT ready after 10 probes;" \
    "removing '${CONTAINER}' and re-creating it fresh" >&2
fi

_ct rm -f "$CONTAINER" 2>/dev/null || true
_ct run -d --name "$CONTAINER" --restart unless-stopped \
  -e POSTGRES_DB="$PG_DB" \
  -e POSTGRES_USER="$PG_USER" \
  -e POSTGRES_PASSWORD="$PW" \
  -p "${PORT}:5432" "$PG_IMAGE" \
  -c max_connections=500 \
  -c fsync=off \
  -c synchronous_commit=off \
  -c full_page_writes=off \
  2>/dev/null \
  || true

if command -v pg_isready >/dev/null 2>&1; then
  _ready() { _pg_ready; }
else
  _ready() { _port_open; }
fi

echo "ensure-ci-db: waiting for CI Postgres on localhost:${PORT} (up to 30s)…" >&2
for i in $(seq 1 30); do
  if _ready; then
    echo "ensure-ci-db: CI Postgres ready within ${i}s" >&2
    exit 0
  fi
  sleep 1
done

echo "Error: CI Postgres not ready on localhost:${PORT} after 30s" >&2
exit 1
