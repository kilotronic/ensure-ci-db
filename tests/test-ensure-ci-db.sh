#!/usr/bin/env bash
# Unit tests that never need a real Docker daemon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
pass() { echo "ok - $*"; }
fail() {
  echo "not ok - $*"
  FAIL=1
}

# --cleanup records rm -f <container>
MOCK=$(mktemp -d)
trap 'rm -rf "$MOCK"' EXIT
cat >"$MOCK/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_LOG}"
exit 0
EOF
chmod +x "$MOCK/docker"
export PATH="$MOCK:$PATH"
export MOCK_LOG="$MOCK/log"
: >"$MOCK_LOG"
CI_PG_CONTAINER=my-ci-db bash "$ROOT/ensure-ci-db.sh" --cleanup
if grep -qx "rm -f my-ci-db" "$MOCK_LOG"; then
  pass "cleanup uses CI_PG_CONTAINER"
else
  fail "cleanup log: $(cat "$MOCK_LOG")"
fi

# CT= override
: >"$MOCK_LOG"
cat >"$MOCK/customct" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_LOG}"
exit 0
EOF
chmod +x "$MOCK/customct"
CT="$MOCK/customct" CI_PG_CONTAINER=x bash "$ROOT/ensure-ci-db.sh" --cleanup
if grep -qx "rm -f x" "$MOCK_LOG"; then
  pass "CT= override is honoured"
else
  fail "CT log: $(cat "$MOCK_LOG")"
fi

# container-runtime.sh
got="$("$ROOT/container-runtime.sh")" || true
if [[ -n "$got" ]]; then
  pass "container-runtime.sh found $got"
else
  fail "container-runtime.sh exited 1 with docker on PATH"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "all tests passed"
