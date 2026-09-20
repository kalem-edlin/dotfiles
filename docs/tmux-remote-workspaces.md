# Tmux remote workspaces

Tmux Remote Workspaces is complete. It keeps the laptop tmux server as the
only visible coordination layer and lets one selected pane continue inside a
durable tmux session on an always-on worker. Remote execution is opt-in and
pane-scoped. This document records the current system and the decisions needed
to maintain it. It is not an implementation plan or backlog.

The colocated plugin README at
[`tmux/local-plugins/tmux-remote-workspaces/README.md`](../tmux/local-plugins/tmux-remote-workspaces/README.md)
is the command and operational reference.

## System rules

### Local first

New shells, windows, and agents start locally. `prefix e` or `rw ensure`
elevates the selected pane. A local pane in a mixed window remains local, and a
split follows the pane from which the split was requested.

The outer laptop tmux owns the visible layout. Each remote-backed pane attaches
over SSH to a single-pane worker tmux session. This keeps navigation, resizing,
and pane selection local and immediate.

### Consume, never provision

The plugin uses only resources already installed on a worker. It never installs
tmux, Git, Git LFS, Neovim, provider CLIs, credentials, or SSH keys.
`scripts/preflight.sh` reports missing requirements and points back to
`make setup-headless`. Worker authentication remains machine-local.

### Intent is separate from connectivity

An endpoint registry entry means the user intends the endpoint to exist. A
live `attach-loop.sh` process means the local pane is currently executing
through that endpoint. The tmux options mirror this distinction:

- `@rw-endpoint`, `@rw-worker`, and `@rw-workspace` cache endpoint intent.
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
`prefix &` use this lifecycle-aware path. Raw pane death is repaired by
reconciliation.

No component deletes an endpoint or checkout merely because it is old.

## Workspaces after slots and claims

The September 2026 simplification removed the entire persistent worktree slot
and worktree claim system. Current behavior has no numbered slots, preparation
tiers, global port allocator, reflected repositories, `.worktree-claim`
markers, writer leases, or `worktree-slot` and `worktree-claim` commands.

Every local Git worktree is an independent workspace. Automatic placement uses
the normalized repository identity, the local worktree directory name, and a
checksum of its canonical path. The result is a stable worker checkout under:

```text
~/rw-workspaces/<focus-machine-id>/<repository>/<worktree-and-checksum>
```

Two physical worktrees for the same repository map to different worker
checkouts. Branch names and numbered directory conventions do not affect the
mapping. A live endpoint for the same local worktree and worker reuses the
existing path. A non-Git directory uses the worker's home unless the caller
passes `--workspace <path>`.

The remote-workspace layer does not create, name, own, recycle, or remove local
Git worktrees. Git and the repository's own practices own that lifecycle.

Removing claims did not remove transfer safety. Handoff still compares sync
generations and content fingerprints, backs up the destination, stages the
transfer, verifies the result, and refuses divergence unless explicitly
overridden. The provider handoff also guards against a duplicate managed resume
of the same agent session. These checks protect a specific transfer. They are
not a global worktree ownership system.

## Endpoint and state model

`rw ensure --worker <alias>` performs this sequence:

1. Validate the logical worker alias and preflight it over SSH.
2. Resolve the worker directory from the current local worktree or explicit
   path.
3. Create or validate `rw-<focus-short-id>-<endpoint-id>` on the worker tmux
   server.
4. Write the endpoint registry entry.
5. Stamp the pane's intent caches.
6. Replace the pane process with `attach-loop.sh`.
7. Let the attach loop stamp execution caches and attach to the worker session.

The dashed endpoint name is deliberate. Tmux treats `.` as target syntax and
rewrites dotted session names, so the earlier dotted design could not
round-trip reliably.

The default state root is
`~/.local/state/tmux-remote-workspaces/`:

```text
machine-id            stable focus-machine UUID
sessions.jsonl         session UUID to tmux session name, latest record wins
endpoints/<id>.json    authoritative live endpoint records
tombstones/<id>.json   close intent written before teardown
events.jsonl           append-only lifecycle and transfer observations
locks/                 mkdir locks around check-then-act operations
rw.log                 diagnostic log
```

Tmux pane and session options are caches. JSON and JSONL state is authoritative
because tmux options do not survive a server restart and window indices are
renumbered.

`mini` is the logical Mini identity. OpenSSH chooses its verified LAN route
when available and falls back to Tailscale. `mini-lan` is diagnostic only and
must not become a second worker entry.

## Handoff and return

`rw handoff` moves unpushed commits, staged and unstaged changes, renames,
deletions, untracked files, and referenced Git LFS objects without requiring an
administrative commit and push. The sync engine uses one code path for local
fixtures and SSH destinations.

The safe ordering is:

1. Preflight the destination and provider compatibility.
2. Capture and transfer workspace and agent state.
3. Apply into a staged destination with a recoverable backup.
4. Start the destination agent and confirm its process in the target pane.
5. Stop the source agent only after the destination resume is confirmed.

`rw return` applies the same engine in the opposite direction and releases the
remote pane before launching the local resume. `--keep-local` and
`--keep-remote` are explicit exceptions that record transcript-divergence risk.
If no agent is detected, the command performs a workspace-only transfer.

Provider adapters for Pi, Claude, and Codex own transcript discovery, version
checks, export, install, resume commands, and process matching. They do not own
tmux or workspace transfer.

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

`prefix Ctrl-s` saves and verifies the focus machine. When the focused pane is
remote-backed, it then runs the same verifier on that worker and updates the
remote freshness chip only after success.

Post-restore work is ordered:

1. `rw-post-restore.sh` resolves restored sessions and panes by stable UUID and
   restores eligible endpoint bindings.
2. `libexec/reconcile` compares the successfully restored desired set with
   tombstones and the endpoint registry.
3. `reconcile-worker` removes worker tmux sessions in this focus machine's
   namespace that have no registry entry.
4. `reconcile-local` removes endpoints proven to have lost their local pane in
   the current server generation.

A missing or invalid snapshot is never an empty desired set. Unreachable
workers yield no deletion candidates. Reconciliation never touches another
focus machine's namespace or unmanaged worker tmux sessions.

After total laptop tmux server loss, `tmux-restore` restores the outer
landscape. Existing remote endpoints are closed cleanly rather than silently
reattached. Reopen them with `prefix e`. This is accepted behavior, not an
unfinished implementation item.

## User-facing controls

| Action | Behavior |
| --- | --- |
| `prefix e` | Choose a worker and ensure, hand off, or return according to the focused pane |
| `prefix \\` / `prefix /` | Split locally, or inherit the source pane's worker and workspace |
| `prefix q` | Close the focused endpoint through tombstone-first teardown, otherwise kill a plain pane |
| `prefix &` | Confirm, close all endpoints in the window, then kill the window |
| `prefix Tab` | Open local Treemux or toggle a remote tree endpoint |
| `prefix [` / `PageUp` | Enter local or worker-side copy mode as appropriate |
| `prefix Ctrl-s` | Run the verified local save and, when focused remotely, the worker save |
| `rw status` | Print registry, live pane, worker liveness, and latest-event state |
| `rw doctor` | Report local, worker, registry, reconciliation, and clipboard health |

Navigation and resize bindings are ordinary local tmux commands. New windows
stay local.

## Implementation map

### Plugin entry and configuration

- `tmux/local-plugins/tmux-remote-workspaces/tmux-remote-workspaces.tmux`
  installs session hooks, display formats, restore hooks, and remote copy-mode
  entry.
- `tmux/local-plugins/tmux-remote-workspaces/config.json` declares logical
  workers, the workspace root, and SSH timeouts.
- `tmux/local-plugins/tmux-remote-workspaces/scripts/rw` is the command
  dispatcher exposed as `~/.local/bin/rw`.
- `tmux/local-plugins/tmux-remote-workspaces/scripts/common.sh` owns state
  paths, JSON access, identity, SSH, tmux, process-tree, logging, locking, and
  close helpers.

### Endpoint commands and pane runtime

- `scripts/rw-ensure.sh`, `rw-close.sh`, `rw-close-window.sh`, and
  `rw-split.sh` implement endpoint creation and pane or window lifecycle.
- `scripts/attach-loop.sh` owns reconnect and pane-release behavior.
- `scripts/preflight.sh` checks configured workers without provisioning them.
- `scripts/resolve-workspace.sh` implements stable per-worktree placement.
- `scripts/rw-picker.sh` implements the popup workflow.
- `scripts/rw-status.sh` and `rw-doctor.sh` expose state and health.
- `scripts/rw-copy-mode.sh` enters copy mode on the correct tmux server.
- `scripts/rw-refresh-indicators.sh` reconciles display caches with live attach
  loops.
- `scripts/session-created-hook.sh` maintains stable session identities.
- `scripts/rw-post-restore.sh` reconnects restored local structure to endpoint
  records.

All `scripts/` paths in this section are relative to
`tmux/local-plugins/tmux-remote-workspaces/`.

### Transfer and agents

- `scripts/rw-handoff.sh` and `scripts/rw-return.sh` coordinate tmux,
  preflight, transfer, adapter, and source-stop ordering.
- `libexec/sync/handoff` is the transactional push and pull engine.
- `libexec/sync/common.sh` owns fingerprints and generation state.
- `libexec/sync/README.md` records the wire format and exit contract.
- `libexec/adapters/{pi,claude,codex}` implement provider-specific session
  movement.
- `libexec/adapters/common-adapter.sh` holds their shared process and transport
  helpers.
- `libexec/adapters/README.md` records the adapter contract.
- `libexec/adapters/smoke-test` provides sandboxed adapter fixtures.

### Reconciliation and remote tree

- `libexec/reconcile`, `reconcile-local`, and `reconcile-worker` cover restored
  desired sets, dead local panes, and worker-side zombie sessions.
- `scripts/rw-treemux.sh`, `rw-tree-pane.sh`, and `rw-tree-listener.sh` own the
  tree and editor endpoint lifecycle.
- `nvim/rw-tree-init.lua` implements worker-side file-open routing.

### Tmux and persistence integration

- `tmux/tmux.conf` loads the two local plugins in order, enables passthrough,
  wires the status line, and replaces Treemux's binding.
- `tmux/tmux.reset.conf` owns picker, split, navigation, resize, close, reload,
  and restore bindings.
- `tmux/local-plugins/tmux-workspace-resurrect/` owns the companion sidecar and
  honors `@workspace-resurrect-skip` during restore.
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
- `setup/headless-doctor.sh` verifies the dispatcher, plugins, patches, and
  worker timer.
- `setup/linux-headless.sh` and `setup/misc-headless.sh` install Linux systemd
  and macOS launchd durability jobs.
- `setup/templates/tmux-resurrect-save.sh` is the timer's verified wrapper.
- `setup/templates/tmux-resurrect-save.{service,timer}` and
  `setup/templates/com.kalem.tmux-resurrect-save.plist` define the jobs.
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
- **2026-08-01:** Kept `mini` as one logical worker with LAN-first SSH routing.
  Remote Treemux moved onto the worker because the outer pane's cwd belongs to
  the local SSH process.
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

The September decision is final for this system. Do not reintroduce slots,
claims, reflected repository rules, or a global worktree manager as a remote
workspace maintenance change.

## Maintenance checks

Keep validation proportional to the layer changed:

1. Run `bash -n` across the plugin, sibling workspace-resurrect integration,
   and changed setup scripts.
2. Validate `config.json` with `jq` after changing workers or timeouts.
3. Run `libexec/adapters/smoke-test` after changing a provider adapter.
4. Use a private tmux socket and private Resurrect directory for any test that
   creates sessions, panes, hooks, or snapshots. Never test those paths on the
   interactive server.
5. Run `rw doctor` for local and reachable-worker health. It is read-only.
6. Recheck stable placement with two physical worktrees of one repository
   after changing `resolve-workspace.sh`.
7. Test tombstone ordering, ambiguous-state protection, and namespace limits
   after changing close or reconciliation logic.
8. Keep comments, the plugin README, and this document aligned with the
   current contract. Historical phase names and retired slot or claim rules do
   not belong in live implementation guidance.

The 2026-08-08 operator journey remains the end-to-end validation record. Run
a new live worker exercise only when behavior changes, not as unfinished work
for the existing system.
