# Workspace handoff sync

Moves one directory root -- a git worktree or a plain folder -- between the
focus machine and a worker, for `rw handoff` / `rw handback`
(`docs/tasks/remote-owned-directories.md`, Q4 and contracts C1/C2). Two
channels:

- **git channel** (git roots): unpushed commits, staged changes, unstaged
  changes, tracked renames/deletions, untracked files and referenced Git LFS
  content, without any commit/push/pull ceremony, with a destination backup
  and a divergence check before a managed destination is overwritten.
  Untracked files the owner no longer has are deleted on the other side.
- **rsync channel**: everything the git channel ignores -- for a git root
  exactly the gitignored set (`.env*`, `node_modules`, build output), for a
  plain root the whole tree -- with delete semantics.

Before either channel touches the destination, the **manifest gate**
compares the destination copy with its stored manifest (owner wins; exit 5
unless `--resolve`).

## Files

- `handoff` -- the transfer core. A standalone executable with three
  subcommands (`sync`, `fingerprint`, `manifest`); testable and usable on
  its own, independent of tmux.
- `common.sh` -- sourced-only helpers for the destination exec wrapper,
  content fingerprints, manifests, the ignored-entry listing, rsync rules,
  and generation-state read/write. It extends `../../scripts/common.sh`.

`../../scripts/rw-handoff.sh` and `../../scripts/rw-handback.sh` are the
command-surface callers; they own the ownership records, tmux and pane
concerns, worker preflight, and the agent-adapter contract. This directory
owns none of that -- it is a pure two-copy sync engine driven by them.

## The exec wrapper: one code path for local-dir testing and real ssh

`handoff` always runs on ONE of the two hosts and reaches the OTHER through
an "exec wrapper" -- an argv prefix (binary + fixed args) that the actual
command is appended to:

```text
--dest-mode ssh    --dest-worker <alias>         -> ssh -o BatchMode=yes -o ConnectTimeout=N <alias> <cmd>
--dest-mode local                                 -> bash -c <cmd>              (same-host testing)
--dest-mode custom --dest-exec-bin X --dest-exec-arg A -> X A <cmd>             (test doubles: throttling/dropping/etc.)
```

By default (push, used by `rw handoff`) `--source-path` is read directly --
this process runs on the focus machine, where the source content already
lives -- and `--dest-path` is reached over the wrapper (the worker). Pass
`--pull` (used by `rw handback`, which also always runs on the focus machine)
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

rsync reaches the far side with `-e "<ssh> -o BatchMode=yes -o
ConnectTimeout=N"` and `<alias>:<path>` in ssh mode (the path shell-escaped
with `%q`, since openrsync has no `--protect-args`), and as a plain local
path in local/custom mode.

## Command line

```text
handoff sync --direction handoff|handback --source-path <path> --dest-path <path>
     --dest-mode local|ssh|custom [--dest-worker <alias>]
     [--dest-exec-bin <bin>] [--dest-exec-arg <arg>]... [--pull]
     [--kind git|plain]                    default: git when the source is a worktree toplevel
     [--dest-manifest <file>]              enables the manifest gate (file may be absent)
     [--resolve overwrite|keep-both|abort]
     [--manifest-out <dir>]                writes source.tsv and dest.tsv after success
     [--endpoint <id> | --state-file <path>] [--token <name>]
     [--backup-root <path>] [--staging-root <path>]
     [--check-lfs] [--force-diverged]
handoff fingerprint --path <path> --dest-mode ... [...]
handoff manifest --path <path> [--kind git|plain] --dest-mode ... [...]
```

Exit codes: 0 ok, 2 diverged (nothing touched), 3 transfer verify failed
(destination untouched), 4 post-apply verify failed or rsync channel failed
(destination partially applied -- see backup; re-running converges), 5
manifest conflict (stdout lists `conflict\t<relpath>\t<changed|added|deleted>`,
nothing touched), 64 usage. On success stdout is one JSON object:
`{ok, kind, generation, backup_dir, head_commit, branch, fingerprint,
renamed[], overwritten, duration_ms}`.

## Manifests and the manifest gate

A manifest has one `<relpath>\t<size>\t<mtime-epoch>` row per file whose
content a sync can overwrite outside git's own diff -- for git roots the
gitignored files (rsync channel) AND the untracked files (git channel's
tar; a nested repository's `.git` excluded), for plain roots every file -- byte-sorted (symlinks record mtime 0: rsync does not
carry symlink times), and for git roots a final `#git\t<fingerprint>` row.
`.DS_Store` files and keep-both copies are never listed. The caller stores
the two manifests `--manifest-out` writes, one per side, at every ownership
change.

With `--dest-manifest`, before anything is touched the destination's current
manifest is diffed against the stored one: every row that changed, appeared
or vanished is a conflict -- unless nothing would be lost: a destination
file that already equals the incoming source file (a retried or partly
finished sync), or a deleted file the source lacks too. When the stored manifest does not exist (first
handoff onto an existing directory), the baseline is the incoming source's
manifest instead and only files that would be replaced or deleted conflict.
Conflicts exit 5 unless `--resolve` says otherwise:

- `overwrite` -- proceed; the owner's copy wins.
- `keep-both` -- first rename each changed or added destination file to
  `<file>.local-<YYYYMMDD-HHMMSS>` (listed in the result's `renamed`).
  Keep-both copies are excluded from both channels' deletes, from manifests
  and from the git fingerprint, so no later sync removes them or reports
  them as changes; they stay on the side they were made on.
- `abort` -- same as no flag.

The stored manifest's `#git` row is also the baseline of the git divergence
gate (below); without one, the endpoint/state-file generation record is used.

A plain owner copy with no files at all would empty the other copy; that
exits 1 unless `--resolve overwrite`. Before the rsync channel writes into a
plain root, every destination file it will replace or delete is tarred into
`<backup-root>/<token>/<generation>-<ts>/files.tar` on the destination host
(the result's `backup_dir`).

Roots with git submodules (any `160000` gitlink, on either side) are refused
with exit 1 before anything is touched: neither channel carries a
submodule's checkout.

## rsync channel

Apple openrsync (protocol 29) on both machines. Flags:

```text
COPYFILE_DISABLE=1 rsync -rlptD --delete --exclude-from=<rules> [-e "<ssh> ..."] <src>/ <dst>/
```

`-rlptD` is `-a` without `-o`/`-g`: the two machines run different users,
and ownership is the receiving user's. Rules (first match wins):

```text
- .DS_Store
- *.local-[0-9]{8}-[0-9]{6}          (spelled as bracket classes)
- /<each keep-both path renamed in this run>
plain roots:  - /.git                 (everything else travels; nested repositories whole)
git roots:    + /<ancestor>/ ...      for each collapsed ignored entry
              + /<entry>/  + /<entry>/**   (directories)  or  + /<entry>  (files)
              - *
```

The collapsed ignored entries are the `!!` rows of `git --no-optional-locks
status --porcelain=v1 -z --ignored=matching --untracked-files=normal`, read
from the source and from the destination after the git channel applied
(the union, so an entry the owner no longer has is deleted on the other
side). Excluded paths are never sent and never deleted, so tracked files,
untracked files and `.git` are left to the git channel. Wildcard characters
in paths are escaped. After the transfer the source and destination
manifests must be identical (exit 4 otherwise: usually another writer).

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
     (non-ignored untracked files only), plus `untracked.list` (their
     names) and `protect.list` (this run's keep-both renames) for the
     untracked-file deletion in the apply step.
   - `lfs-snapshot.tar` -- present only with `--check-lfs` on a repository
     that has Git LFS configured: `git lfs pull` first (best-effort, so
     changed content is materialized locally), then the whole
     `.git/lfs/objects` directory. See the LFS caveat below.
2. **Transfer**: `tar -cf - .` over the snapshot dir, piped through the exec
   wrapper into a destination staging directory (default
   `<state-dir>/handoff-staging/<token>/g<gen>-<ts>/`, resolved on whichever
   side is being written to). A dropped connection here fails the whole
   pipeline (`tar`'s own exit status, checked); the live destination has not
   been touched yet.

   `<state-dir>` resolution differs by side and is intentionally asymmetric:
   - **Local-machine default** (no `--backup-root`/`--staging-root` passed --
     e.g. `rw handback`'s pull direction, where the destination being backed
     up/staged is this same focus machine): `common.sh`'s `rw_state_dir()`,
     i.e. `$TMUX_REMOTE_WORKSPACES_STATE_DIR` if set, else
     `$XDG_STATE_HOME/tmux-remote-workspaces`, else
     `$HOME/.local/state/tmux-remote-workspaces`.
   - **Remote-worker default** (a caller writing to a remote worker, e.g.
     `rw-handoff.sh`'s push direction, always passes both flags itself):
     `common.sh`'s `rw_state_dir_at(<worker-home>)`, computed from the
     worker's own queried `$HOME` (from `preflight.sh`), never this
     process's local `$HOME`/`$XDG_STATE_HOME`. It honors only
     `$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR` (contract C4), which a
     same-host fake-ssh harness sets so the worker side lands in its own
     sandbox; `$TMUX_REMOTE_WORKSPACES_STATE_DIR` redirects the focus side
     only.
3. **Verify staging**: read back `staging/meta.json` over the wrapper and
   confirm its `head_commit` matches what was captured. A truncated/missing
   file here means the transfer was interrupted -- **exit 3**, live
   destination untouched, source untouched.
4. **Divergence check** (runs before staging, together with the manifest
   gate): compute the destination's current content fingerprint (HEAD +
   hash of staged/unstaged/untracked state, see below) and compare it to
   the baseline -- the `#git` row of `--dest-manifest`, else the
   fingerprint recorded after the last sync through this
   endpoint/state-file. Not diverged: a destination that fingerprints
   `EMPTY` (absent or not a repository: nothing there can be lost), or that
   already equals the source. With NO baseline, any other existing
   destination repository is diverged (it was never synchronized by rw, so
   resetting it could drop its commits or edits). A run interrupted after
   it started modifying the destination leaves an in-flight marker
   (`<staging-root>/<token>/inflight`, holding the baseline); a retry from
   the same baseline continues instead of reporting divergence. A mismatch
   means the destination was modified independently since -- **exit 2**,
   both sides left exactly as they were, no backup taken, no
   last-writer-wins. `--force-diverged` explicitly overrides (a backup is
   still taken).
5. **Backup**: only when the destination is already a git worktree. Runs
   entirely on the destination host (bundle + staged/unstaged patches +
   untracked tar of the destination's *own current* state, same format as
   the main snapshot) into
   `<state-dir>/handoff-backups/<token>/<generation>-<timestamp>/` (`rw`
   passes `--token root-<root_id>`). Recoverable with ordinary git
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
   delete destination untracked (non-ignored) files and nested repositories
   absent from the source's list (and any directory that empties), except
   keep-both copies. The bundle is fetched into a per-root ref
   (`refs/rw-incoming/<token>`, since linked worktrees share refs) and the
   captured sha is checked out directly, never a ref.
7. **Verify**: recompute the destination's fingerprint and compare to the
   fingerprint captured from the source before anything was touched. A
   mismatch is reported as **exit 4** (destination was modified but is not
   verified correct; the pre-overwrite backup from step 5 is still there).
8. **rsync channel**, then the manifest check (see "rsync channel").
9. **Record generation**: on success, write
   `{generation, fingerprint, direction, synced_at, head_commit, branch, backup_dir}`
   either onto the endpoint registry's `workspace.sync` (`--endpoint <id>`)
   or a plain JSON file (`--state-file <path>`) -- both are interchangeable
   backends for the same divergence-tracking record, so the sync core is
   testable standalone without the full tmux endpoint registry. This single
   fingerprint is checked against whichever side is about to be
   overwritten on the *next* sync in *either* direction -- push and pull
   share one generation counter.

Every step logs to `events.jsonl` (`rw_log_event`) with duration and
outcome, including failed attempts, per docs/tmux-remote-workspaces.md's Observability
section.

## Content fingerprint

`HEAD-commit:sha256(staged diff):sha256(unstaged diff):sha256(sorted
newline-separated untracked file list, keep-both copies excluded)`, computed by an identical generated script on
whichever side is asked (`rw_sync_fingerprint_via` + `exec_*_script`). An
empty/non-repository path fingerprints as the literal string `EMPTY`. Two
worktrees with this fingerprint equal have byte-identical HEAD, staged,
unstaged, and untracked-file-list state (not full untracked *content*, see
Correctness notes).

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
- **The rsync channel is not staged.** It writes into the live destination
  (per-file temp names, then rename). An interrupted run leaves some
  ignored/plain files updated and some not; the ownership record has not
  changed yet, so re-running the same command converges. Plain roots have
  no backup: the manifest gate is what protects their destination.
- **mtime is second-resolution.** Manifests compare size and whole-second
  mtime; an edit that keeps both (same size, same second) is invisible.
- **Paths containing a tab or newline** are not supported by manifests.
- **Ownership boundary**: this directory does not create, close, or
  reconcile tmux endpoints or ownership records, does not implement provider
  adapters, and does not decide when to stop a local/remote AI agent -- see
  `../../scripts/rw-handoff.sh`, `../../scripts/rw-handback.sh`, and
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
- `--state-file <path>` (or `--dest-manifest`) decouples divergence
  tracking from any registry, so `sync` is fully testable standalone;
  `rw-handoff.sh`/`rw-handback.sh` pass `--dest-manifest` from the ownership
  record.
- `../../tests/run.sh` exercises all of the above (round trips of a plain
  folder and a linked worktree, conflicts, keep-both, divergence, the ssh
  wrapper with rsync `-e`) with a fake same-host ssh and no tmux.
