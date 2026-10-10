#!/usr/bin/env bash
# Runs every test file in this folder. Usage: bash tests/run-all.sh
# Exits non-zero if any file reports a failure.

here=$(cd "$(dirname "$0")" && pwd -P)
status=0
for t in "$here"/test-*.sh; do
  echo "### $(basename "$t")"
  bash "$t" || status=1
  echo
done
[ "$status" = 0 ] && echo "All tests passed." || echo "Some tests FAILED."
exit "$status"
