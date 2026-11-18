# Focus-agent profiles

`claudef`, `pif`, and `codexf` are opt-in focus launchers layered over the
normal Claude Code, Pi, and Codex installations. Bare `claude`, `pi`, and
`codex` keep their native behavior. The split matters because other programs
may invoke those binaries and must not inherit interactive prompts, extensions,
themes, or focus instructions.

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

Codex has no repo-managed Stow package, config, or hooks. Setup installs the
CLI but does not seed `~/.codex/config.toml`. Codex owns its native settings
and runtime data.

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
--system-prompt-snapshot off
--append-system-prompt-file ~/.local/state/focus-agents/prompt.md
```

The generated prompt contains `agents/communication.md`. Prompt snapshots are
disabled so resumed conversations receive the current rules instead of keeping
the system prompt recorded when the conversation was created.

The user setting source remains enabled for two intentional global behaviors:

- `~/.claude/keybindings.json`
- `~/.claude/commands/plan.md`

Claude has no per-invocation keybindings option, and a session plugin cannot
replace the built-in `/plan` command under its unqualified name. These files
therefore affect both `claude` and `claudef`. All other managed Claude behavior
is focus-only.

The plugin directory also ships `agents/`, a link to `agents/subagents/`,
so the subagents defined there (today `research`) are available to
`claudef` under the plugin namespace, as `dotfiles-focus:research`. Bare
`claude` never loads the plugin and does not see them.

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

### Agent Bash stdin

Claude Code gives each agent Bash call a socket as stdin, and that socket never
reaches EOF. A command that reads stdin blocks until the 120 s tool timeout,
then Claude Code moves it to the background and the agent waits on a task that
will never finish. The original case was `cat > file` with `cat` aliased to
`bat`: a subagent waited 3.4 hours.

Two fixes cover this:

- The `PreToolUse` hook `hooks/bash-close-stdin.sh` prepends
  `exec </dev/null` to every Bash command, so reads get EOF at once. Heredocs
  and pipes carry their own input and still work.
- `zsh/.zshrc` skips the `cp -iv`, `mv -iv`, `grep -i`, `find` to `fd`, and
  `cat` to `bat` aliases when `CLAUDECODE` is set. Agent shells get the plain
  coreutils, which match the flags agents expect.

The hook lives in the focus profile only. Bare `claude` is intentionally not
covered, so programs that invoke it keep native behavior. The zsh guard applies
to any Claude Code shell.

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
- the locally maintained `session-replay` derivative
- `web.ts` (`web_search`, `web_fetch` over Exa) and `delegate.ts`
  (subagent runs with a live progress card), described under Web research
  below

The derivative and the progress card in `delegate.ts` retain their upstream
MIT notices. They do not depend on Disler's `themeMap.ts`; rendering uses
this repository's active theme.

### Subagents

`delegate.ts` is the one subagent extension (it replaced the Disler
`subagent-widget.ts` derivative on 2026-11-18; the `/sub` commands went with
it). Each child is a separate Pi process started with `--no-extensions`, so
the parent's extensions never load recursively, and a kept session file
under `sessions/delegate/<member>-<time>.jsonl`, so a slow or wrong run can
be read afterwards. Children share the working directory and filesystem but
not the parent conversation. The child runs in `--mode json`; its tool
calls and last line of text feed the tool call's partial result and a card
above the editor (status, elapsed seconds, call count, last call), and the
running count reaches `agent-state.ts` on `pif:subagents`. Cards clear when
the parent's turn ends.

Without an `agent`, the child is a generalist on the parent's model and
thinking with the built-in tools:

```text
read,write,edit,bash,grep,find,ls
```

It gets the communication prompt and scope rules that allow implementation
inside the delegated scope, forbid unrelated reversions, and require a
report of changes and checks. With an `agent`, the child is the named member
described under Web research.

Completed child reports use Pi's `steer` delivery mode. Pi inserts them before
the coordinator's next model call, so the coordinator can synthesize the
reports and its response remains the last visible message. The reports remain
visible for inspection.

### Web research

`web.ts` registers two driver tools over Exa. `web_search(query,
num_results?, since?)` runs one search (`type: auto`) and returns, per
result, the title, URL, published date and the passages Exa matched to the
query, under a 3,000 character budget with each passage cut at 500
characters. `web_fetch(url, query?, max_chars?)` reads one URL: with a
query it returns the matching passages uncut, without one the cleaned
text; either is capped as a whole at `max_chars` (default 6,000) and says
when it was truncated. A page Exa cannot read fails the tool call
with Exa's reason. No model call of our own is involved; the extraction is
Exa's. Tool parameters are plain JSON Schema, which pi accepts, so the
extension imports nothing from pi at runtime and `node --test` can load it.

`delegate(task, agent?, model?)` with an `agent` runs a member defined in
Claude Code's front matter format plus a `pi_model:` key, and blocks until
it finishes; pi runs sibling tool calls concurrently, so several delegations
in one assistant message run side by side. Members resolve from
`<cwd>/.claude/agents/<name>.md` first, then `~/.config/pif/agents/<name>.md`
(a link to `agents/subagents/`), the precedence Claude Code applies, so a
repo that ships a member of the same name wins in both runtimes. The driver
model picks the member itself: the tool's prompt snippet lists every
member's name and first description sentence, and the guidelines say when
to delegate; no code chooses. The child is `pi --mode json -p --session
<file> --no-skills --no-extensions`, with `-e extensions/web.ts` followed
by the project's `.pi/extensions/*.ts` loaders only when the member lists
`WebSearch` or `WebFetch` (so a repo tool of the same name wins in the child
too), `--tools` mapped from the Claude names (`WebSearch` to `web_search`,
`WebFetch` to `web_fetch`, `Read` to `read`, `Grep` to `grep`, `Glob` to
`find`, `Bash` to `bash`, `Write` to `write`, `Edit` to `edit`, `Ls` to
`ls`), `--model` from `pi_model` unless overridden, `--thinking low`, the
communication prompt and the member body appended to the system prompt, and
the task on stdin. The child's last assistant message is the tool result,
capped at 24,000 characters, followed by a bracketed note with the call
count and session path; a child that runs past ten minutes is stopped.

`agents/subagents/research.md` is the one member shipped: multi-search web
research returning a brief with a URL and a quoted sentence per claim and a
list of what was not found. `claudef` runs it with its native `WebSearch`
and `WebFetch` on `model: sonnet`; `pif` runs it through `delegate` on
`pi_model`. The driver's guidelines tell it to use `web_search` for one or
two lookups and to delegate anything that needs more, so the
search-and-refine loop never lands in the driver's context.

A repo can replace either extension: `web.ts` and `delegate.ts` register
nothing when the current directory has `.pi/extensions/web.ts` or
`.pi/extensions/delegate.ts` respectively, so the repo's loader of that
name supplies the tools. pi exits at startup when two loaded extensions
register one tool name, so this yield is the only way a repo copy can win;
the content-engine harness ships `web.ts` this way.

Keys come from the gitignored `.env` at the dotfiles root (`.env.example`
lists them; today only `EXA_API_KEY`). The three launchers source it with
`set -a` inside a subshell (`pif`, `codexf`) or just before `exec`
(`claudef`), so only the launched process sees the values; bare `pi`,
`claude` and `codex`, and the interactive shell, do not. The file is copied
by hand to each machine; `setup/headless-doctor.sh` warns when it is
missing or has no key. Decisions and the deferred fallbacks (Brave,
Firecrawl, the deeper research CLI) are in
[`tasks/pif-web-research.md`](tasks/pif-web-research.md).

### Replay

Session replay remains command-only. It must not change the terminal title or
active theme.

`system-select` and `pi-pi` are deliberately absent. The first has no defined
focus personas here and may replace the active tool set. The second is a
specialized orchestration mode that changes the system prompt and expects a
project-local expert catalog.

## Shared communication and provenance

All three focus launchers load `agents/communication.md`. Other files under
`agents/`, including `upstream_audit.md`, are references or skill content and
are not system instructions.

`codexf` runs `codex --dangerously-bypass-approvals-and-sandbox`, forwards
arguments unchanged, and reads `$DOTFILES/agents/communication.md` directly.
It injects that file as `developer_instructions`,
Codex's per-launch equivalent of these shared system rules. The former always-on
`unslop` skill is removed because `communication.md` is now the canonical
writing guidance. Bare Codex is unchanged.

The communication prompt's upstream inspirations and the
two Pi derivatives are recorded in `upstream-sources.json`. The profile
skill links reserve `agents/skills/upstream-audit/SKILL.md` as their canonical
target. Keep that target present when enabling agent-triggered audits. See
[`upstream-sources.md`](upstream-sources.md) for the review contract.

## Implementation map

| Concern | Source of truth |
| --- | --- |
| Claude launcher | `claude/.local/bin/claudef` |
| Pi launcher and runtime links | `zsh/.zshrc`, function `pif` |
| Codex focus launcher | `zsh/.zshrc`, function `codexf` |
| Claude focus profile | `claude/.config/claudef/` |
| Intentional global Claude files | `claude/.claude/keybindings.json`, `claude/.claude/commands/plan.md` |
| Pi focus profile | `pi/.config/pif/` |
| Shared system instructions | `agents/communication.md` |
| Web tools and delegation | `pi/.config/pif/extensions/web.ts`, `pi/.config/pif/extensions/delegate.ts`, tests in `pi/tests/` |
| Shared subagents | `agents/subagents/`, linked from `pi/.config/pif/agents` and `claude/.config/claudef/agents` |
| Focus-only keys | `.env` (gitignored), `.env.example` |
| Profile cleanup and doctor checks | `setup/lib.sh`, `setup/headless-doctor.sh` |
| Upstream audit | `upstream-sources.json`, `scripts/audit-upstreams.py`, `agents/upstream_audit.md` |

## Maintenance checks

When changing a focus launcher, verify these boundaries:

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
9. `codexf` forwards explicit arguments with unrestricted execution and the
   shared communication instructions, while bare `codex` remains unchanged.
10. `EXA_API_KEY` reaches the `pif`, `claudef` and `codexf` children and
    nothing else; `pif` in a non-repo directory answers a `web_search`
    prompt and a `delegate research` prompt; `claudef` lists
    `dotfiles-focus:research`; `node --test pi/tests/*.test.mjs` passes.

The migration and noninteractive isolation checks were completed in September
2026. Check 10 was completed on 2026-11-18.
