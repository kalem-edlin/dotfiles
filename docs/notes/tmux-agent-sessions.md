# Tmux agent sessions

The tmux agent sessions picker is complete. It replaces the sessionx popup behind `prefix o` with a custom picker that shows, for every tmux session, which Claude Code and pi agents are running, what each one is called, what state it is in, and how much memory each window and session uses. Agents publish their own state into tmux pane options, so opening the picker costs one tmux call and one memory helper call. This document records the current system and the decisions needed to maintain it. It is not an implementation plan or backlog.

The plugin directory has no README of its own, so this note is the reference for its files, options and keys.

The full planning history (user intent, findings, decisions D1-D70) is in commit 44c0a44, `docs/tasks/sessionx-improvements.md`, removed after this note replaced it.

## Why it exists

- Sessionx had no resource usage support, opened slowly (tens of tmux client calls and about 1 s at the pinned commit), and offered weak extension points. Owning the picker made it faster to iterate on the picker and the agent hooks together, so sessionx and its pin were removed from `tmux/tmux.conf` and `setup/lib.sh`. An old checkout may still sit under `~/.config/tmux/plugins/tmux-sessionx` until it is deleted by hand.
- The state model follows herdr and similar tools: the agent reports its own state through hooks or an extension, and the picker reads it. The picker never scrapes pane contents to decide status, never polls ssh, and never runs per-session tmux calls. Reports from the agent are cheap, exact and survive UI changes in the agent.
- The pushed-state design has the usual failure modes and the system handles them explicitly. A crashed agent leaves its options behind, so the picker checks that `@agent_pid` is alive. An Esc interrupt fires no `Stop` hook, so Claude's `idle_prompt` notification recovers the state. `pane_current_command` is unreliable for Claude Code because it renames its process, so the publisher records the agent pid itself.
- Boundaries that still hold: opening the picker makes one tmux call and one `pane-mem` call (about 5 ms for the helper), the picker has no fork or patch of sessionx to maintain, and agents never invoke `tmux` against the live server during verification of tmux-side work.

## Components and file locations

Everything tmux-side lives in the local plugin `tmux/local-plugins/tmux-agent-sessions/`, loaded by `run-shell` from `tmux/tmux.conf` next to the other local plugins and before TPM.

| Path (plugin dir) | Role |
|---|---|
| `tmux-agent-sessions.tmux` | Binds `prefix o`, sets `@agent_clock`, installs the `pane-focus-in[41]` hook |
| `scripts/agent-state` | Publisher called by Claude Code hooks |
| `scripts/pane-mem` | Memory entry point. Runs `bin/pane-mem-darwin` when present, otherwise one `ps` snapshot summed with awk |
| `scripts/pane-mem-chip` | Prints the status line chip for the current pane |
| `scripts/wire-mem-chip` | Idempotently prepends the chip to `status-right` after TPM |
| `src/pane-mem.c` | Source of the macOS footprint helper |
| `picker/` | Go module `agentpicker` with packages `state`, `tmuxio`, `ui` and `main` |
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
| `@agent_at` | publisher on every transition except the focus-to-Idle one | Epoch of the last agent event. Drives the picker's initial card and session ordering, so a visit must not move it |
| `@agent_state_at` | publisher, focus hook | Epoch when the current state began. A repeat of the same state keeps the stamp. Drives the age shown on chips |
| `@agent_name` | publisher | Session title (see Titles) |
| `@agent_subs` | publisher | Running subagent count. Reset to 0 at session start. pi publishes its running `/sub` count |
| `@agent_empty` | publisher | `1` from session start (startup, `/new`, `/clear`) while the chat has no prompt. Unset on the first prompt, on resume and on compaction |

Rules for the publishers:

- Every write for one event is a single tmux invocation, with commands chained by `;`.
- Both publishers do nothing without `$TMUX_PANE`, and both guard against a stale `$TMUX` (an orphaned agent that still points at a dead server, since pane ids restart at `%0` on a new server). The Claude script compares the inherited server pid with `#{pid}` where it reads from tmux anyway and otherwise checks that the server is alive. The pi extension checks the server pid with `kill(pid, 0)`.
- `@agent_state_at` is written with `set -F` using `#{?#{&&:#{==:#{@agent_state},NEW},#{@agent_state_at}},#{@agent_state_at},NOW}` before `@agent_state` is overwritten, so the age needs no read round trip.
- `@agent_pid` for Claude: the publisher walks up from its parent with `ps -o ppid=` until it reaches the process whose parent is `#{pane_pid}`. If the first hop is a hook wrapper shell directly under the pane process, the agent is the pane process itself. This avoids depending on hook wrapping or on Claude renaming its process. For pi it is `process.pid`.
- `@agent_subs` decrement clamps at zero: `set -pF @agent_subs '#{?#{e|>|:#{@agent_subs},0},#{e|-|:#{@agent_subs},1},0}'`.
- Text values are sanitized (control characters to spaces, runs collapsed, trailing separators stripped) so a name cannot break tmux argv or a picker row.
- Claude hooks are registered with `async: true` except `UserPromptSubmit`, `SubagentStart` and `SubagentStop`, which are synchronous so a turn's `Stop` can never land before them, and `SessionEnd`, which must finish before Claude exits. The `Notification` hook matches `elicitation_dialog|elicitation_url_dialog|idle_prompt` and `PreToolUse` and `PostToolUse` match `AskUserQuestion` only.
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
| Claude `Stop` with `@agent_subs` above 0, or a background shell | working |
| `Stop` or pi `agent_settled`, marker present, no subagents | awaiting |
| `Stop` or `agent_settled`, no marker, pane visible | idle |
| `Stop` or `agent_settled`, no marker, pane not visible | finished |
| tmux `pane-focus-in` while finished | idle |
| Claude `SessionEnd` (except reason `clear` or `resume`), pi `session_shutdown` | all `@agent_*` options unset |

Details that matter when changing this:

- A pane is visible when `#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}` is true, evaluated with `if -F` in the same tmux call that sets the state (D8). An attached but unfocused terminal counts as visible.
- The focus transition is a tmux hook (`pane-focus-in[41]`, a fixed array index so reloads stay idempotent and other hooks are left alone) with an `if -F` check, so a focus change spawns no process. The epoch comes from `set -g @agent_clock '%s'` expanded with `#{T:@agent_clock}`. It touches `@agent_state` and `@agent_state_at` only, never `@agent_at`. It also fires when the terminal regains focus, which counts as a visit.
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

- Claude: `SubagentStart` and `SubagentStop` adjust `@agent_subs`.
- pi: `subagent-widget.ts` emits the running count on `pif:subagents`. `agent-state.ts` publishes it as `@agent_subs`, and a settle with subagents running publishes Working. A finished subagent starts a parent turn, which settles as usual. If no turn starts within 2 s (after `/subrm` or `/subclear`), the held Working settles on its own.
- `idle_prompt` arrives about 60 s after the prompt goes idle, including while background subagents run, so the Esc-recovery rule applies only when `@agent_subs` is 0 (D69). Recovery after a real Esc interrupt therefore takes about 60 s and the pane shows Working until then.
- Background shell detection (D70). A subagent that backgrounds a command and ends its turn fires `SubagentStop` at once and `SubagentStart` only when it resumes, and a main-agent `run_in_background` shell fires no hook at all. So `Stop` and `idle_prompt` call `bg_shells`, which runs one `ps -A` and looks for a direct child of the agent process whose command line contains `/.claude/shell-snapshots/`. At those two points no foreground tool runs, so any such child is background work and the state stays Working. The tmux read for the agent pid happens only if some shell-snapshots process exists at all. Cost is about 40 ms per `Stop`.
- Known tradeoff: a dev server started as a Claude background shell keeps its agent Working. This is accepted because persistent jobs belong in tmux panes.
- A subagent that dies without `SubagentStop` leaves the pane Working until the next `SessionStart`.

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
- One load is one `tmux display-message -p -c CLIENT '#{session_id}' ; list-panes -a -F ...` call (the format carries session, window, pane, pids, commands, `#{session_last_attached}`, `@remote-host`, `@workspace-last-command` and every `@agent_*` option) plus one `pane-mem` call. A failed first load prints the error and waits for enter. Data is reloaded only after an action.
- Measured: keypress to first frame was 76 to 89 ms in an isolated popup run, polling overhead included. Cold start of the binary is about 23 ms, mostly Charm library init.

### Implementation notes

- The module `picker/go.mod` pins `junegunn/fzf` (only `src/algo` and `src/util`), and `charm.land/bubbletea/v2`, `lipgloss/v2` and `bubbles/v2`. The Charm v2 modules live under `charm.land`, and the `github.com/charmbracelet/*/v2` paths fail `go get`.
- `algo.Init("default")` must run at start, or scores are wrong.
- Package split: `state` holds the snapshot types and the `Actions` interface, `tmuxio` holds the tmux call, `pane-mem` and the actions, `ui` holds the Bubble Tea model and rendering, and `main` wires them.
- Bubble Tea runs with `tea.WithColorProfile` set to truecolor and no background detection, so no colour query goes to the terminal. All state is in memory. A keystroke updates the model and redraws without starting a process. The escape timeout is Bubble Tea's 50 ms default. The size can read as 0 under tmux (Bubble Tea issue #1718), so the model renders at 80x24 until a real size arrives. A reply to the synchronized-output query could leak to the shell on a very fast quit (issue #1590) and did not appear in testing, including esc 80 ms after open.
- Search is plain matching of a name or a piece of one, anywhere in the session name (D33). The whole query is one case-insensitive pattern run through `algo.FuzzyMatchV2`, which also gives the highlight positions (shown in red). fzf's extended syntax is not implemented. Rows keep their order and are not re-sorted by score. After a query change the cursor moves to the bottom match.
- Actions run in Go through `tmuxio`. Targets are ids (`$N`, `@N`, `%N`), and names are passed only where tmux needs one. `AGENT_SESSIONS_RW_CLOSE` overrides the `rw-close.sh` path.

### Layout

From the top: the card grid, the session list, then the input line between two rules. There is no header and no key hints.

| Part | Rule |
|---|---|
| Session list | 6 rows (`listRows`), bottom up. With fewer sessions the empty rows sit at the top. Panel background is the base blended 70% toward surface0 |
| Input line | Query with a static block cursor (no blink ticks). At the right edge the match count (`matches/total` sessions) and a 2-column cell, `#a6e3a1` at rest and `#f38ba8` while the prefix is armed. The rules above and below use `#585b70` |
| Grid | Everything above the list. Hidden when less than one card row (`cardRows + 2` lines) fits |
| Short screens | `heights()` gives the input line priority, then up to 6 list rows and the two rules. Rows go from the grid first, then from the list down to one row, and the rules drop only when no list row would be left |

On a large screen the grid may use fewer lines than it is given, which leaves a blank gap between the grid and the list. This is accepted, and the popup size stays at 90% by 85%.

The text input keymap is trimmed so it does not take `ctrl-a`, `ctrl-d`, `ctrl-j`, `ctrl-k`, `ctrl-n`, `ctrl-p`, `ctrl-u` or `ctrl-w`. Arrows, backspace and typing still edit. Prompts (rename, new window, new session) additionally get `ctrl-u`, `ctrl-w`, `ctrl-a` and `ctrl-k` as in tmux's command prompt, so a prefilled name can be cleared.

### Session order and initial cursor

Session order, top to bottom (D63): the invoking client's session is always last (bottom). The others are sorted so higher priority sits lower, comparing in turn the Awaiting count, the Done count, the Working count, the newest agent state change (`@agent_state_at`, else `@agent_at`), then `session_last_attached`. Counts compare one after another (two Awaiting beats one Awaiting plus five Done) and not as a weighted sum. Ties keep tmux's order.

The cursor starts one row above the bottom (D13), which is the highest priority session other than the current one. With a single session it sits on that session. The window of the list is anchored at the bottom so the current session shows.

### Session rows

Left to right: a gutter column (dark, with a rosewater `▌` on the selected row), the name, then three sections pushed to the right edge and divided by thin vertical lines (`#585b70`). A long name is truncated with `…` before chips are dropped, and chips are dropped (rightmost first) only when the name would fall under 12 columns. The selected row has a light highlight across its full width.

1. Status chips: Working, Awaiting, Done in that order, each only when its count is above zero (D55). Each reads count, label, age (`2 Working 4m`), where the count is the number of agents in that state and the age is the newest state change among them. This is the only section of variable width. There is no Idle chip on rows.
2. Agents: bot glyph, a space, the count of all agents in the session, then the age of the newest state change of any of them (`<bot> 3 5m`, D66). A session with no agents shows `<bot> 0` with no age. The section is a constant 8 cells so it aligns on every row. The count shows up to 99.
3. Memory, right aligned in a width shared by all rows (at least 5 cells).

Only the status chips have a background. `ctrl+w` switches the chip labels between words and icons (`2 <icon> 4m`) for that picker run (D57). The setting is not saved.

Ages use the format `42s`, `5m`, `3h`, `2d`, then weeks from 7 days (`3w`), with no months. The age is dimmer than the text beside it everywhere: on rows outside a chip it is `#7f849c` (or `#a6adc8` on the selected row), and on chips it is a lighter shade of the chip text (see colours).

### Cards

The grid has one mode (D50). Cards fill at most two columns, each half the width, and one column when half the width is under 30 columns. A card is 3 content rows inside a rounded border, with one column of padding. A grid row takes the height of its tallest card. At most 3 full grid rows show, and when more rows exist below, the top border and first content line of the next row show under them as a cue (D36). The scroll offset counts grid rows and follows the selection.

Card construction:

- One card per window. A window with two or more agent panes gets one card per agent pane instead, in pane order (D51). A window with one agent pane is one card for that agent.
- Header: `W name` on a window card and `W.P name` on a split card (D58). The index is lavender. Split cards of one window show the same window pane count and the same window memory total, and only the header and agent title differ.
- Subtitle (D53): `Empty chat` (dimmed) for an agent with `@agent_empty`, else `@agent_name`. A card with no agent shows the running command of the window's lowest-index pane. At a shell prompt that is the last command line from `@workspace-last-command`, dimmed. Otherwise it is `@workspace-last-command` if set (`pnpm branch` where `pane_current_command` says `node`), falling back to `pane_current_command`. `#{pane_title}` is unusable because `allow-set-title` is off.
- Third line, wrapping when needed: the `N panes` chip (always shown, `1 pane` included, text `#cdd6f4` on `#45475a`), the agent chip if any, and the window memory as plain text with no cell. An agent chip reads `claudef <icon> 5m` or `pif <icon> 5m` (a card shows at most one agent, with no aggregate chips).
- Text that does not fit is truncated with `…` or wrapped at the card edge.
- Unselected cards blend every colour, chips included, 50% toward the base (`dimAmount`). The selected card has a bright border (`#cdd6f4`) and full colour.

Selection and keys:

- The initial card is the one for the pane whose agent changed state most recently (`@agent_at`), else the active window's active pane. It may sit further down the grid, and the grid scrolls to show it.
- `ctrl-j` and `ctrl-k` step through cards in reading order and stop at the first and last card. `ctrl-d` and `ctrl-u` move one grid row keeping the column, landing on the last card for a short last row.
- Moving to another session rebuilds the grid and reselects the default card.

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

| Key | Action |
|---|---|
| `ctrl-n`, `down` / `ctrl-p`, `up` | Next / previous session |
| `ctrl-j` / `ctrl-k` | Next / previous card |
| `ctrl-d` / `ctrl-u` | Card row down / up |
| `ctrl-w` | Toggle row status chips between words and icons |
| `enter` | Go to the selected card, or create a session from an unmatched query |
| `esc`, `ctrl-c` | Close |
| `C-a c` | New window in the selected session, name prompted (empty keeps automatic naming) |
| `C-a C` | New session, name prompted with the query as the default |
| `C-a r` | Rename the selected card's window |
| `C-a R` | Rename the selected session |
| `C-a q` | Kill the selected card's pane (split card) or window (window card) |
| `C-a Q` | Kill the selected session after a `y/N` prompt |
| `C-a esc` | Close (the prefix disarms and `esc` closes as usual) |

Prefix emulation (D16). In tmux 3.7b a popup is an overlay: `server_client_handle_key` gives every key to the overlay callback before any key table is consulted, and `popup_key_cb` writes it to the popup's job. tmux prefix bindings never run while the popup is open, so the picker emulates the prefix itself. `ctrl-a` arms it (the cell turns red) and the next key is checked against `c C r R q Q`. Any other key disarms and does its normal job (`C-a ctrl-j` moves the card as if `C-a` was never pressed, and `C-a x` types `x`). Lowercase acts on the card selection and uppercase on the session. Option chords are avoided because AeroSpace uses Option, `fn` triggers Wispr Flow, and no Ghostty remaps are used. tmux 3.8 replaces popups with floating panes, so re-check this on an upgrade.

Enter targets. A split card runs `switch-client`, `select-window` and `select-pane` on its pane. A window card runs `switch-client` and `select-window` and keeps the window's active pane. With no session matched, enter creates a session named by the query (rejecting empty names and names containing `.` or `:`).

Action behaviour:

- Name prompts and the kill confirmation are inline in place of the input line, and `esc` cancels. Errors show inline in the input line.
- After any stay-open action the picker reloads, even when the action failed, because a kill can succeed after `rw-close.sh` fails. A failed reload keeps the old snapshot. The selected session and card are kept by id when they still exist.
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
  - `go -C tmux/local-plugins/tmux-agent-sessions/picker test ./...` covers snapshot parsing from fixture `list-panes` output, session ordering, the matcher, age formatting, golden renders of rows, cards, the grid and the input line at several widths, model tests that feed key messages (prefix arm and disarm, card stepping, mode toggle, default selection, enter), and action tests against a fake `tmux` shim first in `PATH`.
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
| Claude hook registrations in `settings.json` | Restart the Claude session (hooks are read at session start) |
| `agent-state.ts` or `subagent-widget.ts` | `/reload` in pif (an old runtime's state write cannot overtake a new runtime's start, because the publish chain is shared on `globalThis`) |
| Icon font, `SIZE`, codepoints, `font-codepoint-map` | Rerun `make lucide-font` if the font changed, then restart Ghostty |

Maintenance cautions:

- Do not invoke `tmux` against the live server from tooling or tests. Verify tmux-side work statically, with shims, or against an isolated `-S` server.
- Any new `run-shell` binding that can show a dialog must exit 0 or end in `|| true`.
- Changing the option contract means changing `scripts/agent-state`, `agent-state.ts`, the `list-panes` format in `picker/tmuxio/snapshot.go` (columns are positional, keep the constants in step) and the fixtures together.
- The marker text is shared by `agents/communication.md`, `scripts/agent-state` and `agent-state.ts`.

## Known gaps and limitations

- Remote (rw) panes show `remote` and no agent state, since their agents run inside the worker's tmux server. Pulling state over ssh was deliberately not built, and ssh must never be polled from a `#()`.
- A reply that asks a question without the marker shows as Done. A "last line ends with ?" fallback was deliberately not added.
- After an Esc interrupt the pane shows Working until `idle_prompt` arrives, about 60 s later.
- A Claude background dev server keeps its agent Working (D70).
- A subagent that dies without `SubagentStop` leaves the pane Working until the next `SessionStart`.
- Memory is footprint on macOS, so totals overcount shared and graphics memory.
- Pane option writes do not trigger resurrect saves. Autosave runs from a separate 300 s timer.
- The tmux 3.7b popup behaviour that forces prefix emulation may change in 3.8.
