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
  zombie (no laptop endpoint). Killed manually. UPDATE 2026-08-04: the
  "save cycle drops zombies within ~5m" assumption is WRONG — the next
  save simply captured the zombie alongside the live session, so
  zombies persist across restores until manually killed (second
  occurrence killed 02:59). Proper fix: worker-side reconcile at ensure
  (kill `rw-<focus-id>-*` sessions absent from the laptop registry) —
  IMPLEMENTED 2026-08-04 as `libexec/reconcile-worker`, called from
  ensure-start (pre-create) and from attach-loop's worker-restore path.
  Guards: focus-machine namespace only, registry-membership is
  authoritative, min-age window vs the concurrent-ensure
  create-to-registry gap (ages computed in the worker's own clock),
  attached sessions never touched, unreachable = zero candidates,
  exact-match kills. Verified live on mini: swept one organic + one
  synthetic zombie, real sessions untouched, tombstones + events
  written. Known gap: zombies born from a FRESH-BOOT ensure's own
  restore are swept by the NEXT ensure, not the same one.
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

## [x] Bucket 1R3 — Remote nvim yank + worker picker + sessionx keys

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

### Bucket 1R3 findings (2026-08-04, partial)

- PASS: remote nvim yank → laptop clipboard. sessionx directions PASS.
- INFO (autosave chip showed 21m on reconnect): worker continuum saves
  are status-line driven, so they only tick while a client is ATTACHED.
  Detached/idle worker servers hold sessions live in memory but write
  no saves; the chip age therefore counts from the end of the last
  connection. Verified on mini: last-save gaps exactly track attach
  windows, and a fresh save landed ~1m after reattach (02:58). Risk is
  narrow: a worker crash while detached restores last-attach state.
  Matters more once detached remote agents mutate state (Bucket 6+);
  candidate fix = launchd/systemd timer driving periodic saves — open
  TODO, operator decision.
- Restore-zombie recurred (see 1R findings UPDATE): killed
  `rw-d157af95-29f40b78` exact-match 02:59; worker-side ensure-time
  reconcile implemented + live-verified same day (see 1R UPDATE).
  Organic verification available to the operator: any future ensure
  that sweeps prints `rw reconcile-worker: worker=<w> closed=N ids=…`
  in the pane before the remote prompt appears.
- PASS: reworked `prefix e` picker — focused-pane ensure, reachability
  column, ctrl-n/ctrl-p, both guards (remote-backed pane, non-shell
  pane), Esc abort, `prefix q` close. Operator: "completely fixed".
- FAIL → FIXED: remote nvim `p` hung "Waiting for OSC 52 response".
  tmux answers an OSC 52 READ only when it already holds a paste
  buffer; with none (nothing yanked remotely yet) it stays silent and
  nvim blocks. Fix: paste side of the ssh clipboard provider no longer
  queries the terminal — it returns nvim's own unnamed register, so
  `p` pastes anything yanked in that nvim and can never hang.
  Laptop→remote paste stays unsupported by design (OSC 52 reads stop
  at the first tmux; mirroring the laptop clipboard onto workers would
  leak every copy, secrets included). Sanctioned path for
  local→remote: Cmd-V terminal paste (bracketed, works in shell +
  nvim insert). Re-verified: `p` pastes remote registers instantly,
  no hang — PASS. Bucket complete.
- INFO (chip showed 520m on reconnect, 11:43): NOT a defect and NOT a
  durability gap. Closing the last endpoint ~03:03 emptied the worker
  server, so it exited; zero sessions existed all night — nothing to
  save, nothing at risk. RESOLVED the earlier "launchd timer TODO":
  the timer ALREADY EXISTS — misc-headless.sh installed a 5-min
  periodic-save net on both workers Aug 2 (launchd agent on mini,
  systemd --user timer on agents-roll, templates/tmux-resurrect-save.*).
  Verified live 2026-08-04: agents-roll timer active + firing; mini
  launchd job healthy (last exit 0, no log errors since Aug 2) and a
  save landed at 11:51:30 with the server fully DETACHED
  (attached=0). Detached background agents are therefore snapshotted
  within ≤5 min. Chip age = last save file age, so it counts up
  whenever the server is empty/absent — cosmetic only.

## [x] Bucket 2 — Drop resilience + idempotent ensure

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

### Bucket 2 findings (2026-08-04, partial)

- PASS: inner `tmux detach` → attach-loop reattached same session,
  history intact, no garbling.
- DEFECT FOUND (step 3): `rw status` showed TWO rows with one live
  pane. Endpoint 0783d52a's local pane %60 was killed hard while
  connected (only a `create` event ever logged — ssh never exited
  normally; some non-`prefix q` kill during the morning nvim-hang
  shuffle). NO cleanup path covers this class: attach-loop dies with
  the pane so it can't self-clean; laptop `reconcile` deliberately
  keeps every registry entry desired (soft pane-match failures must
  never gate remote deletion); worker sweep spares it because it IS
  registered. Orphan lingers forever. Cleaned manually via
  rw_close_endpoint_core (tombstone + exact-match kill + events);
  registry back to one row. Durable fix PROPOSED (pending operator
  go): ensure-time/doctor local-pane sweep — close endpoints whose
  recorded pane id is absent from the live local server, guarded by
  endpoint-generation vs server start time so post-crash stale pane
  ids are never swept before rw-post-restore re-stamps them.
  IMPLEMENTED same day as `libexec/reconcile-local` (approved): closes
  a registry endpoint only when no live pane carries its @rw-endpoint
  AND the binding provably belongs to the current server generation
  (created_at after server start_time, or a restore-reattach success
  event after it) AND min-age (120s) passed. Wired into every
  `rw ensure` (best-effort) + `rw doctor` dry-run preview. Verified
  with synthetic fixtures: current-gen orphan swept (tombstone +
  events, absent remote kill handled); pre-restart ambiguous endpoint
  and under-age endpoint both protected; live endpoint spared.
- Step 2 (Wi-Fi drop) SKIPPED by operator decision — documented in the
  plugin README "Field-validation status" as not-yet-field-validated,
  to be validated stochastically through daily use. Step 3 PASS (one
  endpoint, no reconnect duplicates; the second row was the orphan
  above, not a duplicate). Bucket closed.

## [x] Bucket 3 — Splits inherit remote; close semantics
### (2026-08-04: ALL PASS)

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

### Bucket 3 findings (2026-08-04)

- Splits + `prefix q`: PASS. Split minted its own endpoint (5003742d,
  two rows alongside f9b422bb); `prefix q` closed it cleanly
  (`remote=killed reason=prefix+q`, tombstone written, sibling row
  untouched).
- `prefix &` window close: PASS. 3de9fa04 created in own window, confirm
  prompt shown, `y` killed window AND endpoint
  (`remote=killed reason=window-close`, tombstone written).
- `rw close --pane %65 --no-kill-pane`: PASS. Endpoint f9b422bb closed
  (`remote=killed`, tombstone), attach-loop exited via pane-release
  (`reconnect ... outcome=closed exit=0`), pane survived as local shell.
- Operator UX friction (noted, not built): (1) `--pane` takes a tmux
  pane id (%65), operator naturally tried the endpoint id — an
  `--endpoint <id>` alias would help; (2) CLI close without `--reason`
  logs `reason=prefix+q` (the default), which is misleading in
  events.jsonl for non-keybinding closes.
- Operator challenged `prefix &` as YAGNI; kept — it intercepts tmux's
  STOCK kill-window (removing the bind reverts to a hard kill that leaks
  the Bucket-2 orphan class); teardown is shared with rw-close.sh.

## [x] Bucket 4 — Remote Treemux
### (2026-08-05: operator retest of tree-as-endpoint v2 — ALL PASS)

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

### Bucket 4 findings (2026-08-04, partial)

- DEFECT (operator): remote sidebar unusable in practice — it is a
  worker-side split, so the local server sees the remote rectangle as ONE
  pane: `prefix h/l` could not move focus between sidebar and shell,
  `prefix , .` could not resize it (stuck ~50% width), and `prefix q`
  tore down the ENTIRE endpoint when the intent was "close the sidebar".
- FIX: `rw-dispatch.sh` — nav/resize/close on an `@rw-endpoint` pane now
  forward the equivalent tmux command into the worker session over the
  multiplexed ssh channel (~50ms/keypress; ControlPersist already on).
  Nav at the worker window edge falls back to local `select-pane`
  (cursor crosses out of the remote rectangle); `q` closes the sidebar
  via its own Treemux toggle (registration torn down), a non-Treemux
  worker split via kill-pane, and only a LONE worker pane closes the
  endpoint; every failure path degrades to the exact pre-dispatch
  behavior. Plain local panes keep stock commands via if-shell.
- Considered + rejected: moving the sidebar to a local pane (fork of
  upstream toggle.sh pairing across two tmux servers, second unmanaged
  ssh channel, new orphan classes; logged as post-smoke candidate only
  if dispatch UX proves insufficient).
- Re-verify pending: operator to re-run steps 1–3 plus nav/resize/close
  exercises (config already reloaded live by coordinator).
- INCIDENT 2 (2026-08-05, lockout): first live use of rw-dispatch on an
  agents-roll pane errored `returned 1` on EVERY dispatched key — nav,
  resize, and q all dead, operator locked on the remote pane. Root
  cause: macOS bash 3.2's `$()` parser chokes on the unbalanced `)` of
  case patterns when a heredoc is attached inside the substitution — it
  ended the substitution early and executed the rest of the REMOTE
  script locally, dying on `set -u` BEFORE local_fallback could run
  (the safety net existed; the parser never let execution reach it).
  `bash -n` cannot catch this class. FIX: temp-file capture instead of
  `verdict="$(ssh …heredoc)"`, mirroring rw-treemux.sh (which is why
  treemux's ssh block never hit it) + standing rule in the script:
  heredoc-bearing ssh calls never go inside `$()` in this plugin.
  Verified end-to-end from run-shell (tmux server) context, ssh
  round-trip to agents-roll included; bindings re-armed live. During
  the outage the coordinator live-reverted all nine keys to stock to
  unblock the operator, then re-armed after the verified fix.
- REDESIGN (2026-08-05, operator-driven, supersedes the dispatch layer
  entirely): tree-as-endpoint. Operator proposed the architecture after
  INCIDENT 3: the Treemux tree runs in its OWN worker session shown in its
  OWN local pane, so no endpoint's worker window ever has >1 pane -- nav/
  resize/close revert to stock local tmux (rw-dispatch.sh + the
  @rw-sidebar-open hint DELETED, all 9 bindings back to stock; q goes
  straight to rw-close). New pieces: rw-treemux.sh v2 (Tab toggles a
  role=tree endpoint linked via tree_of; deploys nvim/rw-tree-init.lua to
  the worker), the shim (monkeypatches nvim_tree_remote.remote_nvim_open --
  the single funnel for all neo-tree/nvim-tree opens -- with the operator's
  3-case policy: live editor -> RPC; idle shell -> takeover, no split;
  busy/orphan -> request a local editor pane), rw-tree-listener.sh (polls
  the request file ~1s while tree open; mints role=tree-editor endpoints),
  rw-tree-pane.sh (pane bootstrap -> attach-loop). Orphaning is a FEATURE:
  closing the shell leaves the tree standing (operator requirement).
  Verified end-to-end on agents-roll scratch sessions (never the live
  landscape): tree opens+renders remote root; case-b takeover put Brewfile
  in the shell pane with window_panes=1; case-a RPC'd Makefile into the
  same editor; case-c (busy shell) minted editor endpoint via listener,
  split 70% above shell; case-d (orphaned tree) minted editor split right
  of tree; toggle-off/q/quit-nvim all close cleanly (registry+worker
  sessions verified empty after). Bugs found+fixed during verification:
  (1) plugin module __index errors on unknown keys -> rawget/rawset for
  the patch flag; (2) UPSTREAM takeover types `--listen` as its own
  send-keys argument which tmux 3.4 rejects -> shim types the command
  itself as one literal `-l --` chunk; (3) listener marker landed on the
  request's unterminated line -> own-line marker; (4) `tmux
  display-message -pt <dead-pane>` evaluates the format anyway (exit 0!)
  -> pane liveness must exact-match `list-panes -a` (ghost-pane takeover
  was eating case-d opens).
  FOLLOW-UP (2026-08-05, operator challenge "why isn't the listener
  respawned?"): closed -- attach-loop now re-ensures its tree's listener
  on every attach/reconnect, judged by the listener's own PIDFILE, never
  `pgrep -f` (a pgrep gate false-positived on ANY process whose argv
  mentioned the script name -- including the verifying shell itself --
  and silently suppressed the spawn; pidfile + write-then-reread
  handshake is immune and dedups concurrent spawns). Verified live:
  killed the listener, respawned the tree pane into attach-loop exactly
  as rw-post-restore does (which stamps @rw-* pane options first, its
  lines 212-220, so the restore path is covered end-to-end), listener
  returned via pidfile; the pidfile is trap-removed on listener exit.
  Remaining nit at the time: upstream watcher (tree auto-refresh) not
  spawned; closed 2026-08-05 via use_libuv_file_watcher (see PASS entry).
- INCIDENT 3 (2026-08-05, close-cycle + latency redesign): with the parse
  bug fixed, operator retested and hit two close bugs: (a) `q` on the
  NON-sidebar worker pane closed the sidebar; (b) `q` after the sidebar
  was gone REOPENED it — an uncloseable pane cycling open/close. Root
  cause: dispatch detected "sidebar" via treemux's `@-treemux-*` global
  options and closed through toggle.sh — but upstream NEVER unsets those
  options (liveness is checked via list-panes), so the editor pane
  matched forever and toggle re-created the sidebar once it was dead.
  Worker server wreckage confirmed it: 8 stale sidebar registrations
  (%6–%13) for one editor, one per lap of the loop (all cleaned; pane-id
  recycling makes stale entries a misdetection hazard). FIX: close no
  longer touches toggle.sh or option-sniffing at all — focused-pane
  semantics, `kill-pane` on the active worker pane, lone pane = endpoint
  close. ALSO: measured forwarding cost ~150ms/keypress (~45ms RTT to
  agents-roll; physics, not config) — validated operator's latency
  concern, so forwarding is now gated on local pane hint
  `@rw-sidebar-open` (set by rw-treemux.sh from post-toggle pane count,
  self-healed by dispatch whenever a verdict reports ≤1 worker pane).
  No sidebar → every key local, ~30ms, zero ssh. Verdict protocol now
  `<verdict> <pane-count>`. Verified: remote close/nav verdicts on a
  scratch worker session (forwarded 1 / endpoint 1 / edge 1), fast path
  29ms live, slow-path self-heal clears the hint. Treemux-fork
  alternative (local tree over remote FS) re-examined against upstream
  toggle.sh and re-rejected: tree nvim, editor pane, watcher broker, and
  FS are single-machine assumptions throughout; dispatch keeps upstream
  100% stock on the worker.
- INCIDENT (2026-08-05): coordinator instructed `prefix C-r` for config
  reload off reset.conf line 51 — but TPM loads after that file and
  tmux-resurrect's DEFAULT restore binding is ALSO `prefix C-r`, so the
  reload had been silently shadowed by a one-keystroke, no-confirmation
  landscape restore. Operator triggered it; restore was structurally a
  no-op (snapshot was minutes old, all 16 sessions pre-existed →
  resurrect skipped them) but blocked ALL tmux input while post-restore
  hooks (reconcile) waited out 8s ssh timeouts against the powered-off
  mini, twice. FIX: `@resurrect-restore` parked to `M-F11`; `prefix C-r`
  now genuinely reloads; restore is deliberate-only behind
  `prefix C-M-r` confirm prompt. LESSON: verify hotkeys against
  `tmux list-keys` (live truth), never against config files (load-order
  lies). Worker note: mini offline is fine — ensure-time sweeps only
  contact the TARGET worker (3s timeout); only `rw doctor` and
  post-restore reconcile ping all workers and will stall ~8s on mini.

- PASS (2026-08-05, operator retest, closes the bucket): full v2 journey
  on agents-roll — tree opens in own pane, stock h/l nav, `, .` resize,
  idle-shell open lands in shell pane, busy-shell open mints editor pane,
  `q` on shell orphans the tree (survives), open-from-orphan splits
  editor off the tree, Tab/q closes. Operator: "All of these performed
  correctly and to my satisfaction."
- FOLLOW-UP (2026-08-05, operator findings from the retest, both fixed):
  (1) tree refresh — coordinator's "neo-tree R" advice was right but
  useless in practice (refresh is silent; `r`=rename, `<C-r>` is OIL's
  refresh, not neo-tree's). Real fix: treemux_init.lua wrapper now
  injects `use_libuv_file_watcher = true` (inotify, worker-local, zero
  ssh — replaces upstream's unspawned watch_and_update.sh) plus an
  explicit `R = refresh` mapping. Verified live on agents-roll scratch
  tree: touched gamma.txt behind neo-tree's back, appeared in <3s with
  ZERO keypresses; R confirmed mapped in the tree buffer. Wrapper
  deployed to worker (~/.config/tmux/treemux_init.lua; local copy is a
  hardlink to the repo file). (2) `prefix e` picker slow to show
  reachability when a host is down (operator report, mini off): measured
  8s — `~/.ssh/mini-lan-available` runs at ssh CONFIG evaluation and
  mDNS resolution of the dead .local name blocks ~5s (nc -G/-w bound
  connect, NOT resolution), then +3s tailscale ConnectTimeout; and the
  probe printed nothing until ALL workers settled. Fixed both: watchdog
  bounds the LAN check to 1.5s (stderr-silenced so the shell's
  "Terminated" notice can't leak into ssh output), and rw-picker probe
  now streams each worker's line as its probe finishes — reachable
  workers render in ~a round trip (measured: agents-roll instant, mini
  offline row +4.3s later, was 8s for everything).

## [x] Bucket 5 — Workspace handoff / return (ad hoc, dirty state)
### (2026-08-05: PASS on agents-roll — dirty state byte-identical both ways)

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

### Bucket 5 findings (2026-08-05, worker = agents-roll, mini offline)

- PASS: handoff elevated the pane in place to the ad-hoc checkout
  (`/root/rw-workspaces/<machine-id>/github.com-kalem-edlin-dotfiles`,
  auto-cloned with the worker's own auth); operator's dirty state
  (staged Makefile / unstaged README / untracked file) survived handoff,
  a remote edit, and `rw return --pane %121` BYTE-IDENTICAL both
  directions, remote edit included. Events: return success generation=2,
  attach loop exited `returned`, pane back to plain local zsh with all
  @rw-* options cleared (coordinator-verified).
- OPERATOR TRAP (coordinator instruction defect, cost one round trip):
  bucket said "type `rw return`" — but a handed-off pane is a raw PTY
  into the worker (remote session prefix disabled), so the command ran
  ON THE WORKER via its own dotfiles install and failed with a
  misleading "pane %36 has no @rw-endpoint". By design return can NEVER
  be typed into the handed-off pane; correct form is
  `rw return --pane <id>` from any other local pane (pane id via
  `rw status`). Sonnet investigation confirmed zero cross-host guard in
  rw-return.sh → queued fix.
- DEFECT (found in coordinator verification): rw-return.sh rewrites the
  registry entry (direction=return, generation=2) but never
  deregisters — no tombstone, `rw status` shows a ghost endpoint after a
  successful return. Queued fix.
- COSMETIC: `invalid color specification: selected-bg:#45475a` on every
  interactive worker zsh — zsh/.zshrc:419 FZF_DEFAULT_OPTS uses a color
  key older apt-installed fzf (agents-roll) rejects. Queued fix
  (version gate).
- PROCESS CHANGE (operator directive, applies to all remaining buckets):
  operator does ONLY the experiential keystrokes; coordinator does all
  setup, verification, and cleanup. Buckets 6-9 rewritten accordingly.

## [ ] Bucket 6 — Agent handoff (provider continuity)

Worker: agents-roll (mini offline, packed away). Proves the new `prefix e`
intent-detection hotkey end-to-end — handoff THROUGH the hotkey, not
manual `rw handoff`/`rw return`. Reminder: `prefix e` on an agent/nvim
pane now means HANDOFF (picker → move, conversation transferred
transactionally); on a remote-backed pane it means confirm → `rw return`.

1. COORDINATOR: pre-stage a throwaway scratch repo, hand operator the path.
2. OPERATOR: focus a pane there, start an agent — your choice of
   `claude`/`codex`/`pi` — give it one trivial memorable task ("remember
   the word pineapple").
3. OPERATOR: `prefix e` → picker → pick `agents-roll`. Watch the
   conversation resume remotely.
4. OPERATOR: sanity-chat the resumed agent ("what word?") to confirm
   continuity.
5. OPERATOR: on the now-remote pane, `prefix e` → confirm the return
   prompt. Watch it land back local, agent resumed.
6. COORDINATOR: after each hop verify transcripts/adapters/events/registry;
   confirm the local agent was never stopped until the remote resume
   verifiably started (plugin-enforced ordering — a safety invariant, not
   a race to watch for). Spot-check the no-agent-pane case separately
   (degrades to workspace-only handoff, clear message, never an error) —
   doesn't need operator time.
7. COORDINATOR: clean up scratch repo, registry rows, worker-side checkout.

Expect: recall survives both hops; local session never torn down before
remote resume is confirmed up.

Report: provider used, recall PASS/FAIL both directions, anything about
the `prefix e` flow that felt ambiguous.

## [ ] Bucket 7 — Reflected slot + claims (real content-engine workflow)

Worker: agents-roll. Production shape — real content-engine slot, real
claim transfer, done via the `prefix e` hotkey (not manual `rw handoff`).

1. COORDINATOR: pick a content-engine slot operator currently owns with
   low-stakes/no uncommitted state; `worktree-claim status` to confirm
   writer, `worktree-claim verify-writer` before anything — STOP on exit
   10/11/13, never steal a claim. The slot dir itself stays READ-ONLY for
   coordinator throughout — no edits, no git ops there, only inspection.
2. OPERATOR: focus a pane cwd'd in that slot. `prefix e` → picker → pick
   `agents-roll`. Watch handoff.
3. COORDINATOR: verify placement=reflected (NO clone — agents-roll's
   matching slot dir used as-is), claim marker traveled
   (`worktree-claim handoff-writer` under the hood), local side shows
   writer=handed-off.
4. OPERATOR: make one trivial real edit remotely.
5. OPERATOR: on the remote-backed pane, `prefix e` → confirm → return.
6. COORDINATOR: verify writer role returned (`worktree-claim status`
   local = operator again), state back byte-identical, slot ports/tier
   untouched, local Supabase singleton untouched (never branched per
   worktree — cloud DB branching is the sanctioned path for schema work,
   not this bucket).
7. COORDINATOR: watch for the known stow-dirty-tree refusal (provider
   CLIs on workers can dirty the worker's own dotfiles tree through stow
   symlinks, tripping the clean-tree sync gate). If hit: report the exact
   message, do not force.

Report: how the hotkey flow felt (any friction), any refusal text hit.

## [ ] Bucket 8 — Mini sweep (deferred — blocked on mini power-on)

Old form OBSOLETE: the whole journey (Buckets 0-7) already ran on
agents-roll, so a redundant "second worker sweep — agents-roll" bucket
has nothing left to prove. Its old note that agents-roll was "missing
nvim" is STALE — nvim 0.12.4 confirmed installed there (Bucket 4).

BLOCKED: mini is powered off, packed away, expected back in days. Do not
start early — wait for coordinator to flag mini reachable.

When mini is back:

1. COORDINATOR: re-run the key flows against mini — `rw doctor`,
   `rw ensure --worker mini`, Treemux tree, agent handoff/return,
   `prefix e` picker reachability row for mini.
2. OPERATOR: spot-check a couple of experiential moments only — glance at
   the mini remote prompt after coordinator's ensure, glance at the tree
   after `prefix Tab`.
3. COORDINATOR: report results, close the bucket.

Report (once unblocked): coordinator flags readiness; operator's
spot-check impressions.

## [ ] Bucket 9 — LIVE PRODUCTION CANARIES (⚠️ gated — coordinator warns first)

DO NOT start this bucket ad hoc. It intentionally disrupts the live
laptop tmux server. Coordinator restates the warning below, operator
gives explicit go, THEN serialized — one drill at a time, report before
the next starts. Coordinator never touches live tmux directly (standing
rule); every live-server action below is OPERATOR's hands.

0. COORDINATOR: `brew upgrade tmux` to 3.7b — the running 3.6b binary is
   crash-prone (self-crashed once already, 2026-08-04). Doesn't touch the
   live server process; the new binary takes effect on next server start,
   so this rides along with drill 2.
1. Autosave drill:
   - OPERATOR: leave 1-2 real remote panes up ≥ ~6 min, otherwise idle.
   - COORDINATOR: verify a fresh `tmux_resurrect_*.txt` appears, records
     the remote panes with `@workspace-resurrect-skip` semantics.
2. Default-server-loss drill (THIS KILLS YOUR LIVE SESSIONS — that is the
   test):
   - OPERATOR: give explicit go, then kill the live laptop tmux server,
     restart, let it restore.
   - COORDINATOR: verify full session landscape back; remote-backed
     panes restored WITHOUT pasting stale ssh commands; reconciliation
     (`@resurrect-hook-post-restore-all` chain) reattached desired
     endpoints / closed orphans; `rw-post-restore` re-stamped session
     UUIDs; the server now running is 3.7b.
3. Worker reboot recovery — BLOCKED on mini power-on (see Bucket 8); when
   mini is back:
   - OPERATOR: have an endpoint attached to mini, watch it through the
     reboot.
   - COORDINATOR: trigger mini's reboot (ssh); verify attach-loop backed
     off through the reboot and rebuilt the endpoint on boot
     (worker-server-loss path), pane came back.
4. Optional — focus-Mac sleep/wake with endpoints attached:
   - OPERATOR: sleep/wake the laptop with an endpoint attached.
   - COORDINATOR: verify reconnect, no orphaned state.

Standing safety rules for every coordinator action in this bucket:
exact-match tmux kills only (`'=name'`), never `kill-server` on a
worker's default server, never touch the foreign session
`rw-fa1ce39c-74764279` on agents-roll, never touch Tailscale.

Report each drill separately before starting the next.

---

## Completion log

| Bucket | Result | Notes |
|--------|--------|-------|
| 0 | PASS | doctor all clean, zero endpoints, zero orphans |
| 1 | FAIL→FIXED | restore hijack (53af514 guard); split rule + chips reworked; re-run as 1R |
| 1R | 4/6→FIXED | split rule, close, host/autosave chips PASS; dir chip made live-cwd (set-titles→pane_title); OSC 52 root cause = broken Ms override in tmux.conf, replaced with terminal-features clipboard; re-run as 1R2 |
| 1R2 | PASS | all steps PASS; bonus: existing-repo workspace materialization observed; new defect: remote nvim yank used worker pbcopy, fixed via SSH-guarded OSC 52 provider → 1R3 |
| 1R3 | PASS | yank, paste (no-hang fix e7145f8), picker rework, sessionx keys all PASS; 520m chip + detached-save timer resolved (already installed Aug 2, live-verified) |
| 2 | PASS | detach-reattach + no-duplicate PASS; Wi-Fi drill skipped (README field-validation note); found+fixed local-pane-death orphan class (reconcile-local sweep) |
| 3 | PASS | splits mint own endpoints; prefix q, prefix & window-close, `rw close --no-kill-pane` all clean (tombstones + remote=killed verified); UX notes: want `--endpoint` alias, CLI default reason misleads |
| 4 | FAIL→REDESIGNED→PASS | dispatch v1 unusable (nav/resize/close + latency) → tree-as-endpoint v2 (operator design) → full retest PASS; follow-ups: libuv file watcher (auto-refresh), picker probe streams + mini LAN check bounded 1.5s |
| 5 | PASS | ad-hoc handoff/return byte-identical incl. remote edit; traps found: return must run `--pane` from another local pane (no cross-host guard), ghost registry entry after return, worker fzf color error — all queued as fixes |
| 6 | — | |
| 7 | — | |
| 8 | — | |
| 9 | — | |
