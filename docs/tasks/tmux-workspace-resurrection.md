# Tmux workspace resurrection investigation

Status: reopened September 17, 2026. The earlier fixes did not establish reliable operation under load.

## September 29, verified save repair and retention

No user process, pane, session, or server was restarted or relaunched.

The two missing Codex IDs were recovered by following each pane's process
descendants to native Codex and reading only the metadata header of its open
rollout. The save-time check now validates the root conversation ID, cwd, and
main CLI source. It understands an optional `_attemptUUID` filename suffix,
ignores subagent rollouts, and rejects ambiguous roots. Live verified identity
takes precedence over a stale hook. Process queries have two-second bounds and
metadata reads are limited to 1 MiB. No transcript search or cwd-based ID guess
is used. The precise original reason the startup hooks did not record these
IDs remains unproven. Hook trust was not bypassed or altered; the official
[Codex hook documentation](https://learn.chatgpt.com/docs/hooks) requires review
of non-managed hooks, so this repair does not silently approve them.

The save wrapper now writes into a private staging directory. Only a validated
layout, matching sidecar, full pane coverage, and exact agent IDs are published.
Each successful layout has its own immutable `.workspace_state.json` companion.
`last` is the commit pointer; the restore helper follows it to the matching
companion. The old `workspace_state.json` name is retained as a compatibility
symlink. Filenames include a unique suffix to avoid same-second collisions.
Rejected saves preserve the previous checkpoint and report affected pane names.
The required upstream path-override patch is installed and wired into setup.

Validation included 36 Python tests, transaction/retention regressions, the
existing agent-resume/multiline/restore-guard integrations, ShellCheck, syntax,
and whitespace checks. A first live attempt exposed the newer Codex root
filename and subagent distinction; it rejected the attempt while preserving
the old pointer, metadata, and marker. After adding regression coverage, a real
verified save at September 29, 19:33:54 CDT completed in **2.50 seconds** with
**68 panes, 38 agent records, 10 Neovim sessions, and zero agent capture errors**.
All 68 saved logical panes match the live server. Snapshot:
`tmux_resurrect_20260929T193352_47908_10775.txt`.

Retention remains age-based: 30 days by default, always retaining the newest
five and the current selected snapshot. Companions are removed with expired
layouts. Cleanup uses one directory scan, not one subprocess per file. Manual
and periodic saves use the same path. A continuously active five-minute timer
produces 288 saves per day; there is no fixed count cap. Periodic autosave is
still paused. The separately created emergency recovery bundle is not copied
on each save and has no automatic expiry.

Before live verification, the entire prior save directory was preserved at
`~/.local/state/tmux-workspace-resurrect/pre-transaction-save-Btj7Sj/resurrect/`.
The existing age policy then pruned three expired layouts dated August 28–29;
all three remain recoverable in that copy. There are now 668 ordinary layout
snapshots. Older historical layouts do not retroactively acquire matching
sidecars; per-snapshot metadata history starts with this repair.

## September 26, whitelisted automatic resumption

Approved behavior is now configured as `restore_mode: "whitelist"`, with
`claudef`, `pif`, `codexf`, and `nvim` allowed and a 500 ms launch delay.
Automatic execution requires a recognized saved application record, running
process evidence, and an exact recorded agent ID or existing Neovim session
file. Shell-at-save, unknown commands, unsupported records, and pending shell
input remain queue-only. Pending input wins over application metadata even
when an old Neovim registration is still present.

Unsubmitted scripts retain their literal multiline text, trailing blank lines,
and cursor position. A private ZLE widget assigns the cursor directly in
Emacs and vi insert modes. Live draft input and running foreground processes
are left alone. Repeating restoration does not duplicate launch attempts or
queued text. These changes apply to future restorations; no current user
tools were relaunched to activate the policy.

The local manual restore bindings and Continuum restore path now use a guarded
wrapper. It shares a lock with the verified save wrapper and requires explicit
completion from the workspace restore hook. Saves fail closed while restoring
or after an incomplete attempt on that server. The guard is server-PID scoped,
not cross-restart recovery protection. The remote worker attach-loop's direct
upstream restore path is outside this local wiring. Periodic autosave remains
paused from the preceding incident.

Validation: 27 Python unit tests; isolated tmux/ZLE integration with harmless
tool stubs (exact IDs, 500 ms spacing, byte-exact draft/cursor, live-pane skips,
repeat idempotence); existing agent-resume and multiline capture integrations;
restore/save lifecycle guard regressions; ShellCheck and shell syntax checks.
An early test fixture inherited the user's Neovim path and launched Neovim in
its disposable pane. That fixture was cleaned up. The final test isolates
ZDOTDIR/XDG paths and verifies all four stub resolutions before restoration.

## September 26, 21:25 crash recovery

Recovered all 57 logical panes from the protected 20:08 checkpoint. All 36
nonempty queued commands were verified against pane captures, including 24
recorded agent sessions. Eight editor commands now reference independently
preserved newer generation files with inline buffer text, not the old empty
legacy sessions. Agents/editors remain queued for Enter rather than auto-run.

Automatic startup restoration was blocked by three leaked isolated Neovim test
servers. Continuum suppresses startup restore when other tmux servers exist.
Verified and terminated only `workspace-nvim-test-68900`,
`workspace-nvim-test-80560`, and `workspace-nvim-test-81090`. Added exit cleanup
to the Neovim test; Python syntax validation passed. A new manual save after
the earlier restoration was not required. Saves through 21:16 existed.

At 21:21 the launchd timer replaced `last` and the companion sidecar with the
new one-pane workspace, despite the success marker remaining at 21:16. The
timer was unloaded during recovery and remains paused. Manual saving is still
available. Prevention of partial-workspace overwrite remains unresolved.

Original backup: `~/.local/state/tmux-workspace-resurrect/recovery-bundles/recovery-20260927T012140Z-dd66df99/`.
All 892 payload hashes passed. Incident preservation and recovery staging:
`~/.local/state/tmux-workspace-resurrect/recovery-incident-20260926-AJhzIs/`.
This includes pre-recovery artifacts and newer Neovim files. The original
backup was not modified. The normal restore pointer and sidecar now reference
the recovered checkpoint again.

An isolated tmux 3.7b test reproduced `select-layout` accepting a 118-column
layout while window width remained 113. All 45 staged layouts were normalized
in an isolated server to 113x33 before live restoration. All recovered live
pane bounds fit their windows. This establishes the clipping mechanism, not
the cause of the reported server crash. No September 26 tmux crash report was
found, and a persistent resize/restore fix has not been implemented.

## September 26, 20:59 Neovim text restoration and Codex command repair

### Why `pane-_64.vim` reopened empty

The frozen 20:21 recovery copy contains a meaningful 1,437-byte session for
`roll-5-carousels:3.0`: cwd `content-engine-5`, editing
`/private/tmp/recovered-caption-scene-pairing.md`, with cursor line 17.
The live file was rewritten at **20:43:58** into a 1,090-byte session with cwd
`dotfiles`, `enew`, and no file to edit. This overwrite is directly observed.

The old module used only the tmux pane ID in its filename and scheduled
`mksession!` during initialization. Reused pane IDs and startup saves could
overwrite the very `-S` file being restored. That is the likely mechanism;
there is no per-write audit trail proving which process performed the overwrite.
Separately, the original `/private/tmp` document is now missing. Ordinary
`mksession` stores layout and file references, **not unsaved or unnamed buffer
text**. The earlier existence-only artifact audit did not establish text recovery.

### Audit of all eight previously saved editors

| Saved editor | Current finding |
| --- | --- |
| roll-11-gestures:3.1 | Recovered unnamed buffer open, modified, 5 lines; preserved |
| roll-5-carousels:3.0 | Caption file missing; recovered separately from `.swo` |
| roll-5-carousels:10.1 | Recovered unnamed buffer open, modified, 43 lines; preserved |
| roll-6-agentic-engineering:1.1 | Missing named target, recovered text open, modified, 27 lines; preserved |
| roll-6-agentic-engineering:2.1 | Missing named target, recovered text open, modified, 79 lines; preserved |
| roll-6-agentic-engineering:3.1 | Unopened unnamed buffer; separately recovered uncertain directory-swap candidate |
| roll-9-broll-classification | Missing temporary prompt file, recovered text open, modified, 9 lines; preserved |
| roll-hiring:1.1 | Empty unnamed buffer both in saved references and current editor; no evidence of missing text |

Before activation, all six live editors' ordinary loaded buffers were copied
using read-only RPC to a private safety file:
`~/.local/state/tmux-workspace-resurrect/recovered-buffers/20260926T204936/live-buffer-capture.json`.

Old swap files were copied first, then recovered using isolated, config-free,
headless Neovim into separate private files under the same directory. No
original swap, source document, or live buffer was overwritten/deleted:

- `caption-from-swo.md`: **8,565 bytes / 50 lines**, from the 19:50 swap; no
  reported recovery errors or missing-line markers. This is the substantial
  caption recovery. Other generations are retained separately: newer `.swn`
  recovered only four bytes; older `.swp` recovered 22 lines. Mtime alone was
  therefore not a safe basis for choosing content.
- `UNCERTAIN-roll-6-agentic-engineering-3.1-from-directory-swf.txt`:
  **10,049 bytes / 40 lines**, recovered without reported errors. Attribution
  to the old unnamed pane is not proven, so it was not injected automatically.

### Implemented and activated

- Editor generation filenames include process ID, time and a high-resolution
  nonce retained across module reload. Initial persistence waits for startup
  restoration; it cannot replace its own `-S` source.
- One atomically published, private `.vim` artifact embeds loaded ordinary
  buffer text alongside layout, including modified and unnamed buffers. There
  is no separate companion-text dependency or new background service.
- Text changes (including insert/completion edits) update this artifact on a
  750ms coalesced timer, independent of tmux's save cadence, without per-keystroke
  tmux calls or mksession generation. Explicit saves and topology changes refresh
  the layout too. Edits newer than the last completed snapshot can still be lost
  in an abrupt crash; this is not a zero-loss transactional editor journal.
- Restoring applies text to buffers in memory, preserves window associations,
  cursors, modified state and relevant buffer options, and never overwrites the
  underlying source documents. A temporary, path-scoped swap guard avoids the
  routine recovery prompt for backed-up buffers; normal swap settings resume.
- The tmux save hook now checks Neovim's actual boolean acknowledgement, fails
  an explicit refusal without publishing a new sidecar, and bulk-refreshes the
  registered paths after RPC. An acknowledged session must be a nonempty file.
- Removed the redundant approval-bypass flag from generated Codex resumes.
  Restore also normalizes already-saved Codex commands, retaining exact IDs.
  Pending shell input is not rewritten. The wrapper remains responsible for
  the flag; the recorded command is `codexf resume <recorded-ID>`.

Activated by reloading the module in all six current registered editors and
calling `save()`. Before/after hashes of loaded text, names, buffer IDs and
modified flags matched in every editor; no editor was restarted. The subsequent
verified save at **20:59:44 CDT** took **1.79 seconds**, covered **54/54 current
panes**, had zero agent capture errors, and contained six private inline-text
Neovim session files plus the corrected exact-ID Codex command.

Tests include real isolated Neovim restart with stale swaps and reused tmux pane
ID, modified named text versus changed disk content, two visible unnamed splits,
live module reload, failed-mksession preservation of the prior artifact; 19 Python
tests; recorder/save/restore integration including old redundant Codex flags;
Neovim timeout and false acknowledgement; multiline/68-pane capture; ShellCheck,
syntax and whitespace checks. A separate test edits text after the explicit
save, waits only for the debounce, SIGKILLs the disposable editor (no exit save),
and confirms the newer text restores while the source session stays unchanged.
Legacy frozen sessions remain unchanged and still
require their separate recovery candidates; their missing text cannot be created
retroactively by the new implementation.

## September 26, 20:21 manual recovery copy

At the user's request, made one private, reboot-persistent recovery copy at:

`~/.local/state/tmux-workspace-resurrect/recovery-bundles/recovery-20260927T012140Z-dd66df99/`

- Preserves the verified 20:08 layout/sidecar/marker: 57 panes, 24 exact agent
  resumes, and eight Neovim sessions.
- Includes actual native conversation histories plus Claude's session-specific
  subagent/tool-result directories and Codex child histories, not merely IDs
  or paths. Histories/editor sessions reflect their state at copy time.
- 892 independently copied payload files, 474,387,396 bytes (about 452 MiB),
  with SHA-256 verification of every copied file. Source layout/sidecar/marker
  and the `last` target were checked unchanged throughout creation.
- Private directories/files (0700/0600), outside Git and outside OS temporary
  directories. `manifest.json` records original paths, bundle paths, sizes and
  hashes; `RECOVERY.md` explains careful manual restoration.

The user explicitly rejected a separate maintenance script/service. Removed
the newly drafted bundle CLI, installer and tests; no LaunchAgent was installed,
no automatic backup/cleanup hook was added, and normal save performance is
unchanged. This copy is managed manually for now. If age-based cleanup is later
implemented, keep it in the existing verified-save lifecycle: only recognized
bundles older than three days, retaining the newest verified recovery copy.

## September 26 reboot-readiness audit of the 20:08 manual save

Read-only inspection of the user's new manual save; no save, live restore,
restart, or configuration change was performed during this audit.

- `last` points to `tmux_resurrect_20260926T200849.txt`; companion metadata is
  dated 20:08:51 CDT and the successful-save marker 20:08:52 CDT.
- Exact snapshot/sidecar agreement: 57/57 unique pane logical IDs, all 57 cwd
  directories present, zero agent capture errors.
- 24 exact-ID focus resumes: 21 Claude, two Pi, one Codex. Native session
  history files for all 24 exist, located by explicit session-file path or
  exact-ID filename under native session roots; transcript contents were not
  read. All eight referenced Neovim session files also exist.
- Three valid Treemux mappings. Twenty-one ordinary shell panes have an empty
  selected command: their layout and cwd are saved, but no command is queued.
- Installed configuration enables `@continuum-restore on`, loads the workspace
  post-restore hook, and configures queue mode. The actual loaded config list
  includes both `~/.tmux.conf` and `~/.config/tmux/tmux.conf`; the smaller former
  file is not shadowing the latter. `~/tmux_no_auto_restore` is absent.

### Expected behavior and limitations

After reboot, restoration is configured to run when the first tmux server
starts. This is not a promise that merely booting macOS starts tmux: Continuum
boot integration is not enabled. Restored agent/editor commands are pasted
into the relevant shells without Enter. The user must execute them. This
audit did not perform a full reboot or an actual production restore.

Automatic restore can be skipped by Continuum if another server is already
running, or individual commands can be skipped if shells are not ready within
the configured per-pane/global budgets. Those failures do not inherently
destroy the saved commands or native histories; they remain usable for manual
reconstruction. Neovim session files preserve editor setup and file references,
not a guarantee of every unsaved buffer byte; normal swap recovery is separate.

### Manual recovery reference

If startup restoration fails, **do not take a new save over the recovery source**.
Preserve the current `last` target, `workspace_state.json`, and the referenced
Neovim session files before another attempt. Native Claude/Pi/Codex histories
are also required for exact conversation resumes and must remain on disk.

The live configured restore binding is **prefix + Ctrl-Alt-r**, with confirmation.
**Prefix + Ctrl-r reloads configuration; it is not the restore binding.** Only
invoke restore after inspecting the current landscape: it can alter existing
panes, especially Treemux sidebars. The upstream layout restore chains the
workspace post-restore hook. If necessary, manual reconstruction can instead
use each sidecar pane's `logical_id`, `cwd`, and `selected_command` to rebuild
the layout and queue its exact command, without requiring old pane process IDs.

Redundancy gap: historical layout snapshots exist, but `workspace_state.json`
and the referenced per-pane Neovim session files are mutable latest-state
files. The present save is recoverable; it is not an immutable multi-generation
backup. Recommended next step before reboot is a timestamped recovery bundle
containing the matching layout, sidecar, and Neovim sessions, with a manifest
of required native agent history files. No bundle was created in this read-only
audit. Autosave remains paused; the verified checkpoint is a manual save.

## September 26, 19:13 save-performance repair

Manual saves now complete in **1.89–1.92 seconds** on the current live workspace,
versus **13.345 seconds** measured at the start of this investigation. The earlier
25–30-second observation was on a larger workspace and different machine load;
these measurements are not a guarantee under arbitrary build pressure.

Two GPT-5.6 Sol agents handled upstream auditing/repair and custom-hook batching;
the main agent profiled the real save, reviewed correctness, and verified artifacts.

### Measured cause and changes

| Live measurement | Complete verified save | Upstream before custom hook | Custom hook |
| --- | ---: | ---: | ---: |
| Before changes | 13.345s | 8.884s | 4.325s |
| Process-scan bypass only | 4.870s | 0.501s | 4.236s |
| Bypass plus batching | 1.919s | 0.493s | 1.195s |

Phase times are approximate boundaries from Bash tracing; totals include the
verified wrapper. An independent untraced final save took 1.89s. The user was
actively using/changing the workspace (56–57 panes during this profiling run).

- Upstream Resurrect invoked its `ps` strategy separately for every pane,
  scanning the whole system process list despite `@resurrect-processes=false`.
  The existing setup bypass patch had not been applied to the installed plugin.
  Applied it now: disabled process replay no longer pays for unused command
  capture. Normal/default process-capture behavior and the 11-field layout
  schema remain intact. Existing setup patch installation makes this durable.
- The custom hook launched Python inference for each pane, another Python
  process for each agent resume, and repeated jq decoding/assembly. Replaced
  this with one `assemble_panes.py` process importing the canonical command
  builder and validating all hook records directly. Shell-traced custom-hook
  Python/jq invocations fell from 236 to 11. This count excludes child tmux
  calls within Python; it is not a claim of only 11 total save subprocesses.
- Pane metadata remains one lossless bulk capture. Treemux registrations now
  use bounded batches of eight pane-option expansions; sidebar identities are
  resolved from the captured pane set rather than per-sidebar tmux calls.
- A first all-in-one Treemux query hit tmux's large-format limit at 57 panes
  (9,483-character format returned only a newline). The verification gate
  rejected those candidate saves without advancing the success marker. Bounded
  batches fixed this; a new 68-pane regression prevents repeating it.
- Neovim RPCs remain serial and bounded by the existing timeout. No completeness,
  provenance, exact-ID, atomic publication, or successful-save validation was
  removed for speed. Busy/unresponsive editors can still increase save time.

### Final live acceptance

The verified wrapper completed successfully at **19:13:59 CDT**:

- 57/57 panes, exact layout/sidecar coverage, zero capture errors.
- 21 Claude, two Pi, and one Codex record. All 24 agent objects and generated
  resume commands hash-identical to the pre-optimization baseline; commands
  were also parsed and checked against their exact saved session IDs.
- Eight Neovim sessions and all three valid Treemux sidebar mappings retained.
  Two previously emitted stale Treemux entries with sidebar logical ID `:.`
  are correctly excluded by resolving against actual captured panes.
- Success timestamp advanced. No user client/build was restarted or stopped,
  no live restoration was performed, and autosave remains paused.

Tests pass: 18 Python tests (including malformed/non-UTF8 hook data, identity
edge cases, legacy timestamps, pending-buffer priority and batched exact IDs);
real recorder/save/queued-restore integration; multiline and lossless Treemux
argument round trips; 68-pane capture; Neovim timeout; upstream process bypass,
enabled/default strategy and invalid-strategy fallback; syntax/ShellCheck and
whitespace checks. The Neovim robustness fixture now seeds isolated environment
paths before starting its test server.

Normal usage remains **prefix + Ctrl-S**; no reload is needed. To measure again:
`/usr/bin/time -p bash ~/.config/tmux/scripts/resurrect_save.sh` (writes a save).

## September 26, 18:06 verified repair

This is the current result, superseding the incomplete-save warnings below.
Two GPT-5.6 Sol agents implemented capture/coverage and record/test isolation;
the main agent recovered affected metadata and verified the live save.

### Live acceptance result

The same verified wrapper used by manual prefix+Ctrl-S completed successfully
at **18:06:45 CDT**, in 25 seconds:

- **68/68 panes** captured, with unique logical locations and exact coverage
  of the authoritative tmux-resurrect layout.
- **21 Claude, three Pi, and one Codex session** recorded with nonempty IDs.
- Every generated command was parsed and checked against its saved ID:
  `claudef --resume <id>`, `pif --session <id>`, `codexf resume <id>`.
- **Zero agent_capture_errors**. The success marker advanced and the status
  indicator rendered `0m` immediately afterward.

No live agent was restarted and no production restore was run. Autosave
remains paused as requested; this verifies manual saving, not periodic saving.

### Repairs and recovery

- Replaced independently line-aligned pane-field queries with a single bulk
  query using random field markers decoded into JSON. Commands and edit
  buffers retain embedded newlines instead of shifting later pane rows.
- Refuse incomplete/duplicate/drifting pane capture. The verified wrapper
  compares the sidecar's logical pane set against the actual layout file,
  not just its claimed count or a later live view.
- Hook records now write under
  `agents/server-<server-pid>-<server-start>/pane-N.json`. Different tmux
  servers cannot overwrite same-numbered panes' records. Legacy records are
  read-only fallback and still undergo identity/timestamp validation.
- Test servers receive temporary state/config/resurrection directories before
  any panes exist. Hook lookup can recover the state path from server
  environment if a child loses the variable. Tests cover cross-server pane-ID
  reuse and missing propagated environment without production writes.
- Recovered **all seven** test-contaminated legacy records from the preserved
  pre-test copy. Archived the synthetic versions under
  `~/.local/state/tmux-workspace-resurrect/agents/recovery-20260926-test-contamination/`.
  No native agent conversation history was deleted or rewritten.
- Verified the preserved Codex ID against the current `CODEX_THREAD_ID`.
  Verified Pi's preserved ID/cwd against its native session-file header.
- Verified the disputed Claude ID against its native live-process registry
  `~/.claude/sessions/20586.json`, including PID 20586 being a child of the
  current pane process and the matching tmux pane. The ID was correct; the
  legacy cwd check was a false rejection. Refreshed its scoped registration
  from this authoritative native record, without restarting Claude. Codex's
  scoped registration was similarly refreshed from its verified identity.

The previous layout/sidecar/marker were backed up before the live save under
`/private/tmp/tmux-before-verified-repair.bNLca5`.

### Regression verification

All pass: 15 command/wrapper unit tests; multiline command/edit-buffer capture;
real recorder-to-save-to-queued-restore tests on isolated tmux servers;
cross-server metadata isolation and lost-environment protection; actual
verified-wrapper positive and agent-error cases; Neovim timeout robustness;
syntax and whitespace checks. No real agent command was executed by restore
tests. Future full-restore testing should still use an isolated server rather
than interrupt this live workspace.

## September 26, 17:55 screenshot and manual-save audit

The newest Desktop screenshot, `Shot 2026-09-26 at 5.54.49 PM.png`, shows
"Layout saved, but 3 agent session(s) lack verified resume IDs." This is a
partial save, not evidence that nothing was written. The production sidecar
was written at 17:54:33 CDT and references
`tmux_resurrect_20260926T175130.txt`. The success marker remains at 12:54:36.

The three explicitly rejected entries are:

- `dotfiles:1.0`, pane `%3`, expected Codex. Its live hook file instead holds
  a synthetic Pi record from test server 59702 and temporary test directory
  `/private/tmp/workspace-agent-resume-test.jIp7Su`, recorded at 20:00:12 UTC.
- `dotfiles:2.0`, pane `%4`, expected Pi. Its live hook file instead holds a
  synthetic Codex record from the same test server/time.
- `roll-11-gestures:2.0`, pane `%214`, the previously identified legacy Claude
  record with mismatched cwd and no process identity.

The first two are contamination from this investigation's tests. Earlier
claims that all testing left production hook metadata untouched were wrong.
The current integration script explicitly passes its temporary state directory,
but an earlier test run wrote records into the shared production agent
directory. Files are keyed only by pane number, so a different tmux server
can overwrite same-numbered production files. Identity validation rejects
those records during save but does not prevent the overwrite itself.

The original `%3` Codex and `%4` Pi records are preserved under
`/private/tmp/tmux-agent-preview.gOPB2i/state/agents/`. Their tools, pane IDs,
timestamps and cwd match the earlier live preview. This audit did not yet
replace the contaminated files or claim that a new save has verified recovery.
Native agent session histories were not deleted by this metadata overwrite.

A separate capture defect is confirmed: the saved layout has 67 pane records,
but its companion sidecar has only 50. Logs show "skipping unstable pane row"
for the omitted rows. Fresh read-only queries found three extra physical
lines in `@workspace-last-command` output, while title/path/buffer queries
had one line per pane. The save script joins independently formatted fields
by line position using `paste`; multiline commands therefore misalign later
rows. Its mismatch guard avoids mixing different panes' data but silently
drops application state. Structural validation currently does not compare
layout and sidecar pane coverage.

The sidecar does contain 14 Claude and two Pi records with nonempty IDs and
focus resume commands. That is partial success, not a fully recoverable
workspace. The three-agent warning is not an exhaustive account of the
17 omitted pane records.

Required repairs: recover the two preserved production registrations after
checking current identity; isolate hook-record filenames by tmux server and
harden tests against production writes; encode multiline fields safely and
gate successful-save reporting on full pane coverage; resolve the legacy
Claude registration; then take and inspect a fresh manual save. This turn
performed diagnosis and documentation only, not these repairs.

## September 26, focus-agent resume repair

Scope: repair exact-ID restoration through `claudef`, `pif`, and `codexf`.
Automatic saving stays paused at the user's request. No live restore or
production save was invoked by this investigation. Luna 6 agents audited
profile hooks/artifacts and implemented helper tests and isolated integration
tests; the main agent reviewed and integrated the repair.

### Hook audit and changes

The hooks are installed in the actual focus configurations: claudef's explicit
settings file, pif's extension directory, and the normal Codex hooks file used
by codexf. The suffix/profile split was not a missing-hook issue on this Mac.
The confirmed failure was provider inference ignoring the suffixes, followed
by the broken jq join dropping all otherwise eligible session metadata.

Changes now active through the `~/.config/tmux` repository symlink:

- Parse normal and focus launcher names, including executable paths and
  simple `env`/assignment/command prefixes. Ignore mentions inside unrelated
  commands. Support a literal `cd <path> && <launcher>` prefix.
- Always generate `claudef --resume <id>`, `pif --session <id>`, or
  `codexf resume <id>`. In a follow-up request the user chose explicit resume
  syntax, so codexf now forwards its arguments without inserting `resume`.
  Replace old selectors; do not preserve an old
  session ID. Preserve supported simple options and safely quote arguments.
- Serialize agent metadata before jq joins it. Save the recorded ID in both
  the agent object and the generated selected command.
- Bind new hook records to server PID/start time and pane PID. Reject hooks
  still carrying an old server's TMUX environment. Legacy records require
  matching tool/pane/cwd and a timestamp after server startup. That legacy
  check is intentionally conservative but weaker than new identity binding.
- Missing, malformed or stale records now produce explicit per-pane errors
  and no bare picker/fresh launch. The verified manual-save wrapper refuses
  to advance its success marker when these errors exist. Valid layout and
  other pane data can still be saved; a partial save is no longer reported
  as fully verified agent recovery.
- Preserve pending shell edits and Neovim restoration precedence. Disabled
  Neovim capture no longer performs an RPC anyway.

### Live preview, not a production save

A temporary agent-only capture at 19:56 UTC generated exact-ID commands for
13 Claude, three Pi, and one Codex pane. This preceded the additional literal
`cd ... && claude` support. Production `last`, sidecar and success marker were
not changed. Preview directory: `/private/tmp/tmux-agent-preview.gOPB2i`.

One live legacy record was rejected at `roll-11-gestures:2.0`, pane `%214`.
Its recorded cwd is `content-engine-11/apps/expo`; the pane and current Claude
process cwd are `content-engine-11`. The record lacks the newly added process
identity. The audit did not relabel or overwrite that record to make it pass.
A fresh native SessionStart from the correct client can establish identity;
until then, its exact-resume readiness remains unverified.

The next acceptance step is the user's manual prefix+Ctrl-S, followed by
read-only comparison of generated commands against their recorded IDs and
inspection of `agent_capture_errors`. The user was asked to report any save
warning. A real user-profile resume was not launched as a test.

Verification completed in this turn: 14 command-helper unit tests; the
isolated real-recorder/save/restore test for normal and focus launchers,
including stale/missing metadata and pending shell buffers; the real verified
save wrapper rejecting partial agent capture without advancing its marker;
and the existing Neovim robustness test. All pass. The main agent reran the
integration suite after reviewing the changes. At the final check, the
production sidecar was still the pre-repair 12:54:36 CDT save, so verification
of a new user-triggered manual save remains pending.

Reference: [official OpenAI CLI documentation](https://developers.openai.com/codex/cli/reference/)
confirms interactive Codex resume by ID. The user-requested explicit wrapper
syntax is now covered by 15 unit/wrapper tests and the isolated restore test.
The wrapper test executes its actual zsh function with a fake Codex executable
and checks both instruction-loading branches, including no-argument startup.
Historical launch metadata using `codexf <id>` remains readable; new generated
commands always include `resume`. Existing shells need to reload `.zshrc` or
open a new shell before using the new syntax. Previously saved artifacts are
not rewritten; take a new manual save to capture the updated commands.

## September 23, 23:56 audit after another crash

Read-only runtime audit. No save or restore was invoked, and no commands were
manually inserted into user panes during this investigation.

- The latest verified save is now **23:46:30 CDT**, not the September 21 save
  described in the earlier audit. `last` points to
  `tmux_resurrect_20260923T234612.txt`; the success marker is 1790225190.
- The custom restore log records execution at **23:47:55–57**, ending with
  `restore complete: queued=33 skipped=0 dry_run=false`. The pane input
  buffers were populated by this restore code, not by manual intervention
  from this investigation. Whether startup or a manual restore action invoked
  that code is not established by this log.
- Of the 33 queued commands, **27 are last-command replays and six are
  neovim-session restores**. The sidecar has 57 panes, 33 nonempty selected
  commands and **zero agent records or generated agent-session commands**.
- Exact bare commands in the saved data include nine `claudef --resume`
  entries and one `pif --resume` entry. Additional focus-launcher records
  include other arguments. Their source is `last-command`, not a generated
  session resume. The missing IDs were not stripped by paste/restore: they
  were never added during save. The launcher-inference and metadata-parser
  defects below remain present in the deployed code.
- Neovim's successful restoration follows its separate saved-session path.
  The user's observed Codex recovery does not establish correctness of agent
  metadata capture; its replay source is still last-command, not codex-session.
- `launchctl print gui/501/com.kalem.tmux-resurrect-save` still reports no
  service, and Continuum's interval is zero. Periodic saving remains off.
  The client-detached save hook and manual save path remain available, but
  the current log does not identify which triggered the 23:46 save.
- The screenshot's seven-minute chip is consistent with elapsed time since
  that 23:46 successful save. It is an age display, not a countdown or proof
  of scheduler health. The runtime check, rather than the seven-minute value
  alone, confirms the scheduler is missing.

The timer was paused during the September 17 investigation of slow/failed
saves. Historical logs include sidecar-refresh failures, malformed-save
rejections and write errors. Leaving that pause unresolved after restoring
the status display left durability dependent on nonperiodic saves. This is
an unfinished repair, not a reason normal operation should lack autosave.

## September 23, missing autosaves and agent resume diagnosis

Requested scope: explain the failed save/restore behavior and implement window
naming. Save/restore checks were read-only. No save, restore, agent launch,
timer activation or server restart was performed during this audit.

### Confirmed causes

1. **The five-minute scheduler is absent.**
   `launchctl print gui/501/com.kalem.tmux-resurrect-save` reports no service.
   The plist exists and specifies 300 seconds, but is not loaded. Continuum's
   interval is deliberately zero, so there is no fallback periodic scheduler.
   We paused launchd on September 17 and never completed reactivation. The
   September 18 status restoration changed display only. The live tmux option
   advertising five minutes describes intended cadence, not scheduler health.
2. **The latest verified save is old.** `last` points to
   `tmux_resurrect_20260921T132208.txt`; `.last-successful-save` is epoch
   1790014954, September 21 at 13:22:34 CDT. The launchd log still ends
   September 17, so that save did not come from the periodic launchd job.
   The current tmux server started September 23 at approximately 13:37.
3. **Focus launcher detection is incomplete.** `workspace_infer_agent` in
   `scripts/common.sh` recognizes claude/codex/pi but not claudef/pif. The
   shell records the actual submitted launcher, so those focus commands
   never enter the agent-session resume branch despite their recorder hooks.
4. **Eligible agent metadata fails parsing, silently.** At `scripts/save.sh`
   around line 219, the jq expression joins two strings and an object using
   `join("\u001c")`. A synthetic valid Codex record reproducibly fails with
   exit 5, "string ... and object ... cannot be added". The script suppresses
   stderr and uses `|| true`, leaving all parsed fields empty. Consequently
   even recognized Codex launches retain a raw launch command instead of a
   session-specific resume command. This is a current confirmed code defect;
   the old successful August logs do not validate the current implementation.

The September 21 sidecar contains **69 panes, 60 nonempty selected commands,
9 empty commands, and zero agent records**. Its sources are 65 last-command
and four neovim-session records. It is incorrect to characterize all selected
commands as empty. Current live panes have shell command metadata, so the
absence of agent records cannot be dismissed as a universally missing shell
integration. Replaying the sidecar may queue ordinary launch commands, but
cannot recover session-specific resumes from agent records it never saved.

The current post-restore hook is installed. Logs have no restore/queue
completion entries for September 18–23, so invocation during the crash
recovery remains unproven. The sidecar is a single mutable file rather than a
versioned companion to each layout snapshot; the September 17 sidecar was
overwritten, preventing retrospective proof of exactly what that recovery
could have restored. Queue mode intentionally pastes commands for the user
to review and press Enter; it does not automatically execute them.

### Naming change implemented and tested

- New auto-named shell windows start as `[empty]`.
- The first submitted command names the window immediately and retains that
  name after exit. Focus wrappers remain `pif`/`claudef`, not `node`.
- Basic leading environment assignments and `env`, `command`, `exec`, and
  `noglob` wrappers are skipped. Arguments do not become part of the label.
- Manual window names are preserved. Only the first eligible naming attempt
  contacts tmux; there is no polling or per-keystroke naming work.
- The global format is applied live. The hook is in the existing symlinked
  zsh integration file, so new shells receive it. Existing interactive shells
  can load it with `source ~/.zsh/tmux-workspace-resurrect.zsh`; no commands
  were injected into running editors or agents to force a reload.
- `bash tmux/tests/window_naming_test.sh` passes on a dedicated isolated tmux
  server, including the actual `[empty]` initial window name, sticky command
  name, all three requested launchers, assignments, and manual-name protection.
  Zsh syntax and changed-file whitespace checks pass.

### Repair required next

Recognize the focus launchers, correctly serialize agent metadata and report
capture errors; add regressions for their exact session resume commands.
Version sidecars with layout snapshots. Verify a real save contains current
agent session IDs and test queued restoration in an isolated server, then
reload the five-minute launchd scheduler and observe scheduled success.
Re-enabling the timer alone would only save the currently broken agent data
more frequently. Status should also distinguish a stopped scheduler from a
merely old save. None of these save/restore repairs was applied by this audit.

## September 18, original status restored

At the user's request, removed the temporary plain status-format override and
refreshed the live client. The existing decorated session/window formats and
compact autosave, directory and host chips are active again. No tmux server
restart, plugin reload or autosave service change was performed. The pending
tmux upgrade remains separate from this restoration.

## September 17, latest repair and decision list

This section supersedes earlier completion claims. Treemux is repaired and
deployed. The picker, autosave deployment and tmux server upgrade are still
pending. No Xcode build was stopped, signalled, reprioritized or reconfigured.

### Repaired now: Treemux

- Disabled Neo-tree and nvim-tree Git integration and continuous filesystem
  watchers in `tmux/treemux_init.lua`. Removed custom Git action bindings and
  the custom GIT_EVENT handler that forced Git refresh/redraw cycles. Kept
  file navigation, safe opening, path copying and manual `R` refresh.
- Excluded Pods and DerivedData from the sidebars. External filesystem changes
  now need manual refresh rather than continuous build-output watching.
- Added `setup/patches/treemux-polling.patch`: corrected the inactive interval
  option keys and numeric default; reject invalid intervals; determine actual
  visibility from attached clients' window IDs before doing cwd/RPC
  work (including windows linked into another session); replace lsof/awk cwd
  discovery with tmux's pane_current_path.
- Hidden windows check again every five seconds without cwd queries or Neovim
  RPC. Visible windows retain the existing 0.5/2-second cadence. Returning to
  a hidden tree can therefore take up to five seconds to resume cwd following;
  its existing display and manual navigation remain available immediately.
- Installed the patch locally and wired idempotent application into
  `setup/lib.sh`. Setup fails explicitly on upstream patch drift.
- Restarted only the three Treemux sidebar panes after bounded RPC checks
  showed zero modified buffers. Pane IDs/layouts were preserved. Restarted
  their three watcher processes with validated numeric arguments.

Measured result: the previously hot hidden Neo-tree was still using roughly
38% CPU after the native build ended (40–60% in earlier samples). The three
replacement sidebar cores subsequently measured 0.0% CPU, with no Git
children. This supports a real Treemux improvement, not merely attributing
the build's completion to our fix. It does not establish responsiveness
during another full native build; that remains an acceptance check.

Verification: headless Treemux configuration test, polling behavior tests,
Bash syntax checks, pristine patch application and reverse-check/idempotence
tests pass. Live watchers have numeric `0.5 2 5` arguments and hidden-window
logs show no tree initialization/RPC. The attached client's session/window
ID format was checked against a real pane. No interactive editor was killed.

### What the Content-Engine-11 build actually did

The native build finished naturally at approximately 19:27:56 CDT. Xcode's
activity-log manifest records **3718.582 seconds (61m 58.6s)** for Debug
`Build RollPreview`, with zero errors and 2032 warnings. Its activity log is:

`~/Library/Developer/Xcode/DerivedData/RollPreview-abvamqtdmgzbmxcgmecwjifpbyhq/Logs/Build/6FFFD643-C10C-4A25-A2D5-FB7A15481A6C.xcactivitylog`

- Pods.xcodeproj contains **192 PBXNativeTarget entries**, plus 14 aggregate
  targets. A previous estimate of 400 confused dependency entries with targets.
- The log contains **1630 unique Compile-file arm64 tasks**, and no x86_64
  compile tasks. Hermes and React Native New Architecture are enabled.
- An always-run expo-updates script took approximately 134 ms; that warning
  does not explain an hour-long build.
- The log does not establish a clean build, cache hit rate or the cause of
  broad recompilation. DerivedData creation time alone is not evidence of
  cache deletion. A trustworthy longest-phase breakdown is still missing.
- Expo/Metro and short-lived bundling workers continued after native build
  completion. They must not be mistaken for an ongoing Xcode compilation.

This is a powerful 14-logical-CPU, 36-GiB machine. The earlier measurements
show substantial memory compression, around 12–13 GiB allocated swap, and
slow process launch/system queries even while CPU had idle capacity. Allocated
swap alone does not prove current thrashing. We have evidence of host-level
latency plus terminal-side amplification, not proof that Codex, Ghostty or
Treemux caused the entire build duration. See the timed probes below.

### Remaining actions, in recommended order (not deployed)

1. **Finish autosave and deploy the faster SessionX launcher.** Autosave's
   launchd job is deliberately unloaded, separately from the plain status
   experiment. Last successful marker observed: 18:26:25. Complete the
   installed-plugin patch migration, eliminate repeated global process scans,
   test timeout/failure/concurrent-save paths, verify a real manual save, then
   re-enable and observe a scheduled save. The prepared SessionX wrapper
   reduces mocked startup/selection tmux calls from 48 to 8, including 41 to
   zero scalar option reads. Prefix-o is still bound to the old launcher;
   measured live popup latency after deployment remains to be verified.
2. **Upgrade the running tmux server to 3.7c or a newer verified fixed version,
   then restore the original compact status.** The running server is 3.7b.
   Upstream issue 5367 and the 3.7c changelog identify a format timing-check
   regression/fix matching the blank-status symptom. This is a strong lead,
   not an A/B proof on this Mac. Installing a binary does not upgrade an
   existing server. Plan the server restart only after a fresh verified save
   and user-approved interruption window; do not kill it with live work.
   The plain status is temporary, and autosave indicator padding was already
   returned to compact formatting.
3. **Disable only Codex's decorative glimmer:** set `whimsy = false` inside
   `[tui]`, then restart Codex at a safe point. The installed 0.154.0 schema
   explicitly associates this with Astra composer stars. `animations = false`
   is the broader optional switch. Issue 44444 reports the same input-cursor
   symptom, but that does not explain cursor movement in another editor or
   prove Codex is the main source of host contention. Neither setting changed.
4. **Measure and budget native builds rather than launching more unbounded
   builds.** Capture a build timing summary/result bundle on the next approved
   build and compare an unchanged incremental build against this baseline.
   Inspect the longest compile/script phases and why inputs were invalidated
   before changing project settings. Preserve stable, separate DerivedData
   and Pods state per worktree; avoid unnecessary cleaning. Reuse a development
   build/Metro for JS/TS-only edits where native inputs are unchanged. For two
   simultaneous native builds, test a bounded worker budget (for example four
   compiler jobs per build) and measure memory pressure and terminal latency.
   This is a starting experiment, not a guarantee that every pair fits 36 GiB.

Sources: [tmux status regression](https://github.com/tmux/tmux/issues/5367),
[tmux 3.7c changes](https://github.com/tmux/tmux/blob/3.7c/CHANGES),
[Codex input-cursor report](https://github.com/openai/codex/issues/44444),
[matching Codex config schema](https://github.com/openai/codex/blob/rust-v0.154.0/codex-rs/core/config.schema.json),
[Expo development builds](https://docs.expo.dev/develop/development-builds/introduction/).

## September 17, 19:08 to 19:17 diagnosis during the build

The Xcode build remained running and was not signalled, reniced or reconfigured.
The user confirmed the plain tmux status remains stable, while the decorated
row flashes. This is an isolation result, not justification for permanently
removing the user's status design.

### System latency versus terminal-specific work

Eight rounds of subprocess measurements, with output discarded, yielded:

| Probe | Median | Maximum |
| --- | ---: | ---: |
| Launch `/usr/bin/true` | 133 ms | 161 ms |
| Start clean Bash and exit | 123 ms | 151 ms |
| Query tmux's server PID | 176 ms | 484 ms |
| Enumerate processes with ps | 1.394 s | 7.391 s |

These are diagnostic subprocess latencies, not keystroke-to-pixel timings.
They include process launch and scheduling. They show that delay exists
outside tmux's renderer, and explain how serial subprocess-heavy scripts can
take seconds under this workload. A 45-call startup magnifies that delay.
They do not isolate a particular kernel scheduling or I/O defect.

During these probes autosave was unloaded and the plain status was active.
Neither can therefore be the sole cause of the measured slowdown. Around
19:12, top reported 35 GiB RAM used, about 10 GiB wired, 12 GiB compressor,
and 124 to 434 MiB unused. Swap occupied about 13 GiB and disk had 53 GiB
free. A six-second vm_stat interval showed no new swap-outs and mostly no
swap-ins, although memory decompression continued. Existing swap use alone
does not prove active disk thrashing. CPU was about 57% idle in one sample
despite over 100 runnable processes; calling this simple CPU saturation
would also overstate the evidence.

Short ps samples showed tmux around 2% CPU, Ghostty around 1%, and Codex
around 7%. Those samples do not show any one of these consuming the host.
They cannot exclude intermittent stalls or output-triggered redraw costs.
The Codex native sample mainly showed waiting threads plus TUI/input/render
work; it did not capture a long blocking terminal-size ioctl.

### New confirmed terminal-side amplifier: hidden Treemux work

Hidden Neo-tree PID 38751 used roughly 40 to 60% CPU and had overlapping Git
status children. Its accumulated CPU time exceeded 97 hours over 20 days.
That is substantial background work, not proof that it dominates the whole
machine. The Git command includes ignored-file enumeration:
`git status --porcelain=v2 -z --ignored=traditional --untracked-files=normal`.

The installed Treemux code contains two concrete polling defects:

- `scripts/variables.sh:19` overwrites the numeric inactive-window interval
  with `@treemux-refresh-interval-inactive-window`. `tree_helpers.sh:17` uses
  that same string as the fallback value. Live watchers actually received
  that literal string as argument seven. `watch_and_update.sh:191` passes it
  to sleep, which fails instead of waiting when the inactive-window branch
  is reached. The roll-hiring watcher currently meets that branch condition.
- The watcher chooses its 0.5-second active cadence from pane_active before
  checking window visibility or session attachment. An active pane in an
  unattached session therefore polls as if visible. This was observed for
  the roll-10-experiments and roll-3-revenue watchers.

Each iteration probes cwd with lsof plus awk/tail, queries tmux three times,
and makes two more pane-existence queries. The custom
`tmux/treemux_init.lua:229` also responds to Git events by scheduling another
Git status, filesystem refresh and redraw. The overlapping Git work is
observed; an infinite event feedback loop has not been proven.

These are repair targets independent of Codex and Xcode. Correct interval
defaults, check actual visibility before polling, debounce/coalesce Git work,
and avoid ignored-file scans unless needed. No live Treemux process was
stopped or changed during this diagnostic pass.

A leftover diagnostic `find .. -name AGENTS.md -print`, PID 72446, had
survived the interrupted earlier turn and was itself consuming CPU. Its exact
parent and command were verified before it was terminated. This removed our
own unnecessary scan, not any user workload or build.

### Terra research into Codex reports

The on-disk Codex binary reports 0.154.0. The active process uses that path
and started about 24 hours ago; the version of an already-loaded process
cannot be proven from the current on-disk binary alone.

- [Codex issue 44444](https://github.com/openai/codex/issues/44444) reports
  composer cursor flicker on 0.154.0 with Astra, including reproductions with
  and without tmux. Reporters say `tui.whimsy=false` mitigates it. A contributor
  attributes visible intermediate cursor positions to split frame writes.
  This is a matching-version lead and an A/B test candidate, not a confirmed
  explanation for cursor movement in a different Neovim pane.
- [Codex issue 11877](https://github.com/openai/codex/issues/11877) measures
  substantial PTY output and tmux-history growth from animations while Codex
  appears idle. Later users report improvement with animations disabled.
  The initial measurements use an older HEAD and tmux 3.6a; later comments
  mention 0.154.0. This supports testing animation output as an amplifier,
  not blaming it for tmux's separate decorated-status bug.
- [Codex issue 24527](https://github.com/openai/codex/issues/24527) reports
  long synchronous terminal queries on loaded macOS in 0.145.0, including
  Ghostty. A CPU-heavy build reproduced slow queries in two independent TUIs.
  The focus-query portion has a linked upstream fix, but this review did not
  establish whether all ordinary-draw size-query delays are fixed in 0.154.0.
  Its relevance is the build-dependent latency mechanism, not version-exact
  confirmation on this machine.

Official [Codex TUI documentation](https://learn.chatgpt.com/docs/config-file/config-advanced#tui-options)
documents disabling animations. The more specific whimsy workaround above
comes from issue reports and was not applied to the live process here.

### Exact unfinished state after the interrupted implementation

- The compact autosave age change is applied; the plain live status is left
  active at the user's request.
- `default-terminal=tmux-256color` is applied for new panes. Existing editor
  processes retain their original environment.
- The new SessionX wrapper passes fully mocked end-to-end tests, reducing
  48 calls to 8. It is not wired to the live or persistent prefix-o binding.
- Isolated Neovim save robustness tests pass in six seconds. This is not an
  end-to-end validation of the full live autosave path.
- The skip-process-capture patch is unfinished: it is not registered in the
  installer and does not apply to the currently patched upstream file.
  Do not claim the 57 process scans have been eliminated in the live plugin.
- The launchd autosave timer remains deliberately unloaded from the prior
  repair attempt. It must be restored after the upstream patch is rebased,
  installed and tested. Automatic saving is not currently operational.

The next implementation should fix the Treemux polling/Git churn, deploy the
tested picker wrapper, finish and validate the autosave patch, and test Codex
animation controls separately. Upgrading the running tmux 3.7b server is also
needed for the known format-timeout fix, but must be planned so it does not
interrupt the user's build or destroy live sessions.

## September 17 evening follow-up

At 18:53, load average was about 202 and swap use about 13 GiB, but disk free
space had recovered to 53 GiB. The previous disk-full explanation does not
explain this evening's symptoms. The user explicitly prohibited stopping or
altering the Xcode build; that build was left untouched.

The save marker was 18:26:25 and the active save was over 23 minutes old.
A plain `tmux list-sessions` took 0.02 seconds in the initial sample, while
the status helper took 0.25 seconds. Later helper measurements ranged from
0.20 to 1.18 seconds. These are variable snapshots, not end-to-end UI latency.

### Actual display evidence and upstream cause

A targeted capture of Ghostty window 18070 showed the entire reserved status
row blank. Tmux still reported `status=on`, a 113-by-34 client and a 113-by-33
pane area. The missing row was real, not a user misunderstanding of settings.

The temporary plain `status-format[0]` rendered correctly. The user reported
that it was stable, but could no longer confidently distinguish its behavior
from the prior decorated row. The original full status format was restored.
This experiment did not prove a chip-width bug.

Subsequent user observation strengthened the comparison: restoring the full
decorated row immediately brought back empty/flashing/moving tiles. At the
user's request, the plain live format was reapplied and left active for
verification. The timer's `%4dm` padding was removed, returning its age to
compact text such as `5m`. The plain test format does not display the timer;
the compact age will be used when the regular chips are next enabled.

The comments on [tmux issue 5367](https://github.com/tmux/tmux/issues/5367)
identify the 3.7b regression more precisely than the issue's initial report.
Nested format expansion shares a 100 ms elapsed-time budget. Per-character
clock checks can exhaust that budget under load; some helpers then return an
empty string and discard already-produced output. This explains how a valid
configuration can produce partially missing right-hand chips or a blank row.
The live 3.7b source has these checks. Local observations also caught partial
right-format expansions. This is a strong match, though we have not captured
the live server's own timeout diagnostic for a failing frame.

Commit `cba4ba9cd` reduces the frequency of those checks. The maintainer says
it was included in the 3.7c release branch, and the published 3.7b-to-3.7c
[CHANGES](https://github.com/tmux/tmux/blob/master/CHANGES) lists it against
issue 5367. This corrects the earlier uncertainty about whether that patch
release contains a relevant status fix. Installing a binary alone does not
upgrade the running server. No server restart was attempted during the build.

The terminal default was corrected in `tmux/tmux.conf` and in the running
server to `tmux-256color`. This affects new panes, not the environment or
terminal initialization of existing agents/editors.

### Cursor investigation and its limits

The active unnamed Markdown buffer in Neovim PID 92432 had neither
`b:md_render` nor the reader-mode variables enabled. The installed image
renderer already saves and restores the cursor around image placement, and
the local transport preserves those sequences. The image-renderer theory was
therefore rejected for this buffer. The reported typing/cursor defect remains
unresolved. Do not present status-format repair as proof that it is fixed.

Native profiles and window captures for this pass are in
`/private/tmp/tmux-perf-evening.ii5v7h/`. Tmux's sampled physical footprint
was 188.6 MiB and Ghostty's 488.2 MiB. These do not establish Codex as the
cause of the host-wide memory pressure.

### Changes and deployment checks

The overlong save PID 80833 and its verified save-only descendants were sent
TERM, and the launchd save timer was temporarily unloaded to install repaired
scripts safely. No Xcode, compiler, agent, or pane process was in that tree.

Terra isolated SessionX's option-fetch overhead. The first optimized
end-to-end mock run reduced 48 tmux calls to 8, including selection handling,
and scalar option queries from 41 to zero. One earlier baseline test
mistakenly opened a live popup. It exited without a selection or session
switch. Subsequent tests use fake tmux and fzf commands throughout.

## September 17 live performance investigation

Observed approximately 04:40 to 04:52 America/Chicago. The initial pass was diagnostic.
At 04:52 the user explicitly authorized stopping the identified iOS build.
No agents, terminals, or sessions were stopped, and no runtime settings
were changed. Three Terra agents separately investigated picker startup,
save implementation, and workload/transcript attribution.

### What is established

- The machine has 36 GiB RAM and 14 logical CPUs. `top` reported 35 GiB used,
  about 13 to 14 GiB in the compressor, around 9.6 GiB wired, and only 154 to
  177 MiB unused. Load average reached 258, with roughly 109 runnable processes.
  CPU was still over 50% idle in that sample. This is not evidence that a
  single terminal renderer has saturated all CPUs.
- Swap use grew from about 14 GiB to 18 GiB while available APFS data-volume
  space fell from 5.7 GiB to 1.4 GiB. This is consistent with paging consuming
  the remaining disk headroom, although this inspection did not attribute
  every filesystem write. The save log contains actual `No space left on
  device` failures from the earlier 03:06 save attempt. The rounded `df`
  capacity reads 100%; it does not mean literally zero free bytes at every
  observation.
- The sole observed tmux server was PID 2620, with 18 sessions, approximately
  57 panes and one attached 113-by-34 Ghostty client. Both server and Ghostty
  had been running about 39 days. This inventory covers the local machine,
  not SSH worker servers.
- All tmux pane history together occupied about 109.3 MiB. Sampled physical
  footprints were tmux 205.3 MiB, Ghostty 262.3 MiB and this Codex process
  202.8 MiB. These numbers do not support terminal scrollback or this Codex
  instance being the main consumer of 36 GiB RAM.
- Basic tmux queries completed in about 0.03 to 0.04 seconds in one timing
  sample. The autosave status helper completed in 0.13 seconds later.
  Neither measurement rules out intermittent stalls.

### Autosave is still defective

The success marker remained at 04:19:42. Save wrapper PID 95692 was still
running after 24 minutes. Its descendants were changing, so the observed
attempt was slowly progressing rather than proven permanently deadlocked.

The earlier claim of a hard 120-second timeout was incorrect. The wrapper
counts 1,200 polling iterations, each involving `ps`, `tr`, and `sleep 0.1`.
Those iterations can take much longer than 0.1 seconds under load. The
deadline must use elapsed time, and the child process tree needs a watchdog
that does not rely on rapid process-spawning polls. The lock-wait timeout
has the same loop-count problem. A launchd interval does not force a new
instance to replace an already-running job.

The save log separately establishes ENOSPC failures, malformed shell input
after those failures, and failure to refresh the sidecar. The stale age chip
is reporting lack of a verified save, not merely displaying the wrong clock.
The previously successful manual tests did not cover this resource-pressure
failure mode.

### Terminal drawing remains a separate unresolved problem

`tmux/tmux.conf:28` overrides the earlier screen terminal setting with
`default-terminal "${TERM}"`. The running server reports `xterm-ghostty`;
this live Codex environment has `TERM=xterm-ghostty` and `TERM_PROGRAM=tmux`.
Applications inside tmux are therefore receiving the outer terminal's
description instead of tmux's. The local `tmux-256color` terminfo entry exists.
Tmux explicitly requires a screen/tmux terminal description inside tmux.
This is a confirmed configuration defect and a plausible redraw contributor,
not proof of the exact cursor-jump sequence. See the
[tmux FAQ](https://github.com/tmux/tmux/wiki/FAQ).

The attached client stayed at 113-by-34 during a short observation in
`roll-5-carousels`; its window name, inherited `status=on`, and status-right
configuration stayed unchanged. Application titles were already disabled.
That sample did not establish that the status option itself was toggling.
The narrow window list can legitimately clip, but that alone cannot explain
physical corruption of the entire status row. No failing Ghostty frame was
captured, so the exact drawing defect remains unproven.

Tmux's 3-second native profile spent about half its main-thread samples in
`select`, with the rest spread over command handling, allocations and redraw.
Ghostty's main thread waited for events; its renderer did some glyph/row work.
Several macOS window-snapshot/background stacks stayed unchanged across the
sample. That is not enough to diagnose a Ghostty renderer loop.

One long-running Treemux Neovim process, PID 38751 under parent 38736, consumed
roughly 37 to 44% CPU across observations. Its profile includes Lua/event work.
It is an additional background cost, not by itself an explanation for the
system-wide load or a proven plugin infinite loop.

Correction to the earlier upgrade advice: the published 3.7b-to-3.7c changes
include a macOS allocator workaround, scrollbar initialization, loop timing,
message styling and a floating-pane crash fix. They do not establish that
3.7c fixes this user's status corruption. Do not confuse fixes on development
master with fixes in that patch release. See
[tmux CHANGES](https://github.com/tmux/tmux/blob/master/CHANGES).

Official Codex configuration documents alternate-screen and animation controls,
but changing them would be a controlled diagnostic experiment, not an established
repair for this incident. See the
[Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

### Evidence and limits

Native `sample` reports are in
`/private/tmp/tmux-lag-diagnosis.7pY6DJ/{tmux,ghostty,nvim,codex}.sample.txt`.
The measurements are short snapshots, not a continuous trace. Total transcript
storage was about 1 GiB for Claude and 8 GiB for Codex; disk totals are not
resident-memory measurements. No transcript archive was deleted or truncated.

### Workload attribution from Terra's process audit

The largest identified live workload belonged to Claude PID 89911 in
`roll-5-carousels`, window 6, pane 1, with shell ancestor 86864. Its process
tree accounted for about 8.6 GiB resident memory in one snapshot. This sums
RSS, not unique physical memory, and changes as workers exit.

The build chain was 89911 to 38933 to 38941 to 39050 to 40093. PID 38941 ran
the session's `scratchpad/build-only.sh`; PID 39050 ran:

```text
xcodebuild -project Pods/Pods.xcodeproj -target NitroNativeTools
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO
```

Its SWBBuildService had about 14 runnable Swift/clang compiler children,
together roughly 6.7 GiB RSS. The same Claude also launched overlapping
`npx tsc --noEmit` runs in `content-engine-5/apps/expo`. One exited during
inspection; another, PID 11805, grew to about 915 MiB RSS. These are identified
high-pressure workloads, not proven infinite loops. Another Claude in
`roll-11-adjustments` briefly had a roughly 728 MiB Node child that exited
during inspection.

The active engine-5 root transcript was 16.78 MB and grew only about 1.2 KB
over a roughly 100-second observation. Its 19 subagent transcripts totalled
17.4 MB. The inspected engine-11 root was 4.23 MB, with 14.6 MB of subagent
logs. These file sizes do not explain the live build tree's memory footprint.

### Save cost from Terra's source and live-process audit

Upstream `tmux-resurrect/scripts/save.sh:227` obtains a full command for every
pane. Its default `save_command_strategies/ps.sh:13` runs
`ps -ao ppid,args | sed | grep | cut`, scanning the whole machine 57 times
per save. `@resurrect-processes false` changes restore behavior; it does not
disable these save scans. One live `ps` subprocess lasted 28 seconds.
The partial 04:24:45 snapshot grew from 3,118 to 3,240 bytes over 45 seconds.

After that, the custom save hook performs 11 full pane-list queries, at least
171 per-pane option queries, and repeated jq configuration reads. This is
substantial process-spawning overhead. A true two-minute deadline alone
would bound failure, but would not make this save path reliable under load.
Read the process table once, batch pane options, and cache configuration
before expecting a dependable save interval.

The existing upstream sanity gate retained a valid authoritative `last`
snapshot during the observed disk-full error. Its current target is
`tmux_resurrect_20260917T034128.txt`, with a matching sidecar. Retaining an
older filename can also be legitimate when an unchanged save is deduplicated.
Any future success check must distinguish successful deduplication from a
failed attempt that merely leaves the previous valid snapshot in place.

There is also a source-confirmed false-success path. Upstream calls the
post-save hook even after rejecting a malformed candidate. If the sidecar
write then succeeds, the wrapper accepts the retained valid snapshot plus
the refreshed sidecar and advances the marker. The observed ENOSPC attempt
did not take that path because its sidecar did not refresh. Repair requires
an explicit per-invocation `committed`, `unchanged`, or `rejected` outcome,
with only the first two eligible to publish a success marker. A changed
`last` filename is not a sufficient replacement for that contract.

### Workspace picker measurements

Prefix `o` runs tmux-sessionx through a synchronous `run-shell` binding.
Terra isolated its read-only startup without opening a popup or changing
sessions. It makes 45 separate tmux client calls before invoking fzf.
Measured startup times were 1.178, 1.362, 1.414 and 2.025 seconds. The slowest
measurement spent 1.194 seconds preparing arguments and 0.485 seconds reading
key bindings. Tmuxinator and fzf-marks helpers only define functions at source
time; no helper hang was found.

These timings exclude the fzf-tmux popup, shell launch, rendering and any
already-queued commands on the attached client. They do not fully reproduce
the reported 10-to-20-second wait. They do establish avoidable serial startup
overhead on top of machine-wide pressure. At 04:51 even a standalone
`tmux list-sessions` took 0.56 seconds, compared with about 0.03 seconds earlier.
Synchronous `run-shell` waits its client command queue, not the whole server.
Batching option reads and avoiding duplicate session enumeration should come
before guessing that transcript rendering is delaying the picker.

### Next repair sequence

At 04:52, after explicit approval, TERM was sent to the verified
NitroNativeTools `xcodebuild` PID 39050 and its 29 descendants. The tree had
expanded since the earlier compiler count. Follow-up checks confirmed
xcodebuild and SWBBuildService had exited while Claude 89911, tmux 2620,
and Ghostty 97681 stayed alive. A subsequent `tmux list-sessions` took
0.03 seconds. A further check found none of the 30 targeted PIDs remaining,
and free RAM rose to about 3.8 GiB, 247,930 pages of 16 KiB each.
Load average was still 76 and swap about 17.8 GiB; disk space
remained only 1.6 GiB. This is immediate relief, not evidence that all
performance or rendering problems are repaired. No files were deleted.

1. Relieve disk and memory pressure. Approval was requested to stop only the
   identified NitroNativeTools build, leaving agents and sessions alive.
   Do not delete transcript archives or kill the tmux server as a first step.
2. Repair save deadlines and lock ownership; remove repeated global process
   scans and serial per-pane configuration lookups. Test delayed subprocesses,
   disk-full failures, deduplicated saves and marker publication explicitly.
3. Use `tmux-256color` inside tmux and Ghostty's description outside. Changing
   the default cannot change the environment of already-running agents;
   test one fresh process before planning any broad restart.
4. Measure the picker independently, then reduce its startup subprocesses.
5. Reproduce redraw behavior with a healthy system and correct TERM before
   blaming Codex scrolling or declaring an upstream patch to be the fix.

## September 16 repair record, superseded by the investigation above

## Implemented repair

- Continuum now handles restore-on-start only. Its save interval is zero and
  its command is removed from `status-right` after plugin loading.
- A launchd timer now runs the verified save wrapper every five minutes on
  the laptop. The ordinary install path installs and verifies that timer.
- The status indicator reads only `.last-successful-save`, locally and
  remotely. Its text stays five cells wide at every age.
- Each Neovim RPC has a three-second timeout. The entire save has a
  120-second timeout, and a later save can terminate a stale verified-save
  owner before reclaiming its lock.
- Neovim registrations now include an owner PID. Nested and headless editors
  cannot replace the pane owner. The owner clears its registration on exit.
- Restore readiness has a 30-second global budget and a two-second per-pane
  budget.
- Both tmux doctors now check the real timer, marker age, snapshot, sidecar,
  lock owner, and Neovim registration health.
- Codex uses a static project terminal title instead of a spinner title.
- Tmux rejects application OSC title updates, while explicit pane titles from
  tmux plugins still work. This removes the redraw source for the current
  Codex process and any other animated terminal title.

The old two-day process chain and stale lock are gone. Repeated full saves
completed successfully, the verified marker and sidecar are current, and the
workspace doctor passes every check.

`tmux/local-plugins/tmux-workspace-resurrect/tests/robustness.sh` covers
owner registration, nested-editor rejection, exit cleanup, and a stopped
Neovim server. The stopped server test finishes in four seconds, clears the
bad registration, and still writes the remaining workspace sidecar.

## Reported problems

- The autosave age in the tmux status line jumps between fresh and stale values.
- Running Codex makes the window capsules appear to collapse and expand.
- Workspace resurrection feels unreliable even when its health checks pass.

## September 16 explanation, incomplete for the current incident

Two bugs were implicated in the earlier status-line problem. They do not
fully explain the current incident, and the earlier causal claim was too strong.

The workspace save hook could block forever while asking a registered Neovim
server to save. The blocked save had been alive since September 14. Later
saves waited on its lock, timed out, and failed.

At the same time, tmux-continuum records the start of every save as if it were a
successful save. The verified-save wrapper later replaces that timestamp with
the older successful timestamp when the save fails. Those two writers fight,
so the status indicator alternates between values such as `0m` and `2950m`.
The different text widths make tmux recalculate how many window capsules fit.

Codex updates its terminal title for every spinner frame. Tmux treats each title
update as a reason to redraw the status line. Codex therefore exposes the
existing width and timestamp bug several times a second. It does not directly
rename or collapse the tmux windows.

## Live evidence

The system was inspected on September 16, 2026 with tmux 3.7b.

- The most recent verified save marker was from September 14 at 17:14:35.
- The `last` resurrect snapshot was also from September 14.
- The status indicator still showed `0m` at times.
- The Continuum timestamp changed to the current time, reverted to the old
  verified timestamp, then changed to the current time again.
- A `resurrect_save.sh quiet` process and its descendants had been blocked for
  more than 49 hours.
- The last descendant was an `nvim --remote-expr` request against a registered
  Neovim socket. That request never returned.
- The save lock still named the blocked process as its live owner. The lock
  cleanup only handles dead owners.
- The Codex pane title changed with every spinner frame, roughly every 200 ms.

No live processes were killed and no runtime state was changed during the
investigation.

## Root causes

### An unbounded Neovim RPC can freeze every save

[`save.sh`](../../tmux/local-plugins/tmux-workspace-resurrect/scripts/save.sh)
calls every registered Neovim socket synchronously. It has no timeout. One
unhealthy socket blocks the save wrapper and retains the global save lock.

The Neovim integration also lets nested or embedded Neovim processes overwrite
the pane's `@workspace-nvim-server` option. In the blocked pane, the option
pointed to an embedded child rather than the foreground editor. Exit handling
schedules a final save but does not safely clear ownership of the pane option.
Stale socket registrations accumulate as a result.

Relevant code:

- `tmux/local-plugins/tmux-workspace-resurrect/scripts/save.sh`, lines 28 to 37
- `nvim/lua/tmux_workspace_resurrect.lua`, lines 3 to 7 and 66 to 87
- `tmux/scripts/resurrect_save.sh`, lines 79 to 102

### The timer records attempts as successes

Tmux Continuum starts the configured save command in the background and
immediately sets `@continuum-save-last-timestamp`. It does not wait for the
command to finish.

The custom verified-save wrapper has different semantics. It updates the same
timestamp only after validation and restores the last verified timestamp after
a failure. Both components write the same option, so a failed save makes the
timestamp oscillate.

[`autosave_indicator.sh`](../../tmux/scripts/autosave_indicator.sh) reads that
contested Continuum option locally. Its remote path reads the verified marker
instead, so local and remote indicators already mean different things.

The status line is also acting as the scheduler because Continuum invokes its
save script through a `#()` status command. Rendering the UI should not control
whether workspace state reaches disk.

### Codex forces frequent redraws

Codex 0.154.0 uses its default terminal-title configuration. The default title
contains spinner activity and the project name. It sends an OSC 0 title update
for every spinner frame.

Tmux has `allow-set-title on`. A pane-title change marks the window status as
dirty, so tmux redraws it. The status window list uses `#W`, not the pane title,
and `allow-rename` is off. This rules out Codex directly changing window names.

The status line has limited width on the attached 113-column client. When the
autosave chip changes from `0m` to a four-digit stale age, tmux's built-in
window-list clipping markers and the Catppuccin capsules cross their layout
threshold. The rapid Codex title updates make that reflow look like Codex is
toggling the icons.

OpenAI documents `tui.terminal_title` and permits a static value or `null`.
Codex's title implementation emits OSC 0 updates. Tmux documents pane titles as
separate from window names.

Sources:

- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Codex terminal-title implementation](https://github.com/openai/codex/blob/main/codex-rs/tui/src/terminal_title.rs)
- [Tmux advanced-use guide](https://github.com/tmux/tmux/wiki/Advanced-Use)
- [Tmux default status formats](https://github.com/tmux/tmux/blob/master/options-table.c)

## Other weak points

### Health checks can pass while saving is dead

[`doctor.sh`](../../tmux/local-plugins/tmux-workspace-resurrect/scripts/doctor.sh)
checks configuration strings and sidecar shape. It does not check the age of
the verified marker, the snapshot age, lock age, owner process age, Neovim RPC
health, or timestamp disagreement. It passed the timer and sidecar checks while
the save path had been blocked for two days.

Some checks are stale. The doctor expects the old remote-worker option and old
Claude and Pi paths, which produces unrelated failures and hides the useful
signal.

### Restore time grows badly with pane count

[`restore.sh`](../../tmux/local-plugins/tmux-workspace-resurrect/scripts/restore.sh)
waits serially for each pane's shell and bracketed-paste readiness. Each pane
can consume two five-second waits. A 47-pane workspace therefore has a worst
case near eight minutes. Historical logs show pane skips spaced about five
seconds apart.

### Successful saves are expensive

A healthy save took about 20 to 25 seconds for roughly 47 panes. The save loop
runs many separate tmux queries per field and pane. This is not the current
deadlock, but it increases overlap and makes a five-minute schedule less
forgiving.

### The current tmux release is behind

The machine runs tmux 3.7b and Homebrew offers 3.7c. The newer release contains
status and redraw fixes. It is worth installing after the local bugs are fixed,
but it cannot repair the hung RPC or timestamp race. A tmux server restart is
required after upgrading.

- [Tmux releases](https://github.com/tmux/tmux/releases)
- [Tmux changes](https://github.com/tmux/tmux/blob/master/CHANGES)

## Recommended repair order

1. Add a hard timeout around each Neovim RPC. Log and skip an editor that does
   not answer. Never let one socket retain the global save lock indefinitely.
2. Make Neovim pane registration owner-aware. Record the process and socket,
   reject embedded or nested editors, and clear the option only when the exiting
   process still owns it.
3. Use `.last-successful-save` as the only success clock. Keep any attempt time
   in a separate field.
4. Move local scheduling out of the status line. Use the existing launchd timer
   on the laptop and disable Continuum's status-driven scheduler.
5. Give the indicator a stable width so a value change cannot resize the center
   window list.
6. Set Codex `tui.terminal_title` to `["project"]` for a useful static title, or
   to `null` to stop title updates.
7. Extend the doctor to fail on stale snapshots, stale markers, old live locks,
   unhealthy registered sockets, and timestamp disagreement. Remove its stale
   path assertions.
8. Batch tmux reads during save and parallelize or bound restore readiness
   checks.
9. Upgrade tmux to 3.7c and restart the server after the functional fixes.

## Immediate recovery

The blocked process chain must be terminated before saving can resume. Its lock
can then be removed after confirming the recorded owner is gone. The unhealthy
Neovim registration should also be cleared or the responsible embedded editor
closed, otherwise the next save may block in the same place.

These recovery steps change live editor and tmux state. They were deliberately
left for the implementation pass rather than performed during read-only
triage.

## Verification required for the fix

- A fake Neovim socket that never answers cannot block a save beyond the chosen
  timeout.
- A failed save never changes the verified-success timestamp.
- The indicator reports the verified marker age for both local and remote
  sessions.
- Starting Codex does not change the width or clipping state of the window list.
- Nested Neovim cannot replace the foreground editor's registration.
- The doctor detects an old live lock and an old successful snapshot.
- Restore duration stays bounded when several panes never become ready.
