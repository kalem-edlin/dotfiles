# Provider agent adapters

Provider adapters for the agent handoff described in
`docs/tmux-remote-workspaces.md`, section "Handoff and return".

```text
adapters/
├── common-adapter.sh   # shared helpers; sourced, never executed directly
├── pi                  # simplest adapter -- arbitrary-path resume
├── claude               # transcript placement encodes destination path
├── codex                # all five subcommands implemented (see "Codex gate")
└── smoke-test           # on-demand dev tool -- see "Smoke test" below
```

Build order (decided in the plan): Pi, then Claude, then Codex. Codex's
`install` was gated pending a live smoke test; that test has since run and
passed (see "Codex gate" below), so all three adapters implement the full
five-subcommand contract.

`rw handoff` / `rw handback` (see `../scripts/rw-handoff.sh`,
`../scripts/rw-handback.sh`) are the
command-surface seam that dispatches into these adapters. Adapters are
called blind -- they make no assumptions about tmux-remote-workspaces
runtime state beyond `common-adapter.sh` itself.

## Contract

Each adapter is an executable implementing five subcommands:

### `detect --pane <pane-id>`

Stdout JSON `{provider, session_id, project_path, mode_flags}`, exit 0.
Exit 1 if that provider isn't currently running in the pane.

`mode_flags` is the live process's access mode (a space-joined string,
possibly empty), extracted from its actual argv against a per-provider
**allowlist** -- claude: `--dangerously-skip-permissions`,
`--permission-mode <v>`; codex: `--dangerously-bypass-approvals-and-sandbox`,
`--sandbox <v>`, `--ask-for-approval <v>` (short `-s`/`-a` normalized to
long form); pi: none (no run modes). The original command line is never
copied wholesale: one-shot launch arguments (`--resume`, `--continue`,
prompts, codex's non-resumable `--full-auto`) can never leak into a replay
because only allowlisted tokens survive extraction.

Two-step detection, mirroring (not reinventing) the prior art in
`tmux-workspace-resurrect/scripts/common.sh`'s `workspace_infer_agent()`:

1. **Liveness**: walk the pane's process tree (`common-adapter.sh`'s
   `ca_pane_has_process`) looking for the provider binary. This walks actual
   descendants rather than trusting tmux's `#{pane_current_command}` alone,
   because npm-launched CLIs (codex, pi) commonly surface as `node` there,
   and claudef execs a patched build at `~/.cache/claudef/bin/<version>`
   (tmux then shows the bare version, e.g. `2.1.327`). The claude pattern
   matches bare `claude`, that build, and the native
   `~/.local/share/claude/versions/<version>`; `scripts/common.sh`'s
   `rw_provider_pattern` (used to verify a resume and to stop an agent) is
   kept identical.
2. **Session identity**: read the per-pane JSON that
   `tmux-workspace-resurrect/scripts/record-agent-session.sh` deposits via
   each provider's own `SessionStart` hook/extension, for the CURRENT tmux
   server only: `<state>/agents/server-<pid>-<start_time>/pane-<id>.json`
   (the path from that plugin's `workspace_pane_state_file ... write`).
   The legacy flat `agents/pane-<id>.json` is never read: pane ids restart
   with every server, so it names a stale session. Adapters are a
   **read-only consumer** of this file; they never write it.

If the process is running but no recorded state exists (hook never fired,
or the workspace-resurrect plugin isn't installed), detect exits 1 with an
explanation rather than guessing.

### `versions --worker <alias>`

Stdout JSON exit 0, or exit 3 with an exact stderr remediation command when
the worker CLI is older than local. This adapter **never** runs the
remediation itself (consume, never provision).

- **Claude**: `{local, worker, policy}` where local/worker are plain semver
  strings (native side-by-side installs under
  `~/.local/share/claude/versions`; no Node dependency).
- **Claude / Pi** also check that the worker resolves the focus launcher
  (`claudef` / `pif`: on `PATH`, in `~/.local/bin`, or as a function of the
  interactive login zsh) and exit 1 with the setup remediation when it does
  not, since every resume runs through it.
- **Codex / Pi**: `{local: {cli, node}, worker: {cli, node}, policy}` --
  both are npm packages under fnm, so alignment is CLI package version *and*
  Node version. `policy` is `"identical"` only when both match; a Node-only
  mismatch with an equal-or-newer worker CLI is reported as `newer_worker`
  with a stderr notice (only CLI *oldness* blocks, per the plan).

### `export --session-id <id> --project-path <path> --out <dir> [--worker <alias>]`

Copies the minimum resumable session state into a local staging `<dir>`
plus a `manifest.json` (provider, session_id, source_project_path,
transcript_file, exported_at). `--project-path` is the **source** path
(used to locate the transcript in provider storage); with `--worker`,
export reads it over SSH from that worker instead of locally (this is how a
*return* handoff starts). Auth state is never touched by any adapter --
Claude's `~/.claude.json` and Codex's `~/.codex/auth.json` /
`~/.codex/config.toml` are never read or copied. The one exception: Claude's
`install` marks the destination folder trusted in that machine's own
`~/.claude.json` (`projects["<path>"].hasTrustDialogAccepted = true`, every
other key kept, an already trusted folder left untouched), so a resumed
session never stops at the "trust this folder" dialog.

Exit 4 if no matching transcript exists to export (gated/not-resumable).

### `install --snapshot <dir> --dest-path <path> [--worker <alias>]`

Places the snapshot so the session is resumable from `dest-path`. Idempotent
(re-running with the same snapshot/dest overwrites with identical content).
`--dest-path` is the **destination** path -- the destination's PHYSICAL path
(under the worker's own physical home, never the laptop's user name). For Claude this is the path whose slug becomes the containing
directory name, since Claude resolves transcripts by destination-encoded
project path, and every transcript `cwd` field is rewritten to it. For pi
the session header's `cwd` (line 1) is rewritten to it; every other line is
copied byte for byte.

**Codex `install` is implemented** (de-gated per a live sandboxed smoke
test -- see "Codex gate" below for what was and was not verified).

### `resume-cmd --dest-path <path> --session-id <id> [--fork] [--mode-flags <flags>]`

Prints the exact resume command to stdout (never executes it). Claude and pi
resume through the focus launchers (decision D13), from `--dest-path`:
`cd <path> && claudef [mode flags] --resume <id>` and
`cd <path> && pif --session <ref>`. The command is typed into the endpoint
pane's interactive login shell, so the launcher resolves whether it is a
script on `PATH` or a zsh function, fnm's node is active, and the
launcher's hooks (agent-state publisher, resurrect session record) run on
either machine. `claudef` always passes `--dangerously-skip-permissions`
itself, so a captured copy of that flag is dropped. Codex is unchanged. `--fork`
uses provider-native forking for a divergent-lineage return handoff
(`claude --resume ... --fork-session`, `codex fork ...`, `pi --fork ...`)
rather than bespoke lineage bookkeeping, per the plan.

`--mode-flags` splices `detect`'s captured access mode back into the
printed command (claude: before `--resume`; codex: on the
`resume`/`fork` subcommand, which accepts them directly) so a handed-off
session relaunches in the same permission mode on the other side --
bidirectionally: `rw handoff` passes detect's live capture, `rw handback`
passes the value recorded on the endpoint at handoff time. Tokens are
re-validated against a safe charset before splicing (this is a public CLI
surface).

Codex's `resume-cmd` is **not** gated -- it always prints the intended
command, both for documentation and so `install` can be unblocked later
without touching this subcommand.

## Codex gate

Codex is **de-gated**: `codex install` is implemented and `codex`'s own
private SQLite `threads` table (`~/.codex/state_5.sqlite`, one row per
rollout file, indexed by cwd) no longer needs to be touched directly.

A sandboxed `CODEX_HOME` smoke test against a real `codex` binary confirmed:

- Codex lazily **backfills** the `threads` table from rollout files on disk
  the next time it starts against a `CODEX_HOME` with a missing/stale row --
  no manual DB surgery needed. A copied rollout file becomes a real
  `threads` row automatically.
- The backfilled `cwd` column comes from the rollout's own first-line
  `payload.cwd` field, not from `codex resume`'s `-C` flag. A rollout copied
  verbatim from another host keeps the *source* host's cwd, which breaks
  cwd-filtered discovery (`codex resume --last`, the default picker) at the
  destination even though explicit-id `codex resume <id>` and the
  backfilled row itself are unaffected.

`install` therefore places the rollout at a filename/date-bucket-valid path
(`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`) and rewrites just
the first line's `payload.cwd` to `--dest-path`, then relies on Codex's own
backfill for the DB row -- this adapter never touches sqlite directly. See
`./codex`'s own header comment for the full verified-facts writeup.

The sandboxed smoke test proves indexing, placement, and `payload.cwd`
rewriting. The later live operator journey also completed a real Codex
handoff and return, including prompt continuity and destination-only resume.

## Smoke test

`./smoke-test` is an on-demand dev tool, not wired into tmux anywhere. For
each provider it runs a fully sandboxed (`$HOME` and, for codex,
`$CODEX_HOME`, redirected to a fresh temp directory -- never the real
`$HOME`, live tmux server, ssh, or any content-engine-trees path) export ->
install round trip against a synthetic transcript fixture, and asserts
placement correctness (claude: destination-path-encoded projects dir; pi:
file placed and `resume-cmd` resolves it; codex: rollout placed with
rewritten `payload.cwd`). It prints, and deliberately does not attempt, the
one manual step that still needs a real TTY: completing an interactive
resume. Run it directly:

```sh
libexec/adapters/smoke-test
```
