---
name: reporting
description: Switch Time Tracker work reporting on or off for this computer, or say whether it is on.
argument-hint: "on | off | status"
disable-model-invocation: true
allowed-tools: Bash(tt-reporting:*)
---

Switch work reporting on or off for this computer, with the `tt-reporting`
command this plugin puts on the PATH.

1. Run `tt-reporting $ARGUMENTS`; with no argument, `tt-reporting status`.
2. Show its output to the user as printed. When switching on, it explains what
   is sent: show all of it, since that is what the user agrees to.
3. Add nothing else, except, after switching on, that it applies from the next
   session.

Never run `tt-reporting` unless the user ran this command, and never with an
argument they did not give.
