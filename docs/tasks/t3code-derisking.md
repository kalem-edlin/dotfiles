# T3 Code as a source of de-risked agentic management practice

Status: research, 2026-11-18. Nothing is built or decided. This file holds the
user's intent verbatim, the per-area findings with the T3 Code files that
implement each mechanism, and a verdict for each (adopt, mutate, skip) against
the dotfiles' tmux-only model. The recommended order is in "Adoption order".

Source: `github.com/pingdotgg/t3code` at commit 052ca497 (upstream date
2026-11-19), read-only. T3 paths below are relative to that checkout. Dotfiles
paths are relative to this repo.

Related system docs (current behaviour, not plans):

- `docs/tmux-agent-sessions.md` (the picker, agent state publishing)
- `docs/tmux-remote-workspaces.md` (rw: directory handoff to workers)
- `docs/tasks/remote-owned-directories.md` (remote-owned directories, built 2026-11-18)
- `docs/tasks/worktree-native-tmux.md` (`wt`, worktree-per-session)
- `docs/tasks/tmux-workspace-resurrection.md` (save/restore)
- `docs/focus-agents.md` and `docs/tasks/pif-web-research.md` (pif `delegate`)

## User intent (verbatim, 2026-11-18)

> It ranges from features of worktree management, remote handoffs, remote spinups, repo management, agentic thread management, working status, things like host names and stuff like that. We do similar things, right, where we copy ENV files across remote and whatnot but it's all about how our dot files and our tmux workspace are agentically leveraging.
> I think they also have an account rotation system as well. We could do something similar like that but our UI potential is less fruitful because we don't have the whole user interface. We only really have the picker to work with that we use, as well as the tmux status line itself, and then whatever runs within the CLI.
> I'm a big fan of CLI programs and spinning up panes and using tmux to get notepads spun up so I can: take notes, write about things, copy and paste between each other, reference photos, all that kind of stuff, search files by name. It's always quite good, right?
> This is our approach: my own dot files, personal dot files, to manage my tmux-based workspaces. Whenever I need it to change, I change it, right? It's my software, it's personal software, it's how I like to work.
> There are things that we can take inspiration from in this codebase. I need you to do some research with the subagents: look into it, figure out what is worth deriving into our solutions, come back with lists of files per solution that we could adopt or mutate into our own solution within our dot files.
> The whole tmux process or tmux coordination system, including: the remote stuff, the resurrection stuff, the handoffs, the agentic status updates, the work tree isolation or management threads, seeing how we can manage different initiatives at once, all that kind of stuff.
> Any value that this codebase presents should be picked up on and presented to me as something that either can or cannot be, or should or should not be, integrated into our own dotfile solutions for these kinds of concepts. This codebase is already de-risked a lot of them.
> We can look at this T3 code solution as a source of de-risked agentic management practices that the industry is using and validating as valuable for engineering, AI-based engineering, right now. There's definitely value in this.

## Shape of T3 Code, for orientation

T3 Code is a long-lived local server (`apps/server`, Effect-based TypeScript,
SQLite event store) that spawns agent CLIs (Claude Code, Codex, Pi, ...) and
serves desktop, web and phone clients. Threads live on the host where they
started; clients reconnect to hosts. There is no equivalent of rw's directory
handoff between machines. The reusable value is in the rules and edge cases,
not the transport or UI. Where a rule has a dedicated test file, it is named,
since that is the de-risking evidence.

## Findings by area

### F1. Worktrees, repo management, git workflow

What the dotfiles have: `wt new|status|rm|repurpose|ports|env-refresh`
(`git/.local/bin/wt`), central worktree folder, APFS-clone of `.env*` from the
main checkout with a per-worktree `.env.ports` block, session named after the
directory, picker keys `c C x D e E`, delete moves to Trash with a dirty
warning.

1. Local-change detection before delete. ADOPT. T3's `localChangesReason`
   parses `git status --porcelain=v1 -z`, then also catches changes hidden
   from status: `ls-files -v` flags (assume-unchanged `h`, skip-worktree `S`)
   and a re-hash of on-disk content against the index. Three keep levels
   (tracked edits; plus untracked; plus ignored), and the docs warn that the
   default would delete ignored `.env` files. Output is bounded with an
   explicit "exceeds inspection limit" refusal. Branches survive deletion.
   Files: `apps/server/src/storageCleanup.ts` (~L740-900),
   `apps/server/src/vcs/worktreeRemoval.ts`,
   `apps/server/src/workspace/restoreMissingWorktree.ts`,
   `docs/user/project-settings.md` ("Storage cleanup").
   Gain: the `D` key warning covers hidden changes and lists ignored files
   that would be lost (`.env.local`, local DBs).

2. Fresh base, pre-flight and cleanup on failure in worktree creation.
   ADOPT. Base is a freshly fetched `origin/<default>` SHA, with fallback to
   the default branch if the requested base is gone. Pre-flight errors in a
   fixed order: no repo, no base commit, branch exists, ref-prefix conflict
   (`a` vs `a/b`). The created path and branch are recorded and removed on
   failure or cancel. `git worktree add --lock --reason <token>` marks a
   half-built worktree.
   Files: `apps/server/src/orchestration-v2/ThreadLaunchService.ts`
   (`checkWorktreeBase`, `worktreeFallbackBase`, ~L370-540, L640-720),
   `apps/server/src/git/remoteRefs.ts`,
   `packages/shared/src/git.ts` (`sanitizeBranchFragment`,
   `resolveAutoFeatureBranchName`).
   Gain: no orphaned worktree after a failed `wt new`, no stale base.

3. Auto-pull of the default branch, fast-forward only. ADOPT. Five guards
   (is a repo, on default branch, has upstream, clean, zero ahead), each skip
   logged with a reason, failure is a warning. Tested.
   Files: `apps/server/src/serverRuntimeStartup.ts` (`autoPullProjects`,
   ~L188-245), `apps/server/src/serverRuntimeStartup.autoPull.test.ts`.
   Gain: `wt new` and `C-a e` env refresh read from a current main checkout.

4. Policy-driven cleanup, "wt prune". MUTATE. T3 sweeps for worktrees whose
   PR merged (commits in remote default, or squash: PR targeted default and
   worktree still at PR head), or no commits beyond default, with guards
   (active session, shared, dirty, grace period, re-check before delete) and
   a per-worktree reason in the report. Unmanaged folders are listed with
   sizes and never auto-deleted.
   Files: `apps/server/src/storageCleanup.ts` (~L99-320, L1187-1540),
   `apps/server/src/orchestration-v2/ThreadSettlementService.ts`,
   `apps/server/src/orchestration-v2/PullRequestSyncReactor.ts`.
   tmux shape: `wt prune` prints candidates (merged via `gh pr view`, or
   `git cherry` empty, clean, no live session) with reasons; the picker can
   pre-select them. No timer.

5. Managed-path predicate. MUTATE (small). Destructive actions run only on a
   path exactly `root/repo/leaf` under a managed worktree root, after symlink
   resolution. Old roots are kept in `previousWorktreesDirectories`.
   Files: `apps/server/src/worktreesDirectory.ts`,
   `apps/server/src/workspace/KnownWorkspaces.ts`.
   Gain: `wt rm` and `D` refuse anything outside the worktree root.

6. Setup hook with marker files. MUTATE. `runOnWorktreeCreate` runs with
   `T3CODE_PROJECT_ROOT`/`T3CODE_WORKTREE_PATH`; the example script writes
   `.t3/setup-running|setup-done|setup-failed` so agents wait instead of
   racing an install.
   Files: `apps/server/src/project/ProjectSetupScriptRunner.ts`,
   `apps/server/src/project/WorktreeSetupTracker.ts`,
   `packages/shared/src/projectScripts.ts`, `scripts/setup-worktree.ts`,
   `t3.json`.
   tmux shape: a per-repo `setup` hook run by `wt new` as a plain subprocess,
   `.wt/setup-*` markers with PID, exit trap. Skip the multi-shell sentinel.
   Note: T3's example symlinks `.env` files. Keep the dotfiles' copy, since
   `.env.local` is rewritten per worktree for ports (worktree-native D-rules).

7. Temporary branch then model-named rename. MUTATE, optional. Worktree
   starts on `t3/<8hex>`; after the first prompt a cheap model names it and
   `git branch -m` runs (20 s timeout); nested-ref collisions flattened.
   Files: `apps/server/src/orchestration-v2/ThreadLaunchService.ts`
   (~L569-960), `packages/shared/src/git.ts`,
   `apps/server/src/orchestration-v2/WorktreeBranchSync.ts`.
   tmux shape: `wt new` with no name uses `wip/<8hex>`; a pif first-prompt
   hook renames branch and session. Only if naming friction is real.

8. Per-turn checkpoints as hidden refs. MUTATE, later. Temp `GIT_INDEX_FILE`,
   `write-tree`/`commit-tree`, ref under a private namespace, restore with
   `git restore --source --worktree --staged`; refused when another agent
   shares the worktree.
   Files: `apps/server/src/checkpointing/CheckpointStore.ts`,
   `apps/server/src/vcs/GitVcsDriver.ts` (~L1088, L1810),
   `apps/server/src/orchestration-v2/CheckpointRestoreSafety.ts`,
   `apps/server/src/workspace/workspaceLease.ts`.
   Gain: undo for a bad pif turn without touching the real index. Claude Code
   has its own rewind; pif has none.

9. PR flow. MUTATE (two commands), SKIP the multi-forge layer and review UI.
   `wt pr <n>`: fetch `refs/pull/N/head` into a worktree, verify SHA against
   `gh pr view`, refuse if branch checked out elsewhere, never hard-reset an
   unpublished head. `wt ship`: feature branch if on default, commit, push,
   `gh pr create` with a model-written message.
   Files: `apps/server/src/git/GitManager.ts` (`runStackedAction` L3486,
   `preparePullRequestThread` ~L3040-3430),
   `apps/server/src/git/linkCreatedPullRequest.ts`,
   `apps/server/src/git/refreshPushedPullRequests.ts`.

10. Project registry, scratch projects, transcript import. SKIP. The
    filesystem under `~/Developer` is the registry. One idea: group picker
    rows by `git rev-parse --git-common-dir` so sibling worktrees sit
    together regardless of folder names.
    Files: `apps/server/src/project/RepositoryIdentityResolver.ts`.

SKIP outright: SnapShots, fast checkout cache (`vcs/worktreeCheckoutCache.ts`),
sparse/submodule setup UI.

### F2. Agent working status, attention, notifications

What the dotfiles have: hooks and the pif extension publish `@agent_*` pane
options (`working`, `awaiting`, `finished`, `idle`, remote `disconnected`);
Done becomes Idle on focus; subagent counts; the picker reads options only;
the status line shows memory, autosave and host chips but no agent state; no
OS notifications. Known rough edges: background dev server holds Working,
Esc leaves Working ~60 s, a question without the marker shows Done.

11. Attention ladder and "awaited work holds Done". MUTATE. One status from
    many fields, in priority: approval > input (a child's question bubbles to
    the parent) > guest > waiting-on-child > preparing > working > idle >
    failed/limited > ready. Unseen completion = `completedAt > lastVisitedAt`;
    a Failed pill clears on visit. Background work holds Done only if the
    agent marked it awaited; dev servers do not. 49 tests.
    Files: `apps/web/src/components/Sidebar.logic.ts`
    (`resolveSidebarThreadStatus`, `hasUnseenCompletion`,
    `resolveSidebarFolderDot`), `Sidebar.logic.test.ts`,
    `packages/shared/src/orchestrationV2PendingBackgroundWork.ts`,
    `packages/shared/src/agentAwareness.ts`,
    `packages/client-runtime/src/state/threadInbox.ts`.
    Gain: fixes "dev server keeps agent Working" (only awaited work counts),
    adds Failed and Limited states, and gives the picker a per-session chip
    equal to the most urgent hidden state.

12. Agent-declared await. MUTATE. `t3_background_wait <ids>` tells the
    server to keep a thread Working past the run's end; `waiting=false`
    clears it.
    Files: `apps/server/src/mcp/toolkits/orchestrator/tools.ts`
    (`BackgroundWaitTool`),
    `apps/server/src/orchestration-v2/BackgroundWorkStop.integration.test.ts`.
    tmux shape: `await-bg <n>` sets `@awaited`; the Stop hook writes Working
    while it is non-zero. Replace the `ps` scan with this flag.

13. Working-exit grace and "returned to you" ordering. MUTATE. 2 s grace
    before Working drops (skipped if the run ended >60 s ago). The list sorts
    by when a thread last came back to you, not by activity, so rows do not
    jump.
    Files: `packages/client-runtime/src/state/threadInbox.ts`
    (`createInboxReturnTracker`, `sortInboxThreadsByReturn`),
    `threadInbox.test.ts`.
    Gain: no Working/Done flicker across a Stop hook and a delegate steer;
    stable picker order.

14. Notification gate. MUTATE. Pure state machine: never on first sighting,
    input alerts keyed `status:requestId`, silenced when snoozed/settled, 5 s
    hold before a completion that follows a background wake, child input
    raises the parent. 11 tests.
    Files: `apps/web/src/components/ThreadNotificationCoordinator.logic.ts`,
    `ThreadNotificationCoordinator.logic.test.ts`,
    `apps/server/src/relay/AgentAwarenessRelay.ts`.
    tmux shape: a script behind the state hook with
    `~/.local/state/.../notified.json`, firing `tmux display-message` or a
    macOS notification. Skip push and Live Activities.

15. Title generation. ADOPT the prompts and context budget. 3-8 words,
    <40 chars, subject and outcome, no project/model/branch names, no
    completion claims; 8k chars total, 2k per message, first user message
    always included; a `requestId` discards stale results; regenerate keeps
    the old title if still accurate.
    Files: `packages/provider-core/src/server/textGenerationPrompts.ts`,
    `packages/provider-core/src/server/threadTitleContext.ts`,
    `apps/server/src/orchestration-v2/ThreadTitleRegenerationService.ts`,
    `apps/server/src/orchestration-v2/placeholderThreadTitle.ts`.
    Gain: pif's auto-titler and the picker label use proven rules.

### F3. Delegation and agent-to-agent control

What the dotfiles have: pif `delegate` (background child, steer report,
`delegate_continue`, `delegate_stop`, one-hour cap, members from
`agents/subagents/`), no persistence of delegate state, no batching, no
child-question forwarding, no stop cascade beyond one level.

16. Delegated completion delivery. MUTATE. Per-parent-run cohort mailbox:
    delivery state `pending > claimed > acknowledged > delivered > disposed`,
    deterministic message id (idempotent across restart), sibling completions
    batched into one message, inline results capped at 16,000 bytes with a
    `task_status <id>` pointer, `completionWake` `always|settled_only`. A
    child's `user_input` question wakes the parent (steer mid-turn, queue
    otherwise) and is cancelled if answered first. Parent Stop cascades
    depth-first, drops owed wakes, refuses new delegation. Child permissions
    may only narrow. ~5,500 lines of tests.
    Files: `apps/server/src/orchestration-v2/Orchestrator.ts`
    (`acceptDelegatedCompletionDelivery`, `offerDelegatedCompletionDelivery`),
    `DelegatedTaskQuestionReactor.ts`, `QueuedRunOrder.ts`,
    `NotificationMailbox.ts`, `DelegatedCompletionDelivery.test.ts`,
    `ThreadStop.test.ts`, `apps/server/src/mcp/toolkits/orchestrator/tools.ts`.
    Gains for `delegate.ts`: persist delegate state per parent session;
    batch simultaneous finishes into one steer; cap inline report with a
    `delegate_status` pointer (today the cap is 24,000 chars with
    truncation); forward a child's Awaiting to the parent; make
    `delegate_stop` cascade; refuse tool-set widening in member profiles.
    This also feeds the content-engine harness A12, which builds from
    dotfiles.

17. Budgeted context handoff and lineage. MUTATE. A handoff is a selection
    of real messages, not a summary: budget `min(16k tokens, 64k bytes,
    window - used - input - reserve)`, tokens counted 1 per UTF-8 byte,
    original request plus recent turns kept, omitted ids recorded for later
    retrieval; built lazily on first send; ambiguous delivery forces fresh.
    18 tests.
    Files: `packages/provider-core/src/server/handoffBudget.ts`,
    `apps/server/src/orchestration-v2/ContextHandoffService.ts`,
    `ContextHandoffDelivery.ts`, `ContextHandoffBudget.test.ts`,
    `docs/orchestration-v2/thread-lineage-and-context-transfer.md`,
    `docs/user/portable-handoffs.md`.
    tmux shape: `/new-worktree` and `/remote-handoff` emit a handoff file
    (first message, last N turns, transcript path) sized by the formula; a
    `parent_session` field in the session sidecar lets the picker nest forks
    and delegates. Skip native-fork resolution.

18. Orchestrator tools and the thread CLI. MUTATE. `t3_thread_list|read|
    send|wait|interrupt`, `delegate_task`, `task_status`, `task_cancel`;
    `send` modes `auto|queue|steer|restart`; `wait` timeout never cancels;
    reads paged at ~30k chars; `clientRequestId` idempotency; no privilege
    escalation; instructions say "follow `next`, never poll". CLI
    `t3 thread start|send|show|list --wait` exits 1 on failure, 2 when the
    agent awaits input.
    Files: `docs/orchestration-v2/orchestrator-mcp-server.md`,
    `docs/user/outside-agents.md`,
    `apps/server/src/mcp/toolkits/thread/tools.ts`,
    `packages/provider-core/src/server/orchestrationInstructions.ts`,
    `apps/server/src/cli/thread.ts`.
    tmux shape: a `thr list|read|send|wait` script over pane options and
    session files, exposed to pif as a tool and to Claude as a skill. Copy
    the exit-code contract and the instruction text.

19. Idle compaction before cache expiry. SKIP for now. Needs `send-keys` of
    `/compact` into a pane. Reuse its exclusion list if Claude Code ever
    exposes cache expiry.
    Files: `apps/server/src/orchestration-v2/IdleCompaction.ts`.

### F4. Remote access, host identity, workers

What the dotfiles have: rw hands a directory root to a worker over ssh with
ControlMaster and Tailscale, rsync relative to `$HOME`, attach loop with
bounded backoff, `remote` label (never a hostname), host chip by hostname
colour, 2 s remote-state mirror. Known: laptop `HostName` unpinned causes
`mac` vs `kalems-macbook-pro` flips and claim exit-11 storms.

20. Stable host identity. ADOPT (small). UUID written once with a hard-link
    publish (race-safe), label from `scutil --get ComputerName` then
    `hostnamectl --pretty` then hostname, every probe with a 5 s timeout;
    machine kind from `ioreg` (mac-mini, laptop, studio) or DMI/VM markers.
    Files: `apps/server/src/environment/ServerEnvironment.ts`,
    `ServerEnvironmentLabel.ts`, `ServerEnvironmentMachine.ts`, and their
    tests.
    Gain: rw and the host chip key on an id file, so a hostname flip is
    detected rather than mistaken for a different host.

21. Connection supervisor policy. MUTATE. Ordered routes (loopback, LAN,
    tailnet, public), probe earlier routes every 60 s and on network change
    or resume, 5 min cooldown for a route that probed well then failed,
    never-answering routes checked half as often up to 30 min, backoff 1 s
    to 5 min reset after 30 s stable, 2.5 s silence = dead, 1.5 s probe after
    long suspend, a bare IP is not trusted to be the same host after a
    network change.
    Files: `packages/client-runtime/src/connection/supervisor.ts`,
    `routes.ts`, `wakeups.ts`, `connectivity.ts`, `supervisor.test.ts`.
    Gain: rw attach loop and resurrect reconnects get tested constants and
    wake-from-sleep handling.

22. ssh hygiene and remote lock. MUTATE. Every ssh call sets `BatchMode`,
    `ConnectTimeout=10`, `RemoteCommand=none`, `RequestTTY=no`,
    `ServerAliveInterval=15`, `ServerAliveCountMax=3`; script piped through
    the login shell so PATH matches; remote `.launch.lock` with pid,
    stale detection by `kill -0`, trap releases on HUP/INT/PIPE/TERM; output
    parsed from the last non-empty line; failures classified
    `host_key_unknown|host_key_changed|auth|resolve|connect`; worker log tail
    fetched on failure. 1,762-line test file.
    Files: `packages/ssh/src/command.ts`, `tunnel.ts`, `errors.ts`,
    `tunnel.test.ts`.
    Gain: rw handoffs fail with a named cause; two laptops cannot hand off
    the same root at once (prepares R2).

23. Tailscale preflight. ADOPT into `rw doctor`. `tailscale status --json`
    for Running, MagicDNS name, exit-node set (T3's docs cite an exit node
    as the cause of an outage); sshd listening check; never log raw
    tailscale stderr (can contain keys); `100.64/10` is Tailscale only if
    confirmed (WARP shares it).
    Files: `packages/tailscale/src/tailscale.ts`, `tailscale.test.ts`,
    `apps/server/src/environment/DirectEndpoints.ts`, `RemoteOpenTargets.ts`.

24. Hop-list diagnosis. MUTATE into `rw status <host>`. Ordered hops each
    marked ok, FAILED or not checked, plus a copyable text block; host
    reports a recent event-loop stall via load average.
    Files: `packages/client-runtime/src/connection/diagnosis.ts`,
    `hostFreeze.ts`, `apps/server/src/cloud/ConnectReachability.ts`,
    `docs/user/t3-connect-troubleshooting.md`.

25. Keep-awake and OOM protection on workers. ADOPT. `caffeinate -i -w <pid>`
    (macOS) or `systemd-inhibit` held only while a run is active, 60 s grace
    between runs, handshake line once held, retry with backoff capped at
    10 min, inhibitor dies with its owner. Linux `t3 service protect` writes
    `OOMScoreAdjust=-900` drop-ins for the server, sshd and tailscaled.
    Files: `apps/server/src/background/KeepAwake.ts`, `KeepAwake.test.ts`,
    `HostPowerMonitor.ts`, `BackgroundPolicy.ts`,
    `apps/server/src/cloud/serviceProtection.ts`,
    `docs/user/background-service.md`.
    Gain: a worker never sleeps under a long agent turn; ssh survives memory
    pressure on Linux workers (R3). Note `caffeinate -i` does not block
    lid-close sleep.

26. Stale-while-revalidate for status. ADOPT as a pattern. One cached entry,
    concurrent first callers share one scan, expired value returned at once
    while one bounded refresh runs, failed refresh keeps the old value.
    Files: `apps/server/src/environment/staleWhileRevalidate.ts` and test.
    Gain: a status-line remote chip that never blocks on ssh.

27. Secrets as references. MUTATE, not now. `op://` references resolved on
    the host with `op inject --cache=false`, 45 s timeout, no fallback after
    timeout, failed read never overwrites cached value, on-disk secrets
    0600 with 24 h TTL sweep, `service.env` literal (no expansion).
    Files: `packages/secret-provider-onepassword/src/server/driver.ts`,
    `packages/secret-provider-core/src/server/SecretResolver.ts`,
    `apps/server/src/secrets/SecretRequests.ts`, `docs/user/secrets.md`.
    Position: the dotfiles chose "same machine, keys shared" and rsync of
    env files. Revisit only if env drift between laptop and worker becomes
    a problem.

28. Cross-machine delegation and auto-balance. SKIP. rw's directory
    ownership is simpler and stronger. One idea: `rw run <host> -- cmd` that
    notifies the originating pane on completion.
    Files: `apps/server/src/orchestration-v2/RemoteDelegatedTask.test.ts`,
    `docs/user/remote-access.md`.

### F5. Resurrection and restart recovery

What the dotfiles have: tmux-resurrect plus the local plugin save layout,
agent session ids, Neovim state, remote endpoint panes; only `claudef`,
`pif`, `nvim` auto-launch; verified save; worker boot restore under a lock.
Known: stray tmux servers silently disarm continuum; periodic autosave state
unverified; reliability under load was reopened in September.

29. Restart continuation. ADOPT. After a restart every cut-off run is
    terminalized with a visible note, then continued with: "Continue where
    you left off. Your last turn was cut short, so a command or other action
    it started may have finished or may still be running. Before you repeat
    one that changes state, confirm it did not take effect and is not still
    running; if you cannot tell, say so instead of repeating it." Skipped
    when parked, pending request, user pressed Stop, turn already ended,
    `/compact` in flight, or 3 continuations within 5 minutes. 34 tests.
    Files: `apps/server/src/orchestration-v2/RestartContinuation.ts`,
    `RestartContinuation.test.ts`, `RestartBackgroundNote.ts`,
    `ProviderRuntimeRecoveryService.ts`,
    `docs/operations/background-verification.md`.
    Gain: a restored agent pane that was mid-turn gets this prompt once,
    with the loop guard, instead of a bare resume.

30. Turn-in-progress markers. MUTATE. T3's event store knows which runs were
    live at the crash. The dotfiles can get the same with a hook-written
    `@turn_active` option saved into the sidecar, so restore knows which
    panes need item 29.
    Files (for the idea only): `apps/server/src/persistence/
    OrchestrationEventStore.ts`, `apps/server/src/orchestration-v2/
    EventStore.ts`.

31. Single-owner lock. MUTATE. Exclusive SQLite transaction on an owner
    file, released by the OS on any exit; a second starter exits with a
    distinct code so supervisors stop respawning; pre-lock holders detected
    by pid plus start time; desktop-launched backend polls its parent pid.
    Files: `apps/server/src/serverOwnership.ts`, `legacyServerOwner.ts`,
    `serverRuntimeState.ts`, `launcherWatch.ts`.
    Gain: restore and the autosave arm use one `flock`, never a pid file,
    and a loser exits with a distinct code.

32. Resume failure path. MUTATE. If the native session is gone, T3 says so
    and starts fresh carrying history; unsent resumes retried at most 3
    times.
    Files: `apps/server/src/persistence/ProviderSessionRuntime.ts`,
    `apps/server/src/orchestration-v2/ProviderContinuationService.ts`,
    `EffectOutbox.ts`.
    Gain: `claudef --resume`/`pif --session` failures surface instead of
    leaving a dead pane. Record the account profile (F6) next to the id.

33. Orphaned agent process reaping (Linux). MUTATE for Linux workers only.
    Per-process record with pid, pgid, `boot_id`-prefixed start time,
    written before release; survivors of a dead owner killed at next start;
    agents in a low-weight systemd slice.
    Files: `apps/server/src/process/providerProcesses.ts`, `agentScope.ts`,
    `packages/provider-core/src/server/processGroup.ts`.

SKIP: event sourcing and projections, the updater, power-state gating
(`HostPowerMonitor` is fed by desktop telemetry; there is no wake handler).

### F6. Accounts, auth, usage limits

There is no account rotation in T3 Code. Grep for failover, auto-switch,
round-robin, rotate finds nothing. What exists: several accounts configured
side by side, a pooled limits view, a new-thread fallback model, and
opt-in auto-resume at limit reset. The dotfiles have one Claude account and
no limit handling; a Codex limit probe remnant remains in
`pi/.config/pif/extensions/statusline.ts` after commit 8d911cc.

34. Account as a config dir. ADOPT if a second account appears. Each Claude
    instance has its own `CLAUDE_CONFIG_DIR`; `HOME` is never overridden (it
    hides the Keychain login); sessions cannot resume across config dirs, so
    a switch is a handoff. `ClaudeHome.ts` lists the `CLAUDE_CODE_*`
    variables a nested launch inherits, to scrub when a worker spawns agents.
    Files: `apps/server/src/provider/Drivers/ClaudeHome.ts`, `ClaudeDriver.ts`,
    `packages/provider-core/src/server/instanceEnvironment.ts`,
    `apps/server/src/orchestration-v2/ProviderSessionTransitionPolicy.ts`,
    `docs/user/providers-claude.md`.

35. Limit probes cached for the status line. MUTATE. SDK `get_usage` returns
    five-hour, seven-day and model-scoped windows; polled at most every
    5 minutes; a failed probe keeps the last good reading; wait time is the
    latest reset across limiting windows.
    Files: `apps/server/src/provider/claudeUsageLimits.ts`,
    `packages/provider-core/src/server/usageLimits.ts`
    (`resolveUsageLimitsAfterProbe`).
    Gain: "5h 62% / wk 31%" in the pif footer or tmux chip from a cache
    file; also lets the Codex remnant be replaced or removed.

36. Spawn-time fallback (the closest thing to rotation). ADOPT if 34 exists.
    If the default profile's window is at 100% with a future reset and the
    fallback is authenticated and not exhausted, start under the fallback
    and print one line saying why. Never mid-thread.
    Files: `packages/shared/src/usageLimits.ts` (`exhaustedUsageWindow`,
    `resolveNewThreadModelSelection`), `packages/contracts/src/settings.ts`.

37. Limit-reset auto-resume. ADOPT, opt-in. Record `{pane, profile,
    resetAt}` on a `usage_limit` failure; at reset send "Continue where you
    left off." with a deterministic id; skip parked threads, pending
    approvals, resets past the run's completion, resets >24 h overdue.
    Default off in T3.
    Files: `apps/server/src/orchestration-v2/UsageLimitRecoveryWorker.ts`.
    tmux shape: the always-on worker runs the sweeper; a `limited` pane
    state with `@reset_at`.

38. Pooled limits ordering. ADOPT the two rules only: weekly exhausted means
    session counts as 0; order accounts by soonest five-hour refill.
    Files: `packages/shared/src/usageLimits.ts` (`collectLimitPools`).

SKIP: Codex shadow home, CLIProxyAPI hub, managed policy, device approval,
guest links.

### F7. Juggling initiatives: parking, scheduling, PR watch

39. Pin, snooze, settle, archive, unread. MUTATE. Settle = finished, leaves
    the active list; snooze hides until a time but wakes early for a pending
    request or fresh failure; auto-settle after 7 days idle or PR
    merged/closed, never with pending work, awaited background work, PR
    watch, queued start or pin; `mark_unread` rewinds `lastVisitedAt`;
    agents can do all of it via a tool.
    Files: `packages/client-runtime/src/state/threadSettled.ts`
    (`effectiveSnoozed`, `threadRaisedHandWhileSnoozed`),
    `apps/server/src/orchestration-v2/ThreadSettlementService.ts`
    (`isAutoSettlementCandidate`), `apps/web/src/components/Sidebar.logic.ts`
    (`resolveSidebarThreadSection`), `docs/user/thread-sidebar.md`.
    tmux shape: `@parked=settled|snoozed:<epoch>|pinned` on the session, a
    picker filter key, and the Awaiting-wakes-snooze rule. Skip ordering
    keys, undo toasts, drag.

40. Scheduled and recurring work. MUTATE, low priority. Interval (min 60 s),
    fixed time with weekdays, once; `threadMode` new|continue|fresh; at most
    one queued occurrence per busy thread; fixed-time slots missed by >10 min
    flagged, not fired late; rows stuck `running` recovered at startup.
    Files: `packages/contracts/src/scheduledTask.ts`,
    `apps/server/src/scheduledTasks/ScheduledTaskService.ts`, `Schedule.ts`,
    `apps/server/src/scheduling/Scheduler.ts`, `DueHint.ts`.
    tmux shape: launchd minute tick over a tasks file launching `pif -p` or
    `claudef -p` into a named session. SKIP webhooks.

41. PR watch. MUTATE, light. Poll every 2 minutes; wake the agent on checks
    failed/passed, new remarks, conflict; consecutive comment-only wakes
    capped at 10; "no checks for 15 minutes" reported.
    Files: `apps/server/src/orchestration-v2/pullRequestWatch.ts`,
    `PullRequestWatchReactor.ts`.
    tmux shape: a poller that sends a steer on checks failed, with the loop
    cap; PR state cached for the picker row.

### F8. Not transferable

Phone push, Live Activities, widgets; T3 Connect tunnel and relay; guest and
prompt links; device streams, SnapShots, HTML replies; side chats and Zen
mode; linked environments and managed policy; the Effect event store itself.

## Adoption order (recommendation, not decided)

Ordered by value to the current rough edges, then by how much of T3's test
evidence transfers. Each is independent.

- A1. Delegate hardening (F3.16): persist state, batch finishes, pointer
  for oversized reports, forward child Awaiting, cascade stop, no tool
  widening. Touches `pi/.config/pif/extensions/delegate.ts` and the harness
  A12 reference.
- A2. Status model (F2.11-13): awaited-only hold, Failed and Limited states,
  unseen Done via `@last_visited`, 2 s exit grace, returned-to-you order in
  the picker. Touches `agent-state`, `agent-state.ts`, the picker.
- A3. Restart continuation (F5.29-30): `@turn_active` in the sidecar, the
  continue prompt with loop guard on restore.
- A4. Worktree safety (F1.1-3, 5): hidden-change detection and ignored-file
  list on delete, fresh base plus pre-flight plus cleanup on failure in
  `wt new`, ff-only auto-pull of the main checkout, managed-path predicate.
- A5. Worker hygiene (F4.20, 22, 23, 25, 26): host id file, ssh option set
  and error taxonomy, `rw doctor` Tailscale and sshd checks, keep-awake on
  workers, cached remote chip.
- A6. Reconnect policy (F4.21) and single-owner flock (F5.31).
- A7. Title prompts (F2.15), notification gate (F2.14).
- A8. `wt prune`, `wt pr`, `wt ship` (F1.4, 9); parking states (F7.39).
- Later or conditional: checkpoints (F1.8), temp-branch rename (F1.7), `thr`
  CLI (F3.18), handoff budget (F3.17), accounts (F6, needs a second
  account), scheduler (F7.40), PR watch (F7.41), `op://` secrets (F4.27).

## Corrections after the user's review (2026-11-20)

The first summary overstated several items. Checked against the dotfiles
code, the record is:

- F1.6: T3's env symlinking is not novel and does not solve port collisions.
  T3 has no port allocation at all; its port scanner (`apps/server/src/
  preview/PortScanner.ts`) only discovers what is listening with `lsof`. The
  dotfiles' copy-then-rewrite of `.env.local` per block stays. A hybrid
  (symlink the files that never carry per-worktree values, copy and rewrite
  only `.env.local`) is the only possible gain and `C-a e` already covers
  propagation of later edits.
- F1.7 (model-named branch rename): rejected. `/new-worktree` already names
  the branch from the chat.
- F1.8 (checkpoints): value only for pif. Claude Code has its own rewind.
- F2.11: pif already excludes service shells from holding Working
  (`shells.ts`, `agent-state.ts`). The gap is `claudef` only: `agent-state`
  `bg_shells()` counts every Bash background shell, dev servers included,
  because Claude Code has no service notion. T3's "only agent-declared
  awaited work holds" would become a `bg-await` script the agent calls, with
  the Stop hook honouring that flag instead of the `ps` scan.
- F2.13: the picker already orders by `Recency()` (last attach, focus or
  state change, `picker/state/state.go`). The remaining delta is the 2 s
  Working-exit grace.
- F2.11 "unseen Done": already exists as Done becoming Idle on focus.
- F3.17: wrong link to `/new-worktree` and `/remote-handoff`. Both move the
  whole session (`claudef --resume`, `pif --fork`), so no context selection
  is needed. T3 selects context only because it cannot move a session across
  providers. Dropped.
- F3 scope: T3 does not touch Claude Code's native subagents. `delegate_task`
  is T3's own orchestrator tool, exposed to the agent over MCP, and children
  are T3 threads. It is the counterpart of `delegate.ts`, nothing more.
- F4.20 (host identity): the hostname flip (laptop `HostName` unset, so
  `hostname -s` alternates between `mac` and `kalems-macbook-pro` after
  sleep) broke the old worktree-claim system, which no longer exists. Today
  only `tmux/scripts/host_indicator.sh` reads the hostname. rw uses ssh
  aliases. Low value.
- F4.25 (keep-awake): no value if the worker's sleep is already disabled
  with `pmset`. F4.26: the status chips never call ssh already.
- F4 dev servers: T3 does not map `localhost` to hostnames. It carries raw
  TCP over a WebSocket to the host's loopback ports
  (`apps/server/src/preview/PreviewTunnel.ts`), lists listeners per thread
  with `lsof` (`PortScanner.ts`), and the desktop app forwards a host port to
  the laptop's `localhost`. Reaching a worker's dev server from the laptop
  or a phone is a Tailscale MagicDNS matter (`mini:<port>`), with the
  `.env.ports` block giving the port. Expo QR codes encode the host's LAN
  address, so a phone needs Tailscale or the worker's LAN.
