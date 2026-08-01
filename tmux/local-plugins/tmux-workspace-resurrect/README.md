# tmux-workspace-resurrect

Personal companion plugin for
[`tmux-resurrect`](https://github.com/tmux-plugins/tmux-resurrect). It keeps
Resurrect responsible for tmux topology while adding the application state that
process inspection cannot recover reliably.

The implementation borrows the sidecar and lifecycle-hook architecture of
[`tmux-assistant-resurrect`](https://github.com/timvw/tmux-assistant-resurrect),
but expands it to shell edit buffers, Neovim, and Treemux. Its restore behavior
is deliberately different: commands are placed in the restored shell and are
never executed automatically.

## Behavior

Every Resurrect save also records:

- The exact last command submitted by each integrated zsh pane.
- The current unsubmitted ZLE edit buffer and cursor position.
- Claude Code, Codex, and Pi session ids supplied by their native lifecycle
  APIs.
- A real Neovim session file containing buffers, windows, tabs, and cwd.
- Treemux main/sidebar relationships and the original Treemux arguments.

After Resurrect recreates the sessions, windows, pane names, cwd, and layouts,
this plugin chooses one command for each pane:

1. A supported application restore command.
2. Otherwise, a non-empty pending zsh buffer.
3. Otherwise, the last submitted zsh command.

The selected command is pasted through a tmux buffer without sending Enter.
Pending zsh buffers also return the cursor to its saved position.

## Installation and load order

The plugin is repository-owned and loaded manually from `tmux.conf`:

```tmux
run-shell '~/.config/tmux/local-plugins/tmux-workspace-resurrect/tmux-workspace-resurrect.tmux'
```

It uses the normal tmux plugin structure: an executable `*.tmux` entrypoint and
supporting scripts. It is not downloaded by TPM because its source already lives
inside this dotfiles repository.

The TPM list must keep `tmux-continuum` last. Continuum inserts its timer into
`status-right`; Catppuccin previously loaded after Continuum and replaced that
value, removing the timer. The last automatic Resurrect snapshot before this
fix was dated 2026-07-15.

The entrypoint:

- Reads `config.json`.
- Sets `@continuum-save-interval` to the configured five minutes.
- Enables Continuum restore.
- Sets `@resurrect-processes` to `false`.
- Chains its commands onto Resurrect's post-save and post-restore hooks.
- Adds `prefix + Ctrl-g` as a doctor command.

Continuum owns scheduling. Every five minutes it invokes Resurrect, which then
invokes this plugin's save hook. Manual `prefix + Ctrl-s` uses the same path.

## Configuration

`config.json` is the source of truth:

```json
{
  "autosave_interval_minutes": 5,
  "restore_mode": "queue",
  "capture": {
    "shell_buffers": true,
    "agent_sessions": true,
    "neovim_sessions": true,
    "treemux": true
  },
  "agents": ["claude", "codex", "pi"],
  "redact_patterns": []
}
```

`restore_mode` is intentionally `queue`. Automatic execution is unsupported.
The redaction list is reserved for a future opt-in policy; commands are
currently preserved exactly.

## Provider-owned integration files

The tmux plugin never rewrites provider settings at runtime. Each declaration
lives with its owning dotfile package and calls the plugin's shared recorder:

| Provider | Repository file | Installed path |
| --- | --- | --- |
| zsh | `zsh/.zsh/tmux-workspace-resurrect.zsh` | `~/.zsh/tmux-workspace-resurrect.zsh` |
| Claude | `claude/.claude/settings.json` | `~/.claude/settings.json` |
| Codex | `codex/.codex/hooks.json` | `~/.codex/hooks.json` |
| Pi | `pi/.pi/agent/extensions/tmux-workspace-resurrect.ts` | `~/.pi/agent/extensions/tmux-workspace-resurrect.ts` |
| Neovim | `nvim/lua/tmux_workspace_resurrect.lua` | `~/.config/nvim/lua/tmux_workspace_resurrect.lua` |
| tmux | `tmux/tmux.conf` | `~/.config/tmux/tmux.conf` |

Codex requires manual review of new or changed non-managed command hooks. Open
`/hooks` in Codex after restarting it and trust the user-level SessionStart
hook. Claude and Pi load their integration when a new process starts or an
existing process reloads its configuration.

Agent state is used only while the pane is running the corresponding launch
command. Stale lifecycle records do not turn an ordinary shell pane into an
agent pane.

## Runtime state

Live agent identity:

```text
${XDG_STATE_HOME:-~/.local/state}/tmux-workspace-resurrect/agents/
```

Companion snapshot:

```text
<tmux-resurrect-dir>/workspace_state.json
```

Neovim sessions:

```text
${XDG_STATE_HOME:-~/.local/state}/nvim/tmux-workspace-resurrect/
```

Directories are mode `0700`; state files are mode `0600`. State is intentionally
outside Git.

The sidecar stores logical pane targets such as `dotfiles:1.0`, not old tmux
`%pane` ids. The restore hook resolves those targets to the newly created pane
ids before reconstructing Treemux or queueing input.

Commands may contain passwords, tokens, or other inline secrets. Exact command
preservation means those values will exist in the private sidecar.

## Neovim and swap files

Neovim registers its RPC server and session file on the tmux pane. The save hook
asks a reachable Neovim instance to run `:mksession!` before writing the
sidecar. On restore the shell receives:

```sh
nvim -S '<session-file>'
```

Swap files remain enabled and retain their normal role: recovery of unsaved
buffer contents. They are not used to guess which files or layout were open.

The Treemux Neovim instance is excluded through `NVIM_APPNAME=nvim-treemux`.
Treemux itself is captured separately. On restore its inert placeholder sidebar
is removed and recreated through Treemux's own `toggle.sh`, establishing fresh
main/sidebar registrations and watcher processes.

## Commands

Run diagnostics:

```sh
~/.config/tmux/local-plugins/tmux-workspace-resurrect/scripts/doctor.sh
```

Or press `prefix + Ctrl-g`.

Create a manual Resurrect and companion save:

```sh
~/.config/tmux/plugins/tmux-resurrect/scripts/save.sh
```

Validate restore mappings without pasting input or rebuilding Treemux:

```sh
~/.config/tmux/local-plugins/tmux-workspace-resurrect/scripts/restore.sh --dry-run
```

Inspect metadata without printing saved command contents:

```sh
RESURRECT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
jq '{
  saved_at,
  resurrect_snapshot,
  panes: [.panes[] | {
    logical_id,
    selected_source,
    agent: .agent.tool,
    neovim: (.neovim != null)
  }],
  treemux
}' "$RESURRECT_DIR/workspace_state.json"
```

## Troubleshooting

If autosave stops, check that `status-right` still contains
`continuum_save.sh`:

```sh
tmux show-option -gqv status-right
```

If a provider session id is absent:

- Claude: restart Claude or start/resume a session after the settings change.
- Codex: restart Codex, open `/hooks`, and trust the user hook.
- Pi: restart Pi so the extension is loaded.
- Confirm the process is inside tmux and inherited `TMUX_PANE`.

Logs contain pane mappings and selected-state types, but not command contents:

```text
${XDG_STATE_HOME:-~/.local/state}/tmux-workspace-resurrect/workspace-resurrect.log
```

Restore intentionally skips an existing pane whose active process is not a
shell. This prevents an idempotent Resurrect run from typing recovery commands
into a live TUI or server.
