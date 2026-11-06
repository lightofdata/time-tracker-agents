---
name: report
description: Report to Time Tracker which issue this session's work is for and summarize work you finish. Use when the session start note asks for it, once you know the issue, and each time you finish a piece of work.
allowed-tools: Bash(tt-report:*)
---

Time Tracker turns this session's activity into time entries for the user to
confirm. Your report names the entry after the issue and becomes its
description. Run `tt-report`, which this plugin puts on the PATH:

- **Once you know the issue** the work is for, from the branch, the
  conversation or the issue tracker. The title is the issue's own title, as
  the tracker shows it. Report again if the work moves to another issue.

  ```bash
  tt-report --issue 625 --title - <<'EOF'
  Agent work reports
  EOF
  ```

- **Each time you finish a piece of work**, one sentence in the past tense,
  about what was done, for a timesheet: no file paths, secrets, credentials
  or quotes from the conversation.

  ```bash
  tt-report --summary - <<'EOF'
  Added report fields to the heartbeat and the suggestions.
  EOF
  ```

Rules:

- Pass a title or summary only as `-` with a heredoc whose `'EOF'` is quoted,
  exactly as above, never inside quotes on the command line: an issue title
  can hold backticks or `$(...)`, which a shell would run. One text per call;
  `--issue` goes on the command line.
- Do not fetch an issue only to report it; use what you already know. Without
  a title, report the issue alone.
- Keep it to these calls: do not mention them to the user unless asked.
- If `tt-report` says reporting is off, stop reporting for this session.
