# Focus-agent profiles

`claudef` and `pif` are opt-in focus profiles layered over the normal Claude
Code and Pi installations. Bare `claude` and `pi` keep their native behavior.
The split matters because other programs may invoke those binaries and must not
inherit interactive prompts, extensions, themes, or focus instructions.

Codex is outside this profile system.

## Ownership model

The existing `claude/` and `pi/` Stow packages own both native support files
and focus configuration. There are no separate `claudef/` or `pif/` Stow
packages.

```text
claude/
├── .claude/                 intentional global behavior and native support
└── .config/claudef/         focus-only Claude configuration

pi/
├── .pi/                     native runtime support, if needed
└── .config/pif/             focus-only Pi configuration
```

Authentication, transcripts, caches, project history, telemetry, and other
mutable runtime data stay in each tool's native directory. Do not commit them
or duplicate credentials into a focus profile.

## Claude profile

The shell function `claudef` delegates to the stowed
`claude/.local/bin/claudef` executable. Keeping the launcher in an executable
means an update takes effect in already-running tmux shells. A shell function
containing the full launcher would remain frozen until each shell reloaded.

The launcher keeps Claude's native runtime under `~/.claude` and applies the
focus profile explicitly:

```text
--settings ~/.config/claudef/settings.json
--setting-sources user,project,local
--plugin-dir ~/.config/claudef
--append-system-prompt-file ~/.config/claudef/communication.md
```

The user setting source remains enabled for two intentional global behaviors:

- `~/.claude/keybindings.json`
- `~/.claude/commands/plan.md`

Claude has no per-invocation keybindings option, and a session plugin cannot
replace the built-in `/plan` command under its unqualified name. These files
therefore affect both `claude` and `claudef`. All other managed Claude behavior
is focus-only.

Focus settings enable the LSP plugins already installed in Claude's native
plugin cache. Native user settings leave those plugins disabled, so bare
Claude does not activate them. The ccline runtime and OAuth lookup also stay
native. Launcher-created links select the tracked configuration under
`~/.config/claudef/ccline/`, and the tracked status-line wrapper adds the
current effort to ccline's model segment.

Do not add `--append-subagent-system-prompt` to the interactive launcher. The
flag is print-only in the Claude versions against which this profile was
designed. Test subagent prompt inheritance as its own change if that behavior
is needed later.

## Pi profile

Pi couples configuration and runtime state under `PI_CODING_AGENT_DIR`, and it
does not have Claude's settings-overlay flags. `pif` therefore points that
variable at `~/.config/pif` and creates runtime-only links back to
`~/.pi/agent` for:

- `auth.json`
- `models-store.json`
- `trust.json`
- `pi-debug.log`
- `npm/`
- `git/`

`PI_CODING_AGENT_SESSION_DIR` points directly at `~/.pi/agent/sessions`.
This keeps authentication, package caches, catalog state, trust decisions, and
session history native while extension and theme discovery remain isolated.

The profile applies the canonical communication prompt from
`agents/communication.md` and loads the tracked configuration under
`pi/.config/pif/`:

- `settings.json` and `keybindings.json`
- the `personal` theme
- status-line and tmux session-recording extensions
- `pi-vim` and `pi-fzfp`
- the locally maintained `session-replay` and `subagent-widget` derivatives

The two derivatives retain their upstream MIT notices. They do not depend on
Disler's `themeMap.ts`; rendering uses this repository's active theme.

### Subagents

`subagent-widget.ts` starts each child as a separate Pi process with its own
persistent session. Children share the working directory and filesystem, but
they do not inherit the parent conversation or a dynamically appended system
prompt.

Children receive Pi's complete built-in tool set:

```text
read,write,edit,bash,grep,find,ls
```

`--no-extensions` prevents recursive extension loading. The extension passes
the communication prompt and explicit scope rules to each child. Those rules
allow implementation inside the delegated scope, forbid unrelated reversions,
and require the child to report its changes and checks.

Completed child reports use Pi's `steer` delivery mode. Pi inserts them before
the coordinator's next model call, so the coordinator can synthesize the
reports and its response remains the last visible message. The reports remain
visible for inspection.

### Replay

Session replay remains command-only. It must not change the terminal title or
active theme.

`system-select` and `pi-pi` are deliberately absent. The first has no defined
focus personas here and may replace the active tool set. The second is a
specialized orchestration mode that changes the system prompt and expects a
project-local expert catalog.

## Shared communication and provenance

Both profiles use `agents/communication.md`. Its upstream inspirations and the
two Pi derivatives are recorded in `upstream-sources.json`. The profile
skill links reserve `agents/skills/upstream-audit/SKILL.md` as their canonical
target. Keep that target present when enabling agent-triggered audits. See
[`upstream-sources.md`](upstream-sources.md) for the review contract.

## Implementation map

| Concern | Source of truth |
| --- | --- |
| Claude launcher | `claude/.local/bin/claudef` |
| Pi launcher and runtime links | `zsh/.zshrc`, function `pif` |
| Claude focus profile | `claude/.config/claudef/` |
| Intentional global Claude files | `claude/.claude/keybindings.json`, `claude/.claude/commands/plan.md` |
| Pi focus profile | `pi/.config/pif/` |
| Shared prompt | `agents/communication.md` |
| Profile cleanup and doctor checks | `setup/lib.sh`, `setup/headless-doctor.sh` |
| Upstream audit | `upstream-sources.json`, `scripts/audit-upstreams.py`, `agents/upstream_audit.md` |

## Maintenance checks

When changing either profile, verify these boundaries:

1. Bare `pi` loads no dotfiles-managed focus resources.
2. Bare `claude` loads only the two intentional global behaviors.
3. `pif` retains native OAuth and sessions while loading only the focus Pi
   resources.
4. `claudef auth status` uses native OAuth and the native transcript directory.
5. A fresh-shell `claudef --resume <session-id>` loads the explicit focus
   settings, prompt, skill, LSPs, and ccline status line.
6. Pi child sessions can write, edit, continue, and report back without loading
   the parent extensions.
7. Subagent reports appear before the coordinator response, and `/replay` does
   not mutate theme or title.
8. Profile launches do not write mutable runtime data into tracked paths.

The migration and noninteractive isolation checks were completed in September
2026.
