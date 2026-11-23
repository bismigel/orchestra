#!/usr/bin/env bash
# Every offline test suite in tests/, one after another. Exit non-zero if any fails. No model calls, no network.
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
failed=""
for t in "$here"/*.sh; do
  [ "$(basename "$t")" = all.sh ] && continue
  echo "=== $(basename "$t")"
  bash "$t" || failed="$failed $(basename "$t")"
done
[ -z "$failed" ] && { echo "all suites passed"; exit 0; }
echo "FAILED:$failed"; exit 1
