# tmux-workspace-resurrect

Personal companion plugin for
[`tmux-resurrect`](https://github.com/tmux-plugins/tmux-resurrect). It keeps
Resurrect responsible for tmux topology while adding the application state that
process inspection cannot recover reliably.

The implementation borrows the sidecar and lifecycle-hook architecture of
[`tmux-assistant-resurrect`](https://github.com/timvw/tmux-assistant-resurrect),
but expands it to shell edit buffers, Neovim, and Treemux. Restoration can
automatically resume explicitly whitelisted applications. Other commands stay
in the shell's edit buffer for the user to submit.

## Behavior

Every Resurrect save also records:

- The exact last command submitted by each integrated zsh pane.
- The current unsubmitted ZLE edit buffer and cursor position.
- Claude Code and Pi session ids supplied by their lifecycle integrations,
  and live Codex session ids recovered from its native process and open
  rollout file.
- A real Neovim session file containing buffers, windows, tabs, and cwd.
- Treemux main/sidebar relationships and the original Treemux arguments.

After Resurrect recreates the sessions, windows, pane names, cwd, and layouts,
this plugin chooses one command for each pane:

1. A non-empty pending zsh buffer, preserved without execution.
2. Otherwise, a supported application restore command.
3. Otherwise, the last submitted zsh command.

Recognized running Claude, Pi, Codex, and Neovim sessions can be automatically
resumed through `claudef`, `pif`, `codexf`, and `nvim -S`. Agent commands use
recorded session IDs. Launches are spaced by 500 ms after shell readiness.
An application that had already exited at save time is not auto-launched.

Everything outside that whitelist is pasted without Enter. Pending zsh buffers
always take this path, even if their text names a whitelisted application.
Their multiline content and saved cursor position are preserved.

## Installation and load order

The plugin is repository-owned and loaded manually from `tmux.conf`:

```tmux
run-shell '~/.config/tmux/local-plugins/tmux-workspace-resurrect/tmux-workspace-resurrect.tmux'
```

It uses the normal tmux plugin structure: an executable `*.tmux` entrypoint and
supporting scripts. It is not downloaded by TPM because its source already lives
inside this dotfiles repository.

Continuum remains installed for startup restoration only. Its status-driven
save scheduler is disabled; a launchd/systemd job supplies periodic saving
when explicitly enabled. The status chip displays the last verified save's
age, not whether that scheduler is running.

The entrypoint:

- Reads `config.json`.
- Sets `@continuum-save-interval` to zero and exposes the intended timer interval.
- Enables Continuum restore.
- Sets `@resurrect-processes` to `false`.
- Chains its commands onto Resurrect's post-save and post-restore hooks.
- Adds `prefix + Ctrl-g` as a doctor command.

Manual `prefix + Ctrl-s` invokes the verified save wrapper and this plugin's
save hook. Periodic saving may remain disabled independently of manual saving.

Local startup restoration and the confirmed manual restore binding use
`tmux/scripts/resurrect_restore.sh`. It shares an exclusive lock with saving
and requires a completion acknowledgement from this plugin. Saves are refused
while restoration is active or incomplete. A failed restore keeps saving
blocked for that tmux server until a guarded retry completes. This does not
enable the periodic timer or provide cross-restart backup retention.

## Configuration

`config.json` is the source of truth:

```json
{
  "autosave_interval_minutes": 5,
  "restore_mode": "whitelist",
  "restore_whitelist": {
    "names": ["claudef", "pif", "codexf", "nvim"],
    "delay_ms": 500
  },
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

`restore_mode: "whitelist"` enables the restricted resume policy above.
Use `"queue"` to leave every command awaiting Enter. Removing a name from
`restore_whitelist.names` makes that application queue-only. Arbitrary names
do not authorize arbitrary shell execution; only the supported resume types
are eligible.
The redaction list is reserved for a future opt-in policy; commands are
currently preserved exactly.

## Provider-owned integration files

The tmux plugin never rewrites provider settings at runtime. The declarations
below live with their owning dotfile packages and call the plugin's shared
recorder. Codex has no repo-managed config or hooks and uses native
live-session recovery instead:

| Provider | Repository file | Installed path |
| --- | --- | --- |
| zsh | `zsh/.zsh/tmux-workspace-resurrect.zsh` | `~/.zsh/tmux-workspace-resurrect.zsh` |
| Claude focus | `claude/.config/claudef/settings.json` | `~/.config/claudef/settings.json` |
| Pi focus | `pi/.config/pif/extensions/tmux-workspace-resurrect.ts` | `~/.config/pif/extensions/tmux-workspace-resurrect.ts` |
| Neovim | `nvim/lua/tmux_workspace_resurrect.lua` | `~/.config/nvim/lua/tmux_workspace_resurrect.lua` |
| tmux | `tmux/tmux.conf` | `~/.config/tmux/tmux.conf` |

Claude and Pi load their integration when a new process starts or an existing
process reloads its configuration. Codex requires no hook installation or
trust step. Setup still installs Codex CLI, but does not seed
`~/.codex/config.toml`; `codexf` loads shared instructions directly from
`$DOTFILES/agents/communication.md`.

Agent state is considered only when the last submitted command identifies the
agent and no pending shell edit buffer or Neovim restore takes precedence.
Normal and focus launcher names both map to the focus launcher on restoration:

- `claudef --resume <recorded-session-id>`
- `pif --session <recorded-session-id>`
- `codexf resume <recorded-session-id>`; the wrapper forwards arguments unchanged.

Old session selectors are replaced, never reused. Supported simple flags are
preserved; ambiguous arguments and old task prompts are omitted. A literal
`cd <path> && <launcher>` prefix retains its directory. Resume text is quoted
as shell arguments, not evaluated while saving.

New recorder entries bind the ID to a tmux server incarnation and pane PID.
They are stored in a server-incarnation directory, so equal pane numbers in
different tmux servers cannot overwrite each other's registrations. Legacy
flat files are read-only fallback, never new-write targets.
Legacy records require the same pane/tool/cwd and a timestamp no older than
the running server. This compatibility check cannot prove process ownership
as strongly as a new hook record or verified native Codex recovery; a fresh
Claude or Pi registration supplies the stronger recorded identity. Missing, malformed or stale records produce `agent_capture_errors`
in the staged sidecar and no bare resume picker. The verifier rejects the
attempt without replacing the previous published checkpoint or timestamp.
The error identifies the affected panes.

For live Codex panes, saving checks the native Codex process descended from
that pane and the session metadata in its open rollout file. A uniquely
verified main-session ID takes precedence over a legacy record. This recovers
IDs without restarting Codex, guessing by cwd, or relying on Codex hooks.
Ambiguous associations fail closed.

## Runtime state

Live agent identity:

```text
${XDG_STATE_HOME:-~/.local/state}/tmux-workspace-resurrect/agents/
```

Companion snapshot:

```text
<tmux-resurrect-dir>/<snapshot-name>.workspace_state.json
```

`last` selects the layout and its matching immutable companion. The familiar
`workspace_state.json` name remains a compatibility symlink to the newest
companion. Older layouts without a paired companion use the legacy sidecar.

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

Neovim registers its RPC server and a private, per-editor session generation on
the tmux pane. The save hook requires a successful persistence acknowledgement
and refreshes the registered filename before writing the sidecar. On restore
the shell receives:

```sh
nvim -S '<session-file>'
```

The session is one atomic `.vim` file containing both the editor layout and
inline snapshots of loaded ordinary buffer text, including unnamed and modified
buffers. Text changes refresh it on a 750ms coalesced timer, independent of tmux
saves; this does not launch tmux subprocesses or regenerate the layout for each
keystroke. Layout changes and explicit saves refresh the complete session.

Startup waits for the session to finish loading and writes to a new editor
generation, never the `-S` file currently being consumed. Restoring reconstructs
buffer text in memory and preserves modified state, without overwriting source
files. Normal swap behavior resumes after the scoped session-loading guard;
swaps remain a secondary recovery mechanism, not the normal restoration path.
An abrupt crash can still lose edits newer than the last completed snapshot.
Legacy sessions created before this change contain file references only and
cannot recover missing or unnamed text without a separate swap/history source.

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

Create and verify a manual Resurrect and companion save:

```sh
~/.config/tmux/scripts/resurrect_save.sh
```

Normally use `prefix + Ctrl-s`. The post-TPM binding calls this verified
wrapper and resets the powerline age to `0m` only after the Resurrect snapshot
and workspace sidecar both pass validation.

Saving batches pane metadata, agent-record processing, and Treemux registration
lookups. The local Resurrect process-capture patch also skips its per-pane
system-process scans when `@resurrect-processes` is `false`; exact agent resumes
come from the validated workspace sidecar, not those unused process commands.
Neovim RPC saves retain their timeout, and complete pane coverage and exact
agent IDs are still required before the successful-save timestamp advances.

The verified wrapper writes to a private staging directory first. It publishes
the validated layout and matching metadata before atomically changing `last`.
Failed validation never replaces the previous checkpoint. Same-second saves
use distinct filenames. The setup patch supplies staging-path overrides to
upstream Resurrect without changing the live tmux server's directory option.

Manual and periodic saves follow this same path. Retention is age-based:
`@resurrect-delete-backup-after` defaults to 30 days, and the newest five layouts
are always retained. Matching sidecars are pruned with their layouts in one
directory scan. There is no fixed snapshot-count cap. At five-minute intervals,
there are 288 saves per day when the timer is active continuously.

The separate `recovery-bundles/` emergency checkpoint is manually created,
includes copied native histories, and has no automatic expiry. Ordinary saves
do not duplicate that large bundle. The periodic timer remains independently
enabled or disabled; these changes do not turn it on.

To measure a complete verified save (this writes a new save):

```sh
/usr/bin/time -p bash ~/.config/tmux/scripts/resurrect_save.sh
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

If autosave stops, run the health check. It verifies the operating-system
timer, successful-save marker, snapshot, sidecar, save lock, and Neovim
registrations:

```sh
~/.config/tmux/local-plugins/tmux-workspace-resurrect/scripts/doctor.sh
```

If a provider session id is absent:

- Claude: restart Claude or start/resume a session after the settings change.
- Codex: confirm the live native process belongs to the pane and has a
  readable open rollout file with a uniquely verified main-session ID.
  Recovery does not use a repo-managed hook.
- Pi: restart Pi so the extension is loaded.
- Confirm the process is inside tmux and inherited `TMUX_PANE`.

Logs contain pane mappings and selected-state types, but not command contents:

```text
${XDG_STATE_HOME:-~/.local/state}/tmux-workspace-resurrect/workspace-resurrect.log
```

Restore intentionally skips an existing pane whose active process is not a
shell. This prevents an idempotent Resurrect run from typing recovery commands
into a live TUI or server.
