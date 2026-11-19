# PIF background shells

Status: built (2026-11-18). See the end of "Decisions".

## Intent

Kalem, 2026-11-18: a pif agent should be able to start a process that runs
in the background, "always visible and owned by said pif process and easily
auditable for the user controlling the pif session". The agent keeps
working, can run several at once, and can write its own shell monitor of an
external resource that ends on success or a timeout. Checking, stopping and
the exit report must be obvious to both the user and the agent. Tool
definitions must add as little context as possible. A running shell must
count toward the pif agent's Working state in the tmux session picker.

Model: Claude Code's background Bash (`run_in_background`), its "N shells"
status-line tag and its shell detail panel (status, runtime, command,
output; `x` stops).

Repo-first: a repo that ships its own copy wins over this profile copy, as
with `delegate`. The content-engine harness carries this as a discussion
point next to A12 (`agentic-harness/docs/tasks/harness/discussion-ledger.md`
"Turn log", 2026-11-18).

## Decisions

- D1. Surface. `extensions/shells.ts` overrides pi's built-in `bash` tool
  and adds two optional parameters, `background` and `service`. A call
  without them runs pi's own bash tool unchanged. No new tool.
- D2. Start. A background call returns at once with the shell number, its
  process group id and its log path: "Shell #N started in the background
  (pgid P, log L). Its exit arrives as a "Shell #N" message." The agent
  reads output with `tail` on the log and stops a shell with
  `kill -- -P`.
- D3. Exit report. When a shell exits, a "Shell #N" message arrives before
  the agent's next model call, or starts a turn when the agent is idle
  (delegate's steer delivery). It carries the outcome (exit code, signal,
  timed out, or stopped by the user), runtime, the last 20 lines of output
  and the log path. Services report too: a dev server that dies is news.
- D4. Timeout. A background shell stops after one hour unless the call
  passes `timeout` (seconds). A service has no default timeout.
- D5. Working. Running non-service shells hold the pane at Working, like
  running delegates (`agent-state.ts` `pif:shells`). Services do not, so a
  dev server cannot pin the pane at Working. "Awaiting your input." still
  wins over a held Working.
- D6. Logs. One log per shell under `$TMPDIR/pif-shells/<pif pid>/`. A log
  over 2 MB is cut back to its newest 1 MB. The directory is deleted when
  the session ends, and at startup pif deletes directories whose pif
  process is gone. Logs do not outlive the session. The exit report in the
  transcript does.
- D7. Lifetime. Ending the session (exit, `/new`, `/resume`, reload) sends
  SIGTERM to every running shell's process group, then SIGKILL after three
  seconds.
- D8. UI. The status line shows "1 shell" / "N shells" while any run (no
  key hint). Down or `ctrl+n` in the focused editor, with the cursor on the
  draft's last line (empty or not), while a shell runs focuses that tag:
  it turns inverse, with no hint text. `enter` opens the list, `up`,
  `ctrl+p` or `esc` go back to the editor, any other key goes back and
  reaches the editor unchanged. Down on an earlier line of a multi-line
  draft is the editor's (`ShellFocus`, via `onTerminalInput`,
  which runs before pi-vim's editor; the tag state reaches `statusline.ts`
  as `pif:shells-focus` { focused }). `ctrl+shift+s` or `/shells` opens the
  list directly: a centred, bordered box, 70% wide on a filled background,
  one row per shell (status icon, #N, the command's first line, runtime,
  "service"). `↑↓`/`ctrl+p`/`ctrl+n` select, `x` removes the shell (stopping it if it runs) and deletes its log, `esc` closes,
  `enter` opens the shell full screen: pi's TUI stops, the screen and
  scrollback are cleared and the header (status, runtime, timeout, pgid,
  log, full command) and the whole log print as plain terminal output in
  the normal screen buffer, so the terminal's scrollback and tmux copy
  mode read it. New output follows live. `x` stops the shell and its
  outcome prints; `q`, `esc`, `←` or `ctrl+c` clear the screen and
  scrollback and restart pi's TUI with a full redraw. Nothing in pi paints
  while its TUI is stopped. The exit message renders as a card on pi's
  tool backgrounds: green on exit 0, red on a failure, kill or timeout,
  the neutral pending shade when the user stopped it. Collapsed: a header
  (#N, the command's first line, outcome, runtime) and the last 5 output
  lines; expanded: the full command, the last 20 lines and the log path.
  Every rendered row is one terminal row: a newline inside a row (a
  heredoc command, 2026-11-18) made pi paint the editor mid-transcript.
  The tool row reads "↳ Shell #N running in the background".
  `ctrl+shift+s` is free in pi, pi-vim, tmux's root table and aerospace.
  Alt keys are out: Ghostty does not send Option as Alt.
- D9. No UI (`pif -p`). As with `delegate`, a non-service background call
  blocks and returns its output as the tool result, so unattended runs keep
  synchronous results. A service still starts in the background and dies
  when the run ends. Open for the content-engine runners: see the ledger
  entry.
- D10. Process rules. The tmux `processes` window rule and the job-bounding
  rule are removed from `agents/communication.md` (section 4, which pif
  links as `communication.md`). Claude Code uses its own background shell
  tool, pif uses this one, and each tool's own description says how.
  Agent-owned dev servers are preferred over tmux panes, which remote
  agents mirrored into the local tmux workspace could not create cleanly.

Status: built and proven live 2026-11-18 (start, status-line tag, held
Working after the turn, `/shells` panel, `x` stop, exit report, log
directory removed on exit). The D8 rework was proven live the same day in
a tmux server with extended keys (csi-u): Down, ctrl+n, Up and ctrl+p on
the tag; Enter opens the list; `ctrl+shift+s`; the full-screen view with
live output, `x` and Esc; tmux copy mode over the view; the view's output
gone from scrollback on return; an agent turn streaming while the view was
open; a heredoc card with no mis-painting; a service that leaves the pane
Finished and dies with the session. Opening the list from the tag's Enter
had to be deferred one tick: an overlay opened inside the terminal-input
handler was created but never drawn.
- D11. Repo override. A repo with `.pi/extensions/shells.ts` silences this
  file, because pi exits at startup when two extensions register the same
  tool name.

## Known gaps

- A pif process killed with SIGKILL cannot stop its shells. A shell that
  writes output dies on the broken pipe. A silent one survives as an
  orphan.

## Future

- F1. Expand a running shell into its own tmux pane from `claudef` and
  `pif`, for a user who wants to watch or type into it. Not built.
