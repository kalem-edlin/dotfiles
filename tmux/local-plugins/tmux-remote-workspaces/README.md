# tmux-remote-workspaces

Personal local plugin that lets the laptop tmux server stay the single
visible coordination layer while selectively elevating one pane to a
persistent remote tmux endpoint on an always-on worker (`ssh mini`, Linux
VMs). Local-first: remote is opt-in per pane, never the default. Worker names
are logical identities: OpenSSH may route `mini` over its LAN listener or
Tailscale without the plugin treating those paths as different workers.

Full intent, requirements, and design rationale live in
[`docs/tasks/tmux-remote-workspaces/initial-plan.md`](../../../docs/tasks/tmux-remote-workspaces/initial-plan.md).
This README documents what is actually implemented in this wave.

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
creating a second endpoint (initial-plan.md, Resolved decision #5).

`rw` is linked onto `$PATH` by `make install`/`make install-headless`
(`~/.local/bin/rw` -> this repo's `scripts/rw`), so `rw <command>` works
directly after setup. It can still be invoked by full path,
`~/.config/tmux/local-plugins/tmux-remote-workspaces/scripts/rw`, if needed.

## Keybindings (tmux.reset.conf)

- `prefix q`: for a pane with a live `@rw-endpoint`, `rw-dispatch.sh close`
  decides scope on the worker: a Treemux sidebar (or other worker-side
  split) closes just THAT pane -- the sidebar via its own toggle so the
  registration is torn down -- while a lone worker pane closes the whole
  endpoint through `rw close`. Plain panes keep unchanged `kill-pane`.
- `prefix h/j/k/l` (nav) and `prefix , . - =` (resize): on a remote-backed
  pane these forward the equivalent tmux command into the worker session
  over the multiplexed ssh channel (`rw-dispatch.sh`) -- the worker-side
  Treemux sidebar is otherwise invisible to the local server, so nav,
  resize, and close could never reach it (smoke-journey Bucket 4 finding).
  Nav at the worker window's edge falls back to LOCAL `select-pane`, so the
  cursor crosses out of the remote rectangle into the local layout
  seamlessly. Any failure (worker unreachable, session gone) degrades to
  the stock local command; close's failure path degrades to `rw close`,
  the exact pre-dispatch behavior.
- `prefix \` / `prefix /`: unchanged local splits, *unless* the source pane
  is remote-backed, in which case the new pane inherits the same
  worker+workspace and becomes its own endpoint via `rw ensure` (new
  endpoint id -- pane-based ownership per the plan's pane/window model).
- `prefix &`: now closes any remote endpoints owned by panes in the window
  before killing it (`rw-close-window.sh`), behind the same confirmation
  prompt tmux ships by default.
- `prefix Tab`: opens ordinary local Treemux for a local pane. For a
  remote-backed pane it invokes Treemux inside that pane's worker-side endpoint
  tmux session. Treemux therefore roots itself at the active remote pane's
  directory, and file, Git, editor, and tmux-split actions all execute on the
  worker. It never substitutes the outer pane's local `#{pane_current_path}`.
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
  -> resolve workspace placement (reflected slot | ad hoc checkout | plain $HOME)
  -> create/validate rw-<focus-short-id>-<endpoint-id> on mini's own tmux server
  -> write endpoints/<endpoint-id>.json (source of truth)
  -> set pane cache options: @rw-endpoint @rw-worker @rw-workspace @remote-host
  -> exec attach-loop.sh <endpoint-id>   (this pane's foreground process from here on)
```

`attach-loop.sh` runs `ssh -t mini tmux new-session -A -s <endpoint>` in a
capped exponential backoff loop (1s -> 2s -> 4s ... capped at 30s, reset on a
connection that stays up). Before each retry it checks for a tombstone or a
missing registry entry -- that is an *intentional* close, so the loop exits
and closes the pane. Anything else is treated as a drop: retry quietly,
never delete anything, keep the pane alive. On return from each ssh attempt
it resets local mouse-tracking state and redraws, working around the known
"unclean inner-session end leaves the outer pane with garbled mouse state"
artifact from initial-plan.md's Transport section.

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
  "reflected_repositories": [{
    "identity": "github.com/kalem-edlin/content-engine",
    "workers": ["mini"],
    "focus_path_pattern": "~/Developer/content-engine-trees/content-engine-<N>",
    "worker_path_pattern": "~/Developer/content-engine-trees/content-engine-<N>"
  }],
  "workspace_root": "~/rw-workspaces/<focus-machine-id>",
  "ssh": { "connect_timeout_seconds": 8, "preflight_timeout_seconds": 10, "status_timeout_seconds": 3 }
}
```

Adding a reflected repository is config-only: append an entry with its
normalized `identity` (host/owner/repo, from `git remote get-url origin`,
never `.git`, always lowercase), optional worker-alias allowlist, and the two
path patterns. Omitting `workers` (or using an empty array) reflects the
repository to every configured worker; a non-empty array limits reflection to
those worker aliases, allowing other workers to use ad hoc placement. `<N>` is
the only supported placeholder (a numbered slot); `~` in either pattern is
substituted for the relevant host's own `$HOME` at resolution time -- never an
absolute username. Patterns are matched with plain prefix/suffix string
comparison (see `scripts/resolve-workspace.sh`), not regex, so path
metacharacters in a pattern are never a hazard.

Workspace resolution order (`--workspace auto`, the default):

1. Not a git repo (no `origin` remote) -> `plain`, worker's `$HOME`.
2. Repo matches a configured reflected pattern for the selected worker (cwd
   is the slot dir or beneath it) -> `reflected`, no clone, no filesystem
   changes.
3. Repo, not reflected, but a live-registry `adhoc` endpoint already exists
   for the same normalized identity on the same worker -> reuse its path.
4. Otherwise -> fresh `adhoc` checkout under `workspace_root`, cloned with
   the *worker's own* git/ssh auth. A clone failure aborts with a message
   about registering the worker's key with the git host -- this plugin never
   supplies or forwards credentials.

`--workspace <path>` (anything other than `auto`) is used verbatim as the
remote path (`~` substituted for the worker's home); no reflected/ad hoc
inference runs.

## `rw status` / `rw doctor`

`rw status` prints one row per `endpoints/*.json`: worker, mode, remote path,
the live pane currently bound to it (re-resolved via `tmux list-panes`, not
trusted from the registry), a short-timeout liveness check, and the last
matching `events.jsonl` line.

`rw doctor` is read-only: local prerequisites (jq/ssh/uuid source/config
validity/state-dir writability), a consume-never-provision preflight report
per configured worker (this is where that report lives per Resolved decision
#5), registry/live-pane consistency (orphans are reported, never touched),
and clipboard/`allow-passthrough` checks on both the local and (where
reachable) worker tmux layers. It never writes into another pane or TUI.

## Testing without a reachable worker

- `scripts/preflight.sh --worker <alias>` fails fast, with no ssh attempt,
  when `<alias>` is not declared in `config.json`.
- Every script that shells out to `ssh` goes through `rw_ssh_bin`
  (`common.sh`), which honors `RW_SSH_BIN` -- point it at a fake executable
  to exercise the reachable/unreachable/missing-binaries paths without
  touching a real worker.
- `scripts/resolve-workspace.sh` takes the worker's `$HOME` as an explicit
  argument (not resolved via ssh itself), so reflected/ad hoc/plain
  resolution logic is fully testable offline.
- Use a private tmux socket (`tmux -L <name>`) for any test that needs a real
  tmux server -- never exercise pane/session/hook behavior against a live
  server you also use interactively.

## Restore opt-out integration (implemented in the sibling plugin)

`rw ensure` sets `@workspace-resurrect-skip` on a managed pane so a
`tmux-workspace-resurrect` restore skips pasting a stale command (e.g. an
old `ssh mini`) into it, per initial-plan.md's "Local restore of remote
attachments". `tmux-workspace-resurrect/scripts/restore.sh` reads that
option (see its restore loop, around the `@workspace-resurrect-skip` check)
and skips the pane accordingly -- this integration is implemented and wired,
not a seam.

## `rw handoff` / `rw return`

Implemented: transactional workspace handoff/return (`libexec/sync/handoff`
-- see `libexec/sync/README.md` for the full wire format, exit codes, and
correctness notes) plus claims integration
(`worktree-claim handoff-writer`/`return-writer`, marker travels with the
workspace). Agent handoff (detect/versions/export/install/resume-cmd) is
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

Proven in lane testing but NOT yet organically encountered/validated in
the field (validate stochastically as daily use continues; see
docs/tasks/tmux-remote-workspaces/smoke-journey.md for what HAS been
smoke-verified):

- Network-loss drop resilience (Wi-Fi off/on mid-attach): attach-loop's
  ssh ServerAlive timeout + backoff path. Inner-detach reattach IS
  smoke-verified (Bucket 2); a real network drop is not — operator
  declined the synthetic drill.
- `reconcile-local`'s events.jsonl eligibility path (proof via
  restore-reattach after a server restart) — synthetic fixtures proved
  the created-after-start path and both protective guards; the
  post-restore rebind path awaits a real crash + pane-death sequence.
