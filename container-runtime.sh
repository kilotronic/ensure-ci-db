#!/usr/bin/env bash
# Print the container runtime command to use, or exit 1 if none is available.
#
# Order: $CT override, then docker, then podman.

set -uo pipefail

if [[ -n "${CT:-}" ]]; then
  echo "$CT"
  exit 0
fi

for _rt in docker podman; do
  if command -v "$_rt" >/dev/null 2>&1; then
    echo "$_rt"
    exit 0
  fi
done

exit 1
