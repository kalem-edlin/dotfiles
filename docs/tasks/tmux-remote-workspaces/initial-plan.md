# Tmux Remote Workspaces — Initial Plan

Status: implementation is complete dotfiles-side. The worker-provisioning
prerequisite this plan depended on is now satisfied and verified — see
"Headless worker provisioning results (2026-08-02)" below and
`docs/headless-workers.md` for the full campaign record. The remaining
open surface is this plan's own live smoke execution: Waves 0-7 below are
mostly unexecuted, Wave 5's real provider handoff/return matrix is blocked on
operator authentication, and the live-server crash/restore drill is
deliberately deferred to the last step. See "Remaining smoke-test surface
(as of 2026-08-02)" at the end of the smoke-testing section for the current
breakdown. Separately, this plan implies changes to the content-engine
repository itself; those are not part of this document's dotfiles execution
and are consolidated as their own ad hoc PR in "Content-engine follow-up: a
separate PR" near the end of the smoke-testing section.

Created: 2026-07-30
Implementation status: implemented dotfiles-side (2026-07-31); see
"Implementation record" at the end of this document for deviations, verified
results, and the remaining live-worker validation items.

## Purpose of this document

This file preserves the user's intent, constraints, corrections, and the
realistic engineering requirements for a dotfiles-owned remote workspace
system.

The intent is particularly important. Implementation details may change as the
system is tested, but the implementation must not quietly narrow the desired
workflow into "start everything remotely" or "commit and push before changing
machines." Those are explicitly not acceptable substitutes for the workflow
described here.

This is an active task document. Decisions that remain open are marked as such.

## Original intent

The user's laptop is the focus machine and primary orchestration surface.
Development is organized through local tmux sessions. A tmux session represents
a durable responsibility area or parallel project task. Some sessions
correspond to Git worktrees, but tmux usage must not become universally coupled
to Git worktrees.

The focus machine already has:

- Persistent tmux sessions, windows, panes, names, shell input, Neovim state,
  Treemux state, and AI coding-agent resume commands captured by
  `tmux-workspace-resurrect`.
- Approximately five-minute autosaves while the laptop tmux client is active.
- Reusable, numbered worktree slots for repositories that benefit from durable
  heavyweight setup such as CocoaPods, Xcode caches, Git LFS material, and
  other expensive build state.
- AI coding work that normally begins and remains local.

The user also has always-on headless machines reached over SSH and Tailscale,
including a macOS Mini available as `ssh mini`. The Mini is used as a terminal
worker and for automated Xcode and Simulator operations. Other workers may be
Linux machines or VMs.

The desired unlock is to keep the laptop tmux instance as the single visible
coordination layer while selectively elevating a local pane, window, workspace,
or active AI coding session to a persistent remote worker.

The user should be able to:

1. Work locally by default.
2. Decide that a particular local focus area should continue on a remote host.
3. Establish a durable remote tmux endpoint corresponding to that local focus
   area.
4. Transfer the current repository state, including eligible uncommitted
   changes, without an administrative commit/push/pull cycle.
5. Transfer a supported AI agent transcript and make it eligible to resume from
   the corresponding remote directory.
6. Continue interacting through the existing laptop tmux layout.
7. Survive laptop sleep, network loss, SSH loss, remote tmux detach, local tmux
   resurrection, remote tmux resurrection, and either machine being restarted.
8. Hand the work and agent conversation back to the laptop later.

Remote use is selective. The sustainable model is local-first with optional
remote reflection and handoff. Starting all agents remotely from the beginning
is not a valid replacement for this requirement.

## Terminology

- **Focus machine**: the laptop whose tmux server is the primary human-facing
  orchestration surface.
- **Worker**: a headless macOS or Linux host reachable through SSH.
- **Remote attachment**: the local tmux pane process that connects to a durable
  remote endpoint.
- **Remote endpoint**: a persistent remote tmux PTY and its metadata. Losing an
  attachment does not delete it; an intent-aware local close does.
- **Workspace**: a Git worktree, clone, or ordinary directory associated with a
  focus responsibility.
- **Persistent slot**: a durable numbered worktree whose branch/task assignment
  changes while its path, ports, and prepared machine-local resources remain
  stable.
- **Preparation tier**: repository-configured setup level such as light, warm,
  or heavy. Tiers control which costly dependencies and caches are prepared for
  a slot.
- **Reflected repository**: a repository configured with durable numbered
  worktree slots on both the focus machine and an eligible worker.
- **Ad hoc workspace**: a worker-side checkout created for a repository that
  does not use reflected slots on that worker.
- **Handoff**: moving the current writable workspace and, when present, agent
  conversation state from one host to another.
- **Return handoff**: moving remote work and agent conversation state back to
  the focus machine.
- **Claim**: metadata saying which responsibility/tmux owner owns a worktree and
  which host is currently allowed to act as its writer.
- **Sidecar**: used in two related but distinct senses in this document.
  1. The specific `tmux-workspace-resurrect` state file,
     `workspace_state.json`, written alongside each plain `tmux-resurrect`
     snapshot in the same Resurrect directory (`workspace_sidecar_file()` in
     `tmux/local-plugins/tmux-workspace-resurrect/scripts/common.sh:31-33`),
     plus its companion log, `workspace-resurrect.log`. `save.sh` writes it
     atomically (temp file + `mv`) and enriches the bare Resurrect topology
     snapshot with per-pane command buffers/ZLE state, Neovim session
     pointers, Treemux sidebar/main-pane pairings, and AI coding-agent
     session ids (`tmux/local-plugins/tmux-workspace-resurrect/scripts/save.sh:200-217`).
     `restore.sh`, `doctor.sh`, and this repo's own `rw reconcile`
     (`tmux/local-plugins/tmux-remote-workspaces/libexec/reconcile:106-130`)
     all read this same file and treat a missing/invalid sidecar as "abort,
     never delete" rather than an empty desired set.
  2. A generic architectural description applied to `tmux-remote-workspaces`'
     own endpoint registry: an "external sidecar" chained onto the same
     upstream `@resurrect-hook-post-save-all`/`post-restore-all` hooks rather
     than a fork of `tmux-workspace-resurrect`'s schema (see "Local restore
     of remote attachments" below). This is not the `workspace_state.json`
     file itself — the endpoint registry is a separate store under
     `TMUX_REMOTE_WORKSPACES_STATE_DIR` — it is only sidecar *in the same
     architectural sense*, i.e. a companion data store hung off the same
     hooks instead of extending the primary plugin's own schema.

The word "mirror" describes the user experience and relationship between the
focus pane and worker endpoint. It must not be interpreted as permission for
unsafe simultaneous filesystem or transcript writers.

## Non-negotiable product requirements

### Consume, never provision

User intent: "We need to figure out a way to not have this new tmux
local-plugin try to setup anything — it only works on available resources."

- The plugin operates only on resources already provisioned by the dotfiles
  installs. It never installs CLIs, packages, keys, or credentials.
- Before establishing an endpoint, workspace, or handoff, it preflights:
  required binaries on the worker (tmux, git, git-lfs when applicable, the
  specific provider CLI for an agent handoff), worker-side git SSH
  authentication for the repository host (a private clone/fetch fails without
  the worker's own registered key — `setup-headless` already generates a
  worker key, but registering it with the Git host is a manual step), and
  version compatibility where required.
- A missing resource produces a clear, actionable warning naming the
  remediation path (`setup-headless` or manual provisioning) and aborts that
  operation. It never falls back to attempting the provisioning itself.
- Provisioning belongs to `setup-headless` and the dotfiles install, never to
  this plugin.

### Local-first behavior

- Local shells and local AI coding sessions remain the default.
- Remote delegation is an explicit action applied only to selected focus work.
- An existing local AI coding session must be eligible for remote handoff.
- A remote AI coding session must be eligible for return handoff.
- The design must not depend on vendor-hosted remote-control products.
- In particular, Anthropic Remote Control or similar AI-lab-controlled remote
  session facilities are not part of the design.

### Tmux remains the focus control plane

- The laptop tmux server remains responsible for the visible session, window,
  and pane layout.
- A remotely backed local pane must remember its remote host and endpoint
  explicitly.
- Focusing a remote pane must show the remote host in the tmux status line.
- A remote attachment that loses SSH must reconnect to the same endpoint.
- Splitting a remote pane with the configured vertical or horizontal split
  bindings must create a new remote pane on the same host and in the same
  workspace context by default.
- Opening Treemux from a remote-backed pane must run Treemux inside that
  endpoint's worker tmux session. The outer focus-machine pane remains an SSH
  attachment process, so its `#{pane_current_path}` is necessarily local and
  must never be used as the remote tree root. Worker-side dispatch makes the
  active remote pane's directory authoritative and keeps every tree, Git,
  editor, and tmux-split action on the worker.
- Creating a new window remains local by default and requires an explicit
  remote assignment.
- Baseline reality check: `tmux/scripts/host_indicator.sh` currently sets one
  global, server-wide Catppuccin host value at tmux load time; there is no
  per-pane logic anywhere in the current config. Per-pane remote-host display
  for a mirrored pane is net-new work (see "Status line, clipboard, and
  input").

### Endpoint lifetime follows user intent

The local focus pane and its mirrored remote endpoint normally have the same
intentional lifetime.

- The configured `prefix + q` action is an intentional close. For a remotely
  backed pane it must close the local focus pane and its corresponding remote
  tmux endpoint.
- An intentional local window close must close the remote endpoints owned by
  that window.
- An SSH disconnect, laptop sleep, laptop crash, local tmux crash, `kill-server`,
  machine restart, or resurrection flow is not an intentional pane close. The
  remote endpoint must remain available for reconnection or resurrection.
- Directly killing the remote endpoint is also intentional and must be
  reconciled back into the focus registry instead of being recreated forever.

The `prefix + q` binding must therefore call a lifecycle-aware close command,
not raw `kill-pane`. That command records the close intent before terminating
the endpoint, removes/releases the endpoint mapping, closes the remote tmux
endpoint, and then closes the local pane. Recording intent first prevents an
older Resurrect snapshot from reviving a deliberately closed endpoint after a
crash during cleanup.

Remote endpoint cleanup and repository storage cleanup are separate:

- Closing the endpoint stops its remote process and releases its active-writer
  lease.
- A reflected numbered worktree slot remains a reusable slot and is not
  deleted.
- An ad hoc checkout may only be removed automatically when the endpoint owns
  it exclusively and the workspace handoff policy proves that no unsynchronized
  work would be lost. Otherwise the endpoint is closed but the checkout remains
  recoverable and visible in status.

### Resurrection reconciliation and orphan disposal

After a complete local resurrection, the system compares:

- The endpoints declared by the successfully restored local snapshot.
- Close tombstones newer than that snapshot.
- Endpoints registered remotely as owned by this focus-machine identity.

The resulting desired set is authoritative for that resurrection generation.

- Desired endpoints are reattached, remotely resurrected, or rebuilt.
- A newer close tombstone suppresses stale local snapshot entries.
- Managed remote endpoints owned by this focus machine but absent from the
  successfully restored desired set are closed automatically because the local
  equivalents will not be reinvoked.
- Reconciliation must wait until local restore has completed successfully. A
  missing or unreadable snapshot is not an empty desired set and must never
  trigger bulk remote deletion.
- Reconciliation may only close endpoints in this focus machine's namespace.
  It cannot touch endpoints owned by another focus machine or unmanaged remote
  tmux sessions.

This is deterministic mirror reconciliation, not age-based garbage collection.

### No age-based garbage collector

- The plugin must not scan for and delete endpoints, worktrees, or repositories
  merely because they are old.
- Initial scope has no scheduled archival warnings or stale-workspace
  notifications.
- A future read-only `doctor` or status command may report inconsistent
  registries, but it is not part of ordinary pane lifecycle and must not inject
  messages into shells or TUIs.

### Remote-side tmux durability

- Every eligible worker installs and runs its own
  `tmux-workspace-resurrect`.
- The worker's plugin captures its own shells, remote agent processes,
  Neovim state, Treemux state, and command buffers.

Verified finding: tmux-continuum has no independent timer. Its autosave is a
`#()` shell command injected into `status-right`, evaluated only while some
client is actively rendering the status line. With `status off`, or on a fully
detached worker, that interpolation never fires, so a detached endpoint never
autosaves. This is separate from the already-solved failure where themes
overwrite `status-right`; that one is handled by loading Continuum last in the
TPM plugin list (`tmux/tmux.conf:49`), after the 2026-07-15 incident.

DECISION: the earlier "no custom `launchd`/systemd timer" constraint is
reversed on this evidence.

- Workers install a small, direct periodic save timer — a `launchd` user agent
  on macOS, a systemd user timer on Linux — that invokes
  `tmux-resurrect`'s save script directly, independent of any rendering
  client. `setup-headless` installs this timer.
- Continuum remains unchanged on the focus machine, where a rendering client
  always exists.
- Consequence: endpoint sessions may safely use `status off`.

The worker-side `client-detached` hook is retained, but only as a best-effort
immediate save on clean detach. Verified: such hooks do not fire on
signal-based client termination (tmux/tmux#1174); behavior on an abrupt
TCP/SSH drop (as opposed to a clean `detach-client`) is unverified and must be
smoke-tested explicitly — the killed-connection path, not just clean detach.
The periodic timer is the correctness net; the hook is an optimization on top
of it, not a substitute.

Recommended endpoint session config:

```text
set -g prefix None
set -g prefix2 None
set -g mouse off
set -g escape-time 10
set -g status off
```

- A remote reconnect may start the tmux server and let the worker's own
  resurrection installation restore it. Eagerly starting every worker tmux
  server at OS boot is not required for v1.

### Local restore of remote attachments

When the laptop tmux state is restored, each remote attachment must:

1. Try to reach the remembered worker.
2. Attach to the remembered remote endpoint if it exists.
3. If the worker is reachable but its tmux server is absent, ask the worker's
   resurrection installation to restore the worker tmux server.
4. Recheck for the endpoint after remote restoration.
5. If the endpoint still does not exist, reconstruct it from the saved
   declarative endpoint manifest as if it were being established again.
6. If the worker is unreachable, remain in an unobtrusive reconnecting state
   without replacing or deleting anything.

The local side therefore needs a minimal declarative endpoint manifest. It does
not need to duplicate every transient detail already recorded by the worker,
but it must remember enough to rebuild:

- Worker alias and stable worker identity.
- Stable local focus/session/window/pane identifiers.
- Remote endpoint identifier.
- Workspace identity and remote path.
- Repository/reflection mode.
- Original launch intent.
- Agent provider, session identifier, and provider resume intent when relevant.

Two integration requirements against `tmux-workspace-resurrect` follow from
this:

- `tmux-workspace-resurrect` must gain a small pane-option opt-out so its
  restore never pastes a recorded command (for example a stale `ssh mini`)
  into a pane that `tmux-remote-workspaces` manages. Today no such seam
  exists, so both plugins would write into the same pane after a restore.
- The endpoint registry is the source of truth for endpoint identity. It is an
  external sidecar, chained onto the same upstream
  `@resurrect-hook-post-save-all`/`post-restore-all` hooks rather than a fork.
  Tmux user options are runtime cache only — neither the stock nor the
  workspace-resurrect variant of Resurrect persists arbitrary `@`-vars across
  a restart. Logical `session:window.pane` ids are also destabilized by
  `renumber-windows on` (`tmux/tmux.conf:13`), so the registry must define
  UUID re-resolution after restore/renumbering. Never extend
  `tmux-workspace-resurrect`'s own schema for this (anti-monolith rule).

### Worker state may be rebuilt

- For initial development, existing state on `mini` is disposable.
- Current Mini worktrees, tmux sessions, stale Resurrect snapshots, and tool
  state do not need to be preserved for this task.
- Destructive setup must still target explicit managed paths rather than
  treating the whole home directory as disposable.

## Pane and window model

The preferred underlying ownership model is pane-based with window affinity:

- Every remote pane has its own durable endpoint identity.
- A window may declare a default worker and workspace.
- New splits inherit that window/pane context.
- A window assignment command may promote all eligible panes in a window, but
  the registry still tracks each endpoint separately.
- Mixed-host windows are technically possible but are not the default UX.

The initial implementation should use one remote tmux session containing one
endpoint pane for each local remote pane. All endpoint sessions live in the
normal remote tmux server and use a recognizable namespace.

This avoids implementing a custom terminal renderer around tmux control mode.
It also preserves the laptop tmux server as the only layout and keybinding
authority.

Example relationship:

```text
Laptop tmux session/window/pane
  -> reconnecting remote attachment
    -> ssh mini
      -> Mini tmux server
        -> endpoint session rw-<focus-id>-<endpoint-id>
          -> shell, nvim, server, or AI coding agent
```

Remote endpoint names are implementation identifiers, not the entire source of
truth. Full metadata lives in a private runtime registry.

### Transport

V1 reconnect is a plain SSH retry loop:

```text
ssh -t <worker> tmux new -A -s <endpoint>
```

wrapped in capped exponential backoff, with `ServerAliveInterval`/
`ServerAliveCountMax` for prompt dead-connection detection and
`ControlMaster`/`ControlPersist` for fast reattach. The loop distinguishes
intentional-close exit codes from connection drops so it does not spin after a
deliberate `prefix + q`.

The worker alias is a logical identity, not a physical network route. In
particular, `mini` remains the only worker identity stored in endpoint
registries, pane/window options, claims, handoff metadata, status output, and
resurrection state. The SSH layer may resolve that alias through different
routes without creating a second worker:

- On the Mini's LAN, `ssh mini` prefers the verified ordinary SSH listener at
  `Alfies-Mac-mini.local`.
- Away from that LAN, the same command falls back to the Mini's Tailscale IP.
- `mini-lan` remains an explicit diagnostic/maintenance alias, never a worker
  identity supplied to `rw ensure` or persisted in plugin state.

This selection is implemented in `ssh/.ssh/config`, below the plugin. All
plugin operations already call the logical alias through OpenSSH, so endpoint
creation, probes, handoff transfer, provider adapters, close, reconciliation,
and interactive attachment inherit the chosen route consistently. If route
availability changes during an attachment, the resulting transport drop is an
ordinary reconnect to the same remote tmux endpoint; it does not change worker
ownership or rebuild the endpoint under another identity.

Mosh is a deferred transport option, evaluated alongside Mutagen in
[`deferred-sync-and-transport.md`](./deferred-sync-and-transport.md).

Known artifact: an unclean inner-session end (dropped connection, killed
worker process) can leave the outer local pane with garbled mouse state
because the nested tmux never sent its cleanup sequences. Reconnect should
issue a reset/redraw on the local pane as part of recovery.

## Workspace placement

### Reflected worktree repositories

Reflection must be configuration-driven and support multiple repositories. It
must not contain content-engine-specific assumptions.

A host/repository configuration maps a relative focus path to a relative worker
path. For example:

```text
Focus:  ~/Developer/content-engine-trees/content-engine-4
Worker: ~/Developer/content-engine-trees/content-engine-4
```

The same mechanism must allow another repository to define its own numbered
slot root and pattern later.

The mapping uses each host's `$HOME`; absolute usernames are not shared.

Repository-specific setup remains eligible as a post-placement policy. Examples
include CocoaPods, Xcode preparation, port allocation, environment pulls, or
Git LFS materialization. Those policies must not be hard-coded into the generic
tmux transport.

### Non-reflected workers

For a worker without a reflected slot configuration:

- An ordinary non-repository pane starts in `$HOME` unless a path is supplied.
- A repository pane identifies the repository by normalized Git remote
  identity, not only by folder name.
- The system first looks for a managed workspace already associated with the
  same logical focus responsibility.
- Otherwise it creates an ad hoc workspace under a configurable worker-owned
  root.
- Workspaces belonging to different focus machines/users are namespaced.
- An intentional endpoint close may clean up an exclusively owned ad hoc
  checkout only under the proven-safe workspace policy. Crash/disconnect
  lifecycle never removes it.

## Persistent slot worktrees and ports

The reusable philosophy is documented concisely in
[`docs/worktree-slots.md`](../../worktree-slots.md). This section defines what
the implementation must provide for the remote-workspace system.

### Slot identity and naming

- Slot-enabled repositories are explicitly opted into the global dotfiles
  configuration.
- Each repository declares a collection parent and canonical repository name.
- Persistent worktrees use `<repo-name>-<positive-slot-number>`.
- A slot number identifies durable local infrastructure, not a permanent task,
  branch, agent, or tmux session.
- A task claims a slot temporarily and may later release it for another task.
- Port assignments and preparation tier remain stable across branch/task swaps.
- Reflected hosts use the same repository and slot identity. Git
  administration, caches, build outputs, and listeners remain host-local.

### Preparation tiers

Each opted-in repository defines named, idempotent preparation tiers in the
dotfiles configuration. For example:

- `light`: checkout plus minimal tooling.
- `warm`: routine dependencies and common build caches.
- `heavy`: scarce resources such as CocoaPods, Xcode/Simulator state, large
  Git LFS material, or expensive generated outputs.

The names and commands are repository policies in personal dotfiles, not
hard-coded universal meanings. Only selected slots receive expensive tiers.
Changing a task, branch, claim, or active writer host does not implicitly
downgrade or erase reusable slot resources.

### Deterministic port allocator

DECISION: the port formula is formalized as the scheme already in live use,
not the packed repository-base-plus-stride layout considered earlier:

```text
port = service_base + (slot_number - 1) * block_size
```

Each opted-in repository declares named services with an explicit per-service
base and one shared `block_size`. For content-engine:

```text
NEXT        base 3000
DASHBOARD   base 3010
ENGINE      base 7500
EXPO/METRO  base 8081   (one listener)
block_size  100
```

This preserves existing port muscle memory (developers already know `3000`,
`3010`, `7500`, `8081`); slots 1-4 are already correct under it.

Requirements:

- The central dotfiles registry still validates that every
  `service_base + (slot - 1) * block_size` value across a repository's
  declared slot capacity never collides within that repository, across
  repositories, or with prohibited/system/OS-ephemeral ranges.
- Each service's allocation reserves `slot_capacity * block_size`, so adding a
  new slot within capacity never reallocates existing ports.
- Expanding capacity must prove the adjacent range is free or perform an
  explicit reviewed migration. It cannot silently renumber live slots.
- The default mapping is identical across focus and reflected hosts. An
  explicit host override is permitted only for a demonstrated host conflict and
  is recorded as configuration, never chosen ad hoc at server start.
- Slot provisioning and `doctor` perform listener diagnostics. A port occupied
  by another allocation or unrelated process is a blocking diagnostic.
- A listener collision never causes fallback to a random free port. Stable
  mapping is part of the slot's identity.
- Every derived port must be valid, unique within the host configuration, and
  covered by its service's reservation.
- Only services with a real listener are registered. The current speculative
  `API_PORT`/`SERVER_PORT`/`METRO_PORT` fallback entries are not carried over
  into the formalized configuration.

DEFERRED (YAGNI, decided): dynamic base-pool negotiation. Repository/service
bases are hand-assigned lines in `config.json`; automatic pool arbitration is
only built when a second repository actually opts in and a real conflict
needs resolving.

The allocator renders `.worktree-slot.json` -- an ignored private manifest
recording repository identity, slot, tier, host, allocation generation, and
named ports -- plus, when the repository declares one, a ports file at the
filename the repository chose.

That filename is the repository's, not ours: it names a `ports_file` in its
`config.json` entry (content-engine: `.env.ports`), ignores that name in its
own `.gitignore`, and falls back to its own defaults when the file is absent,
so the same checkout works on CI, on a worker, and for anyone not running
these dotfiles. We write plain dotenv into it and nothing else. A repository
that declares no `ports_file` gets no ports file. Agents never hand-edit
assigned ports.

Port generation is idempotent. Re-running it for the same
repository/slot/host generation produces the same result.

### Minimal v1 command

V1 exposes one idempotent slot command:

```text
worktree-slot ensure [slot-number] [--tier <tier>] [--dry-run]
```

Repository opt-in, collection paths, service offsets, capacities, and default
slot tiers are edited deliberately in the dotfiles configuration rather than
through another command.

`ensure` owns the internal sequence:

1. Resolve the opted-in repository and slot from its argument or current path.
2. Allocate and persist the repository base if this is its first slot.
3. Create the missing `<repo-name>-N` worktree safely at the configured base
   revision, or validate the existing one without recreating it.
4. Validate name, path, Git worktree metadata, range capacity, service offsets,
   and active listeners.
5. Render the stable private manifest and environment.
6. Apply the configured tier idempotently when creation or an explicit
   promotion requires it.
7. Print a concise summary of path, tier, claim state, and named ports.

`--dry-run` performs resolution, derivation, validation, and summary without
creating or changing anything. This replaces separate list, ports, and doctor
commands for v1.

Claiming remains a separate responsibility operation. Creating a durable slot
does not permanently claim it, and claiming an existing slot does not recreate
or renumber it.

### Global agent rules for slot creation

Claude, Codex, and Pi global instruction files must state:

- For an opted-in slot repository, never create a persistent worktree with raw
  `git worktree add`; use `worktree-slot ensure`.
- Derive the repository and positive slot number from the configured collection
  and `<repo-name>-N` path. Never invent a second naming convention.
- Run slot validation/port rendering before dependency preparation or server
  startup.
- Never copy another slot's port file, infer ports from its current listeners,
  or hand-edit assigned port variables.
- A branch/task swap keeps the slot's ports and preparation tier.
- Promote a tier only when explicitly requested or required by configured slot
  policy; do not install heavy resources in every slot.
- Claim the slot for the current focus/tmux responsibility before managed
  edits.
- Treat repositories outside the opted-in registry as ordinary Git
  repositories.

### Content-engine inconsistency to replace

Current content-engine state has two incompatible derivations:

- Its GCP environment renderer uses `(slot - 1) * 100`.
- `scripts/sync-env-worktrees.ts` uses `slot - 1`.

The live worktree pool consequently contains both schemes. The global allocator
must replace both as the only authority for slot ports. Content-engine may keep
portable application support for environment-provided port variables, but it
must not retain a second numbered-worktree port formula.

Verified live damage: 8 of the 15 existing slots carry ports corrupted by the
linear `slot - 1` formula, apparently from an `env:sync:worktrees` run against
slot 1. Concretely, claimed slot pairs 10/11 and 12/13 currently share
identical dev-server ports: slots 10 and 11 both render
`NEXT_PORT=4000/DASHBOARD=4010/ENGINE=8500/EXPO=9081`, and slots 12 and 13 both
render `NEXT=4200/DASHBOARD=4210/ENGINE=8700/EXPO=9281`. Per `config.json`'s
declared bases, the correct values are slot 10 to 3900, 11 to 4000, 12 to
4100, and 13 to 4200 — so slots 10 and 12 are the ones actually wrong; 11 and
13 already hold their correct values, which is why the pairs collide rather
than both being visibly broken.

DECISION, revised: `scripts/sync-env-worktrees.ts` is being kept, not
deleted — it covers a real gap (non-port secrets) the global allocator
doesn't render. See "Content-engine follow-up" near the end of the
smoke-testing section for why, and for the authoritative remaining checklist
(port repair on slots 10/12, per-slot marker migration, Playwright port
conversion). None of that is bundled into a PR — it's live-state operator
work, one-time and not urgent, but not part of the code-retirement PR
(#431) that already shipped. The first `worktree-slot ensure` run against
slots 10/12 will legitimately block on the listener/collision diagnostic
until remediated — expected, per the blocking-diagnostic rule above, not a
bug in the allocator.

Supabase ruling and user intent: the local Supabase stack is a repository-wide
singleton — identical `project_id` and ports in every slot. It is an accepted
v1 limitation that only one slot can run it at a time; the slot system does
not attempt to scale local Supabase per slot. User intent: the local
singleton should ideally always track `origin/main` schema; development and
migration trials use cloud Supabase DB branches (`pnpm branch`) instead. This
is the standing rule for all autonomous agents running in parallel
worktrees/tasks, so that migrations never collide locally.

## Workspace synchronization and handoff

### Correctness model

The first implementation should use an explicit transactional handoff. A
handoff makes the destination the active writer and records a synchronization
generation.

The design must not require a user to commit and push merely to move current
work to a worker.

The design must not blindly run `git pull` before reproducing dirty work.
Pulling can change the base under staged and unstaged changes.

The handoff must be capable of preserving:

- Exact source commit, including locally committed but unpushed commits.
- Current branch identity.
- Staged tracked changes.
- Unstaged tracked changes.
- Tracked deletions and renames.
- Untracked, non-ignored files.
- Changed or unmaterialized Git LFS content where applicable.
- Selected ignored files only through explicit repository/host policy.

The destination must keep valid host-local Git metadata. `.git` directories,
linked-worktree gitfiles, indexes, locks, and host-specific worktree
administration are never filesystem-synchronized.

Before overwriting an existing managed destination, the handoff creates a
recoverable snapshot and verifies that the destination has not diverged from
the last known generation without an explicit resolution.

### Bidirectionality

- Focus-to-worker handoff is required.
- Worker-to-focus return handoff is required.
- "Local-first" describes the default and origin, not a permanent one-way data
  flow.
- A return handoff follows the same safety and backup rules as an outward
  handoff.
- If both sides have diverged, the system preserves both and refuses silent
  last-writer-wins replacement.

### Continuous synchronization

Continuous synchronization is deliberately deferred. V1 implements only an
explicit transactional handoff and return handoff so correctness, Git state,
claims, and agent resume can be proven without a live synchronization process.

Mutagen is free and relatively simple to install for SSH use, but it will only
be pursued if real handoff-mode pain points justify it. Its feasibility,
licensing details, Git caveats, and future acceptance criteria — alongside the
Mosh transport option (see "Transport" above) — live in
[`deferred-sync-and-transport.md`](./deferred-sync-and-transport.md).

The v1 implementation should avoid speculative watch-mode machinery beyond
keeping workspace identity and handoff operations modular enough that a future
evaluation is possible.

## Local-first AI coding-agent handoff

### Required behavior

Most AI coding sessions begin locally. The system must support elevating an
existing local Claude, Codex, or Pi session to a worker.

For each supported provider, handoff must:

1. Detect the running provider and session identifier using the existing
   provider hooks/state where possible.
2. Discover the exact transcript/session storage required for resume.
3. Compare the local and worker CLI versions during preflight, before any
   state is touched.
4. Apply the version policy: identical versions proceed; a newer worker CLI
   resuming an older transcript proceeds with a notice (this is the ordinary
   provider upgrade path); a worker CLI older than local blocks the handoff
   with the exact update command to run on the worker. The plugin never
   performs the update itself (consume, never provision).
5. Transfer the minimum provider session state needed for resume, excluding
   authentication state.
6. Register/place that state in the worker-side project directory or provider
   storage location so the session is eligible for direct resume there.
7. Start the provider-specific resume command in the remote endpoint.
8. Preserve enough lineage and backup data for a later return handoff.

Version matching belongs to an internal adapter script in this package, not to
manual user memory.

DECISION: handoff stops the source agent by default. An explicit
`--keep-local` flag leaves it running and, in that case, records the
transcript-divergence risk described below.

Handoff is transactionally ordered so failure never strands the user:

1. Preflight the worker first — provider CLI present, version policy
   satisfied, workspace reachable. A preflight failure aborts the handoff
   with a precise remediation message while the local agent continues
   running, untouched. `--keep-local` is never needed as a hedge against
   preflight failures; it exists only for deliberately running both sides.
2. Snapshot, transfer, and verify worker-side resume eligibility.
3. Start the provider resume command in the remote endpoint.
4. Stop the local agent (default) only after the remote resume has started
   successfully. Stopping last adds no divergence risk beyond what the
   snapshot boundary already implies — anything typed locally after the
   snapshot is divergent regardless of when local stops.
5. If any step fails, the local agent has not been stopped, the handoff
   reports the failure, and any partially copied remote state is inert.

### Mid-turn handoff

A handoff is not required to wait for an idle or completed turn.

The user invoking a mid-turn handoff accepts that the remote resume point may
only include data the provider had flushed at the time of the snapshot.

The implementation copies the most recently available provider snapshot and
uses ordinary provider-specific resume behavior. It does not wait for a safe
turn boundary, analyze or report an in-flight tail, or introduce special
mid-turn diagnostics. Choosing an appropriate handoff moment is developer
discipline.

### Concurrent resumes and transcript divergence

The system should prevent its own remote handoff command from launching two
managed writers for the same logical agent session.

Provider-native behavior may provide additional protection, but the design does
not assume every provider will do so.

If the local process continues after a mid-turn handoff, the system must record
potential divergence. It must not later merge two independently appended
provider transcripts by blind rsync.

Return handoff selects or verifies an authoritative lineage and keeps a backup
of the other lineage when necessary.

Where available, adapters lean on provider-native forking — `claude
--fork-session`, `codex fork`, `pi --fork` — to preserve diverged lineages,
rather than building bespoke copy-and-track bookkeeping on top of the raw
transcript files.

### Authentication

- Authentication state is not synchronized.
- The remote provider may prompt for login or fail naturally if it is not
  authenticated.
- Authentication readiness is not a reason to corrupt, skip, or rewrite the
  transferred transcript.
- Version and transcript eligibility checks should run before opening the
  remote agent where possible.
- The user may log in or update the worker interactively and retry.

### Vendor-independent operation

- No AI vendor's hosted remote-control service is a dependency.
- Provider CLIs and their locally persisted resumable session formats are the
  integration boundary.
- Each provider adapter is version-aware because private session formats may
  change.
- Provider adapters must have smoke tests that prove a transferred transcript
  can be resumed from the corresponding destination directory.

### Provider notes

Verified facts, provider by provider:

- **Pi**: `pi --session <path>` accepts an arbitrary session file path, so no
  destination directory-encoding mimicry is needed at all — the transcript
  file can be copied anywhere and resumed by path. This is expected to remain
  the simplest adapter.
- **Claude**: the transcript must be placed under a directory whose name
  encodes the *destination* absolute project path (slashes replaced with
  dashes) beneath `~/.claude/projects/`. Seeding the matching per-path trust
  entry in `~/.claude.json` avoids a trust prompt but is not resume-blocking —
  a nice-to-have, out of the minimal adapter, not a requirement for it.
- **Codex**: resume is driven by a private SQLite `threads` table in
  `~/.codex/state_5.sqlite`, with rows 1:1 against rollout files, indexed by
  cwd; no filesystem watcher was observed picking up new rollout files on its
  own. A copied rollout file alone is therefore likely invisible to resume.
  The Codex adapter is gated on a live smoke test — does direct-ID resume work
  without a corresponding `threads` row? — before it is built out further.
  `CODEX_HOME` override is available if sandboxing the smoke test is useful.

Version facts: Claude ships side-by-side native versioned installs under
`~/.local/share/claude/versions`. Codex and Pi are npm packages managed under
fnm. Version alignment for Codex/Pi therefore means matching Node plus a
pinned npm install; `codex doctor` reports install consistency.

DECISION (ordering): Phase 5 implements adapters in the order Pi, then Claude,
then Codex. The Codex adapter may slip to a follow-up task if its smoke test
result is bad, without blocking delivery of the other two.

## Worktree claims and editing ownership

### User intent

When a tmux session corresponds to a worktree, that relationship should be
obvious to other sessions and agents. A session represents a responsibility
area or parallel task, and another session should not casually hijack its
worktree.

This applies across repositories, not only content-engine.

The existing content-engine `.worktree-claim` system is useful prior art but
currently mixes:

- Generic ownership: holder, branch, tmux session, claim/release/status.
- Content-engine policy: numbered slot naming, fixed port derivation,
  staging-lane environment pull, and package-specific commands.

### Candidate global model

Extract a generic, dotfiles-owned claim capability that any Git repository may
use when desired.

A generic claim should be able to record:

- Stable claim ID.
- Canonical repository identity.
- Worktree path/identity.
- Responsibility or task label.
- Owning user.
- Owning focus-machine identity.
- Owning stable tmux session identity and human session name.
- Optional window/pane/endpoint identity.
- Branch and base commit.
- Active writer host.
- Handoff/synchronization generation.
- Created and updated times.
- State such as local, handed-off, returning, conflicted, or released.

Verified facts constraining two of the fields above:

- Repository identity must be the normalized Git remote, not `package.json`
  name. The prior-art content-engine claim system keys on `package.json`
  name, which fails for non-Node repositories, including dotfiles itself.
- A stable tmux session identity does not exist anywhere today. The prior-art
  system captures tmux's renameable `#S`, which is not durable. A durable
  session UUID (a `session-created` hook plus registry entry) is net-new and
  is a Phase 2 build item shared by both claims and endpoints, not something
  claims can assume already exists.

The important distinction is:

- **Responsibility owner**: the logical focus/tmux session that owns the work.
- **Active writer host**: the host currently expected to edit/run that
  workspace.

A remote handoff may change the active writer host without changing the
responsibility owner.

### How the two-level lock meets the workflow

Every managed editor or Git operation has a caller identity:

```text
caller responsibility = focus-machine-id + stable tmux-session-id
caller execution host  = current machine identity
```

It may mutate a claimed worktree only when both are true:

```text
caller responsibility == claim.responsibility_owner
caller execution host  == claim.active_writer_host
```

Example:

| Situation | Responsibility match | Host match | May write? |
| --- | --- | --- | --- |
| Owning `dotfiles` session on laptop before handoff | yes | yes | yes |
| Another laptop tmux session opens that worktree | no | yes | no |
| `dotfiles` is handed off to `mini` and its mapped endpoint edits there | yes | yes | yes |
| Original laptop process tries to keep editing after that handoff | yes | no | no |
| Unrelated session or endpoint on `mini` opens the reflected slot | no | yes | no |
| Work is returned to the laptop and the old Mini process attempts a write | yes | no | no |

The remote endpoint inherits the stable focus-session identity; its generated
remote tmux session name is not treated as a new responsibility owner. This is
how the original local responsibility continues remotely without another local
session or another machine hijacking it.

Claims are optional. A tmux session that is not associated with a configured
worktree has no worktree lock. Claiming is activated when a responsibility
chooses/creates a managed worktree or explicitly claims an existing one.

### Visibility and storage

Recommended design:

- A `.worktree-claim` file in the worktree is highly visible to humans and
  agents.
- A private registry under `~/.local/state` supports richer indexing and is the
  authoritative state.
- Use a hybrid: a small visible ignored marker plus the authoritative private
  registry on each participating host.

If `.worktree-claim` remains:

- Dotfiles can globally ignore it instead of requiring every repository to
  modify `.gitignore`.
- Handoff transfers/updates it as coordination metadata, not as ordinary user
  source.
- A generation number prevents an older copied marker from replacing a newer
  claim.

### Enforcement surfaces

The system should enforce the claim where it has a trustworthy caller identity,
while making its limits explicit.

1. **Tmux and handoff commands:** claim, handoff, return, endpoint launch, and
   release operations validate both responsibility and host. These are hard
   failures on mismatch.
2. **AI provider hooks:** global Claude, Codex, and Pi integrations pass the
   focus/session/host identity to the claim checker before file-changing tools
   where the provider exposes a suitable hook. A mismatch blocks that managed
   agent write.
3. **Global agent instructions:** every supported agent is told to inspect the
   visible claim before editing. This covers provider versions or operations
   for which a blocking hook is unavailable, but is advisory rather than a
   security boundary.
4. **Git guards:** an interoperable dispatcher may block commit, merge, rebase,
   and push when responsibility or host does not match. It must chain, not
   replace, repository-owned hooks.
5. **Human/raw processes:** a shell command, editor, or arbitrary program can
   write files without invoking Git or an AI-provider hook. Preventing that
   would require filesystem permissions, containers, or invasive command
   wrappers and is not required for the personal v1 workflow.

Enforcement reality check: zero blocking hooks exist today in any repository —
current claim guidance is prose only, enforced by nothing. The provider-hook
`verify-writer` layer described above is therefore net-new invention, not an
extension of an existing mechanism, and is the highest-uncertainty part of
Phase 3. The staged rollout already described in this section (hard
enforcement where a blocking hook demonstrably exists, advisory instructions
elsewhere) stands as the mitigation for that uncertainty.

The first implementation should deliver hard enforcement in the tmux/handoff
control path and in provider hooks that demonstrably support blocking. Git
guards follow only after a chaining strategy has been smoke-tested. It must not
claim to have a universal filesystem lock.

Network partitions also mean a copied file alone cannot provide perfect
distributed locking. The personal single-focus-machine design can use the focus
registry as the authority and use generation-checked remote updates. If the
focus machine cannot confirm a handoff, the destination does not acquire the
writer lease. A multi-focus/team system would require stronger shared
coordination or explicit stale-lock takeover.

### Global dotfiles distribution

The slot and claim system is a personal cross-repository development primitive
and must be installed entirely from dotfiles. Repository checkouts are
consumers, not owners, of the implementation.

Proposed dotfiles ownership:

```text
worktrees/
├── .config/worktrees/config.json
├── .local/bin/worktree-claim
└── .local/bin/worktree-slot

claude/.claude/CLAUDE.md
claude/.claude/settings.json
codex/.codex/AGENTS.md
codex/.codex/hooks.json
pi/.pi/agent/AGENTS.md
pi/.pi/agent/extensions/worktrees.ts
```

Installed global instruction locations:

| Provider | Dotfiles source | Installed location | Purpose |
| --- | --- | --- | --- |
| Claude | `claude/.claude/CLAUDE.md` | `~/.claude/CLAUDE.md` | Global personal claim rules |
| Codex | `codex/.codex/AGENTS.md` | `~/.codex/AGENTS.md` | Global personal claim rules |
| Pi | `pi/.pi/agent/AGENTS.md` | `~/.pi/agent/AGENTS.md` | Global personal claim rules |

The Markdown rules make the workflow clear to every newly started agent:

- Detect whether the current repository is opted into persistent slots.
- Use `worktree-slot ensure` for persistent slot creation, validation, port
  rendering, and tier preparation.
- Detect whether the current Git worktree has a claim.
- Resolve the current focus-machine, stable tmux-session, and execution-host
  identities.
- Call `worktree-claim verify-writer` before making managed edits or Git
  mutations.
- Refuse the operation when either the responsibility owner or active writer
  host does not match.
- Never steal or overwrite a claim; use explicit handoff, return, release, or
  approved takeover operations.
- Treat unclaimed and non-opted-in repositories normally.

Markdown remains behavioral guidance, not enforcement. Claude settings hooks,
Codex hooks, and the Pi extension call the same global `verify-writer`
executable at supported file-changing lifecycle points. This keeps provider
logic thin and ensures all providers evaluate the same claim registry.

`config.json` is the personal registry of opted-in repositories, collection
paths, port pools/allocations, services, slot capacity, preparation tiers, and
claim policies. It may describe content-engine and other repositories later
without putting personal orchestration rules in those repositories.

### Relationship to content-engine

Extraction fact: content-engine's `worktree-claim.ts` was a self-contained
356 lines, roughly 90% generic, with its only content-engine coupling a
single `env:pull` invocation — so claim-mechanics extraction was low-risk,
and it shipped as one PR: https://github.com/kalem-edlin/content-engine/pull/431
(`chore/retire-worktree-claim`, in review as of 2026-08-02). It deletes
`worktree-claim.ts` and its three `package.json` scripts outright, drops the
redundant `.worktree-claim` gitignore entry, and points `AGENTS.md` and
`env-rendering.md` at the global dotfiles rules instead of restating them.
`scripts/sync-env-worktrees.ts` was kept, not deleted — see "Content-engine
follow-up" below for why.

This separation prevents collaborators from inheriting a tmux/worktree process
they did not choose, while allowing the same personal claim system to work
across content-engine and any future opted-in repository.

The remaining live-state work (port repair, per-slot marker migration) is not
a PR at all — it's tracked in "Content-engine follow-up: a separate PR" near
the end of the smoke-testing section, which is the authority on what remains.

### Relationship to workmux

`workmux` is valuable prior art for coupling a worktree lifecycle to terminal
and agent lifecycle.

It is not automatically a better fit for this intent because:

- Not every tmux session corresponds to a worktree.
- Existing persistent numbered slots must be supported.
- Work may begin in an already-established local session/worktree.
- Cross-host reflection, dirty-state transfer, and agent transcript handoff are
  required.
- Claiming should be usable without requiring workmux to create or own every
  tmux window.

The likely direction is to borrow lifecycle and status ideas while keeping a
smaller optional claim layer. This remains a discussion decision rather than a
final rejection of workmux.

## Ephemeral sub-agent worktrees

User intent: provider built-in worktree features — for example Claude Code's
`.claude/worktrees/agent-*` mechanism — are not the authority for worktree
creation or management in managed repositories. "Claude is not the authority
on worktree creation/management. Repo specific md files / this handoff system
is — as well as repos that use the slot system." Authority belongs to
repo-specific instruction files and to this system (slots plus claims) for
opted-in repositories. Global agent rules must direct agents away from
provider-native worktree mechanisms in opted-in repos.

This surfaces a third worktree category, distinct from persistent slots and ad
hoc worker workspaces: when an agent working a single slot task fans out into
sub-agents, those sub-agents will likely need separate, completely ephemeral
worktrees of their own to reduce overlap risk — one host agent working one
slot, but several sub-agents that must not step on each other's edits inside
that same worktree. User intent: "We must think of this."

Requirements for this category (conventions decided; convention-only in v1):

- Created under `<collection>/.eph/<slot>-<task-slug>-<n>`. The dot-prefixed
  directory keeps ephemeral worktrees visually and glob-wise separate from
  numbered slots.
- Branches are prefixed `eph/`.
- Raw `git worktree add` is permitted in opted-in repositories only under
  `.eph/`.
- No slot numbers and no port allocations — ephemeral sub-agent worktrees must
  not start slot services.
- No claims.
- Never reflected to a worker and never handoff-eligible.
- Lifecycle owned and cleaned up by the spawning session/agent via
  `git worktree remove` when the parent task completes; outside the slot
  system entirely.
- `worktree-slot ensure --dry-run`/`doctor` lists leftover `.eph` entries as
  an on-demand report — visible when asked, never a notification, and never
  garbage-collected.

A helper command is deliberately deferred until the convention demonstrates
friction in real use.

## Headless platform differences

The tmux remote-workspace model should treat workers uniformly whenever
possible. The user should not need to care whether a selected worker is macOS
or Linux for ordinary SSH, tmux, Git, shell, editor, or agent handoff.

The OS difference matters only to `setup-headless` when installing packages or
resolving executable paths. The remote-workspace plugin does not provision or
model Xcode, Simulator, signing, keychain, CocoaPods, or similar machine-local
tooling. Those may be prepared manually through an ordinary SSH or remote
screen-sharing session.

The wider dotfiles concern is ensuring `setup-headless` produces the same
remote-workspace contract on both platforms. No general capability scheduler
is part of initial scope.

## Status line, clipboard, and input

- Remote host display comes from explicit pane metadata, not process
  scraping. Concretely, this is net-new work: a pane-scoped user option (for
  example `@remote-host`) set at endpoint attach, plus a status-line format
  conditional that falls back to the local hostname when the option is unset.
  The pane-scoped `tmux set-option -pqt` pattern this needs is already proven
  in `zsh/.zsh/tmux-workspace-resurrect.zsh`.
- The host indicator must continue to show the focus-machine hostname for local
  panes.
- Remote Neovim should use OSC 52 or an equivalent supported path so explicit
  system-clipboard yanks reach the focus terminal. This path already exists
  and is reusable: `tmux/tmux.conf:4,14,15` plus `tmux/scripts/yank.sh`, which
  wraps the OSC 52 sequence in a DCS passthrough when `$SSH_TTY` is set. Both
  the worker's and the focus machine's tmux layers need
  `allow-passthrough on`, and the outer terminal emulator's clipboard-access
  setting is a `doctor`-check item. The OSC 52 payload has a known cap of
  roughly 74KB; larger yanks silently fail to reach the terminal.
- Local terminal paste should continue to enter the remote application.
- Ordinary Vim registers remain process-local; this is acceptable.
- Pending input and TUI state survive connection loss primarily because the
  remote process remains inside remote tmux.

## Configuration and extensibility

The new feature should live in a separate dotfiles-owned plugin rather than
turning `tmux-workspace-resurrect` into a monolith:

```text
tmux/local-plugins/tmux-remote-workspaces/
├── tmux-remote-workspaces.tmux
├── config.json
├── README.md
├── scripts/
├── libexec/
├── adapters/
│   ├── claude
│   ├── codex
│   └── pi
└── sync/
    └── handoff
```

The exact directory layout may evolve, but ownership boundaries should remain:

- `tmux-remote-workspaces`: endpoint registry, SSH attach/reconnect, workspace
  mapping, handoff orchestration, claims integration, and agent adapters.
- `tmux-workspace-resurrect`: host-local tmux/application state capture and
  restoration.
- `ssh`: SSH alias and transport configuration.
- `setup-headless`: packages, platform service installation, and validation.
- Provider dotfile packages: provider-owned hook declarations and global agent
  instructions.
- Runtime state: private files under XDG state/data paths, never committed.

The configuration must support adding new reflected repositories without code
changes.

## Observability

V1 writes a minimal append-only event log: jsonl under the XDG state
directory, local only, never committed, no telemetry. It records endpoint
create/attach/reconnect/close events and handoff/return events, each with a
timestamp, duration, and outcome.

Purpose: a debugging trail for reconciliation, and the evidence base for the
deferred Mutagen/Mosh gate. "Repeated manual handoffs are measurably
disruptive" becomes something the log can show, rather than something argued
anecdotally.

## Team and future extraction

The first implementation is personal and assumes one primary focus machine.

Its identifiers should nevertheless namespace:

- User.
- Focus machine.
- Logical responsibility/session.
- Workspace.
- Endpoint.

This permits multiple focus machines to share one worker for non-overlapping
work without session-name collisions.

A company-grade version would additionally require centralized identity,
authorization, secrets, audit, workspace quotas, and stronger distributed
locking. Those are not dotfiles requirements.

The dotfiles implementation should keep a clean registry/adapter boundary so
the core could later be extracted without making team-scale concerns block the
personal workflow.

## Conflicts between literal intent and safer requirements

These are intentional adjustments, not dismissals of the user's goals.

### "Mirror" versus independent writers

Literal bidirectional simultaneous writing can create Git, filesystem, and
agent transcript conflicts. The initial solution uses explicit active-writer
handoff while retaining a future conflict-aware watch mode.

This preserves uncommitted work movement without requiring administrative Git
commits.

### Exact mid-turn agent state

The user may hand off mid-turn and should not be blocked. A provider cannot
resume bytes it never persisted. The system simply copies the most recently
available snapshot. Handoff timing is developer intent, not a workflow the
plugin needs to police or diagnose.

### Endpoint lifetime

An intentional `prefix + q` closes the local pane and mirrored remote endpoint.
Infrastructure loss does not. Tombstones plus post-resurrection reconciliation
distinguish those cases and dispose only endpoints that the completed restore
proves no longer have local equivalents.

### Automatic cleanup

Age-based garbage collection remains out of scope. Deterministic disposal of an
intentionally closed or no-longer-restored mirror is required and is not
considered garbage collection.

### Platform capability model

The Mini's Darwin/Xcode distinction is a setup detail, not a user-facing
restriction on the tmux workflow. Initial scope keeps host metadata small and
does not build a general scheduler.

## Implementation phases

### Phase 0: persist and approve requirements

- Discuss the open decisions in this document.
- Update this document with resulting decisions.
- Do not implement against assumptions that contradict local-first handoff.

### Phase 1: headless durability and transport foundation

- Finish/deploy the existing `tmux-workspace-resurrect` work.
- Make noninteractive shell startup safe.
- Validate Claude, Codex, Pi, tmux, Git, Git LFS, and required paths on workers.
- Install and validate Continuum's five-minute save behavior on workers.
- Save immediately through a tmux hook when the last remote client detaches.
- Restore remote tmux on demand when reconnecting after reboot.
- Build endpoint identity, registry, attach, reconnect, and `ensure`.
- Add explicit remote-host status.
- Fix `zsh/.zshrc:1-4`'s unconditional `exec > /dev/tty` by gating it on an
  interactive shell, for noninteractive SSH safety.
- Make `ssh/.ssh/config` cross-platform: `UseKeychain` is macOS-only and is
  currently set in `Host *`; guard it via `Match exec`/`IgnoreUnknown` or a
  platform-specific include before stowing this config on Linux.
- Add `~/.local/bin` to `PATH` in both `zshenv` and `zshrc` so hook-invoked
  executables resolve in noninteractive/non-login shell contexts.
- Add `ControlMaster`/`ControlPersist` and `ServerAlive*` SSH settings.
- Install the worker save timer (`launchd`/systemd) via `setup-headless`.
- Implement the consume-never-provision preflight checks.
- Start the observability event log.
- Verification: resolved. As of 2026-08-01, `ssh/.ssh/config` uses `User
  admin` (with NOPASSWD sudo) for both the Tailscale and LAN Mini blocks as
  the intended identity/namespace root.

### Phase 2: pane/window behavior and resurrection integration

- Persist stable focus/session/window/pane UUIDs.
- Assign a worker to a pane/window.
- Inherit worker/workspace on split.
- Keep new windows local by default.
- Reattach remembered endpoints on laptop restore.
- Invoke remote resurrection or declarative endpoint rebuild when needed.
- Route `prefix + q` through an intent-aware close operation.
- Persist close tombstones before terminating remote endpoints.
- Reconcile and close owned remote endpoints missing from a completed local
  resurrection.
- Confirm crashes and server restarts do not look like intentional closes.
- Add the pane-option restore opt-out seam to `tmux-workspace-resurrect` so it
  never pastes a stale command into a plugin-managed pane.
- Define UUID re-resolution across restore/renumber, with the endpoint
  registry authoritative and pane `@vars` treated as cache only.

### Phase 3: global worktree slots and claims

- Design generic claim schema and storage.
- Add the global `worktrees` dotfiles provider plus `worktree-slot` and
  `worktree-claim` executables.
- Implement manual repository opt-in through configuration and the idempotent
  `worktree-slot ensure` flow.
- Implement the central deterministic port allocator, private manifest/env
  rendering, listener diagnostics, and idempotence tests.
- Fold collection/name validation, persistent slot creation, port rendering,
  diagnostics, summary, and repository-configured tier preparation into
  `ensure`.
- Install global Claude, Codex, and Pi instruction files.
- Add slot-creation rules and provider hooks/extensions that call the common
  writer verifier.
- Add personal repository policies to the dotfiles configuration.
- Completely remove the personal claim implementation and directives from
  content-engine.
- Remove content-engine's competing numbered-worktree port derivations after
  verifying the global environment seam.
- Preserve content-engine's genuine repository setup and environment-variable
  consumption commands.
- Do not require claims for tmux sessions that have no worktree.
- Fold the content-engine port-repair, legacy claim migration, and
  script/doc-reference deletion into this extraction PR.
- Update global agent rules to exclude provider-native worktree mechanisms in
  opted-in repositories and to describe ephemeral sub-agent worktree
  conventions.

### Phase 4: reflected workspace handoff

- Add configuration for multiple reflected repositories.
- Implement exact Git/base/state transfer with destination backup.
- Handle unpushed commits and LFS.
- Implement return handoff.
- Validate on a disposable repository before a real dirty slot.

### Phase 5: local-first agent handoff

- Implement common version comparison/alignment.
- Implement Pi transcript eligibility and resume.
- Implement Claude transcript eligibility and resume.
- Implement Codex transcript registration and resume, gated on its smoke test;
  may slip to a follow-up task without blocking Pi or Claude.
- Implement reverse handoff and divergence preservation.
- Smoke-test every supported provider across laptop and worker.

### Phase 6: ad hoc worker workspaces

- Discover or create non-reflected workspaces.
- Namespace by focus machine and responsibility.
- Add explicit status/archive/remove commands.
- Keep all cleanup manual.

### Deferred: continuous watch and Mosh transport

- Do not implement until handoff-mode use demonstrates specific pain.
- Evaluate against the acceptance criteria in
  [`deferred-sync-and-transport.md`](./deferred-sync-and-transport.md).

## Resolved decisions

1. Handoff stops the source agent by default; `--keep-local` is the explicit
   opt-out.
2. V1 assigns panes one at a time and sets a window default for future
   splits, rather than transactionally reassigning every pane in a window at
   once — this matches the pane-based ownership model.
3. An orphaned ad hoc checkout with unsynchronized work is retained
   indefinitely and surfaced in status. It is never auto-removed.
4. The port scheme is the formalized per-service-base-plus-`block_size` model
   with hand-assigned bases (see "Deterministic port allocator").
5. Command vocabulary is `rw ensure | handoff | return | close | status |
   doctor`. There is no user-facing attach/reconnect verb: reconnection is
   automatic through the retry loop, and `ensure` is idempotent, so
   establishing and manually re-establishing an endpoint are the same verb.
   `doctor` hosts the consume-never-provision preflight report.
6. Ephemeral sub-agent worktrees are convention-only in v1 (see "Ephemeral
   sub-agent worktrees" for the decided conventions); a helper command is
   deferred until the convention shows friction.
7. The allowed slot-service port pool is everything below 32768 (the Linux
   ephemeral floor; macOS's is 49152) minus a prohibited list including macOS
   AirPlay (5000, 7000), Postgres (5432), and the local Supabase singleton
   block. Content-engine declares slot capacity 20; its bases top out around
   10,081, comfortably inside the pool. A confirmation `sysctl`/listener
   probe on the Mini and one Linux worker remains a Phase 3 configuration
   step, not an open design question.

## Open decisions for discussion

1. What is the outcome of the client-detached-on-TCP-drop smoke test (see
   "Remote-side tmux durability")? Empirical Phase 1 result; the design does
   not depend on the answer — the worker save timer is the correctness net
   and the hook is only a fast-path optimization.

## Implementation record (2026-07-31)

Implemented dotfiles-side by a multi-agent build reviewed against this
document. Everything in Phases 1-5 that can exist in this repository now
does; Phase 6's ad hoc workspace discovery/creation is implemented inside
`rw ensure` (workspace placement), with cleanup deliberately manual per
Resolved decisions 3 and 5 (no archive/remove verbs in the v1 vocabulary).

Defensible deviations from the letter of this plan:

- Remote endpoint sessions are named `rw-<machine-short>-<endpoint-id>`
  (dashes), not the dotted form sketched earlier: tmux silently rewrites
  `.` in session names to `_` because `.` is target syntax, so a dotted
  convention can never round-trip through `has-session`/`list-sessions`.
  Discovered empirically against tmux; the code comments now anchor this to
  tmux 3.7b (`tmux-remote-workspaces.tmux:29`, `rw-post-restore.sh:136`). See
  "Headless worker provisioning results (2026-08-02)" below for the related
  tmux >= 3.7 control-character sanitization work this same version surfaced.

Verified results that close items this document left open:

- The Codex resume smoke test was RUN (sandboxed `CODEX_HOME`) and passed:
  Codex auto-backfills its private `threads` table from rollout files on
  disk, keying `cwd` from the rollout's own embedded `payload.cwd` (not
  `-C`). The Codex adapter therefore rewrites `payload.cwd` on install and
  is de-gated; it never touches `state_5.sqlite` directly. Remaining
  caveat: a full interactive `codex resume` (TTY + auth) has not been
  exercised. Once Codex is authenticated, the agent-first smoke plan below
  runs it in a disposable tmux PTY and verifies it automatically; this is an
  authentication readiness gate, not a permanently manual smoke step.
- The worker save timer (launchd/systemd user timer invoking
  tmux-resurrect's own save entrypoint) is implemented and was verified to
  drive the entire save chain with no attached client and `$TMUX` unset.

### Adversarial audit and fix round (2026-07-31)

After the build waves, an independent completeness audit cross-referenced
every requirement bullet against the code and ran the read-only commands
live. It confirmed the crash-safety core (tombstone ordering,
namespace-scoped reconciliation, identity/state contracts, provider exit
codes) held up under adversarial reading, and surfaced findings that were
all subsequently fixed and re-verified:

- BLOCKER (fixed): `rw handoff` stopped the local agent without checking
  that the remote resume dispatch succeeded. Now the dispatch exit status
  is checked AND the provider process is observed running in the endpoint
  session before the local agent is stopped; any failure leaves the local
  agent untouched (the plan's transactional step 5, now actually enforced,
  in both directions).
- Claims are now enforced at endpoint launch (`rw ensure` runs
  `verify-writer`; blocks on 10/11/13), not only at handoff/return.
- A duplicate managed-writer guard blocks a second handoff of the same
  provider+session (including after `--keep-local`).
- Window-level default worker/workspace options now back split
  inheritance (Resolved decision 2's window-default half; the rejected
  promote-all-panes command was not built).
- Divergent returns use provider-native forking (`resume-cmd --fork`).
- `libexec/adapters/smoke-test`: runnable sandboxed export→install
  round-trip assertions per provider (the plan's adapter smoke-test
  requirement as an artifact, 11/11 passing).
- The newer-worker version notice is surfaced; `rw return` gained the
  mirror-image version gate (runs before transfer).
- INTERIM BEHAVIOR (deliberate): legacy content-engine claim markers
  (key=value/colon formats, still live on unmigrated slots) are detected
  and labeled "legacy claim marker (unmigrated)" in status/doctor with a
  stderr warning from `verify-writer` — but do NOT block writes. Blocking
  would break current daily workflows, and the legacy system enforced
  nothing either. Real enforcement over those slots begins with the
  content-engine migration PR (see "Content-engine follow-up: a separate
  PR" near the end of the smoke-testing section for exactly what that PR
  must do).
- Also fixed: state-dir override consistency, a `--dry-run` write leak,
  proactive git-host auth preflight, and five stale doc/doctor surfaces
  that described finished work as stubs.

Known latent gaps, accepted for v1 and left visible here:

- The local-agent stop locates the agent as the deepest child of the pane
  process; an agent `exec`'d directly into the pane has no child and the
  stop silently no-ops (handoff still succeeds; both copies then run —
  same posture as `--keep-local` but without the recorded flag).
- The attach loop's success heuristic (exit 0 + >2s connected) and its
  backoff-reset behavior are untested against real network timing.
- Legacy-marker detection is "is it valid JSON" — sufficient for both
  known real-world legacy formats.

### Location-aware Mini routing (2026-08-01)

Live latency investigation established that the same Mini needs a low-latency
LAN route when on-premise and a Tailscale route everywhere else. OpenSSH now
keeps `mini` as the single public/logical alias and conditionally selects the
LAN listener when reachable, falling back to Tailscale otherwise. The
remote-workspaces implementation requires no duplicate worker configuration:
every SSH call already goes through the logical alias. `mini-lan` is retained
only for explicit diagnostics and recovery.

### Remote-aware Treemux dispatch (2026-08-01)

Upstream Treemux derives its root from the tmux server-local
`#{pane_current_path}`, starts its Neovim sidebar in that directory, and polls
the main pane's local process cwd. A focus-machine pane displaying an attached
worker endpoint is still locally an `ssh`/attach-loop process, so running
Treemux in the outer server cannot discover or safely act on a remote cwd.

Implemented `prefix + Tab` dispatches by pane ownership. Local panes retain the
upstream local Treemux path. An `@rw-endpoint` pane resolves its registry worker
and endpoint session, then invokes the worker's own Treemux against that
session's active pane. This also preserves Treemux's sidebar-to-main-pane
registration and ensures tree mutations and generated editor splits occur in
the nested worker tmux. Missing worker-side Treemux is an actionable failure
(`make setup-headless`); the dispatcher deliberately never falls back to a
misleading local tree for a remote pane.

### Headless worker provisioning results (2026-08-02)

Both workers were provisioned from `origin/main` and verified: `agents-roll`
(Ubuntu 24.04 VPS, login user `root`, tmux 3.4) passed headless-doctor 61/61;
`mini` (macOS, login user `admin`, tmux 3.7b) passed headless-doctor 62/62.
On both, the detached save-chain was proven — the timer fires with no
attached client, the Resurrect snapshot mtime advances, and the workspace
sidecar logs `saved N pane records` — and rerunning the chain was proven
idempotent. `rw doctor` run from the focus machine reports all checks
passing for both workers.

Nine installer/plugin defects were found and fixed along the way: macOS 26
`sudo -v` PAM/TTY behavior, a silent `brew bundle` failure, untrusted
Homebrew taps, a `gh auth login` hang in the headless lane, pyenv
rerun-safety, the launchd save-wrapper's `PATH`, tmux >= 3.7's
control-character sanitization inside this repo's own sidecar and `rw`
scripts, the same sanitization inside vendored tmux-resurrect (now pinned to
`cff343c` and patched via
`setup/patches/tmux-resurrect-tmux37-delimiter.patch`), and `rw` failing when
invoked through its `~/.local/bin` symlink.

The tmux >= 3.7 sanitization directly affects the multi-field pane-registry
parsing this plan specifies: tmux 3.7 rewrites control characters (including
literal TAB) in format output to `_`, with no opt-out, so every tab-delimited
multi-field parse of tmux stdout had to become one field per call instead.
See commits `bbd0211` (this repo's sidecar/`rw` scripts) and `d232f42`
(vendored tmux-resurrect pin and patch).

See `docs/headless-workers.md` for the full campaign record.

## Pre-smoke-test work

The items below are not smoke-testing steps. They are the work that must land
— or, for (c), be explicitly confirmed — before the smoke-testing plan that
follows can start meaningfully. Each subsection states its own definition of
done. Status as of 2026-08-02: (a) and (b) are DONE; (c) is the only item
still open.

Gating relationship, stated plainly: (a) and (b) are independent of each other
and may proceed in parallel. (b), the worktree-claim extraction, is
content-engine-side work and does not gate any dotfiles-side smoke wave — the
dotfiles claim/slot tools already run in advisory mode against live slots
regardless of migration state (see "Content-engine follow-up: a separate PR"
below). (a), the autosave freshness indicator, is different: its entire
purpose is letting the operator trust at a glance that the landscape about to
be restored was actually saved, so it specifically must land before Wave 6's
final live crash/restore drill — the serialized production canaries against
the live focus-machine tmux server that the smoke plan below deliberately
defers to "a final, explicitly-warned step." It is not required for Waves 0-5.
(c), operator auth, gates only Wave 5's live provider handoff/return matrix
and the real authenticated `codex resume` check, per the readiness gate and
`BLOCKED`-item accounting already built into the smoke-testing section below.

### a. Autosave freshness indicator

**STATUS: DONE, verified 2026-08-02 (7/7 assertions).** Built as specified
below, including the disarmed case (assertion 4) — continuum's interpolation
stripped from `status-right` while the timestamp still looks recent still
renders red `AUTOSAVE OFF`. Renders as a catppuccin-style chip prepended to
`status-right`. One spec revision: the <10ms cost budget below was
unachievable and was revised upward; measured cost is 18.8ms, against ~50ms
for the `continuum_save.sh` interpolation already running on every refresh, so
the added cost is proportionate rather than dominant.

**Why.** On 2026-08-01 the laptop's tmux-continuum autosave stopped arming
itself and nothing said so. The last snapshot was 34 hours old before anyone
noticed, and it was only found because someone went looking. The failure is
silent by construction: continuum skips arming when any other tmux process
exists, and a `source-file` (which re-runs catppuccin and rewrites
`status-right`) drops the interpolation without an error. `rw doctor` now
detects this, but only when run deliberately. The operator's requirement is an
always-visible indicator that answers "has a save happened in the last five
minutes?" so the session's recoverability can be trusted at a glance rather
than audited on demand.

**Behavior.** Read `@continuum-save-last-timestamp` (epoch seconds, set by
continuum after each successful save) and compare against now, using the
configured `@continuum-save-interval` (currently 5 minutes) rather than a
hardcoded value. Three states:

- **Fresh** — age <= interval + a small grace. Quiet, low-contrast (for
  example `󰄬 2m`). This is the normal state and must not draw the eye.
- **Late** — age > interval + grace but < 3x interval. Warning colour
  (catppuccin yellow `#f9e2af`, for example `󰀦 7m`). Covers the benign case
  where the status line simply has not refreshed because no client is
  rendering.
- **Stale / disarmed** — age >= 3x interval, OR `@continuum-save-last-timestamp`
  is empty, OR `status-right` no longer contains `continuum_save.sh`. Alert
  colour (catppuccin red `#f38ba8`), explicit text (`󰀦 NO SAVE 47m` or
  `󰀦 AUTOSAVE OFF`). This disarmed case is the one that actually bit us and
  must be visually distinct from merely late — of the seven verification
  assertions below, it is the single most important one because it is the
  exact failure that occurred.

The empty-timestamp case needs care: continuum sets the option on first plugin
load (`delay_saving_environment_on_first_plugin_load`), so empty means "armed
but never saved yet" immediately after a reload, and must show as Late rather
than Stale for the first interval after server start — compare against
`#{start_time}` to distinguish the two.

**Integration mechanism.** Do not add a catppuccin module. The installed
plugin under `~/.config/tmux/plugins/catppuccin/tmux` uses the newer
per-module `.conf` API (`status/host.conf`, `utils/status_module.conf`), which
does not consume the `@catppuccin_status_modules_right` option
`tmux/tmux.conf:62` sets — so the integration point is ambiguous and would
need to be re-derived, and that route is rejected for exactly that reason. Use
instead the mechanism already proven to work in this exact config: append our
own `#(...)` interpolation to `status-right`, the same way tmux-continuum
itself does. A `run-shell` line in `tmux/tmux.conf` placed after the TPM line
(`tmux/tmux.conf:100`) so it survives catppuccin rewriting `status-right`,
appending `#(~/.config/tmux/scripts/autosave_indicator.sh)` guarded so repeated
`source-file` calls do not stack duplicates. Continuum appends its own
interpolation during TPM load; appending after TPM means both survive. Verify
after implementation that `status-right` contains both `continuum_save.sh` and
`autosave_indicator.sh`, and that `source-file`-ing twice in a row does not
duplicate either.

**Performance constraint.** The script lives at
`tmux/scripts/autosave_indicator.sh`, matching the existing
`tmux/scripts/host_indicator.sh` precedent. It runs on every status refresh
(every `status-interval`, default 15s, independent of continuum's own cadence),
so it must be cheap: no subshell storms, no `git`, no filesystem walks — two
`tmux show-option` calls and arithmetic. Measured mean cost is 18.8ms (see
STATUS above); the original <10ms target proved unachievable and was revised.
It must
never fail loudly: any error path prints nothing rather than an error string,
or the status line fills with noise. Colour is applied with tmux `#[fg=...]`
inline styling and reset afterwards so it cannot leak into adjacent segments.

**Verification (non-destructive, agent-runnable).** All seven assertions run
against an isolated tmux server (separate `TMUX_TMPDIR`), never the live
one — and per the continuum teardown rule described in the coordinator
isolation contract below, that isolated server must be killed promptly
afterwards, because its existence disarms continuum on the live server:

1. Fresh state: set the timestamp to now, assert the fresh glyph and no
   warning colour.
2. Late state: set the timestamp to now minus (interval + grace + 1), assert
   warning colour.
3. Stale state: set it to now minus 3x interval, assert alert colour and the
   explicit text.
4. Disarmed state: strip `continuum_save.sh` out of `status-right`, assert the
   AUTOSAVE OFF branch fires even when the timestamp is recent — the single
   most important assertion, since it is the exact failure that occurred.
5. Empty-timestamp-after-start: unset the option on a freshly started server,
   assert Late rather than Stale.
6. Idempotency: `source-file` the config twice, assert `status-right` contains
   exactly one copy of each interpolation.
7. Cost: time 100 invocations, assert the mean stays within the budget above.

**Definition of done.** `tmux/scripts/autosave_indicator.sh` exists and is
wired into `status-right` via `run-shell` after the TPM line; a `source-file`
shows both interpolations present exactly once; all seven verification
assertions above pass against an isolated, promptly-killed tmux server. This
item is independent of (b) and can proceed in parallel, but must land before
Wave 6's live crash/restore drill (see the gating relationship above).

### b. Worktree-claim extraction (content-engine retirement, not a build)

**STATUS: dotfiles-side capability gaps DONE, verified 2026-08-02.** The two
small gaps below (branch checkout on claim, dirty-tree guard on release) are
closed. The content-engine-side code retirement itself is also done —
shipped as one PR, https://github.com/kalem-edlin/content-engine/pull/431,
in review as of 2026-08-02, not yet merged. Migrating markers and repairing
ports are separate live-state operator work, not part of that PR, tracked in
"Content-engine follow-up: a separate PR" — closing the two gaps was the
only part of (b) that gated anything, per the gating relationship above.

**Headline finding — this inverts the expected framing.** Investigated
2026-08-02 against the live worktrees, verified by direct inspection rather
than inferred. The dotfiles implementation
(`worktrees/.local/bin/worktree-claim`, `worktree-slot`,
`worktrees/.local/lib/worktrees/common.sh`) is already strictly more capable
than content-engine's `scripts/worktree-claim.ts`. It is already stowed to
both workers (`setup/linux-headless.sh:544-545`) and already wired into the
Claude, Codex, and Pi hooks. Content-engine is already registered in
`worktrees/.config/worktrees/config.json`. So the remaining work is not "build
the global system" — it is: retire content-engine's copy, migrate the live
markers, repair the port collisions its old script caused, and close two small
capability gaps.

**Capability diff.** Dotfiles has, content-engine does not: a cross-host
writer model (responsibility owner vs. active writer host, with
`handoff-writer`/`return-writer` and a `handoff_generation` counter); durable
session identity (`@session-uuid`) rather than the renameable session name
content-engine keys on; actual enforcement via `verify-writer` wired into all
three provider hooks (content-engine's system had zero enforcement of its
own); repo identity from the git remote rather than `package.json`'s name
field (so it works for non-Node repos); a deterministic multi-service port
allocator with global collision validation; and `status --json`, release
tombstones, and a `format_version` field.

Content-engine has, dotfiles does not — three gaps, all now closed or resolved:

1. **Branch checkout on claim — CLOSED 2026-08-02.** Content-engine's `claim`
   switches to or creates the branch and refuses on a dirty tree unless
   forced. Dotfiles' `claim` was metadata-only. It now takes `--branch <name>`
   (checkout) and `--create` (create-and-checkout), refusing on a dirty tree
   unless `--force`.
2. **Dirty-tree guard on release — CLOSED 2026-08-02.** Content-engine refuses
   to release a dirty worktree unless forced. Dotfiles' `release` now carries
   the same guard, with `--force` to override. Both guards define dirty as
   tracked changes only — deliberately not untracked-sensitive, because an
   untracked-sensitive check would have refused claim/release on 5 of the 15
   live slots that git itself would check out/switch cleanly.
3. **Arbitrary env-key fan-out — RESOLVED, kept.** `scripts/sync-env-worktrees.ts`
   propagates whole `.env.local`/`.env.production` files across sibling
   worktrees; `worktree-slot` only renders the four port variables declared
   in `config.json`. A real `.env.local` in `content-engine-2` holds dozens
   of non-port keys (API keys, `DATABASE_URL`, Apple/Meta/AppsFlyer secrets,
   Supabase keys), so PR #431 keeps the script rather than deleting it — this
   answers the operator question of whether non-port keys are relied on: yes.

Shared gaps, not regressions: neither system expires stale claims, and neither
prevents the same branch being live in two worktrees (both lock by path, not
by branch).

**Cross-host semantics — the recommendation.** The current design is a
hybrid, and it is already built: each host keeps its own private authoritative
registry under `~/.local/state/worktrees/claims/`, and the in-worktree
`.worktree-claim` marker is the travel mechanism. `rw handoff` captures and
re-places it as `claim-marker.json`; the focus machine bumps the generation
before the snapshot, and the receiving side adopts lazily on next use.
`worktree-claim` is never invoked over SSH — a worker does not even need the
binary for handoff to work. **Recommendation: keep this. Do not build a shared
registry.** It is a single-operator system; a shared store adds an
availability dependency for a problem that only arises if the operator
manually bypasses `rw handoff`. The generation counter plus `verify-writer`'s
host check already hard-blocks the common failure (stale writer host
attempting a write). One real unspecified edge worth closing as a scoped
follow-up: the schema has a `state: "conflicted"` value that `verify-writer`
and `flip_writer` both check for, but nothing in the codebase ever sets it. If
marker adoption ever sees two markers at the same generation with different
owners, it should mark conflicted rather than silently picking one. Small
additive change; not required for the extraction.

**What actually shipped.** PR #431 did the whole code retirement in one shot
rather than the staged a-d sequence this document originally sketched —
`worktree-claim.ts` and its `package.json` scripts deleted, `.gitignore`
entry dropped, `AGENTS.md`/`env-rendering.md` pointed at the global rules,
`sync-env-worktrees.ts` kept (see the capability-diff item 3 above). None of
that touched the 14 live worktrees' running state, so there was no
disruption to sequence around. What remains is live-state operator work the
PR deliberately left out of scope: port repair on slots 10/12 (a dev server
already bound to the old port needs restarting — coordinate slot by slot,
not batch-scripted) and marker migration by each slot's actual current owner,
one at a time, since migration rewrites `owning_user`/`session_uuid`/
`active_writer_host` to whoever runs it. Playwright port conversion remains
independent and low-risk, any time, but needs a matching service entry added
to dotfiles' `config.json` first.

**Verification (non-destructive, agent-runnable).** Safe against real slots
right now, all read-only:

- `worktree-claim status --path <slot>` for all 15 slots — reproduces the
  claimed/unclaimed inventory as a repeatable check. Run 2026-08-02: 14
  claimed (1-14, all legacy markers), only 15 unclaimed. (Slot 3 was claimed
  partway through the investigation session, which is why an earlier pass
  during the same session counted differently — not a discrepancy in the
  tooling.)
- `worktree-slot ensure <N> --dry-run` — guaranteed to write nothing, and
  proves the port collisions programmatically instead of grepping
  `.env.local` by hand. Run 2026-08-02: confirmed slots 10+11 and 12+13
  collide as described below. `ensure 11 --dry-run` also failed against a
  *live* listener on port 9081, traced to a running Expo dev server whose cwd
  is `content-engine-10` — a real process conflict, not just a stale-config
  one, so the port repair step (2b) needs that process stopped or moved
  first.
- `worktree-claim verify-writer --path <slot>` — never mutates.
- Over SSH: `ssh <worker> 'worktree-claim status --path <slot>'` for a
  reflected slot, confirming the worker's own install resolves the same
  semantics against a traveled marker.

Mutating tests (claim/release/handoff-writer/return-writer round trips) belong
in a scratch git repo under the session scratchpad, never against a live slot.
Do not run `claim` or `handoff-writer` against a real reflected slot over SSH
as part of verification — that mutates live claim state for a workspace that
may have in-flight work.

**Definition of done.** The dotfiles-side capability gaps (1 and 2 above) are
DONE as of 2026-08-02. The code retirement is DONE, shipped as PR #431 (in
review). The remaining, non-gating part of (b) is done when: PR #431 merges;
all 14 currently-claimed markers are migrated by their actual owners; slots
10 and 12 are repaired to their correct ports (see "Content-engine
follow-up: a separate PR" below for the authoritative checklist); and the
read-only verification commands above are rerun clean against all 15 slots.
This item does not gate any dotfiles-side smoke wave (see the gating
relationship above) and can proceed in parallel with (a).

### c. Operator auth: `gh auth login` on `agents-roll`

`gh auth login` on `agents-roll` is the only remaining authentication item.
Everything else was verified 2026-08-02: Tailscale is up and online on both
workers; `claude auth status` and `codex login status` both report logged in
on both workers; Pi shows no model-downgrade fallback and has `auth.json`
present on both workers. This verification date and scope is recorded here so
it is not re-litigated — only the GitHub CLI login on `agents-roll` remains
open.

**Definition of done.** `gh auth login` succeeds on `agents-roll` (per "Never
launch interactive gh auth login in the headless lane," this must not be done
by an automated agent) and `gh auth status` confirms it there, matching the
already-verified state on `mini`.

## Smoke testing — agent-first execution plan

This section supersedes the earlier short, Mini-only checklist. Once the user
has provisioned and authenticated the focus Mac, `mini`, and `agents-roll`, a
local coordinating agent should own the smoke run. It should delegate the
isolated work packages below to sub-agents, run independent lanes in parallel,
collect machine-readable evidence, and finish with the narrow integration and
outage tests that must be serialized.

The target is not a guided manual tour. The target is an agent-executed test of
every implemented surface. Tmux gives agents real PTYs plus `send-keys`,
`send-keys -K`, `capture-pane`, `display-message`, `wait-for`, and structured
formats; SSH exposes the worker state; the sync layer and provider adapters
already have test seams. Even authenticated Claude, Codex, and Pi resumes can
be launched in disposable tmux panes and driven/polled by an agent. Never run a
handoff test in the coordinating agent's own pane: successful handoff stops the
source agent by design.

### Execution contract: fully automated, agent-run, non-destructive

This entire smoke plan runs the same way the just-completed headless-install
worker-provisioning campaign did (see "Headless worker provisioning results
(2026-08-02)" above and `docs/headless-workers.md`): programmatic,
agent-executed, and structured so nothing destructive can happen by accident.
That precedent is the binding contract for every lane below, not a stylistic
preference, and every wave, lane, and assertion that follows must satisfy it.

- **Programmatic execution only.** Every lane is executed by an instructed
  subagent running commands over SSH or against an isolated tmux server, per
  the coordinator isolation contract below. No lane is run by a human typing
  into a terminal, and no lane is a guided manual walkthrough — the human's
  only role is the readiness gate in "The small user-owned readiness gate."
- **The live focus-machine tmux server is untouchable.** Agents never run any
  tmux command against the user's live focus-machine tmux server — not
  `send-keys`, not `capture-pane`, not `kill-session`, nothing. Worker-side
  tmux is permitted, but confined to sessions carrying the lane's test prefix
  (the `rw-<machine-short>-<endpoint-id>` namespace under a lane-unique focus
  id, or the lane's own `$RUN_ID`/`$LANE_ID`), and such a session is only ever
  killed by quoted exact match: `tmux kill-session -t '=exact-session-name'`.
  The leading `=` forces tmux's exact-match target syntax instead of prefix
  matching; the quotes matter because a zsh login shell would otherwise
  consume a bare `=word` as an EQUALS-expansion glob before tmux ever sees the
  argument.
- **Nothing destructive, anywhere, ever.** Saves only — never a Resurrect
  *restore* run against a worker's real state. No unscoped `kill-server` or
  `pkill`. No `git reset --hard` or `git clean` on a worker with a dirty tree
  without explicit operator approval. No write to the real Resurrect `last`
  target. No deletion of real user data. This is the same rule as "Hard
  safety rules for every sub-agent" below, stated here as a precondition of
  the whole run rather than a per-lane footnote.
- **Blocked is not failed.** An auth-blocked or interactive-blocked step (a
  sudo password prompt, `tailscale up`, a provider login, anything that would
  need `ssh -t`) is reported `BLOCKED`, never `FAIL`. The agent skips it,
  continues everything that does not depend on it, and the coordinator
  reports one consolidated operator checklist at the end of the run instead
  of halting on the first blocked item.
- **Required-step failure halts and reports verbatim.** The coordinator stops
  at the first failed *required* step and reports it exactly as observed. It
  does not improvise a fix or a workaround beyond what the failing step
  names — repairing forward mid-lane is exactly what "no edits/fixes during a
  smoke lane" below forbids.
- **Every lane tears itself down and proves it.** A lane is not done when its
  assertions pass; it is done when it has also torn down everything it
  created and verified no orphaned tmux processes remain on that machine.
  This is the same rule as the continuum-suppression hazard documented in the
  coordinator isolation contract below — a stray private server left running
  silently disarms the live session's autosave with no error, which is
  exactly the class of accidental damage this contract exists to prevent.
- **Every lane produces a machine-checkable result.** Not a prose impression:
  a per-step PASS/FAIL/BLOCKED line, the commit SHA under test, and every WARN
  with its recorded detail, per the evidence contract below.
- **What cannot be proven programmatically is named, not assumed.** The final
  terminal-emulator OSC 52 clipboard acceptance and a real authenticated
  provider resume that depends on interactive login the operator performed
  out of band are called out explicitly as needing one brief human
  confirmation. Neither is ever silently marked passed.

### Completion rule

A smoke run is complete only when:

- both Darwin (`mini`) and Linux (`agents-roll`) have passed the applicable
  matrix, not merely one representative worker;
- every assertion is reported as `PASS`, `FAIL`, or `BLOCKED` with evidence —
  a blocked provisioning/auth prerequisite is not mislabeled as an
  implementation failure;
- all P0 safety assertions pass: no wrong-host/path Treemux behavior, no source
  agent stopped before destination start, no divergence overwrite, no
  namespace escape during reconciliation, and no live-user tmux/state damage;
- the coordinator verifies cleanup from exact ownership manifests; and
- failures remain preserved with enough sanitized evidence to reproduce them.

"Mostly passed" is not a completion state.

### The small user-owned readiness gate

The user should do or explicitly authorize only the following before handing
the run to an agent:

1. Run the normal dotfiles install on the focus Mac and `make setup-headless`
   on both workers. Confirm the intended `Host mini` account before any Mini
   reprovisioning.
2. Register each worker's own Git-host SSH key and make `ssh mini` and
   `ssh agents-roll` succeed noninteractively with `BatchMode=yes`.
3. Install and authenticate Claude, Codex, and Pi independently on every host
   where that provider will be tested. Complete OAuth/MFA/device-login,
   Keychain, and persistent hook-trust prompts personally; agents must never
   receive or log those secrets.
4. Enable the terminal's OSC 52 permission if it prompts. An agent can test the
   byte path and, when it has a real attached terminal client, compare a
   sentinel with `pbpaste`; the final terminal-emulator/OS clipboard acceptance
   may still need one brief human confirmation.
5. Give explicit outage permission before the final default-worker-tmux-server
   or host-reboot drills, and provide Mini sudo interactively if it is not
   passwordless. A literal focus-Mac sleep/reboot also requires the user to
   wake, unlock, and reopen the client; the private-socket equivalent remains
   the primary automated test.

Provisioning, login, and outage authority are gates to the smoke run, not smoke
steps the user should have to execute manually. After the gate is green, the
agent owns the commands and assertions.

Current-state assumption (2026-08-01): **no remote service is authenticated on
either worker yet** — no Tailscale login, no Claude/Codex/Pi login. The only
assumed credential is a working Git-host SSH key on each worker. The
coordinating agent must therefore run everything that doesn't depend on the
gate, mark gate-dependent lanes `BLOCKED` (never `FAIL`), and halt with ONE
consolidated operator checklist of the outstanding gate items; gate-dependent
lanes run only after the operator confirms the checklist is complete.

### Coordinator isolation contract

Before spawning lanes, the coordinating agent creates a unique run id and a
run root, then gives every sub-agent a distinct lane id. A representative
focus-side harness is:

```sh
RUN_ID="rw-smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/${RUN_ID}.XXXXXX")"
LANE_ID="<assigned-lane>"
LANE_ROOT="$RUN_ROOT/$LANE_ID"
FOCUS_SOCKET="${RUN_ID}-${LANE_ID}"
FIXTURE="$LANE_ROOT/fixture"
mkdir -p "$LANE_ROOT/tmp" "$FIXTURE"

export TMUX_REMOTE_WORKSPACES_STATE_DIR="$LANE_ROOT/rw-state"
export TMUX_WORKSPACE_RESURRECT_STATE_DIR="$LANE_ROOT/workspace-resurrect-state"
export TMUX_RESURRECT_DIR="$LANE_ROOT/resurrect"
export WORKTREES_CLAIMS_STATE_DIR="$LANE_ROOT/claims"
export TMPDIR="$LANE_ROOT/tmp"
```

The coordinator or lane then:

- starts a private focus tmux server with
  `tmux -L "$FOCUS_SOCKET" -f "$HOME/.config/tmux/tmux.conf" new-session -d
  -s "$LANE_ID" -c "$FIXTURE"`, never the user's live socket. `$FIXTURE` is
  just the lane's disposable starting directory (`$LANE_ROOT/fixture`,
  created above) so the session never opens in the operator's real cwd; it is
  distinct from the disposable per-repository fixtures (each its own
  `mktemp -d` checkout against a harmless bare origin) created later for
  workspace-placement and handoff cases;
- sets that server's `@resurrect-dir` to the lane's unique Resurrect directory
  with `tmux -L "$FOCUS_SOCKET" set-option -g @resurrect-dir
  "$TMUX_RESURRECT_DIR"` before any save — a private tmux socket alone does
  **not** isolate upstream Resurrect snapshots;
- uses a lane-specific `TMUX_REMOTE_WORKSPACES_STATE_DIR`, which also creates a
  unique focus-machine id and therefore a unique
  `rw-<machine-short>-<endpoint-id>` worker namespace;
- supplies a temporary `TMUX_REMOTE_WORKSPACES_CONFIG` and `WORKTREES_CONFIG`
  referencing only disposable repositories, collections, and remote paths;
- creates every repository with `mktemp -d`, uses a harmless disposable bare
  origin, and never touches a real content-engine slot or branch;
- uses a reviewed lane-specific SSH-override wrapper with SSH multiplexing
  disabled, so killing a test connection cannot kill a shared ControlMaster.
  Both `RW_SSH_BIN` (honored by `tmux-remote-workspaces`' own scripts, see
  `scripts/common.sh:404` and the README's "Testing without a reachable
  worker" section) and `CA_SSH_BIN` (honored by the provider adapters'
  shared helpers, `libexec/adapters/common-adapter.sh:40`, which falls back
  to `RW_SSH_BIN` and then plain `ssh`) must point at the wrapper so both
  seams are covered; and
- records exact local pane ids, endpoint ids, remote session names, PIDs,
  workspaces, state paths, and backup paths before mutating or cleaning them.

The existing SSH override seam can also give a lane a private worker tmux
server: the reviewed wrapper exports a unique remote `TMUX_TMPDIR` before
executing the original remote command, while preserving arbitrary command
strings and stdin/heredocs. It should also set lane-specific remote
`TMUX_WORKSPACE_RESURRECT_STATE_DIR`, `TMUX_RESURRECT_DIR`, and `TMPDIR`, and use
the normal worker config so hooks and Treemux remain production-equivalent.
This wrapper must be a reviewed harness artifact, not improvised quoting in
each sub-agent prompt. Include one final unwrapped canary per worker to prove
the actual default production path.

Conservative default: only one mutating lane per worker at a time. Mini and
`agents-roll` lanes may run concurrently, as may any number of fully local or
fake-SSH lanes. Worker endpoint names are isolated, but production commands
otherwise use that worker's default tmux server. Actual timer, default-server
loss, and reboot tests are exclusive maintenance operations even when private
endpoint lanes have passed. Provider lanes also serialize per worker because
process-start verification has a host-global `pgrep` fallback.

Hard safety rules for every sub-agent:

- no unscoped `tmux kill-server`, `pkill`, network-interface changes, broad
  process scans followed by kills, or wildcard cleanup;
- no writes to the default focus-machine state roots or real Resurrect `last`;
- no edits/fixes during a smoke lane — report the failure and let the
  coordinator decide whether to stop and open a repair cycle;
- close endpoints through `rw close` first, then clean only exact resources
  recorded in that lane's manifest;
- preserve failing workspaces/backups until the coordinator has copied the
  evidence; and
- tear down every lane's private tmux server promptly and verify no orphaned
  `tmux` processes remain on the machine when the lane finishes, per the
  continuum-suppression hazard below.

Newly discovered constraint, verified 2026-08-02: tmux-continuum only arms
its autosave by prepending a `#(continuum_save.sh)` interpolation to
`status-right`, and `continuum.tmux`'s `main()` skips that step entirely
whenever any other tmux process is running on the machine
(`another_tmux_server_running` in `scripts/helpers.sh` compares all `tmux`
processes except the current server against that server's attached-client
count). Therefore any private/isolated laptop tmux server — exactly what
these smoke lanes are built on — suppresses continuum's re-arming on the
user's live server for as long as it exists. Combined with the fact that
every `source-file` re-runs catppuccin and rewrites `status-right`, a stray
server left running leaves the live session's autosave silently disarmed
with no error. This is not hypothetical: six orphaned test servers from
earlier runs left the live server's autosave dead from 2026-08-01 03:45
until 2026-08-02. After any smoke run, the operator should re-source
tmux.conf and confirm autosave re-armed; `rw doctor` now has a "Local
durability" section that checks this.

### Evidence contract

Each sub-agent writes under its lane root:

```text
manifest.json       run/lane/host/socket/state roots, exact owned resources,
                     and the commit SHA under test
assertions.jsonl    id, surface, expected, actual, PASS|FAIL|BLOCKED, timestamps
commands.log        sanitized argv, exit code, duration (no secrets/transcripts)
before.json         scoped local/worker inventory before the lane
after.json          scoped local/worker inventory after assertions
events.jsonl        copy of this lane's remote-workspace events
panes/              short, sanitized capture-pane excerpts
cleanup.json        exact cleanup attempted, outcome, retained failure artifacts
```

The parent agent produces one `summary.md` matrix linking to those artifacts.
It must redact credentials, environment secrets, complete provider
transcripts, and unrelated panes/processes. Every command that intentionally
expects a nonzero status records the expected status explicitly.

### Parallel execution waves

The waves are dependency boundaries, not single-agent tasks. Rows within a
wave are independent unless they name the same worker. The parent should spawn
as many sub-agents as available concurrency safely permits.

| Wave | Parallel sub-agent work packages | Gate to next wave |
|---|---|---|
| 0 | Coordinator creates isolation/evidence harness; read-only readiness agents audit local, Mini, and VPS | both SSH aliases, packages, plugins, timers, Git auth, and requested provider auth are green |
| 1 | local/fake-SSH contracts; sync fault injection; adapter fixtures; worktree slots/claims; private focus-tmux keymap/session UUIDs | hermetic safety and test harness pass before live worker mutation |
| 2 | one Mini endpoint lane and one `agents-roll` endpoint lane in parallel | endpoint lifecycle, cwd, metadata, splits, closes, status/events pass on each OS |
| 3 | one Mini and one VPS Treemux/transport lane in parallel | remote-only tree actions and exact-connection reconnect behavior pass |
| 4 | one disposable handoff/return lane per worker in parallel | exact Git/LFS/claim round-trip plus failure safety pass |
| 5 | live provider lanes in paired waves: Pi, Claude, then Codex; one provider lane per worker at a time | real TTY resume and transactional stop/return assertions pass |
| 6 | private resurrection/reconciliation lanes; then serialized default-server/timer/reboot canaries | destructive namespace and recovery assertions pass |
| 7 | coordinator reruns diagnostics, audits cleanup/evidence, and publishes the final matrix | no P0 failure, no owned resource leak, no unclassified result |

### Wave 0 — automated readiness and baseline

After the user gate, readiness sub-agents perform all remaining checks:

- `rw doctor`, `preflight.sh --worker mini`, and
  `preflight.sh --worker agents-roll`;
- `make headless-doctor` with the correct profile on the focus Mac and both
  workers, plus the sibling `tmux-workspace-resurrect` doctor;
- SSH host/user/fingerprint and `BatchMode=yes` checks;
- `ssh -G mini`, the LAN-listener predicate, and a non-disruptive route
  fault-injection proving the logical `mini` alias selects LAN when available
  and Tailscale otherwise (never disable the controller's real Wi-Fi/Tailscale
  path for this test);
- `tmux`, Git, Git LFS, rsync, jq, Neovim, `lsof`, Treemux, provider CLI, and
  plugin-path/version inventories on each host;
- `allow-passthrough` and the actual bound key table;
- `launchctl print gui/$UID/com.kalem.tmux-resurrect-save` on the Mini and
  `systemctl --user status tmux-resurrect-save.timer` plus linger status on
  Linux;
- the timer wrapper's read-only `--check` mode; and
- worker-side Git `ls-remote` from a disposable origin.

A missing prerequisite stops only the dependent lane as `BLOCKED`; no smoke
agent provisions or logs in on the user's behalf.

### Wave 1 — fully parallel, worker-free contracts

#### Lane 1A: config, command, preflight, and observability contracts

- Parse every JSON config and run shell syntax/static checks.
- Exercise `rw help`, unknown commands/arguments, unknown worker (must fail
  before SSH), unreachable SSH, and fake-worker missing tmux/Git/Git LFS.
- Exercise Git-host-auth failure and assert the message names worker-key
  registration without attempting it.
- Validate registry/event schemas, modes, permissions, and malformed/stale
  state reporting.
- Hash state before/after `rw doctor` and `reconcile --dry-run`. The code calls
  `mkdir` and preflight event logging today despite describing doctor as
  read-only; record the observed behavior rather than silently relaxing the
  assertion.

#### Lane 1B: workspace resolution and standalone sync engine

- Test pure resolution for plain non-repo, explicit `~` expansion, reflected
  slot/subdirectory, fresh ad-hoc clone, same-worker ad-hoc reuse, and
  other-worker separation.
- In paired disposable Git repositories, use the sync engine's local
  destination mode and state-file backend to transfer unpushed commits,
  staged and unstaged changes separately, binary changes, rename, deletion,
  untracked contents, detached HEAD, claim marker, and LFS objects.
- Assert fingerprint equality, generation increments, ignored-file exclusion,
  and recoverable destination backup.
- Inject divergence (expect exit 2 and no mutation), truncated transfer
  (exit 3 and live destination untouched), post-apply mismatch (exit 4), and
  apply interruption (backup exists and recovers it). Test `--force-diverged`
  only against the disposable destination.

#### Lane 1C: provider adapter fixtures and version/failure doubles

- Run `libexec/adapters/smoke-test` and preserve all assertions.
- For Pi, Claude, and Codex, exercise detect, versions, export, install, and
  resume-cmd with both ordinary and `--fork` output.
- Assert auth files are never read/copied and destination-path rewriting is
  correct.
- Simulate equal, newer-worker, older-worker, and Node-mismatch policies.
- Simulate export/install/resume generation failures for the live
  orchestration lanes to consume later.

#### Lane 1D: worktree slots, ports, and claims

- Use a temporary `WORKTREES_CONFIG`, collection, claims root, and private tmux
  session UUID.
- Prove `worktree-slot ensure --dry-run` makes zero filesystem/state changes;
  real ensure is idempotent; tier promotion is explicit; slot names,
  metadata, capacity, environment rendering, and deterministic ports are
  correct.
- Inject port collision, prohibited port, pool ceiling, malformed collection,
  and over-capacity cases.
- Exercise claim, idempotent same-owner claim, responsibility mismatch,
  host mismatch, missing stable session, conflicted state, no claim,
  handoff-writer, return-writer, takeover, and release. The numbers in
  parentheses below are `worktree-claim` process exit codes, not the
  similarly-numbered content-engine slots discussed elsewhere in this
  document (see "Content-engine inconsistency to replace") — do not confuse
  the two: responsibility mismatch is exit 10, host mismatch is exit 11,
  missing stable session is exit 12, conflicted state is exit 13, all
  returned by `worktree-claim verify-writer`
  (`worktrees/.local/bin/worktree-claim:378,382,368,361`) and consumed by the
  Claude PreToolUse hook, which blocks only on 10/11/13 and treats 12 as a
  pass-through (`claude/.claude/settings.json`). No claim is a distinct exit
  14, returned only by the `handoff-writer`/`return-writer` path
  (`flip_writer`, `worktrees/.local/bin/worktree-claim:406,412`), never by
  `verify-writer` itself.
- Confirm opted-out repos remain advisory and legacy marker formats are labeled
  as deliberately non-blocking until migration.

#### Lane 1E: private focus tmux behavior

- Prove new sessions receive one stable `@session-uuid`, config reload does not
  mint a replacement, and renaming records the latest session name.
- Drive the actual prefix key table through a dedicated attached test client
  (`send-keys -K -c <client>` where supported), not merely the backing scripts.
- On local panes, verify `\` and `/` remain local at the same cwd, `q` kills
  only that pane, `Tab` opens local Treemux, and `c` opens a local window.
- Save and dry-run restore shell buffers, Neovim state, local Treemux
  registration, and provider resume commands in isolated Resurrect/state dirs.
- Run the sibling plugin's doctor and `restore.sh --dry-run` against those
  isolated artifacts before performing any real restore.

### Waves 2–3 — worker endpoint, tmux UI, Treemux, and transport matrix

Run the following once against `mini` and once against `agents-roll`. The two
worker lanes may run in parallel.

#### Endpoint establishment and placement

- From a private focus pane, run `rw ensure --worker <worker>` for explicit
  plain, inferred reflected, and inferred ad-hoc fixtures.
- Assert the registry JSON and 0600 mode; pane caches `@rw-endpoint`,
  `@rw-worker`, `@rw-workspace`, `@remote-host`, and
  `@workspace-resurrect-skip`; window defaults; and create/attach event.
- Assert the exact remote session cwd and options: `prefix=None`,
  `prefix2=None`, `mouse=off`, `escape-time=10`, and `status=off`.
- Re-run ensure and prove the endpoint/session id is unchanged, its generation
  advances, and no duplicate remote session appears.
- For fresh ad-hoc mode, prove clone/auth behavior and same-worker reuse. A
  failed worker Git key must abort before endpoint creation.

#### Pane/window behavior and lifecycle

- Drive both bound split directions. Each child receives a distinct endpoint
  but inherits worker and workspace. A still-local pane in the same window
  inherits the window default; a new window remains local.
- Expand the status format while focusing local and remote panes and assert it
  changes from the focus hostname to the explicit worker alias.
- Test direct `rw close`, bound `prefix q`, and confirmed `prefix &`. Assert
  tombstone-first ordering, registry removal, exact remote-session close,
  event reason, cache cleanup, and that reflected/ad-hoc storage remains.
- Repeat close while the worker is unreachable: local intent/registry cleanup
  must still complete. Unmanaged worker sessions must remain untouched.
- Record what happens when a returned pane later splits: window affinity is
  currently cached and has no explicit clearing path, so this is a discovery
  assertion rather than an assumed pass.

#### Mandatory remote Treemux smoke — both workers

Treemux success means remote behavior, not merely "a sidebar appeared":

1. Create a unique remote Git root/subdirectory and a same-named path that is
   deliberately absent locally. `cd` the endpoint's active remote pane into
   that subdirectory and record both focus- and worker-side pane inventories.
2. Invoke the actual outer `prefix + Tab` binding. Assert the focus tmux server
   did **not** gain a sidebar; the worker endpoint session did; the worker's
   Treemux registration points from its sidebar to its active main pane; and
   its root is the remote Git root/current context, never the outer pane's
   local `#{pane_current_path}`.
3. Drive Neo-tree through tmux keys to create, rename, and remove a uniquely
   named scratch file and to open a sentinel file/editor split. Assert every
   mutation and new editor pane/process exists only on the worker.
4. Close the tree, change the main remote pane cwd, reopen it, and prove the new
   remote directory is authoritative. Toggle closed and assert registration and
   worker sidebar cleanup.
5. Negative cases — stale/missing endpoint registry, absent endpoint session,
   missing worker toggle script, and missing `@treemux-key-Tab` — must report an
   actionable error and must never open local Treemux as fallback.

#### Connection loss and endpoint-state branches

- Use the lane's no-multiplex SSH wrapper and kill only the exact pane-owned
  SSH client. Prove registry and worker session survive, reconnection targets
  the same endpoint, and a stable connection resets backoff.
- Inject quick failures and observe 1/2/4/.../30-second capped backoff without
  killing worker networking or another lane.
- Kill only the exact endpoint session while the worker tmux server remains.
  Assert remote-intentional-close creates a tombstone, removes the registry,
  closes the outer pane, and never recreates it.
- Exercise all attach-loop states: unreachable, server present/session present,
  server present/session absent, and isolated worker-server absent followed by
  Resurrect or manifest rebuild.
- Abruptly kill the SSH/TCP path and inspect worker
  `workspace-resurrect.log`. Whether the detach hook fires is the one empirical
  question; the periodic timer remains the correctness net either way.
- Verify pending remote TUI input remains in the worker process across the
  disconnect and that the outer terminal mouse/reset sequence is restored.

### Wave 4 — live workspace handoff and return on both workers

Each worker gets an independent disposable repository containing an unpushed
commit, staged change, unstaged change, rename, deletion, binary change,
untracked file, and LFS object where available.

- Run workspace-only `rw handoff`; compare source/destination fingerprint,
  HEAD/branch, index/worktree status, untracked bytes, and LFS materialization.
- Assert endpoint/claim generation, writer-host transition, backup location,
  event sequence, and source preservation.
- Make a remote change, run `rw return`, and prove exact reverse state and
  writer-host return.
- Repeat representative explicit/plain, reflected, and ad-hoc cases.
- Independently mutate the inert destination and assert divergence refuses to
  overwrite either side. Exercise an explicit override only after verifying
  the backup.
- Inject failed transfer and failed apply against disposable paths and prove
  inert-live-destination versus recoverable-backup guarantees.
- Run with Git LFS hidden both with and without the CLI's `--check-lfs`. The
  current handoff/return callers appear to request LFS preflight
  unconditionally; record whether implementation behavior matches the public
  optional flag.
- After return, test whether the retained remote endpoint is reusable and
  closeable. Current return clears pane cache while retaining the registry and
  session, so explicitly detect/report any unreachable retained-endpoint leak.

### Wave 5 — real provider handoff/return matrix

Run Pi, Claude, and Codex against each OS worker (six live cases), in disposable
authenticated panes with minimal harmless prompts. Provider lanes are
sequential per worker but Mini and VPS cases can pair in parallel.

For each case:

1. Start a new provider session in a disposable pane and wait for both the live
   child process and recorded provider/session/cwd state.
2. Handoff to the worker. Assert transcript installation, destination cwd,
   exact resume command, destination process start, and only then source
   process stop.
3. Send a sentinel follow-up in the worker pane and assert continuity without
   recording the transcript contents in evidence.
4. Return. Assert remote export, local install, real local PTY resume, process
   verification, and only then remote stop. A local agent can drive Codex's
   real interactive resume through tmux; authentication, not interactivity, was
   the missing ingredient in the earlier sandbox test.
5. Exercise `--keep-local`, duplicate managed-writer refusal,
   provider-native fork on divergent return, and `--keep-remote` risk
   recording.
6. Inject preflight, version, export, install, resume-cmd, send-keys, and
   process-verification failure. Every pre-destination-start failure must leave
   the source agent running untouched.
7. Include the accepted direct-`exec` source-agent stop limitation as an
   expected known-gap case, not a surprise pass.

Two high-priority discovery assertions must not be skipped:

- Return currently types the local resume command into the same pane while
  `rw-return.sh` still owns its foreground. Prove that the process can actually
  start before the verification timeout; otherwise record `resume_unverified`
  and confirm the remote source remains alive.
- The duplicate-writer guard and fork behavior must identify the logical
  provider session, not just any host-global process (the live worker verifier
  has a `pgrep` fallback).

### Wave 6 — resurrection, reconciliation, timer, and outage safety

Private focus-tmux and private worker-tmux variants are agent-safe and run
first:

- Save, kill only the named private focus server, restore it, and prove stable
  session UUID re-resolution, endpoint pane recache/respawn, command-replay
  opt-out, Treemux reconstruction, and same-endpoint reconnect.
- Include two panes with the same cwd and prove ambiguous matching never
  guesses or deletes.
- Reconciliation must abort without writes/deletes on missing/invalid sidecar;
  dry-run must close/log nothing; newer-or-equal tombstone must finish an
  incomplete close; older tombstone must not suppress desired state; an
  unreachable worker contributes no deletion candidates.
- Create exact test-prefix orphans and prove only this lane's
  `rw-<machine-short>-*` namespace is closed. Other focus-machine namespaces
  and unmanaged worker sessions must remain untouched.
- Kill the isolated worker tmux server and prove worker Resurrect recovery or
  declarative endpoint rebuild, including shell cwd/buffer, Neovim, Treemux,
  and provider state where captured.

Then run serialized production canaries behind the outage gate:

- invoke/observe the actual launchd/systemd timer with no client and prove a
  fresh normal-worker snapshot and workspace sidecar;
- inventory the worker's default tmux server and proceed with default-server
  loss only when no unrelated important session exists;
- reboot one worker at a time, wait for SSH, and prove timer/server/endpoint
  recovery; and
- optionally sleep/wake the focus Mac once, with the user performing only the
  physical wake/unlock, then let the agent assert reconnection and state.

### Final functional and cleanup audit

The coordinator finishes, rather than delegates away, the cross-lane verdict:

- rerun `rw doctor`, status, timer checks, provider version/auth probes, and
  reconciliation preview;
- test local-to-remote paste and a small OSC 52 sentinel. The roughly 74KB
  clipboard cap remains an expected limitation, not a failure;
- compare all before/after scoped inventories;
- run `rw close` for every surviving owned endpoint, then verify no exact test
  remote session, pane process, SSH PID, claim, or test-prefix workspace was
  missed;
- preserve only evidence and explicitly retained failure backups; and
- publish the per-worker/per-provider matrix plus any implementation findings.

This audit should call out discovered defects rather than normalizing them.
The first run must pay particular attention to the doctor write behavior,
optional-LFS preflight behavior, retained endpoint reuse/cleanup after return,
return-pane resume verification, attach-loop timing/backoff, and remote Treemux
path/action guarantees.

### Content-engine follow-up: a separate PR

This plan is dotfiles-only. It implies real changes inside the separate
`content-engine` repository (worktrees live under
`~/Developer/content-engine-trees/content-engine-*` on this machine), but
those changes are not part of this document's dotfiles work, are not part of
the smoke-testing waves above, and do not gate them. This subsection is the
single place that states what the content-engine PR changed, what's left as
live-state operator work, and what already works today independent of either.

**Code retirement: DONE, shipped as one PR, in review as of 2026-08-02.**
https://github.com/kalem-edlin/content-engine/pull/431
(`chore/retire-worktree-claim`, off `origin/main` at `b29491933`, authored in
an ephemeral worktree outside the claim system; not yet merged). It:

- Deletes `scripts/worktree-claim.ts` (356 lines, confirmed; roughly 90%
  generic claim/release/status/tmux-ownership/slot-claiming/machine-writer
  logic per the extraction fact above, with its only content-engine coupling
  being a single `env:pull` call) and removes its `package.json` scripts
  `worktree:claim`, `worktree:release`, `worktree:status` outright — not
  replaced with wrappers, because content-engine cannot express or verify
  that the dotfiles binary is on `PATH`, and a silently broken wrapper is
  worse than a clear "command not found."
- Removes the now-redundant `.worktree-claim` entry from content-engine's
  `.gitignore` — the global `core.excludesfile` already covers it repo-wide
  (see "already works" below).
- Reduces `AGENTS.md`'s `### Worktrees` section to a pointer at the
  agent-global dotfiles rules (naming `~/.claude/CLAUDE.md`,
  `~/.codex/AGENTS.md`, `~/.pi/agent/AGENTS.md`), keeping only the two
  genuinely content-engine-specific bits: the `pnpm -F @content-engine/gcp
  env:pull --lane staging` follow-up and the legacy `../active/` grandfather
  clause.
- Strips the restated port formula and `worktree:claim` delegation prose out
  of `platform/gcp/protocols/env-rendering.md`, keeping that file's
  content-engine-specific URL-derivation/Bonjour/`LOCAL_HOST` behavior.

**Reversed 2026-08-03: `scripts/sync-env-worktrees.ts` is DELETED** (PR
#433, `chore/ports-from-env-ports-file`, commit `e886bfa3d`), superseding
the earlier "kept" decision above this note replaced. Two reasons: its
`_PORT` renumbering used stride 1 (slot 11 would get `NEXT_PORT=3010` —
`DASHBOARD_PORT`'s base), a third allocator actively fighting `env:pull`'s
`.env.ports` rendering; and its non-port propagation is superseded by each
checkout rendering its own `.env.local` from Secret Manager via `env:pull`.
Both `package.json` entries and the runbook references
(`docs/notes/cicd/staging-ops.md`, `docs/notes/cicd/env.md`) were removed in
the same commit, which also dropped the now-nonexistent `--no-ports` flag
from every remaining `env:pull` caller (including CI's `render-sm-env.js`,
which would otherwise have broken on the flag-removal in `b144b5e99`).

Opting content-engine into the dotfiles-side registry was already done
before this PR and required no code change: it is opted into
`worktrees/.config/worktrees/config.json` today (repo identity
`github.com/kalem-edlin/content-engine`, `slot_capacity: 20`, services
`NEXT`/`DASHBOARD`/`ENGINE`/`EXPO`, `block_size: 100`, default tier `warm`).

**Still open — live-state operator work, out of PR #431's scope, not a PR:**

- Port repair on slots 10 and 12: one-time restoration of the correct
  `(N - 1) * block_size` ports on slots 10/11 and 12/13, currently corrupted
  by the old linear `slot - 1` formula (both pairs currently share identical
  dev-server ports). Confirmed with `worktree-slot ensure <N> --dry-run`:
  `ensure 11 --dry-run` also hit a *live* listener on port 9081 (an Expo dev
  server whose cwd is `content-engine-10`), so the repair needs that process
  stopped or moved, not just config values fixed.
- Per-slot `.worktree-claim` marker migration for **all 14 currently-claimed
  slots** (1-14; only slot 15 is unclaimed — slot 3 was claimed partway
  through the 2026-08-02 investigation session, which is why an earlier pass
  that session counted it among the unclaimed). Legacy markers are key=value
  or colon-delimited (`worktree-claim`'s `wt_marker_is_legacy` treats both
  identically — any `.worktree-claim` content that is not valid JSON).
  Example, from `content-engine-1/.worktree-claim` (itself one of the 14
  unmigrated slots):
  ```text
  holder=kalemedlin
  branch=fix/straight-to-app-attribution-readiness
  tmux_session=roll-1-web-billing
  date=2026-07-31T15:24:48.287Z
  ```
  Migration rewrites `owning_user`/`session_uuid`/`active_writer_host` to
  whoever runs it, so each slot must be migrated by its actual current
  owner, one at a time — never batch-scripted blind.
- ~~Convert Playwright's hardcoded port 3014~~ DONE 2026-08-03 in PR #433,
  and differently than proposed: no new dotfiles service entry needed.
  `apps/tanstack/playwright.config.ts` now derives `baseURL` and
  `webServer.port` from `DASHBOARD_PORT` (its `test:e2e` script already runs
  under `with-local`, and `pnpm dev` binds `${DASHBOARD_PORT:-3010}` — the
  3014 was a fossil of the old stride-1 formula and only ever matched a
  checkout whose `.env.local` said 3014). `supabase/config.toml`'s
  localhost redirect enumeration (3010-3014) was port-globbed in the same
  commit.

**What already works today, independent of PR #431 merging.** The
dotfiles-side `worktree-slot` and `worktree-claim` executables are capable of
operating against content-engine's opted-in configuration right now,
including against slots that still carry a legacy marker — but capable is
not the same as exercised: as of the 2026-08-02 investigation there are zero
`.worktree-slot.json` manifests across any of the 15 slots, so no slot has
ever actually had the new allocator run against it. `worktree-slot ensure`,
`worktree-claim claim/release/status/verify-writer`, and the deterministic
port allocator would all run today if invoked. `.worktree-claim` is already
globally ignored by dotfiles'
`core.excludesfile` (`git/.gitignore_global`), independent of content-engine's
own now-redundant `.gitignore` entry, so a claim marker never needs to be
committed to get that behavior. `wt_marker_is_legacy` in
`worktrees/.local/lib/worktrees/common.sh` detects a pre-migration marker by
the same test used above (present but not valid JSON) and labels it "legacy
claim marker (unmigrated — see content-engine extraction PR)" in
`status`/`doctor` output, with a `verify-writer` stderr warning — but it does
NOT block writes. New claims and handoffs written by `worktree-claim` on any
slot, migrated or not, always use the current JSON schema.

**What remains true until PR #431 merges:** content-engine's own
`worktree:claim`/`worktree:release`/`worktree:status` scripts stay live on
`main` and duplicate the dotfiles-owned implementation. Enforcement over any
unmigrated slot stays advisory-only regardless of merge state — a warning,
never a block — until each slot's marker is actually migrated, per the
INTERIM BEHAVIOR decision recorded in the adversarial-audit findings above.
Of the two disagreeing port derivations, both are now gone from the code:
the GCP renderer's `(slot - 1) * 100` was deleted with `worktreePorts.ts`
and `sync-env-worktrees.ts`'s plain `slot - 1` was deleted with that script
(both in PR #433). The live corruption they left behind persists: slots
10/11 and 12/13 keep colliding until the port-repair item above runs,
whether or not PRs #431/#433 have merged.

See also "Content-engine inconsistency to replace" and "Relationship to
content-engine" earlier in this document for the design rationale behind
these items; this subsection is the authoritative checklist for what
remains.

### Wave 0 and Wave 1 results (2026-08-02)

Wave 0's SSH-only worker surface ran **17/17 PASS**: both workers'
`preflight.sh`, Treemux/plugin-version inventory, the `allow-passthrough` +
key-table check, a worker-side `git ls-remote` against a disposable origin,
both timer wrappers' `--check` self-test, and `make headless-doctor`
(`mini` 65/65, `agents-roll` 64/64).

Wave 1's fully parallel hermetic contracts (lanes 1A-1E: config/command
preflight, sync-engine fault injection, provider-adapter fixtures, worktree
slots/ports/claims, private focus-tmux behavior) ran **32 PASS / 2 FAIL / 4
DEFERRED** — mostly green, not a fully clean pass; which specific assertions
failed or were deferred is not itemized in this round's record. Fully proven
within that run: the complete sync-engine fault-injection sweep (divergence,
truncated transfer, post-apply mismatch, apply interruption) against the
documented exit-code contract (0/2/3/4) with zero silent overwrites on any
failure path, and both `RW_SSH_BIN` and `CA_SSH_BIN` seams honored and
independent, including CA's documented fallback to RW.

Also verified this round: `agents-roll` runs tmux 3.4, `mini` runs 3.7b. The
tmux >= 3.7 delimiter patch (`bbd0211`/`d232f42`) is confirmed correct and a
no-op on 3.4 — a literal TAB survives `-F`/`display-message -p` intact there,
and real save files on both workers parse correctly. No defect found. Caveat:
the original 3.7b corruption could not be reproduced against the currently
running server on `mini`, so the patch comment's "always sanitizes, no
off-switch" claim is asserted more strongly than is presently reproducible.

Cleanup found along the way: two leftover `smoke-headless` sessions (one per
worker) from an earlier run were found and removed by exact-match kill; zero
tmux processes remain on either worker afterward. Also found, not a failure:
plugin pin drift — `tmux-fzf` and `tpm` sit at different HEAD SHAs on `mini`
vs. `agents-roll`; the two workers are not bit-identical.

Two defects found and fixed along the way, independent of (a)/(b)/(c) above:

- `pi versions --worker` was broken: pi prints its version to stderr, so
  reading it with `2>/dev/null` always returned empty and the command died
  before reaching the SSH seam. Fixed and verified end-to-end against `mini`.
- `rw doctor` is not literally read-only — per-worker preflight appends to the
  events log (the exact behavior Lane 1A's assertion above was written to
  observe). Its usage text was corrected rather than removing the
  observability.

New durability fix, worth its own note: tmux-resurrect's `save_all()`
repointed the `last` symlink at any save that merely *differed* from the
previous, with no validity check, so a partially-written save could silently
become the authoritative restore source. Real occurrence: `agents-roll` wrote
a 0-byte save on 2026-08-01 and `last` pointed at it for 13 seconds. Now
gated on >=1 well-formed pane record plus a complete trailing `state` record
(`save_all` writes `state` last, so a complete `state` line proves the whole
write finished); on rejection `last` stays at the previous good snapshot.
Shipped as `setup/patches/tmux-resurrect-save-validity-gate.patch` with a
`headless-doctor` check. The sibling `tmux-workspace-resurrect` writes via
mktemp+mv and does not have this hole.

All fixes above landed at commit `fa5cd83`. Every result in this subsection
ran against the workers at `453fc1a`. **Resolved 2026-08-03:** both workers
were pulled to `af75b5a` and `install_tmux_plugins` was re-run on each; the
save-validity gate is now applied and both headless doctors pass fully
(`agents-roll` 65/65, `mini` 66/66). `gh auth login` on `agents-roll` was
also completed by the operator on 2026-08-03 (verified: account
`kalem-edlin`, active), clearing the Wave 5 auth gate.

### Campaign record (2026-08-03): full Waves 1-6 run, defects, and fixes

Run id `rw-smoke-20260803-w1r2`; evidence for every lane under the session
scratchpad (`.../scratchpad/rw-smoke-20260803-w1r2/<lane>/`, per-lane
`assertions.jsonl`/`manifest.json`/`cleanup.json`). Sonnet subagent lanes,
coordinator-verified. Both workers tracked dotfiles main throughout
(453fc1a -> af75b5a -> 41605ec -> d8630a5 -> fa120eb -> c9eec00 -> 601fe37);
save-validity gate applied on both, headless doctors fully green
(`agents-roll` 65/65, `mini` 66/66), `gh auth` on agents-roll completed.

**Wave 1 re-run (hermetic, itemized — supersedes the 32/38 record):**
- 1A config/commands 25/25; findings: `rw status` leaks jq noise on a
  malformed registry entry (reconcile handles it cleanly); `rw doctor`
  calls bare `tmux` with no test seam (lanes must PATH-shim).
- 1B resolution + sync engine 94/94; exit contract 0/2/3/4 exact.
- 1C adapters 108/108 (incl. smoke-test 11/11, pi stderr fix confirmed,
  zero auth leakage against planted decoys).
- 1D slots/ports/claims green; found+fixed REAL BUG: exit-12
  no-session-identity was swallowed by command substitution in
  claim/release/handoff-writer/return-writer -> identity-less claims with
  empty session_uuid could silently overwrite each other (`41605ec`).
- 1E/1E2 private focus tmux: CRITICAL harness finding — a private socket
  does NOT isolate resurrect; on server recreate `@resurrect-dir` (runtime
  option) is lost and save.sh falls back to the real
  ~/.local/share/tmux/resurrect (a lane snapshot briefly became the real
  `last`; self-healed by continuum; debris cleaned). Mitigation now
  standard: lane conf via `-f` (mk-lane-conf.sh) pinning @resurrect-dir,
  asserted before every save/restore. 1E2 redo 25/26 clean; the one FAIL
  was harness methodology (prefix key table has no auto-expiry; a lone
  C-a probe poisons the next sequence — pair keys atomically).

**Waves 2-3 (endpoint/Treemux/transport, both workers):** core lifecycle,
placement modes, splits/status/closes, remote-only Treemux guarantees,
capped 1/2/4/../30s backoff, worker-server-loss rebuild, and both
unwrapped production canaries PASS. Open question answered: the detach
hook DOES fire on abrupt SIGKILL (~1s, far faster than the timer).
Found+fixed (`d8630a5`): prefix q dead on remote panes (run-shell has no
TMUX_PANE; binding now passes --pane #{pane_id}); prefix & closed only the
first endpoint (ssh drained the while-read stdin); ghostty's
TERM=xterm-ghostty broke every agents-roll attach (attach now pins
TERM=screen-256color).

**Wave 4 (handoff/return, both workers):** state fidelity byte-exact
(porcelain-v2 index/worktree split, binary, rename, deletion, untracked,
LFS materialization), divergence refusal + recoverable backups, transfer/
apply failure guarantees all held. Found+fixed (`fa120eb`): rw return
clobbered fresh sync metadata with its pre-sync snapshot (next sync
spuriously "diverged"); failed handoff did not roll back the
handoff-writer claim flip; --force-diverged was named in the error but
rejected by the CLIs; --check-lfs was hardcoded into preflight (now
caller-or-autodetect); macOS AppleDouble xattrs broke cross-OS fingerprint
verify (COPYFILE_DISABLE=1 on all tar creates). Incident (w4m): a failed
`cd` left a lane shell in the real dotfiles checkout and pushed junk to
origin/main; reverted non-destructively (4 content-neutral commits:
114a24e/05c8006/4999c18/bb0b197; `git diff d8630a5..bb0b197` empty).

**Wave 5 (live provider matrix) + redo:** codex-on-mini delivered a fully
clean cross-host resume with sentinel continuity. Found+fixed across
`c9eec00`+`601fe37`: pi resume used the SOURCE-host transcript path
(destination silently started a fresh session while the registry said
"resumed"); claude_slug only slugged '/' while claude slugs EVERY
non-alphanumeric (dotted fixture paths -> transcript in a dir claude never
scans -> "No conversation found"; discovery is a pure filename scan of
~/.claude/projects/<slug>/, no index — confirmed via docs agent); both
provider-start verifiers had a host-global pgrep fallback that verified
resumes off unrelated processes (now pane-PID-tree scoped +
match-must-hold-twice stability); rw return dispatched the "local" resume
into the REMOTE shell because the pane was still attach-loop->ssh (return
now releases the pane first; attach-loop gained a pane-released exit that
execs a login shell — plain exit killed the pane since the loop is the
pane's root process); Node-only version drift (24.18.0 vs .1) blocked
every pi/codex return (CLI-equality now proceeds per the adapter
contract); `--pane X` handoffs hijacked the caller's terminal (now
respawn X, and only when X is a plain shell — respawn-pane -k was
destroying still-running source agents); originless git worktrees fell
through to plain-$HOME placement and applied repo contents into workers'
real $HOME in three lanes (now refused with guidance). Trust dialogs:
claude/codex show per-directory trust prompts on fresh fixture dirs; lanes
either pre-seed trust for lane-owned dirs (jq-only, no file contents read,
removed at teardown) or record BLOCKED — never click through blind.

**Wave 6 (agent-safe private drills):** 24 PASS — ambiguity safety,
5-point reconciliation contract, namespace-scoped orphan cleanup (decoys
byte-identical), worker-loss manifest rebuild, real resurrect dir/`last`
untouched. Found+fixed (`601fe37`): rw-post-restore's session-UUID
re-stamp was dead code (display-message missing -p); libexec/reconcile
closed one orphan per invocation (ssh drained the here-string stdin);
sibling-rebuild race — with 2+ endpoints on one worker server, the
post-loss race loser saw "server up, session absent" and wrongly
self-tombstoned as remote-intentional-close (session-absent now compares
the server's start_time to the last successful attach; rebuilt server ->
recreate, same server -> intentional close).

**VERIFICATION PENDING — the final verification lane (W5F) was stopped by
the operator mid-run.** The `601fe37` fix set is therefore shipped but NOT
yet verified live. Outstanding proofs (V1-V6): pi cross-host sentinel
continuity both directions; claude continuity with a dotted workspace
path; cross-pane return leaves pane X alive as a local shell; two
endpoints both survive a worker-server loss (no false tombstone);
reconcile closes 4 orphans in one invocation; restored sessions re-resolve
their original @session-uuid.

**Design/robustness backlog (recorded, deliberately not hot-fixed):**
retained endpoint after return is reusable/closeable only manually (fresh
ensure mints a duplicate; no `rw close --endpoint <id>` form);
force-diverged overwrite leaves destination-only untracked cruft (verify
exit 4) and its backup excludes LFS objects; a killed remote session can
wedge the attached worker tmux client for minutes before reconciliation;
rapid concurrent `rw close` calls can misreport `remote=
unreachable_or_absent` and leak live remote sessions (3s probe-timeout
contention); Treemux worker-side registration options go stale after
sidebar close; reflected-mode preflight demands origin reachability it
does not need; a Ctrl-Z-suspended source agent survives the post-resume
stop; ambiguous-restore panes keep a stale queued command in their buffer;
`rw status` malformed-entry stderr noise; `rw doctor` bare-tmux seam.
Worker provisioning: agents-roll Neovim 0.9.5 is too old for the Treemux
plugin stack (needs >=0.10) — belongs in linux-headless.sh plus a doctor
check.

### Remaining smoke-test surface (as of 2026-08-03, end of campaign day)

Honest accounting of where the waves above actually stand:

PROVEN (see "Campaign record (2026-08-03)" above for full detail):

- Wave 0 (17/17) and the full itemized Wave 1 re-run (1A-1E2, ~300
  assertions, zero unresolved product FAILs);
- Waves 2-3 on both workers: endpoint lifecycle, placement modes,
  splits/closes/status, remote-only Treemux guarantees, connection-loss/
  backoff, worker-server-loss rebuild, unwrapped production canaries; the
  detach hook empirically FIRES on abrupt SIGKILL;
- Wave 4 on both workers: byte-exact handoff/return state fidelity,
  divergence refusal, recoverable backups, transfer/apply failure
  guarantees;
- Wave 5 partially: codex cross-host handoff/return with real sentinel
  continuity (mini); the real authenticated `codex resume` works; the
  duplicate-writer guard is registry-scoped (immune to process-scan
  misfires);
- Wave 6 agent-safe drills: ambiguity safety, the 5-point reconciliation
  contract, namespace-scoped cleanup, worker-loss rebuild.

PENDING VERIFICATION (fix set `601fe37` shipped, final lane W5F stopped by
the operator before completing): V1 pi continuity both directions; V2
claude continuity on a dotted workspace path; V3 cross-pane return leaves
the target pane alive; V4 both endpoints survive worker-server loss; V5
reconcile closes all orphans in one pass; V6 restored sessions re-resolve
their original @session-uuid. Re-run lane W5F to close these.

BLOCKED on a brief human check, unrelated to worker auth:

- the final terminal-emulator OSC 52 clipboard confirmation.

DEFERRED to a final, explicitly-warned step: Wave 6's serialized production
canaries against the live focus-machine tmux server — real timer firing
without isolation, default-server-loss inventory, worker reboot recovery,
and the optional focus-Mac sleep/wake drill.

Operator items outstanding (unchanged): content-engine slot 10/12 port
repair (slot 10's Expo still squats 9081); per-slot claim-marker migration
(14 slots, each by its owner); PRs #431/#433 blocked on the red
provision-supabase check; agents-roll Neovim >= 0.10 provisioning.

## Research references

- tmux control mode and stable server-lifetime IDs:
  <https://github.com/tmux/tmux/wiki/Control-Mode>
- Continuum autosave behavior and status-line requirement:
  <https://github.com/tmux-plugins/tmux-continuum>
- Claude user-level instruction location:
  <https://code.claude.com/docs/en/memory>
- Codex global `AGENTS.md` behavior:
  <https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide#using-agentsmd>
- Git linked-worktree metadata:
  <https://git-scm.com/docs/git-worktree>
- tmux detach hooks do not fire on signal-based client termination:
  <https://github.com/tmux/tmux/issues/1174>
- Deferred Mutagen and Mosh investigation:
  [`deferred-sync-and-transport.md`](./deferred-sync-and-transport.md)
- OpenSSH connection multiplexing:
  <https://man.openbsd.org/ssh_config>
- Claude local session storage and resume scoping:
  <https://code.claude.com/docs/en/sessions>
- Pi session management:
  <https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/README.md#sessions>
- tmux clipboard behavior over SSH and nested tmux:
  <https://github.com/tmux/tmux/wiki/Clipboard>
- Workmux prior art:
  <https://github.com/raine/workmux>
- Treemux root selection and worker-local sidebar implementation:
  <https://github.com/kiyoon/treemux>
- tmux working-directory semantics (`pane_current_path`, `new-window -c`, and
  `split-window -c`):
  <https://github.com/tmux/tmux/wiki/Advanced-Use#working-directories>
