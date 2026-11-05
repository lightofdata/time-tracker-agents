---
name: connect
description: Connect this computer to the Time Tracker app, so Claude Code sessions become suggested time entries.
argument-hint: "[staging | server URL]"
disable-model-invocation: true
allowed-tools: Bash(tt-connect:*)
---

Connect this computer to Time Tracker. The user approves it in the app with a
short code; the `tt-connect` command, which this plugin puts on the PATH, does
the rest.

1. Run `tt-connect start $ARGUMENTS`. It prints a code and where to enter it.
   If it fails, show its message and stop.
2. Show the user the code and the steps exactly as printed, the code on a line
   of its own so it stands out. Tell them to enter it in the app and approve,
   and that you are waiting.
3. Run `tt-connect wait`, with a Bash timeout of 600000 ms: it returns once
   the user approves, or when the code expires after 10 minutes.
4. Report the outcome in one sentence. On success, add that new sessions are
   tracked from now on, and that suggested entries appear in the app's
   Suggestions tab once a session has been quiet for 15 minutes.

The token `tt-connect` saves is a credential. Never read, print or quote
`~/.config/time-tracker/agent-hook.env` or the pairing file, and never pass
anything to `tt-connect` but the subcommand and the server the user gave: a
name such as `staging`, or a URL.
