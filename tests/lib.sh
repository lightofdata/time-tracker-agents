# shellcheck shell=bash
# Helpers for the tests: a temporary home and fake server per test, and a few
# assertions. Sourced by run.sh; each test is a function named test_*.
#
# The variables set here are read by the test files, which shellcheck checks
# one at a time:
# shellcheck disable=SC2034

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/claude/scripts/tt-heartbeat.sh"
CONNECT="$ROOT/claude/bin/tt-connect"
# The bash the scripts run under. CI sets /bin/bash on macOS, which is 3.2:
# the oldest the scripts must run on, and what a Mac without Homebrew has.
SCRIPT_BASH="${TEST_BASH:-bash}"

setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/home" "$T/server"
  python3 "$ROOT/tests/fake_server.py" "$T/server" &
  SERVER_PID=$!
  local _
  for _ in $(seq 1 50); do
    [ -f "$T/server/port" ] && break
    sleep 0.1
  done
  PORT="$(cat "$T/server/port")"
  BASE="http://127.0.0.1:$PORT/functions/v1"
}

teardown() {
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  rm -rf "$T"
}

fail() {
  printf '    %s\n' "$*" >&2
  return 1
}

assert_eq() { # actual expected [what]
  [ "$1" = "$2" ] || fail "${3:-value}: expected [$2], got [$1]"
}

assert_contains() { # haystack needle [what]
  case "$1" in
    *"$2"*) ;;
    *) fail "${3:-text} does not contain [$2]: [$1]" ;;
  esac
}

assert_not_contains() { # haystack needle [what]
  case "$1" in
    *"$2"*) fail "${3:-text} contains [$2]" ;;
  esac
}

# A field of each request (or of each heartbeat sent), one per line, read with
# python3 so the tests do not trust the scripts' own JSON handling.
requests() { # python expression over r, the request
  [ -f "$T/server/requests.jsonl" ] || return 0
  python3 -c '
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    print(eval(sys.argv[2]))
' "$T/server/requests.jsonl" "$1"
}

heartbeats() { # python expression over h, a heartbeat
  [ -f "$T/server/requests.jsonl" ] || return 0
  python3 -c '
import json, sys
for line in open(sys.argv[1]):
    for h in json.loads(line)["body"]["heartbeats"]:
        print(eval(sys.argv[2]))
' "$T/server/requests.jsonl" "$1"
}

lines() { # file: its line count, 0 when it does not exist
  if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi
}
