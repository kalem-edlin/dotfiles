# Tmux agent sessions

The tmux agent sessions picker is complete. It replaces the sessionx popup behind `prefix o` with a custom picker that shows, for every tmux session, which Claude Code and pi agents are running, what each one is called, what state it is in, and how much memory each window and session uses. A second mode (`ctrl-w`) lists the git worktrees that panes sit in instead of sessions. Agents publish their own state into tmux pane options, so opening the picker costs one tmux call and one memory helper call. This document records the current system and the decisions needed to maintain it. It is not an implementation plan or backlog, apart from the short deferred list at the end.

The plugin directory has no README of its own, so this note is the reference for its files, options and keys.

The full planning history (user intent, findings, decisions D1-D70) is in commit 44c0a44, `docs/tasks/sessionx-improvements.md`, removed after this note replaced it. Decisions D71-D81 come from the worktree mode build (commits 6dc081b to be1fdea, 2026-10-08). Its plan was never committed, so this note is their only record.

## Why it exists

- Sessionx had no resource usage support, opened slowly (tens of tmux client calls and about 1 s at the pinned commit), and offered weak extension points. Owning the picker made it faster to iterate on the picker and the agent hooks together, so sessionx and its pin were removed from `tmux/tmux.conf` and `setup/lib.sh`. An old checkout may still sit under `~/.config/tmux/plugins/tmux-sessionx` until it is deleted by hand.
- The state model follows herdr and similar tools: the agent reports its own state through hooks or an extension, and the picker reads it. The picker never scrapes pane contents to decide status, never polls ssh, and never runs per-session tmux calls. Reports from the agent are cheap, exact and survive UI changes in the agent.
- The pushed-state design has the usual failure modes and the system handles them explicitly. A crashed agent leaves its options behind, so the picker checks that `@agent_pid` is alive. An Esc interrupt fires no `Stop` hook, so Claude's `idle_prompt` notification recovers the state. `pane_current_command` is unreliable for Claude Code because it renames its process, so the publisher records the agent pid itself.
- Boundaries that still hold: opening the picker makes one tmux call and one `pane-mem` call (about 5 ms for the helper) and spawns nothing else, worktree mode included, the picker has no fork or patch of sessionx to maintain, and agents never invoke `tmux` against the live server during verification of tmux-side work.

## Components and file locations

Everything tmux-side lives in the local plugin `tmux/local-plugins/tmux-agent-sessions/`, loaded by `run-shell` from `tmux/tmux.conf` next to the other local plugins and before TPM.

| Path (plugin dir) | Role |
|---|---|
| `tmux-agent-sessions.tmux` | Binds `prefix o`, sets `@agent_clock`, installs the `pane-focus-in[41]` hook (focus stamp and Done to Idle) |
| `scripts/agent-state` | Publisher called by Claude Code hooks |
| `scripts/pane-mem` | Memory entry point. Runs `bin/pane-mem-darwin` when present, otherwise one `ps` snapshot summed with awk |
| `scripts/pane-mem-chip` | Prints the status line chip for the current pane |
| `scripts/wire-mem-chip` | Idempotently prepends the chip to `status-right` after TPM |
| `src/pane-mem.c` | Source of the macOS footprint helper |
| `picker/` | Go module `agentpicker` with packages `state`, `tmuxio`, `worktree`, `ui` and `main` |
| `bin/` | Built `agent-picker` and `pane-mem-darwin`, gitignored |
| `tests/` | `agent-state-test.sh`, `pane-mem-test.sh` and fixtures |

Outside the plugin:

| Path | Role |
|---|---|
| `claude/.config/claudef/settings.json` | Hook registrations for `scripts/agent-state` |
| `pi/.config/pif/extensions/agent-state.ts` | pi publisher and pif auto titles |
| `pi/.config/pif/extensions/subagent-widget.ts` | Emits the running `/sub` count on the `pif:subagents` event channel |
| `agents/communication.md` | The `Awaiting your input.` marker rule (symlinked from the claudef and pif config dirs) |
| `tmux/tmux.conf` | Loads the plugin (`run-shell` of the `.tmux` file) and runs `wire-mem-chip` after TPM. `focus-events` is on and `allow-set-title` is off |
| `setup/lib.sh` (`install_tmux_plugins`) | Builds `pane-mem-darwin` (macOS, with `clang -O2`) and `agent-picker` (macOS and Linux) |
| `setup/go.sh` | Pinned Go toolchain for Linux workers |
| `setup/lucide-font.sh`, `setup/lucide-font-derive.py` | Derived icon font installer (`make lucide-font`, part of `make setup`) |
| `ghostty/config` | `font-codepoint-map` for the icon codepoints |
| `setup/headless-doctor.sh` | `go` in required commands and a warn-level check for `bin/agent-picker` |

The zsh preexec hook in `zsh/.zsh/tmux-workspace-resurrect.zsh` stores the full command line in the pane option `@workspace-last-command`, which the cards use.

## Agent state contract

Pane options are written only by the publishers and the focus hook.

| Option | Written by | Meaning |
|---|---|---|
| `@agent_kind` | publisher at session start | `claude` or `pi` |
| `@agent_pid` | publisher at session start | The agent process. The picker treats a dead pid as no agent |
| `@agent_state` | publisher, focus hook | `idle`, `working`, `awaiting` or `finished` (shown as Done) |
| `@agent_at` | publisher on every transition except the focus-to-Idle one | Epoch of the last agent event. Fallback for `@agent_state_at` in row ordering, so a visit must not move it. It no longer picks the initial card (D79) |
| `@agent_state_at` | publisher, focus hook | Epoch when the current state began. A repeat of the same state keeps the stamp. Drives the age shown on chips |
| `@agent_name` | publisher | Session title (see Titles) |
| `@agent_subs` | publisher | Running subagent count. Reset to 0 at session start. pi publishes its running `/sub` count |
| `@agent_empty` | publisher | `1` from session start (startup, `/new`, `/clear`) while the chat has no prompt. Unset on the first prompt, on resume and on compaction |
| `@agent_cwd` | publisher | The agent's own working directory (D73). Claude writes the hook input's `cwd` at `SessionStart`, `UserPromptSubmit` and `Stop`, and `new_cwd` on `CwdChanged`. pi writes `ctx.cwd` at `session_start` only, since it is fixed per process. Worktree mode uses it in place of the pane directory |
| `@pane_focus_at` | focus hook | Epoch when the pane last gained focus, on every pane, agent or not (D74). Picks the initial card in both modes and is a worktree's last ordering key |

Rules for the publishers:

- Every write for one event is a single tmux invocation, with commands chained by `;`.
- Both publishers do nothing without `$TMUX_PANE`, and both guard against a stale `$TMUX` (an orphaned agent that still points at a dead server, since pane ids restart at `%0` on a new server). The Claude script compares the inherited server pid with `#{pid}` where it reads from tmux anyway and otherwise checks that the server is alive. The pi extension checks the server pid with `kill(pid, 0)`.
- `@agent_state_at` is written with `set -F` using `#{?#{&&:#{==:#{@agent_state},NEW},#{@agent_state_at}},#{@agent_state_at},NOW}` before `@agent_state` is overwritten, so the age needs no read round trip.
- `@agent_pid` for Claude: the publisher walks up from its parent with `ps -o ppid=` until it reaches the process whose parent is `#{pane_pid}`. If the first hop is a hook wrapper shell directly under the pane process, the agent is the pane process itself. This avoids depending on hook wrapping or on Claude renaming its process. For pi it is `process.pid`.
- `@agent_subs` decrement clamps at zero: `set -pF @agent_subs '#{?#{e|>|:#{@agent_subs},0},#{e|-|:#{@agent_subs},1},0}'`.
- Text values are sanitized (control characters to spaces, runs collapsed, trailing separators stripped) so a name cannot break tmux argv or a picker row. A path is not rewritten: `@agent_cwd` is skipped when the path is empty, holds a control character or ends in `;` (which tmux would read as a command separator), in both publishers. The Claude write rides in the same tmux call as the event's other writes, so it costs no extra spawn.
- Claude hooks are registered with `async: true` (`CwdChanged` included) except `UserPromptSubmit`, `SubagentStart` and `SubagentStop`, which are synchronous so a turn's `Stop` can never land before them, and `SessionEnd`, which must finish before Claude exits. The `Notification` hook matches `elicitation_dialog|elicitation_url_dialog|idle_prompt` and `PreToolUse` and `PostToolUse` match `AskUserQuestion` only.
- The remote workspace panes (rw) are out of scope. Agents inside a worker's tmux server are invisible to the laptop picker. Such panes show `remote` where memory would go, and carry no agent chip.

## State classification and transitions

The four states and what the user means by them:

| State | Meaning |
|---|---|
| Working | Running or processing, or subagents or background shells still running |
| Awaiting | The agent is waiting for a human answer |
| Done (`finished`) | A reply finished with no awaiting indication and the user has not visited the pane |
| Idle | The agent is up and nothing is pending. Also a Done pane after the user focused it, or an agent that has produced no response yet |

### Transition table

| Trigger | Result |
|---|---|
| Claude `SessionStart` (startup, resume, clear), pi `session_start` | idle. Sets kind and pid, `@agent_subs` 0 |
| Claude `SessionStart` with source `compact` | State, subs and name kept. Name refreshed if a title exists. `@agent_empty` unset |
| Claude `UserPromptSubmit`, pi `agent_start` | working. `@agent_empty` unset |
| Claude `PreToolUse` on `AskUserQuestion`, pi `ui_prompt_start` | awaiting |
| Claude `PostToolUse` on `AskUserQuestion` | working |
| pi `ui_prompt_end` | working if the agent is not idle, else unchanged until `agent_settled` |
| Claude `Notification` `elicitation_dialog` or `elicitation_url_dialog` | awaiting |
| Claude `Notification` `idle_prompt` while working | idle, only when `@agent_subs` is 0 and no background shell exists |
| Claude `SubagentStart` and `SubagentStop` | `@agent_subs` plus one and minus one. State unchanged |
| Claude `CwdChanged` (Bash `cd`, entering a worktree) | `@agent_cwd` set from `new_cwd`. State unchanged |
| Claude `Stop` with an in-flight entry in the hook's `background_tasks` (subagent, background shell, monitor or workflow). Without that field (older Claude): `@agent_subs` above 0, or a background shell | working. `@agent_subs` is resynced to the in-flight subagent count from the list |
| `Stop` or pi `agent_settled`, marker present, no subagents | awaiting |
| `Stop` or `agent_settled`, no marker, pane visible | idle |
| `Stop` or `agent_settled`, no marker, pane not visible | finished |
| tmux `pane-focus-in` while finished | idle |
| Claude `SessionEnd` (except reason `clear` or `resume`), pi `session_shutdown` | all `@agent_*` options unset, `@agent_cwd` included |

Details that matter when changing this:

- A pane is visible when `#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}` is true, evaluated with `if -F` in the same tmux call that sets the state (D8). An attached but unfocused terminal counts as visible.
- The focus transition is a tmux hook (`pane-focus-in[41]`, a fixed array index so reloads stay idempotent and other hooks are left alone) with an `if -F` check, so a focus change spawns no process. The epoch comes from `set -g @agent_clock '%s'` expanded with `#{T:@agent_clock}`. It touches `@agent_state` and `@agent_state_at` only, never `@agent_at`. It also fires when the terminal regains focus, which counts as a visit.
- The same hook first runs `set -pF @pane_focus_at "#{T:@agent_clock}"` unconditionally, ahead of the `if -F` (D74). tmux keeps no per-pane focus time (`window_activity` is last output), and a stamp inside the server costs no process. Checked on an isolated tmux 3.7b server: it fires on attach, `select-window` and `switch-client` in both directions, and on `select-pane` when the pane's window is visible, so no `client-session-changed` hook is needed.
- Awaiting is never cleared by a visit (D56). It lasts until the next prompt, `/clear` or the agent exiting. The focus hook only turns Done into Idle.
- Working wins over the marker when subagents or background shells are running. When a background Claude subagent finishes, Claude Code resumes the main agent, whose next `Stop` sets the final state. `SubagentStop` reaching zero does not change state by itself.
- `AskUserQuestion` counts as Awaiting when it happens. The user rarely uses it, and `claudef` runs with `bypassPermissions`, so permission prompts almost never occur and `permission_prompt` is deliberately not hooked.

### The Awaiting marker

An agent ends a reply that needs the user's answer or decision with the exact final line `Awaiting your input.`, required by `agents/communication.md` (section "Awaiting input marker"). Both publishers check the last non-empty line of the final assistant message against that text, after trimming. The check reads raw reply text and not the rendered terminal, so terminal styling cannot break it.

- Claude: the `Stop` hook stdin carries `last_assistant_message`.
- pi: the extension reads the last assistant message in process on `agent_settled`.
- Screen scraping and a pi `report_status` tool were rejected. Scraping drifts with agent UI changes and the tool adds a round trip to every reply.
- pif background subagents run with `--no-extensions` (`subagent-widget.ts`), so they never publish pane state.

### Subagent counting and background work

- Claude: `SubagentStart` and `SubagentStop` adjust `@agent_subs`, and every `Stop` resyncs it from the hook input's `background_tasks` (present since Claude Code 2.1.29x, status `running` or `pending` counts as in flight). The counter alone drifts: a finished subagent resumed with `SendMessage` fires `SubagentStop` again at its next stop but no `SubagentStart`, so each resume takes the count one below reality and the clamp hides it at 0. Seen 2026-10-08: a session resumed one subagent twice and showed Idle with a subagent still running. The list is authoritative at `Stop`, which is when the state is decided; `SubagentStop`'s own list still contains the stopping subagent, so it is not used there.
- pi: `subagent-widget.ts` emits the running count on `pif:subagents`. `agent-state.ts` publishes it as `@agent_subs`, and a settle with subagents running publishes Working. A finished subagent starts a parent turn, which settles as usual. If no turn starts within 2 s (after `/subrm` or `/subclear`), the held Working settles on its own.
- `idle_prompt` arrives about 60 s after the prompt goes idle, including while background subagents run, so the Esc-recovery rule applies only when `@agent_subs` is 0 (D69). Recovery after a real Esc interrupt therefore takes about 60 s and the pane shows Working until then.
- Background shell detection (D70). A subagent that backgrounds a command and ends its turn fires `SubagentStop` at once and `SubagentStart` only when it resumes, and a main-agent `run_in_background` shell fires no hook at all. `background_tasks` covers both as `shell` or `subagent` entries, so `Stop` skips the ps scan when the field is present. Without it, and always at `idle_prompt` (whose input has no task list), the publisher calls `bg_shells`, which runs one `ps -A` and looks for a direct child of the agent process whose command line contains `/.claude/shell-snapshots/`. At those two points no foreground tool runs, so any such child is background work and the state stays Working. The tmux read for the agent pid happens only if some shell-snapshots process exists at all. Cost is about 40 ms per `Stop`.
- Known tradeoff: a dev server started as a Claude background shell keeps its agent Working. This is accepted because persistent jobs belong in tmux panes.
- A subagent that dies without `SubagentStop` leaves the pane Working until the next `Stop` resyncs the count from `background_tasks`.

## Titles

`@agent_name` is the agent's session title and is the second line of an agent card.

Claude (`transcript_title` in `scripts/agent-state`):

- Order: last `custom-title` entry (from `/rename`), else last `ai-title` entry (Claude's auto title), else the first 40 characters of the first prompt until a title exists.
- Read at `SessionStart` for sources `resume` and `compact` only (startup and clear begin a new transcript with no title), and at `UserPromptSubmit` and `Stop`. The transcript is read for the name only, never for state.
- The reader takes the last 256 KiB of the transcript first, since Claude re-appends titles through the file. If the tail has none, one scan of the whole file runs, using `rg` when available (about 15 ms on a 45 MB transcript against about 260 ms with macOS grep). Malformed lines are skipped and the result is cut to 60 characters.

pif (`agent-state.ts`):

- pi has no built-in auto title. A name exists after `/name`, `--name` or `pi.setSessionName()`. `session_info_changed` publishes it to `@agent_name`.
- The extension generates a title (D46) once after the first settled reply whose prompt has at least 10 characters (so "hi" never becomes the title), again after each compaction using the compaction summary, and on demand with `/retitle`. There is no per-turn or threshold retitle.
- The first-title input is the first prompt plus the start of the reply, capped at about 2,000 characters (head and tail kept when longer). The compaction input is capped at 2,000 characters.
- It runs as a background promise, so it never delays a turn or a state publish. Errors are dropped. At most one first-title attempt runs per runtime.
- A name set with `/name` or `--name` is never replaced. Each auto title is recorded as a custom session entry (`agent-state-title`). If the current name differs from the last recorded one, the user set it and automatic titles stop. One function, `autoTitleAllowed`, guards every automatic write and re-checks just before writing. `/retitle` skips the guard because the user asked, and records its result as an auto title.
- Model: the preference list is `openai-codex/gpt-5.6-luna`, `anthropic/claude-haiku-4-5`, `google/gemini-2.5-flash-lite`, `openai/gpt-5-nano`, with the current provider's entry first, then the session's own model. Reasoning is turned off (or minimal where a model cannot disable it) and output is capped at about 30 tokens. The prompt asks for a two to five word noun phrase in sentence case without request verbs.
- A reopened session without a name publishes its first prompt (40 characters) as `@agent_name` until a title lands. A reopened session with a qualifying exchange and no title is titled at session start.

Empty chat:

- A Claude or pif agent whose chat has no prompt yet shows the dimmed placeholder `Empty chat` as its subtitle, so a fresh agent does not look broken. The signal is `@agent_empty` and not a missing `@agent_name`, because a resurrected or untitled agent also has no name. Card subtitle order is `Empty chat`, then `@agent_name`, then the pane command.

## Memory

`scripts/pane-mem PID...` prints `PID KIB` for each given root that is alive, summing the root's whole process tree. A root that is not alive prints nothing, which is how the picker checks `@agent_pid` liveness.

- macOS: `bin/pane-mem-darwin` reads `ri_phys_footprint` and the parent pid of every process through `proc_listallpids` and `proc_pid_rusage`. It takes about 5 ms for roughly 600 processes. RSS is badly wrong for idle processes on macOS because compressed pages are excluded, and the `footprint` CLI is far too slow (seconds).
- Linux and fallback: one `ps -axo pid=,ppid=,rss=` snapshot summed with awk, about 30 ms.
- Footprint overcounts shared and graphics memory, so the numbers rank panes and do not add up to system totals.
- Format: whole MiB below 1 GiB (`640M`, at least `1M` when nonzero), one decimal above (`2.4G`).
- The picker makes one `pane-mem` call per load with every pane pid and every `@agent_pid`.
- Status line chip: `scripts/wire-mem-chip` prepends `#(.../pane-mem-chip #{pane_pid})` to `status-right`, so it renders to the left of the autosave, directory and hostname chips. It runs after TPM (catppuccin rewrites `status-right` when TPM loads) and strips existing copies first so repeated `source-file` calls never stack duplicates. tmux caches the job per distinct command string, so it runs at most once per `status-interval` (5 s) per pane, and the chip is blank for a few milliseconds after a pane change. The chip does not read separators from tmux, since a client spawn per pane per interval would cost more than the measurement. They are copied from `@catppuccin_status_{left,right}_separator`, and the two must be kept in sync.
- Remote panes show `remote`. A session mixing local and remote panes shows the local total followed by `remote`.

## Picker

### Open path

- `prefix o` runs `run-shell -b` wrapping `display-popup -c '#{client_name}' -E -w 90% -h 85% -s 'bg=#1e1e2e' -S 'bg=#1e1e2e' "bin/agent-picker '#{client_name}'" || true`.
- `run-shell` is needed because `display-popup` does not format-expand its command (tmux 3.7b `cmd-display-menu.c`). The picker needs the invoking client name to target `switch-client`.
- `-s` and `-S` give the popup and its border cells the catppuccin mocha base `#1e1e2e` (sessionx's old background). Cells with their own background keep it, and the border keeps its default line colour. Ghostty runs `background-opacity = 0.9`, so default cells stay translucent.
- `run-shell` shows any non-zero exit in view mode, which traps the client until `q`. So the binding ends in `|| true` and the picker always exits 0 (`main.go`). The same rule applies to every `run-shell` binding that can open a dialog, and new bindings of that kind should follow it.
- If `bin/agent-picker` is missing at plugin load, `prefix o` shows `agent-picker not built: run make install` and there is no fallback.
- One load is one `tmux display-message -p -c CLIENT '#{session_id}␞#{pane_id}' ; list-panes -a -F ...` call plus one `pane-mem` call. The first line gives the client's session and active pane. The format carries session, window, pane, pids, commands, `#{session_last_attached}`, `#{session_attached}`, `#{pane_current_path}`, `@remote-host`, `@workspace-last-command`, `@pane_focus_at` and every `@agent_*` option. A failed first load prints the error and waits for enter. Data is reloaded only after an action.
- Every load builds both the session rows and the worktree rows, so `ctrl-w` never waits on I/O. Worktree resolution happens in process (D75, see Worktree mode) and spawns nothing.
- Measured: keypress to first frame was 76 to 89 ms in an isolated popup run, polling overhead included. Cold start of the binary is about 23 ms, mostly Charm library init.

### Implementation notes

- The module `picker/go.mod` pins `junegunn/fzf` (only `src/algo` and `src/util`), and `charm.land/bubbletea/v2`, `lipgloss/v2` and `bubbles/v2`. The Charm v2 modules live under `charm.land`, and the `github.com/charmbracelet/*/v2` paths fail `go get`.
- `algo.Init("default")` must run at start, or scores are wrong.
- Package split: `state` holds the snapshot types, the `Row` interface and the `Actions` interface, `tmuxio` holds the tmux call, `pane-mem`, worktree grouping, row sorting and the actions, `worktree` holds the filesystem resolver, `ui` holds the Bubble Tea model and rendering, and `main` wires them.
- Sessions and worktrees share one `Row` interface (`RowID`, `Members`, `IsCurrent`, `Recency`), so sorting, row aggregates, the default card and reload by id are one code path for both modes.
- Bubble Tea runs with `tea.WithColorProfile` set to truecolor and no background detection, so no colour query goes to the terminal. All state is in memory. A keystroke updates the model and redraws without starting a process. The escape timeout is Bubble Tea's 50 ms default. The size can read as 0 under tmux (Bubble Tea issue #1718), so the model renders at 80x24 until a real size arrives. A reply to the synchronized-output query could leak to the shell on a very fast quit (issue #1590) and did not appear in testing, including esc 80 ms after open.
- Search is plain matching of a name or a piece of one, anywhere in the session name (D33), or in worktree mode the branch name (the commit id when detached). The whole query is one case-insensitive pattern run through `algo.FuzzyMatchV2`, which also gives the highlight positions (shown in red). fzf's extended syntax is not implemented. Rows keep their no-query order in both modes and are never re-sorted by score. After a query change the cursor moves to the bottom match.
- Actions run in Go through `tmuxio`. Targets are ids (`$N`, `@N`, `%N`), and names are passed only where tmux needs one. `AGENT_SESSIONS_RW_CLOSE` overrides the `rw-close.sh` path.

### Layout

From the top: the card grid, the row list (sessions or worktrees), then the input line between two rules. There is no header and no key hints. Both modes use the same layout.

| Part | Rule |
|---|---|
| Row list | 6 rows (`listRows`), bottom up. With fewer rows the empty rows sit at the top. Panel background is the base blended 70% toward surface0 |
| Input line | Query with a static block cursor (no blink ticks). At the right edge the match count (`matches/total` rows, where total counts rows that pass the repo filter) and a 2-column cell, `#a6e3a1` at rest and `#f38ba8` while the prefix is armed. In worktree mode the repo filter chip sits between the match count and the cell (D80). The rules above and below use `#585b70` |
| Grid | Everything above the list. Hidden when less than one card row (`cardRows + 2` lines) fits |
| Short screens | `heights()` gives the input line priority, then up to 6 list rows and the two rules. Rows go from the grid first, then from the list down to one row, and the rules drop only when no list row would be left |

On a large screen the grid may use fewer lines than it is given, which leaves a blank gap between the grid and the list. This is accepted, and the popup size stays at 90% by 85%.

The text input keymap is trimmed so it does not take `ctrl-a`, `ctrl-d`, `ctrl-h`, `ctrl-j`, `ctrl-k`, `ctrl-n`, `ctrl-p`, `ctrl-u` or `ctrl-w`. Bubbles binds `ctrl-h` to backspace by default, and the query drops it because the grid uses it (D72). Ghostty sends `0x7f` for backspace and `0x08` for `ctrl-h`, so the two stay distinct through the popup. Arrows, backspace and typing still edit. Prompts (rename, new window, new session) additionally get `ctrl-h` as backspace and `ctrl-u`, `ctrl-w`, `ctrl-a` and `ctrl-k` as in tmux's command prompt, so a prefilled name can be cleared.

### Session order and initial cursor

Session order, top to bottom (D63): the invoking client's session is always last (bottom). The others are sorted so higher priority sits lower, comparing in turn the Awaiting count, the Done count, the Working count, the newest agent state change (`@agent_state_at`, else `@agent_at`), then `session_last_attached`. Counts compare one after another (two Awaiting beats one Awaiting plus five Done) and not as a weighted sum. Ties keep tmux's order. Worktree rows use the same sort (`sortRows`) with their own last key (D78).

The cursor starts one row above the bottom (D13), which is the highest priority session other than the current one. With a single session it sits on that session. The window of the list is anchored at the bottom so the current session shows.

### Session rows

Left to right: a gutter column (dark, with a rosewater `▌` on the selected row), the name, then three sections pushed to the right edge and divided by thin vertical lines (`#585b70`). A long name is truncated with `…` before chips are dropped, and chips are dropped (rightmost first) only when the name would fall under 12 columns. The selected row has a light highlight across its full width.

1. Status chips: Working, Awaiting, Done in that order, each only when its count is above zero (D55). Each reads count, state word, age (`2 Working 4m`), where the count is the number of agents in that state and the age is the newest state change among them. This is the only section of variable width. There is no Idle chip on rows.
2. Agents: bot glyph, a space, the count of all agents in the session, then the age of the newest state change of any of them (`<bot> 3 5m`, D66). A session with no agents shows `<bot> 0` with no age. The section is a constant 8 cells so it aligns on every row. The count shows up to 99.
3. Memory, right aligned in a width shared by all rows (at least 5 cells).

Only the status chips have a background. Row chips always show words (`2 Working 5m`), and the icons belong to the card grid. This is a fixed convention: the words/icons toggle on `ctrl-w` (D57) was removed to free the key for the mode switch (D71).

Ages use the format `42s`, `5m`, `3h`, `2d`, then weeks from 7 days (`3w`), with no months. The age is dimmer than the text beside it everywhere: on rows outside a chip it is `#7f849c` (or `#a6adc8` on the selected row), and on chips it is a lighter shade of the chip text (see colours).

### Cards

The grid has one mode (D50). Cards fill at most two columns, each half the width, and one column when half the width is under 30 columns. A card is 3 content rows inside a rounded border, with one column of padding. A grid row takes the height of its tallest card. At most 3 full grid rows show, and when more rows exist below, the top border and first content line of the next row show under them as a cue (D36). The scroll offset counts grid rows and follows the selection.

Card construction:

- One card per window. A window with two or more agent panes gets one card per agent pane instead, in pane order (D51). A window with one agent pane is one card for that agent.
- Header: `W name` on a window card and `W.P name` on a split card (D58). The index is lavender. Split cards of one window show the same window pane count and the same window memory total, and only the header and agent title differ.
- Subtitle (D53): `Empty chat` (dimmed) for an agent with `@agent_empty`, else `@agent_name`. A card with no agent shows the running command of the window's lowest-index pane (lowest-index member pane in worktree mode). At a shell prompt that is the last command line from `@workspace-last-command`, dimmed. Otherwise it is `@workspace-last-command` if set (`pnpm branch` where `pane_current_command` says `node`), falling back to `pane_current_command`. `#{pane_title}` is unusable because `allow-set-title` is off.
- Third line, wrapping when needed: the `N panes` chip (always shown, `1 pane` included, text `#cdd6f4` on `#45475a`), the agent chip if any, and the window memory as plain text with no cell. An agent chip reads `claudef <icon> 5m` or `pif <icon> 5m` (a card shows at most one agent, with no aggregate chips).
- Text that does not fit is truncated with `…` or wrapped at the card edge.
- Unselected cards blend every colour, chips included, 50% toward the base (`dimAmount`). The selected card has a bright border (`#cdd6f4`) and full colour.

Selection and keys:

- The initial card (D79, replacing D15's newest `@agent_at` rule) is the card holding the row's member pane with the newest `@pane_focus_at`. In session mode every pane of the session is a member. A tie goes to the first pane in window and pane order. A focused pane without a card of its own (a shell beside split agent cards) selects its window's first card. With no stamped pane, session mode falls back to the active window's active pane, and worktree mode to a member pane that is active in an active window of an attached session (`#{session_attached}`), else the first card. The initial card may sit further down the grid, and the grid scrolls to show it.
- Card moves are spatial, as vim directions (D72). `ctrl-h` and `ctrl-l` move one card left or right within the grid row and stop at its edges. `ctrl-j` and `ctrl-k` move one grid row down or up keeping the column, land on the last card when the row below is short, and stop at the top and bottom rows. `ctrl-d` and `ctrl-u` are no longer bound, and reading-order stepping is gone.
- Moving to another row rebuilds the grid and reselects the default card.

### Worktree mode

`ctrl-w` switches the list between sessions and git worktrees (D71). A pane's directory places it in a worktree, so the worktree rows reuse the session layout, card grid, keys, colours and ordering, with the differences below. The picker always opens in session mode. Which mode should be the default is deferred until both have been used.

Effective directory (D73):

- An agent pane with a live `@agent_pid` and a non-empty `@agent_cwd` uses `@agent_cwd`. Every other pane, remote panes included, uses `#{pane_current_path}` (`Pane.Dir()`).
- The reason is that an agent can move. Claude's hook `cwd` follows the Bash tool's `cd` and the worktree root after entering a worktree, while `pane_current_path` of a Claude pane stays at its launch directory. Transcripts showed `cwd` moving within 26 of 43 sampled sessions.
- A Claude session started before the `CwdChanged` registration still gets `@agent_cwd` from its next prompt or `Stop`, because `scripts/agent-state` changes apply on the next hook run. Only mid-turn moves need the restart that picks up the new hook.

Resolution (D75). `picker/worktree` maps a directory to its worktree by reading the filesystem only, and never spawns git:

- Walk up to the first `.git`. A `.git` directory is a main worktree and is its own common dir. A `.git` file holds `gitdir: <path>`. The worktree's `HEAD` is in that gitdir, and the common dir is named by `<gitdir>/commondir`, or is the gitdir itself when that file is absent (submodules, `--separate-git-dir`).
- A directory that does not exist, or whose `.git` entry or `HEAD` is unreadable or malformed, resolves to no worktree. Panes outside any repo never appear in worktree mode.
- Files are read with a raw open, one read and close into a 4 KiB buffer, because syscalls are nearly all of the cost. Paths are cleaned but not passed through `EvalSymlinks`.
- One `Resolver` is made per load (`buildSnapshot`). It caches every directory a walk passes through, so siblings of a resolved directory stop at the first shared ancestor. Nothing is cached across loads, so results are exact at open time.
- Cost is about 0.6 ms for 100 directories on a fresh resolver. Options rejected during planning: `git rev-parse` per path (34 ms in parallel, 179 ms sequential, which would double the open time), precomputing `@pane_worktree` in a zsh `chpwd` hook and agent hooks (a tmux spawn per `cd`, and stale for anything that changes directory outside zsh, such as nvim `:cd`), and a background cache or daemon (another component to keep alive for no gain).

Identity and labels (D76):

- A worktree's id is its root directory. Its repo is the source repo's local directory name, not the remote: the basename of the main worktree (the parent of a `.git` common dir), the name of a bare `<name>.git` common dir without the suffix, the common dir's basename when it was reached through a `commondir` file, else the worktree root's basename (submodules, `--separate-git-dir`). Examples: `content-engine-1`, `search-primitives`, `dotfiles`.
- The row label is the branch from `HEAD` (`refs/heads/` stripped, other refs with `refs/` stripped). A detached `HEAD` shows the 7-character commit id, dimmed. Worktree directory names are never shown as labels, since branches are what is read and searched. Search matches the branch (or commit id) and match highlights always show.
- A repo badge sits immediately left of the label, after the gutter and its leading space: exactly 2 columns holding the repo's code, bold, on the repo's shade, then one plain space and the label. It replaces the old repo column on the right.
- Codes and shades are computed once per snapshot from the distinct repo names of all worktree rows (`assignRepoBadges` in `picker/ui/badge.go`), independent of the filter and of row order, so they stay stable between opens. Names claim in sorted (byte-wise) order. Candidates come from the lowercased name's ASCII letters and digits, in this order: the first two, the initials of the first two segments when split on other characters (`search-primitives` gives `sp`), the first character with each later one in turn, the first character with `1` to `9`, then `00` to `99`. A name without letters or digits starts at `00`. Each name takes its first unclaimed candidate. Examples: `content-engine-1` is `co`, `dotfiles` is `do`, `search-primitives` is `se`, `yap-trial` is `ya`, and with `co` and `content-engine-1` already claiming `co` and `ce`, `content-engine-2` gets `cn`.
- Shades are five dark greys, darkest first: `#37384b`, `#3e4052` (Surface0 toward Surface1), `#4d4f63` (Surface1 toward Surface2), `#585b70` (Surface2) and `#606379` (Surface2 toward Overlay0). They sit a few levels above the row background so they read without standing out. The band around Surface1 is skipped because it matches the selected row background. The repo at position i in sorted order takes shade i mod 5. Text is `#bac2de` (Subtext1) on all of them. Badges keep full colour on the selected row.
- `ctrl-t` toggles full-repo mode for that picker run (off on open, kept across `ctrl-w`). Every badge widens to the full repo name on the same shade, padded to a shared width (the longest repo name among all worktree rows, at most 24 columns, truncated with `…`), so the branch labels stay aligned behind it. The row's right side then shows only the status chips: the agents section and its separator are hidden, and the label gets the freed width.

Membership and cards (D77):

- A window shows when at least one of its panes is a member, meaning its effective directory resolves to the selected worktree. A window with no member pane gets no card.
- The split-card rule counts member agent panes only. Two or more give one split card per member agent. One gives a window card for that agent. None gives a window card whose subtitle comes from the first member pane. An agent pane in another worktree gets no card.
- The `N panes` chip and window memory stay window totals, other worktrees' panes included.
- A window linked into several sessions is grouped once, under the first session that holds it in tmux's order. Grouping happens before sorting, so it does not depend on agent states.

Rows and order (D78):

- Status chips and the agents cell count member agent panes only.
- There is no memory or repo column. The right side ends with the agents section and one space, or with the status chips in full-repo mode, and the repo shows only in the badge (D76).
- The current worktree is the one holding the invoking client's active pane (its effective directory) and sits at the bottom. The others sort as sessions do (Awaiting, Done and Working counts, then the newest agent state change), with the newest `@pane_focus_at` among member panes in place of `session_last_attached`. Ties keep first-appearance order.
- The cursor starts one row up. When the bottom row is not the current worktree (the client's pane is outside any repo, or the repo filter hides it), the cursor starts on the bottom row.

Repo filter (D80):

- `tab` and `shift-tab` step forward and back through All and each repo, wrapping both ways. The filter starts at All on every open.
- Repos are ordered by first appearance scanning the worktree rows from the bottom up, so the first `tab` lands on the highest priority repo, normally the current worktree's. Entries are repo names, so two repos with the same directory name share one entry.
- The filter applies with and without a query, before the branch match. A filter step resets the cursor and card as on open.
- The input line shows the filter as a chip between the match count and the prefix cell, one space from each. It reads `All` (`#cdd6f4` on `#45475a`, the panes chip colours) or the repo name on that repo's badge shade and text colour. The query has priority: the chip takes whatever room is left, is truncated, and is dropped below 3 columns. Prompts and errors replace the query and show no chip.

Mode switch:

- The query, the repo filter and full-repo mode are kept across `ctrl-w` within one run. Session mode ignores the filter and shows no chip.
- The cursor and card go to their defaults: with an empty query the open-time cursor rule, with a query the bottom match, as after typing.

Actions (D81). Card actions (`enter`, `C-a r`, `C-a q`) work as in session mode, using the card's own session. `C-a c` needs a card and makes a window in that card's session with `-c <worktree root>`. `C-a C` needs a worktree row and makes a detached session rooted at the worktree, with its directory name as the default name. `C-a R`, `C-a Q` and enter with no card do nothing, because a worktree row is not a session.

### Colours

Palette is catppuccin mocha (`picker/ui/palette.go`). Terminals have no alpha, so highlights, the panel and dimmed cards are colours pre-blended against the base.

| State | Chip background | Chip count, label and icon | Chip age |
|---|---|---|---|
| Done | `#a6e3a1` | `#465f44` | `#719b6f` |
| Working | `#89b4fa` | `#394c69` | `#5e7bac` |
| Awaiting | `#fab387` | `#694b39` | `#ac7a5c` |
| Idle | `#6c7086` | `#2d2f38` | `#4a4d5c` |

The text on each chip is a darker shade of its own pastel (D64, D67), and the age is 30% of the way from that text toward the background, so time reads at lower contrast. Row chips are always drawn at full (selected) colour. The colours are trial values, so expect further tuning in `palette.go` only.

### Keys and actions

| Key | Session mode | Worktree mode |
|---|---|---|
| `ctrl-n`, `down` / `ctrl-p`, `up` | Next / previous row | same |
| `ctrl-h` / `ctrl-l` | Card left / right within the grid row | same |
| `ctrl-j` / `ctrl-k` | Card row down / up, keeping the column | same |
| `ctrl-w` | Switch to worktree mode | Switch to session mode |
| `ctrl-t` | Nothing | Toggle full-repo mode: badges show full repo names and rows show only their status chips on the right |
| `tab` / `shift-tab` | Nothing | Next / previous repo filter |
| `enter` | Go to the selected card, or create a session from an unmatched query | Go to the selected card. Nothing without a card |
| `esc`, `ctrl-c` | Close | same |
| `C-a c` | New window in the selected session, in its active pane's directory, name prompted (empty keeps automatic naming) | New window in the selected card's session, started in the worktree root. Nothing without a card |
| `C-a C` | New detached session in the home directory, name prompted with the query as the default | New detached session started in the worktree root, name prompted with the worktree directory name as the default |
| `C-a r` | Rename the selected card's window | same |
| `C-a R` | Rename the selected session | Nothing |
| `C-a q` | Kill the selected card's pane (split card) or window (window card) | same |
| `C-a Q` | Kill the selected session after a `y/N` prompt | Nothing |
| `C-a esc` | Close (the prefix disarms and `esc` closes as usual) | same |

`ctrl-d` and `ctrl-u` are unbound (D72). The picker always opens in session mode (D71).

Prefix emulation (D16). In tmux 3.7b a popup is an overlay: `server_client_handle_key` gives every key to the overlay callback before any key table is consulted, and `popup_key_cb` writes it to the popup's job. tmux prefix bindings never run while the popup is open, so the picker emulates the prefix itself. `ctrl-a` arms it (the cell turns red) and the next key is checked against `c C r R q Q`. Any other key disarms and does its normal job (`C-a ctrl-j` moves the card as if `C-a` was never pressed, and `C-a x` types `x`). Lowercase acts on the card selection and uppercase on the session, so in worktree mode, where a row is not a session, `R` and `Q` do nothing (D81). Option chords are avoided because AeroSpace uses Option, `fn` triggers Wispr Flow, and no Ghostty remaps are used. tmux 3.8 replaces popups with floating panes, so re-check this on an upgrade.

Enter targets. A split card runs `switch-client`, `select-window` and `select-pane` on its pane. A window card runs `switch-client` and `select-window` and keeps the window's active pane. With no session matched, enter creates a session named by the query (rejecting empty names and names containing `.` or `:`). In worktree mode enter switches to the selected card's own session, and with no card (no match, or a row without cards) it does nothing.

Action signatures: `NewWindow(session, dir, name)` uses `dir` as `-c`, or reads the session's active pane directory with one `display-message` when `dir` is empty. `NewSession(name, dir)` uses `dir`, or the home directory when empty.

Action behaviour:

- Name prompts and the kill confirmation are inline in place of the input line, and `esc` cancels. Errors show inline in the input line.
- After any stay-open action the picker reloads, even when the action failed, because a kill can succeed after `rw-close.sh` fails. A failed reload keeps the old snapshot. The selected row (session id or worktree root) and card are kept by id when they still exist. A repo filter whose repo has gone falls back to All.
- Kill paths. tmux `prefix q` routes panes with `@remote-host` through `tmux-remote-workspaces/scripts/rw-close.sh --pane`. The picker does the same: `KillPane` reads `@remote-host` fresh, and window and session kills close every remote pane in them through `rw-close.sh --pane` first, then kill the window or session. If `rw-close.sh` cannot run at all the kill does not go ahead. If it fails for individual panes the kill still proceeds and the failures are reported. Closing every window of a session keeps killing the session, which is plain tmux behaviour.

## Icon font

The status icons are Lucide glyphs shown through a derived font.

| Glyph | Lucide icon | Codepoint |
|---|---|---|
| Done | circle-check | U+E1C0 (taken from Lucide's U+E226) |
| Working | circle-dashed | U+E4B0 |
| Awaiting | circle-question-mark | U+E082 |
| Idle | circle-minus | U+E07E |
| Agents | bot | U+E1BB |

- `lucide-static` 1.52.0 (ISC licence) ships `font/lucide.ttf`. `setup/lucide-font.sh` downloads the pinned npm tarball, verifies its sha256, verifies the sha256 of the font inside it, derives the font with `uv run --with fonttools==4.62.1 python3 setup/lucide-font-derive.py`, verifies the sha256 of the derived font (`DERIVED_TTF_SHA256`), and installs `~/Library/Fonts/lucide-picker.ttf` (family `Lucide Picker`). It removes the old unmodified `lucide.ttf` when that file matches the known hash. Output is byte-identical between runs, which is why the derived hash can be pinned.
- Changing a glyph, a codepoint or `SIZE` means updating `DERIVED_TTF_SHA256` in `setup/lucide-font.sh` and the `font-codepoint-map` line in `ghostty/config`, then restarting Ghostty.
- Linux workers need no font because the glyphs render in Ghostty on the laptop.
- `ghostty/config` maps only these five codepoints: `font-codepoint-map = U+E1C0,U+E4B0,U+E082,U+E07E,U+E1BB=Lucide Picker`. 815 of Lucide's 1907 codepoints overlap Hack Nerd Font glyphs, so a wider map would break other icons.

Why the font is derived, and the Ghostty facts behind it (Ghostty 1.3.1 source):

- Lucide's glyphs are about 0.92 em circles drawn from the baseline up on a 1 em advance. In a Hack cell about 0.6 em wide they spill right and sit high.
- Ghostty has no per-font scale or offset. A private-use codepoint without a Nerd Font rule only gets "fit" with no alignment change, and may use two cells when a space follows. The font's own outline position decides where it lands.
- A codepoint-mapped font is scaled to match the primary font's x-height. JetBrains Mono NL is listed first in `ghostty/config` but is not installed, so Hack Nerd Font Mono is the effective primary font. The derived font therefore copies Hack's metrics (scale 1.0) so Ghostty applies no size adjustment. If the installed primary font ever changes, re-check the icon sizes.
- The derive script centres each circle on the cell. `SIZE = 1.15` draws the widest glyph at 1.15 cell widths, which is a little bigger than a cell, so each icon overflows evenly into the neighbouring spaces. Every icon is followed by a space in its chip for that reason. One scale applies to all glyphs, taken from the widest, so the glyphs keep their relative size. `bot` is narrower than the widest glyph, so it did not change the other four.
- Circle-check moved from U+E226 to U+E1C0. A Nerd Font attribute rule covers the E200 to E2A9 range and holds U+E226 to one cell, which stopped the 1.15 overflow. U+E1C0 lies outside every Nerd Font range.
- The picker's Go source holds the same codepoints as literal characters in `palette.go` (`stateIcon`, `botIcon`), and they must match the derive script.

## Build, setup and tests

- Build: `go -C picker build -trimpath -ldflags='-s -w' -o ../bin/agent-picker .` in the plugin dir, run by `install_tmux_plugins` in `setup/lib.sh` after the `pane-mem` block, on macOS and Linux. Without `go`, or when the build fails, setup prints a `WARNING:` and continues. Reload the tmux config after a rebuild so the binding sees the binary. The binary is about 3 MB.
- `pane-mem-darwin` builds with `clang -O2` on macOS only. A failed build falls back to the `ps` path.
- Go on macOS comes from the Brewfiles. On Linux `setup/go.sh` installs a pinned Go (1.26.3, sha256 for linux-amd64 and linux-arm64 verified with `sha256sum -c`) into `~/.local/opt/go-<version>` and links `go` and `gofmt` into `~/.local/bin`. It is not apt, because Ubuntu 24.04's `golang-go` is older than the module needs. It skips when `go version` already reports the pin. `setup/linux-headless.sh` calls it before the dotfiles install and checks `go` in its verify list. `go` is listed in `setup/tool-parity-exceptions.txt` as installed by another mechanism, and `setup/headless-doctor.sh` requires `go` and warns when `bin/agent-picker` is missing.
- Tests:
  - `go -C tmux/local-plugins/tmux-agent-sessions/picker test ./...` covers snapshot parsing from fixture `list-panes` output, session and worktree ordering, worktree membership, the matcher, age formatting, golden renders of rows, cards, the grid and the input line at several widths for both modes (`wt_*` goldens for worktree mode), model tests that feed key messages (prefix arm and disarm, spatial card moves, `ctrl-h` not deleting, mode switch, repo filter, default selection, enter, worktree action gating), and action tests against a fake `tmux` shim first in `PATH`.
  - `picker/worktree` tests build real repos under a temp dir with `git init` and `git worktree add` (main checkout, linked worktrees, subdirectories, detached `HEAD`, bare repos, missing `commondir`, non-repo and missing directories, malformed `.git` and `HEAD` files) and skip when `git` is not installed. `BenchmarkResolve100` times a fresh resolver over 100 directories, and `BenchmarkBuildSnapshotWorktrees` a 600-pane snapshot over 40 worktrees.
  - `tests/agent-state-test.sh` drives `scripts/agent-state` with fixture hook JSON through a fake tmux shim and asserts the argv of every tmux call.
  - `tests/pane-mem-test.sh` covers the memory script and chip formatting.
  - Run Go tools with `TMUX` and `TMUX_PANE` unset. Tests must assert the shim is in use before anything runs, and never touch the live server.
- `make install` and `make install-headless` previously deleted claudef's ccline symlinks (`cleanup_focus_agent_links`). The `claudef` launcher creates those links on purpose, so they are no longer in that function's list (D48).

## Operating it

| Change | What to do |
|---|---|
| Picker Go code or `agent-picker` build | Rebuild (`make install` or the `go build` line above). The next `prefix o` uses the new binary. Reload tmux if the binary was missing at plugin load |
| `tmux-agent-sessions.tmux` or `tmux.conf` | Reload tmux config |
| `scripts/agent-state` | Takes effect on the next hook run. Already running agents need no restart |
| Claude hook registrations in `settings.json` | Restart the Claude session (hooks are read at session start). Until then a session misses `CwdChanged`, and its `@agent_cwd` updates only at prompts and `Stop` |
| `agent-state.ts` or `subagent-widget.ts` | `/reload` in pif (an old runtime's state write cannot overtake a new runtime's start, because the publish chain is shared on `globalThis`) |
| Icon font, `SIZE`, codepoints, `font-codepoint-map` | Rerun `make lucide-font` if the font changed, then restart Ghostty |

Maintenance cautions:

- Do not invoke `tmux` against the live server from tooling or tests. Verify tmux-side work statically, with shims, or against an isolated `-S` server.
- Any new `run-shell` binding that can show a dialog must exit 0 or end in `|| true`.
- Changing the option contract means changing `scripts/agent-state`, `agent-state.ts`, the `list-panes` format in `picker/tmuxio/snapshot.go` (columns are positional, keep the constants in step) and the fixtures together. The two raw path columns sit before the numeric last columns so a path containing a line break is joined back up like a multi-line command.
- Keep worktree resolution in process. A git spawn or an extra tmux call per load would break the open budget.
- The marker text is shared by `agents/communication.md`, `scripts/agent-state` and `agent-state.ts`.

## Known gaps and limitations

- Remote (rw) panes show `remote` and no agent state, since their agents run inside the worker's tmux server. Pulling state over ssh was deliberately not built, and ssh must never be polled from a `#()`.
- A reply that asks a question without the marker shows as Done. A "last line ends with ?" fallback was deliberately not added.
- After an Esc interrupt the pane shows Working until `idle_prompt` arrives, about 60 s later.
- A Claude background dev server keeps its agent Working (D70).
- A subagent that dies without `SubagentStop` leaves the pane Working until the next `Stop` resyncs the count from `background_tasks` (or until `SessionStart` on an older Claude without that field).
- Memory is footprint on macOS, so totals overcount shared and graphics memory.
- Pane option writes do not trigger resurrect saves. Autosave runs from a separate 300 s timer.
- The tmux 3.7b popup behaviour that forces prefix emulation may change in 3.8.
- Worktree mode shows only worktrees that hold at least one pane. Other worktrees of the same repo are invisible.
- Worktree paths are not resolved through symlinks, so one checkout reached through a symlink and through its real path shows as two rows.
- The repo filter groups by directory name, so two different repos with the same directory name share one filter entry.

## Deferred

- X1. Show all worktrees of tracked repos, including those with no panes. A repo would count as tracked when it has at least one member pane. Linked worktrees are listed in `<commondir>/worktrees/*/gitdir`, readable in process without git (content-engine has about 50), so this fits D75's budget. Rows with no panes would sort above all others and select into an empty grid, where enter could create a session there.
- X2. Choose the default open mode after using both. An option or a second binding could then open straight into worktree mode.
- X3. A tracked-repo registry beyond "repos with panes", if X1 needs repos that currently have no panes. None exists today: `GIT_WORKTREE_PARENT` in `zsh/.zshrc` covers content-engine only, and `tmux-remote-workspaces/scripts/common.sh` already normalises an origin URL to `host/owner/repo`.
