# Persistent Worktree Slots

Persistent worktree slots separate long-lived development infrastructure from
short-lived task ownership.

## Philosophy

A repository that opts into the slot model has a collection directory:

```text
<repo-name>-trees/
├── <repo-name>-1
├── <repo-name>-2
└── <repo-name>-N
```

The numbered directory is a durable slot, not a permanent branch or task. A
task temporarily claims a slot, checks out its branch, uses the slot's prepared
resources, and releases it when finished. The next task can reuse the same
checkout and caches.

This provides:

- Stable places for parallel tmux responsibility areas and coding agents.
- Fast task switching without constantly creating and destroying worktrees.
- Reuse of dependencies, Git LFS objects, CocoaPods, Xcode build state, and
  other expensive machine-local artifacts.
- A bounded storage budget: not every temporary branch receives every heavy
  resource.
- Matching slot identities on reflected workers without synchronizing
  host-specific Git metadata or caches.

Claims identify the owning focus/tmux responsibility and active writer host.
The slot number identifies infrastructure; neither the branch nor the claim
owns that number permanently.

## Preparation tiers

Each repository defines its own tiers in the global dotfiles configuration.
Typical meanings are:

- **Light:** checkout and minimal tooling; suitable for shell, review, or
  inexpensive server work.
- **Warm:** common dependencies and routine build caches are ready.
- **Heavy:** scarce resources such as CocoaPods, Xcode/Simulator state, large
  LFS material, or expensive generated artifacts are prepared.

Only selected slots are promoted to expensive tiers. Tier changes are explicit
and idempotent; changing a task or branch does not automatically discard a
slot's reusable resources.

## Stable ports

Ports belong to `(repository, slot, service)`, never to a branch or task:

```text
port = service_base + (slot_number - 1) * block_size
```

The global allocator reserves a non-overlapping range per service, validates
that no derived port collides, renders a private slot environment, and checks
the host before starting servers. It never silently substitutes a random free
port. A collision is an error with an owner/process report because stable,
predictable ports are part of the slot identity.

Per-service bases and the shared `block_size` are declared centrally in
dotfiles so different slot-enabled repositories cannot overlap. Generated
manifests and ports files are ignored runtime state, not committed repository
policy.

Ports reach a repository through a file that repository declares — the
`ports_file` in its `config.json` entry, e.g. content-engine's `.env.ports` —
which we write as plain dotenv and it reads as data. The repository owns the
filename, ignores it in its own `.gitignore`, and falls back to its own
defaults when the file is absent, so the same checkout still works on CI, on a
worker, and for anyone not running these dotfiles. A repository that declares
no `ports_file` gets none. A repository must never derive ports from its own
directory name or an index: that is a second allocator, blind to what is
actually bound on the machine and to every other repository sharing the pool,
and the two will drift.

Repository-wide singleton services — for example a local Supabase stack — are
outside slot scaling; only one slot runs them at a time. Parallel migration
work instead uses that repository's cloud-branching workflow.

## Lifecycle

1. Add an opted-in repository and its collection path, capacity, tiers, and
   services to the global dotfiles configuration.
2. Run `worktree-slot ensure <N>`, which creates or validates the numbered slot,
   assigns stable ports, and applies the selected preparation tier.
3. Claim the slot for a focus/tmux responsibility.
4. Work locally or hand the same responsibility to an eligible reflected host.
5. Return or finish the work, then release the claim.
6. Reuse the durable slot for another task without discarding its tiered
   machine-local resources.

Raw `git worktree add` remains available for repositories outside this model.
For an opted-in persistent collection, agents use the global slot helper rather
than inventing names, ports, claims, or setup behavior.
