# pharos

Keep one Claude Code Remote Control server (`claude rc`) running on a Linux machine,
so you can always start sessions on it from the Claude mobile app or claude.ai/code. It
also handles two things `claude rc` doesn't do on its own:

- **Keeping phone sessions in bypass permissions mode.** The app switches new sessions
  to Auto unless the machine refuses.
- **Removing stale entries from the app.** A stopped server's entry stays listed
  forever, and the CLI has no command to remove it.

It is a systemd user service with a small bash wrapper. Restarting the service gives
you exactly one fresh entry in the app; stopping it leaves none.

> The cleanup uses an undocumented Anthropic API endpoint, taken from Claude Code's own
> client code. It can change or break in any Claude Code release. Everything else uses
> documented behaviour.

## Install

Requires Linux with a systemd user manager, `bash`, `jq`, `curl`, `flock`, and Claude
Code logged in with a claude.ai subscription (not an API key).

```bash
git clone https://github.com/shitchell/pharos.git
cd pharos
./install.sh
```

This installs `~/.local/bin/claude-rc-service` and
`~/.config/systemd/user/claude-rc.service`, sets `permissions.disableAutoMode` to
`"disable"` in `~/.claude/settings.json`, and enables and starts the service. Re-run it
after pulling updates; it restarts the service so the new files take effect.

The service starts when you log in. To start it at boot without logging in, run
`loginctl enable-linger`.

Don't also run `claude rc` by hand in `~`. Remote Control allows one server per folder
per machine, so the second one fails with a 409.

To remove it: `./install.sh --uninstall`. This stops the service, which cleans up its
entries, and removes both files. It leaves `disableAutoMode` set; remove that by hand if
you want Auto mode back.

## Use

```bash
systemctl --user restart claude-rc     # clean up, then one fresh server
systemctl --user stop claude-rc        # stop; the app no longer lists this machine
systemctl --user start claude-rc       # clean up leftovers, then start
systemctl --user status claude-rc
journalctl --user -u claude-rc -f      # server output, plus each cleanup action
claude-rc-service cleanse --dry-run    # show what a cleanup would delete
```

Optional per-machine settings go in `~/.config/claude-rc-service.conf`, which is sourced
as bash. For example, to skip the idle session `claude rc` starts by default, which
saves about 200 MB on a small machine:

```bash
CLAUDE_RC_EXTRA_ARGS=(--no-create-session-in-dir)
```

## How it works

### The service

`claude-rc.service` runs `claude-rc-service run`, which:

1. cleans up entries left by earlier runs (see below), so a crash is cleaned up on the
   next start;
2. marks `~` as trusted in `~/.claude.json` if it isn't, because `claude rc` won't
   serve an untrusted folder;
3. starts `claude rc --spawn same-dir --permission-mode bypassPermissions` with
   `ANTHROPIC_API_KEY` removed from its environment, and waits on it.

`Restart=always` restarts it if `claude rc` exits. It needs no terminal or tmux: with the
API key removed, it runs fine with stdin at `/dev/null`.

### Stop and restart: the SIGTERM trap

`systemctl --user stop` and `restart` send SIGTERM. The unit sets `KillMode=mixed`, so
only the wrapper gets it. With the default mode, `claude rc` would be killed at the same
moment and nothing could clean up after it. The wrapper's trap then:

1. sends `claude rc` SIGINT, the same as Ctrl-C, and waits up to 40 seconds for it to
   exit;
2. falls back to SIGTERM if it hasn't;
3. cleans up, and exits.

One detail matters here: bash starts background jobs with SIGINT ignored, so a plain
`claude rc &` would ignore the SIGINT. The wrapper launches it as
`( trap - INT; exec ... ) &` to undo that.

### Why bypass mode needs `disableAutoMode`

`--permission-mode bypassPermissions` on `claude rc` is not enough. The app's New
Session picker offers Manual, Accept edits, Plan and Auto, never Bypass. When a session
starts, the app sends the picker's selection to the machine:

```
{"request":{"mode":"auto","subtype":"set_permission_mode"}, ...}
```

The session accepts it and switches from bypass to Auto. Setting
`permissions.disableAutoMode` to `"disable"` makes the session refuse that request
(`Cannot set permission mode to auto: auto mode disabled by settings`), so it stays in
bypass.

**The app still shows Auto. That label is wrong.** Check the real mode in the session's
transcript:

```bash
jq -r 'select(.permissionMode) | .permissionMode' ~/.claude/projects/-home-$USER/<session>.jsonl | tail -1
```

Limits:

- This disables Auto mode for every Claude Code session on the machine, including CLI
  sessions. `claude rc` doesn't accept `--settings`, so it can't be limited to the
  server. A folder's `.claude/settings.local.json` also works, but only for sessions in
  that folder.
- Only Auto is blocked. Choosing Manual, Accept edits or Plan in the app still switches
  the session, and the app can't switch back to bypass.

### Why the cleanup is needed

`claude rc` registers an *environment*, which is the machine entry you pick in the app.
On shutdown it deliberately leaves that registered so sessions can reconnect later,
logging `Skipping archive+deregister to allow resume`. The entry outlives the process,
and even the folder. No `claude` command removes it.

The server records its environment ID in a pointer file,
`~/.claude/projects/<folder>/bridge-pointer.json`, with `"source": "standalone"`. While
that file exists, a restarted server reuses the same environment.

The cleanup deletes an environment only if all three hold:

- the API lists it as a Remote Control environment (`config.type` is `bridge`);
- its `metadata.machine_id` equals this machine's `remoteControlMachineId` in
  `~/.claude.json`;
- a `"standalone"` pointer on this machine names it.

It deletes it with `DELETE /v1/environments/bridge/{id}`, the call Claude Code makes
internally, then removes those pointers so the next start registers a fresh environment.
Cloud environments, other machines' entries, and interactive sessions are left alone.
Environments of this machine that no pointer names are reported in the log and kept,
because nothing proves `claude rc` made them.

The login token is read from `~/.claude/.credentials.json` and passed to curl on stdin,
so it never appears in a process list.

## Findings, with evidence

All measured on 2026-11-07 against Claude Code 2.1.283 and 2.1.319, using a phone,
debug logs (`claude rc --debug-file`), session transcripts, and API calls.

| Finding | Evidence |
|---|---|
| The app sends Auto at session start, overriding the server's bypass flag | Debug log showed the `set_permission_mode` request; the transcript recorded `auto`; the launch flag still said `bypassPermissions` |
| `disableAutoMode` keeps the session in bypass | Request refused with `auto_mode_settings`; the transcript recorded `bypassPermissions`; a Bash call ran with no prompt |
| The Auto label is cosmetic | It stayed on Auto in a brand-new environment after the old ones were deleted |
| `--permission-mode bypassPermissions` behaves like `--dangerously-skip-permissions` | Both start a session in bypass and both accept a switch back to it; with neither, the switch is refused |
| A stopped server's entry persists | Seen in the app after the process and folder were gone; the CLI's shutdown code skips deregistering |
| The DELETE call removes an entry | HTTP 200 `environment_deleted`, several times, on two accounts |
| Interactive `/rc` sessions aren't affected | `claude --remote-control` wrote no pointer and registered no environment |
| `claude rc` needs no terminal | Connected with no TTY and stdin at `/dev/null` |
| `ANTHROPIC_API_KEY` breaks Remote Control | With it set, the server showed Ready but every session failed with "Couldn't verify your organization's policy" |

## Troubleshooting

- **A phone session says Auto.** That's expected; see above. Check the transcript.
- **`Session failed: Process exited with error` right after a restart.** This was traced
  once to `Epoch mismatch (409, reason=session_not_active)`: an old session that can't
  reconnect, not a crash. Start a new session.
- **`Couldn't verify your organization's policy for remote control`.** Check for
  `ANTHROPIC_API_KEY` in the server's environment. The wrapper removes it, so if you see
  this, a `claude rc` outside the service is probably running.
- **The cleanup logs an HTTP error.** The undocumented endpoint may have changed.
  Stopping and starting still work; old entries just stay listed.
