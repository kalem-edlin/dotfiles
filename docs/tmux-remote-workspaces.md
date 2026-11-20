# Tmux remote workspaces

Tmux Remote Workspaces keeps the laptop tmux server as the only visible
coordination layer and lets a directory, with every pane working inside it,
continue on an always-on worker. The unit of handoff is a directory root: the
git toplevel of a worktree, or a plain folder. Whoever holds a root owns it.
While a root is remote, the worker copy is the single source of truth and each
of its laptop panes attaches to its own durable tmux session on the worker.
Remote execution is opt-in. This document records the current system and the
decisions needed to maintain it. It is not an implementation plan or backlog;
the plan that produced the directory model is `docs/tasks/remote-owned-directories.md`.

The colocated plugin README at
[`tmux/local-plugins/tmux-remote-workspaces/README.md`](../tmux/local-plugins/tmux-remote-workspaces/README.md)
is the command and operational reference.

## System rules

### Local first

New shells, windows, and agents start locally. `prefix e` opens one menu for
the focused pane. Its first rows move only that pane to another host (a soft
switch). Its last rows transfer the pane's root: one row per remote hands the
root off to it, or one row hands it back when a remote owns it, whichever pane
it is pressed from. A handoff (such a row, or `rw handoff --worker <alias>`) moves every pane
on the laptop server whose cwd is the root or inside it, in any session and
at any depth. The rest of a mixed session stays local. Transfers run in the
background (`rw bg`), so the popup closes as soon as the choice is made. See
"Pane host switching" for the menu.

A new window or split follows the pane from which it was requested: from a
remote pane, with or without ownership of its directory, it opens on that
same remote in the pane's directory, and from a local pane it stays local,
even beside remote panes. The picker's new-window and bare-worktree actions
follow the owner instead: they call `rw open` when the root is remote.

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

A worker session dies only through an explicit hand-back, `rw forget`,
`rw close`, or a soft switch of its pane to another host. No component deletes an endpoint or a copy merely because it is
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
with no sync. `rw switch` creates one for a pane that visits a worker, or
reuses the `rw open` path when that worker owns the directory. An endpoint
is `owned` (listed in its root's ownership record, the default) or `visit`
(the same hidden session and attach loop with no ownership record behind it).
Each endpoint follows this sequence:

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
held/<worker>/<root_id>.json         every worker copy this machine created, kept after hand-backhandoff-backups/, handoff-staging/   git-channel backups and staging on the side being written
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
which workers still hold a copy. A visit endpoint has no record, so the
worker keeps a small marker for it, `visits/<endpoint_id>.json` under its
own state root, written when the endpoint is created and removed whenever the
endpoint closes.

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

A pane that is already visiting the target worker inside the root (a soft
switch put it there) is not moved again. The handoff adopts it: its endpoint
becomes owned and joins the record, with no second session and no respawn,
and its visit marker goes once the mirror is written. A visiting pane that
is mid-turn with an agent refuses the handoff before anything stops. Visit
panes on other workers are left as they are. A hand-back moves only the
record's endpoints, so those panes stay where they are, off-owner.

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
local shell enters a frozen root, naming the worker alias and `rw handback`,
and the host chip turns red (see "Pane host switching"). From such a pane,
`prefix e` lists the root's owner as its first, marked row, so enter moves
the pane there in the same directory (the `rw open` path) without a prompt.

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
ownership records directly and never polls over SSH. Remote agents show
their state like local ones, from the options the attach loop mirrors onto
their panes (see "Remote agent state").

Provider adapters for Pi and Claude own transcript discovery, version
checks, export, install, resume commands, and process matching. They do not own
tmux or workspace transfer. Resumes go through `claudef --resume` and
`pif --session` on both machines, typed into the endpoint's login shell, so
the same hooks run on the worker as on the laptop.
Transcripts are installed under the worker's physical path, which is what
Claude slugs its project directory from.

## Pane host switching

Ownership says which machine holds a root's files. A pane's host says where
its shell runs. A handoff moves both together. A soft switch moves only the
focused pane, in the same directory: no files move and ownership does not
change. Three terms carry the rest of this section:

- The owner host of a path is the remote named by the ownership record whose
  root contains the path, otherwise this machine. A path that was never handed
  off belongs to this machine.
- The pane host is the remote the pane's attach loop runs on, otherwise this
  machine.
- An off-owner pane is one whose host is not the owner host of its directory.
  Every soft switch away from the owner makes one, and so does the frozen
  local copy of a remote root.

Nothing here is specific to one worker. Any number of workers declared in
`config.json` appear as menu rows. The UI says `remote` and `this machine`,
never a host name, and follows `remote` with the configured alias in
parentheses where the menu has to tell remotes apart.

### The `prefix e` menu

`prefix e` opens one popup for the focused pane. It first works out the pane's
directory: a local pane's own, or a remote pane's live directory on the
worker, asked over one ssh with a hard deadline. It then finds the root, the
owner and the pane host. The popup keeps its size (70% by 60%); the content
is what fits it, so no row is padded to a common width and no label carries
the root's path.

The header is a muted grey, not the red the shell's `FZF_DEFAULT_OPTS` would
give it. Its first line names the directory and its root (`<dir> (root)` or
`<dir>  ·  root <root>`). A second line, `pane on <host>  ·  owned by <host>`,
appears only when the two differ, or when the pane's remote is unreachable or
no longer in `config.json`. Warnings are yellow: an unreachable remote, a
directory only the remote has, a root that cannot be handed off (outside `~`
or `~` itself). When a hand-off row is offered and more than one pane would
move, a line `moves: <session>:<window>.<pane> <command>, ...` names them,
folded to the popup's width.

Each row starts with a reachability marker, then the label, then a short note
when there is one: a grey `…` while the remote is being probed, a green `●`
online, a red `○` offline, and nothing for a row that needs no remote (this
machine, hand back, release). The marker fills in without moving the cursor.

The rows, in order:

1. Soft-switch rows, one for every host except the pane's own: this machine
   and each configured remote. The owner comes first, marked `(owner)`, so
   enter picks it. Then this machine, then the other remotes in `config.json`
   order. When the pane has an agent and the destination is not the owner,
   the row says `⚠ agent would work on a non-owner copy`.
2. The full-transfer rows last. Their direction comes from the owner, not from
   where the pane runs. When a remote owns the root, one row reads "hand back
   to this machine", from a local pane or a remote one alike. When this
   machine owns the root, there is one row per configured remote, "hand off to
   `<alias>`", so with several remotes each choice names where it goes (the
   pane's own remote first). Either label adds `(N panes)` when more than one
   pane moves. The root is the one the header names, even if the pane has
   since changed directory. The hand-off rows are absent when the root is
   outside `~` or is `~` itself (the header says so), when the directory
   exists only on the remote with nothing enclosing it here to hand off, and
   when no remote is configured.

Choosing a row is the confirmation. There is no yes or no prompt, including
for a hand-back, and `esc` runs nothing. There is no second menu to pick the
remote. Transfers start in the background and the popup closes. A soft switch
runs in the popup, since it is quick. A refusal that `rw bg` finds at once,
such as a root already moving, shows in the popup as a notice. Later
conflicts and failures open their dialogs as before.

If the pane's remote does not answer within the probe deadline, or its alias
is no longer in `config.json`, the header says so and the menu changes. No
soft-switch row is offered, because each one needs that remote. The first row
is instead "release this pane to this machine (remote unreachable)" (or
"remote not in config.json"). It runs `rw switch --to local --force`. The pane
becomes a local shell in the last directory it reported, or the nearest
existing parent, and prints one line saying so. Its endpoint leaves the
ownership record but stays registered with a pending close. Whatever still
runs on the remote, including an agent, is stopped by the next contact with
that remote (any handoff, hand-back, open, switch or forget), and restore
never reattaches that endpoint. Release changes no ownership, and a transfer
row that needs the dead remote (a hand-back to it, a hand-off to it) is left
out. `rw reclaim --force` is the separate way to take a
remote-owned root back. A reachable remote ignores `--force`, so the same
command is then a normal switch.

### Soft switch

`rw switch --pane <pane> --to <alias|local> [--dir <abs-path> | --dir-of <pane>]`
is what the menu runs. It is synchronous and moves one pane, in the same
directory.

- To a remote that owns the directory's root, the pane gets an owned endpoint,
  made as `rw open` makes it and listed in the record. To any other remote it
  gets a visit endpoint, which has no record. Either way the worker directory
  is the mapped path, or its nearest existing parent with one printed line
  saying so.
- To this machine from a remote pane, the attach loop is replaced by a local
  shell in the same pane, window and layout, in the mapped local directory
  (the nearest existing parent when missing). The worker session closes and
  the endpoint is unregistered, and removed from its record when it was owned.
- Remote to remote works the same way, closing the source endpoint after the
  new one is attached.

What moves with the pane is the program in it. A shell moves as it is. A
`claudef` or `pif` agent moves through the provider adapters, the same
export, install and resume as a handoff without the directory sync, and the
source agent stops only after the destination resume is confirmed, so there
are never two writers and never zero. If anything fails before then, the new
endpoint is discarded and the source is untouched. An editor (nvim, vim, vi)
reopens on the destination, best effort, and unsaved buffers never travel.
Files and ownership do not move. After a soft switch away from the owner, the
pane works on whatever copy the destination has, which may be stale.

A switch refuses, with exit 7 and one `rw: <reason>` line, when:

- the pane already runs on that host;
- the pane is a remote file tree pane (close it with `prefix Tab`);
- its foreground program is not a shell, an editor or a recognized agent
  (quit it first), checked on the remote for a remote pane;
- an agent in it is working, or a remote agent has no session record to move;
- an agent's directory does not exist on the destination, because Claude finds
  its transcript by path;
- a background transfer of the root is running (`rw bg`).

The other exit codes are those of the rest of `rw`: 3 when an agent's CLI
at the destination is older than the one that wrote the session (remote to
remote compares the two remotes, since this machine's version does not
matter); 6 when the destination, or the pane's own remote, is unreachable,
with the pane unchanged; 64 for usage or an alias not in `config.json`; and
1 for any other failure, which leaves the pane as it was. A remote pane whose
session is missing on its remote also exits 1 while that remote is restoring
its sessions or when an agent ran in it, so a restoring remote never has its
agent mistaken for an empty shell. Every root a switch touches is locked while
it runs.

### New windows and splits

`prefix c`, `prefix \`, and `prefix /` follow the pane host. From a remote
pane, owned or off-owner, they open a new window or split on the same remote
in the pane's directory. The window or pane appears at once as a local shell in
the title-based directory, with no ssh in the key press, and `rw switch
--dir-of <source pane>` then runs in it, asks the remote for the live
directory, and attaches the remote shell, in about half a second. If the
remote cannot be reached, the new pane simply stays a local shell. From a local
pane, `prefix c` and the splits are ordinary local ones, even beside remote
panes in the same window. The picker's new window (`prefix o`, then `w`) is
the one exception: it follows the root's owner, opening remote for a remote
root.

### The red host chip

The host chip in the status line is red instead of its usual color
while the focused pane is off-owner. The pane option `@rw-off-owner` (`1` or
unset) drives it, and `rw-refresh-indicators.sh` is its only writer. It shows
in two cases:

- A remote pane whose directory this machine owns, or another remote owns. The
  directory is the one the endpoint was opened in, not whatever the shell has
  `cd`'d to on the worker since.
- A local pane in a directory a remote owns, which is the frozen copy.

A pending forget does not make a remote the owner. The flag is recomputed when a local shell changes
directory (the zsh `chpwd` hook, which runs while any ownership record
exists), when an endpoint's attach loop starts, after every handoff, hand-back,
switch, open, reclaim and forget (for every pane in the root), after pending
actions finish, and after restore. It makes no ssh and runs under one lock, so
the last run always writes the newest state. A restore recomputes it and never
trusts the saved value.

### Restore of visit panes

Panes connected to a remote restore as such on both machines, visit panes the
same as owned ones. On the laptop, `rw-post-restore.sh` reattaches a visit
endpoint by endpoint id, and the sidecar treats the pane as captured. On the
worker, the hidden session is saved by the worker's timer and restored by the
boot restore. `rw-worker-post-restore.sh` keeps it because its visit marker
names a different focus machine, and re-applies the hidden-session options as
for any `rw-*` session. Reconciliation never closes a visit endpoint for
lacking an ownership record. The one exception is an endpoint with a pending
close, which restore leaves alone.

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

## Remote agent state

An agent on the worker publishes its state into the worker's tmux server,
through the same `claudef` and `pif` hooks as on the laptop. Each attach
loop mirrors it onto its laptop pane, so the picker, the Working guard and
anything else that reads `@agent_*` see a remote agent like a local one.

- `attach-loop.sh` starts `libexec/remote-state watch` in the background
  just before each attach and stops it before the next attempt and on every
  exit. It is one long-lived ssh per endpoint on the alias's ControlMaster,
  never one per poll, and it shares the loop's process group.
- The ssh runs a worker-side loop, sent inline, so the worker needs nothing
  installed. Every 2 s it reads the endpoint pane with one local
  `tmux display-message` and prints a line only when something changed,
  with a heartbeat so a dead connection ends it. Polling is used because
  tmux has no hook for a user-option change and the publishers are the only
  writers.
- Mirrored: `@agent_kind`, `@agent_state`, `@agent_state_at`, `@agent_at`,
  `@agent_name`, `@agent_subs`, `@agent_empty`, and `@agent_cwd` mapped back
  to the laptop path. `@agent_pid` is not mirrored. The worker loop checks
  the pid there, and the mirror unsets a stale local one.
- A finished turn becomes Done or Idle by whether the laptop pane is in view,
  as for a local agent. The worker cannot tell, because its hidden session
  always looks visible.
- When the worker is out of sight, `@agent_state` becomes `disconnected`,
  never a stale `working`. This happens when the stream ends, the worker
  reports the session gone, or the probe finds the worker unreachable. The
  picker shows it as a grey chip. When the loop exits, it unsets every
  mirrored option.
- The same line carries the worker pane's `@rw-request`. An agent on the
  worker that runs `rw request handback` sets it. The channel clears it on
  the worker, then runs `rw bg handback --pane <laptop pane>` through
  `tmux run-shell -b`, detached from the loop that the hand-back replaces.

The contract, including the line format and the rejected alternatives, is
"Changes recorded by B2" in `docs/tasks/remote-owned-directories.md`.

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

rw never starts the worker's tmux server with a bare `tmux new-session`. That
would load the worker's `tmux.conf`, whose Continuum restore-on-start then runs
the guarded restore into the server rw just made. That restore fails and
leaves the incomplete-restore marker
(`<TMPDIR>/tmux-resurrect-<server pid>-restore-incomplete`), and every later
verified save on the worker is refused. When `rw handoff`, `rw open` or an
attach loop's rebuild finds no server, rw runs the boot restore wrapper with
`--start <session> <dir>`. The wrapper restores the last snapshot and creates
the session before it drops its bootstrap session. With no snapshot it starts
an empty server and removes the marker that Continuum's empty attempt left.
rw waits up to 120 s (`RW_WORKER_START_TIMEOUT`) for a restore in progress or
a boot lock (wrapper exit 75). rw refuses a live server whose last restore did
not complete, because nothing created there would ever be saved. The refusal
is one line naming the marker and the remedy: run the guarded restore
(`prefix C-M-r`) or restart the server. `rw handoff` checks this before any
agent stops. `rw doctor` reports the state for each worker and lists markers
of servers that have exited. The wrapper deletes those markers on its next
run.

After rw creates or closes worker sessions, it asks the worker for a verified
save without waiting for the result. The worker runs the trigger in the
background under `nohup`, and its shell returns at once. This machine's ssh
runs detached, so no command or pane waits on it. `launchctl kickstart` of a
job spawned less than its `ThrottleInterval` ago (10 s by default) blocks
until that window has passed. When rw waited on it, a split made right after
a close took 5 to 9 s longer.

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
| `prefix e` | One menu for the focused pane: soft-switch rows (this machine and each remote except the pane's own host), then the transfer rows: hand back when a remote owns the root, one "hand off to `<alias>`" row per remote otherwise. Each remote row shows a reachability marker. Choosing a row is the confirmation. Transfers run in the background |
| `prefix c` | New window on the pane's host: local from a local pane, the same remote from a remote pane |
| `prefix \\` / `prefix /` | Split on the pane's host, with the same rule as `prefix c` |
| `prefix q` | Close the focused endpoint through tombstone-first teardown, otherwise kill a plain pane |
| `prefix &` | Confirm, close all endpoints in the window, then kill the window |
| `prefix Tab` | Open local Treemux or toggle a remote tree endpoint |
| `prefix [` / `PageUp` | Enter local or worker-side copy mode as appropriate |
| `prefix Ctrl-s` | Run the verified local save and, when focused remotely, the worker save |
| `rw status` | Print remote roots (owner, worker, panes, pending), then each endpoint's live pane and latest event |
| `rw doctor` | Report local, worker, registry, reconciliation, ssh config speed, and clipboard health |
| `rw switch` | Soft-switch one pane to a remote or back to this machine, in the same directory. No files move |
| `rw bg handoff` / `rw bg handback` | Check, return at once, then transfer detached after the root's agents go idle; status-line chip, dialogs on conflict or failure |
| `rw request handback` | On the worker side of a pane: ask the laptop to hand the root back |
| `/remote-handoff to [worker]` / `back` | Agent skill: the agent hands off its own directory and continues on the other side |

The CLI forms are `rw handoff`, `rw handback`,
`rw bg handoff [--worker <alias>] --pane <pane> [--wait-idle <seconds>]`,
`rw bg handback --pane <pane> [--wait-idle <seconds>]`,
`rw request handback`, `rw open`,
`rw switch [--pane <pane>] --to <alias|local> [--dir <abs-path> | --dir-of <pane>] [--force]`,
`rw forget`, `rw reclaim --force`,
`rw status [--json]`, `rw close`, and `rw doctor`. `rw bg` exits 0 once
started, 1 when a transfer of the root already runs or the pane is
missing, 7 for an invalid, already remote or not remote root or the
worker side, and 64 on usage; the transfer's own codes go to its log and
dialog.
Exit codes: 0 ok, 1 failure, 2 git history diverged, 3 agent CLI too old,
5 manifest conflict, 6 worker unreachable, 7 root invalid or not in the
required state (`rw switch`: refused), 64 usage.

Navigation and resize bindings are ordinary local tmux commands. New windows
and splits follow the host of the pane they were made from, and the picker's
new window follows the owner of its root.

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
- `scripts/rw-open.sh`, `rw-switch.sh`, `rw-close.sh`, `rw-close-window.sh`,
  `rw-split.sh`, and `rw-new-window.sh` implement endpoint creation, the soft
  switch, and pane or window lifecycle. `rw-split.sh` and `rw-new-window.sh`
  back the splits and `prefix c`.
- `scripts/attach-loop.sh` owns reconnect and pane-release behavior and
  starts and stops each endpoint's agent-state side channel.
- `libexec/remote-state` is that side channel: the worker-side poll loop,
  the mirror of `@agent_*` onto the laptop pane, the `disconnected` value,
  and the `@rw-request` hand-back.
- `scripts/preflight.sh` checks configured workers without provisioning them
  and reports the worker's physical home.
- `scripts/resolve-workspace.sh` resolves a root and its `~`-relative worker
  placement without SSH.
- `scripts/rw-picker.sh` implements the `prefix e` popup: the soft-switch
  and transfer rows (one hand-off row per worker), the release row, and the
  reachability markers. It
  calls only `rw switch`, `rw bg handoff` and `rw bg handback`, and never
  creates endpoints itself.
- `libexec/rw-bg` is `rw bg`: the synchronous check, the `setsid` detach
  and the runner (wait-idle, transfer, conflict re-run, failure dialog).
  `libexec/rw-bg-dialog` runs the conflict dialog inside the runner's
  popup, and `libexec/rw-dialogs.sh` holds the conflict dialog and failure
  wording shared with the picker. `libexec/rw-request` is
  `rw request handback`.
- `scripts/rw-status.sh` and `rw-doctor.sh` expose state and health.
- `scripts/rw-copy-mode.sh` enters copy mode on the correct tmux server.
- `scripts/rw-refresh-indicators.sh` reconciles display caches with live attach
  loops, is the only writer of `@rw-off-owner` (`--pane`, `--root`, or every
  pane), and, with `--transfers`, sets `@rw-transfer` and
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
- `libexec/adapters/{pi,claude}` implement provider-specific session
  movement.
- `libexec/adapters/common-adapter.sh` holds their shared process and transport
  helpers.
- `libexec/adapters/README.md` records the adapter contract.
- `libexec/adapters/smoke-test` provides sandboxed adapter fixtures.
- `tests/run.sh` runs the shell tests for path mapping, ownership records,
  manifests, the rsync channel, sync round trips, and the CLI round trip
  against a same-host fake worker, with no tmux server and no network.
  `tests/test_remote_state.sh` covers the agent-state side channel.

### Reconciliation and remote tree

- `libexec/reconcile`, `reconcile-local`, and `reconcile-worker` cover restored
  desired sets, the unbound-endpoint report, and worker-side zombie sessions.
- `scripts/rw-treemux.sh`, `rw-tree-pane.sh`, and `rw-tree-listener.sh` own the
  tree and editor endpoint lifecycle.
- `nvim/rw-tree-init.lua` implements worker-side file-open routing.

### Tmux and persistence integration

- `tmux/tmux.conf` loads the two local plugins in order, enables passthrough,
  wires the status line, and replaces Treemux's binding.
- `tmux/tmux.reset.conf` owns picker, new-window, split,
  navigation, resize, close, reload, and restore bindings, including
  `prefix e`, `prefix c` and the splits.
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
- **2026-11-18 (R1):** Remote agents became visible on the laptop. Each
  attach loop runs one ssh side channel that mirrors the worker pane's
  `@agent_*` onto its laptop pane, with `disconnected` while the worker is
  out of sight. The same channel carries `rw request handback`.
- **2026-11-18 (`rw-pane-switching`):** `prefix e` became one menu: soft-switch
  rows that move only the pane (and its `claudef`, `pif` or editor) between
  this machine and any remote, then one transfer row whose direction the
  owner decides. Choosing a row is the confirmation, so the hand-back prompt
  went. Visit endpoints carry a pane to a remote that does not own its
  directory, `prefix c` and the splits follow the pane host, and a red host
  chip marks off-owner panes. A pane on an unreachable remote is released
  with `rw switch --to local --force`. Review findings were fixed before
  merge (`docs/tasks/remote-owned-directories.md`, "Pane host switching").

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
6. Run `rw doctor` for local and reachable-worker health. It is read-only. It
   also times `ssh -G <worker>` and fails above 300 ms
   (`RW_DOCTOR_SSH_CONFIG_SLOW_MS`). ssh evaluates a `Match ... exec` line on
   every call, before it looks at the ControlMaster socket, so one slow check
   (a LAN probe that hangs away from home, on the `mini` alias) once added
   1.5 s to every key that reached the worker. Keep such helpers cached.
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
