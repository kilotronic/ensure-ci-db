#!/usr/bin/env bash
# What ensure-ci-db.sh decides for each state of the port, with a mock container runtime and pg_isready and a
# real listening socket standing in for the port. No Docker daemon needed.
#   - a port held by someone else's container is refused, and that container is left alone;
#   - a stray CI Postgres on the port is reclaimed; ours is reused, or recreated when the image changed or
#     Postgres never becomes ready;
#   - a fresh container gets the configured database, user, password, port and image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  fails=$((fails + 1))
}

T=$(mktemp -d)
listener=""
stop_listener() { if [ -n "$listener" ]; then
  kill "$listener" 2>/dev/null || true
  wait "$listener" 2>/dev/null || true
  listener=""
fi; }
trap 'stop_listener; rm -rf "$T"' EXIT

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
listen() { # hold PORT open, as a running container would
  python3 -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(600)' "$PORT" &
  listener=$!
  echo "$listener" >"$T/listener.pid"
  for _ in $(seq 1 50); do
    (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && return 0
    python3 -c 'import time; time.sleep(0.1)'
  done
  echo "listener did not start" >&2
  exit 1
}

# Mock runtime: logs every call; `ps` answers with $T/holder, `inspect` with $T/image; `rm` of the holder frees
# the port; `run` marks Postgres ready when $T/run-makes-ready exists. Mock pg_isready: ready when $T/ready exists. sleep is instant.
mkdir -p "$T/bin"
cat >"$T/bin/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$T/log"
case "\$1" in
  ps) cat "$T/holder" 2>/dev/null ;;
  inspect) cat "$T/image" 2>/dev/null ;;
  run) [ -e "$T/run-makes-ready" ] && touch "$T/ready" ;;
  rm) # removing the container holding the port frees it
    if [ "\$3" = "\$(cat "$T/holder" 2>/dev/null)" ] && [ -e "$T/listener.pid" ]; then
      # Postgres is gone at once, even if the port takes a moment to close.
      kill "\$(cat "$T/listener.pid")"; rm -f "$T/listener.pid" "$T/ready" || exit 97
    fi ;;
esac
exit 0
EOF
cat >"$T/bin/pg_isready" <<EOF
#!/bin/sh
test -e "$T/ready"
EOF
printf '#!/bin/sh\nexit 0\n' >"$T/bin/sleep"
chmod +x "$T/bin/"*
# Only these tools on PATH, so the host's own docker or pg_isready is never used.
mkdir -p "$T/sys" "$T/sys-no-pg"
for tool in bash dirname head seq cat printf touch rm; do
  ln -s "$(command -v "$tool")" "$T/sys/$tool"
  ln -s "$(command -v "$tool")" "$T/sys-no-pg/$tool"
done
for tool in docker sleep; do ln -s "$T/bin/$tool" "$T/sys-no-pg/$tool"; done

# reset <holder> <image> <ready: yes|no> <run-makes-ready: yes|no> <port: open|closed>
reset() {
  stop_listener
  : >"$T/log"
  rm -f "$T/holder" "$T/image" "$T/ready" "$T/run-makes-ready"
  [ -n "$1" ] && echo "$1" >"$T/holder"
  [ -n "$2" ] && echo "$2" >"$T/image"
  [ "$3" = yes ] && touch "$T/ready"
  [ "$4" = yes ] && touch "$T/run-makes-ready"
  [ "$5" = open ] && listen
  return 0
}
# ensure [cli args]: run the script with this test's port and container settings; sets $rc.
ensure() {
  rc=0
  env -i PATH="${TEST_PATH:-$T/bin:$T/sys}" HOME="$T" CI_PG_PORT="$PORT" CI_PG_CONTAINER=ci-postgres-test \
    CI_PG_IMAGE=postgres:18-alpine CI_PG_DB=appdb CI_PG_USER=appuser CI_PG_PASSWORD=apppw \
    bash "$ROOT/ensure-ci-db.sh" "$@" >"$T/out" 2>&1 || rc=$?
}
called() { grep -q -- "$1" "$T/log"; }
check() { # check <name> <condition...>
  local name=$1
  shift
  if "$@"; then pass "$name"; else
    fail "$name"
    sed 's/^/     log: /' "$T/log"
    sed 's/^/     out: /' "$T/out"
  fi
}
not() { ! "$@"; }

# --- Someone else's container on the port: refuse, and leave it alone.
reset redis-cache "" yes no open
ensure
check "a foreign container on the port is refused" test "$rc" = 1
check "the foreign container is not removed" not called "rm -f redis-cache"
check "no container is started over it" not called "^run "
check "the refusal says why" grep -q "refusing to remove it" "$T/out"

# --- A stray CI Postgres under another name: reclaim the port.
reset old-ci-postgres-1 "" yes yes open
ensure
check "a stray CI Postgres is removed" called "^rm -f old-ci-postgres-1$"
check "and ours is started in its place" called "^run -d --name ci-postgres-test "

# --- Our own container, the right image, Postgres ready: reuse it.
reset ci-postgres-test postgres:18-alpine yes no open
ensure
check "a ready container of ours is reused" test "$rc" = 0
check "it is not removed" not called "^rm "
check "nothing new is started" not called "^run "

# --- Our own container on another image: recreate it.
reset ci-postgres-test postgres:16-alpine yes yes open
ensure
check "our container on another image is removed" called "^rm -f ci-postgres-test$"
check "and run again on the configured image" called "^run .* postgres:18-alpine "

# --- Port open but Postgres never ready: recreate.
reset ci-postgres-test postgres:18-alpine no yes open
ensure
check "an unready Postgres is recreated" called "^run "
check "and the run succeeds once it is ready" test "$rc" = 0

# --- Port free: a fresh container with the configured settings.
reset "" "" no yes closed
ensure
check "a free port gets a fresh container" test "$rc" = 0
check "any stale container of ours is removed first" called "^rm -f ci-postgres-test$"
check "it is named and restarts" called "^run -d --name ci-postgres-test --restart unless-stopped "
check "it gets the database" called "-e POSTGRES_DB=appdb "
check "it gets the user" called "-e POSTGRES_USER=appuser "
check "it gets the password" called "-e POSTGRES_PASSWORD=apppw "
check "it publishes the port to 5432" called "-p $PORT:5432 postgres:18-alpine "

# --- Port free and Postgres never comes up: fail.
reset "" "" no no closed
ensure
check "a Postgres that never becomes ready fails" test "$rc" = 1
check "the failure says so" grep -q "not ready on localhost:$PORT" "$T/out"

# --- No pg_isready: an open port counts as ready.
reset ci-postgres-test postgres:18-alpine no no open
TEST_PATH="$T/sys-no-pg" ensure
check "without pg_isready an open port is reused" test "$rc" = 0
check "without pg_isready nothing new is started" not called "^run "

# --- Cleanup removes our container only.
reset "" "" no no closed
ensure --cleanup
check "cleanup succeeds" test "$rc" = 0
check "cleanup removes our container" test "$(cat "$T/log")" = "rm -f ci-postgres-test"

# --- The Action's run step: the cleanup input, and inputs reaching the script.
action() { # action <cleanup>: action.yml's run step with its inputs filled in
  python3 - "$ROOT/action.yml" "$1" <<'PY' >"$T/step.sh"
import re, sys
text = open(sys.argv[1]).read().split("run: |", 1)[1]
print(re.sub(r"\$\{\{ inputs\.cleanup \}\}", sys.argv[2], text))
PY
  rc=0
  env -i PATH="$T/bin:$T/sys" HOME="$T" GITHUB_ACTION_PATH="$ROOT" CI_PG_PORT="$PORT" CI_PG_CONTAINER=ci-postgres-test \
    CI_PG_IMAGE=postgres:18-alpine bash "$T/step.sh" >"$T/out" 2>&1 || rc=$?
}
reset "" "" no no closed
action true
check "the cleanup input cleans up" test "$(cat "$T/log")" = "rm -f ci-postgres-test"
reset "" "" no yes closed
action false
check "without cleanup the Action ensures the database" called "^run "
if grep -q "CI_PG_DB: \${{ inputs.database }}" "$ROOT/action.yml" \
  && grep -q "CI_PG_USER: \${{ inputs.user }}" "$ROOT/action.yml" \
  && grep -q "CI_PG_PASSWORD: \${{ inputs.password }}" "$ROOT/action.yml" \
  && grep -q "CI_PG_PORT: \${{ inputs.port }}" "$ROOT/action.yml" \
  && grep -q "CI_PG_IMAGE: \${{ inputs.image }}" "$ROOT/action.yml" \
  && grep -q "CI_PG_CONTAINER: \${{ inputs.container }}" "$ROOT/action.yml"; then
  pass "every input reaches the script's environment"
else
  fail "every input reaches the script's environment"
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
