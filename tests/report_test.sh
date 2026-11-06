# shellcheck shell=bash
# Work reporting (opt-in): tt-reporting switches it, tt-report records what
# the agent says, the session start note asks for it, and the hook sends it.
#
# What matters most: nothing is recorded or sent while reporting is off, the
# agent cannot switch it on through its own skill, and a summary is sent once.

SESSION="0b5c1a2e-6d84-4b7c-aeb8-ccf3422799b7"
REPORTS_REL=".local/state/time-tracker/reports"

# report [args...]: tt-report as the agent runs it, inside a session.
report() {
  env -i PATH="$PATH" HOME="$T/home" CLAUDE_CODE_SESSION_ID="$SESSION" \
    "$SCRIPT_BASH" "$REPORT" "$@" >"$T/stdout" 2>"$T/stderr"
}

reporting() {
  env -i PATH="$PATH" HOME="$T/home" "$SCRIPT_BASH" "$REPORTING" "$@" \
    >"$T/stdout" 2>"$T/stderr"
}

# The session start note, as Claude Code would add it to the conversation.
note() {
  env -i PATH="$PATH" HOME="$T/home" "$SCRIPT_BASH" "$REPORT_NOTE" \
    <<<"{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$SESSION\"}"
}

# The hook for this session, connected through the config file as
# tt-connect leaves it, which is also where tt-reporting writes.
session_hook() {
  mkdir -p "$T/home/.config/time-tracker"
  if ! grep -q TT_API_TOKEN "$T/home/.config/time-tracker/agent-hook.env" 2>/dev/null; then
    printf 'TT_API_TOKEN=%s\nTT_HEARTBEAT_URL=%s\n' "$TOKEN" "$BASE/activity-heartbeat" \
      >>"$T/home/.config/time-tracker/agent-hook.env"
  fi
  UNCONFIGURED=1 DEFAULT_PATHS=1 \
    hook "{\"session_id\":\"$SESSION\",\"hook_event_name\":\"$1\"}"
}

test_records_nothing_while_reporting_is_off() {
  report --issue 625 --summary "Did things." || fail "exit $?: $(cat "$T/stderr")"
  assert_contains "$(cat "$T/stdout")" "reporting is off" "output"
  [ ! -e "$T/home/$REPORTS_REL" ] || fail "recorded a report"
  assert_eq "$(note)" "" "session start note"
}

test_reporting_on_says_what_is_sent_and_keeps_the_token() {
  mkdir -p "$T/home/.config/time-tracker"
  printf 'TT_API_TOKEN=%s\n' "$TOKEN" >"$T/home/.config/time-tracker/agent-hook.env"

  reporting on || fail "exit $?: $(cat "$T/stderr")"

  assert_contains "$(cat "$T/stdout")" "issue title" "explanation"
  assert_contains "$(cat "$T/stdout")" "never do" "explanation"
  local config
  config="$(cat "$T/home/.config/time-tracker/agent-hook.env")"
  assert_contains "$config" "TT_API_TOKEN=$TOKEN" "config"
  assert_contains "$config" "TT_REPORT_WORK=1" "config"
  assert_eq "$(mode_of "$T/home/.config/time-tracker/agent-hook.env")" 600 "config mode"
  assert_contains "$(note)" "time-tracker:report" "session start note"
}

test_reporting_off_stops_it_and_deletes_what_waits() {
  reporting on
  report --issue 625 --summary "Did things."
  reporting off || fail "exit $?: $(cat "$T/stderr")"

  assert_not_contains "$(cat "$T/home/.config/time-tracker/agent-hook.env")" \
    "TT_REPORT_WORK" "config"
  [ ! -e "$T/home/$REPORTS_REL" ] || fail "kept the reports"
  assert_eq "$(note)" "" "session start note"
  reporting status
  assert_contains "$(cat "$T/stdout")" "off" "status"
}

test_reporting_off_takes_reports_out_of_the_queue() {
  # Offline, so heartbeats wait in the queue, reports and all.
  echo 503 >"$T/server/status"
  reporting on
  # A title made to look like the fields it must not be mistaken for.
  report --issue 625 --title - <<<'Fix ,"issue":7 and "quotes" \ too'
  report --summary - <<<'Did "this", then that.'
  session_hook UserPromptSubmit
  session_hook Stop
  local queue="$T/home/.local/state/time-tracker/agent-hook-queue.jsonl"
  assert_contains "$(cat "$queue")" '"summary"' "queue before"
  # A lock left by a send that died, which must not hold this up.
  mkdir "$T/home/.local/state/time-tracker/agent-hook.lock"
  touch -t 202001010000 "$T/home/.local/state/time-tracker/agent-hook.lock"

  reporting off || fail "exit $?: $(cat "$T/stderr")"

  assert_contains "$(cat "$T/stdout")" "not yet sent was deleted" "output"
  python3 -c '
import json, sys
lines = open(sys.argv[1]).read().splitlines()
assert len(lines) == 2, lines
for line in lines:
    h = json.loads(line)
    assert not {"issue", "title", "summary"} & set(h), h
    assert h["session_id"] and h["event"] and h["repo"], h
' "$queue" || fail "queue after: $(cat "$queue")"
  [ ! -e "$T/home/.local/state/time-tracker/agent-hook.lock" ] || fail "left the lock"
}

test_the_agents_skill_cannot_switch_it_on() {
  # The report skill grants tt-report alone; tt-reporting is the user's.
  local skill="$ROOT/claude/skills/report/SKILL.md"
  assert_contains "$(cat "$skill")" "allowed-tools: Bash(tt-report:*)" "report skill"
  assert_not_contains "$(cat "$skill")" "tt-reporting" "report skill"
  assert_contains "$(cat "$ROOT/claude/skills/reporting/SKILL.md")" \
    "disable-model-invocation: true" "reporting skill"
}

test_sends_the_issue_with_every_heartbeat_and_a_summary_once() {
  reporting on
  report --issue "#625" --title "Agent work
reports" || fail "exit $?: $(cat "$T/stderr")"
  report --summary "Added the report fields."

  session_hook UserPromptSubmit
  session_hook Stop

  assert_eq "$(heartbeats 'h.get("issue")' | paste -s -d ' ' -)" "625 625" "issues"
  assert_eq "$(heartbeats 'h.get("title")' | sort -u)" "Agent work reports" "title, on one line"
  assert_eq "$(heartbeats 'h.get("summary")' | paste -s -d '|' -)" \
    "Added the report fields.|None" "summary, once"
}

test_a_new_issue_drops_the_old_title() {
  reporting on
  report --issue 625 --title "Agent work reports"
  report --issue 626

  session_hook UserPromptSubmit

  assert_eq "$(heartbeats '(h.get("issue"), h.get("title"))')" "(626, None)" "report"
}

test_sends_no_report_while_reporting_is_off() {
  reporting on
  report --issue 625 --summary "Did things."
  # Switched off by hand in the file, the reports left in place.
  printf 'TT_REPORT_WORK=0\n' >>"$T/home/.config/time-tracker/agent-hook.env"

  session_hook UserPromptSubmit

  assert_eq "$(heartbeats '[k for k in ("issue", "title", "summary") if k in h]')" \
    "[]" "report fields"
}

test_a_session_end_takes_its_report_with_it() {
  reporting on
  report --issue 625 --summary "Finished."

  session_hook SessionEnd

  assert_eq "$(heartbeats 'h.get("summary")')" "Finished." "summary"
  [ ! -e "$T/home/$REPORTS_REL/$SESSION" ] || fail "kept the session's report"
}

test_refuses_what_is_not_an_issue_or_a_session() {
  reporting on
  if report --issue 6x5; then fail "took 6x5"; fi
  if report --issue 0625; then fail "took 0625"; fi
  if report --title; then fail "took --title without a text"; fi
  if report; then fail "took nothing"; fi
  if env -i PATH="$PATH" HOME="$T/home" CLAUDE_CODE_SESSION_ID="../x" \
    "$SCRIPT_BASH" "$REPORT" --issue 625 >/dev/null 2>&1; then
    fail "took a session id that is a path"
  fi
  [ ! -e "$T/home/.local/state/x" ] || fail "wrote outside the reports"
}

test_cuts_a_summary_to_what_the_server_keeps() {
  reporting on
  report --summary "$(printf 'x%.0s' $(seq 1 1200))"
  local kept
  kept="$(cat "$T/home/$REPORTS_REL/$SESSION.summaries")"
  assert_eq "${#kept}" 1000 "summary length"
}

test_cuts_a_title_between_characters_not_inside_one() {
  reporting on
  # 199 bytes of ASCII, then č, two bytes: the 200-byte cut splits it.
  report --issue 625 --title - <<<"$(printf 'x%.0s' $(seq 1 199))č and more"
  local kept
  kept="$(sed -n 's/^title=//p' "$T/home/$REPORTS_REL/$SESSION")"
  assert_eq "$kept" "$(printf 'x%.0s' $(seq 1 199))" "title"
  # Whole characters survive the cut.
  report --issue 625 --title - <<<"Popravak čćžšđ"
  assert_eq "$(sed -n 's/^title=//p' "$T/home/$REPORTS_REL/$SESSION")" \
    "Popravak čćžšđ" "title"
}

test_sends_every_summary_finished_in_a_turn() {
  # The hook fires once a turn, after the agent may have finished several.
  reporting on
  report --issue 625
  report --summary "First."
  report --summary "Second."
  report --summary "Third."

  session_hook Stop
  session_hook UserPromptSubmit

  assert_eq "$(heartbeats 'h.get("summary")' | paste -s -d '|' -)" \
    "First.|Second.|Third.|None" "summaries, each once"
  assert_eq "$(heartbeats 'h["event"]' | paste -s -d ' ' -)" \
    "agent_stop agent_stop agent_stop prompt" "events"
  assert_eq "$(heartbeats 'h.get("issue")' | sort -u)" "625" "issue on each"
  [ ! -e "$T/home/$REPORTS_REL/$SESSION.summaries" ] || fail "kept sent summaries"
  # The server stores one heartbeat per session, event and time, and drops
  # another as a resent copy: each must differ, and keep the order.
  assert_eq "$(heartbeats '(h["event"], h["occurred_at"])' | sort -u | wc -l | tr -d ' ')" \
    4 "distinct event and time"
  assert_eq "$(heartbeats 'h["occurred_at"][-5:]' | head -n 3 | paste -s -d ' ' -)" \
    ".001Z .002Z .003Z" "times, in order"
}

test_a_session_end_sends_every_summary_before_it_closes() {
  # The server closes the entry at the first session_end: the others go first.
  reporting on
  report --summary "First."
  report --summary "Second."

  session_hook SessionEnd

  assert_eq "$(heartbeats '(h["event"], h.get("summary"))' | paste -s -d '|' -)" \
    "('agent_stop', 'First.')|('session_end', 'Second.')" "heartbeats"
  [ ! -e "$T/home/$REPORTS_REL/$SESSION.summaries" ] || fail "kept the summaries"
}

test_reads_a_text_from_stdin_without_running_it() {
  # As the skill passes it: a quoted heredoc, so nothing in it is expanded.
  reporting on
  # shellcheck disable=SC2016 # the backticks and $(...) are meant literally
  report --issue 625 --title - <<<'Fix `touch ran` and $(touch ran)' ||
    fail "exit $?: $(cat "$T/stderr")"
  # shellcheck disable=SC2016
  report --summary - <<<'Ran `id`.' || fail "exit $?: $(cat "$T/stderr")"

  session_hook UserPromptSubmit

  # shellcheck disable=SC2016
  assert_eq "$(heartbeats 'h.get("title")')" 'Fix `touch ran` and $(touch ran)' "title"
  # shellcheck disable=SC2016
  assert_eq "$(heartbeats 'h.get("summary")')" 'Ran `id`.' "summary"
  [ ! -e ran ] && [ ! -e "$T/ran" ] || fail "ran a command from the text"
}

test_reads_only_one_text_from_stdin() {
  reporting on
  if report --title - --summary - <<<'Both'; then fail "read stdin twice"; fi
  assert_contains "$(cat "$T/stderr")" "Only one" "message"
}
