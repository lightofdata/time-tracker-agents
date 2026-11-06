#!/usr/bin/env bash
# Claude Code hook: reports agent activity to Time Tracker.
#
# Usage: tt-heartbeat.sh [session_start|prompt|agent_stop|session_end]
#
# The plugin's hooks.json runs this on SessionStart, UserPromptSubmit, Stop
# and SessionEnd, naming the event as the argument; Claude Code passes the
# rest as JSON on stdin. Without an argument, the event is read from stdin's
# hook_event_name, for a hook registered by hand. Each event becomes one
# heartbeat for Time Tracker's server, which groups them into suggested time
# entries for the user to confirm in the app.
#
# Rules this script keeps, because breaking any of them hurts the agent:
#
#   * It prints nothing, ever. Claude Code adds a UserPromptSubmit or
#     SessionStart hook's stdout to the conversation, so any output — an error
#     included — would leak into the agent's context.
#   * It always exits 0. Exit code 2 from UserPromptSubmit blocks the prompt.
#   * It returns at once. The network call runs detached, so a slow or absent
#     server never holds up a prompt.
#
# What is sent: the session id, the event, the time, and the repository and
# branch the session runs in. Never the prompt, the transcript or the path.
# Where the user switched work reporting on (tt-reporting), also what the
# agent reported with tt-report: the issue, its title, and a summary of
# finished work.
#
# A heartbeat that cannot be sent waits in a queue file and goes with the next
# one that can. Problems are written to a log file instead of the screen.
#
# Needs bash 3.2 or later, curl, git and sed; not jq. The JSON read and
# written here is flat and small, so sed and printf do.
#
# Config, from the environment or from ~/.config/time-tracker/agent-hook.env,
# which tt-connect writes:
#   TT_API_TOKEN      a personal API token
#   TT_HEARTBEAT_URL  the activity-heartbeat endpoint
#   TT_HOOK_CONFIG    another config file
#   TT_HOOK_STATE_DIR where the queue and log live
#                     (default ~/.local/state/time-tracker)
#   TT_REPORT_WORK=1  send what the agent reports; set by tt-reporting on
#   TT_HOOK_SYNC=1    send in the foreground; for tests only

exec 1>/dev/null 2>/dev/null
# Every step here is best effort: one that fails must never end the hook.
# errexit or nounset can arrive from the user's environment through an
# exported SHELLOPTS, so they are turned off rather than assumed off.
set +eu
# The queue and log name the user's repositories and branches: private to the
# user, as the config is.
umask 077

state_dir="${TT_HOOK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/time-tracker}"
config_file="${TT_HOOK_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/time-tracker/agent-hook.env}"
queue="$state_dir/agent-hook-queue.jsonl"
lock="$state_dir/agent-hook.lock"
log_file="$state_dir/agent-hook.log"

# The server takes at most 100 a batch; the queue keeps at most this many, so
# a token that stays wrong for weeks cannot fill the disk.
batch_size=100
queue_cap=5000

log() {
  mkdir -p "$state_dir" || return
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$log_file"
  # Keep the log short; it is for a person debugging, not an audit trail.
  if [ "$(wc -l <"$log_file")" -gt 400 ]; then
    tail -n 200 "$log_file" >"$log_file.tmp" && mv "$log_file.tmp" "$log_file"
  fi
}

# The value of the top-level string field $1 of the JSON in $input, or
# nothing. A field is matched only after `{`, `,` or the start of a line, so
# the same name inside a string — the prompt, say, where its quotes are
# escaped and which holds no raw line break — is not taken for it. The value
# is returned raw: escapes are left as they are.
json_field() {
  printf '%s\n' "$input" |
    sed -nE 's/^(.*[{,])?[[:space:]]*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\2/p' |
    head -n 1
}

# $1 as a JSON string, quotes included. Control characters are dropped: none
# belongs in a repository name, a branch or a session id.
json_string() {
  local value
  value="$(printf '%s' "$1" | tr -d '\000-\037')"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

# The value of setting $1 in the config file: the last `NAME=value` or
# `export NAME=value` line, with trailing spaces and a Windows line ending
# dropped, then one pair of surrounding quotes. The file is read, never run:
# this script runs on every prompt, so anything in the file that ran as shell
# would run on every prompt too. So `$(...)` or a `# comment` is taken as
# part of the value.
config_value() {
  sed -nE 's/^[[:space:]]*(export[[:space:]]+)?'"$1"'=//p' "$config_file" |
    tail -n 1 |
    tr -d '\r' |
    sed -E "s/[[:space:]]+\$//; s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/"
}

# Values already exported win over the file.
if [ -f "$config_file" ]; then
  [ -n "${TT_API_TOKEN:-}" ] || TT_API_TOKEN="$(config_value TT_API_TOKEN)"
  [ -n "${TT_HEARTBEAT_URL:-}" ] || TT_HEARTBEAT_URL="$(config_value TT_HEARTBEAT_URL)"
  [ -n "${TT_REPORT_WORK:-}" ] || TT_REPORT_WORK="$(config_value TT_REPORT_WORK)"
fi

command -v curl >/dev/null || {
  log "curl not found; nothing sent"
  exit 0
}

input="$(cat)"

event="${1:-}"
if [ -z "$event" ]; then
  case "$(json_field hook_event_name)" in
    SessionStart) event=session_start ;;
    UserPromptSubmit) event=prompt ;;
    Stop) event=agent_stop ;;
    SessionEnd) event=session_end ;;
  esac
fi
case "$event" in
  session_start | prompt | agent_stop | session_end) ;;
  *) exit 0 ;;
esac

session_id="$(json_field session_id)"
[ -n "$session_id" ] || {
  log "no session_id in $event"
  exit 0
}

# The session's folder. A path with an escape in its JSON — a quote, a
# backslash, a character outside ASCII — is rare enough not to decode: the
# project folder Claude Code exports stands in for it.
cwd="$(json_field cwd)"
case "$cwd" in
  *\\*) cwd="${CLAUDE_PROJECT_DIR:-}" ;;
esac
[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

# owner/name from the origin remote, whether it is an SSH or an HTTPS URL;
# else the folder name, so a repo without a remote still maps to something.
repo=""
branch=""
if command -v git >/dev/null && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  remote="$(git -C "$cwd" remote get-url origin 2>/dev/null)"
  if [ -n "$remote" ]; then
    repo="$(printf '%s' "$remote" | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')"
  else
    repo="$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)")"
  fi
  # symbolic-ref rather than rev-parse: it names the branch of a repository
  # with no commits yet, and says nothing on a detached HEAD.
  branch="$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null)"
fi

occurred_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# What the agent reported about its work (tt-report), where the user switched
# work reporting on. The issue and title, in the session's report file, go
# with every heartbeat, so each suggested entry knows them. Summaries, one a
# line in the file beside it, go once each and are then gone from it. The
# queue keeps them, so a summary taken here is never lost to a failed send.
report_file=""
case "$session_id" in
  *[!A-Za-z0-9-]*) ;;
  *) report_file="$state_dir/reports/$session_id" ;;
esac
report_fields=""
summaries=()
if [ "${TT_REPORT_WORK:-}" = 1 ] && [ -n "$report_file" ]; then
  if [ -f "$report_file" ]; then
    report_issue="$(sed -n 's/^issue=//p' "$report_file" | tail -n 1)"
    report_title="$(sed -n 's/^title=//p' "$report_file" | tail -n 1)"
    case "$report_issue" in
      "" | *[!0-9]*) ;;
      *)
        report_fields=",\"issue\":$report_issue"
        [ -z "$report_title" ] ||
          report_fields="$report_fields,\"title\":$(json_string "$report_title")"
        ;;
    esac
  fi
  # Taken by renaming the file, which tt-report only ever appends to: a
  # summary it writes meanwhile starts a new file, for the next heartbeat.
  taken="$report_file.summaries.$$"
  if [ -f "$report_file.summaries" ] && mv "$report_file.summaries" "$taken"; then
    while IFS= read -r summary || [ -n "$summary" ]; do
      [ -z "$summary" ] || summaries+=("$summary")
    done <"$taken"
    rm -f "$taken"
  fi
fi

# One heartbeat of event $1, with summary $2 if given, at $3 if given, else
# at occurred_at.
heartbeat() {
  local l
  l="{\"session_id\":$(json_string "$session_id")"
  l="$l,\"event\":\"$1\",\"occurred_at\":\"${3:-$occurred_at}\""
  [ -z "$repo" ] || l="$l,\"repo\":$(json_string "$repo")"
  [ -z "$branch" ] || l="$l,\"branch\":$(json_string "$branch")"
  l="$l$report_fields"
  [ -z "${2:-}" ] || l="$l,\"summary\":$(json_string "$2")"
  printf '%s}' "$l"
}

# The server keeps one summary a heartbeat, so several finished in one turn
# go as several heartbeats of this event at this moment, the last summary on
# the event's own. A session_end's go as agent_stop, which the server orders
# before it: the first session_end closes the entry, and a summary on a later
# one would be left out of it.
#
# Each a millisecond after the one before, from .001: the server stores a
# heartbeat once per session, event and time, and takes a second one at the
# same time for a resent copy, dropping it. Not from .000, which is when a
# plain heartbeat of the same second is stored. The latest 100 at most, which
# no turn comes near.
lines=""
count=${#summaries[@]}
if [ "$count" -eq 0 ]; then
  lines="$(heartbeat "$event")"
else
  extra_event="$event"
  [ "$event" != session_end ] || extra_event=agent_stop
  i=0
  [ "$count" -le 100 ] || i=$((count - 100))
  first=$i
  while [ "$i" -lt "$count" ]; do
    at="${occurred_at%Z}.$(printf '%03d' "$((i - first + 1))")Z"
    if [ "$i" -lt "$((count - 1))" ]; then
      lines="$lines$(heartbeat "$extra_event" "${summaries[$i]}" "$at")"$'\n'
    else
      lines="$lines$(heartbeat "$event" "${summaries[$i]}" "$at")"
    fi
    i=$((i + 1))
  done
fi

mkdir -p "$state_dir" || exit 0
# The umask covers only what is created from now on: a state directory left
# by 0.1.1 or earlier, and its queue and log, were readable by everyone.
chmod 700 "$state_dir"
chmod 600 "$queue" "$log_file"
# Built first and appended in one write, so two sessions' hooks firing
# together cannot interleave inside a line.
printf '%s\n' "$lines" >>"$queue"

# A session's report goes with the session; any a crashed session left behind
# goes after a month.
if [ "$event" = session_end ] && [ -n "$report_file" ]; then
  rm -f "$report_file" "$report_file.summaries"
elif [ "$event" = session_start ] && [ -d "$state_dir/reports" ]; then
  find "$state_dir/reports" -type f -mtime +30 -exec rm -f {} + 2>/dev/null
fi

# Sends the queue in batches. Only one process does it at a time: parallel
# sessions fire hooks together, and whichever holds the lock sends what the
# others queued. mkdir is the lock because it is atomic everywhere; flock is
# not on macOS.
flush() {
  if ! mkdir "$lock" 2>/dev/null; then
    # A lock older than two minutes belongs to a process that died.
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null
      mkdir "$lock" 2>/dev/null || return
    else
      return
    fi
  fi
  trap 'rmdir "$lock" 2>/dev/null' EXIT

  if [ -z "${TT_API_TOKEN:-}" ] || [ -z "${TT_HEARTBEAT_URL:-}" ]; then
    log "not connected (no TT_API_TOKEN or TT_HEARTBEAT_URL); queued only"
    return
  fi

  local sending="$state_dir/agent-hook-sending.jsonl"
  local status
  while [ -s "$queue" ]; do
    # Take the queue over, so heartbeats arriving meanwhile start a new one.
    mv "$queue" "$sending" || return
    head -n "$batch_size" "$sending" >"$sending.batch"
    tail -n +"$((batch_size + 1))" "$sending" >>"$queue"
    rm -f "$sending"

    # The token goes to curl through a file descriptor, not its arguments,
    # which any local user can read in `ps`. printf is a builtin, so it is
    # never in an argument list either.
    status="$(
      {
        printf '{"heartbeats":['
        paste -s -d , "$sending.batch"
        printf ']}'
      } |
        curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
          -X POST "$TT_HEARTBEAT_URL" \
          -H @<(printf 'authorization: Bearer %s\n' "$TT_API_TOKEN") \
          -H 'content-type: application/json' \
          --data-binary @-
    )"

    case "$status" in
      2??) rm -f "$sending.batch" ;;
      400 | 413)
        # The server will never take this batch; resending it would block
        # everything behind it.
        log "batch refused ($status); dropped $(wc -l <"$sending.batch" | tr -d ' ') heartbeats"
        rm -f "$sending.batch"
        ;;
      *)
        # 401 (token wrong or revoked), 429, 5xx, or no answer: keep it.
        log "send failed (${status:-no response}); kept for next time"
        cat "$sending.batch" >>"$queue"
        rm -f "$sending.batch"
        break
        ;;
    esac
  done

  if [ -f "$queue" ] && [ "$(wc -l <"$queue")" -gt "$queue_cap" ]; then
    tail -n "$queue_cap" "$queue" >"$queue.tmp" && mv "$queue.tmp" "$queue"
    log "queue over $queue_cap; oldest heartbeats dropped"
  fi
}

if [ "${TT_HOOK_SYNC:-}" = "1" ]; then
  flush
else
  # Detached, so the hook returns before the request is even made.
  (flush) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
fi
exit 0
