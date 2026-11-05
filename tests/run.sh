#!/usr/bin/env bash
# Runs every test_* function in tests/*_test.sh, each in a fresh temporary
# home with its own fake server. Needs bash, curl, git and python3 (the last
# for the fake server only; the scripts themselves do not use it).
#
# Usage: tests/run.sh [name filter]

cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
. tests/lib.sh

for tool in curl git python3; do
  command -v "$tool" >/dev/null || {
    echo "needs $tool" >&2
    exit 1
  }
done

passed=0
failed=0
for file in tests/*_test.sh; do
  # shellcheck source=/dev/null
  . "$file"
done
for name in $(declare -F | awk '{print $3}' | grep '^test_' | grep -- "${1:-}"); do
  setup
  # Not inside the `if`: bash ignores set -e in a condition, and set -e is
  # what makes the first failed assertion end the test.
  (
    set -e
    "$name"
  )
  status=$?
  if [ "$status" -eq 0 ]; then
    passed=$((passed + 1))
    printf 'ok   %s\n' "$name"
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n' "$name"
  fi
  teardown
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
