# Remote-owned directories: handing worktrees and folders to always-on workers

Status: built, reviewed and smoke-tested against the worker on 2026-11-18 (W0-W6 done; pane host switching planned and in build, section "Pane host switching"; the real UC-A/UC-B handoffs are the user's own next step, followed by the manual idol-app path fixes and Ghidra output copy, D16). Opened 2026-11-17 as an investigation; design P1 accepted 2026-11-18. Contracts and the per-wave change notes below are the binding interface description.

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
- Remote agent state (working, idle, awaiting) was left out of this plan as follow-up R1 and built afterwards by B2: rw mirrors the worker pane's `@agent_*` onto the laptop pane, so the picker reads remote agents like local ones (see "Changes recorded by B2").

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

### Changes recorded by V (editor reopen, 2026-11-18)

- C2 editor panes are no longer workspace-only. Handoff: a pane whose `pane_current_command` is `nvim`, `vim` or `vi` (and not the calling pane) gets its editor reopened in its new worker session, typed into the login shell after the session is created and verified like an agent resume (`rw_wait_remote_provider_started` with the editor pattern). Hand-back: an editor found in a remote endpoint pane (the probe's process tree, then the adapter) is captured before the panes are released and reopened in the laptop pane after its local shell is back (`rw_wait_local_provider_started`). Both directions are best effort: an unconfirmed or uncapturable editor is a warning naming the command, never a rollback; a hand-back endpoint with no laptop pane any more only warns.
- New `libexec/adapters/editor` (`export`, `install`; not a provider, never in the agent loops). The editor is the pane process or a direct child of it, never an `nvim --embed` server. With the `tmux_workspace_resurrect.lua` registration on the pane (`@workspace-nvim-owner-pid` = that editor or its embedded server), it asks for a fresh `:mksession` over `@workspace-nvim-server` (bounded at 3s) and carries `@workspace-nvim-session` minus the two `lua require('tmux_workspace_resurrect')` lines that embed buffer contents (unsaved text never travels); otherwise the `ps` argv, argv0 reduced to its basename, `-S <file>` dropped. Paths equal to or under the source root are rewritten to the destination root (escaped spelling in session files); `~/`-relative `cd` lines need no change.
- Reopen command: `cd <dest dir> && nvim -S <file>` or `cd <dest dir> && <argv>`. Session files: `<worker state>/editor-sessions/<endpoint_id>.vim` on handoff, `$(rw_state_dir)/editor-sessions/<endpoint_id>.vim` on hand-back, 0600 in a 0700 dir, files older than 7 days pruned at each write.
- C3 endpoint JSON gains `editor`: `null`, or `{reopen_intent: <command>}` when handoff reopened an editor.
- Tests: `tests/test_editor_reopen.sh`; the tmux stub answers the remote pane's other options from `$FAKE_REMOTE_PANE_OPTS` and flips a pane to `nvim` on a typed `&& nvim`/`&& vim` when `FAKE_LOCAL_RESUME_OK=1`.

### Changes recorded by B2 (R1 remote agent state, 2026-11-18)

- CX1 the laptop pane that attaches an endpoint carries the worker agent's state in the same options a local agent pane has: `@agent_kind`, `@agent_state`, `@agent_state_at`, `@agent_at`, `@agent_name`, `@agent_subs`, `@agent_empty` and `@agent_cwd` (the worker path mapped back: under the root to the laptop root, elsewhere under the worker home to the laptop home, anything else not mirrored). There is no `@agent_provider`; the provider is `@agent_kind`. `@agent_pid` is not mirrored, since a worker pid means nothing on the laptop: the worker loop checks the pid itself and reports a dead agent as no agent, and the first mirrored line unsets a stale local `@agent_pid` left by the agent stopped at handoff (the picker still tests any `@agent_pid` it finds, so stale pre-handoff options stay hidden until the mirror runs).
- Transport: `libexec/remote-state watch <endpoint_id> <pane_id>`, started in the background by `attach-loop.sh` just before each attach and stopped (SIGTERM, then `wait`) before the next attempt and on every exit (EXIT trap, and explicitly before the exec into a local shell). It shares the loop's process group, so closing the pane kills it too. It holds one long-lived ssh per endpoint, multiplexed on the alias's ControlMaster, never one per poll. The ssh runs a POSIX worker-side loop that polls the endpoint pane every 2 s (`RW_STATE_POLL_SECONDS`) with one local `tmux display-message -t '=<session>:'` and prints a line only when it changed, plus the unchanged line every 15 polls as a heartbeat, so a dead connection ends the worker loop at its next write. Line: `<alive>|kind␞state␞state_at␞at␞subs␞empty␞request␞cwd␞name` (U+241E, since tmux rewrites control characters; the name is last), `<alive>` 1, 0 (pid dead) or `-` (no pid); `gone` when the session or the worker server is absent. Polling, not a push: the publishers (`scripts/agent-state`, `agent-state.ts`) are the only writers of these options and tmux has no hook for a user option change; tmux-workspace-resurrect's hook fires only at SessionStart and writes a file. A control-mode client with `refresh-client -B` subscriptions was rejected because it counts as an attached client (worker `session_attached`, `reconcile-worker`'s attached-session skip, the client-detached save hook). Tree and tree-editor endpoints get no channel. Nothing is installed on the worker: the loop is sent inline over ssh.
- Writes: one tmux call per change, only while the pane's `@rw-endpoint` is still this endpoint. State and its stamp are written only when the worker's (state, state_at) pair changes, so a laptop-side transition (the focus hook's Done to Idle) is not undone by another field. A worker `working` to `idle` becomes `finished` when the laptop pane is not in view (the publishers' own visibility test, evaluated on the laptop pane with `if -F`); the worker cannot decide it, because its hidden session is attached and single-pane and so always reads as visible.
- Disconnect value: `@agent_state` = `disconnected`, with `@agent_state_at` set to the moment of loss. It is written when the stream ends on its own (ssh lost; the channel then retries with a 2-30 s backoff while its attach loop lives), when the worker reports `gone`, and at once when the attach loop's probe finds the worker unreachable (the channel is stopped first). It is never written on a pane with no mirrored agent, and a killed channel writes nothing. The picker renders it as its own state (`state.StateDisconnected`, a grey chip with Font Awesome chain-broken U+F127 from Hack Nerd Font, no row chip, counted as an agent); any other unknown value still reads as Idle. When the attach loop exits for any reason (including the respawn a hand-back does), it unsets every mirrored option; the agent resumed locally then publishes its own.
- CX2 the line carries the worker pane's `@rw-request`. When it changes to `handback`, the channel clears it on the worker (`tmux set-option -pqu` and `-qu` on `=<session>:`, one ssh over the ControlMaster) and only after that succeeded runs `tmux run-shell -b "rw bg handback --pane <laptop pane>"`. The command is chosen by whether `libexec/rw-bg` exists (`rw bg --help` exits 64, so it is no test); without it the fallback is `rw handback --pane <pane> --wait-idle 600`. A failed clear starts nothing, so the request is seen again on the next connection. Event `request-handback`.
- Laptop-side writers checked: tmux-workspace-resurrect writes no `@agent_*` (its hooks write `agents/server-*/pane-N.json` files and read `@rw-endpoint`), and the publishers run only inside agent processes, which a remote pane's attach loop is not. The only other writer on a remote pane is tmux-agent-sessions' `pane-focus-in[41]` Done-to-Idle hook, which is wanted. No guard in either plugin was needed. The status line has no agent chip (`wire-mem-chip` shows the pane's memory only), so nothing there changed.
- Picker: `buildPane` no longer returns before agent classification for remote panes and `paneState` no longer drops them, so a remote agent gets its chip next to the card's `remote` marker, counts in row chips and agents, and the Working guard (`refuseChange`, repurpose and delete) covers it. A `disconnected` agent does not block.
- Running attach loops keep the code they started with; a remote pane gets the mirror when its loop is next started (`rw open --pane <pane>` on it, a laptop restore, a new handoff). Nothing on the worker needs a reload or a dotfiles rerun.
- Tests: `tests/test_remote_state.sh` (worker loop under sh and zsh with a stub tmux; the mirror, cwd mapping, Done mapping, disconnect, request handling and the released-pane guard against a file-backed tmux stub; the channel process against a replaying fake ssh; start, replace and exit under the attach loop). Checked once on a throwaway tmux server (`-L rw-b2`, scratch `TMUX_TMPDIR`): the worker format, liveness, the separator in a name, the request clear on `=<session>:`, the chained writes and the `if -F` Done mapping.

### Changes recorded by B1 (background transfer, request channel, skill, 2026-11-18)

- CX3 `rw bg handoff [--worker <alias>] --pane <pane-id> [--wait-idle <seconds>]` and `rw bg handback --pane <pane-id> [--wait-idle <seconds>]` (`libexec/rw-bg`), built as pinned. Synchronous preflight: the pane exists on this server (else exit 1); it is not the worker side (its session is `rw-<8hex>-<8hex>` or its cwd is inside a worker-held copy: exit 7, hint `rw request handback`). Handoff: the root resolves as `rw handoff` without `--root` resolves it (exit 7 for outside `~`, `~` itself, already remote, overlap, a top-level plain folder, a plain folder holding a repository); `--worker` is declared (exit 64) and defaults to the only configured worker. Handback: the pane's root (`@rw-root-id`, then `@rw-endpoint`, then the enclosing remote root of its cwd) is worker-owned (exit 7) and its worker declared (exit 1). Either: no live per-root rw lock and no running bg transfer of the root (exit 1). Usage is exit 64. Then exit 0 and one line: `rw: handing off ~/x to <alias> in the background (log: <path>)` / `rw: handing ~/x back in the background (log: <path>)`.
- Detach: perl forks, the parent exits at once (the runner is reparented to init, out of the caller's process tree), the child calls `POSIX::setsid` (own session and process group, no terminal), takes stdin from `/dev/null`, appends stdout and stderr to the log, closes fds 3-255 and execs the runner (`rw-bg --run <job dir>`). Without perl: `nohup … &`. It keeps the caller's environment (state-dir overrides, `PATH`, `$TMUX`) and unsets `TMUX_PANE` for the transfer, so `rw handoff` does not refuse the agent's own pane. Checked on a throwaway server: the runner survived `respawn-pane -k` of the pane that launched it. `tmux display-popup -E` from outside a client blocks until the popup closes, and returns 0 without running anything while another popup is open on the client.
- Log `$(rw_state_dir)/logs/bg-<root_id>-<YYYYmmdd-HHMMSS>.log` (0600). Job and lock `$(rw_state_dir)/bg/<root_id>/`: `job.json` (`verb`, `root_id`, `root_rel`, `root_local`, `worker`, `pane`, `wait_idle`, `log`, `started`) and `pid` (the runner). A job whose runner is dead is reclaimed.
- Runner. Handoff: waits until no pane in the root (`rw_root_panes`) has `@agent_state` = `working`, bounded by `--wait-idle` (default 600 s), then runs `rw handoff --worker <alias> --root <root> --pane <pane>`. If that is refused because an agent started another turn, it waits again while time remains. Handback: runs `rw handback --root <root> --pane <pane> --wait-idle <remaining seconds>`, which waits for the remote agents itself. rw's exit codes stand (1, 2, 3, 5, 6, 7). Exit 5 opens the conflict dialog (`rw_conflict_dialog` in `libexec/rw-dialogs.sh`, moved there from the picker and shared with it) in a `display-popup` through `libexec/rw-bg-dialog`, and re-runs with `--resolve overwrite|keep-both`; abort ends with "`<verb>` of ~/x aborted; nothing moved". A popup tmux did not run (no client, or another popup open) is retried every 5 s for up to 10 min. Any other failure releases the lock and the chip first, then shows a `rw_dialog` with the cause, the action (`rw_failure_explain`, shared with the picker), the `rw:` error lines and the log path. Events: `bg-handoff` / `bg-handback` with outcome `start`, `success` or `fail`.
- Indicator: global options `@rw-transfer` = `handoff <root_rel>` / `handback <root_rel>` (several joined with `, `) and `@rw-transfer-label` = `handing off <basename>…` / `handing back <basename>…` / `<n> transfers…`. `rw-refresh-indicators.sh --transfers` sets or unsets them from the live jobs; the runner calls it at start and exit, and the plugin load runs it too. The chip `#{?@rw-transfer-label,…⇄ #{@rw-transfer-label}…,}` (catppuccin colours, the theme's status separators) is prepended to `status-right` when a transfer starts and renders empty without the label. `display-message`: start `handing off ~/x to <alias> in the background` / `handing ~/x back in the background`, success `~/x is now on <alias>` / `~/x is local again`, failure `rw <verb> of ~/x failed: <first rw: line>`.
- `prefix e`: after the worker choice (handoff) or the y/n (hand-back) the popup runs `rw bg …` and closes; a synchronous refusal is shown inline. The unsaved-buffer warning, the worker chooser and the confirmation stay in the popup. `rw open` still runs in the popup.
- CX2 `rw request handback` (`libexec/rw-request`), built as pinned. It needs `$TMUX_PANE` (else exit 64) and runs only where the pane's cwd is inside a worker-held copy: `rw_worker_copy_root_for_path`, a worker-owned mirror whose `focus_machine_id` is not this machine's id. Anywhere else it exits 7: on the focus machine's frozen copy with a hint to use `prefix e`, on a root held here with a hint to use `rw bg handoff`. It sets the pane option `@rw-request` = `handback` on `$TMUX_PANE`, prints `rw: hand-back of ~/<root_rel> requested; it runs once the agents here are idle.` and logs event `request`.
- `scripts/common.sh` gains `rw_worker_copy_root_for_path` and `rw_bg_dir`.
- Skill `agents/skills/remote-handoff/SKILL.md` (`disable-model-invocation: true`; `/remote-handoff to [worker]`, `/remote-handoff back`). claudef and pif already link `skills -> agents/skills`, so nothing else installs it. The agent tells the sides apart by its tmux session name (`rw-<8hex>-<8hex>` is the worker), runs `rw bg handoff --worker <alias> --pane "$TMUX_PANE"` or `rw request handback` as its last tool call, replies in one line and ends its turn.
- Tests: `tests/test_bg.sh`.

### Changes recorded by B3 (worker server start, non-blocking save trigger, 2026-11-18)

- C6 A tmux server on the worker is only ever started through the boot restore wrapper. Before, `rw_create_remote_session` ran a bare `tmux new-session -d` over ssh. With no server running, that started one from the worker's `tmux.conf`. Continuum's restore-on-start then ran the guarded restore into the server that already held rw's new session, the restore failed, and its `tmux-resurrect-<pid>-restore-incomplete` marker made the worker refuse every verified save from then on. This was observed on the real worker: a handoff landed on a server whose saves had been blocked for an hour.
- C6 The wrapper gains `--state` (prints `none`, `restoring`, `incomplete <marker>` or `ready`; no side effects) and `--start [<session> <dir>]`. `--start` runs the default restore and creates `<session>` before it drops the bootstrap session, so the server never exits in between. With no snapshot it still starts the server, waits for Continuum's empty attempt, and removes the marker that attempt leaves, since nothing exists to protect. Every default or `--start` run first deletes markers whose pid is not a live tmux process (`TMUX_RESURRECT_MARKER_DIRS` narrows the directories it searches; the tests set it).
- C2 `rw_create_remote_session` (used by handoff, open and the attach loop's rebuilds) and the new `rw_worker_ensure_server` run one worker-side program, `rw_worker_server_sh`, under `sh -c` over one ssh with keepalives. It reads `--state`. With no server it runs `--start` (an older wrapper without it falls back to a plain restore). It waits up to `RW_WORKER_START_TIMEOUT` seconds (default 120) on `restoring` and on exit 75, then creates the session. It refuses `incomplete <marker>`, a wrapper that left no server, and a missing or too-old wrapper when there is no server. Each refusal is one line in `RW_WORKER_SERVER_ERROR`. `rw handoff` runs `rw_worker_ensure_server` before any agent stops (exit 1, or 6 when unreachable, with "nothing was moved"). `rw open` reports the failure as `rw open: could not create the remote session for this pane: <reason>.` (exit 1). `remote_wrapper_sh` and `RW_BOOT_SESSION` moved from `attach-loop.sh` to `common.sh`.
- C2 `rw doctor` reads the wrapper's `--state` for each reachable worker. It fails on `incomplete` (naming the marker and the remedy) and lists markers of servers that have exited (`rw_worker_restore_report_sh`, read only). The headless doctor's existing `tmux:restore-complete` check already fails while the live server has a marker, so it is unchanged.
- C6 `rw_worker_request_save` is fire and forget at both ends. The worker side is `nohup sh -c '<trigger>' </dev/null >/dev/null 2>&1 &`, so its shell returns at once. This machine runs the ssh in a detached subshell, so no caller or pane holds it. The cause was measured on this laptop with a throwaway LaunchAgent (`StartInterval 300`, no `ThrottleInterval`): `launchctl kickstart` returns in 0.01 s the first time, and a second kickstart 1 s later blocks 9.03 s. The exit status (0 or 1) makes no difference. launchd's default throttle is one spawn per 10 s, and kickstart waits out the rest of that window. This is the 5.28 s measured in a split made seconds after a `prefix+q` close. `RW_WORKER_SAVE_TRIGGER` stays the test hook.
- Tests: `tests/test_worker_server.sh`. It covers a 5 s trigger with request_save, handoff, open and close all returning before it ends, and the remote shell returning first. It covers server start through the wrapper (a stateful fake worker tmux, fake guarded restore and Continuum; the guarded restore runs before the session exists, and the session is never the server's first) and the refusals for an incomplete or failed restore, including the handoff and open messages. It also covers no snapshot, old and missing wrappers, the stale-marker sweep and the doctor report. `lib.sh` gains `wait_for` and sets `TMUX_RESURRECT_MARKER_DIRS` to the sandbox. Also checked once on a throwaway server (`-L rw-b3`, `-f /dev/null`, scratch `TMUX_TMPDIR`): `--state`, `--start` with no snapshot, and `rw_worker_server_sh` against a live server and against no server.

## Pane host switching (plan, 2026-11-18)

Status: planned 2026-11-18, build delegated the same day (waves X1-X4 below). Extends the directory model above; nothing in P1 or C1-C8 is withdrawn unless a line below says so.

### User intent (verbatim)

2026-11-18, on `prefix e`:

> prefix+e takes a PANE's current focus directory and presents a menu for a FULL handoff (backward to local if remote owned dir/subdirectory of owned dir (no matter what remote command is fired from) OR if local owned dir handoffable to a selected remote) OR a simple switch of the pane (no handoff of directory) to the remote or back to local. If a remote owns a dir and prefix e is done from the local machine - the handoff option is to handback (since that is the only way a handoff can go) ( still providing the option for a soft handoff of just the pane's host (to same dir remember).

> This means that since we can switch back and forth easily like this that prefix + c (creating a new window) does so from the same REMOTE of the pane where the command was fired. SAME goes for split pane commands too

On the status line:

> If this is ever the case and a dir / sub dir of a remote owned dir is in focus (or a local owned dir is somehow focused in remote) ... I think that the host chip in the tmux status line should show a RED background instead of blue behind the host icon - make sense? that'll make it clear we are not on the right owner host of said directory system.

On restore and agents:

> Yes panes that are connected to remote shoudl restore as such on BOTH machines via our ressuraction workflows in a way that makes the most sense please.

> soft handoffs can move coding agent sessions `claudef` and `pif` between hosts without the full handoff.

On hosts:

> Why are we making it specific to "mini" here? It should be a system that handles any numebr of remote hosts we have managed within our tmux remote session management system??

### Terms

- Owner host of a path: the worker named in the worker-owned record whose root contains the path (`rw_owned_root_for_path`), else this machine (the laptop). Every path that has not been handed off is owned by this machine.
- Pane host: the worker a pane's attach loop runs on (`@remote-host`), else this machine.
- Full handoff: the existing root transfer (`rw bg handoff` / `rw bg handback`): files move, ownership changes, every pane in the root moves.
- Soft switch: only the focused pane changes host, in the same directory. No files move and ownership does not change. An agent or editor in the pane moves with it.
- Off-owner pane: a pane whose host is not the owner host of its directory. Every soft switch away from the owner produces one. The frozen-copy panes in D17 are the local case.

### Design

- S1 `prefix e` menu. The pane's directory is resolved first: a local pane uses `pane_current_path`; a remote pane uses its live worker cwd from `pane_title` when that is an absolute path (the directory chip's existing source), mapped back to this machine through the endpoint's worker root and `$HOME` mapping, else the endpoint's focus path. The root is the enclosing worker-owned root, else `rw_default_root_for_path`. One fzf menu, the same look as today's worker chooser, its header naming the directory, the root, the pane host and the owner host:
  - Soft switch rows first (enter picks the first row). The destinations are every host except the pane's own: this machine, and each configured worker. When the root is worker-owned, its owner is listed first.
  - Full-handoff row last. Worker-owned root: "hand back <root> to this machine" (the only direction a handoff can go, whatever pane it is pressed from, local or remote). Root owned by this machine: "hand off <root> to remote", then the worker chooser.
  - Choosing a row is the confirmation; the separate y/n for hand-back goes. Transfers stay background (`rw bg`).
  - The worker chooser is skipped when exactly one worker is configured.
- S2 New windows and splits follow the pane host. `prefix c` on a remote pane (owned or off-owner) opens a new window on the same worker in the pane's live directory; on a local pane, a local window as today. `prefix \` and `prefix /` already follow the pane (`rw-split.sh`) and must keep doing so for off-owner remote panes. The picker's new-window action (`prefix o`, then `w`) keeps following the owner.
- S3 Soft switch to a worker. Worker-owned root, destination is its owner: the existing `rw open` path (owned endpoint, listed in the record's `endpoints`). Any other case (a root this machine owns, or a worker that does not own it): a visit endpoint, the same hidden worker session and attach loop with no ownership record behind it. Its worker directory is the mapped path, or the nearest existing parent when the path does not exist there, with one printed line saying so.
- S4 Soft switch to this machine from a remote pane: the attach loop is replaced by a local shell in the same pane, window and layout, in the mapped local directory (nearest existing parent if missing). The worker session for that endpoint is closed and the endpoint unregistered (removed from the record's `endpoints` when it was owned). A foreground program that is not a shell, a supported agent or an editor is refused with a notice (quit it first).
- S5 Agents and editors move in a soft switch. `claudef` and `pif` agents move with the adapters' detect / export / install / resume, minus the directory sync: never two writers, never zero (the source agent stops only after the destination resume is confirmed). Refused when the directory does not exist on the destination (Claude finds its transcript by path). The menu row warns when the destination is off-owner ("the agent will work on a copy that does not own this directory"). Editors reopen through the editor adapter, best effort, unsaved buffers never travel (warned, as in the full handoff).
- S6 Red host chip. A pane option `@rw-off-owner` (`1` or unset) marks off-owner panes. The host chip's background reads it: Catppuccin red when set, the host's normal color otherwise. It is recomputed when a local shell changes directory (the zsh `chpwd` hook that already warns on frozen roots), when an endpoint attaches, after every handoff, hand-back and soft switch (for every pane in the root), and after restore (`rw-refresh-indicators.sh`). A remote pane's flag follows its endpoint's directory, not later `cd`s on the worker.
- S7 Resurrection on both machines. Laptop: visit endpoints reattach by endpoint id through `rw-post-restore.sh` exactly like owned ones; the sidecar treats them as captured. Worker: their hidden sessions are saved by the worker's save timer and restored by the boot restore like owned ones, with hidden-session options re-applied. Reconcile never closes a visit endpoint for lacking a record (D14 applies). After restore, `@rw-off-owner` is recomputed, never restored from the save.
- S8 Interplay with full transfers. A full handoff of root R to worker W adopts visit panes already on W inside R as owned panes (added to the record, no second session) and leaves visit panes on other workers as they are. A hand-back of R moves the record's endpoints as today; visit panes on other workers stay where they are and stay off-owner. Local panes in R move on handoff as today.
- S9 Any number of workers. Nothing is specific to one worker. UI strings say `remote` and `this machine` (C7); worker aliases appear only as chooser rows taken from `config.json`.

### Decision log (pane host switching)

- D19 `prefix e` is one menu with soft-switch rows and one full-transfer row; the full transfer's direction is decided by the owner, the soft switch's by the pane host.
- D20 Choosing the hand-back row is the confirmation; the y/n prompt is removed.
- D21 `prefix c` and splits follow the pane host; the picker's new window follows the owner.
- D22 Soft switch to a non-owner worker uses a visit endpoint with no ownership record.
- D23 Soft switch moves `claudef`/`pif` agents and editors without the directory sync; refused when the directory is missing on the destination.
- D24 Off-owner panes show a red host chip, from a recomputed pane flag.
- D25 Visit panes restore on both machines like owned panes.
- D26 The worker chooser is skipped with exactly one worker configured.
- 2026-11-18: the `agents-roll` worker was removed from `config.json` (the host no longer exists).

### Contracts (pane host switching)

- CS1 Command: `rw switch --pane <pane-id> --to <worker-alias|local> [--dir <abs-path>]`. Soft switch of one pane, synchronous (no sync channel, quick). `--dir` defaults to the pane's resolved directory (S1). Exit codes: 0 done; 6 destination worker unreachable; 7 refused (pane already on that host, unsupported foreground program, agent move with the directory missing on the destination), with one `rw: <reason>` line; 1 failure after which the pane is left as it was.
- CS2 Endpoint JSON gains `kind`: `owned` (default when absent, so existing endpoints read as owned) or `visit`. A visit endpoint carries `root_id`/`root_rel` of the enclosing root when there is one, and never appears in a record's `endpoints`.
- CS3 `@rw-off-owner` is set or unset only by `scripts/rw-refresh-indicators.sh`. New modes: `--pane <id>` and `--root <path>` (every pane in that root) recompute it; the existing no-argument run recomputes it for every pane. `rw handoff`, `rw handback`, `rw switch`, `rw open` and the attach loop call it best effort when they change a pane's host or a root's owner. The zsh `chpwd` hook calls `--pane "$TMUX_PANE"`.
- CS4 `prefix c` runs a script (`scripts/rw-new-window.sh`, owned by X1) in the shape of `rw-split.sh`: remote pane, new window on the same worker through `rw open` (owned) or a visit endpoint; local pane, `new-window -c "#{pane_current_path}"`.
- CS5 `scripts/rw-picker.sh` (owned by X2) calls only `rw switch`, `rw bg handoff` and `rw bg handback`. It never creates endpoints itself.
- CS6 Each wave records its interface changes under its own "Changes recorded by X<n>" heading below, in the same commit.

### Build order (pane host switching)

C8 testing rules apply to every wave, and the builder works in its own git worktree, never on the live checkout: the live tmux server runs these scripts straight from `~/.config/tmux`, so a half-built script there breaks the user's keys.

- X1 rw core (CS1, CS2, CS4, S2-S5, S7, S8): `scripts/rw`, new `scripts/rw-switch.sh`, new `scripts/rw-new-window.sh`, `scripts/rw-open.sh`, `scripts/rw-split.sh`, `scripts/common.sh`, `scripts/roots.sh`, `scripts/attach-loop.sh`, `scripts/rw-handoff.sh`, `scripts/rw-handback.sh`, `scripts/rw-post-restore.sh`, `scripts/rw-worker-post-restore.sh`, `libexec/*` as needed, `tmux/tmux.reset.conf` (`prefix c`, and the `prefix e` comment), tests. Done when: new tests cover switch in both directions (shell, claude, pi, editor, refused program), visit endpoint restore on both sides, handoff adopting a visit pane, `prefix c` following the pane; the full existing suite (`tests/run.sh`) passes.
- X2 menu and chip (S1, S6, S9, CS3, CS5): `scripts/rw-picker.sh`, `scripts/rw-refresh-indicators.sh`, `tmux-remote-workspaces.tmux`, `tmux/scripts/host_indicator.sh` if needed, the `chpwd` hook in `zsh/.zshrc`, tests. Done when: menu rows match S1 for each pane-host and owner combination (one and two workers), the chip format renders red for an off-owner pane on a throwaway server, and the existing suite passes.
- X3 independent review of X1 and X2 merged, by reviewers who read the code without the builders' conclusions; findings fixed.
- X4 smoke test against the configured worker after it is updated to the merged code (C8: throwaway laptop server, isolated state dir, everything created removed on both machines), then `docs/tmux-remote-workspaces.md` describes soft switching, the menu, the chip and `prefix c`.

### Changes recorded by X1 (2026-11-18)

Additive to CS1-CS6 unless stated.

- CS1 `rw switch [--pane <pane-id>] --to <alias|local> [--dir <abs-path>]` (`scripts/rw-switch.sh`). `--pane` defaults to `$TMUX_PANE`; `--dir` is a path on this machine. Exit codes beyond the pinned 0/1/6/7: 3 (the agent CLI version gate, as in handoff: toward a remote `versions --worker <dest>` must not exit 3; away from a remote, hand-back's inverted rule), 64 usage or an alias not in `config.json`. Exit 6 also covers a remote pane whose own remote is unreachable (nothing in it can move). Refusals (exit 7, one `rw: <reason>` line): already on that host, a remote file tree pane, a foreground program that is not a shell, editor or recognized agent (checked on the remote for a remote pane), an agent whose `@agent_state` is `working`, a remote agent with no SessionStart record, an agent whose directory is missing on the destination. Run inside the pane itself (`$TMUX_PANE` equals `--pane`, how splits and `prefix c` use it) nothing is moved and the pane execs into the attach loop. Event `switch` (`from=local|remote`, `to=`, `kind=`, `program=`).
- CS1 agent ordering. Toward a remote: endpoint and session created, transcript exported while the source agent still runs (it is idle), installed, resumed and confirmed there; only then the source agent stops, then the pane is respawned into the attach loop and a remote source endpoint is closed. A failure before the source stops discards the new endpoint (`rw_endpoint_discard`; exit 1, nothing at the source touched); a source agent that does not stop gets the destination copy stopped and discarded. Toward this machine: the pane is released to a local shell, the agent resumed and confirmed, then the remote agent stops and the endpoint closes; a failure stops the local copy and puts the pane back on its attach loop. Editors use the editor adapter with `--from-root`/`--to-root` set to the two machines' home directories (a soft switch has only the home mapping).
- CS2 endpoint JSON written by `rw open` and `rw switch`: `kind` (`owned`/`visit`), `worker_home`, and `root_id`/`root_rel` null when the directory has no root (outside `~`, or `~` itself). A visit endpoint's root is the enclosing worker-owned root, else `rw_default_root_for_path`; its `workspace.root_local`/`worker_root` are that root on both machines, else `$HOME` and the worker home (so the B2 cwd mapping works). Its pane gets `@rw-root-id` when it has a root. A path outside `~` maps to itself on the other machine.
- CS2 visit marker on the worker: `<worker state>/visits/<endpoint_id>.json` (`endpoint_id`, `session_name`, `focus_machine_id`, `worker_path`, `kind`, `created_at`), 0600 in a 0700 dir, written over ssh at creation (a failed write fails the switch, exit 1, endpoint closed). `rw_close_endpoint_core` removes it in the same ssh as the session kill (`rm -f`, harmless for owned endpoints), so every close path (rw close, reconcile, hand-back, switch) drops it; handoff adoption drops it too.
- S7 `rw-worker-post-restore.sh` keeps a restored `rw-*` session named by a visit marker whose `focus_machine_id` is not the worker's own, exactly like a session listed in a worker-owned mirror; hidden options are re-applied to every `rw-*` session as before. Laptop restore and `libexec/reconcile*` needed no change (they work from the endpoint registry, which lists visit endpoints); comments say so.
- S8 `rw handoff --worker W` adopts, at its commit, every pane whose endpoint is a visit on W with its focus path or pane cwd inside the root: `kind` becomes `owned`, the root fields and `worker_home` are written, the endpoint joins the record and mirror, the pane gets `@rw-root-id`, the marker goes; no session is created and the pane is not respawned. A mirrored `@agent_state` of `working` on such a pane refuses the handoff (exit 1) before anything stops. Visit panes on other workers are left as they are, and no longer draw the "already has remote endpoint" warning. Event detail gains `adopted=<n>`. `rw handback` needed no change for this (it only moves the record's endpoints, adopted ones included); it gained only the CS3 call.
- Shared helpers in `scripts/roots.sh` (X2 uses the first): `rw_pane_dir <pane-id> [--live]` is the S1 resolver (prints a path on this machine, which may not exist here). Without `--live` it reads the pane title; with `--live` it first asks the worker for the hidden session's `pane_current_path` (one ssh, status timeout) and falls back to the title, then the focus path. Finding (throwaway pair of servers, both `-f /dev/null`): the title lagged a `cd` on the worker by more than a minute; a hidden session has `status off`, and tmux appears to re-send titles only on a full redraw, so the directory chip, which reads the same title, likely lags the same way on the real worker (not checked there; X4 can). So rw switch, splits and `prefix c` use `--live`; the picker can show the title-based answer but should call `rw switch` without `--dir` so the switch resolves live. Also: `rw_endpoint_local_path <endpoint-json> <worker-path>`, `rw_endpoint_worker_home <endpoint-json>`, `rw_map_home_path <path> <from-home> <to-home>`, `rw_local_existing_dir <path>`, `rw_worker_existing_dir <worker> <path>` (6 when unreachable), `rw_endpoint_open <kind> ...` (session, registry, record or marker; shared by `rw open` and `rw switch`; sets `RW_ENDPOINT_ID`), `rw_endpoint_discard <id> <reason>`, `rw_bind_pane <pane> <id>`, `rw_visit_marker_push`/`rw_visit_marker_remove`. In `scripts/common.sh`: `rw_worker_state_sh` (the worker state dir as a word for the worker's shell) and `rw_refresh_indicators --pane <id> | --root <path>` (best effort; it does not run a refresh script whose text does not mention the mode, since the pre-X2 script ignores arguments and repairs every pane).
- `rw_worker_agent_probe` prints a sixth column, the endpoint pane's `pane_current_command`. `rw open` gains `--dir <abs-path>`.
- CS3 calls: `rw switch` runs `--pane` after it changed a pane (the exec path leaves it to the loop); the attach loop runs `--pane` once per loop start, in the background; `rw handoff` and `rw handback` run `--root <root_local>` after a success. `rw open` relies on the attach loop's call.
- CS4 `scripts/rw-new-window.sh [pane-id]`: remote pane (`@remote-host` set and an `@rw-endpoint`), `new-window -t <session_id>: -c <nearest local dir>` running `rw switch --to <its remote> --dir <live dir>; exec $SHELL -l`; local pane, `new-window -t <session_id>: -c <pane_current_path>`. Binding: `bind c if-shell -F '#{@remote-host}' 'run-shell "…/rw-new-window.sh #{pane_id} || true"' 'new-window -c "#{pane_current_path}"'` (a local pane never spawns the script). `rw-split.sh v|h [pane-id]` (the bindings now pass `#{pane_id}`) follows `@remote-host` for owned and visit panes alike and runs `rw switch --to <its remote> --dir <live dir>` in the new pane instead of `rw open`.
- Tests: `tests/test_switch.sh` (resolver; shell both directions, remote to remote, nearest-parent lines; owned endpoint to the owner and back; refusals and exit codes; claude and pi both directions with ordering and rollback; editor both directions; the exec path) and `tests/test_visit.sh` (`prefix c` and splits on a visit pane and a local pane, the binding; laptop restore match; worker post-restore keeping a visit session; both reconciles; handoff adoption and hand-back). `lib.sh`'s stub flips a pane to `pi` on a typed `pif` (was `claude`) and answers `display-message` on an `rw-*` session with `$FAKE_REMOTE_CWD`. Also run once on a throwaway pair of servers (laptop `-L rw-x1-l`, worker `-L rw-x1-w`, both `-f /dev/null`, scratch `TMUX_TMPDIR`, same-host fake ssh): switch to a remote and back, the title and `--live` resolution, `prefix c` and a split from the remote pane, pane id kept; and the `tmux.reset.conf` bindings as tmux parses them.

### Changes recorded by X2 (2026-11-18)

- S1 / CS5 `scripts/rw-picker.sh` is one fzf menu. Rows are `key<TAB>label<TAB>status<TAB>note`, shown from the label on (`--with-nth=2..`, `--no-sort`). Keys: `switch:local`, `switch:<alias>`, `handback`, `handoff`. Soft-switch order: the owner host first (when it is not the pane's own host), then this machine (when the pane is remote and a worker owns the root), then the other configured workers in `config.json` order; the owner's row says `(owner)`. The transfer row: `hand back <root> to this machine` (with `(N panes come back)` when more than one endpoint pane is bound) for a worker-owned root, from any pane; `hand off <root> to remote` (with `(N panes move)`, local panes only) for a root this machine owns, omitted when the root is outside `~` or `~` itself (the header says why) or no worker is configured. The hand-back y/n and the `rw open` y/n are gone; esc runs nothing. Header: line 1 `<dir>  ·  root <root>` (or `<dir> (root)`), line 2 `pane on <host>  ·  owned by <host>` with `<host>` = `this machine` or `remote (<alias>)` (the alias is the `config.json` one, so with several workers the header can say which; no machine host name appears), then an editor warning when the pane runs nvim/vim/vi (`… unsaved buffers do not travel: save first`) or, for a hand-off, when other panes in the root do.
- Agent warning (S5): a soft-switch row whose destination is not the owner carries `⚠ the agent will work on a copy that does not own this directory` in its note column when the pane has an agent: a remote pane with a mirrored `@agent_kind`, a local pane with `@agent_kind` and a live `@agent_pid`.
- Runs exactly `rw switch --pane <id> --to <alias|local> --dir <resolved dir>` (always passes `--dir`, so the menu and the switch agree on the directory), `rw bg handback --pane <id>`, `rw bg handoff --worker <alias> --pane <id>`, each with `TMUX_PANE` unset. `rw switch` exit 6: dialog "`<dest>` is unreachable over ssh; the pane is unchanged"; 7: inline notice "rw switch refused" with the `rw:` reason; any other non-zero: failure dialog with the last `rw:` line. The worker chooser (the existing `list`/`probe` look, typed alias passthrough) runs only for a hand-off with two or more workers (D26), with the pane's own worker listed first. `rw open` and the picker-side conflict dialog are no longer used by the picker (rw bg's runner keeps its conflict dialog).
- Reachability: the menu starts instantly and fzf's `start` reloads it with `reload-sync` from the new mode `probe-rows <rows file>` (parallel `rw_ssh_batch` probes, printed once all answered, same order), so worker rows go from `…` to `online`/`offline` without moving the cursor off the first row. New self-modes for tests: `rows <pane>`, `header <pane>`; `pick [pane]` takes an optional pane. Test seams `RW_PICKER_RW_BIN`, `RW_PICKER_FZF`.
- Pane directory (S1): `rw_pick_pane_dir` in `rw-picker.sh`: local `pane_current_path`; remote: `pane_title` when absolute, mapped through the endpoint's `workspace.worker_root` → `workspace.root_local`, else the worker home → `$HOME` (worker home from `workspace.worker_home` or `worker_home` when the endpoint carries one, else `worker_root` minus `/<root_rel>`), else `workspace.focus_path` (then `root_local`, then `pane_current_path`). To be reconciled with X1's shared resolver at merge.
- CS3 `scripts/rw-refresh-indicators.sh` modes `--pane <id>`, `--root <path>`; the no-argument run also computes `@rw-off-owner` for every pane (after recomputing `@remote-host` from the process tree). Unknown arguments exit 64. Off-owner: pane host (`@remote-host`, else this machine) differs from the owner host of the pane's directory, where a remote pane's directory is its endpoint's `workspace.focus_path` (then `root_local`), never its live cwd. Owner host: the longest enclosing worker-owned `root_local`; a record with `pending.action = forget` does not count, nor does a worker-held copy's mirror (`focus_machine_id` not this machine's), so on a worker its copies read as owned there. Records are read with one jq per run and none when there are no records; no ssh.
- zsh `chpwd` hook (`zsh/.zshrc`, `_rw_off_owner_refresh`): runs `rw-refresh-indicators.sh --pane "$TMUX_PANE"` detached (`&!`) after every cd and once at shell start, only inside tmux and only while an ownership record exists, plus one more call after the last record went (to clear a flag it set). `RW_REFRESH_INDICATORS` overrides the script path (tests).
- S6 chip: `tmux-remote-workspaces.tmux` wraps `@catppuccin_host_color` as `#{?@rw-off-owner,#f38ba8,<host_indicator colour>}` (fallback `#cba6f7`, the theme default, when unset), guarded against nesting. The pinned catppuccin-tmux (`e30336b`, `status/host.sh` → `build_status_module`) splices the colour verbatim into the separator's `fg` and the icon cell's `bg` inside `#[...]`, and tmux expands the conditional per redraw against the client's active pane; verified on a throwaway server with the real theme. `host_indicator.sh` is unchanged.
- Tests: `tests/test_picker_menu.sh` (rows for local/remote pane x laptop/worker-owned root x one/two workers, the off-owner remote pane, agent warnings, header, dispatch through stub fzf/rw, refusal and failure dialogs, chooser skip and order, probe-rows), `tests/test_off_owner.sh` (`--pane`/`--root`/all modes, pending forget, worker-held copy, the zsh hook extracted from `zsh/.zshrc` under `zsh -f`, and the chip on a throwaway server: `-L rw-x2-test-<pid>`, `-f /dev/null`, `TMUX_TMPDIR` under `/tmp` because the scratch path overflows the socket path limit, killed on exit).

### Changes recorded by fix wave B (2026-11-18)

Picker and off-owner fixes from the independent review of `rw-pane-switching` (d790236). Uses fix wave A's pinned interfaces I1-I4; nothing here changes them.

- Full-transfer row (finding 1): the picker now runs `rw bg handback --pane <id> --root <root>` and `rw bg handoff --worker <alias> --pane <id> --root <root>` (I1), `<root>` being exactly the root the label and header name. Before, `rw bg` re-resolved the root itself (`@rw-root-id` for hand-back, the pane's local `pane_current_path` for hand-off), so a remote pane that had cd'd into another root, or a visit pane that had cd'd elsewhere, moved a different root than the row said.
- Directory only the worker has (finding 1, choice recorded): when the pane's live directory does not exist on this machine and no worker-owned record encloses it, the root is taken from its nearest existing parent ONLY when that parent lies in a worker-owned record or a git repository (the record root or git toplevel, which encloses the directory); otherwise there is no root on this machine: header line 1 reads `<dir>  ·  no root on this machine`, a line says `<dir> exists only on remote (<alias>): nothing on this machine to hand off`, and no hand-off row is offered. The missing directory itself, or a bare existing parent such as `~/Developer`, is never named as a root. Resolving the root as the worker sees it (an ssh) was rejected: the menu must not wait on it, and the transfer is driven from this machine's tree.
- Remote pane probe (finding 2): a remote pane's directory and foreground command come from `rw_pane_remote_probe` (I3, hard deadline) instead of `rw_pane_dir --live` (bounded only by ConnectTimeout, up to ~60 s of blank popup). Exit 6: the directory is the title-based one (`rw_pane_dir` without `--live`), header line 2 reads `pane on remote (<alias>), remote unreachable  ·  owned by …` plus `the directory is the last one it reported; switching needs the remote, releasing does not`, no soft-switch row is offered (every `rw switch` from that pane needs its remote), and the first row is `release this pane to this machine (remote unreachable)` (key `release`), running `rw switch --pane <id> --to local --force` (I4) in the popup with the usual exit handling. A transfer row that needs the unreachable remote is left out too: a hand-back whose owner is that remote, a hand-off when no other worker is configured (with another worker the chooser does not list the pane's own remote first). A pane whose `@remote-host` is no longer in `config.json` is never probed and gets the same treatment with `remote not in config.json` / `release this pane to this machine (remote not in config.json)`.
- Owner (finding 3): the picker reads owner and root from `rw_owner_for_path` (I2), the chip's rules, so a pending forget and another machine's mirror no longer make the picker say `owned by remote` while the chip says otherwise.
- Remote editor (finding 4): `P_EDITOR` comes from the probe's `pane_current_command` for a remote pane, so a remote nvim/vim/vi gets the unsaved-buffers line.
- Hand-back count (finding 5): `(N panes come back)` counts panes whose `@rw-endpoint` is one of the record's `endpoints`; `@rw-root-id` alone (a visit pane on another worker carries it) no longer counts.
- Off-owner race (finding 6): every off-owner computation in `rw-refresh-indicators.sh` (`--pane`, `--root`, no argument) runs under one `rw_with_lock rw-indicators` (mkdir lock in `<state>/locks/`, the existing ~5 s stale guard) and reads the panes and the records only once it holds it, so the last run to take the lock reads the newest state and writes last. Uncontended cost: one mkdir and one rmdir per run. `--transfers` is unchanged.
- `pick <pane>` (finding 7): already honoured; every tmux call after it is targeted at that pane (now asserted). The untargeted `display-message -p '#{pane_id}'` remains only as the fallback when no pane is passed; the binding in `tmux.reset.conf` (not this wave's file) still calls `rw-picker.sh pick` without `#{pane_id}`.
- Test seam: `RW_PICKER_STUBS`, a file `rw-picker.sh` sources after `roots.sh`. `tests/test_picker_menu.sh` uses it for stand-ins of I2 and I3 with the pinned output (the I3 stand-in ssh-es through the sandbox's fake ssh and kills it at the status timeout), so the picker is tested against the contracts, not against wave A's implementation.
- Tests: `tests/test_picker_menu.sh` gains B1-B7 cases (dispatched `--root` equals the labelled root for a remote pane cd'd into another worker-owned root, live and title-only, and for a visit pane cd'd into another laptop root; worker-only directories in a git root, in a worker-owned root and with no root; unreachable owner pane, visit pane with one and two workers, a pane whose own remote hangs while the owner answers, a remote dropped from `config.json`; a hanging ssh (connects, never answers, 8 s) with a 1 s status timeout opens the menu within 3 s with `release` and no soft switch; pending forget and mirror owners; remote nvim; the hand-back count; no untargeted `display-message`). `tests/test_off_owner.sh` gains the lock cases (a run waits for a held lock, then computes from the state after a change made while it waited; a stale lock is passed after its guard and removed) and its throwaway server is now `-L rw-fb-offowner-<pid>`.

## Follow-ups (not in this plan)

- R1 Remote agent state in the picker: built by B2 (see "Changes recorded by B2").
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
