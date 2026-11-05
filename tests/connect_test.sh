# shellcheck shell=bash
# tt-connect against the fake server.
#
# What matters: the token it saves is the one whose hash it offered and whose
# approval it waited for, the token never travels or shows before then, and
# nothing is saved unless the pairing was approved.

CONFIG_REL=".config/time-tracker/agent-hook.env"

# connect [args...]; stdout and stderr land in $T/stdout and $T/stderr.
connect() {
  env -i PATH="$PATH" HOME="$T/home" TT_COMPUTER_NAME="work laptop" \
    ${FUNCTIONS_URL:+TT_FUNCTIONS_URL="$FUNCTIONS_URL"} \
    "$SCRIPT_BASH" "$CONNECT" "$@" >"$T/stdout" 2>"$T/stderr"
}

saved() { # the value of a setting in the saved config
  sed -n "s/^$1=//p" "$T/home/$CONFIG_REL"
}

sha256_of() {
  if command -v sha256sum >/dev/null; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}

mode_of() { # file: its permissions, e.g. 600
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

test_saves_the_token_it_offered_once_it_is_approved() {
  printf 'pending\napproved\n' >"$T/server/statuses"
  connect "$BASE" || fail "exit $?: $(cat "$T/stderr")"

  assert_contains "$(cat "$T/stdout")" "WDJB-MJHT" "output"
  assert_contains "$(cat "$T/stdout")" "work laptop" "output"

  local token
  token="$(saved TT_API_TOKEN)"
  [[ "$token" =~ ^tt_[A-Za-z0-9_-]{43}$ ]] || fail "token [$token]"
  assert_eq "$(saved TT_HEARTBEAT_URL)" "$BASE/activity-heartbeat" "heartbeat URL"
  assert_not_contains "$(cat "$T/stdout" "$T/stderr")" "$token" "output"

  assert_eq "$(requests 'r["route"]' | paste -s -d ' ' -)" "start status status" "routes"
  assert_eq "$(requests 'r["authorization"]' | head -n 1)" "None" "start authorization"
  assert_eq "$(requests 'r["body"] and r["body"]["name"]' | head -n 1)" "work laptop" "name"
  assert_eq "$(requests 'r["body"] and r["body"]["token_hash"]' | head -n 1)" \
    "$(sha256_of "$token")" "token hash"
  assert_eq "$(requests 'r["body"] and r["body"]["token_prefix"]' | head -n 1)" \
    "${token:0:8}" "token prefix"
  assert_not_contains "$(head -n 1 "$T/server/requests.jsonl")" "$token" "start request"
  assert_eq "$(requests 'r["authorization"]' | tail -n +2 | sort -u)" "Bearer $token" "poll authorization"
}

test_start_and_wait_as_two_steps() {
  # As /time-tracker:connect runs it: the code first, the wait after.
  printf 'approved\n' >"$T/server/statuses"
  connect start "$BASE" || fail "start exit $?: $(cat "$T/stderr")"
  assert_contains "$(cat "$T/stdout")" "WDJB-MJHT" "start output"
  assert_eq "$(lines "$T/server/requests.jsonl")" 1 "requests after start"
  [ ! -f "$T/home/$CONFIG_REL" ] || fail "config saved before approval"

  local pending="$T/home/.local/state/time-tracker/pairing.env"
  assert_eq "$(mode_of "$pending")" 600 "pending file mode"

  connect wait || fail "wait exit $?: $(cat "$T/stderr")"
  assert_contains "$(cat "$T/stdout")" "Connected" "wait output"
  [[ "$(saved TT_API_TOKEN)" =~ ^tt_ ]] || fail "no token saved"
  [ ! -f "$pending" ] || fail "pending file left behind"
}

test_wait_without_start_says_what_to_do() {
  if connect wait; then fail "wait succeeded"; fi
  assert_contains "$(cat "$T/stderr")" "tt-connect start" "message"
  assert_eq "$(lines "$T/server/requests.jsonl")" 0 "requests"
}

test_keeps_the_file_private_and_the_rest_of_it_as_it_was() {
  printf 'approved\n' >"$T/server/statuses"
  mkdir -p "$(dirname "$T/home/$CONFIG_REL")"
  printf 'TT_API_TOKEN=tt_old\nTT_HEARTBEAT_URL=http://old\nTT_HOOK_STATE_DIR=/somewhere\n' \
    >"$T/home/$CONFIG_REL"

  connect "$BASE" || fail "exit $?: $(cat "$T/stderr")"

  [ "$(saved TT_API_TOKEN)" != tt_old ] || fail "old token kept"
  assert_eq "$(saved TT_HEARTBEAT_URL)" "$BASE/activity-heartbeat" "heartbeat URL"
  assert_eq "$(saved TT_HOOK_STATE_DIR)" "/somewhere" "other setting"
  assert_eq "$(lines "$T/home/$CONFIG_REL")" 3 "lines"
  assert_eq "$(mode_of "$T/home/$CONFIG_REL")" 600 "mode"
}

test_saves_nothing_when_the_code_expires() {
  printf 'pending\nexpired\n' >"$T/server/statuses"
  if connect "$BASE"; then fail "succeeded"; fi
  assert_contains "$(cat "$T/stderr")" "Run this again" "message"
  [ ! -f "$T/home/$CONFIG_REL" ] || fail "config saved"
  [ ! -f "$T/home/.local/state/time-tracker/pairing.env" ] || fail "pending file left behind"
}

test_refuses_a_server_it_does_not_know() {
  if connect start stagin; then fail "succeeded"; fi
  assert_contains "$(cat "$T/stderr")" "production, staging" "message"
  assert_eq "$(lines "$T/server/requests.jsonl")" 0 "requests"
}

test_uses_tt_functions_url_when_given_no_url() {
  printf 'approved\n' >"$T/server/statuses"
  FUNCTIONS_URL="$BASE" connect || fail "exit $?: $(cat "$T/stderr")"
  assert_eq "$(saved TT_HEARTBEAT_URL)" "$BASE/activity-heartbeat" "heartbeat URL"
}
