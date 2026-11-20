# Drop-to-remote paste: local files dropped into remote panes land on the worker

Status: design accepted 2026-11-20, build starting 2026-11-20. Owning system doc: `docs/tmux-remote-workspaces.md` (add a short "Dropping files into remote panes" section there when the build lands; the detail stays here).

## User intent (verbatim)

2026-11-20:

> Also one more thing I want to see if you can ship / derisk, and that is when dragging an image into a terminalwindow that is sshed / tmux remote workspace connected to a remot host, that the FILE im dragging from my local machine is somehow moved over to the new machine w/ the now remote path placed if its done into a nvim pane OR we figure out a way to ensure that the image is copied to clipboard and able to be control+v 'd into the pif or claudef chat right? What are your thoughts on the best ways for me to get file paths by dragging into nvim/vim buffers / agentic input text areas, as well as doing it by means of copy and paste. Make sense?

On remote-side detection of laptop paths (rejected):

> It will not be deterministic enough or consistent enough to have the remote host detect if a file path comes from the laptop. It's not flexible enough for our needs. It's going to be too hard-coded. I can already see that happening so I don't think that's going to be a valid approach. Maybe our local or remote tmux sessions can do something about it via interception?

On where copied files land:

> For copied files: this please: `or the same relative spot as on your laptop.`

On the shim and on risk (the acceptance bar for this build):

> I woudl just HATE IT if we tried to do this [the pty shim] that it would have a negative performance impact on the tmux workspace lcoally and or remotely... - that said - it DOES sound good.

> Also definitely YES to this: [O3, a hotkey for clipboard images]

> just faciliate the build out of this w/ opus subagnets and lets really ry to amke sure and adversarially review the implementation such that it will NOT have ANY performance impact / risks to up time / weird bugs that could completely CRASH the tmux window - rather ideally just fail the copy if it needs to fail - not crash the full tmux process. Im worried that this will introduce risk surface area if not addressed CORRECTLY.

## Findings that fix the design

- F1 tmux cannot intercept a drop, on either side. Ghostty 1.4.0 turns a file drop into a paste (`SurfaceView_AppKit.swift` `performDragOperation` calls `pasteText`), so the terminal sends it as a bracketed paste. In tmux 3.7b `server-client.c`, `server_client_key_callback` checks `server_client_is_bracket_paste` and jumps to `paste_key` -> `window_pane_paste` before any key table lookup. A `bind PasteStart` never fires for a real paste. No hook covers pane input (hook list checked in the 3.7b binary). The remote tmux only sees bytes that arrived over ssh.
- F2 the one deterministic choke point we own is the pty between Ghostty and the tmux client. tmux is started by typing `tmux new` / `tmux attach` in Ghostty's zsh. Every byte Ghostty sends passes through that process's stdin. A bracketed paste is unambiguous: `ESC [ 2 0 0 ~` ... `ESC [ 2 0 1 ~`. Ghostty always sends pastes bracketed to tmux because tmux enables mode 2004 on the outer terminal.
- F3 the dropped text format is known exactly. `NSPasteboard+Extension.swift` `getOpinionatedStringContents`: each file URL becomes `Ghostty.Shell.escape(path)` and multiple items are joined with a single space. `escape` prefixes a backslash before each of: backslash, space, `()[]{}<>"'` backtick `!#$&;|*?` and tab. Unescape rule: a backslash followed by any character yields that character.
- F4 Ghostty has `clipboard-paste-protection = true` and `clipboard-paste-bracketed-safe = true`. A single path has no newline, so no prompt appears and the paste is sent in one piece.
- F5 the rw endpoint record already carries the mapping: `~/.local/state/tmux-remote-workspaces/endpoints/<id>.json` has `worker`, `worker_home`, `workspace.focus_path` and `workspace.remote_path`. The pane option `@rw-endpoint` names the record. `docs/tasks/remote-owned-directories.md` D9 already defines "worker path = worker `$HOME` + laptop path with the laptop `$HOME` stripped".

## Decisions

- D1 Build the pty shim (O1). Rejected: remote-side detection (user), tmux fork with a pane-paste hook (maintenance; only revisit if the shim measurably costs latency), SMB mount of the laptop on the worker (hangs when the laptop sleeps).
- D2 Files land at the same relative spot (user). Inside the pane's workspace: `remote_path` + path relative to `focus_path`. Elsewhere under the laptop home: `worker_home` + path relative to the laptop home (D9 rule). Outside the laptop home (external volume, /tmp): `worker_home/rw-drops/<basename>`, the only case with no "same spot".
- D3 The hotkey for clipboard images (O3) ships with the same build and reuses the push script. Key: `prefix C-v` (verified unbound in the live prefix table on 2026-11-20). Local file: `~/Pictures/rw-clips/<UTC timestamp>.png`, so the remote copy lands at `<worker_home>/Pictures/rw-clips/<same>.png` under D2.
- D4 Fail open, always. Any doubt, error, or timeout means the original bytes reach tmux unchanged. The shim is never allowed to be the reason a tmux client dies. The only user-visible failure is one `tmux display-message` line saying the copy failed and the local path was pasted.
- D5 Zero added latency on the keystroke path. The shim never holds a byte that is not inside a recognised paste bracket. A start marker split across two reads is simply missed (pass-through), it is never waited for.
- D6 Interpreter: `/usr/bin/python3` (macOS 3.9, stdlib only). Not the pyenv shim (100 ms startup) and no third-party modules.
- D7 Scope: remote workspace panes (`@rw-endpoint` set) only in this build. A plain `ssh` pane (`pane_current_command` = ssh) is a documented follow-up, not built now.

## Contracts (pinned before the build)

### C1 Files and names

- `tmux/local-plugins/tmux-remote-workspaces/libexec/rw-paste-shim` (Python, `#!/usr/bin/python3`). Usage: `rw-paste-shim [tmux args...]`. Runs `tmux` with the given args under a fresh pty and relays.
- `tmux/local-plugins/tmux-remote-workspaces/libexec/rw-push-file` (bash, sources `scripts/common.sh`). Usage: `rw-push-file <pane_id> <local path>...`. Prints one remote path per line in input order. Exit 0 only when every file was copied. Exit 2 when the pane is not a remote workspace pane (prints nothing). Exit 1 on any copy failure. Honors `RW_SSH_BIN` and a new `RW_SCP_BIN` (default `scp`) so tests can stub transport.
- `tmux/local-plugins/tmux-remote-workspaces/scripts/rw-paste-image.sh <pane_id>`: reads the laptop pasteboard image (PNG via `osascript -e 'the clipboard as «class PNGf»'`, hex to bytes; no new tools), writes `~/Pictures/rw-clips/<UTC ts>.png`, pushes it with `rw-push-file` when the pane is remote, and types the resulting path into the pane with `tmux send-keys -l`. No image on the pasteboard: one `display-message`, exit 0. Bound in `tmux-remote-workspaces.tmux` as `bind-key C-v run-shell -b '... rw-paste-image.sh "#{pane_id}"'` so tmux never blocks on it.
- `zsh/.zsh/tmux-paste-shim.zsh`, sourced from `zsh/.zshrc` next to the existing `source_if_exists "$HOME/.zsh/tmux-workspace-resurrect.zsh"` line. Defines a `tmux` function that execs the shim only when all hold: stdin and stdout are a tty, `$TMUX` is unset, `RW_PASTE_SHIM` is not `0`, the first argument is empty or one of `new` `new-session` `attach` `attach-session` `a` `at`, `/usr/bin/python3` is executable and the shim file is executable. Otherwise `command tmux "$@"`. The shim sets `RW_PASTE_SHIM=1` in the child environment so nothing nests.
- Tests: `tmux/local-plugins/tmux-remote-workspaces/tests/test_paste_shim.sh` and `tests/test_push_file.sh`, runnable by the existing `tests/run.sh` (headless: no tmux server, no ssh, no network). The shim's protocol core lives in importable functions so the test can drive it with `pty.openpty()` on both sides, a `cat`-like child, a fake `tmux` on PATH that answers `display-message` from environment variables, and a fake `scp`.
- Log: `~/.local/state/tmux-remote-workspaces/paste-shim.log`, append-only, one line per intercept decision or error, never per byte.

### C2 Shim relay rules (the safety contract; the review checks each one)

1. Pass-through is the default. Bytes outside a paste bracket are written to the child the moment they are read. The shim never buffers to look ahead for a marker and never introduces a timer on the keystroke path.
2. Paste capture starts only when a complete `ESC[200~` appears inside a single read. Bytes before it in that read are forwarded first. Capture ends at `ESC[201~`. Cap: 64 KiB or 2 s without the end marker, after which everything captured is forwarded unchanged and capture mode ends.
3. A captured paste is a candidate only when: it contains no newline or carriage return; after splitting on unescaped spaces and unescaping, every token is an absolute path to an existing regular file on the laptop (directories and anything else: pass-through).
4. The pane check runs only for candidates: `tmux display-message -p -t <client tty> '#{pane_id}<TAB>#{@rw-endpoint}'` with a 2 s timeout. Empty endpoint, non-zero exit, or timeout: pass-through.
5. The copy runs in a worker thread so the output direction (child to terminal) keeps flowing. Input read while a copy is pending is queued in order behind the paste, never reordered. Hard deadline 8 s: on expiry the original paste is forwarded, then the queued input, and the copy result is discarded.
6. Copy success replaces the paste content with the remote paths, Ghostty-escaped the same way, same separator, still inside `ESC[200~` ... `ESC[201~`. Copy failure forwards the original paste and issues one `tmux display-message` to the client.
7. Terminal handling: raw mode on the real tty before the child starts, restored in `finally` and on SIGTERM/SIGHUP; initial window size copied with TIOCGWINSZ/TIOCSWINSZ before exec; SIGWINCH forwarded by re-copying size and sending SIGWINCH to the child.
8. Exit: child exit -> restore tty, exit with the child's status (128+signal if signalled). EOF or EIO on the real stdin -> SIGHUP the child, wait, restore, exit. EIO on the child pty -> treat as child exit.
9. I/O: `os.read` in 64 KiB chunks, every `os.write` looped until complete, EINTR and EAGAIN retried, no Python-level per-byte processing outside capture mode (find the marker with `bytes.find`).
10. Any exception anywhere in classification, pane lookup or copy is caught, logged once, and results in pass-through. An exception in the relay loop itself restores the tty and re-raises so the failure is visible, but the loop must have no code path that can raise on ordinary bytes.

### C3 rw-push-file behaviour

- Reads `@rw-endpoint` from the pane with `tmux display-message -p -t <pane_id>`. Loads the endpoint record with `rw_read_endpoint`. Mapping per D2 with physical paths (`rw_physical_path` for the laptop side) and the laptop `$HOME`.
- Transport: one `ssh` with `rw_ssh_stream_opts`, `-o BatchMode=yes -o ConnectTimeout=5`, running `mkdir -p` for each parent; then one `scp` per file with the same options. Total wall-clock budget enforced by the caller (the shim's 8 s). Never starts a new ControlMaster (`-o ControlMaster=no`).
- Prints remote paths only after every copy succeeded, so a partial failure never leaves a half-rewritten paste.

### C4 Testing rules

- Never invoke the real `tmux` (no `tmux` process may be started by any test or any agent; a fake `tmux` script on PATH is the only tmux a test sees). Never ssh. Never touch `~/.local/state/tmux-remote-workspaces`; tests use a sandbox state dir (see `tests/lib.sh` `rw_test_sandbox`).
- Required test cases: plain bytes pass through unchanged byte-for-byte (including lone ESC, mouse sequences, and a paste of ordinary text); a paste of one existing file into a remote pane is rewritten; a paste of a non-existent path passes through; a paste into a local pane passes through; a fake scp that fails yields the original paste plus one display-message; a fake scp that sleeps past the deadline yields the original paste and keeps relaying output meanwhile; input typed during a pending copy arrives after the paste in order; child exit code is propagated; the terminal attributes are restored after exit; a 64 KiB+ paste passes through; a split start marker passes through.
- `bash -n` and shellcheck on the shell files; `python3 -m py_compile` on the shim.

## Risks

- R1 The shim is in front of every new tmux client. Mitigation: D4, D5, C2.8, the `command tmux` and `RW_PASTE_SHIM=0` escape hatches, and the existing clients, which are untouched until reattached.
- R2 Extra pty hop on the output path. Expected cost is one `read`/`write` pair per chunk, the same shape as `script(1)`. Measure in the smoke test: time a `cat` of a large file through the shim versus without.
- R3 `osascript` for the pasteboard can be slow (hundreds of ms) and runs only from the hotkey, never from the shim.
- R4 Ghostty may change the drop format. The unescape rule in F3 is the only coupling; a change makes the shim pass through, not break.

## Build order

- W1 shim + push script + zsh wrapper + tests (opus agent, own worktree).
- W2 adversarial review against C2 and the user's acceptance bar (opus agent, fresh context, code only).
- W3 fixes, re-review of the fixes, findings ledger below, smoke test by the user in a new Ghostty tab (the orchestrator never attaches to or alters the live server).

## Changes recorded by W1 (2026-11-20)

### What was built

Paths are relative to `tmux/local-plugins/tmux-remote-workspaces/` unless they start with `zsh/` or `docs/`.

- `libexec/rw-paste-shim` (Python 3.9 stdlib, `#!/usr/bin/python3`). Pure parts: `parse_paths` (no filesystem access), `all_regular_files`, `classify`, `ghostty_escape`, `rewrite`, and the `PasteCapture` byte state machine. Then `resolve` (worker-thread body), the `Relay` class (select loop over the real stdin, the child pty master and a wake pipe that also serves as `signal.set_wakeup_fd`), and `main`. Only the relay thread writes to the child. The worker thread posts its result through the wake pipe. A `Pending` record moves from `running` to exactly one of `done` (set by the thread) or `cancelled` (set by the relay at the deadline), under a lock, so exactly one side writes the paste and at most one display-message is sent. The tmux it runs, and the tmux it asks for the pane, both come from PATH. The push script is found next to the shim's real path. Log: `<state dir>/paste-shim.log`, where the state dir is resolved exactly like `rw_state_dir`.
- `libexec/rw-push-file` (bash 3.2 compatible, sources `scripts/common.sh`). Implements C3 and the D2 mapping, including physical laptop paths: the parent directory is resolved with `rw_physical_path`, so a file reached through a symlinked directory maps by its real location. Transport is one ssh `mkdir -p --` for all parents, then one scp per file. Remote paths are printed only after every copy succeeded.
- `scripts/rw-paste-image.sh <pane_id>`: osascript `«class PNGf»` -> byte-wise sed strip -> `xxd -r -p` into a temp file in `~/Pictures/rw-clips`. It checks the PNG signature, then renames to `<UTC %Y%m%dT%H%M%SZ>.png` (`-N` suffix on a same-second collision), pushes the file, and types the path with `tmux send-keys -t <pane> -l --`. Every other outcome is one `display-message -t <pane>`. The script prints nothing, because `run-shell` would show it in the pane.
- `tmux-remote-workspaces.tmux`: `tmux bind-key C-v run-shell -b "bash '$PLUGIN_DIR/scripts/rw-paste-image.sh' '#{pane_id}'"`, appended at the end of the file.
- `zsh/.zsh/tmux-paste-shim.zsh`, sourced from `zsh/.zshrc` on the line after the `tmux-workspace-resurrect.zsh` source line. It defines a `tmux` function with exactly the C1 conditions, and only in interactive shells.
- Tests: `tests/test_paste_shim.sh` builds the sandbox and fakes, lints, and runs `tests/paste_shim_driver.py`. `tests/test_push_file.sh` covers rw-push-file plus rw-paste-image.sh.
- Deployment note: `~/.zsh` is a stow-folded real directory (it holds per-file symlinks), so `~/.zsh/tmux-paste-shim.zsh` only exists after `make install` (stow) runs. Until then `source_if_exists` skips it and the feature is off. Existing tmux clients are untouched until they are reattached from a new shell.

### Deviations from the contracts and design notes, and why

1. Child process placement (design note said `pty.fork()`). Built: `os.openpty()` + `os.fork()`, and the child calls `setpgid(0, 0)`. It gets its own process group inside the shim's session, not a new session and not a controlling tty. Why: tmux `suspend-client` (default `prefix C-z`, still bound because `unbind -a` is commented out in `tmux.reset.conf`) makes the client send itself SIGTSTP. A process group whose leader's parent is in another session is orphaned, and the kernel discards SIGTSTP for it. Verified on this Mac: a `setsid` child's self-SIGTSTP returned without stopping. Under `pty.fork()` the server would mark the client suspended and stop reading its tty, while nothing actually stopped and nothing would ever send SIGCONT: a frozen tab. With its own group in the shim's session the stop really happens. Side benefit: the kernel's SIGWINCH for the user's terminal goes only to the shim's group, so the client never sees a resize before the shim has copied the new size. Cost: the client is not a session leader, so if the shim is SIGKILLed the kernel sends the client no SIGHUP (see residual risk R-W1-3).
2. Client tty for the pane lookup (design note said `os.ttyname(real stdin)`). That is Ghostty's tty, which tmux does not know. The tmux client's tty is the shim's inner pty slave (`client_tty`), so the lookup uses `os.ttyname(slave)`. The test asserts that the lookup targets the child's tty and that this tty differs from the outer one.
3. New behaviour not in C2, which mirrors job control: when the child stops (`waitpid` with `WUNTRACED`), the shim forwards the remaining child output, restores the real tty, sends itself SIGTSTP so zsh sees a suspended job, and on `fg` re-applies raw mode, sends SIGCONT to the child and re-sends the size. When its own stop is discarded (no job control above it), it continues the child at once instead of leaving it stopped.
4. The filesystem half of the classifier (C2.3) and the pane lookup (C2.4) run on the worker thread, not just the copy (C2.5). The relay thread runs only the pure parse on a completed paste. Why: a `stat` on a dead network volume, or a slow tmux server, must never block the output direction. The 8 s deadline starts at the end marker and spans check, lookup and copy. The lookup timeout is min(2 s, time left).
5. The parse tolerates a trailing run of unescaped spaces and re-appends it unchanged after the rewritten paths. Reason: some drop sources add a trailing space. F3 says Ghostty does not, so this only adds tolerance. A leading space, or two spaces in a row, means not a candidate. Control characters (other than an escaped tab), invalid UTF-8, a dangling backslash, or any token not starting with `/` also mean not a candidate.
6. Window size: the full `winsize` struct is copied, pixel sizes included, instead of `struct.pack('HHHH', rows, cols, 0, 0)`, because tmux uses the pixel size for images. Before the fork the size is set on the slave (no race). On SIGWINCH it is set on the master and the child gets SIGWINCH.
7. The inner pty starts with the real tty's termios, copied before the fork the way script(1) does it. tmux then sets its own modes.
8. C2.8 "SIGHUP the child, wait" is bounded: 0.2 s grace, then SIGHUP and SIGCONT (in case it is stopped), up to 2 s, then SIGKILL, up to 2 s more. Child exit is detected through SIGCHLD on the wakeup fd as well as EIO/EOF, because the tmux server keeps the client's tty open, so EOF on the master can lag the client's exit. After the child exits, the remaining pty output is forwarded (at most 1 s, stopping after 50 ms idle).
9. SIGINT is handled like SIGTERM and SIGHUP. In raw mode ^C is a byte, so only `kill -INT` reaches it.
10. Nesting: C1's wrapper only checks `RW_PASTE_SHIM != 0`, so `RW_PASTE_SHIM=1` alone would not stop nesting. The shim itself execs plain tmux when `RW_PASTE_SHIM=1` is in its environment. That is what makes "nothing nests" true, for example when something inside a pane runs `env -u TMUX tmux attach`. The shim also execs plain tmux when stdin or stdout is not a tty, and when any setup step fails before the child exists. That is fail-open at startup, logged.
11. C1 says the wrapper "execs" the shim. It runs it as an ordinary command instead, so detach still returns to the zsh prompt as it does today (`exec` would close the tab on detach).
12. rw-push-file adds `-s -q` to scp. `-s` forces SFTP mode: the legacy scp protocol passes the worker path through the worker's shell, so a dropped file named `$(...)` would run there. In SFTP mode the path is taken literally. The test drops a file named `a b;$(touch PWNED)'q"*.png` and checks that nothing ran on either side. This needs OpenSSH 8.7 or later on the laptop (10.0p2 here) and the sftp subsystem on the worker (macOS default). Without them scp fails, which means exit 1, so the original paste goes through plus one message.
13. rw-push-file exit codes beyond C1. Exit 1 when two inputs map to the same worker path, for example two files outside home with one basename: it never overwrites silently. Exit 64 on usage errors. Exit 1 when jq is missing. Exit 2 when the endpoint record has no `worker` or a non-absolute `worker_home`. Stdin is closed for ssh and scp.
14. rw-paste-image.sh behaviour C1 leaves open. When the push fails, it types nothing and shows "copying the clipboard image to the worker failed; it is saved in ~/Pictures/rw-clips", because typing a laptop path into a remote pane is useless. In a local pane (exit 2) it types the laptop path. Typed paths are Ghostty-escaped, the same as a drop. A non-PNG result counts as "no image".
15. Logging covers only path-shaped pastes (candidates) and errors. Ordinary text pastes are not intercept decisions and are not logged.
16. The shim cases live in `tests/paste_shim_driver.py`, run by `tests/test_paste_shim.sh`, because they need ptys. C1 names only the `.sh` file. The rw-paste-image.sh cases sit in `tests/test_push_file.sh`; C4 does not require them.
17. The attribute-restore assertions mask `PENDIN`. The kernel sets that flag itself when a tty returns to canonical mode (macOS shows it in `tcgetattr` right after a raw-then-restore on a plain pty, with no shim involved).
18. A timeout notification is sent only once the copy phase has started. A lookup that times out is a silent pass-through, as C2.4 specifies.

### Tests (all headless; the only tmux any test sees is a fake script on PATH; no ssh, no network)

- `bash tests/run.sh paste`: `test_paste_shim.sh`, 11 checks (py_compile, `bash -n` and shellcheck on the 4 shell files, `zsh -n` on the wrapper, driver result). Driver: 88 checks, 0 failed.
  - Unit: parse (escaped path, two paths, trailer, relative, newline, CR, double space, leading space, dangling backslash, control byte, invalid UTF-8, empty); escape/parse round trip over every Ghostty special; PasteCapture (plain bytes, complete paste, split start marker in two reads, split end marker, over the cap, capture timeout).
  - End to end with the real binary on a pty: pass-through byte for byte (text with CR, lone ESC, SGR and X10 mouse, a paste of text with a newline, a missing path, a directory, control bytes, all 256 byte values); one file with spaces and parentheses into a remote pane is rewritten, the file arrives on the fake worker, the lookup targets the inner tty, no message, the log line is written; two files are rewritten in order; a missing file passes through with no lookup; a local pane passes through after one lookup, with no copy and no message; a failing lookup passes through; a hanging lookup is released by the 2 s timeout; a failing scp gives the original paste and exactly one display-message to this client; an scp that sleeps 23 s is released at 8 s with the original paste followed by the input typed meanwhile, output ticks keep flowing (20 in 4 s), exactly one "timed out" message, and the scp process group is killed; queued input, including a second paste, arrives in order after the rewritten paste; the child's exit code is propagated (7); a 70 000-byte paste passes through with no lookup; a split start marker passes through with no lookup; a start marker with no end marker is forwarded after 2 s and relaying continues; the window size is copied before start and after SIGWINCH; terminal gone (master closed) makes the shim exit; SIGTERM makes it exit with the tty restored; suspend without job control continues the client and restores raw mode; suspend under a job-control launcher stops the shim with the tty restored, `fg` resumes the client and restores raw mode, then exit 0; `RW_PASTE_SHIM=1` runs tmux directly on the same tty; stdin not a tty runs tmux directly; the child sees `RW_PASTE_SHIM=1`; no run wrote anything to stderr; terminal attributes are restored after every exit checked.
- `bash tests/run.sh push`: `test_push_file.sh`, 50 checks, 0 failed: the D2 mapping (inside the workspace, elsewhere under home, outside home, a symlinked directory, several files in order); a hostile file name copied verbatim with no command run on either side; ssh/scp option shapes (one ssh for the mkdir, `ControlMaster=no`, `BatchMode=yes`, `ConnectTimeout=5`, the stream ControlPath, `-s`); exit 2 for a local pane, an unknown pane and a missing record; exit 1 with no output for scp failure, failure of the second of two copies, unreachable worker, missing file, directory and duplicate target; exit 64 on usage; rw-paste-image.sh with no image, remote pane, local pane, copy failure and a non-PNG pasteboard.
- Both suites were run 3 times in a row with no failures. Lint: `bash -n`, `shellcheck -x` (run from each file's directory, the repo convention) and `/usr/bin/python3 -m py_compile` are all clean.

### Measurements

R2, measured 2026-11-20 on this laptop. The child is a fake `tmux` that execs `/bin/cat`, and the measuring process reads the pty master as fast as it can.

| Measure | Direct | Through the shim |
|---|---|---|
| 50 MB of text to a pty, harness A (subprocess, 3 runs, two sessions) | 0.83 / 0.56 / 0.55 s; 0.58 / 0.56 / 0.56 s | 0.94 / 0.94 / 0.92 s; 0.91 / 0.96 / 0.93 s |
| 50 MB of text to a pty, harness B (fork + wait4, 3 runs) | wall 0.57-0.58 s; CPU user 0.00 s, sys 0.22-0.23 s | wall 0.66-0.71 s; CPU (shim + cat) user 0.23-0.24 s, sys 0.60-0.62 s |
| 1-byte keystroke echo round trip, raw cat, 500 rounds, run 1 | median 13 us, p99 24 us | median 23 us, p99 46 us |
| same, run 2 | median 21 us, p99 85 us | median 57 us, p99 284 us |
| Idle shim | - | RSS about 12.5 MB; 0.00 s CPU over 5 s idle (select without a timeout) |
| Start to child output | - | 42-43 ms, including the fake child's own Python start |

Reading the numbers: the shim itself costs about 0.6 s of CPU per 50 MB, roughly 12 ms per MB of terminal output. On a 50 MB burst that adds 0.1 to 0.4 s of wall time. A keystroke gains tens of microseconds, against a 16 ms frame at 60 Hz. Output was checked to be lossless (identical once CR bytes are removed). The `\r\r\n` doubling seen in the raw comparison is the macOS pty ONLCR artefact at buffer boundaries, and it shows up on the direct path as well.

### Residual risks for the reviewer to attack

- R-W1-1: the pane lookup uses `display-message -p -t /dev/ttysNNN`. A client tty given as a target-pane relies on tmux's cmd-find resolving a client name to its session, and from there to the active pane. This was not verified against the 3.7b source or binary, because running tmux is forbidden here. If it is wrong, the lookup errors and the feature is silently inert: pass-through, no harm. Check this first in the smoke test (`paste-shim.log` says "pane lookup failed").
- R-W1-2: the child has no controlling terminal of its own and sits in a background process group of the user's terminal session. This is safe only if the tmux client never opens `/dev/tty` and never calls `tcsetpgrp` (it uses `ttyname(stdin)` and the fd it passes to the server). Verified by reasoning only. Anything that did open `/dev/tty` would get SIGTTIN or SIGTTOU, which the shim mirrors as a suspended job, recoverable with `fg`. Candidates: `lock-server` (bound to `prefix ^X`; macOS lock(1) reads stdin) and `detach -E`.
- R-W1-3: if the shim is SIGKILLed (no cleanup runs), the client gets no kernel SIGHUP because it is not a session leader. The master closes, so the server's next read of the client tty fails, and tmux drops a client on a tty read error. Also not verified here. Worst case: a lingering client process; the sessions survive. The outer tty is also left raw, though zsh's line editor sets its own modes at the next prompt.
- R-W1-4: writes to the child are blocking (C2.9). If the tmux server stopped reading the client tty while a large paste is being written, the relay, and with it the output direction, waits. The server reads non-blocking through libevent, so this needs a wedged server, and then the window is dead anyway.
- R-W1-5: any exception in the relay loop restores the tty, sends SIGHUP to the client (a detach; sessions survive), prints a traceback and exits non-zero. No fault injection test exercises this path.
- R-W1-6: the 8 s deadline covers check, lookup and copy. A large file (a video) over a slow link times out: the original paste goes through, one message is shown, and the scp process group is killed. A partly written file can be left on the worker.
- R-W1-7: rw-paste-image.sh has no wall-clock bound of its own. osascript and the copy run under `run-shell -b`, and `ConnectTimeout=5` bounds only the connection. tmux is never blocked; only the typed path is delayed.
- R-W1-8: messages use `display-message`, as C1 requires. The repo convention in `common.sh` `rw_dialog` says interactive warnings belong in a popup. The orchestrator should decide whether that matters for these two one-line messages.
- R-W1-9: `prefix C-v` is added in the plugin file. That the key is unbound, and that nothing loaded later rebinds it, was checked only in the config files. The doc's own 2026-11-20 check of the live prefix table is the reference.
- R-W1-10: the output direction's throughput cost (Measurements above) applies to every client started through the shim. `command tmux` and `RW_PASTE_SHIM=0` remain the escape hatches.
- Not done in W1: the short "Dropping files into remote panes" section in `docs/tmux-remote-workspaces.md`. The status line says it is added when the build lands, after W2 and W3.

## Findings ledger (W2, W3)

(filled in after review: ID, finding, root cause, outcome, regression test, residual risk)
