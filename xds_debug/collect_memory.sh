#!/usr/bin/env bash
set -euo pipefail

output_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
memory_url="http://127.0.0.1:19000/memory"

trap 'exit 0' INT TERM

while true; do
  snapshot="$(mktemp "${output_dir}/envoy-memory-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
  if curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
    "${memory_url}" --output "${snapshot}"; then
    mv -- "${snapshot}" "${snapshot}.json"
    printf 'Saved: %s.json\n' "${snapshot}"
  else
    rm -f -- "${snapshot}"
    printf 'Memory request failed; retrying in five minutes.\n' >&2
  fi
  sleep 300 &
  wait "$!"
done
