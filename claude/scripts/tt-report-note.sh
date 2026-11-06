#!/usr/bin/env bash
# Claude Code SessionStart hook: asks the agent to report its work, where the
# user switched work reporting on (tt-reporting on). Otherwise it prints
# nothing.
#
# Claude Code adds a SessionStart hook's output to the conversation, which is
# the point here and the reason tt-heartbeat.sh prints nothing: this is the
# one deliberate exception, kept to two lines, since it is in every session.
#
# It always exits 0 and never prints an error: a failure here only means the
# agent is not asked.

exec 2>/dev/null
set +eu

config_file="${TT_HOOK_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/time-tracker/agent-hook.env}"

value="${TT_REPORT_WORK:-}"
if [ -z "$value" ] && [ -f "$config_file" ]; then
  # Read, never run, as tt-heartbeat.sh reads the same file.
  value="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?TT_REPORT_WORK=//p' "$config_file" |
    tail -n 1 | tr -d "\r\"' ")"
fi
[ "$value" = 1 ] || exit 0

printf '%s\n' \
  "Time Tracker records this session's time for the user's timesheet." \
  "When you know which issue the work is for, and each time you finish a piece of work, report it with the time-tracker:report skill."
exit 0
