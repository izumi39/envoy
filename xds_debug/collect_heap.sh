#!/usr/bin/env bash
set -euo pipefail

output_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
heap_url="http://127.0.0.1:19000/heap_dump"
snapshot=""
sleep_pid=""

cleanup() {
  if [[ -n "${sleep_pid}" ]]; then
    kill "${sleep_pid}" 2>/dev/null || true
  fi
  if [[ -n "${snapshot}" ]]; then
    rm -f -- "${snapshot}"
  fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM

while true; do
  snapshot="$(mktemp "${output_dir}/envoy-heap-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
  if curl --fail --silent --show-error --connect-timeout 5 --max-time 120 \
    "${heap_url}" --output "${snapshot}" && [[ -s "${snapshot}" ]]; then
    mv -- "${snapshot}" "${snapshot}.heap"
    printf 'Saved: %s.heap\n' "${snapshot}"
  else
    rm -f -- "${snapshot}"
    printf '%s Heap request failed or was empty; retrying in 30 minutes.\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  fi
  snapshot=""
  sleep 1800 &
  sleep_pid="$!"
  wait "${sleep_pid}"
  sleep_pid=""
done
