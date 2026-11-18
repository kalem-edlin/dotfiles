---
name: remote-handoff
description: Hand the directory this chat works in, with every pane in it, to an always-on worker, or bring it back, and continue this same conversation on the other side. Use on /remote-handoff to [worker] or /remote-handoff back, and on "hand this off to the worker", "move this to the remote", "run this on the worker", "bring it back", "hand it back to the laptop".
disable-model-invocation: true
---

Move the root this chat works in (its git worktree's top, or its folder) between the laptop and a worker, with every pane in it. `rw` stops this agent once the turn ends, moves the files, and resumes this same session on the other side (`claudef --resume <id>` or `pif --session <file>`), so the conversation goes on there. Nothing to commit or install. The copy left behind stays frozen. Unsaved editor buffers in the root are the user's to save first.

## 1. Read the direction

- `to [worker]` (also "off", "remote", "to the worker"): hand off. The worker is the alias the user named; with none named, leave `--worker` out and `rw` uses the only configured worker (it refuses and lists the aliases when there are several: ask which).
- `back` (also "home", "to the laptop"): hand back.

## 2. Check which side you are on

```sh
tmux display-message -p -t "$TMUX_PANE" '#{session_name}'
```

A name of the form `rw-<8 hex>-<8 hex>` means this chat runs on the worker; anything else is the laptop. Asked for the side you are already on: say so in one line and stop.

## 3. Start the transfer as the last tool call of the turn

On the laptop, to the worker:

```sh
rw bg handoff --worker <alias> --pane "$TMUX_PANE"
```

On the worker, back:

```sh
rw request handback
```

`rw` is on PATH (`~/.local/bin`); otherwise use `"$HOME/.config/tmux/local-plugins/tmux-remote-workspaces/scripts/rw"`. Both return at once. They must not be followed by more work: `rw` refuses to move a root from inside its agent's own pane and while that agent is working, so a detached runner waits for this turn to end, then stops this agent, moves the root and resumes the session on the other side.

## 4. Reply in one line and end the turn

`handing off <root> to <alias> when this turn ends; continuing there`, or `handing <root> back when this turn ends; continuing on the laptop`.

If the command exits non-zero it printed one `rw: ...` line (the root is outside `~` or already remote, a transfer of it is already running, wrong side): report that line instead and stop. Later failures show the user a dialog on the laptop with the log path; the chat then stays where it was.
