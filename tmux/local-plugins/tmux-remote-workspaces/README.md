# tmux-remote-workspaces

Personal local plugin that lets the laptop tmux server stay the single
visible coordination layer while selectively elevating one pane to a
persistent remote tmux endpoint on an always-on worker (`ssh mini`, Linux
VMs). Local-first: remote is opt-in per pane, never the default. Worker names
are logical identities: OpenSSH may route `mini` over its LAN listener or
Tailscale without the plugin treating those paths as different workers.

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
rw ensure --worker <alias> [--workspace <path>|auto]
rw close  [--pane <pane-id>] [--no-kill-pane] [--reason <text>]
rw status
rw doctor
rw handoff --worker <alias> [--workspace <path>|auto] [--pane <pane-id>] [--keep-local] [--check-lfs]
rw return  [--pane <pane-id>] [--keep-remote] [--check-lfs]
```

There is no separate `attach`/`reconnect` verb. `rw ensure` is idempotent: run
against a pane with no endpoint it establishes one; run against a pane that
already has a live `@rw-endpoint`, it revalidates and reattaches instead of
creating a second endpoint.

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
  is remote-backed, in which case the new pane inherits the same
  worker+workspace and becomes its own pane-scoped endpoint via `rw ensure`.
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

## How a pane becomes remote

```text
rw ensure --worker mini
  -> preflight mini over ssh (tmux, git, git-lfs; consume-never-provision)
  -> resolve workspace placement (worktree-specific checkout | plain $HOME)
  -> create/validate rw-<focus-short-id>-<endpoint-id> on mini's own tmux server
  -> write endpoints/<endpoint-id>.json (source of truth)
  -> set endpoint-intent cache: @rw-endpoint @rw-worker @rw-workspace
  -> exec attach-loop.sh <endpoint-id>   (this pane's foreground process from here on)
  -> attach-loop sets execution cache: @remote-host @workspace-resurrect-skip
```

`attach-loop.sh` runs `ssh -t mini tmux new-session -A -s <endpoint>` in a
capped exponential backoff loop (1s -> 2s -> 4s ... capped at 30s, reset on a
connection that stays up). Before each retry it checks for a tombstone or a
missing registry entry -- that is an *intentional* close, so the loop exits
and closes the pane. Anything else is treated as a drop: retry quietly,
never delete anything, keep the pane alive. On return from each ssh attempt
it resets local mouse-tracking state and redraws, working around the known
"unclean inner-session end leaves the outer pane with garbled mouse state"
terminal artifact.

For the Mini specifically, always pass `mini` to `rw`. The SSH package makes
that alias location-aware: it prefers `Alfies-Mac-mini.local` when the verified
LAN listener is reachable and otherwise uses the Tailscale address. The
explicit `mini-lan` alias is diagnostic/maintenance-only and must not be added
to `config.json` as another worker.

## Registry (state root: `~/.local/state/tmux-remote-workspaces/`)

```text
machine-id            single-line UUID, lazily created (uuidgen)
sessions.jsonl         stable session UUID <-> tmux session name, latest line wins
endpoints/<id>.json    source of truth for a live endpoint (deleted on close)
tombstones/<id>.json   close-intent record, written BEFORE the endpoint dies
events.jsonl           append-only observability log (create/attach/reconnect/close)
locks/                 short-lived mkdir-mutexes for check-then-act sequences
rw.log                 free-text diagnostic log
```

`@session-uuid`, `@rw-endpoint`, `@rw-worker`, `@rw-workspace`, `@remote-host`
are tmux user options and are **cache only** -- they do not survive a server
restart. The jsonl/json files under the state root are authoritative.
`@remote-host` specifically means the local pane is currently owned by an
attach loop; it is not inferred merely from endpoint intent. Host/directory
chips and remote-aware bindings use that execution marker, and config reload
repairs it from the live pane process tree. This prevents a failed or racing
handoff from labeling a still-local agent as remote.
`renumber-windows on` (`tmux/tmux.conf:13`) means nothing is ever keyed on
`session:window.index`.

Override the state root or config path for testing:

```sh
TMUX_REMOTE_WORKSPACES_STATE_DIR=/tmp/rw-test-state \
TMUX_REMOTE_WORKSPACES_CONFIG=/path/to/alt-config.json \
  ~/.config/tmux/local-plugins/tmux-remote-workspaces/scripts/rw status
```

## config.json

```json
{
  "workers": [
    { "alias": "mini", "platform": "darwin", "notes": "..." },
    { "alias": "agents-roll", "platform": "linux", "notes": "..." }
  ],
  "workspace_root": "~/rw-workspaces/<focus-machine-id>",
  "ssh": { "connect_timeout_seconds": 8, "preflight_timeout_seconds": 10, "status_timeout_seconds": 3 }
}
```

`workspace_root` is namespaced by the focus machine's stable id. Automatic Git
workspace placement adds the normalized repository identity, the local
worktree's directory name, and a checksum of its canonical path. Two physical
worktrees for the same repository therefore get separate remote checkouts.
Branch names and numbered-directory conventions do not affect placement.

Workspace resolution order (`--workspace auto`, the default):

1. Not a git repo (no `origin` remote) -> `plain`, worker's `$HOME`.
2. A live `adhoc` endpoint already exists for the same canonical local
   worktree on the same worker -> reuse its path.
3. Otherwise -> use that worktree's stable `adhoc` checkout under
   `workspace_root`, cloned with the *worker's own* git/ssh auth when absent.
   A clone failure aborts with a message about registering the worker's key
   with the Git host. This plugin never supplies or forwards credentials.

`--workspace <path>` (anything other than `auto`) is used verbatim as the
remote path (`~` substituted for the worker's home); no automatic placement
runs.

## `rw status` / `rw doctor`

`rw status` prints one row per `endpoints/*.json`: worker, mode, remote path,
the live pane currently bound to it (re-resolved via `tmux list-panes`, not
trusted from the registry), a short-timeout liveness check, and the last
matching `events.jsonl` line.

`rw doctor` is read-only: local prerequisites (jq/ssh/uuid source/config
validity/state-dir writability), a consume-never-provision preflight report
per configured worker, registry/live-pane consistency (orphans are reported,
never touched),
and clipboard/`allow-passthrough` checks on both the local and (where
reachable) worker tmux layers. It never writes into another pane or TUI.

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

- `scripts/preflight.sh --worker <alias>` fails fast, with no ssh attempt,
  when `<alias>` is not declared in `config.json`.
- Every script that shells out to `ssh` goes through `rw_ssh_bin`
  (`common.sh`), which honors `RW_SSH_BIN` -- point it at a fake executable
  to exercise the reachable/unreachable/missing-binaries paths without
  touching a real worker.
- `scripts/resolve-workspace.sh` takes the worker's `$HOME` as an explicit
  argument (not resolved via ssh itself), so ad hoc/plain resolution logic is
  fully testable offline.
- Use a private tmux socket (`tmux -L <name>`) for any test that needs a real
  tmux server -- never exercise pane/session/hook behavior against a live
  server you also use interactively.

## Restore opt-out integration (implemented in the sibling plugin)

The attach loop sets `@workspace-resurrect-skip` while it owns a managed pane,
so a `tmux-workspace-resurrect` restore skips pasting a stale command such as
an old `ssh mini` into it. `rw-refresh-indicators.sh` repairs that execution
marker from the live process tree after a config reload. The sibling plugin's
`scripts/restore.sh` reads the marker and skips the pane accordingly.

## `rw handoff` / `rw return`

Implemented: transactional workspace handoff/return (`libexec/sync/handoff`
-- see `libexec/sync/README.md` for the full wire format, exit codes, and
correctness notes). Agent handoff (detect/versions/export/install/resume-cmd) is
wired against the adapter contract in `libexec/adapters/README.md` and all
three provider adapters (`pi`, `claude`, `codex`) are implemented there --
see `libexec/adapters/README.md` for per-provider details and its
`smoke-test` dev tool. A pane with no detected agent (or a genuinely missing
adapter file) degrades cleanly to workspace-only.

## Reconciliation

`libexec/reconcile` (post-resurrection reconciliation: desired-set
computation against tombstones/registry, closing this-focus-machine-owned
orphans, reattach/rebuild of desired-but-missing endpoints) is implemented
and wired onto the same `@resurrect-hook-post-restore-all` chain this
plugin's `tmux-remote-workspaces.tmux` already appends to (after
`rw-post-restore.sh`). `rw doctor` also runs it with `--dry-run` for a
report-only preview.

Two ensure-time companions complete the sweep triangle (each covers a
class the others deliberately spare):

- `libexec/reconcile-worker` — worker-side zombies: `rw-<focus-id>-*`
  sessions a worker's own continuum restore resurrected after their
  laptop endpoints were closed. Registry membership is authoritative
  (registered = spared); min-age vs the ensure create-to-registry gap,
  worker-clock ages, attached sessions never touched, unreachable =
  zero candidates, exact-match kills.
- `libexec/reconcile-local` — local-pane-death orphans: registry
  endpoints whose LOCAL pane was killed without `prefix q` (attach-loop
  dies with the pane, so nothing self-cleans). Closes only on proof the
  binding belongs to the CURRENT local server generation (created after
  server start, or restore-reattached after it per events.jsonl) — the
  ambiguous-post-restore class `reconcile` protects is never eligible.
  Min-age guards the ensure registry-write-to-pane-stamp gap.

Both run best-effort at every `rw ensure`; `rw doctor` previews both
dry-run.

## Field-validation status

The operator smoke campaign closed on 2026-08-08 with every bucket passing.
Its deleted journey file remains available in git history through commit
`be0ae44`. Smoke-verified end to end on the live laptop server: ensure /
splits / close semantics, drop-reattach, remote Treemux (tree-as-endpoint
v2), ad-hoc handoff/return, agent handoff with verbatim
access-mode replay (claude + codex),
OSC 52 clipboard from remote (shell + nvim yank), server-side copy-mode
entry, laptop server-loss restore, worker-reboot endpoint rebuild from
manifest, picker failure dialogs.

Pure network loss and laptop sleep rely on the same bounded attach-loop retry
used by the verified worker-reboot path. These are accepted operating
conditions, not missing implementation.

`reconcile-local` has synthetic coverage for its created-after-start path and
both protective guards. Ambiguous post-restore state remains report-only by
design.

## Operational notes (learned in the field)

- After a laptop tmux server loss, restore via `tmux-restore` (on PATH;
  tmux/scripts/tmux_restore.sh) from outside tmux — it refuses when
  there is no snapshot and leaves no bootstrap session behind.
- Endpoints do NOT survive a laptop server loss: restored attach-loop
  panes come back as plain shells, so reconcile closes the endpoints
  cleanly (no zombies). Re-open with `prefix e`. This is the accepted restore
  behavior.
- Don't hand off a worktree while another local agent/editor is actively
  writing in it — the sync verify will (correctly) refuse; the picker
  dialog names this case. Pause the writer, retry.
- Worker-side continuum restore revives CLOSED rw-* sessions from stale
  saves (live-endpoint durability is the point; closed ones are noise).
  Laptop-side `libexec/reconcile` protects pre-restart registry entries
  by design; a lingering one is closed with `rw_close_endpoint_core`.
