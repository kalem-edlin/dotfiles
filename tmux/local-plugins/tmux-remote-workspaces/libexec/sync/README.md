# Workspace handoff sync

Implements the Phase 4/5 transactional handoff described in
`docs/tasks/tmux-remote-workspaces/initial-plan.md` ("Workspace
synchronization and handoff", "Local-first AI coding-agent handoff",
"Worktree claims and editing ownership"). Moves dirty git state -- unpushed
commits, staged changes, unstaged changes, tracked renames/deletions,
untracked files, and referenced Git LFS content -- between two worktrees
without any commit/push/pull ceremony, with a destination backup and a
divergence check before ever overwriting a managed destination.

## Files

- `handoff` -- the transfer core. A standalone executable with two
  subcommands (`sync`, `fingerprint`); testable and usable on its own,
  independent of tmux.
- `common.sh` -- sourced-only helpers: the destination "exec wrapper"
  abstraction, the content-fingerprint script, generation-state read/write
  (registry- or file-backed), and claim-marker helpers. Extends (never
  duplicates) `../../scripts/common.sh`.

`../../scripts/rw-handoff.sh` and `../../scripts/rw-return.sh` are the
command-surface callers (`rw handoff` / `rw return`); they own tmux/pane
concerns, worker preflight, claim orchestration, and the agent-adapter
contract. This directory owns none of that -- it is a pure two-worktree
sync engine that happens to be driven by them.

## The exec wrapper: one code path for local-dir testing and real ssh

`handoff` always runs on ONE of the two hosts and reaches the OTHER through
an "exec wrapper" -- an argv prefix (binary + fixed args) that the actual
command is appended to:

```text
--dest-mode ssh    --dest-worker mini            -> ssh -o BatchMode=yes -o ConnectTimeout=N mini <cmd>
--dest-mode local                                 -> bash -c <cmd>              (same-host testing)
--dest-mode custom --dest-exec-bin X --dest-exec-arg A -> X A <cmd>             (test doubles: throttling/dropping/etc.)
```

By default (push, used by `rw handoff`) `--source-path` is read directly --
this process runs on the focus machine, where the source content already
lives -- and `--dest-path` is reached over the wrapper (the worker). Pass
`--pull` (used by `rw return`, which also always runs on the focus machine)
to invert that: `--source-path` is then reached over the wrapper and
`--dest-path` is read/written directly. Internally this is four small
functions (`exec_source`/`exec_source_script`/`exec_dest`/`exec_dest_script`)
that every git/tar/tmux command in `handoff` goes through instead of ever
hard-coding local-vs-remote -- the exact same capture/backup/apply/verify
code serves both directions. Remote-side multi-line logic (fingerprint,
backup, apply) is generated as a small script with paths pre-substituted via
`printf %q` and always executed by explicitly invoking `bash -s` on the far
side, piped over stdin -- this sidesteps any ambiguity about what the far
login shell is, and keeps quoting to one well-tested layer instead of
nesting shell-in-shell escaping.

## Wire format: what travels, in what order

`sync` builds a local snapshot directory, streams it to a destination
**staging** directory (never the live workspace), verifies it landed intact,
backs up the destination's prior state, then applies staging onto the live
destination and verifies the result:

1. **Capture** (read-only against the source):
   - `meta.json` -- format version, direction, branch, HEAD commit,
     detached-HEAD flag, which of the pieces below are present, untracked
     file count, source content fingerprint, timestamps.
   - `bundle.git` -- `git bundle create - <range>`, where `<range>` is
     `<dest-HEAD>..HEAD` when the destination's current HEAD is an ancestor
     known to the source (so only commits the destination actually lacks
     travel -- this is what carries unpushed commits without ever touching
     `origin`), or plain `HEAD` (a full-history bundle) when the
     destination has nothing yet or its HEAD is unknown to the source.
     Omitted entirely when the commit range is empty (destination is
     already at the same commit).
   - `staged.patch` -- `git diff --binary -M --cached` (index vs HEAD).
   - `unstaged.patch` -- `git diff --binary -M` (working tree vs index).
     Captured **separately** from `staged.patch` so staged/unstaged
     identity survives the trip; `-M` gives compact rename patches, but
     correctness does not depend on it (a plain delete+add reconstructs the
     same tree).
   - `untracked.tar` -- `tar` of `git ls-files --others --exclude-standard`
     (non-ignored untracked files only).
   - `lfs-snapshot.tar` -- present only with `--check-lfs` on a repository
     that has Git LFS configured: `git lfs pull` first (best-effort, so
     changed content is materialized locally), then the whole
     `.git/lfs/objects` directory. See the LFS caveat below.
   - `claim-marker.json` -- a verbatim copy of `.worktree-claim` at the
     source root, present only if that file exists there. `.worktree-claim`
     is globally gitignored, so it is intentionally captured as a distinct
     step rather than relying on the generic untracked-file scan (which
     would skip it).
2. **Transfer**: `tar -cf - .` over the snapshot dir, piped through the exec
   wrapper into a destination staging directory (default
   `<state-dir>/handoff-staging/<token>/g<gen>-<ts>/`, resolved on whichever
   side is being written to). A dropped connection here fails the whole
   pipeline (`tar`'s own exit status, checked); the live destination has not
   been touched yet.

   `<state-dir>` resolution differs by side and is intentionally asymmetric:
   - **Local-machine default** (no `--backup-root`/`--staging-root` passed --
     e.g. `rw return`'s pull direction, where the destination being backed
     up/staged is this same focus machine): `common.sh`'s `rw_state_dir()`,
     i.e. `$TMUX_REMOTE_WORKSPACES_STATE_DIR` if set, else
     `$XDG_STATE_HOME/tmux-remote-workspaces`, else
     `$HOME/.local/state/tmux-remote-workspaces`.
   - **Remote-worker default** (a caller writing to a genuinely remote
     worker, e.g. `rw-handoff.sh`'s push direction, always passes both flags
     itself): `common.sh`'s `rw_state_dir_at(<worker-home>)`, computed from
     the worker's own queried `$HOME` (from `preflight.sh`), never this
     process's local `$HOME`/`$XDG_STATE_HOME` -- those describe the local
     machine and are meaningless for a path that must exist on the worker.
     In real (non-test) use this is a **fixed** default: a genuine remote
     ssh session never inherits this process's local environment, so
     `$TMUX_REMOTE_WORKSPACES_STATE_DIR`/`$XDG_STATE_HOME` are never actually
     set on that side. `rw_state_dir_at()` still *checks* those local env
     vars (not the worker's) purely so a test harness running a fake worker
     on the same machine (`RW_SSH_BIN` pointed at a same-host fake ssh, which
     inherits this process's env) can redirect both sides into one isolated
     sandbox with a single override variable.
3. **Verify staging**: read back `staging/meta.json` over the wrapper and
   confirm its `head_commit` matches what was captured. A truncated/missing
   file here means the transfer was interrupted -- **exit 3**, live
   destination untouched, source untouched.
4. **Divergence check**: skipped on a first-ever sync (no prior recorded
   generation). Otherwise, compute the destination's current content
   fingerprint (HEAD + hash of staged/unstaged/untracked state, see below)
   and compare it to the fingerprint recorded after the last successful
   sync through this endpoint/state-file. A mismatch means the destination
   was modified independently of this tool since -- **exit 2**, both sides
   left exactly as they were, no backup taken, no last-writer-wins.
   `--force-diverged` explicitly overrides (a backup is still taken).
5. **Backup**: only when the destination is already a git worktree. Runs
   entirely on the destination host (bundle + staged/unstaged patches +
   untracked tar of the destination's *own current* state, same format as
   the main snapshot) into
   `$HOME/.local/state/tmux-remote-workspaces/handoff-backups/<token>/<generation>/`
   -- the exact path the plan specifies. Recoverable with ordinary git
   commands (`git fetch bundle.git 'HEAD:refs/heads/x'`, `git apply
   *.patch`, `tar -x untracked.tar`) even without this tool.
6. **Apply** (staging -> live destination): `git init` if the destination
   isn't a repo yet; place any LFS objects into `.git/lfs/objects` *before*
   checkout so the smudge filter materializes real content directly; fetch
   the bundle into a scratch ref and force-checkout (`-B`/`--detach`) onto
   it, or straight onto `head_commit` when no bundle was needed -- `-f` is
   required here because the destination may have local modifications the
   overwrite is meant to discard (the backup above is what makes that
   safe); apply `staged.patch` with `--index` (not `--cached` -- see
   Correctness notes) then `unstaged.patch` plain; extract `untracked.tar`;
   copy the claim marker into place if present.
7. **Verify**: recompute the destination's fingerprint and compare to the
   fingerprint captured from the source before anything was touched. A
   mismatch is reported as **exit 4** (destination was modified but is not
   verified correct; the pre-overwrite backup from step 5 is still there).
8. **Record generation**: on success, write
   `{generation, fingerprint, direction, synced_at, head_commit, branch, backup_dir}`
   either onto the endpoint registry's `workspace.sync` (`--endpoint <id>`)
   or a plain JSON file (`--state-file <path>`) -- both are interchangeable
   backends for the same divergence-tracking record, so the sync core is
   testable standalone without the full tmux endpoint registry. This single
   fingerprint is checked against whichever side is about to be
   overwritten on the *next* sync in *either* direction -- push and pull
   share one generation counter.

Every step logs to `events.jsonl` (`rw_log_event`) with duration and
outcome, including failed attempts, per initial-plan.md's Observability
section.

## Content fingerprint

`HEAD-commit:sha256(unstaged diff):sha256(staged diff):sha256(sorted
untracked file list)`, computed by an identical generated script on
whichever side is asked (`rw_sync_fingerprint_via` + `exec_*_script`). An
empty/non-repository path fingerprints as the literal string `EMPTY`. Two
worktrees with this fingerprint equal have byte-identical HEAD, staged,
unstaged, and untracked-file-list state (not full untracked *content*, see
Correctness notes).

## Claims integration

`handoff` itself only carries the `.worktree-claim` marker file along as
inert coordination metadata (capture step 1, apply step 6) -- it never
invokes `worktree-claim`. The orchestration scripts do that, and only over
local calls (never ssh):

- `rw-handoff.sh`, before capturing the snapshot: `worktree-claim
  handoff-writer --host <worker> --path <local-worktree>` on the FOCUS
  machine. This bumps the claim's generation and flips
  `active_writer_host` to the worker *before* the marker is captured, so
  the copy that travels already reflects the new state.
- `rw-return.sh`, after the workspace lands back locally: `worktree-claim
  return-writer --path <local-worktree>` on the FOCUS machine. By then the
  just-arrived marker (if its generation happened to be newer) has already
  been adopted into the local registry by `wt_sync_claim_from_marker` --
  every `worktree-claim` subcommand calls that first -- so `return-writer`
  reconciles from the correct baseline before bumping again.

Neither script requires `worktree-claim` to be installed/invokable on the
worker for a handoff/return to succeed: adoption happens lazily, on
whichever host next runs a `worktree-claim` subcommand against that path.
Both scripts skip all of this cleanly when `.worktree-claim` is absent
(claims are optional).

## Correctness notes / known limitations

- **Why `--index`, not `--cached`, for the staged patch**: `git apply
  --cached` only updates the index, never the working tree. A staged
  rename/add applied that way leaves the working tree holding the *old*
  file and missing the new one -- inconsistent with the index. `--index`
  applies to both atomically. `unstaged.patch` is applied with a plain
  (working-tree-only) `git apply` afterward, which is safe *because* the
  destination was just force-checked-out to the exact source `head_commit`
  first -- the unstaged patch's base always matches.
- **`git bundle create` needs a ref, not a bare commit id.** The
  full-history fallback path bundles `HEAD` (the symbolic ref), never the
  literal SHA -- `git bundle create - <sha>` unconditionally fails with
  "Refusing to create empty bundle" because a bundle's boundary must
  resolve through a name.
- **LFS is best-effort and repo-wide, not incremental.** `--check-lfs`
  tars the *entire* local `.git/lfs/objects` directory rather than only
  the objects referenced by the changed files. Simple and correct, but
  wasteful for a large repo with a small dirty change -- an oid-diffed
  transfer (`git lfs ls-files -l` intersected with changed paths) would be
  the natural follow-up if this proves slow in practice. Also: `git lfs
  pull` before packaging assumes the source already has (or can reach)
  network access to its LFS remote; a fully offline dirty LFS change that
  was never pulled/pushed anywhere is not covered.
- **Untracked-file identity in the fingerprint is by filename list, not
  content hash.** Two untracked trees with the same filenames but
  different byte content would fingerprint equal. This does not affect
  correctness of the transfer itself (the untracked tar always carries the
  real bytes) -- it only means the divergence check could theoretically
  miss a same-filenames-different-bytes edit to an untracked file made
  directly on a "should be inert" side between syncs. Tightening this to a
  content hash is a cheap follow-up; not done here to keep the fingerprint
  script fast on repositories with large untracked build directories that
  are merely gitignore-adjacent misses.
- **Apply-phase interruption is a smaller residual risk than
  transfer-phase interruption, not an eliminated one.** The transfer step
  (3) is interruption-proof by construction -- everything lands in a
  staging directory first, and the live destination is only touched in the
  apply step, once staging is verified intact. If the *apply* step itself
  is killed mid-way (a much shorter window, all-local git operations, no
  network), the destination can be left partially updated. A backup (step
  5) was already taken by that point whenever the destination was a
  managed repo, so this is "recoverable", not "silently corrupted" -- but
  it is not "provably inert" the way an interrupted transfer is. A real
  two-host smoke test should include killing the ssh connection during
  apply specifically, not just during transfer.
- **Ownership boundary**: this directory does not create, close, or
  reconcile tmux endpoints, does not implement provider adapters, and does
  not decide when to stop a local/remote AI agent -- see
  `../../scripts/rw-handoff.sh`, `../../scripts/rw-return.sh`, and
  `../adapters/README.md`.

## Testing without a reachable worker or real ssh

- Every remote-reaching call goes through the exec wrapper described
  above; `--dest-mode custom` accepts an arbitrary test double as
  `--dest-exec-bin`/`--dest-exec-arg` (a throttling wrapper, a wrapper that
  deliberately truncates/fails partway through a transfer to simulate a
  dropped connection, etc.) with no code changes to `handoff` itself.
  `--dest-mode ssh` still honors `RW_SSH_BIN` (`scripts/common.sh`), so a
  fake-ssh executable exercises the *exact* real-world argv shape
  (`ssh -o ... worker "<cmd>"`) without a network hop.
- `--dest-mode local` plus two plain local directories is enough to
  exercise the entire capture/backup/divergence/apply/verify pipeline with
  real git repositories and no tmux/ssh/registry involvement at all.
- `--state-file <path>` decouples generation/divergence tracking from the
  full tmux endpoint registry, so `sync` is fully testable standalone;
  `rw-handoff.sh`/`rw-return.sh` pass `--endpoint <id>` instead for the
  real integration.
