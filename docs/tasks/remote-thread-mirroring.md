# Remote thread mirroring and control

Status: design accepted; implementation has not started. Build it behind the `thread_mirroring.mode` flag and leave current `rw` behavior as the default until the prototype passes the validation phases below.

Related current-system documentation:

- `docs/tmux-remote-workspaces.md`: current `rw` ownership, transfer, endpoints, and handoff behavior.
- `docs/tmux-agent-sessions.md`: current Claude and Pi state classification.
- `docs/tasks/remote-owned-directories.md`: current root ownership and provider adapter contracts.

## Intent

Make an agent thread and its worktree available on both the laptop and the configured always-on authority, which is the `mini` worker today. A handoff changes which host controls the thread and resumes from the latest complete mirror. It does not copy the workspace synchronously.

The system must:

- keep working when the laptop is asleep or offline and the authority owns the thread;
- mirror uncommitted, staged, untracked, and conversation state without mirroring dependencies, build output, DerivedData, or caches;
- prevent two threads or hosts from writing the same thread or worktree;
- preserve the current `/remote-handoff to mini` and `/remote-handoff back` user actions;
- expose generic thread status and inspection interfaces that do not depend on Grok Bot or any other consumer;
- let consumers block for a status condition instead of polling in loops;
- support an optional opaque caller tag so an external agent driver can correlate a thread it started;
- tolerate the accepted loss windows rather than blocking a handoff for a final copy; and
- prove the new path in shadow mode before it controls any existing `rw` handoff.

`mini` is deployment configuration, not a code-level assumption. The design calls it the authority so another always-on worker can replace it later.

## Non-goals

- No dependency, build-output, DerivedData, or cache mirroring.
- No zero-loss guarantee after abrupt sleep, power loss, or network loss.
- No built-in Grok Bot routing, webhook client, ntfy client, or caller-tag interpretation.
- No per-thread executable hooks.
- No live polling or streaming of partial assistant output while a thread is Working.
- No replacement of provider transcript formats with a new conversation format.
- Lane 2, status-only synchronization without source and conversation mirroring, is dropped.

## Decisions

### D1 Mirror active, recent, and pinned work

A thread and its root stay in the hot mirror while the thread is active, was active within the configured retention window, or is explicitly pinned. The default recent window is 30 days.

`rw threads pin <id>` pins the thread, its conversation, and its associated root. `rw threads unpin <id>` restores automatic retention. A root remains pinned while any thread associated with it is pinned.

Never delete the authoritative working copy when pruning a mirror. Pruning removes only non-owner mirror generations and hot conversation material that can be recovered from the archive.

### D2 Lock the thread and the worktree

The authority owns the control records. Each thread has one controller and a monotonically increasing control epoch. Each worktree has one writer lock held by one thread. A host may write only when both its thread epoch and worktree lock are current.

A process validates its epoch before starting another agent turn. A turn already in progress may settle after temporary authority loss, but no new turn or ownership change starts until the authority is reachable. Control records do not expire into a second writer automatically.

### D3 Accept bounded, non-blocking loss windows

Conversation mirrors may be up to 10 seconds behind. Source mirrors may be up to 30 seconds behind. Mirroring, status publication, and hooks never block the agent loop.

A best-effort sleep notification may start one bounded mirror pass, but must not delay sleep. Reconciliation runs after wake. An abrupt loss may omit the last accepted window.

### D4 Archive conversations once, then maintain the hot set

Seed the existing Claude and Pi conversations into a neutral archive once. After seeding, continuously mirror only active, recent, and pinned threads. Provider-specific paths are rewritten only when materializing a conversation for resume on a host.

The initial archive is separate from the hot set and can be removed manually without changing thread control records. The system does not repeatedly copy unchanged historical conversations.

### D5 Preserve the handoff command surface

Keep `/remote-handoff to mini` and `/remote-handoff back`. With the prototype disabled they use current `rw` behavior. In control mode they request an epoch and lock transfer, then resume from the latest complete source and conversation generations.

The command returns after the authority accepts the request. Transfer and resume continue in the background. The destination starts only after the previous controller is quiescent and both locks transfer. It never waits for a final mirror pass. If no complete destination generation exists, the request fails instead of falling back to an inline workspace copy.

### D6 Use stable mirror-owned thread identity

Every managed thread has a stable UUID owned by the mirror. Claude and Pi session IDs are provider bindings, not the cross-host identity.

An optional caller tag is an opaque UTF-8 string stored in the neutral thread record. The core never treats it as a bot name, URL, command, topic, or credential.

Resume, handoff, mirroring, and `chat-move` preserve the thread ID and caller tag. A fork gets a new thread ID and clears the caller tag unless its creator explicitly supplies one. An imported existing thread has no caller tag unless one is supplied during import.

### D7 Keep the event journal authoritative and notifications generic

The authority keeps the durable status event journal. `rw threads watch` is the supported blocking interface, both as a continuous stream and as a one-shot wait for a status condition. One optional global `on-status` command can turn committed events into HTTP posts, ntfy publications, or another consumer-specific action.

Every consumer has two wake paths without a polling loop: keep a blocking watch process that returns when its condition is met, or receive a push from the global hook. The hook is a best-effort wake hint, not a second source of truth. Recovery always comes from the journal. There is no built-in webhook or ntfy delivery and no per-thread command.

### D8 Separate semantic thread status from tmux attention state

The canonical thread statuses are:

- `working`: an agent turn or its background work is active;
- `awaiting`: the completed assistant response requires human input; and
- `done`: a turn completed without an Awaiting indication.

Done is emitted regardless of pane visibility. The existing tmux `finished` versus `idle` behavior remains an attention-display concern and does not suppress or rewrite the canonical Done event. Focusing a pane creates no thread-status event.

Working events contain no assistant message. Awaiting and Done events contain only user-visible assistant text, capped at 64 KiB. A capped message sets `message_truncated` to true. Thinking, tool arguments, tool results, terminal control sequences, and internal metadata are excluded.

## Prototype flag and isolation

Add this configuration under `tmux/local-plugins/tmux-remote-workspaces/config.json`:

```json
{
  "thread_mirroring": {
    "mode": "off",
    "authority": "mini",
    "recent_days": 30,
    "on_status": null,
    "on_status_timeout_seconds": 5
  }
}
```

Modes:

- `off`: current `rw` behavior is unchanged. No mirror-v2 background work runs.
- `shadow`: build mirrors, thread records, the journal, and inspection commands in an isolated state namespace. Existing handoff commands still use current internals.
- `control`: handoff commands use epochs, locks, and complete mirror generations.

Use a separate `thread-mirror-v2` state namespace during the prototype. Shadow mode must not mutate current ownership records, provider stores, panes, or handoff behavior. Moving from `control` back to `shadow` or `off` requires first materializing the latest owner state through an explicit safe rollback; it must never silently expose a stale copy.

## Mirror model

### Source generations

Only the current worktree owner publishes source generations. Extend the existing Git-aware transfer so each generation contains committed, staged, unstaged, untracked, and required Git administrative state. Include ignored source and environment files unless they match a hard exclusion.

Hard exclusions include:

- dependency directories such as `node_modules`, Pods, and virtual environments;
- build outputs such as `build`, `dist`, `.next`, and `target`;
- Xcode DerivedData;
- tool and worktree caches; and
- `rw` backup, staging, and prior mirror-generation directories.

Build into staging on the destination, validate it, and atomically promote a complete generation. A half-written worktree or `.git` state must never become resumable. Dependencies and generated artifacts are rebuilt on the controlling host.

Reconcile an active root at least every 30 seconds and after an idle file-change burst. A generation records its source host, thread epoch, root identity, creation time, and content fingerprint.

### Conversation generations

Snapshot active Claude and Pi conversations through their provider adapters at least every 10 seconds. Store neutral archive metadata separately from the provider files. Materialize a host-specific provider session only during resume, applying the existing home, project-slug, and cwd rewrites.

A conversation generation records the mirror thread ID, provider binding, source host, control epoch, creation time, and content fingerprint. Promotion is atomic. A generation from an old epoch may be retained for diagnosis but cannot become the current resumable generation.

### Tiny control state

Publish control and mirror metadata on change, with a periodic 60-second reconciliation. At minimum a thread record contains:

- stable thread ID and optional caller tag;
- provider and host-specific provider bindings;
- home-relative root identity;
- controller, control epoch, and worktree-lock identity;
- latest complete source and conversation generations;
- canonical status and status sequence;
- last activity time and pin state; and
- pending handoff or recovery error, when present.

State directories and files are private to the user. Conversations, environment files, and event messages may contain secrets.

## Status publication and journal

Use the same provider lifecycle signals that currently publish tmux agent state. Do not scrape the terminal or poll tmux options for status transitions.

- Claude: derive Working from prompt/turn start and in-flight work, Awaiting from the existing exact final marker or an explicit question prompt, and Done from `Stop` with no Awaiting marker.
- Pi: derive Working from `agent_start` and held background work, Awaiting from the existing marker or UI prompt, and Done from `agent_settled` with no Awaiting marker.

Only the host holding the current thread epoch may publish. A laptop-side publisher first records an event in a private local spool and sends it to the authority asynchronously. The authority rejects stale epochs and deduplicates replayed event IDs. Authority-local events use the same ingestion path without SSH.

The journal is append-only and ordered by an authority-assigned sequence. Each status event contains:

```json
{
  "event_id": "uuid",
  "sequence": 42,
  "thread_id": "uuid",
  "thread_status_sequence": 7,
  "occurred_at": "RFC3339 timestamp",
  "committed_at": "RFC3339 timestamp",
  "host": "configured host alias",
  "control_epoch": 3,
  "provider": "claude|pi",
  "root": "home-relative path",
  "caller_tag": "opaque string or null",
  "status": "working|awaiting|done",
  "message": "string or null",
  "message_truncated": false
}
```

`message` is null for Working. Events are ordered globally by `sequence` and within a thread by `thread_status_sequence`. Delivery is at least once across a watch reconnect, so consumers deduplicate by `event_id`. Re-ingesting the same event does not append it or run the hook again.

Retain journal events for at least the configured recent window. If a streaming watch requests an expired cursor, it reports a cursor-expired record followed by the current matching thread snapshots before continuing with live events. A one-shot watch with an expired `--after` cursor exits non-zero with one machine-readable cursor-expired object; the consumer can then restart without `--after` to atomically check the current state and wait.

## Thread CLI

### `rw threads watch`

```text
rw threads watch [<id>] [--after <sequence>]
                 [--caller-tag <opaque-string>] [--status <status>]
rw threads watch <id> --until <status>[,<status>...] [--after <sequence>]
```

Without `--until`, the command emits newline-delimited JSON and remains blocked for new committed events. With `--until`, it is a blocking one-shot: it exits successfully after writing the single event JSON object whose status first matches the requested set. For example, `rw threads watch <id> --until awaiting,done` can run as a background SSH process and return the moment the thread needs input or finishes.

A one-shot watch checks the thread's current committed status and establishes its journal position as one atomic authority operation, so an event cannot land between the check and the wait. If the current status already matches, it returns that status's latest event immediately. Supplying `--after` asks for the first matching event newer than that sequence instead, which lets a consumer wait for a later turn rather than receive the current state.

The command runs directly on the authority. A laptop invocation transparently connects to the configured authority, while a remote consumer can run it through its own outbound SSH connection. The authority does not require inbound SSH access to the consumer.

A streaming consumer persists the last processed sequence, reconnects with `--after`, and deduplicates by `event_id`. A one-shot consumer may be supervised and restarted after an SSH failure with the same cursor. Neither mode requires a timed polling loop.

### `rw threads show`

```text
rw threads show <id> [--json]
```

This is an on-demand read, not a background poll. For a Working thread, query the current controller once and ask its provider adapter for the latest user-visible assistant text. Prefer the transcript tail. If the provider has not persisted usable partial text, use a one-time pane capture only when the adapter can isolate the assistant response region confidently. Never return thinking, tool payloads, prompts, or unrelated pane content.

For Awaiting or Done, use the latest committed event message unless a newer provider transcript is available. Apply the same 64 KiB cap and truncated flag.

JSON output includes `thread_id`, `status`, `message`, `message_truncated`, `source` (`transcript`, `pane`, or `journal`), `observed_at`, and `fresh`. If the controller is unreachable, return the latest committed journal text with `fresh: false`; fail only when no safe text is available.

### Pinning

```text
rw threads pin <id>
rw threads unpin <id>
```

These commands change retention only. They do not take control or start an agent.

### Remote thread creation

Reserve this interface for the final phase:

```text
rw threads start --worker <alias> --root <path> \
  --provider claude|pi [--caller-tag <opaque-string>] --prompt-file -
```

The command authenticates through the existing SSH boundary, resolves the root by the normal home-relative mapping, creates the stable thread record, acquires the thread and worktree locks, starts the provider through its adapter, and writes the initial prompt from stdin. It prints the stable mirror thread ID. The caller tag is data only and cannot choose a hook or executable command.

## Global `on-status` hook

Configure at most one authority-local command as an argv array, not a shell expression. After a new status event is committed, invoke the command asynchronously with the event JSON on stdin and a closed inherited stdin after that payload. Do not interpolate event fields into a shell command or environment variable.

The hook receives every Working, Awaiting, and Done event and decides what to ignore or where to send it. This lets one owner-managed command route by caller tag, fan out to an accountability service, run `curl`, or publish to ntfy without putting those products into `rw`.

Apply the configured timeout, kill the hook process group on expiry, and record exit status or timeout in a private log. Run it once. Do not retry, delay later journal commits, or mark the thread operation failed. A consumer that needs recovery reconnects through a streaming or one-shot `rw threads watch`; it does not need to poll.

This behavior works while the laptop is offline because the authority owns both the journal and hook. If an event originated on an offline laptop and has not reached the authority, no authority-side wake can occur until connectivity returns.

## Handoff sequence

In control mode, a handoff does the following:

1. Resolve the stable thread and root through the authority.
2. Record a pending transfer and verify that a complete destination source and conversation generation exist.
3. Quiesce the current controller at a turn boundary. Refuse or leave the request pending rather than allowing concurrent writers.
4. Atomically increment the thread epoch and transfer both the thread controller and worktree writer lock.
5. Materialize the selected complete generations on the destination.
6. Resume the provider session through the existing adapter and publish subsequent status under the new epoch.
7. Reconcile any later-arriving old-epoch mirror or status records without promoting them.

The user command returns after step 2 is accepted. Steps 3 through 7 run in the background. A failure leaves one explicit owner and a diagnosable pending/error record; it never falls back to two writable copies.

## Failure behavior

- **Authority unreachable:** no new turn, handoff, lock acquisition, pin change, or remote thread start. Existing state remains readable.
- **Destination mirror stale within the accepted window:** resume it. This is the chosen non-blocking tradeoff.
- **No complete destination generation:** fail the handoff request without inline copying.
- **Interrupted mirror:** keep the previous complete generation; discard or diagnose staging data.
- **Stale controller:** reject status and mirror promotion with its old epoch. Do not delete the payload until reconciliation records the rejection.
- **SSH watch disconnect:** the consumer restarts its blocking stream or one-shot wait after its last sequence and may receive duplicates.
- **Hook failure:** log it and continue. The journal remains available.
- **Pane capture ambiguity:** return transcript or journal text, or report no safe text. Do not return the raw pane indiscriminately.
- **Disk growth:** prune only eligible non-owner hot generations. Never prune pins or the only complete resumable generation.

## Phases and proof

### P0 Flag, records, and isolated tests

Add the three modes, isolated v2 state paths, schemas, authority resolution, event IDs, and thread/worktree lock primitives. Keep the default `off`.

Proof:

- tests use sandbox homes, fake SSH, fake providers, and no live tmux server;
- stale epochs and duplicate events are rejected deterministically;
- two threads cannot acquire the same worktree writer lock; and
- `off` produces no v2 files, processes, or command-path changes.

### P1 Status prototype in shadow mode

Build stable thread IDs, provider status publication, the authority journal, `watch`, `show`, pinning, and the global hook. Do not change handoff internals.

Proof:

- Claude and Pi each produce Working, Awaiting, and Done in order;
- visible and hidden completed panes both produce Done;
- Working has no message, while Awaiting and Done contain only capped user-visible text;
- streaming watch reconnect resumes by sequence and handles an expired cursor;
- one-shot watch returns immediately for an already-matching state, blocks without polling otherwise, and cannot miss a transition between its state check and wait;
- hook timeout or failure never delays the agent or journal;
- a duplicate event neither appends nor invokes the hook twice; and
- `show` identifies its source and marks stale fallback honestly.

### P2 Mirror prototype in shadow mode

Seed the one-time neutral conversation archive. Build hot conversation snapshots, source generations, exclusions, atomic promotion, retention, and pins. Observe current active threads without taking control.

Proof:

- a throwaway worktree round-trips committed, staged, unstaged, untracked, ignored source, and environment files;
- dependencies, outputs, DerivedData, caches, and v2 staging are absent;
- killing a mirror mid-write leaves the previous complete generation resumable;
- Claude and Pi materialize on the other host with correct cwd and provider paths;
- measured shadow lag meets the 10-second conversation and 30-second source windows under normal connectivity;
- sleep, wake, SSH loss, authority reboot, and laptop-offline drills reconcile without split brain; and
- retention removes only eligible mirror data while pins survive.

### P3 Opt-in control

Enable `control` only for throwaway threads and roots. Switch the existing `/remote-handoff` internals under the flag, preserving its user-facing commands.

Proof:

- handoff in both directions resumes the same stable thread from complete generations;
- the command returns without a synchronous copy;
- old-epoch processes cannot publish or start another turn;
- thread and worktree contention is refused cleanly;
- failures leave exactly one recorded owner; and
- the safe rollback procedure restores the latest owner before disabling control.

### P4 Remote creation and consumer trial

Build `rw threads start`. Configure a test global hook that sends an HTTP POST, then replace it with an ntfy command without changing `rw`. Exercise both a persistent outbound SSH stream and `rw threads watch <id> --until awaiting,done` as a blocking one-shot.

Proof:

- a remote caller starts a tagged Claude or Pi thread and receives its stable ID;
- the tag survives resume and handoff, while a fork clears it by default;
- the HTTP and ntfy trials wake their consumers while the laptop is off;
- removing the hook leaves thread management, streaming and one-shot watches, and mirroring functional; and
- no consumer can turn a caller tag into authority-side code execution.

### P5 Soak and cutover decision

Run shadow and opt-in control long enough to cover laptop sleep/wake, authority restart, provider compaction/resume, network interruption, and retention. Record loss-window observations, disk growth, hook failures, and recovery outcomes.

Only after P0 through P4 pass and the soak has no unresolved ownership or generation-integrity failure may a separate reviewed change make `control` the default. Do not remove the legacy path as part of this prototype.

## Rejected designs

- **Built-in webhooks:** require URL routing, authentication, secrets, retry policy, and HTTP-specific failure handling that the global hook can supply outside the core.
- **Built-in ntfy:** adds a broker and topic/credential policy; use an `on-status` command instead.
- **Per-thread hooks:** add lifecycle and code-execution risk. Caller-provided metadata must remain data.
- **Direct journal-file consumers:** couple consumers to storage and rotation. Use `rw threads watch`.
- **Partial-response polling:** adds continuous provider-specific work for a display need served by `rw threads show` on demand.
- **Syncthing or Mutagen:** neither solves linked-worktree Git state or host-specific provider paths, and each adds another coordinator.
- **Git push as the mirror:** omits staged, unstaged, untracked, ignored, and live conversation state.
- **Blocking final flush:** contradicts the accepted handoff behavior and still cannot guarantee zero loss after abrupt disconnection.
