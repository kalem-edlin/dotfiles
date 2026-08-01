# Deferred: Mutagen Watch Mode and Mosh Transport

Status: documented future option, not approved implementation scope

Created: 2026-07-30
Updated: 2026-07-31

## Mutagen watch mode

### Why this is separate

Tmux Remote Workspaces v1 uses explicit transactional handoff and return
handoff. This proves workspace transfer, Git consistency, worktree ownership,
and agent transcript resume before introducing continuous synchronization.

Mutagen should only become a follow-up initiative if actual daily use shows
that explicit handoff creates material friction. This file preserves the option
without expanding v1.

### Cost and setup findings

Mutagen is free for this personal use. Its documentation describes it as free
and open source. The repository license is mostly MIT, while official release
builds from v0.17 onward also include code under the Server Side Public License
(SSPL). The project documents a build option that omits the SSPL component if a
strictly MIT/non-copyleft build is preferred.

Setup is comparatively light:

- Homebrew installation is supported on macOS and Linux:
  `brew install mutagen-io/mutagen/mutagen`.
- Mutagen uses the existing OpenSSH client, including configured aliases and
  keys such as `mini`.
- It automatically deploys its small endpoint agent over SSH; a separate
  permanent remote installation is not required.
- A synchronization session can be created between a local path and an
  SSH-accessible path and then paused, resumed, flushed, monitored, or
  terminated.

These properties satisfy the basic cost and installation constraints. They do
not by themselves prove that watch mode is correct for reflected Git
worktrees.

### Important Git constraint

Mutagen recommends excluding `.git` from continuous synchronization.

Its documentation also warns against continuously synchronizing two working
trees that each retain independent Git metadata. A commit on one side advances
only that side's repository state; the synchronized files can then appear as
uncommitted changes on the other side. That is directly relevant to reflected
numbered worktree slots, where both hosts need valid Git operations.

Therefore a future watch design cannot be "`mutagen sync create` and forget":

- `.git` and linked-worktree administration must never be synchronized.
- The responsibility owner and active writer host must remain explicit.
- Git operations need a coordinated handoff or pause/flush protocol.
- Commit/ref movement must be transferred through Git-aware operations.
- Agent transcripts must not share the working-tree synchronization session.
- Mutagen termination must not delete either endpoint's files.

### Potential future shape

A plausible workflow to evaluate later is:

1. Establish both worktrees with compatible Git state using normal handoff.
2. Start Mutagen only for eligible working-tree content.
3. Keep one active writer host according to the global claim.
4. Pause and flush synchronization around host handoff and Git ref changes.
5. Transfer commits/refs through the handoff transport.
6. Resume watch mode only after both worktrees agree on their base.
7. Surface Mutagen conflicts in an explicit status command.

This may still be too cumbersome. The evaluation must compare it against the
actual pain of explicit handoff rather than assuming continuous sync is better.

### Acceptance criteria before implementation

Mutagen watch mode is only worth implementing if:

- V1 handoff is already reliable.
- Repeated manual handoffs are measurably disruptive.
- A disposable reflected-slot test proves bidirectional file changes,
  untracked files, renames, deletions, commits, rebases, and return handoff.
- `.git`, provider authentication, transcripts, sockets, caches, and
  host-specific build products are excluded.
- Network loss and conflicts never produce silent last-writer-wins behavior.
- Claim enforcement prevents the local and remote agents from becoming
  simultaneous managed writers.
- Installation remains a one-command focus-host setup with automatic SSH agent
  deployment.

Until these criteria are met, Mutagen remains documented but absent from the
runtime dependency set.

### Primary references

- Overview and free/open-source statement:
  <https://mutagen.io/documentation/introduction>
- Installation:
  <https://mutagen.io/documentation/introduction/installation/>
- SSH session setup and lifecycle:
  <https://mutagen.io/documentation/introduction/getting-started/>
- Git/VCS synchronization guidance:
  <https://mutagen.io/documentation/synchronization/version-control-systems/>
- Safety mechanisms:
  <https://mutagen.io/documentation/synchronization/safety-mechanisms/>
- Repository license:
  <https://github.com/mutagen-io/mutagen/blob/master/LICENSE>

## Mosh transport

### What it offers

Mosh is UDP-based and natively survives laptop sleep, IP changes, and brief
network loss — this is the plan's literal durability requirement, not an
approximation of it. Adopting it would reduce the SSH retry loop (see
`initial-plan.md`, "Transport") to a thin restart-on-clean-exit wrapper
instead of a backoff-driven reconnect loop.

### Compatibility

The plan's design uses plain `tmux new -A`/attach, not control mode, so
Mosh's known control-mode (`tmux -CC`) limitation does not apply here. The
swap-in shape inside the existing retry loop is:

```text
mosh <worker> -- tmux new -A -s <endpoint>
```

### Costs/caveats

- A new dependency on both the focus machine and the worker. If adopted, it is
  installed by `setup-headless`, per the consume-never-provision rule — this
  plugin would still never install it itself.
- One `mosh-server` process per endpoint attachment.
- UDP must be open between the hosts; this is fine over Tailscale.
- No native scrollback, which is irrelevant here because the terminal content
  lives inside tmux.
- Predictive echo can look odd in TUIs; it can be disabled if it interferes
  with Neovim or an AI coding agent's TUI.

### Acceptance criteria

Adopt Mosh only if:

- The v1 observability event log shows real reconnect pain — frequent drops,
  or slow reattach after laptop sleep — that the SSH retry loop plus
  `ControlPersist` does not absorb.
- A disposable-endpoint test proves clean interaction with the endpoint
  session recipe (`prefix None`, `status off`) and OSC 52 passthrough.

### References

- Mosh: <https://mosh.org/>
- Mosh tmux control-mode limitation:
  <https://github.com/mobile-shell/mosh/issues/851>
