# Tmux remote workspaces

Tmux Remote Workspaces keeps the laptop tmux server as the only visible
coordination layer and lets a directory, with every pane working inside it,
continue on an always-on worker. The unit of handoff is a directory root: the
git toplevel of a worktree, or a plain folder. Whoever holds a root owns it.
While a root is remote, the worker copy is the single source of truth and each
of its laptop panes attaches to its own durable tmux session on the worker.
Remote execution is opt-in. This document records the current system and the
decisions needed to maintain it. It is not an implementation plan or backlog;
the plan that produced the directory model is `docs/tasks/mini-remote-sessions.md`.

The colocated plugin README at
[`tmux/local-plugins/tmux-remote-workspaces/README.md`](../tmux/local-plugins/tmux-remote-workspaces/README.md)
is the command and operational reference.

## System rules

### Local first

New shells, windows, and agents start locally. `prefix e` on a local pane, or
`rw handoff --worker <alias>`, hands the pane's root to a worker: every pane
on the laptop server whose cwd is the root or inside it moves, in any session
and at any depth. The rest of a mixed session stays local. `prefix e` on a
remote pane hands the root back, behind a confirmation. `prefix e` runs both
directions as background transfers (`rw bg`), so its popup closes as soon as
the choice is made. A split follows the
pane from which it was requested: a split of a remote pane opens remote in
the same root, a split of a local pane stays local.

New windows and panes for a root that is already remote open on the worker:
the picker's new-window and bare-worktree actions call `rw open` when the
root is remote, and splits of a remote pane do the same.

The outer laptop tmux owns the visible layout. Each remote-backed pane attaches
over SSH to a single-pane, hidden worker tmux session (`prefix None`,
`status off`). There is no nested tmux UI. This keeps navigation, resizing,
and pane selection local and immediate.

### Consume, never provision

The plugin uses only resources already installed on a worker. It never installs
tmux, Git, Git LFS, rsync, Neovim, provider CLIs, credentials, or SSH keys.
`scripts/preflight.sh` reports missing requirements and points back to
`make setup-headless`. Worker authentication remains machine-local.

### Intent is separate from connectivity

An endpoint registry entry means the user intends the endpoint to exist. A
live `attach-loop.sh` process means the local pane is currently executing
through that endpoint. The tmux options mirror this distinction:

- `@rw-endpoint`, `@rw-worker`, `@rw-workspace`, and `@rw-root-id` cache
  endpoint intent.
- `@remote-host` and `@workspace-resurrect-skip` are set only while an attach
  loop owns the pane process tree.

This prevents a failed or racing handoff from labeling a still-local agent as
remote. `rw-refresh-indicators.sh` repairs the execution caches after a config
reload by inspecting the live process tree.

### Intentional close is different from a disconnect

`attach-loop.sh` retries network loss, SSH loss, worker restarts, and detached
sessions with capped exponential backoff. It exits when the registry entry is
gone or a close tombstone exists.

`rw close` writes the tombstone first, then tears down the worker endpoint, then
closes or releases the local pane. The order prevents an older tmux snapshot
from reviving an endpoint the user deliberately closed. `prefix q` and
`prefix &` use this lifecycle-aware path. Closing a pane does not change who
owns its root.

A worker session dies only through an explicit hand-back, `rw forget`, or
`rw close`. No component deletes an endpoint or a copy merely because it is
old or because its local pane could not be found.

## Workspaces after slots and claims

The September 2026 simplification removed the entire persistent worktree slot
and worktree claim system. Current behavior has no numbered slots, preparation
tiers, global port allocator, reflected repositories, `.worktree-claim`
markers, writer leases, or `worktree-slot` and `worktree-claim` commands.

A handoff target is a directory root under `~`. Without `--root`, the root is
the pane's git toplevel, or the pane's directory when it is not in a git
worktree. A root is refused (exit 7) when it lies outside `~`, is `~` itself,
is a subdirectory of a git worktree (hand off the worktree instead), or
overlaps a root that is already remote. Each root has a `root_rel`, its path
relative to `~`, and a `root_id`, the first field of `cksum` over `root_rel`,
which is identical on both machines.

Every synced path is expressed relative to `~`. The worker copy of a root
lives at the same relative path under the worker's home:

```text
laptop:  ~/<root_rel>              e.g. ~/Developer/content-engine/scheduling-r1
worker:  <worker home>/<root_rel>
```

The worker home is the physical path preflight reports, so the two machines
never need the same user name. Adapters and resume commands use that physical
worker path. Two physical worktrees of the same repository are two roots and
map to two worker copies. A plain folder is a root like any other, and its
whole tree travels. `~/rw-workspaces` is no longer written.

The remote-workspace layer does not create, name, own, recycle, or remove local
Git worktrees. Git and the repository's own practices own that lifecycle.
Ownership records say which machine currently holds a root's working copy.
They are not worktree claims and are never stored inside the directory.

Removing claims did not remove transfer safety. Every transfer compares the
copy about to be overwritten with its stored manifest, checks the git
fingerprint for divergence, backs up a git destination, stages the git
transfer, verifies the result, and refuses a conflict or divergence unless
explicitly resolved. The provider handoff also guards against a duplicate
managed resume of the same agent session. These checks protect a specific
transfer. They are not a global worktree ownership system.

## Endpoint and state model

`rw handoff` creates one endpoint per pane in the root it moves. `rw open`
creates one endpoint for a single new pane in a root the worker already owns,
with no sync. Each endpoint follows this sequence:

1. Resolve the root and its ownership record and preflight the worker over
   SSH. Handoff refuses a root that is already remote. Open refuses a root
   that is not remote, and its `--worker` defaults to the record's worker.
2. Map the pane's cwd onto the worker: the worker home plus the path relative
   to `~`. A cwd outside the root maps to the worker root.
3. Create the hidden session `rw-<focus-short-id>-<endpoint-id>` in that
   directory on the worker tmux server.
4. Write the endpoint registry entry and add its id to the ownership record.
5. Stamp the pane's intent caches.
6. Replace the pane process with `attach-loop.sh`.
7. Let the attach loop stamp execution caches and attach to the worker session.

`rw open` on a pane that already carries a registered endpoint reattaches that
endpoint instead of creating a second one. Endpoint records carry `root_id`,
`root_rel`, the laptop session uuid and name, window and pane indices, the
laptop and worker paths, and, for agents, the provider, session id and both
project paths.

The dashed endpoint name is deliberate. Tmux treats `.` as target syntax and
rewrites dotted session names, so the earlier dotted design could not
round-trip reliably.

The default state root is
`~/.local/state/tmux-remote-workspaces/`:

```text
machine-id                           stable focus-machine UUID
sessions.jsonl                       session UUID to tmux session name, latest record wins
endpoints/<id>.json                  authoritative live endpoint records
tombstones/<id>.json                 close intent written before teardown
owned/<root_id>/record.json          ownership record: root, kind, worker, owner, since, endpoints, pending
owned/<root_id>/manifest.focus.tsv   manifest of the laptop copy at the last ownership change
owned/<root_id>/manifest.worker.tsv  manifest of the worker copy at the last ownership change
held/<worker>/<root_id>.json         every worker copy this machine created, kept after hand-back
handoff-backups/, handoff-staging/   git-channel backups and staging on the side being written
events.jsonl                         append-only lifecycle and transfer observations
locks/                               mkdir locks around check-then-act operations
rw.log                               diagnostic log
```

A focus record exists only while a root is worker-owned or has a pending
action. The worker keeps a mirror of each record and both manifests under its
own state root, written by the laptop over SSH with `root_local` set to the
worker path. The mirror survives hand-back with `owner: focus`, so the next
handoff can check the worker copy against its manifest, and it is deleted only
by `rw forget`. The `held/` index outlives the record so `rw forget` knows
which workers still hold a copy.

Tmux pane and session options are caches. JSON and JSONL state is authoritative
because tmux options do not survive a server restart and window indices are
renumbered.

A worker is one logical SSH alias declared in `config.json`. OpenSSH chooses
the route, a verified LAN path when available and Tailscale otherwise.
Ownership records, the `held/` index and endpoint records are keyed by that
alias, so a diagnostic route alias must never become a second worker entry.
UI and log strings say `remote`, never a host name.

## Handoff and hand-back

`rw handoff --worker <alias>` moves the root and its panes in this order.
Nothing is replaced until every check that can refuse has run:

1. Resolve the root (exit 7) and preflight the worker (exit 6 when
   unreachable). Run any pending action recorded for that worker.
2. Per pane: detect a supported agent, refuse a busy pane that is neither a
   shell, an editor, nor a recognized agent session, and check the provider
   version policy. One version block (exit 3) aborts the whole handoff.
3. Sync the root once: git channel plus rsync channel, divergence gate
   (exit 2) and manifest gate (exit 5). Then write the ownership record with
   `owner: worker`, both manifests, the `held/` entry and the worker mirror.
4. Per pane: create the worker session, export and install the agent's
   session, resume it there, confirm its process, and stop the local agent
   only after the remote resume is confirmed. Then write the endpoint and
   replace the pane with its attach loop.

An editor pane (nvim, vim, vi) is not left as a bare remote shell: its
editor is reopened in the worker pane, from the Neovim session that
`tmux_workspace_resurrect.lua` registers (refreshed over its RPC socket, so
buffers, windows and tabs come back), or else from the editor's own argv,
with paths inside the root rewritten to the worker root. Unsaved buffer
contents never travel (the picker warns first), and an editor that cannot
be confirmed only prints the command to run, it never fails the handoff.

A pane whose agent resume cannot be verified keeps its local agent running and
stays local, so there are never two writers and never zero. The root still
moves, and the command reports the pane. A handoff clears
`@workspace-last-command` on each laptop pane it replaces.

While a root is remote, the laptop copy stays on disk, frozen. It is not
deleted, because a linked worktree's registration lives in its main
checkout's `.git/worktrees`, discovery needs the path, hand-back is then a
delta, and the copy stays readable while the worker is unreachable. Nothing
blocks the filesystem. Any edit made to the frozen copy is caught by the
manifest gate on hand-back. The zsh `chpwd` hook prints one line when a
local shell enters a frozen root, naming the worker alias and `rw handback`;
`rw-picker.sh` offers `rw open` when `prefix e` is pressed in a local pane
that already sits inside a remote root.

`rw handback` brings the root and all of its panes back. It runs on the laptop
from a local pane or popup and refuses to run inside the worker side of a
remote pane. It finds the record from `--root`, the pane's `@rw-root-id` or
`@rw-endpoint`, or the cwd's enclosing remote root, then:

1. Preflights the worker. An unreachable worker refuses the hand-back with
   exit 6 and nothing changes.
2. Applies the version policy inverted: a local CLI older than the worker one
   that wrote the session exits 3 before anything moves.
3. Pulls the root once, with the frozen laptop copy checked against the
   manifest stored at handoff.
4. Per pane: replaces the attach loop with a local shell in the same pane,
   window and layout, then resumes the agent locally. The worker agent is
   stopped only after the local one is confirmed. An editor running in a
   remote pane is reopened in its laptop pane the same way, best effort.
   Remote tree and editor endpoints are closed.
5. Only after every pane is back: closes the worker sessions, makes the
   laptop the owner, deletes the record when nothing is pending, and rewrites
   the worker mirror with fresh manifests.

An agent that fails to resume locally leaves its endpoint open and the record
`owner: focus` with a pending reconcile (exit 1). The next contact with that
worker closes it. If no agent is detected, both commands move the workspace
only.

Background transfers. `rw bg handoff --worker <alias> --pane <pane>` and
`rw bg handback --pane <pane>` run the same two commands without holding
the caller. A synchronous check (the pane exists, its root resolves, the
worker is known or the root is remote, this is not the worker side, no
other transfer of the root runs) exits 0 at once, and a runner detached
with `setsid` (own session and process group, output to
`logs/bg-<root_id>-<YYYYmmdd-HHMMSS>.log` under the state root) does the
rest. It outlives its caller, the calling agent's turn and the respawn of
the pane it came from. A handoff first waits, up to `--wait-idle` seconds
(600 by default), until no pane in the root has `@agent_state` `working`;
a hand-back passes the remaining time to `rw handback --wait-idle`, which
waits for the remote agents. While a transfer is in flight the global
options `@rw-transfer` (`handoff <root_rel>`, several joined with `, `) and
`@rw-transfer-label` are set, and a chip prepended to `status-right` shows
the label ("⇄ handing off idol-app…") until they are cleared.
`display-message` reports the start and the end. Exit 5 opens the same
conflict dialog the popup uses, in a `display-popup`, and re-runs with the
chosen `--resolve`; any other failure opens a dismissible dialog with the
error lines and the log path. `bg/<root_id>/` in the state root is the
one-transfer-per-root lock.

`rw request handback` is the way back from the worker side. Run in an
endpoint pane on the worker, it sets the pane option `@rw-request` to
`handback` there; the laptop's attach loop for that pane clears it and
runs `rw bg handback --pane <its laptop pane>`. It refuses where the root
is held on the machine it runs on, and `rw bg handoff` refuses on a
worker-held copy. The `/remote-handoff` agent skill
(`agents/skills/remote-handoff/SKILL.md`) uses the two, so an agent can
move its own directory and continue the conversation on the other side.

Transfer uses two channels over the existing SSH alias:

- The git channel moves unpushed commits, staged and unstaged changes,
  renames, deletions, untracked files, and referenced Git LFS objects without
  an administrative commit and push. Untracked files the owner no longer has
  are deleted on the other side.
- The rsync channel moves everything the git channel ignores: the gitignored
  set of a git root (`.env*`, `node_modules`, build output) or the whole tree
  of a plain root. It runs Apple openrsync with `-rlptD --delete` and
  `COPYFILE_DISABLE=1`, so the first transfer of a large root is full and
  later ones are deltas.

The sync engine uses one code path for local fixtures and SSH destinations.
The git channel is staged and backed up. The rsync channel writes into the
live destination, and re-running the same command converges after an
interruption.

Conflicts follow one rule: the owner wins. A manifest (relative path, size,
mtime, plus the git fingerprint for git roots) is written for both copies at
every ownership change. Before a copy is overwritten it is compared with its
stored manifest. No change proceeds silently. A change exits 5 and lists one
`conflict<TAB>path<TAB>changed|added|deleted` line per file unless
`--resolve overwrite|keep-both|abort` is given. `keep-both` renames the losing
file to `<file>.local-<YYYYMMDD-HHMMSS>` first, and those copies are never
deleted, synced or listed. The first handoff onto an existing worker directory
uses the incoming copy as the baseline, so only files that would be replaced
or deleted are listed. The git divergence gate uses the manifest's `#git` row
as its baseline and is overridden only by `--force-diverged`.

An unreachable worker never blocks forever. `rw reclaim --force <root>` makes
the laptop the owner again from its frozen copy, releases every bound pane to
a local shell, and marks the worker copy stale. Work done on the worker since
the handoff is not brought back. The next contact with that worker closes its
endpoints and keeps its copy for manual inspection. `rw forget <root>` closes
the root's endpoints and deletes every worker copy this machine handed off,
but only where that worker's mirror record names the same root. An
unreachable worker gets a pending forget (exit 6). Handoff, hand-back, open
and forget run pending actions for a worker whenever it answers.

Deleting a session or worktree from the picker (`C-a D`) or with `wt rm` calls
`rw forget` for every worker that holds the root, after confirming when the
root is currently remote. The picker shows the word `remote` on a worktree or
session row whose root is remote, even with zero panes, and on each window
card in a mixed session whose panes are in a remote root. It reads the
ownership records directly and never polls over SSH.

Provider adapters for Pi, Claude, and Codex own transcript discovery, version
checks, export, install, resume commands, and process matching. They do not own
tmux or workspace transfer. Resumes go through `claudef --resume` and
`pif --session` on both machines, typed into the endpoint's login shell, so
the same hooks run on the worker as on the laptop. Codex is unchanged.
Transcripts are installed under the worker's physical path, which is what
Claude slugs its project directory from.

## Remote Treemux and input

`prefix Tab` preserves ordinary Treemux on a local pane. On a remote shell it
creates a separate tree endpoint, displayed as another local pane but running
Neovim on the worker. Worker endpoint sessions remain single-pane.

Opening a file follows the current worker-side policy:

1. Reuse a known live editor Neovim socket.
2. Take over the associated shell endpoint when it is idle.
3. Ask the focus-side tree listener to create an editor endpoint.

A tree may outlive its original shell. The listener then creates an editor
beside the tree. `attach-loop.sh` re-establishes the listener while the tree
endpoint exists.

Remote copy-mode entry is sent once to the worker tmux server. Subsequent vi
motions travel through the existing SSH PTY. OSC 52 passthrough returns yanks
to the focus machine. Local paste remains useful because it types the local
tmux buffer into the remote program.

## Persistence and reconciliation

The focus machine and workers use `tmux-workspace-resurrect`, tmux-resurrect,
and tmux-continuum. The companion workspace sidecar stores shell input, Neovim
sessions, Treemux relationships, and agent session identifiers that plain
tmux-resurrect does not know about.

Continuum's save trigger is a status-line interpolation. A detached worker has
no rendering client, so it cannot rely on that trigger. Headless setup installs
a five-minute launchd or systemd user timer that calls the same serialized,
verified save wrapper. Clean detach also requests a best-effort immediate save.
The timer is the worker durability mechanism.

A worker restores its own sessions at boot, before any laptop connects. The
LaunchAgent `com.kalem.tmux-resurrect-restore` (`RunAtLoad`, GUI domain, so
the worker needs auto-login) starts the tmux server and runs the guarded
restore wrapper under the same lock the save wrapper uses. An attach loop
that finds no tmux server on the worker runs the same wrapper and waits on the
lock, so two laptop panes cannot race a restore. After any worker restore,
`rw-worker-post-restore.sh` re-applies the hidden-session options to every
`rw-*` session and re-stamps the worker's mirror records. Agents on the
worker resume through `claudef` and `pif`, so the worker's verified save
captures them.

`prefix Ctrl-s` saves and verifies the focus machine. When the focused pane is
remote-backed, it then runs the same verifier on that worker and updates the
remote freshness chip only after success.

The sidecar records `rw_endpoint` for each pane that carries `@rw-endpoint`.
Such panes count as captured and are never replayed, so a remote pane cannot
poison the laptop's verified save. A `session-renamed` hook keeps
`sessions.jsonl` current and rewrites `focus_session_name` (and, for bound
panes, the window and pane indices) in every endpoint of that session, so a
renamed worktree session still reattaches.

Post-restore work is ordered:

1. `rw-post-restore.sh` runs first, before
   the sidecar replay. It reattaches each registered, untombstoned endpoint
   by endpoint id, finding its pane from the record's session name, window
   and pane indices and the restored sidecar's `rw_endpoint` field, and
   respawns that pane into its attach loop (`restore-reattach` event). It
   only takes a bare restored shell and never kills a busy pane. When the
   sidecar places an endpoint elsewhere than the record's indices, the
   sidecar wins, because its positions are what tmux-resurrect recreated.
2. The sidecar replay (`tmux-workspace-resurrect/scripts/restore.sh`) runs
   next and skips every pane that has `rw_endpoint` in the sidecar or
   `@rw-endpoint` live.
3. `libexec/reconcile` compares the successfully restored desired set with
   tombstones and the endpoint registry. Every registered endpoint stays in
   the desired set whether or not a pane was found for it.
4. `reconcile-worker` removes worker tmux sessions in this focus machine's
   namespace that have no registry entry. It skips young and attached
   sessions.
4. `reconcile-local` reports registered endpoints that no live local pane
   carries and leaves them running. It never closes anything.

A missing or invalid snapshot is never an empty desired set. Unreachable
workers yield no deletion candidates. Reconciliation never touches another
focus machine's namespace or unmanaged worker tmux sessions.

After total laptop tmux server loss, `tmux-restore` restores the outer
landscape and `rw-post-restore.sh` reattaches every restored remote pane to
its endpoint by id. Worker sessions, and the agents in them, keep running
through the loss. They die only on an explicit hand-back, `rw forget`, or
`rw close`. An endpoint whose pane is not found is logged
(`restore-reattach-missing`), stays registered, and shows as unattached in
`rw status`. Its root keeps showing as remote.

## User-facing controls

| Action | Behavior |
| --- | --- |
| `prefix e` | On a local pane, choose a worker and hand off the pane's root. On a remote pane, confirm, then hand the root back. Both run in the background |
| `prefix \\` / `prefix /` | Split locally, or open a new remote pane in the source pane's root with `rw open` |
| `prefix q` | Close the focused endpoint through tombstone-first teardown, otherwise kill a plain pane |
| `prefix &` | Confirm, close all endpoints in the window, then kill the window |
| `prefix Tab` | Open local Treemux or toggle a remote tree endpoint |
| `prefix [` / `PageUp` | Enter local or worker-side copy mode as appropriate |
| `prefix Ctrl-s` | Run the verified local save and, when focused remotely, the worker save |
| `rw status` | Print remote roots (owner, worker, panes, pending), then each endpoint's live pane and latest event |
| `rw doctor` | Report local, worker, registry, reconciliation, and clipboard health |
| `rw bg handoff` / `rw bg handback` | Check, return at once, then transfer detached after the root's agents go idle; status-line chip, dialogs on conflict or failure |
| `rw request handback` | On the worker side of a pane: ask the laptop to hand the root back |
| `/remote-handoff to [worker]` / `back` | Agent skill: the agent hands off its own directory and continues on the other side |

The CLI forms are `rw handoff`, `rw handback`,
`rw bg handoff [--worker <alias>] --pane <pane> [--wait-idle <seconds>]`,
`rw bg handback --pane <pane> [--wait-idle <seconds>]`,
`rw request handback`, `rw open`, `rw forget`, `rw reclaim --force`,
`rw status [--json]`, `rw close`, and `rw doctor`. `rw bg` exits 0 once
started, 1 when a transfer of the root already runs or the pane is
missing, 7 for an invalid, already remote or not remote root or the
worker side, and 64 on usage; the transfer's own codes go to its log and
dialog.
Exit codes: 0 ok, 1 failure, 2 git history diverged, 3 agent CLI too old,
5 manifest conflict, 6 worker unreachable, 7 root invalid or not in the
required state, 64 usage.

Navigation and resize bindings are ordinary local tmux commands. New windows
stay local unless they are opened for a root that is already remote.

## Implementation map

### Plugin entry and configuration

- `tmux/local-plugins/tmux-remote-workspaces/tmux-remote-workspaces.tmux`
  installs session hooks, display formats, restore hooks, and remote copy-mode
  entry.
- `tmux/local-plugins/tmux-remote-workspaces/config.json` declares logical
  workers and SSH timeouts. It has no workspace root.
- `tmux/local-plugins/tmux-remote-workspaces/scripts/rw` is the command
  dispatcher exposed as `~/.local/bin/rw`.
- `tmux/local-plugins/tmux-remote-workspaces/scripts/common.sh` owns state
  paths, JSON access, identity, SSH, tmux, process-tree, logging, locking,
  close helpers, hidden-session options, and the root, ownership-record,
  `held/` and worker-mirror helpers.

### Root and endpoint commands and pane runtime

- `scripts/roots.sh` holds the root-level operations shared by the commands:
  finding a root's panes, path mapping, pane release, mirror pushes, worker
  copy deletion, and pending-action reconciliation.
- `scripts/rw-handoff.sh`, `rw-handback.sh`, `rw-forget.sh`, and
  `rw-reclaim.sh` implement root ownership changes.
- `scripts/rw-open.sh`, `rw-close.sh`, `rw-close-window.sh`, and
  `rw-split.sh` implement endpoint creation and pane or window lifecycle.
- `scripts/attach-loop.sh` owns reconnect and pane-release behavior.
- `scripts/preflight.sh` checks configured workers without provisioning them
  and reports the worker's physical home.
- `scripts/resolve-workspace.sh` resolves a root and its `~`-relative worker
  placement without SSH.
- `scripts/rw-picker.sh` implements the
  `prefix e` popup: worker chooser and `rw bg handoff` on a local pane,
  confirmation and `rw bg handback` on a remote pane, `rw open` on a local
  pane in a remote root.
- `libexec/rw-bg` is `rw bg`: the synchronous check, the `setsid` detach
  and the runner (wait-idle, transfer, conflict re-run, failure dialog).
  `libexec/rw-bg-dialog` runs the conflict dialog inside the runner's
  popup, and `libexec/rw-dialogs.sh` holds the conflict dialog and failure
  wording shared with the picker. `libexec/rw-request` is
  `rw request handback`.
- `scripts/rw-status.sh` and `rw-doctor.sh` expose state and health.
- `scripts/rw-copy-mode.sh` enters copy mode on the correct tmux server.
- `scripts/rw-refresh-indicators.sh` reconciles display caches with live attach
  loops and, with `--transfers`, sets `@rw-transfer` and
  `@rw-transfer-label` from the running background transfers and wires
  their status-line chip.
- `scripts/session-created-hook.sh` maintains stable session identities.
- `scripts/rw-session-renamed.sh` keeps `sessions.jsonl` and the endpoint
  records' session name and indices current across session renames.
- `scripts/rw-post-restore.sh` reattaches
  restored laptop panes to their endpoints by id.
- `scripts/rw-worker-post-restore.sh`
  re-applies hidden-session options and mirror records after a worker
  restore.

All `scripts/` paths in this section are relative to
`tmux/local-plugins/tmux-remote-workspaces/`.

### Transfer and agents

- `libexec/sync/handoff` is the transactional push and pull engine with the
  git and rsync channels and the manifest gate.
- `libexec/sync/common.sh` owns fingerprints, manifests, rsync rules, and
  generation state.
- `libexec/sync/README.md` records the wire format, manifest rules, and exit
  contract.
- `libexec/adapters/{pi,claude,codex}` implement provider-specific session
  movement.
- `libexec/adapters/common-adapter.sh` holds their shared process and transport
  helpers.
- `libexec/adapters/README.md` records the adapter contract.
- `libexec/adapters/smoke-test` provides sandboxed adapter fixtures.
- `tests/run.sh` runs the shell tests for path mapping, ownership records,
  manifests, the rsync channel, sync round trips, and the CLI round trip
  against a same-host fake worker, with no tmux server and no network.

### Reconciliation and remote tree

- `libexec/reconcile`, `reconcile-local`, and `reconcile-worker` cover restored
  desired sets, the unbound-endpoint report, and worker-side zombie sessions.
- `scripts/rw-treemux.sh`, `rw-tree-pane.sh`, and `rw-tree-listener.sh` own the
  tree and editor endpoint lifecycle.
- `nvim/rw-tree-init.lua` implements worker-side file-open routing.

### Tmux and persistence integration

- `tmux/tmux.conf` loads the two local plugins in order, enables passthrough,
  wires the status line, and replaces Treemux's binding.
- `tmux/tmux.reset.conf` owns picker, split,
  navigation, resize, close, reload, and restore bindings, including
  `prefix e` in both directions.
- `tmux/local-plugins/tmux-workspace-resurrect/`
  owns the companion sidecar, records `rw_endpoint` per pane, skips replay
  for endpoint panes, and honors `@workspace-resurrect-skip` during restore.
- `tmux/local-plugins/tmux-agent-sessions/picker/`
  reads the ownership records for the `remote` marker, opens new windows
  remote for remote roots, and calls `rw forget` on delete.
  `git/.local/bin/wt` calls `rw forget` from `wt rm`.
- `tmux/scripts/{autosave_indicator.sh,manual_resurrect_save.sh,wire_autosave_indicator.sh,wire_resurrect_save.sh}`
  implement verified saves and freshness display.
- `tmux/local-plugins/tmux-workspace-resurrect/scripts/save.sh` is the
  serialized save entry point shared by manual and scheduled saves.
- `tmux/scripts/{dialog.sh,host_indicator.sh,tmux_restore.sh,treemux-python.sh,window_nav.sh,yank.sh}`
  provide the shared UI, recovery, tree, navigation, and clipboard paths used
  by the integration.
- `setup/patches/tmux-resurrect-{rw-client-guard,save-validity-gate,tmux37-delimiter}.patch`
  preserve restore clients, reject incomplete snapshots, and handle tmux 3.7
  delimiter changes.

### Installation and worker durability

- `Makefile` and `setup/lib.sh` install tmux plugins and link `rw` onto PATH.
- `setup/headless-doctor.sh` verifies the dispatcher, plugins, patches, worker
  timer, and worker power settings.
- `setup/linux-headless.sh` and `setup/misc-headless.sh` install Linux systemd
  and macOS launchd durability jobs.
- `setup/templates/tmux-resurrect-save.sh` is the timer's verified wrapper.
- `setup/templates/tmux-resurrect-save.{service,timer}` and
  `setup/templates/com.kalem.tmux-resurrect-save.plist` define the jobs.
- `setup/templates/tmux-resurrect-restore.sh`
  and `setup/templates/com.kalem.tmux-resurrect-restore.plist` define the
  guarded worker boot restore.
- [`headless-workers.md`](headless-workers.md) is the provisioning and worker
  registration runbook.
- [`headless-vs-local.md`](headless-vs-local.md) explains why detached workers
  need timers while the focus machine can use Continuum.

## Decision record

- **2026-07-30:** Chose a local-first design with the laptop tmux server as the
  visible control plane. Remote endpoints consume provisioned workers and must
  move dirty Git and agent state without requiring a commit and push.
- **2026-07-31 to 2026-08-01:** Implemented endpoint registry, attach loop,
  transactional handoff, provider adapters, tombstone-first close, and worker
  save timers. The initial system landed in `6c08c9c`. Dashed endpoint names
  replaced dotted names because of tmux target parsing.
- **2026-08-01:** Kept the primary worker as one logical alias with LAN-first
  SSH routing. Remote Treemux moved onto the worker because the outer pane's
  cwd belongs to the local SSH process.
- **2026-08-02:** Verified macOS and Linux worker provisioning and detached
  saves. Tmux 3.7 testing led to one-field parsing and pinned tmux-resurrect
  patches for delimiter handling, client protection, and snapshot validity
  (`bbd0211`, `d232f42`, and `53af514`).
- **2026-08-03:** Removed window-level remote defaults. A split now follows
  only its source pane. Transactional sync and provider resume failures were
  hardened through the first full smoke campaign.
- **2026-08-04:** Made the picker elevate the focused pane, added remote status
  and directory indicators, repaired clipboard behavior, and completed local
  and worker reconciliation (`418e10a`, `0aad387`, and `fc98e55`).
- **2026-08-05:** Replaced remote key forwarding and nested worker splits with
  tree and editor endpoints (`1c5ecba`). Navigation and resize returned to
  stock local tmux commands. The picker became the intent-aware ensure,
  handoff, and return entry point (`a749b14`, `c3ed88a`).
- **2026-08-06 to 2026-08-08:** Added server-side copy-mode entry, exact agent
  access-mode replay, restore hardening, and failure dialogs. The live smoke
  journey closed with endpoint, split, close, reconnect, Treemux, handoff,
  return, agent resume, clipboard, worker reboot, and laptop restore paths
  passing. Commits `e5c3850` and `be0ae44` closed the journey and folded its
  durable findings into the plugin README.
- **2026-09-08 (`85c54bc`):** Removed persistent worktree slots, preparation
  tiers, stable port allocation, reflected repository configuration, claim
  markers and commands, and agent worktree hooks. Stable per-local-worktree
  remote checkouts replaced that machinery. Tmux Remote Workspaces stopped
  governing the worktree lifecycle.
- **2026-11-18 (`fe61a15`):** Replaced pane-scoped handoff with directory-root
  ownership. A root and every pane inside it move together; the holder owns
  it and the laptop copy stays frozen. Paths are relative to `~` and
  `~/rw-workspaces` placement is retired. An rsync channel carries gitignored
  files and plain folders, guarded by manifests with an owner-wins conflict
  rule. `rw ensure` became `rw open`, `rw return` became `rw handback`, and
  `rw forget` and `rw reclaim --force` were added. Worker resumes go through
  `claudef` and `pif`. Reconciliation stopped closing registered endpoints,
  and laptop restore reattaches by endpoint id, reversing the earlier
  accepted behavior of closing remote endpoints after laptop server loss.
- **2026-11-18 (`48c7f8e`):** Transfers can run in the background (`rw bg`),
  so `prefix e` no longer holds the client and an agent can hand off its
  own directory (`/remote-handoff`). `rw request handback` lets the worker
  side ask for a hand-back through the `@rw-request` pane option.

The September decision is final for this system. Do not reintroduce slots,
claims, reflected repository rules, or a global worktree manager as a remote
workspace maintenance change. Directory ownership records are not claims: they
record which machine holds a root's working copy during a handoff and nothing
else.

## Maintenance checks

Keep validation proportional to the layer changed:

1. Run `bash -n` across the plugin, sibling workspace-resurrect integration,
   and changed setup scripts.
2. Validate `config.json` with `jq` after changing workers or timeouts.
3. Run `tests/run.sh` after changing path mapping, ownership records, the
   sync engine, or the `rw` command surface.
4. Run `libexec/adapters/smoke-test` after changing a provider adapter.
5. Use a private tmux socket and private Resurrect directory for any test that
   creates sessions, panes, hooks, or snapshots. Never test those paths on the
   interactive server.
6. Run `rw doctor` for local and reachable-worker health. It is read-only.
7. Recheck `~`-relative placement, roots outside `~`, and subdirectories of a
   worktree after changing `resolve-workspace.sh` or the root helpers in
   `common.sh`.
8. Test tombstone ordering, ambiguous-state protection, the rule that
   registered endpoints are never closed by reconciliation, and namespace
   limits after changing close, restore, or reconciliation logic.
9. Keep comments, the plugin README, and this document aligned with the
   current contract. Historical phase names and retired slot or claim rules do
   not belong in live implementation guidance.

The 2026-08-08 operator journey remains the end-to-end validation record for
endpoints, Treemux, clipboard and reconnect. Run a new live worker exercise
only when behavior changes, not as unfinished work for the existing system.
