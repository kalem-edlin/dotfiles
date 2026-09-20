# Tmux workspace resurrection investigation

Status: reopened September 17, 2026. The earlier fixes did not establish reliable operation under load.

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
