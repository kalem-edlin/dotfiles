# Remote-owned directories: handing worktrees and folders to always-on workers

Status: plan confirmed 2026-11-18, ready to implement. Nothing built yet. Opened 2026-11-17 as an investigation ("mini remote sessions"); the design below (P1, directory ownership) was accepted by the user on 2026-11-18 together with Q7, Q8 and Q4. Build order is in "Build order". Findings from two read-only investigation rounds are kept at the end as the evidence base.

Related system docs (current behaviour, not plans):

- `docs/tmux-remote-workspaces.md` (rw: pane handoff, endpoints, the 2026-09-20 "closed, not reattached" note this plan reverses)
- `docs/tmux-agent-sessions.md` (the picker behind `prefix o`)
- `docs/tasks/worktree-native-tmux.md` (worktree-native sessions; the uncommitted build this plan depends on)
- `docs/tasks/tmux-workspace-resurrection.md` (save/restore practices)
- `docs/headless-workers.md`, `docs/headless-vs-local.md` (worker provisioning)

## User intent (verbatim)

2026-11-17:

> The mac mini will become a CRITICAL part of my development workflow - and it is imporatnt that this system starts remembering tmux panes / windows / sessions on their remote mirror IF they were left there when I pick up and put down my laptop (this machine) - where ideally those remote agentic sessions, scripts, processes etc are ALL RUNNING since the mac mini never gets turned off.

> It needs to work with our branch / worktree tracking tmux session system AND the ressurection system too! (ie the resurection should apply by remembering the ssh host pane / window / session used, and restore it w/ a reconnect attempt to the pane AND the ressuraction must also work the same way on the remote side by understanding what is remotely provisioned for the main machine tmux setup and spinning it back up for the SSH connection on the local side to connect to where neceseary.

2026-11-18, on the design:

> OKAy i like this idea and I want to try it out: "the unit is a directory, and whoever holds the directory owns it"

> rsync copies should happen relative to the ~/ directory (so we dont need absolute usernames in the paths)...

> "mini" or aything relevant to "mini" is incorrect and should be just "remote" if it belogs to a remote right? mini is too specific to that one remote hsot (the main one for now yes - but not forever)

> Our tmux remote workspaces and picker will likely need to be able to clear whatever session / worktree is deleted on any connected / previously connected hosts too

> It needs to be clean such that I dont need to worry about it unless something actually becomes at risk due to conflicts. I want to be able to handoff back and forth without worrying about anything and seeing confirmations / actions to do when things are at risk.

Use cases that drive the build and the live trial:

- UC-A: `agentic-harness` window 3 "z" (pane %55 `pi` agent, %95 nvim), cwd `~/Developer/idol-app` (non-git, 613 MB, Ghidra reverse-engineering pipeline). Depends on `~/Developer/tools` (JDK 21, Ghidra 12.1.4, ipatool, 1.2 GB) and `~/Developer/rea` (REA checkout, 407 MB). Only that window moves; the rest of `agentic-harness` stays local.
- UC-B: the whole `scheduling-r1` session (4 windows, 3 claude agents, nvim), worktree `~/Developer/content-engine/scheduling-r1`, branch `docs/post-r1-builds-2026-11-16`. Needs `.env.local/.staging/.production`, `node_modules` (3.8 GB), expo prebuild output.

Workers: `mini` today (ssh alias, user `admin`, home `/Users/admin`, reached over Tailscale with ControlMaster). The design is worker-neutral; nothing in UI or code may say `mini`.

## Design (confirmed 2026-11-18)

### P1 The unit is a directory, and the holder owns it

- A handoff target is a directory root: the git toplevel of a worktree, or an explicit plain folder (`~/Developer/idol-app`). Roots never nest in practice: content-engine is a plain container with `main` and every worktree as siblings (`~/Developer/content-engine/<name>`, common git dir `main/.git`). If roots ever do nest, the nearest enclosing root owns a path, and a linked worktree is always its own root.
- Handing off a root moves every pane whose cwd is inside it (any depth, any session) to the worker. For a worktree session that is the whole session (UC-B). For a grab-bag session it is only the windows in that directory (UC-A).
- While a root is remote, the worker copy is the single source of truth. The laptop copy stays on disk but is frozen (D17): the picker opens new windows and panes for that root on the worker, `rw open` creates remote panes, and a zsh `chpwd` hook prints a one-line warning when a local shell enters a frozen root. No hard block on the filesystem.
- Hand-back moves every pane in the root back to the laptop and makes the laptop the owner again.
- Each laptop pane still attaches to its own hidden worker session (`prefix None`, `status off`), one window inside. There is no nested tmux UI. `prefix [` copy mode and `prefix \` `/` splits keep working as today.
- Ownership state lives in rw's registry on the laptop (`~/.local/state/tmux-remote-workspaces/owned/<root-cksum>.json`: root, worker, owner, since, manifest ids, endpoints[]), never inside the directory. The worker holds a mirror record under its own state dir so it can restore without the laptop.

Why the laptop copy is frozen rather than deleted (D17): a linked worktree's registration lives in the sibling main checkout's `.git/worktrees`, discovery and the picker row need the path to exist, hand-back is then a delta rather than a 4 GB re-transfer, and the copy stays readable while the worker is unreachable. The manifest check (below) catches any edit made to the frozen copy.

### Paths (D9)

- Every synced path is expressed relative to `~`. Worker path = worker `$HOME` + laptop path with the laptop `$HOME` stripped. Applies to any root under `~`, not only `~/Developer`. `~/rw-workspaces` placement is retired; `config.json` `workspace_root` goes away.
- Adapters and resume commands use the worker's physical path (`/Users/admin/...`). No `/Users/kalemedlin` symlink on the worker (Q8).
- Everything we write uses `~`/`$HOME`. Agent-written absolute paths found so far (`idol-app/scripts/work-native/run_batch*.sh:4-9`, `mcp_driver*.mjs:15`) are fixed by hand before UC-A moves.

### Sync and conflicts (Q4)

- Transfer channels: today's git channel (bundle of unpushed commits, staged and unstaged binary patches, untracked tar) plus a new rsync channel for everything the git channel ignores: gitignored files (`.env*`, `node_modules`, build output) and, for non-git roots, the whole tree. rsync runs over the existing ssh alias with Apple openrsync (both machines, protocol 29), relative paths, delete semantics, `COPYFILE_DISABLE=1`. First transfer of UC-B is ~4 GB; later transfers are deltas.
- A manifest (relative path, size, mtime, plus the git fingerprint for worktrees) is written on both sides at the moment ownership changes, stored in the ownership record.
- Owner wins. On hand-back, before the worker copy overwrites the laptop copy, the laptop copy is compared to its manifest. Unchanged: silent. Changed: one dialog listing the files, with overwrite, keep both (`<file>.local-<date>`), or abort. The same check runs on handoff against the worker copy. There are no other prompts.
- The git channel's divergence gate stays as is; the rsync channel adds the manifest gate. Deleted files propagate (rsync delete; the git channel also learns to remove untracked files absent on the owner).
- Worker unreachable: hand-back is refused with the reason. `rw reclaim --force <root>` re-takes ownership from the frozen copy and marks the worker copy stale; the next contact with that worker reconciles (closes its endpoints, keeps its copy for manual inspection).

### Keys and commands (D12)

- `prefix e` on a local pane: worker chooser, then hand off the pane's root (every pane in it). On a remote pane: hand the root back, behind a confirmation. One binding, direction decided by `@remote-host`.
- `rw handoff <root> --worker <alias>` and `rw handback <root>` are the CLI forms. `rw ensure` is renamed `rw open` ("open a new remote pane in a root that is already remote"); the picker and splits call it. `rw status` lists roots, owners and endpoints. `rw forget <root>` closes endpoints and removes the worker copy (used by delete, D11).
- Picker `w` (new window) and `enter` on a bare worktree row open remote when the root is remote. Picker delete (`C-a D`) and `wt rm` call `rw forget` for every worker that holds the root; unreachable workers get a pending record reconciled on next contact.

### Agents (D13)

- Worker-side resume uses `claudef --resume` and `pif --session`, never bare `claude`/`pi`, so hooks (agent state publisher, resurrect session record) run on the worker exactly as on the laptop. Codex stays as is.
- Transcript install uses the physical worker path for the Claude project slug and cwd rewrite. Pi gets its session header cwd rewritten too.
- CLI version gate (exit 3) stays; the mini update (W1) clears today's skew.

### Picker (D10)

- Marker word is `remote`, never a host name. Two placements, one fact: a worktree or session row whose root is remote shows `remote` on the row (even with zero panes, so a parked root is still visible); in a mixed session, each window card whose panes are in a remote root shows `remote`. Replaces today's "remote as the memory value" rendering.
- Source: the ownership records (one small JSON dir read, no spawn, inside the open budget) plus `@remote-host` on panes for the card case.
- Remote agent state (working, idle, awaiting) is out of this plan's scope. It needs a push transport from the worker; the picker side is a two-line change once state lands on the laptop pane. Recorded as follow-up R1.

### Resurrection, laptop side (D14)

- The sidecar records `rw_endpoint` per pane. `rw-post-restore.sh` reattaches by endpoint id (not by cwd, not by session uuid) and runs before the sidecar replay, which skips any pane with an endpoint. Handoff endpoints record session uuid, window and pane indices like `rw ensure` does today.
- A `session-renamed` hook keeps `sessions.jsonl` current so renamed worktree sessions still reattach.
- Rule: a worker session is killed only by explicit hand-back, `rw forget`, or `rw close`. Reconcile never closes a registered endpoint because a pane was not found; it logs and leaves it, and the picker row keeps showing `remote` with a reconnect action.
- Remote panes do not poison the laptop's verified save: handing off clears `@workspace-last-command` on the laptop pane and the sidecar treats endpoint panes as captured.

### Resurrection, worker side

- Boot-time restore: a LaunchAgent (`RunAtLoad true`, GUI domain, needs auto-login) starts the tmux server and runs the guarded `resurrect_restore.sh`, under the same lock the save uses. The attach loop's `no-server` path calls the same guarded script instead of upstream `restore.sh`, and waits on the lock, so two laptop panes cannot race.
- After any worker restore, rw re-applies the hidden-session options (`prefix None`, `status off`, etc.) to every `rw-*` session, and re-stamps the worker's mirror records.
- Worker-side agent capture works because resumes go through `claudef`/`pif` (D13); the worker's verified save is no longer rejected.
- Power (D15): headless setup runs `pmset -a sleep 0 autorestart 1 womp 1`; doctor checks auto-login user, FileVault off, and these values.

### Install and update (D1, D4, D8, D15, D16)

- `setup/rea.sh` + Makefile target `rea`, wired into `setup`, `setup/macos-headless.sh` and `setup/linux-headless.sh`: `mkdir -p ~/Developer`; clone `git@github.com:morluto/rea.git` to `~/Developer/rea` with submodules (idempotent fetch + `submodule update --init` on rerun); `npm ci` (required by idol-app's `mcp_driver*.mjs`, which spawn REA's server from the checkout); JDK 21 and Ghidra 12.1.4 as pinned sha256 archives into `~/Developer/tools/` following `setup/go.sh`. No `install.sh`, no global skills, no `.mcp.json` rendering.
- `zsh/.zshenv` exports `JAVA_HOME` and `GHIDRA_INSTALL_DIR` when the directories exist.
- `headless-doctor.sh` gains: `rea:checkout`, `rea:node-modules`, `tool:jdk`, `tool:ghidra`, `power:autologin`, `power:filevault`, `power:pmset`. New commands go in `REQUIRED_CMDS` plus `tool-parity-exceptions.txt`.
- Mini update (no `update` target exists; rerun is the contract): `git -C ~/Developer/dotfiles reset --hard origin/main` (discarding its dirty `nvim/lazy-lock.json`), `make setup-headless`, `make headless-doctor`.
- One-off job state (frozen Ghidra output) is copied by hand (D16).
- Found while building W1 (2026-11-18), folded into `setup/rea.sh`: (a) consumers spawn `node dist/main.js` and `dist/` is gitignored, so `npm ci` alone leaves REA unrunnable; the script also runs `npm run build` (tsc into the checkout, nothing global) after any `npm ci` or when `dist/main.js` is missing; doctor check `rea:build`. (b) Ghidra 12.1.4's public zip ships the decompiler native only for `linux_x86_64` and Windows; the laptop's `mac_arm_64/decompile` was built locally. The script builds it from the zip's sources (`make ghidra_opt` with `ARCH_TYPE` overridden) on macOS and Linux aarch64; `tool:ghidra` checks it. (c) Ghidra is a zip, so `unzip` joins `REQUIRED_CMDS` and the Linux required arrays. (d) Doctor check `env:jdk-ghidra` proves `.zshenv` and the pins agree.

## Decision log

- D1 Install REA via dotfiles, full and headless (refined by D8).
- D2 Gitignored files (`.env*` etc.) are copied. The hosts are the user's own machines.
- D3 Non-git folders are synced too.
- D4 Mini dotfiles and tools are updated through the Makefile targets.
- D5 Handoff unit is bigger than a pane (superseded by P1: the unit is a directory root).
- D6 No new `kalemedlin` account on the mini.
- D7 Commit the uncommitted worktree-native work by explicit pathspec so the mini can pull it.
- D8 REA: clone with submodules, `npm ci`, nothing else. JDK and Ghidra by dotfiles. `JAVA_HOME`/`GHIDRA_INSTALL_DIR` from `.zshenv`.
- D9 Paths relative to `~`; worker path = worker `$HOME` + relative path; `~/rw-workspaces` retired.
- D10 UI says `remote`, never a host name.
- D11 Deleting a session or worktree clears it on every worker that holds it, with pending records for unreachable workers.
- D12 `prefix e` both directions; hand-back confirms; `ensure` renamed `open`.
- D13 Worker agents resume via `claudef`/`pif`.
- D14 Laptop restore reattaches by endpoint id; worker sessions die only on explicit hand-back, forget, or close.
- D15 Headless setup fixes worker power settings; doctor checks auto-login, FileVault, pmset.
- D16 Frozen job dependencies are copied by hand, not by the handoff system.
- D17 The laptop copy of a remote root stays on disk, frozen; it is not deleted.
- D18 Ownership covers the whole tree under the root; any pane at any depth inside it belongs to the root.
- Q7 yes (P1), Q8 yes (no symlink), Q4 yes (manifest rule). Q1-Q3, Q5, Q6 folded into D9, D14, D10, D13, D15.
- Withdrawn 2026-11-17: nested-prefix question (already solved by hidden sessions). Verified: mini auto-logs in as `admin`, FileVault off, save job installed.

## Build order

Each step lists the files it touches and what proves it done. Steps W1 and W2 are independent of each other; W3-W5 depend on W2; W6 depends on everything. Commits by explicit pathspec (the tree carries unrelated sketchybar, nvim and obsidian changes).

### W0 Commit the base (D7)
- Commit the worktree-native picker build, `git/.local/bin/{wt,chat-move}`, tests, `docs/tasks/worktree-native-tmux.md`, `scripts/agent-state`, and this doc, by pathspec. Go tests pass against the shim harness (verified 2026-11-18).
- Done when: `git status` shows none of those paths, origin/main has them.

### W1 Worker provisioning
- `setup/rea.sh`, Makefile `rea` target and wiring, `zsh/.zshenv` exports, `setup/headless-doctor.sh` new checks, `setup/macos-headless.sh` power settings (`pmset`), `docs/headless-workers.md` update section.
- The hard-coded paths in `~/Developer/idol-app/scripts/work-native/{run_batch*.sh,mcp_driver*.mjs}` are fixed by hand after the user's own first handoff (user, 2026-11-18: the manual UC-A/UC-B steps happen after they have done the handoff themselves).
- Run on the laptop (`make rea`, `make headless-doctor` dry equivalent), then on the mini: reset to origin/main, `make setup-headless`, `make headless-doctor` green.
- Done when: the mini has `~/Developer/rea` with `node_modules`, JDK 21 and Ghidra under `~/Developer/tools`, pi and claude at laptop versions, `pmset -g` shows sleep 0 and autorestart 1, doctor passes.

### W2 rw core: ownership, directory handoff, sync
- `scripts/resolve-workspace.sh` (relative-to-home mapping, drop workspace_root), new ownership records, `scripts/rw-handoff.sh` (root-level: collect panes, one sync per root, per-pane endpoints with session uuid and indices, window grouping option), `scripts/rw-return.sh` becomes hand-back, `rw-ensure.sh` becomes `rw-open.sh`, `scripts/rw` subcommands (`handoff`, `handback`, `open`, `forget`, `reclaim`, `status`), `libexec/sync/handoff` (rsync channel, manifest, delete propagation, conflict report), `libexec/adapters/{claude,pi}` (claudef/pif, physical path, pi cwd rewrite), `libexec/reconcile*` (never close registered endpoints), `config.json`.
- Done when: rw's existing shell tests pass plus new ones for mapping, manifest diff, conflict dialog paths; a dry handoff of a throwaway non-git folder and a throwaway worktree round-trips with identical trees.

### W3 Keys and picker
- `tmux/tmux.reset.conf` (`prefix e` both directions), `scripts/rw-picker.sh` (chooser, hand-back confirmation, conflict dialog), picker: `tmuxio/snapshot.go` (ownership read, window remote field), `state/state.go`, `ui/format.go`, `ui/render.go` (row and card `remote` marker, memory no longer replaced), `ui/lifecycle.go` and `tmuxio/wt.go` (open-remote on remote roots, delete calls `rw forget`), `git/.local/bin/wt` (`rm` calls `rw forget`), fixtures and goldens, `docs/tmux-agent-sessions.md`.
- Done when: goldens show `remote` on a parked root row and on a mixed session's cards; Go tests and `tests/wt-test.sh` pass.

### W4 Resurrection, laptop
- `tmux-workspace-resurrect/scripts/{save.sh,restore.sh}`, `assemble_panes.py` (endpoint field, skip replay for endpoint panes, no capture error for them), `scripts/rw-post-restore.sh` (by id, hook order), new `session-renamed` hook in `tmux-remote-workspaces.tmux`, `rw-handoff.sh` clears `@workspace-last-command`.
- Done when: a drill on a throwaway server (never the live one) restores a handed-off pane back into its attach loop with zero worker sessions killed; `events.jsonl` gains `restore-reattach`.

### W5 Resurrection, worker
- `setup/templates/com.kalem.tmux-resurrect-restore.plist` (RunAtLoad), `setup/misc-headless.sh` install, `scripts/attach-loop.sh` (guarded restore, lock wait), a worker-side `rw-worker-post-restore` that re-applies hidden-session options and mirror records, doctor check `timer:restore-loaded`.
- Done when: rebooting the mini with a parked root brings its `rw-*` sessions back hidden, with the agent resumed, before any laptop connects; the laptop attach loop reconnects without a rebuild.

### W6 Review and smoke test (revised 2026-11-18)
- User instruction: "Just make sure it works with my SSH mini, cleans up after itself, and also don't do the handoff ... let me do the handoff step for the panes that I mentioned ... set up a couple of fake work trees and just fake directories, .env files, all that kind of shit, and just hand them off and see how it works. Make it quick."
- Review: independent reviewer agents per area (sync and ownership, picker and keys, laptop resurrection, worker resurrection, provisioning) read the code without the builders' conclusions; findings fixed before the smoke test.
- Smoke test, run by agents against the worker over ssh from a throwaway laptop tmux server (C8) with an isolated focus state dir: a fake plain folder and a fake worktree (fake origin, `.env.*` with fake values, a gitignored `node_modules`), handed off, opened, edited on the worker, handed back, conflict path exercised, `rw forget` on a deleted worktree, worker reboot drill for the boot restore. Everything created is removed on both machines.
- The real UC-A and UC-B handoffs are the user's. After they have done one, the manual steps follow (idol-app path fixes, copying frozen Ghidra output), per D16.
- Done when: every smoke step passes and `docs/tmux-remote-workspaces.md` is rewritten to describe the directory model (the 2026-09-20 "closed, not reattached" paragraph goes).

## Contracts (pinned 2026-11-18 before the build fanned out)

These are fixed so parallel builders compose without talking. A builder who needs to change one records the change here in the same commit.

### C1 Ownership records and paths

- `root_rel`: the root path relative to `$HOME` on the machine that holds it (`Developer/idol-app`, `Developer/content-engine/scheduling-r1`). Never starts with `/` or `~`. Roots outside `$HOME` are refused (exit 7).
- `root_id`: the first field of `printf '%s' "$root_rel" | cksum`. Identical on both machines.
- Focus path = `$HOME/$root_rel`; worker path = `<worker home from preflight>/$root_rel`. `config.json` `workspace_root` is removed; `~/rw-workspaces` is never written again.
- Record directory: `$(rw_state_dir)/owned/<root_id>/` holding `record.json`, `manifest.focus.tsv`, `manifest.worker.tsv`. The worker keeps a mirror with the same layout under its own state dir.
- `record.json` fields: `root_id`, `root_rel`, `root_local` (absolute path on the machine that wrote the record), `kind` (`git` or `plain`), `worker` (alias as known to the focus machine), `owner` (`focus` or `worker`; the same word on both machines), `since` (ISO 8601), `endpoints` (array of endpoint ids), `pending` (absent, or `{"action": "forget"|"reconcile", "reason": "...", "at": "..."}` when the worker was unreachable), `stale_worker` (absent or `true` after `rw reclaim --force`).
- A record exists only while a root is worker-owned or has a pending action. Hand-back with nothing pending deletes the record directory.
- Manifest rows: `<relpath>\t<size>\t<mtime-epoch>` for every file the rsync channel carries (for `git` roots: gitignored files; for `plain` roots: every file). A final row `#git\t<fingerprint>` for `git` roots. Written on both sides at every ownership change.
- Lookup helper in `scripts/common.sh`: `rw_owned_root_for_path <abs-path>` prints the `root_id` of the worker-owned record whose `root_local` is that path or an ancestor of it, else nothing (exit 1). Longest match wins.

### C2 `rw` command surface

- `rw handoff --worker <alias> [--root <path>] [--pane <pane-id>] [--check-lfs] [--force-diverged] [--resolve overwrite|keep-both|abort]`. Root defaults to the pane's git toplevel, or the pane cwd for a non-git directory. Moves every pane (any session) whose cwd is inside the root.
- `rw handback [--root <path>] [--pane <pane-id>] [--check-lfs] [--force-diverged] [--resolve overwrite|keep-both|abort]`. Replaces `rw return`, which is removed.
- `rw open --worker <alias> [--root <path>] [--pane <pane-id>]`. Replaces `rw ensure` (removed, no alias). New remote pane in a root the worker already owns; no sync. Every caller (`rw-split.sh`, picker Go code, docs) is updated.
- `rw forget <root> [--worker <alias>]`: close the root's endpoints, delete the worker copy and mirror record, delete the focus record. Unreachable worker: record gets `pending.action = forget`, exit 6, reconciled on next contact.
- `rw reclaim --force <root>`: focus becomes owner from the frozen copy; record keeps `stale_worker: true` until the worker is next reached (its endpoints are closed, its copy is left in place).
- `rw status [--json]`: roots with owner, worker, endpoints, pending. `--json` emits one array of the record objects.
- `rw close`, `rw doctor`, `rw-close-window.sh`, `rw-split.sh` keep their names.
- Exit codes: existing 2 (git divergence) and 3 (CLI version gate) stay. New: 5 manifest conflict (stdout carries one line per file `conflict\t<relpath>\t<changed|added|deleted>`), 6 worker unreachable, 7 root invalid or not owned as required.
- Conflict rule: owner wins. Before a copy is overwritten, it is compared to its stored manifest. No change: silent. Change: exit 5 unless `--resolve` is given. `keep-both` renames the losing file to `<file>.local-<YYYYMMDD-HHMMSS>` before the transfer.

### C3 Pane options and endpoint records

- Existing pane options stay: `@rw-endpoint`, `@rw-worker`, `@rw-workspace` (worker absolute path), `@rw-session-uuid`, `@remote-host`. New: `@rw-root-id`.
- Endpoint JSON gains `root_id`, `root_rel`, `focus_session_uuid`, `focus_session_name`, `focus_window_index`, `focus_pane_index`, written by handoff and open alike.
- Handoff clears `@workspace-last-command` on the laptop pane it replaces.

### C4 Environment overrides

- `TMUX_REMOTE_WORKSPACES_STATE_DIR` redirects the focus-side state dir only.
- `TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR` redirects the worker-side state dir (`rw_state_dir_at`); default `<worker home>/.local/state/tmux-remote-workspaces`. The same-host fake-ssh harness sets both; a real-worker smoke test sets only the first.
- `RW_SSH_BIN` stays as the ssh override.

### C5 Worker-side resume

- Claude: `claudef --resume <session-id>` from the worker path. Pi: `pif --session <path>` from the worker path. Both via the login shell so the aliases and fnm resolve. Codex unchanged.

### C6 Resurrection

- Sidecar per-pane field `rw_endpoint` (endpoint id, from `@rw-endpoint`). Panes with it are treated as captured, never replayed.
- `rw-post-restore.sh` reattaches each restored pane by endpoint id, matching on `focus_session_name` + window and pane indices, and runs before the sidecar replay.
- `scripts/common.sh` exposes `rw_apply_hidden_session_options <session-name>` (prefix None, prefix2 None, status off, mouse off, detach-on-destroy on), used by session creation and by the worker-side post-restore.
- Worker boot restore: LaunchAgent label `com.kalem.tmux-resurrect-restore`, template `setup/templates/com.kalem.tmux-resurrect-restore.plist`, wrapper `setup/templates/tmux-resurrect-restore.sh`, lock shared with the save wrapper. The attach loop's `no-server` path runs the same wrapper.
- Changed in the W5 fix wave (2026-11-18): the boot lock (`~/.local/state/tmux-workspace-resurrect/boot-restore.lock`, pid plus boot time) serializes every boot restore and blocks the verified save while live; the lifecycle lock and incomplete-restore marker are named from the tmux server's own TMPDIR. The worker post-restore writes `restored.json` (`restored_at`, `restored_endpoints`) beside each mirror `record.json` and never writes `record.json`; it is also chained into post-restore-all as `rw-worker-post-restore.sh --hook` (acts only where `rw-*` sessions exist). The attach loop's probe has a `restoring` state (bootstrap session, live boot lock, running guarded restore, or marker) in which it neither closes nor rebuilds, and it decides an intentional close only when the session vanished from the same worker server instance (start time and pid) it was last seen on, persisted in `$(rw_state_dir)/attach-seen/<endpoint_id>`. Wrapper exit 75 means the boot lock wait timed out: retry, never build.

### C7 Words and paths

- UI and log strings say `remote`, never a host name. Code and templates use `$HOME` or `~`, never `/Users/<name>`.

### C8 Testing rules for every agent

- Never run any tmux command against the default server. A throwaway server is allowed only with `TMUX_TMPDIR=<scratch dir>` exported and `-L rw-<name>` on every tmux invocation, with `TMUX` unset in that shell, and it is killed by name when done. Static checks first: `bash -n`, `shellcheck`, Go tests (the picker harness already isolates `TMUX_TMPDIR`), `tests/wt-test.sh`.
- The worker alias for live checks is `mini` (ssh only). Nothing created on it is left behind.
- Commits by explicit pathspec, no co-author line, no push (the orchestrator pushes).

### Changes recorded by W2 (2026-11-18)

Additive unless stated. Builders of W3-W6 read these as part of C1-C8.

- C1 `record.json` also carries `worker_root` (absolute worker path) and `focus_machine_id`. The worker mirror is written by the focus machine over ssh with `root_local` = the worker path; it survives hand-back with `owner: focus` (so the next handoff can gate the worker copy against `manifest.worker.tsv`) and is deleted only by `rw forget`.
- C1 new focus-side index `held/<worker>/<root_id>.json` (`worker`, `root_id`, `root_rel`, `worker_root`, `since`, optional `pending`): every worker copy this machine created. It outlives the record, so `rw forget` (and picker delete / `wt rm`) know which workers hold a copy after hand-back.
- C1 manifests never list `.DS_Store` or keep-both copies; symlink rows carry mtime `0` (rsync does not carry symlink times).
- C2 conflict rule: with no stored manifest for the copy being overwritten (first handoff onto an existing remote directory), the baseline is the incoming source, so only files that would be replaced (`changed`) or deleted (`added`) are listed. Keep-both copies (`<file>.local-YYYYMMDD-HHMMSS`) are never deleted by either channel, never listed in manifests, and excluded from the git fingerprint.
- C2 the git divergence baseline is the stored manifest's `#git` row; a destination that fingerprints `EMPTY` (absent or not a repository) never counts as diverged.
- C2 `rw open --worker` is optional (defaults to the record's worker; a mismatch is exit 7). `--workspace`, `--keep-local` and `--keep-remote` are gone with `ensure`/`return`.
- C2 a hand-back whose agent resume fails for a pane leaves that endpoint open and the record `owner: focus` with `pending.action = reconcile` (exit 1); the next contact with the worker closes it.
- C3 endpoints also carry `workspace.root_local`, `workspace.worker_root`, `workspace.mode` = the root kind, and for agents `agent.project_path_focus` / `agent.project_path_worker`.
- C5 adapters' `versions` exits 1 (setup remediation) when the worker cannot resolve `claudef`/`pif`; `resume-cmd` emits `cd <dest> && claudef ... --resume <id>` / `cd <dest> && pif --session <ref>` on both machines, typed into the pane's interactive login shell. `claudef` drops a captured `--dangerously-skip-permissions` (it always passes it).
- Preflight now requires `rsync` on the worker and reports `home` as the physical path (`pwd -P`).
- rsync flags are `-rlptD --delete` (`-a` without `-o`/`-g`, since the two machines run different users), verified against openrsync protocol 29 on both machines.

### Changes recorded by W4 (2026-11-18)

- C6 matching: the endpoint record's `focus_session_name` + indices is the primary key. The restored sidecar's `rw_endpoint` mapping overrides it when the two disagree (the sidecar describes the exact layout tmux-resurrect recreated; the record's indices date from the handoff) and is the fallback when the record has no position; a record without `focus_session_name` resolves its session from `sessions.jsonl` via `focus_session_uuid`. A pane that already carries the endpoint's `@rw-endpoint` is left attached whatever it runs. Otherwise only a bare shell is taken: shell command, no child processes (macOS `pane_current_command` is the process-group leader, so a foreground script or a live loop reads as `bash`), not started as an attach loop, no other `@rw-endpoint`; a shell busy only with children is re-checked for ~3s. Fix wave 2026-11-18: a record position the sidecar saved as a local pane after the endpoint's `created_at` is refused (`restore-reattach-missing`), so a stale record never takes a local pane and suppresses its replay.
- C6 sidecar: `rw_endpoint` is additive; the sidecar stays `version: 1` (the existing convention for additive fields). Endpoint panes are recorded with `selected_source: "remote-endpoint"`.
- C6 hook order: `rw-post-restore.sh` first, everything else (the sidecar replay) in its existing order, `libexec/reconcile` last, re-placed on every plugin load.
- New events: `restore-reattach` (success) and `restore-reattach-missing` (outcome `skipped` or `fail`, detail = reason).
- `session-renamed` updates `sessions.jsonl` and, in every endpoint of the session, `focus_session_name` plus the bound pane's `focus_window_index`/`focus_pane_index`. The hook passes only `#{q:session_id}`; the script reads the current name back from tmux (out-of-order double renames), and rewrites endpoint files atomically, under `rw_root_lock` when common.sh has it, only if unchanged since read.

### Changes recorded by the rw core fix wave (2026-11-18, review of fe61a15)

- C1 manifests of git roots list untracked (non-ignored) files as well as gitignored ones, so the conflict gate sees content edits to untracked files on the losing copy. A conflict whose destination file already equals the incoming source (or a deletion the source shares) is dropped: nothing would be lost, and a retried sync converges.
- C1 `record.json` (and the mirror) gains `worker_root_created` (true when rw created the worker directory at the first handoff). `rw forget` deletes a worker copy only when it is true; otherwise only the mirror goes.
- C2 handoff and hand-back are all or nothing: agents are stopped before the sync (handoff refuses an agent whose `@agent_state` is `working`), and any per-pane resume failure rolls every pane back. A failed hand-back keeps the root worker-owned with nothing pending (the W2 "pending reconcile after a failed resume" rule is withdrawn). Pending reconcile (after `rw reclaim`) never closes an endpoint whose agent state is `handed-off`.
- C2 `rw forget <root> [--worker <alias>] [--force]`: `--force` is required when the root is worker-owned; the picker and `wt rm` pass it after their own confirmation. The worker copy is deleted before endpoints are closed.
- C2 `rw reclaim [--force] <root>`: probes the worker and refuses when it is reachable; `--force` skips the probe.
- C2 `rw close --endpoint <id>` closes a registered endpoint no local pane carries.
- C2 handoff without `--root` refuses (exit 7) a plain root that is a top-level folder of `~` or that contains a git repository; roots with git submodules are refused (exit 1) by the sync core before anything is touched.
- C2 git divergence: with no baseline, an existing destination repository that differs from the source exits 2. An in-flight marker on the destination lets a retry after an interrupted sync continue. Plain roots get a pre-transfer backup of every replaced or deleted destination file; an owner copy with no files exits 1 unless `--resolve overwrite`.
- C2 per-root lock (`locks/root-<root_id>`, pid file, dead holder reclaimed) around handoff, handback, open, forget, reclaim and pending reconciliation; concurrent operations on one root exit 1.
- C3 agent endpoints record `agent.transcript_id` (pi: the transcript header id). pi export/install/resume-cmd address the exact `<timestamp>_<id>.jsonl`, never the newest file.
- C6 `libexec/reconcile` applies a min-age (`RW_RECONCILE_MIN_AGE_SECONDS`, default 120) and skips attached sessions, like `reconcile-worker`.

### Changes recorded by the rw smoke-test fix wave (2026-11-18)

- C5 agent detection reads only the current server's SessionStart record, `<state>/agents/server-<pid>-<start>/pane-N.json` (tmux-workspace-resurrect's `workspace_pane_state_file ... write` path), never the legacy flat `agents/pane-N.json`. The claude process pattern (adapters and `rw_provider_pattern`) also matches claudef's patched build `~/.cache/claudef/bin/<version>` and `~/.local/share/claude/versions/<version>`.
- C2 hand-back discovers agents live on the worker (process tree under each endpoint pane plus the worker's server-scoped records): an agent started after the handoff is exported and resumed locally; a running agent whose session cannot be identified refuses the hand-back (exit 1) before anything is stopped.
- C5 claude `install` marks the destination folder trusted in that machine's `~/.claude.json` (`projects[<path>].hasTrustDialogAccepted = true`, nothing else changed) -- the one write to that file.
- C6 `rw-worker-post-restore.sh` kills every restored `rw-*` session (named in the snapshot) whose endpoint no worker-owned mirror lists. Closing worker sessions requests a verified save on the worker (launchd `com.kalem.tmux-resurrect-save` kickstart, or the systemd unit) when sessions remain; `RW_WORKER_SAVE_TRIGGER` overrides the command (tests).
- C2 `forget` prunes `handoff-backups/root-<id>` and `handoff-staging/root-<id>` on both sides and removes worker parent directories it emptied (not a top-level folder of home); a failed delete is exit 1 with nothing closed. A successful hand-back keeps only the newest backup per side. Endpoint close removes `attach-seen/<endpoint>`.
- C2 the worker checkout gets the laptop branch's upstream (`branch.<b>.remote/.merge`, adding that remote with the laptop's URL). Preflight skips the git-host auth probe for local-path and `file://` remotes.
- C3 attach loops log `reconnect` / `attached` in events.jsonl at the moment they reattach.

### Changes recorded by the rw agent re-run fix wave (2026-11-18)

- C2 `rw handback [--wait-idle [seconds]]`: refused (exit 1) before anything is stopped while any remote endpoint pane runs an agent whose `@agent_state` is `working`; `--wait-idle` waits (default 300s) for it first.
- C2 hand-back writes the ownership record as `owner: focus` before the panes get their local shells (a rollback writes `worker` back), so the returned shells never see the root as remote.
- C5 every adapter installs transcripts 0600 (new directories 0700) on both machines.
- C6 rw requests a verified worker save after it creates sessions there too (handoff commit, `rw open`), not only after it closes them: the worker save refuses a capture during which the pane set changed ("incomplete pane logical-id coverage"), and this makes the next consistent save immediate.

## Follow-ups (not in this plan)

- R1 Remote agent state in the picker: needs a worker-to-laptop push of `@agent_*` (candidate: the attach loop's ssh ControlMaster carrying a tiny state stream into the laptop pane's options). The picker then drops the early return at `snapshot.go:415` and the Working guard covers remote agents.
- R2 Multiple laptops handing off the same root (ownership record per focus machine). Not needed while one laptop coordinates.
- R3 Linux workers (`agents-roll`): the same plan applies; `pmset` and auto-login checks are macOS-only.

## Findings (evidence, two investigation rounds, 2026-11-17 and 2026-11-18)

### F1 Pane-only handoff
Window or session = N independent handoffs, N worker sessions, N ssh attaches. Layout lives only on the laptop. `rw-split.sh:40-59` already creates a second pane as its own worker session in the same directory with no second sync; `rw-close-window.sh:22-32` already iterates every pane of a window. No window or directory grouping exists; the only pane options are `@rw-endpoint`, `@rw-worker`, `@rw-workspace`, `@rw-session-uuid`.

### F2 Non-git directories move nothing
`resolve-workspace.sh:82-84` resolves a non-git cwd to the worker `$HOME`; `rw-handoff.sh:322-325` only runs `mkdir -p`. UC-A would land the pi agent in `/Users/admin` with no files. Same-path placement is a prerequisite for syncing a plain folder.

### F3 Gitignored state never moves
`libexec/sync/handoff:262` uses `git ls-files --others --exclude-standard`; unchanged since the first commit, no recorded rationale. The fingerprint (`sync/common.sh:122`) also ignores them, so the divergence gate is blind to anything rsync adds. No rsync anywhere; transport is tar over ssh into staging. Worker apply never runs `git clean`. Both machines have Apple openrsync only.

### F4 Path identity
`/Users/kalemedlin` is hard-coded in idol-app `run_batch*.sh:4-9`, `mcp_driver*.mjs:15`, `STATE.md`, and REA's git-excluded `.mcp.json` / `.claude/settings.local.json` (`.git/info/exclude:7-8`, so a fresh clone lacks them). Only `resolve-workspace.sh:110-115` builds the worker path; every other script reads `workspace.remote_path` from the registry, so changing placement breaks nothing else. A root symlink alone would break Claude resume: Claude slugs its project from the physical cwd, so `/Users/kalemedlin/Developer/x` on the worker yields `-Users-admin-Developer-x` while the adapter installs under the typed path (`adapters/claude:256-289,341-343`). Pi is unaffected.

### F5 Mini is stale
Dotfiles 619f10e (Aug 8, predates the agent-sessions plugin entirely), dirty `nvim/lazy-lock.json`. pi 0.73.1 vs 0.85.1, claude 2.1.226 vs 2.1.326 (trips the version gate), no `~/.config/pif`. Java 1.8 x86_64 only, no Ghidra, no `~/Developer/tools`, no `rea`, no content-engine checkout. Node 24.18.1 (REA `.nvmrc` 24.18.0, engines allow it).

### F6 Laptop restore has never reattached
tmux-resurrect saves no `@` options and an empty `full_command` (`@resurrect-processes false`). The sidecar (`workspace-resurrect/scripts/save.sh:124-139`) records no rw field. `rw-post-restore.sh:104-108` skips endpoints without `focus_session_uuid`, which handoff never records (only `rw-ensure.sh:142-145,208`), then matches by exact `pane_current_path == focus_path`. `events.jsonl` has zero `restore-reattach` events; every restore since Oct 8 logs `reattached=0`. Hook order runs the sidecar replay first, and `@workspace-resurrect-skip` does not survive a server restart, so a former remote pane comes back as plain zsh with its pre-handoff `claudef` pasted. The "closed cleanly, accepted behavior" note (`docs/tmux-remote-workspaces.md:207-210`, 4602dad) was copied from the 2026-08-08 drill; under today's reconcile a registered endpoint lingers unbound and the worker session survives. Risk: an ex-agent pane's stale `@workspace-last-command` yields an `agent_capture_error` that rejects the laptop's verified save (`resurrect_save.sh:352-356`); 82 rejections in the launchd log, cause unconfirmed. No `session-renamed` hook exists.

### F7 Worker does not restore at boot
Save plist has `RunAtLoad false`; `tmux-resurrect-save.sh:115-117` exits when no server. Restore runs only from a laptop attach loop's `no-server` path (`attach-loop.sh:243-285`), using the unguarded upstream `restore.sh` for the whole snapshot with no lock. Resurrected `rw-*` sessions come back with a live prefix and status bar (options not saved; only `rw_create_remote_session` re-applies them). Adapters resume with bare `claude`/`pi` (`adapters/claude:341-343`, `adapters/pi:353-355`), so the agent-state publisher and `record-agent-session.sh` hook (wired only into `claudef`/`pif`) never run on the worker, and the worker's verified save is rejected.

### F8 Picker and remote
`remote` is rendered as the memory value in the row memory column (`ui/render.go:344-349`) and the window card's third line (`:132-134`); host name dropped at `snapshot.go:398`; `buildPane` returns before agent classification for remote panes (`:415`), so the Working guard (`ui/lifecycle.go:147-164`) ignores remote agents. `KillSession` already routes remote panes through `rw-close.sh` (`tmuxio/actions.go:201-245`); `wt rm` checks nothing. Rows are sessions or worktrees, cards are windows; a per-window attribute costs one format column in the single `list-panes -a -F` call. Agent state for remote panes needs a transport; the picker contract forbids ssh polling (`docs/tmux-agent-sessions.md:12-14,492`).

### F9 Install mechanics
No `update` target; rerun is the contract (`docs/headless-workers.md:42-46,211-237`). `setup/macos-headless.sh:69-76` sequence: brew-headless, python, neovim, node, obsidian, install-headless, misc-headless, headless-doctor. Precedents: pinned sha256 archives (`setup/go.sh`, `setup/lucide-font.sh`) and clone-plus-post-install (`setup/lib.sh:install_tmux_plugins`). `~/Developer` is created only by `setup/macos.sh:161`. Nothing references JDK, Ghidra or `JAVA_HOME`. `headless-doctor.sh` has no auto-login, FileVault or power check; new sections go after section 7 (lines 732-816). Worker registry is `tmux-remote-workspaces/config.json`; host details live in untracked `~/.ssh/config.local`.

### F10 Mini state (ssh probe 2026-11-17 23:04 CST)
No tmux server, no resurrect snapshots, uptime 10h28m (rebooted that day). `pmset`: `sleep 1` held off only by `displaysleep 0`; `autorestart 0`; `womp 1`. Auto-login `admin`, FileVault off, save LaunchAgent loaded. `~/rw-workspaces` holds an old dotfiles checkout and a `selftest` dir (orphaned once placement changes).

### F11 Uncommitted worktree-native work
42 modified files (+2422/-858) across the picker, `scripts/agent-state`, `docs/tmux-agent-sessions.md`; untracked `git/.local/bin/{wt,chat-move}`, `picker/{inspect,worktree,tmuxio/wt*.go,ui/lifecycle*.go,state/recency_test.go}`, `tests/*`, `agents/skills/new-worktree/`, `docs/tasks/worktree-native-tmux.md`, this file.

### F12 Ghidra batch 5
Finished 2026-11-18 00:00:32 CST (`DONE5:` in `idol-app/scripts/work-native/run5-status.txt`). No Ghidra processes remain. Ghidra projects were temporary per run.
