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

## [~] Bucket 1 — First remote pane + status anatomy + OSC 52 check

1. Open a fresh local pane in a NON-git directory (e.g. `cd ~`).
2. `rw ensure --worker mini`
3. Expect the pane to become a shell ON mini (verify: `hostname`,
   `echo $TMUX` shows mini's own server socket, `tmux display-message -p
   '#S'` shows a session named `rw-<short-id>-<endpoint-id>`).
4. From a DIFFERENT local pane: `rw status` — expect exactly one row:
   worker=mini, mode=plain, path=mini's `$HOME`, bound pane id matches,
   liveness OK, last event `create`/`attach`.
5. OSC 52 clipboard check (the blocked human item): inside the remote
   pane, select/copy text via tmux copy-mode (or `printf` + your normal
   copy binding), then paste on the LAPTOP (Cmd-V in another app).
   Expect: remote-copied text lands in the laptop clipboard through the
   nested tmux layers.

Report: hostname/session name seen, status row, and PASS/FAIL on the
clipboard paste (this closes the OSC 52 item).

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
| 1 | — | |
| 2 | — | |
| 3 | — | |
| 4 | — | |
| 5 | — | |
| 6 | — | |
| 7 | — | |
| 8 | — | |
| 9 | — | |
