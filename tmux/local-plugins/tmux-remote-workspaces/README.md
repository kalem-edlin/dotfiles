# tmux-remote-workspaces

Personal local plugin that lets the laptop tmux server stay the single
visible coordination layer while handing whole directories -- a git
worktree or a plain folder, and every pane working in it -- to an always-on
worker (an ssh alias for an always-on Mac, or a Linux VM). Local-first:
remote is opt-in per directory, never the default. Worker names are logical
identities: OpenSSH may route an alias over a LAN listener or Tailscale
without the plugin treating those paths as different workers.

The model ("the unit is a directory, and whoever holds the directory owns
it"), its decisions and the binding contracts live in
[`docs/tasks/remote-owned-directories.md`](../../../docs/tasks/remote-owned-directories.md).

The maintained system design and decision record live in
[`docs/tmux-remote-workspaces.md`](../../../docs/tmux-remote-workspaces.md).
This README is the command and operational reference.

## Consume, never provision

This plugin never installs anything on a worker. Every operation that needs a
worker preflights it first (`scripts/preflight.sh`); a missing binary aborts
with a message naming `make setup-headless`, never an attempt to install it
itself.

## Command vocabulary

One dispatcher, `scripts/rw`:

```text
rw handoff --worker <alias> [--root <path>] [--pane <pane-id>] [--check-lfs]
           [--force-diverged] [--resolve overwrite|keep-both|abort]
rw handback [--root <path>] [--pane <pane-id>] [--check-lfs]
            [--force-diverged] [--resolve overwrite|keep-both|abort]
            [--wait-idle [seconds]]
rw open    [--worker <alias>] [--root <path>] [--pane <pane-id>]
rw forget  <root> [--worker <alias>] [--force]
rw reclaim [--force] <root>
rw status  [--json]
rw close   [--pane <pane-id> | --endpoint <id>] [--no-kill-pane] [--reason <text>]
rw doctor
```

- `handoff` moves a root to a worker: by default the pane's git toplevel,
  or the pane's directory when it is not in a repository. Every pane on the
  laptop server whose cwd is the root or inside it (any depth, any session)
  moves with it; the rest of a mixed session stays local. Without an
  explicit `--root`, a plain folder that is a top-level folder of `~` (like
  `~/Developer`) or that holds git repositories is refused (exit 7): hand
  off the project inside it, or pass `--root` to mean the whole folder.
- `handback` brings the root and all of its panes (and their agents) back.
  It replaces `rw return`.
- `open` is a new remote pane in a root that is already remote (splits and
  the picker use it). No sync. Idempotent: on a pane that already has a
  live endpoint it reattaches instead. It replaces `rw ensure`.
- `forget` is for a root that is gone (deleted worktree or session): it
  deletes every remote copy this machine handed off, then closes the root's
  remote panes. A remote directory that already existed before rw's first
  handoff is never deleted (only rw's mirror record goes). A root that is
  remote right now needs `--force` (its remote copy is the only current
  one); the picker and `wt rm` pass it after asking. An unreachable worker
  is cleaned up on next contact.
- `reclaim` takes a remote root back from the frozen local copy when its
  worker is unreachable: it probes the worker first and refuses when it
  answers (use `handback`); `--force` skips the probe. Remote work since
  the handoff stays on the (now stale) remote copy.
- Closing worker sessions (hand-back, forget, close, reconcile) asks that
  worker for a verified tmux save while it still has sessions, so its
  snapshot stops listing them. When none remain the server exits with a
  stale snapshot; the worker's post-restore (`rw-worker-post-restore.sh`)
  kills every restored `rw-*` session no worker-owned mirror lists, so a
  closed session never comes back (a session not in the snapshot, i.e. one
  rw is creating, is never touched).
- `forget` also prunes the root's backups and staging on both sides and
  removes worker parent directories the delete left empty (never a
  top-level folder of the worker's home); a successful hand-back keeps only
  the newest backup. Endpoint close removes the attach loop's
  `attach-seen/<endpoint>` marker.
- `close --endpoint <id>` closes a registered endpoint no local pane
  carries (e.g. an agent left running on a reclaimed root's stale copy).
- Every command that changes a root takes a per-root lock
  (`locks/root-<root_id>`, reclaimed when its holder died); a second one
  for the same root fails with exit 1 instead of interleaving.
- `status` lists roots (owner, worker, panes, pending) and endpoints; it
  never touches ssh. `--json` prints the ownership records as one array.

Exit codes: 0 ok, 1 failure, 2 git history diverged, 3 agent CLI version
gate, 5 files changed on the copy about to be overwritten (stdout:
`conflict<TAB><relpath><TAB>changed|added|deleted`), 6 worker unreachable,
7 root invalid or not in the required state, 64 usage.

`rw` is linked onto `$PATH` by `make install`/`make install-headless`
(`~/.local/bin/rw` -> this repo's `scripts/rw`), so `rw <command>` works
directly after setup. It can still be invoked by full path,
`~/.config/tmux/local-plugins/tmux-remote-workspaces/scripts/rw`, if needed.

## Keybindings (tmux.reset.conf)

- `prefix q`: for a pane with a live `@rw-endpoint`, closes that endpoint
  through the lifecycle-aware `rw close` (tombstone, remote teardown, then
  the local pane). Tree and editor endpoints are ordinary endpoints, so q
  closes exactly the pane under the cursor. Plain panes keep `kill-pane`.
- `prefix h/j/k/l` (nav) and `prefix , . - =` (resize): STOCK local
  commands, even on remote-backed panes. The tree-as-endpoint design
  guarantees every endpoint's worker window is single-pane, so there is
  never a worker-side split to reach -- no ssh in any keystroke path. (The
  2026-08-05 rw-dispatch forwarding layer this replaced cost ~150ms per
  forwarded key and produced two operator-facing incidents; it is gone.)
- `prefix \` / `prefix /`: unchanged local splits, *unless* the source pane
  is remote-backed, in which case the new pane opens in the same remote
  root as its own endpoint via `rw open`.
- `prefix &`: now closes any remote endpoints owned by panes in the window
  before killing it (`rw-close-window.sh`), behind the same confirmation
  prompt tmux ships by default.
- `prefix Tab`: opens ordinary local Treemux for a local pane. For a
  remote-backed SHELL endpoint it toggles a TREE ENDPOINT (tree-as-endpoint,
  2026-08-05): a dedicated worker-side session running the tree Neovim
  (deployed `nvim/rw-tree-init.lua` as its init), shown in its own LOCAL
  pane split left of the shell (width 40). The tree roots itself at the
  shell pane's remote directory; every filesystem/git action runs on the
  worker. Tab on the tree pane closes it. Opening a file follows a
  three-way policy implemented in the deployed shim, which intercepts
  `nvim_tree_remote.remote_nvim_open` (the single funnel all neo-tree /
  nvim-tree opens go through):
    1. a previously-established editor nvim is alive -> RPC the file in;
    2. the associated shell pane is idle -> take it over with
       `nvim --listen <sock>` (the worker window never gains a split);
    3. shell busy or absent -> the shim writes a request file the
       focus-side `rw-tree-listener.sh` polls (~1s, only while the tree is
       open); the listener mints an EDITOR ENDPOINT -- its own worker
       session running `nvim --listen`, its own local pane split above the
       shell (or right of an orphaned tree) -- and publishes its socket
       back for the RPC open.
  ORPHANING IS ALLOWED: closing the shell endpoint leaves the tree standing
  as a normal remote-backed pane; its next open mints an editor endpoint
  beside it. The listener is self-healing: attach-loop re-ensures it (via
  the listener's pidfile) on every attach/reconnect, which covers laptop
  restores and listener crashes without any restore-path coupling.
- New windows stay local by default -- unchanged.

Remote Treemux is consume-never-provision like the rest of this plugin. The
worker must already have the dotfiles, Neovim >= 0.10, and the Treemux TPM
plugin from `make setup-headless`, with its tmux config loaded. Treemux's
directory watcher also requires `lsof` (included explicitly by Linux headless
setup). If any of those are absent, the binding reports the missing worker-side
setup and does not open a local sidebar that could be mistaken for the remote
filesystem; `rw doctor` reports these optional-per-endpoint prerequisites per
worker.

## How a directory becomes remote

```text
rw handoff --worker <alias>
  -> resolve the root (git toplevel or plain directory; must be under ~);
     take the per-root lock
  -> preflight the worker (tmux, git, rsync, physical $HOME; consume-never-provision)
  -> per pane in the root: detect a supported agent; refuse a working agent
     or a busy pane no adapter recognizes; check the agent CLI version
     (one exit-3 block aborts everything before anything is touched)
  -> stop the local agents, so the snapshot holds their last write
  -> ONE sync of the root to <worker home>/<path relative to ~>
       git channel (git roots): bundle, staged/unstaged patches, untracked tar
       rsync channel: the gitignored set (git roots) or the whole tree (plain)
       divergence gate (exit 2) and manifest gate (exit 5 unless --resolve);
       on failure the local agents are resumed and nothing moved
  -> per pane: hidden worker session rw-<focus-short-id>-<endpoint-id> in the
     pane's mapped directory; the (now final) transcript exported, installed
     and resumed there (claudef/pif) and verified
  -> any failure: roll everything back (worker sessions killed, local agents
     resumed, root stays local; exit 1)
  -> commit: owned/<root_id>/record.json (owner = worker) and the worker's
     mirror; endpoints/<endpoint-id>.json; pane options; each pane replaced
     by attach-loop.sh <endpoint-id> (same pane id, layout, window)
```

`rw handback` mirrors it: lock, preflight (exit 6 leaves everything as it
was), find the agents running in the remote panes NOW (the worker's process
tree plus its server-scoped SessionStart records), so an agent started on the
worker after the handoff comes back too and a remote agent whose session
cannot be identified refuses the hand-back before anything is stopped, as
does one that is mid-turn (the worker pane's `@agent_state` is `working`;
`--wait-idle [seconds]` waits for it instead); stop the remote agents, ONE
pull (manifests stored at once, so an
interrupted hand-back retries cleanly), export and install every
transcript, then give each pane its local shell back and resume its agent
there (the ownership record already says `owner: focus` when those
shells start, so they never print the "is remote" notice). If any pane
fails, every pane goes back on its attach loop, the
remote agents are resumed, and the root stays remote with nothing pending
(exit 1). Only after every pane is back are the worker sessions closed and
the record deleted.

While the root is remote the worker copy is the single source of truth. The
laptop copy stays on disk, frozen (a linked worktree's registration lives in
its main checkout, the picker needs the path, and hand-back is then a delta).
An edit made to the frozen copy is caught by the manifest gate at hand-back.

`attach-loop.sh` runs `ssh -t <alias> tmux new-session -A -s <endpoint>` in a
capped exponential backoff loop (1s -> 2s -> 4s ... capped at 30s, reset on a
connection that stays up). Before each retry it checks for a tombstone or a
missing registry entry -- that is an *intentional* close, so the loop exits
and closes the pane. Anything else is treated as a drop: retry quietly,
never delete anything, keep the pane alive. On return from each ssh attempt
it resets local mouse-tracking state and redraws, working around the known
"unclean inner-session end leaves the outer pane with garbled mouse state"
terminal artifact.

Each laptop pane attaches to its own hidden worker session (`prefix None`,
`status off`; `rw_apply_hidden_session_options` in `common.sh` re-applies
them after a worker-side restore). There is no nested tmux UI.

Always pass the worker's logical alias to `rw`. For the always-on Mac the SSH
package makes that alias location-aware (LAN listener when reachable,
otherwise Tailscale); the explicit LAN-only alias is diagnostic/maintenance
only and must not be added to `config.json` as another worker.

## Paths and placement

Every synced path is relative to `$HOME`: a root at `~/<root_rel>` on the
laptop lives at `<worker home>/<root_rel>` on the worker, where the worker
home is preflight's physical `$HOME` (`pwd -P` on the worker).
Roots outside `~`, and `~` itself, are refused (exit 7); so is a directory
inside a git worktree (hand off the worktree). `root_id` is the first field
of `printf '%s' "$root_rel" | cksum`, identical on both machines. Nothing is
ever written under `~/rw-workspaces` any more, and `config.json` has no
`workspace_root`. `scripts/resolve-workspace.sh` is the pure (no ssh) form
of this mapping.

Agents resume at the worker's physical path: Claude's project slug and the
transcript `cwd` fields, and pi's session header `cwd`, are rewritten to it.

## Sync, manifests and conflicts

`libexec/sync/handoff` (see `libexec/sync/README.md`) moves a root over two
channels and records a manifest -- `<relpath>\t<size>\t<mtime>` for every
file whose content a sync can overwrite outside git's own diff (git roots:
gitignored and untracked files; plain roots: every file), plus
`#git\t<fingerprint>` for git roots -- on both sides at every ownership
change.

Owner wins. Before a copy is overwritten (the worker copy at handoff, the
frozen laptop copy at hand-back) it is compared with its stored manifest:
unchanged is silent; a change exits 5 with one `conflict` line per file and
nothing touched. `--resolve overwrite` overwrites, `--resolve keep-both`
first renames each losing file to `<file>.local-<YYYYMMDD-HHMMSS>`,
`--resolve abort` (or no flag) stops. Keep-both copies are never deleted by
any later sync and never count as changes. A copy with no stored manifest
(first handoff onto an existing remote directory) is compared with the
incoming source instead, so only files that would really be replaced or
deleted are listed. A file the destination already holds in the incoming
version is never a conflict (a retry after an interrupted transfer
converges). Changes to committed, staged or unstaged git state are the git
channel's divergence gate (exit 2, `--force-diverged` overrides after a
backup); an existing remote repository with no record of an earlier sync
that differs from the source is exit 2 too, never silently reset. Roots
with git submodules are refused before anything is touched. Plain roots get
a backup of every file a transfer replaces or deletes, and an owner copy
with no files at all never empties the other copy without
`--resolve overwrite`.

## Registry (state root: `~/.local/state/tmux-remote-workspaces/`)

```text
machine-id                       single-line UUID, lazily created (uuidgen)
sessions.jsonl                   stable session UUID <-> tmux session name, latest line wins
owned/<root_id>/record.json      ownership record (see below)
owned/<root_id>/manifest.focus.tsv   manifest of the laptop copy at the last ownership change
owned/<root_id>/manifest.worker.tsv  manifest of the worker copy at the last ownership change
held/<worker>/<root_id>.json     worker copies this machine created (survives hand-back;
                                 `rw forget` uses it to find every copy)
endpoints/<id>.json              source of truth for a live endpoint (deleted on close)
tombstones/<id>.json             close-intent record, written BEFORE the endpoint dies
events.jsonl                     append-only observability log
locks/                           short-lived mkdir-mutexes for check-then-act sequences
rw.log                           free-text diagnostic log
```

`record.json` fields: `root_id`, `root_rel`, `root_local` (absolute path on
the machine that holds the record), `kind` (`git`|`plain`), `worker`,
`worker_root`, `owner` (`focus`|`worker`), `since`, `endpoints` (endpoint
ids), `focus_machine_id`, and optionally `pending` (`{action:
"forget"|"reconcile", reason, at}`) and `stale_worker: true`. A laptop record
exists only while the root is worker-owned or has a pending action;
`scripts/common.sh`'s `rw_owned_root_for_path <path>` returns the
worker-owned root enclosing a path (longest match). The worker keeps a
mirror with the same layout under its own state dir (`root_local` = the
worker path); it survives hand-back with `owner: focus` so the next handoff
can check the worker copy, and is deleted by `rw forget`.

Endpoint records keep their previous shape plus `root_id`, `root_rel`,
`focus_session_uuid`, `focus_session_name`, `focus_window_index`,
`focus_pane_index`, and `workspace.{root_local,worker_root}`; agent
endpoints also record `agent.project_path_focus` and
`agent.project_path_worker`.

`@session-uuid`, `@rw-endpoint`, `@rw-worker`, `@rw-workspace`,
`@rw-root-id`, `@remote-host` are tmux user options and are **cache only** --
they do not survive a server restart. The json files under the state root are
authoritative. `@remote-host` specifically means the local pane is currently
owned by an attach loop; it is not inferred merely from endpoint intent.
Host/directory chips and remote-aware bindings use that execution marker, and
config reload repairs it from the live pane process tree.
`renumber-windows on` (`tmux/tmux.conf:13`) means nothing is ever keyed on
`session:window.index` alone.

Overrides for testing (contract C4):

```sh
TMUX_REMOTE_WORKSPACES_STATE_DIR=/tmp/rw-focus-state \
TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR=/tmp/rw-worker-state \
TMUX_REMOTE_WORKSPACES_CONFIG=/path/to/alt-config.json \
RW_SSH_BIN=/path/to/fake-ssh \
  ~/.config/tmux/local-plugins/tmux-remote-workspaces/scripts/rw status
```

`TMUX_REMOTE_WORKSPACES_STATE_DIR` redirects only the laptop's state dir;
`TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR` redirects the worker-side one
(default `<worker home>/.local/state/tmux-remote-workspaces`). A same-host
fake-ssh harness sets both; a real-worker smoke test sets only the first.

## config.json

```json
{
  "workers": [
    { "alias": "mini", "platform": "darwin", "notes": "..." }
  ],
  "ssh": { "connect_timeout_seconds": 8, "preflight_timeout_seconds": 10, "status_timeout_seconds": 3 }
}
```

Only workers and ssh timeouts. Placement needs no configuration (see
"Paths and placement").

## `rw status` / `rw doctor`

`rw status` prints one row per ownership record (root, owner, worker, pane
count, pending action, stale remote copy), then one row per
`endpoints/*.json`: worker, remote directory, the live pane currently bound
to it (re-resolved via `tmux list-panes`, not trusted from the registry),
and the last matching `events.jsonl` line. It never uses ssh.

`rw doctor` is read-only: local prerequisites (jq/ssh/uuid source/config
validity/state-dir writability), a consume-never-provision preflight report
per configured worker, registry/live-pane consistency (unbound endpoints are
reported, never touched), and clipboard/`allow-passthrough` checks on both
the local and (where reachable) worker tmux layers. It never writes into
another pane or TUI.

## Manual durability save

`prefix + Ctrl-s` always saves and verifies the focus machine's outer tmux
landscape. When the focused pane is rw-backed, the same binding then runs the
same verified save wrapper on that pane's worker. A successful worker response
updates the remote freshness cache immediately, so the powerline reads `0m`;
a failed or unreachable worker retains its previous timestamp and produces an
explicit partial-failure message. The worker launchd/systemd timer keeps its
normal five-minute cadence. The dispatcher streams the focus machine's
verifier over SSH, so a manual save does not depend on the worker's separate
dotfiles clone having pulled the same revision first.

## Testing without a reachable worker

`tests/run.sh` runs the shell suite (`tests/test_*.sh`): path mapping and
`root_id`, ownership records and `rw_owned_root_for_path`, worker mirrors,
manifest generation and diff, the conflict gate (exit 5, keep-both,
overwrite), rsync-channel set selection, the sync safety fixes
(untracked content, existing repositories, interrupted retries, submodules,
nested repositories, plain backups), agent ordering and rollback
(`test_agent_flow.sh`, a pane-aware tmux stub plus fake adapters via
`RW_ADAPTERS_DIR`), pi transcript identity, reconcile guards, sync round trips of a plain folder
and a linked worktree (push, remote edits, pull; deletions on both
channels; divergence exit 2; the ssh exec wrapper with rsync `-e`), and the
`rw` command surface end to end (handoff, open, handback, conflicts,
unreachable worker, reclaim, forget). It needs no tmux server and no ssh:
`tests/lib.sh` puts a logging `tmux` stub and a same-host fake `ssh` (a
separate fake worker `$HOME`) first on `PATH`, and isolates both state dirs
and git's config.

- `scripts/preflight.sh --worker <alias>` fails fast, with no ssh attempt,
  when `<alias>` is not declared in `config.json`.
- Every script that shells out to `ssh` goes through `rw_ssh_bin`
  (`common.sh`), which honors `RW_SSH_BIN`; rsync reaches the worker with
  `-e "$RW_SSH_BIN -o BatchMode=yes ..."`.
- `scripts/resolve-workspace.sh` takes the worker's `$HOME` as an explicit
  argument, so placement is testable offline.
- Anything that needs a real tmux server uses a throwaway one
  (`TMUX_TMPDIR=<scratch>`, `-L rw-<name>` on every call, `TMUX` unset,
  killed when done) -- never a live server you also use interactively.

## Restore opt-out integration (implemented in the sibling plugin)

The attach loop sets `@workspace-resurrect-skip` while it owns a managed pane,
so a `tmux-workspace-resurrect` restore skips pasting a stale command such as
an old `ssh <alias>` into it. `rw-refresh-indicators.sh` repairs that execution
marker from the live process tree after a config reload. The sibling plugin's
`scripts/restore.sh` reads the marker and skips the pane accordingly.

## Agents

Agent handoff (detect/versions/export/install/resume-cmd) is wired against
the adapter contract in `libexec/adapters/README.md`; both provider
adapters (`pi`, `claude`) are implemented there. Resumes go through
the focus launchers -- `claudef --resume <id>` and `pif --session <path>`,
typed into the endpoint pane's interactive login shell so the launcher
resolves whether it is a script on `PATH` or a zsh function, and fnm's node
is active -- so hooks (agent-state publisher, resurrect session record) run
on the worker exactly as on the laptop. `versions` refuses (before anything
moves) when the worker cannot resolve the launcher. Claude transcripts are
installed with the destination folder pre-trusted, so a resumed claudef
never waits at the trust dialog. A git root's worker checkout gets the same
`origin` and the same branch upstream as the laptop. Preflight skips the
git-host authentication probe for a local-path (or `file://`) origin. pi transcripts travel by
exact id (`<timestamp>_<id>.jsonl`), so two pi agents in one root each
resume their own session. A pane with no detected
agent moves as a shell, except that an editor (nvim, vim, vi) is reopened
on the other side (`libexec/adapters/editor`: its Neovim session or its
argv, root paths rewritten; best effort, a warning when unconfirmed); a
busy pane no adapter recognizes aborts the whole handoff.

## Reconciliation

Rule (decision D14): a worker session is killed only by an explicit
hand-back, `rw forget`, or `rw close`. No sweep ever closes a registered
endpoint because its pane was not found.

- `libexec/reconcile` (post-resurrection, on the
  `@resurrect-hook-post-restore-all` chain after `rw-post-restore.sh`)
  closes only worker sessions in this machine's namespace that have no
  registry entry at all, are older than the min-age
  (`RW_RECONCILE_MIN_AGE_SECONDS`, default 120: `rw open`/handoff create a
  session a moment before registering it) and have no client attached; and
  finishes tombstoned closes. `rw doctor` runs it with `--dry-run`.
- `libexec/reconcile-worker` (run by `rw open`) closes unregistered
  `rw-<focus-id>-*` sessions a worker's own restore revived: registry
  membership is authoritative, min-age vs the create-to-registry gap,
  worker-clock ages, attached sessions never touched, unreachable = zero
  candidates, exact-match kills.
- `libexec/reconcile-local` is report-only: it lists registered endpoints
  no live local pane carries (logged to `rw.log`, never closed).
- Pending actions (`rw forget` or `rw reclaim` while a worker was
  unreachable) run on the next contact with that worker: any `handoff`,
  `handback`, `open` or `forget` that reaches it. A reclaim's cleanup closes
  the root's remote sessions except those running a handed-off agent, which
  are never closed automatically (`rw close --endpoint <id>` once their work
  is rescued).

## Field-validation status

The operator smoke campaign closed on 2026-08-08 with every bucket passing.
Its deleted journey file remains available in git history through commit
`be0ae44`. Smoke-verified end to end on the live laptop server (before the 2026-11-18
directory model): ensure / splits / close semantics, drop-reattach, remote
Treemux (tree-as-endpoint v2), ad-hoc handoff/return, agent handoff with
verbatim access-mode replay (claude + codex),
OSC 52 clipboard from remote (shell + nvim yank), server-side copy-mode
entry, laptop server-loss restore, worker-reboot endpoint rebuild from
manifest, picker failure dialogs.

Pure network loss and laptop sleep rely on the same bounded attach-loop retry
used by the verified worker-reboot path. These are accepted operating
conditions, not missing implementation.

The directory model (handoff/handback/open/forget/reclaim, manifests, the
rsync channel) is covered by `tests/run.sh` and a throwaway-server drill;
its live smoke test against a real worker is the plan's W6 step.

## Operational notes (learned in the field)

- After a laptop tmux server loss, restore via `tmux-restore` (on PATH;
  tmux/scripts/tmux_restore.sh) from outside tmux — it refuses when
  there is no snapshot and leaves no bootstrap session behind.
- After a laptop server loss, registered endpoints stay registered and
  their worker sessions keep running (D14); reattaching restored panes by
  endpoint id is the plan's W4 step. Until then, `rw open` in the root
  starts a fresh remote pane, and `rw status` lists the unbound endpoints.
- Don't hand off a root while a writer that is not one of its panes (a dev
  server, a build, an agent in another root) is changing it -- the sync
  verify will (correctly) refuse; pause the writer, retry.
- Worker-side continuum restore revives CLOSED rw-* sessions from stale
  saves (live-endpoint durability is the point; closed ones are noise).
  Laptop-side `libexec/reconcile` protects pre-restart registry entries
  by design; a lingering one is closed with `rw_close_endpoint_core`.
