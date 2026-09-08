# Focus-agent profile isolation

Status: ready for implementation

## Goal

Keep the top-level `claude/` and `pi/` Stow packages. Their managed behavior is for the opt-in `claudef` and `pif` launchers only. Bare `claude` and bare `pi`, including programmatic invocations by other systems, must not discover these settings, prompts, extensions, themes, hooks, commands, or packages.

The native runtime locations may still hold credentials, sessions, caches, and genuinely global runtime state. They must not contain focus-agent behavior merely because the dotfiles were installed.

Codex is out of scope.

## Required package layout

Use both native runtime paths and focus-specific config paths inside the existing Stow packages:

```text
claude/
├── .claude/                 # only genuinely global/native runtime support, if needed
└── .config/
    └── claudef/             # all focus-agent Claude configuration

pi/
├── .pi/                     # only genuinely global/native runtime support, if needed
└── .config/
    └── pif/                 # all focus-agent Pi configuration
```

Do not create top-level `claudef/` or `pif/` Stow packages.

The `.claude/` and `.pi/` trees may be empty in the repository if no tracked setting is truly global. Authentication and mutable runtime state must never be committed.

## Launcher behavior

### `pif`

`pif` must set:

```text
PI_CODING_AGENT_DIR=$HOME/.config/pif
```

The directory is populated through the existing `pi/` Stow package. This preserves Stow ownership while using Pi's supported profile-isolation mechanism.

The launcher must apply the canonical `agents/communication.md` prompt. It may share the native Pi session directory if that is useful, but profile configuration and extension discovery must remain isolated.

Pi credentials require a runtime-only bridge or another verified mechanism because changing `PI_CODING_AGENT_DIR` also changes Pi's `auth.json` lookup. Do not copy credentials into the repository. Validate token refresh and login behavior before choosing the bridge.

### `claudef`

`claudef` must set:

```text
CLAUDE_CONFIG_DIR=$HOME/.config/claudef
```

The directory is populated through the existing `claude/` Stow package. Move the current focus settings, statusline configuration, command, keybindings, hooks, and communication prompt there.

Changing `CLAUDE_CONFIG_DIR` can change Claude Code's secure-storage namespace. Test OAuth reuse and refresh behavior. Either authenticate this profile independently or use a verified runtime-only secure-storage bridge. Do not copy secrets into the repository.

### Claude subagent prompt flag

Do not include `--append-subagent-system-prompt` in the new interactive `claudef` launcher.

Claude Code 2.1.263 describes this hidden option as appending a prompt to Task-tool subagents, propagating to nested subagents, and working only with `--print`. It is not needed for profile isolation and does not provide a justified benefit to the normal interactive launcher.

`--append-system-prompt-file` remains useful because it applies `agents/communication.md` to the primary focus session. If native Claude subagent behavior is intentionally added later, test prompt inheritance separately rather than retaining an undocumented or print-only flag.

## Pi focus profile

Move all currently managed Pi behavior under `pi/.config/pif/`:

- `settings.json`
- canonical communication prompt link
- personal theme
- statusline extension
- tmux workspace recorder extension
- `pi-vim` and `pi-fzfp` package activation
- locally maintained derived extensions listed below

Initial derived extensions:

- `subagent-widget.ts`
- `purpose-gate.ts`
- `session-replay.ts`

Do not initially include:

- `system-select.ts`
- `pi-pi.ts`
- unrelated extensions from `pi-vs-claude-code`

### Derived subagent behavior

Maintain the extension in this repository. Do not load it from an external checkout.

Children must receive Pi's complete built-in tool set:

```text
read,write,edit,bash,grep,find,ls
```

The old `read,bash,grep,find,ls` list was behavioral steering, not a security boundary. Unrestricted `bash` already allowed writes. No explicit rationale was found in the source, documentation, or commit history.

Each child is a separate `pi` process with its own persistent session. It shares the parent's working directory and filesystem but does not inherit the parent conversation or dynamically appended system prompt. Add concise child guidance that permits implementation when assigned and requires it to:

- stay within its delegated scope
- avoid reverting unrelated changes
- avoid editing files owned by concurrent children
- run relevant checks
- report changed files, checks, and unresolved concerns
- create handoff files only when requested

Keep `--no-extensions` for children to prevent recursive or accidental extension loading. Ensure the communication behavior expected from children is passed deliberately rather than assumed to propagate.

### Purpose Gate and replay

Include both extensions, but remove their dependency on Disler's `themeMap.ts`.

Adapt Purpose Gate rendering to the active personal theme. Preserve its session-purpose prompt injection.

Keep session replay command-only. It must not change the terminal title or active theme.

### Excluded modes

`system-select` prepends a selected persona to Pi's existing system prompt, so it does not inherently remove the communication prompt. It may replace the active tool set from agent frontmatter. Omit it until there are intentional focus personas that need it.

`pi-pi` is a specialized orchestration mode, not baseline support. It adds persistent tool-schema and expert-catalog context, expects project-local expert definitions, changes UI behavior, and replaces rather than appends the current system prompt. Omit it.

## Implementation tasks

- [ ] Move focus-only Claude files from `claude/.claude/` to `claude/.config/claudef/`.
- [ ] Move focus-only Pi files from `pi/.pi/agent/` to `pi/.config/pif/`.
- [ ] Leave only proven global/native support in the repository's `.claude/` and `.pi/` paths.
- [ ] Update Stow installation and doctor checks without introducing new top-level packages.
- [ ] Update `claudef` and `pif` in `zsh/.zshrc`.
- [ ] Remove `--append-subagent-system-prompt` from interactive `claudef`.
- [ ] Add and adapt the three derived Pi extensions.
- [ ] Add runtime-only credential handling for each isolated profile.
- [ ] Add provenance and audit support from `docs/tasks/upstream-sources.md`.

## Validation

- [ ] A clean shell running bare `pi` loads no dotfiles-managed packages, extensions, themes, or communication prompt.
- [ ] A clean shell running bare `claude` loads no dotfiles-managed settings, hooks, commands, statusline, keybindings, or communication prompt.
- [ ] `pif` loads only the intended focus profile and retains usable credentials.
- [ ] `claudef` loads only the intended focus profile and retains usable credentials.
- [ ] `pif` children can use `write` and `edit`, continue through `/subcont`, and report results to the parent.
- [ ] Parallel children can complete disjoint implementation tasks without overwriting one another.
- [ ] Purpose Gate preserves the personal theme and injects the chosen purpose.
- [ ] `/replay` works without changing the theme or terminal title.
- [ ] Existing Pi and Claude sessions remain available according to the chosen runtime-sharing policy.
- [ ] Programmatic bare invocations remain unaffected by focus-agent configuration.
