# Manual smoke journey — tmux-remote-workspaces

Purpose: operator-driven final smoke pass. Automated campaign is CLOSED
(see initial-plan.md "Campaign record (2026-08-03)") — every product path
was proven in isolated lanes. This journey is about YOU: real usage on the
real laptop tmux server, building command fluency, and closing the two
remaining user-gated items (OSC 52 human check; warned live canaries).

How to use: do one bucket, report results in chat, coordinator marks it
`[x]` and hands you the next. If anything surprises you, stop and report —
do not improvise recovery on remote state.

Status: `[ ]` pending · `[~]` in progress · `[x]` complete · `[!]` issue found

Conventions: `prefix` = your tmux prefix. All commands run inside your
normal live tmux session — that is the point of this journey. Nothing here
is destructive until Bucket 9, which is explicitly gated.

---

## [x] Bucket 0 — Baseline health (read-only)

From any local pane:

1. `rw doctor`
2. `rw status`

Expect:
- doctor: local prereqs OK (jq/ssh/uuid/config/state dir); per-worker
  preflight OK for `mini` and `agents-roll` (tmux, git, git-lfs present —
  consume-never-provision report); registry/live-pane consistency clean
  (no orphans); clipboard/`allow-passthrough` report for local + workers;
  reconcile `--dry-run` preview showing desired=0, nothing to close.
- status: no rows (zero live endpoints).

Report: full doctor output oddities (or "all clean"), status row count.

## [!] Bucket 1 — First remote pane + status anatomy + OSC 52 check
### (first run found defects — fixed; superseded by Bucket 1R below)

1. Open a fresh local pane in a NON-git directory (e.g. `cd ~`).
2. `rw ensure --worker mini`
3. Expect the pane to become a shell ON mini (verify: `hostname`,
   `echo $TMUX` shows mini's own server socket, `tmux display-message -p
   '#S'` shows a session named `rw-<short-id>-<endpoint-id>`).
4. From a DIFFERENT local pane: `rw status` — expect exactly one row:
   worker=mini, mode=plain, path=mini's `$HOME`, bound pane id matches,
   liveness OK, last event `create`/`attach`.
5. OSC 52 clipboard check (the blocked human item). Outer-tmux copy-mode
   is NOT a valid test (it writes the laptop clipboard directly). The
   copy must ORIGINATE remote-side — run inside the remote pane's shell:
   `printf '\033]52;c;%s\a' "$(printf 'rw-osc52-remote-test' | base64)"`
   then Cmd-V on the laptop. Pass = `rw-osc52-remote-test` pasted,
   proving remote-emitted OSC 52 traverses inner tmux → ssh → outer tmux
   → terminal (the claude-code copy-key path).

Report: hostname/session name seen, status row, and PASS/FAIL on the
clipboard paste (this closes the OSC 52 item).

### Bucket 1 findings (2026-08-03, first run)

- Endpoint creation, @remote-host powerline segment, registry row: PASS.
- DEFECT (fixed, 53af514): first attach after mini's reboot started the
  worker tmux server → continuum auto-restore fired → restore.sh
  switch-client stole the client off `rw-d157af95-29f40b78` onto a stale
  campaign session `smoke-headless`. Everything anomalous the operator saw
  (inner powerline visible, session name `smoke-headless`, window `zsh`,
  dir `admin`) was that hijacked session — endpoint sessions themselves
  run `status off`/`prefix None` as designed. Fixed with a third resurrect
  patch (rw client-guard: restore switch-client no-ops for rw-* clients),
  applied laptop + both workers, doctor-required. Stale session killed,
  client re-pinned.
- `hostname` on mini = `Mac.localdomain`: force-reset left scutil
  HostName unset (LocalHostName still `Alfies-Mac-mini`, so ssh/LAN
  routing unaffected). Optional operator fix:
  `sudo scutil --set HostName Alfies-Mac-mini.local` on mini.
- Split from a LOCAL pane created a remote endpoint: working as designed
  per initial-plan Resolved decision #2 (@rw-window-worker window default
  recorded by the first `rw ensure` in that window). Operator surprised —
  decision pending on whether to drop window-default inheritance.
- `rw status` inside a remote pane reads the WORKER's (empty) registry —
  correct but confusing; candidate UX note in status output.
- Enhancements decided + SHIPPED same day: split ALWAYS follows the
  focused pane's host (window-default inheritance removed, plan decision
  #2 amended); outer dir chip shows remote workspace basename for rw
  panes; autosave chip shows the remote host's save age (30s-TTL cached
  ssh, never blocks) when a remote pane is focused. Also: `rw close`
  exit-1 via prefix-q could NOT be reproduced post-repair (exact
  run-shell path exits 0) — attributed to the hijacked state; watch-item.
- The prior `returned 1` panes were closed; registry at zero.

## [!] Bucket 1R — Re-run with fixes applied
### (second run: 4/6 PASS; dir-chip + OSC 52 defects root-caused & fixed; re-run as 1R2)

### Bucket 1R findings (2026-08-03, second run)

- PASS: bare remote prompt, `#S` = `rw-d157af95-f25e4d91`, host chip,
  autosave chip, chip flip-back, split rule both directions, prefix-q
  close.
- INFO (not a defect): a "restoring session" message appeared in the
  remote pane on first ensure. The worker server had exited (previous
  close emptied it), so this ensure booted it fresh → continuum
  auto-restore ran. The client-guard patch WORKED (you stayed on your
  rw-* session; pre-patch you'd have been yanked onto a restored one).
  Side effect: the restore resurrected the previously-closed endpoint
  session `rw-d157af95-29f40b78` from the worker's last save file as a
  zombie (no laptop endpoint). Killed manually; a worker-side save
  cycle drops closed endpoints from the save file within ~5m, so this
  only bites when the server dies inside that window. Watch-item, not
  chased further.
- FAIL → FIXED: dir chip stuck on `admin` after `cd ~/Developer` in the
  remote pane. `@rw-workspace` is a static ensure-time value. Fix:
  endpoint sessions now set `set-titles on` +
  `set-titles-string '#{pane_current_path}'` (common.sh), so the worker
  tmux pushes its live cwd through the ssh tty as an OSC 0 title; the
  outer dir chip now prefers `#{b:pane_title}` when the title is an
  absolute path, falling back to the workspace root
  (tmux-remote-workspaces.tmux).
- FAIL → FIXED: remote-originated OSC 52 never reached the laptop
  clipboard. Root cause found in tmux.conf itself: the
  `,*:Ms=\E]52;c;%p2%s\a` terminal-override is a %p2-only capability
  string that FAILS tiparm expansion ("could not expand Ms" in
  `tmux -vvv`) — tmux consumed every OSC 52 into a buffer (the test
  payload was found still sitting in mini's tmux buffer) and silently
  emitted nothing, on BOTH hops. The override also clobbered the
  working terminfo Ms of xterm/ghostty clients. Fix: override deleted;
  `set -s terminal-features[8] '*:clipboard'` installs tmux's canonical
  Ms for every client TERM including the `screen-256color` that
  attach-loop pins (attach-loop.sh:309). Verified end-to-end against
  throwaway tmux servers with captured client ttys.

## [x] Bucket 1R2 — Final re-verify (dir chip live cwd + OSC 52)
### (2026-08-04: ALL PASS; one new defect found → fixed → re-verify as 1R3)

Only the two fixed areas plus one attach sanity pass. IMPORTANT
pre-step: your current Ghostty tmux client still carries the broken Ms
from before the fix (tmux builds a client's capability table once, at
attach). Detach and reattach once first: `prefix d`, then `tmux attach`
(or close and reopen the Ghostty tab).

1. Reattach your outer tmux client (above). Then fresh pane, `cd ~`,
   `rw ensure --worker mini`. Worker servers were left stopped, so
   expect one "restoring session" flash (benign, see 1R findings) and a
   bare remote prompt.
2. Dir chip live cwd: with the remote pane focused the dir chip starts
   at `admin`; `cd ~/Developer` in the remote pane → chip flips to
   `Developer` within a couple of seconds. `cd /tmp` → `tmp`. Focus a
   local pane → local cwd again.
3. OSC 52 remote-originated: in the remote pane,
   `printf '\033]52;c;%s\a' "$(printf 'rw-osc52-remote-test' | base64)"`
   then Cmd-V locally. Pass = pastes `rw-osc52-remote-test`. This is
   the same path a remote program's copy key (e.g. claude code's
   copy-last-message) uses, so it stands in for those too.
4. `prefix q` the remote pane: clean close, `rw status` zero rows.

### Bucket 1R2 findings (2026-08-04)

- PASS: dir chip tracks live remote cwd; OSC 52 printf → laptop
  clipboard; splits; `prefix q`; `#S` format.
- INFO (bonus validation): `rw ensure` from inside an existing repo
  checkout materialized the workspace at
  `~/rw-workspaces/<focus-id>/github.com-kalem-edlin-dotfiles` on the
  worker — early confirmation of repo-identity workspace materialization
  ahead of Buckets 5/7.
- NEW DEFECT → FIXED: yank in remote nvim (`vi`→nvim alias) did NOT
  reach the laptop clipboard, while the raw OSC 52 printf in the same
  pane did. Root cause: `clipboard=unnamedplus` makes nvim resolve a
  clipboard PROVIDER, and on the mini it finds `pbcopy` — yanks landed
  on the MINI's own clipboard and no OSC 52 was ever emitted (the printf
  bypassed the provider entirely, which is why it worked). Fix in
  nvim/init.lua: when `SSH_TTY`/`SSH_CONNECTION` is set (and
  nvim ≥ 0.10), force `vim.g.clipboard` to the built-in OSC 52 provider
  so yanks ride the exact tty path the printf test proved. Paste (`p`)
  queries the innermost tmux, which answers from its own paste buffer;
  the laptop clipboard is not readable from remote by design (OSC 52
  reads stop at the first tmux). Re-verify as 1R3.

## [~] Bucket 1R3 — Remote nvim yank + worker picker + sessionx keys

New fix plus two new features (2026-08-04): `prefix e` worker-picker
popup and sessionx ctrl-n/ctrl-p direction swap. All laptop-side except
the nvim change (deployed to both workers).

1. Remote nvim yank: `rw ensure --worker mini`, open `vi something`,
   type a line, `yy`, then Cmd-V locally → pastes that line. (`dd` also
   lands on the laptop clipboard, same as local behavior.)
2. Remote nvim paste: still inside remote nvim, `p` pastes the last
   yank. If it ever hangs "waiting for clipboard", press a key and
   report — that would mean the worker tmux didn't answer the query.
   Note pasting the LAPTOP clipboard into remote nvim is not expected
   to work (OSC 52 reads stop at the first tmux).
3. Picker: from a local pane at a shell prompt, `prefix e` → popup
   lists mini + agents-roll, reachability column fills in
   (… → online/offline); ctrl-n moves DOWN, ctrl-p moves UP; enter on
   `mini` → `rw ensure --worker mini` runs in THAT pane (the focused
   one, not a new window; the pane's cwd drives workspace resolution);
   `prefix q` closes it cleanly. Esc aborts with no side effects.
   Guard checks: `prefix e` from an already-remote pane or from a pane
   running a program (e.g. nvim) → status-line message, nothing typed.
4. sessionx: `prefix o` → ctrl-n now steps DOWN the session list,
   ctrl-p UP.

Report: yank PASS/FAIL, paste behavior, picker flow, sessionx keys.

## [ ] Bucket 2 — Drop resilience + idempotent ensure

1. In the remote pane from Bucket 1, detach the INNER session
   (`tmux detach` typed in the remote shell, or kill the ssh: from
   another pane find it via `pgrep -fl 'ssh.*rw-'` and kill that exact
   pid). Expect: pane does NOT die — attach-loop notices, retries with
   backoff (1s→2s→4s…), and you land back in the SAME remote session,
   shell history intact. Screen redraws cleanly, mouse still works.
2. Optional stronger drop: toggle Wi-Fi off ~15s then on. Expect quiet
   retries while down, reattach when back, nothing deleted.
3. Idempotence: from another local pane run
   `rw ensure --worker mini --pane <that-pane-id>`? — no; ensure targets
   the calling pane. Instead verify via `rw status`: still exactly ONE
   endpoint (no duplicate was ever created by the reconnects).

Report: reconnect observed (rough time), any screen/mouse garbling,
status still one row.

## [ ] Bucket 3 — Splits inherit remote; close semantics

1. With the remote pane active: `prefix \` (vertical split). Expect the
   new pane is ALSO on mini, same workspace, but its OWN endpoint —
   `rw status` now shows two rows with distinct endpoint ids.
2. `prefix /` for horizontal — same behavior (close one after if crowded).
3. Close one remote pane with `prefix q`. Expect: tombstone written,
   remote session for THAT endpoint gone on mini, pane closes, `rw status`
   drops to the remaining row(s). Other remote pane unaffected.
4. Try `rw close --no-kill-pane` from inside a remaining remote pane's
   sibling (`rw close --pane <id> --no-kill-pane`): endpoint closes but
   the pane survives as a local shell.
5. Recreate one remote pane, put it in its own window, then `prefix &`.
   Expect the stock confirm prompt mentioning remote endpoints; on `y`
   the window dies AND its endpoint closes cleanly (check `rw status`).

Report: status counts after each step, any pane that died when it
should have survived (or vice versa).

## [ ] Bucket 4 — Remote Treemux

1. Ensure a remote pane on mini (any mode). `prefix Tab`.
2. Expect: Treemux sidebar opens INSIDE the worker-side session, rooted
   at the remote pane's directory. File opens, git signs, and splits all
   act on mini's filesystem — spot-check by opening a file that exists
   only on mini.
3. Close sidebar; pane returns to normal.
4. (agents-roll note: remote Treemux there is expected to REPORT missing
   nvim >= 0.10 rather than open a misleading local sidebar — that check
   happens in Bucket 8.)

Report: sidebar rooted correctly remote-side? any local-sidebar
confusion?

## [ ] Bucket 5 — Workspace handoff / return (ad hoc, dirty state)

Low-stakes scratch repo so mistakes cost nothing:

1. `git clone git@github.com:kalem-edlin/dotfiles ~/rw-journey-scratch
   && cd ~/rw-journey-scratch`
2. Dirty it three ways: edit a tracked file (unstaged), stage a second
   edit, add an untracked file (`echo hi > SCRATCH-untracked.txt`).
   Note `git status` output.
3. From a pane cwd'd there: `rw handoff --worker mini`
4. Expect: preflight → ad hoc placement (clone under
   `~/rw-workspaces/<focus-machine-id>/...` on mini, cloned with MINI's
   own git auth) → transactional sync → pane becomes remote, cwd the
   worker checkout, `git status` BYTE-IDENTICAL to step 2 (same branch,
   same staged/unstaged split, untracked file present). Local tree left
   per handoff semantics (default moves writer role; `--keep-local` was
   not passed — confirm what local side shows and report it).
5. Make one MORE remote edit (`echo remote >> SCRATCH-untracked.txt`).
6. `rw return`
7. Expect: state flows back byte-identical including the remote edit;
   pane lands back local in `~/rw-journey-scratch`; `rw status` shows
   the endpoint closed.
8. Cleanup (after coordinator confirms): remove scratch clone locally
   and the worker-side ad hoc checkout.

Report: both `git status` comparisons (exact), placement path chosen on
mini, any refusal/divergence prompt text.

## [ ] Bucket 6 — Agent handoff (provider continuity)

In the same scratch repo (re-handoff is fine):

1. Start an agent in the pane — pick ONE of `pi` / `claude` / `codex`
   (all three adapters proven; pick what you actually use). Ask it
   something memorable ("remember the word 'pineapple'").
2. Keep the agent RUNNING (or exit — both paths exist; running-agent
   handoff is the interesting one). `rw handoff --worker mini`.
3. Expect: adapter detects the provider + session, exports it, installs
   it worker-side, and the remote pane offers/runs the resume command.
   Resumed agent RECALLS the conversation ("what word?" → pineapple).
4. `rw return` — expect continuity again on the way back: resume locally,
   agent still knows the word.
5. Edge to notice: a pane with NO agent degrades to workspace-only with
   a clear message, never an error.

Report: provider used, recall verified both directions, exact wording of
anything that felt ambiguous.

## [ ] Bucket 7 — Reflected slot + claims (real content-engine workflow)

The production shape. Pick a content-engine slot YOU currently own with
low-stakes uncommitted state (or none). Reflected to mini only.

1. In a pane cwd'd in `~/Developer/content-engine-trees/content-engine-<N>`:
   `worktree-claim status` — confirm you're the writer.
2. `rw handoff --worker mini`
3. Expect: placement=reflected (NO clone — mini's matching slot dir used
   as-is), sync transactional, claim marker travels
   (`worktree-claim handoff-writer` under the hood) — local side now
   shows writer=handed-off; mini side holds the claim.
4. Do a trivial real edit remotely; `rw return`.
5. Expect: writer role returns (`worktree-claim status` local = you),
   state back byte-identical, slot ports/tier untouched.
6. Known wrinkle: provider CLIs on workers write through stow symlinks
   and can dirty mini's DOTFILES tree, tripping clean-tree sync gates —
   if you hit a refusal naming a dirty tree, report exact message, don't
   force.

Report: placement mode line, claim status at each of the 4 checkpoints,
any refusal text.

## [ ] Bucket 8 — Second worker sweep (agents-roll)

Quick repeat of the basics on the Linux worker:

1. `rw ensure --worker agents-roll` from a non-git pane → shell on the
   VPS (root, tmux 3.4). `rw status` row correct.
2. One split (`prefix \`), one `prefix q` close.
3. `prefix Tab` → expect a clean "worker-side Treemux prerequisites
   missing (nvim >= 0.10)" style report, NOT a local sidebar.
4. Close everything; `rw status` empty.

Report: all four outcomes.

## [ ] Bucket 9 — LIVE PRODUCTION CANARIES (⚠️ gated — coordinator warns first)

DO NOT start this bucket ad hoc. It intentionally disrupts the live
laptop tmux server. Coordinator restates the warning, you give explicit
go, then serialized:

1. Real continuum autosave with live endpoints: leave 1-2 remote panes
   up ≥ ~6 min; verify a fresh `tmux_resurrect_*.txt` appears and
   records the remote panes with `@workspace-resurrect-skip` semantics.
2. Default-server-loss drill: kill the LIVE laptop tmux server, restart,
   restore. Expect: full session landscape back; remote-backed panes
   restored WITHOUT pasting stale ssh commands; reconciliation
   (`@resurrect-hook-post-restore-all` chain) reattaches desired
   endpoints / closes orphans; `rw-post-restore` re-stamps session UUIDs.
   THIS KILLS YOUR LIVE SESSIONS — that is the test.
3. Worker reboot recovery: reboot mini while an endpoint is attached;
   attach-loop backs off through the reboot; on boot the endpoint
   rebuilds (worker-server-loss path) and the pane comes back.
4. Optional: focus-Mac sleep/wake with endpoints attached.

Report each drill separately before starting the next.

---

## Completion log

| Bucket | Result | Notes |
|--------|--------|-------|
| 0 | PASS | doctor all clean, zero endpoints, zero orphans |
| 1 | FAIL→FIXED | restore hijack (53af514 guard); split rule + chips reworked; re-run as 1R |
| 1R | 4/6→FIXED | split rule, close, host/autosave chips PASS; dir chip made live-cwd (set-titles→pane_title); OSC 52 root cause = broken Ms override in tmux.conf, replaced with terminal-features clipboard; re-run as 1R2 |
| 1R2 | PASS | all steps PASS; bonus: existing-repo workspace materialization observed; new defect: remote nvim yank used worker pbcopy, fixed via SSH-guarded OSC 52 provider → 1R3 |
| 1R3 | — | |
| 2 | — | |
| 3 | — | |
| 4 | — | |
| 5 | — | |
| 6 | — | |
| 7 | — | |
| 8 | — | |
| 9 | — | |
