# Time Tracker for coding agents

Record the time you spend working with coding agents in the
[Time Tracker](https://github.com/lightofdata) app, including several sessions
running in parallel. Your sessions become suggested time entries, which you
confirm, adjust or discard in the app. Nothing is recorded until you confirm
it.

This repository holds the **Claude Code plugin**. It is also a Claude Code
plugin marketplace, so you install from it directly.

> Agent tracking is in testing and not yet in the store version of the app.

## Install

In a terminal:

```bash
claude plugin marketplace add lightofdata/time-tracker-agents
claude plugin install time-tracker@time-tracker-agents
```

Then, in Claude Code:

```text
/time-tracker:connect
```

It shows a code such as `WDJB-MJHT`. In the app, go to **Settings →
Integrations → Connected computers → Connect a computer**, enter the code, check
that the computer's name is right, and approve. The code is valid for 10
minutes. That screen also shows the command to run, for the server your build
of the app uses.

New sessions are tracked from then on. Each computer is connected once, for
every project on it.

**Testing a pre-release build of the app?** It talks to a test server; connect
to that one instead with `/time-tracker:connect staging`. A computer reports to
one server at a time, and connecting again switches it.

## Connecting with a connection token

For where nobody can run `/time-tracker:connect` and approve it in the app: CI,
or a machine image built ahead of time.

1. In the app, go to **Settings → Integrations → Connected computers →
   Advanced → Create a connection token**, and give it a name. The app shows
   two lines, the token and your server's address. Copy them: the token is
   shown only this once.
2. On the computer, with the plugin installed, save the two lines where its
   hook reads them, readable only by you:

   ```bash
   mkdir -p ~/.config/time-tracker
   cat > ~/.config/time-tracker/agent-hook.env   # paste, then Ctrl-D
   chmod 600 ~/.config/time-tracker/agent-hook.env
   ```

   The file looks like this:

   ```bash
   TT_API_TOKEN=tt_…
   TT_HEARTBEAT_URL=https://<server>/functions/v1/activity-heartbeat
   ```

The hook reads the file but never runs it, so a value is taken literally:
`$(...)` or a trailing `# comment` becomes part of it.

Instead of the file, `TT_API_TOKEN` and `TT_HEARTBEAT_URL` can be set in the
environment, which wins over the file: in CI, keep the token in the CI's
secrets.

The computer appears in the app's list under the name you gave the token.
Disconnecting it there stops it at once.

## What is sent

One small report, a _heartbeat_, when:

| Claude Code event  | Meaning                                  |
| ------------------ | ---------------------------------------- |
| `SessionStart`     | a session opened                         |
| `UserPromptSubmit` | you sent a prompt                        |
| `Stop`             | Claude finished answering and is waiting |
| `SessionEnd`       | a session closed                         |

Each carries the session id, the event, the time, and the repository
(`owner/name` from the `origin` remote, or the folder name) and branch the
session runs in.

**It never sends** your prompts, the transcript, or any file path.

The server groups each session's heartbeats into stretches of work. A stretch
ends after 15 minutes without a prompt from you, or where the branch changes,
and becomes one suggested entry. In the app, rules decide which project and
task a repository's time goes to; a branch such as `fix/123-login` can go to
the task for issue `#123`.

## How it behaves

- **It never gets in the way.** The hook prints nothing, always succeeds, and
  sends in the background, so a prompt is never held up.
- **Offline is fine.** A heartbeat that cannot be sent waits in a queue and
  goes with the next one that can.
- **On the free plan,** one session is tracked at a time. Pro tracks any
  number.

## Requirements

`bash`, `curl` and `git`, on macOS or Linux. Connecting also needs `sha256sum`
or, on macOS, `shasum`. No `jq`, Node or Python.

## Files

| Path                                    | What                                         |
| --------------------------------------- | -------------------------------------------- |
| `~/.config/time-tracker/agent-hook.env` | the token and server address, private to you |
| `~/.local/state/time-tracker/`          | the send queue, and a log of problems        |

`$XDG_CONFIG_HOME` and `$XDG_STATE_HOME` are honoured when set.

## Is it working?

- In the app, under Connected computers, the computer shows **Last used**
  within a few minutes of your first prompt.
- `~/.local/state/time-tracker/agent-hook.log` has a line for every problem: a
  missing token, a refused batch, a failed send. No log file means nothing has
  gone wrong.
- A `401` in the log means the computer was disconnected in the app: run
  `/time-tracker:connect` again.

If you set up the hook by hand before this plugin existed, remove those four
entries from `~/.claude/settings.json`, or each event is reported twice.

## Uninstall

```bash
claude plugin uninstall time-tracker@time-tracker-agents
rm -rf ~/.config/time-tracker ~/.local/state/time-tracker
```

Then disconnect the computer in the app.

## Development

```bash
tests/run.sh                      # all tests; needs python3 for the fake server
TEST_BASH=/bin/bash tests/run.sh  # under macOS's bash 3.2
claude plugin validate ./claude
```

To try a change, add this folder as a marketplace instead:
`claude plugin marketplace add ./`. To connect to any other server, such as a
local one, pass its functions URL: `/time-tracker:connect
http://127.0.0.1:<port>/functions/v1`. Plain `http://` is accepted only for
`localhost` and `127.0.0.1`, so the token never crosses a network unencrypted.

## License

[MIT](LICENSE)
