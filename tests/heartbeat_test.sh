# shellcheck shell=bash
# tt-heartbeat.sh against the fake server, with TT_HOOK_SYNC so the send
# happens before the script exits.
#
# What matters most is what the hook must never do: print anything (Claude
# Code feeds a prompt hook's stdout to the agent), exit non-zero (exit 2
# blocks the prompt) or send the prompt itself.

TOKEN="tt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# hook <stdin JSON> [event argument]; options as variables:
#   UNCONFIGURED=1  no token or URL
#   ASYNC=1         the real, detached send
#   DEFAULT_PATHS=1 the default config and state directories
hook() {
  local vars=(PATH="$PATH" HOME="$T/home")
  [ -n "${ASYNC:-}" ] || vars+=(TT_HOOK_SYNC=1)
  [ -n "${DEFAULT_PATHS:-}" ] || vars+=(TT_HOOK_STATE_DIR="$T/state")
  [ -n "${UNCONFIGURED:-}" ] ||
    vars+=(TT_API_TOKEN="$TOKEN" TT_HEARTBEAT_URL="$BASE/activity-heartbeat")
  env -i "${vars[@]}" "$SCRIPT_BASH" "$HOOK" ${2:+"$2"} <<<"$1" >"$T/stdout" 2>"$T/stderr"
}

# A git repository with the given origin, as a session's folder.
repo_with_origin() {
  mkdir -p "$T/work"
  git -C "$T/work" init -q
  git -C "$T/work" symbolic-ref HEAD refs/heads/feature/x
  git -C "$T/work" remote add origin "$1"
}

test_maps_each_claude_code_event_and_nothing_else() {
  local name
  for name in SessionStart UserPromptSubmit Stop SessionEnd PreToolUse Notification; do
    hook "{\"hook_event_name\":\"$name\",\"session_id\":\"s1\"}"
  done
  assert_eq "$(heartbeats 'h["event"]' | paste -s -d ' ' -)" \
    "session_start prompt agent_stop session_end" "events"
  assert_eq "$(requests 'r["authorization"]' | head -n 1)" "Bearer $TOKEN" "authorization"
}

test_takes_the_event_from_its_argument() {
  # The plugin names the event; stdin's hook_event_name is then ignored.
  hook '{"hook_event_name":"Stop","session_id":"s1"}' prompt
  hook '{"session_id":"s1"}' agent_stop
  hook '{"session_id":"s1"}' not_an_event
  assert_eq "$(heartbeats 'h["event"]' | paste -s -d ' ' -)" "prompt agent_stop" "events"
}

test_prints_nothing_and_exits_0_even_when_it_cannot_send() {
  echo 503 >"$T/server/status"
  hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}'
  assert_eq "$?" 0 "exit code when the server fails"
  assert_eq "$(cat "$T/stdout" "$T/stderr")" "" "output when the server fails"

  UNCONFIGURED=1 hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}'
  assert_eq "$?" 0 "exit code unconfigured"
  assert_eq "$(cat "$T/stdout" "$T/stderr")" "" "output unconfigured"

  hook '{"not":"a hook event"}'
  assert_eq "$?" 0 "exit code on garbage"
  assert_eq "$(cat "$T/stdout" "$T/stderr")" "" "output on garbage"
}

test_sends_the_repo_and_branch_never_the_prompt_or_the_path() {
  repo_with_origin git@github.com:lightofdata/time_tracker.git
  hook "{\"session_id\":\"s1\",\"transcript_path\":\"/home/me/t.jsonl\",\"cwd\":\"$T/work\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"secret plans\"}"

  assert_eq "$(heartbeats 'h["repo"]')" "lightofdata/time_tracker" "repo"
  assert_eq "$(heartbeats 'h["branch"]')" "feature/x" "branch"
  assert_eq "$(heartbeats '",".join(sorted(h))')" "branch,event,occurred_at,repo,session_id" "fields"
  local sent
  sent="$(cat "$T/server/requests.jsonl")"
  assert_not_contains "$sent" "secret plans" "what was sent"
  assert_not_contains "$sent" "$T/work" "what was sent"
}

test_is_not_fooled_by_field_names_inside_the_prompt() {
  # Read without jq: the prompt's own "session_id" and "cwd", escaped as JSON
  # escapes them, must not be taken for the real ones.
  repo_with_origin git@github.com:lightofdata/time_tracker.git
  hook "{\"session_id\":\"real\",\"prompt\":\"say \\\"session_id\\\":\\\"fake\\\", \\\"cwd\\\":\\\"/tmp\\\"\",\"cwd\":\"$T/work\",\"hook_event_name\":\"UserPromptSubmit\"}"

  assert_eq "$(heartbeats 'h["session_id"]')" "real" "session id"
  assert_eq "$(heartbeats 'h["repo"]')" "lightofdata/time_tracker" "repo"
}

test_reads_pretty_printed_input() {
  hook '{
  "session_id": "s1",
  "hook_event_name": "Stop"
}'
  assert_eq "$(heartbeats 'h["session_id"] + " " + h["event"]')" "s1 agent_stop" "heartbeat"
}

test_reads_owner_and_name_from_an_https_origin_too() {
  repo_with_origin https://github.com/lightofdata/time_tracker.git
  hook "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"cwd\":\"$T/work\"}"
  assert_eq "$(heartbeats 'h["repo"]')" "lightofdata/time_tracker" "repo"
}

test_escapes_what_it_sends() {
  # A quote is allowed in a git branch name.
  repo_with_origin git@github.com:lightofdata/time_tracker.git
  git -C "$T/work" symbolic-ref HEAD 'refs/heads/say-"hi"'
  hook "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"cwd\":\"$T/work\"}"
  assert_eq "$(heartbeats 'h["branch"]')" 'say-"hi"' "branch"
}

test_keeps_what_it_could_not_send_and_sends_it_with_the_next() {
  echo 503 >"$T/server/status"
  hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}'
  assert_eq "$(lines "$T/state/agent-hook-queue.jsonl")" 1 "queued"

  echo 200 >"$T/server/status"
  rm "$T/server/requests.jsonl"
  hook '{"hook_event_name":"Stop","session_id":"s1"}'
  assert_eq "$(heartbeats 'h["event"]' | paste -s -d ' ' -)" "prompt agent_stop" "events"
  assert_eq "$(lines "$T/state/agent-hook-queue.jsonl")" 0 "queued after"
}

test_drops_a_batch_the_server_will_never_take() {
  # Resending it would block everything queued behind it.
  echo 400 >"$T/server/status"
  hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}'
  assert_eq "$(lines "$T/state/agent-hook-queue.jsonl")" 0 "queued"
}

test_returns_at_once_while_a_slow_server_is_still_answering() {
  # Claude Code waits for the hook's output to close, so a background send
  # that kept it open would hold up the prompt just the same.
  echo 3 >"$T/server/delay"
  local start=$SECONDS
  ASYNC=1 hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}'
  [ $((SECONDS - start)) -lt 2 ] || fail "took $((SECONDS - start)) s"

  # And the heartbeat still arrives.
  local _
  for _ in $(seq 1 50); do
    [ -s "$T/server/requests.jsonl" ] && break
    sleep 0.1
  done
  assert_eq "$(heartbeats 'h["event"]')" "prompt" "event"
}

test_reads_its_config_and_keeps_its_state_in_the_xdg_directories() {
  mkdir -p "$T/home/.config/time-tracker"
  printf 'TT_API_TOKEN=%s\nTT_HEARTBEAT_URL=%s\n' "$TOKEN" "$BASE/activity-heartbeat" \
    >"$T/home/.config/time-tracker/agent-hook.env"
  echo 503 >"$T/server/status"

  UNCONFIGURED=1 DEFAULT_PATHS=1 hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}'

  assert_eq "$(requests 'r["authorization"]')" "Bearer $TOKEN" "authorization"
  assert_eq "$(lines "$T/home/.local/state/time-tracker/agent-hook-queue.jsonl")" 1 "queued"
}

test_queues_without_a_token_and_sends_once_there_is_one() {
  UNCONFIGURED=1 hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}'
  assert_eq "$(lines "$T/server/requests.jsonl")" 0 "requests"

  hook '{"hook_event_name":"Stop","session_id":"s1"}'
  assert_eq "$(heartbeats 'h["event"]' | paste -s -d ' ' -)" "prompt agent_stop" "events"
}
