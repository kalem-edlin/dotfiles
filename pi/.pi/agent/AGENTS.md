# Global agent rules (Pi, all repositories)

## Managed worktrees, slots, and claims (dotfiles-owned)

These rules apply to any repository opted into the dotfiles `worktrees`
package (a `.config/worktrees/config.json` entry keyed by normalized git
remote identity, not by folder name or `package.json` name). Treat any
other repository as an ordinary git repository -- none of this applies
there.

### Persistent numbered slots

- Never create a persistent worktree with raw `git worktree add` in an
  opted-in repository. Use `worktree-slot ensure [slot-number] [--tier
  <tier>] [--dry-run]`.
- Derive the repository and positive slot number from the repo's configured
  collection and the `<repo-name>-N` path. Never invent a second naming
  convention.
- Run slot validation/port rendering (`worktree-slot ensure`) before
  dependency preparation or server startup.
- Never copy another slot's port file, infer ports from its current
  listeners, or hand-edit assigned port variables (`.worktree-slot.json`,
  `.worktree-slot.env`).
- A branch/task swap keeps the slot's ports and preparation tier -- do not
  reset or reassign them.
- Promote a preparation tier only when explicitly requested or required by
  configured slot policy; do not install heavy resources into every slot.
- Slots are created detached-HEAD. Branch assignment happens only via claim
  or explicit checkout -- never invent or assume a slot's branch.

### Claims

- Before making a managed edit or git mutation in a claimed/claimable
  worktree, resolve the caller's focus-machine, stable tmux-session, and
  execution-host identity and run `worktree-claim verify-writer [--path
  <worktree>]`.
- Respect its refusal. Exit codes 10 (responsibility mismatch), 11 (host
  mismatch), and 13 (conflicted) mean STOP -- do not edit, do not retry
  with a workaround. Exit 12 (no stable session identity, e.g. running
  outside tmux) is not itself a block; use ordinary judgment.
- Claim the worktree for the current focus/tmux responsibility
  (`worktree-claim claim`) before starting managed edits on it.
- Never steal or overwrite an existing claim. Use the explicit
  `handoff-writer` / `return-writer` / `release` operations, or an approved
  `--force-takeover`, never a silent overwrite.
- Unclaimed worktrees and non-opted-in repositories are unaffected --
  claims are optional, not a universal lock.

### Ephemeral sub-agent worktrees

- If you (an agent working one slot/worktree) fan out into sub-agents that
  need to edit in parallel without stepping on each other, give each
  sub-agent its own ephemeral worktree under
  `<collection>/.eph/<slot>-<task-slug>-<n>`, branch prefixed `eph/`.
- Raw `git worktree add` is permitted here -- but ONLY under `.eph/`.
- No slot numbers, no port allocations, no slot services started, no
  claims.
- Never reflect an `.eph/` worktree to a remote worker and never make it
  handoff-eligible.
- You (the spawning agent) own cleanup: `git worktree remove` it once the
  sub-agent's task completes. Do not leave it for later garbage collection
  -- there isn't any.

### Pi's own worktree mechanisms are not the authority here

- Do not use any Pi built-in worktree-management feature to create or
  manage worktrees in an opted-in repository.
- Authority over worktree creation/management in an opted-in repository
  belongs to that repository's own instruction files and to the dotfiles
  slot/claim system described above -- not to any Pi built-in worktree
  feature.

### Local Supabase is a singleton -- never branch it per worktree

- The local Supabase stack is a repository-wide singleton: identical
  `project_id` and ports in every slot/worktree. Only one slot can run it
  at a time; this is accepted, not a bug to work around.
- The local singleton should track `origin/main` schema.
- For migration or schema-trial work in a parallel worktree/task, use the
  repository's cloud Supabase DB branching workflow (e.g. `pnpm branch` for
  content-engine) instead of touching the local singleton. This is standing
  policy for every autonomous agent running in parallel worktrees, so
  migrations never collide locally.

## Enforcement note

The `worktrees.ts` extension (`~/.pi/agent/extensions/worktrees.ts`,
installed from this dotfiles repo) intercepts file-modifying tool calls and
calls `worktree-claim verify-writer`, hard-blocking on a
responsibility/host/conflict mismatch (fails open with a warning if the
`worktree-claim` binary is missing). That extension is the enforced
backstop; this file is the rest of the policy (slot usage, ephemeral
worktrees, Supabase) that has no blocking hook and depends on you following
it.
