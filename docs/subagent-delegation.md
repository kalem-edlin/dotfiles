# Subagent delegation

How pif's `delegate` works and the decisions behind it. This is the
reference for delegation. The content-engine harness builds its own
`delegate` (ledger A12) from this file,
`pi/.config/pif/extensions/delegate.ts` and `pi/tests/delegate.test.mjs`.
A change to delegation behaviour lands here as a decision, with its tests,
before the harness follows it.

Decision numbers continue the series in
[`tasks/pif-web-research.md`](tasks/pif-web-research.md), where D1 to D12
were first recorded. That file stays the record of the web research lane
(Exa, `web_search`, `web_fetch`, the `research` member). D13 onward live
only here.

## Behaviour

### Who runs

`delegate(task, agent?, model?, wait?)` starts a child: a separate
`pi --mode json -p` process with `--no-extensions` and `--no-skills`, in the
parent's working directory, with the task on stdin. The child shares the
filesystem but not the conversation, so the task must carry everything it
needs.

- **Member** (`agent` set): a file in Claude Code's subagent front matter
  (`name`, `description`, `model`, `tools`) plus a `pi_model:` key. Resolved
  from `<cwd>/.claude/agents/<name>.md` first, then
  `~/.config/pif/agents/<name>.md` (which links to `agents/subagents/`).
  The body is the child's directive. `tools` maps Claude Code names to pi
  names (`Read` to `read`, `Glob` to `find`, `WebSearch` to `web_search`,
  `Agent` to `delegate`, and so on). Names with no pi equivalent are
  skipped and listed in the report.
- **Generalist** (no `agent`): the parent's model and thinking level with
  `read,write,edit,bash,grep,find,ls,delegate` and a directive that allows
  implementation inside the delegated scope, forbids reverting unrelated
  changes, and asks for a report of changed files and checks.
- A member that lists `WebSearch` or `WebFetch` gets `web.ts` with `-e`,
  then the repo's own `.pi/extensions` loaders, so a repo tool of the same
  name wins in the child as in the parent.
- Members run at thinking `low`. `model` on the call overrides the
  member's `pi_model` for that run.

### Background, wait and reports

- In the interactive UI, `delegate` returns `Delegate #N` at once. The
  parent keeps working: other tools, more delegations, replies to the user.
- The child's last assistant message comes back as a `delegate` message
  with steer delivery and `triggerTurn`. It lands before the parent's next
  model call, or starts a turn when the parent is idle.
- `wait: true` blocks the call and returns the report as the tool result.
  A parent with no UI (`pif -p`, a tier-1 child) always blocks. Several
  blocking `delegate` calls in one assistant message still run side by
  side, because pi runs a message's tool calls concurrently.
- `delegate_continue(id, task)` resumes a finished child's kept session
  with a follow-up. `delegate_stop(id)` ends a running child and returns its
  partial output.
- Every run, background or waited, stops after one hour. The session is
  kept, so `delegate_continue` resumes a capped run. A new session or
  quitting pif stops running children, and a stopped tier-1 child stops its
  own children the same way (pi's print mode runs `session_shutdown` on
  SIGTERM).
- Session files are `sessions/delegate/<member>-<time>-<6 hex>.jsonl`.
- A report is capped at 24,000 characters. A failed child's report carries
  its exit code and stderr, so the parent can retry or change course.

### Nesting: two tiers at most

```text
driver (depth 0)
└── tier 1: generalist or a member that lists Agent (depth 1, has delegate)
    └── tier 2: any member or generalist (depth 2, no delegate)
```

- The child's depth travels in `PIF_DELEGATE_DEPTH`. A child gets
  `delegate.ts` and the `delegate` tool only when its depth is below 2 and
  its tools list names `Agent`. The generalist lists it. `research` does
  not, so it stays a leaf.
- `delegate.ts` loaded at depth 2 registers nothing, even when forced with
  `-e` and `--tools delegate`.
- A tier-1 child has no UI, so its delegations block. It fans out by
  putting several `delegate` calls in one message. Its tool description
  and guidelines say so and leave out `delegate_continue` and
  `delegate_stop`.
- No limit on which members a tier-1 child may call, and no limit on how
  many. Whether a tier-1 agent fans out is set by its directive.

### What you see

- **Card above the editor**, one per delegate, in the old subagent widget's
  shape:

  ```text
  ────────────────────────────────────────────────────────────────
   ● Delegate #1 · generalist · 2 subagents  Translate CallWatcher…  (50s) | Tools: 13
     read: /Users/admin/Developer/idol-app/scripts/b6_analysis.json
  ────────────────────────────────────────────────────────────────
  ```

  The header carries status (`●` running, `✓` done, `✗` failed, `■`
  stopped), number, member, `· wait` for a blocking call, `· Turn N` after
  a continue, `· N subagents` while a tier-1 child's own delegations run,
  the task cut to 40 characters, elapsed seconds and tool count. The line
  under it is the newest activity: the last line of text or the last tool
  call, whichever came later, or the child's last stderr line when it
  failed. Finished cards stay until the user's next prompt.
- **Tool rows**: `delegate`, `delegate_continue` and `delegate_stop` render
  as one unshaded line each (`delegate research  <task>`), with
  `↳ Delegate #N started` under a background call. A blocking call shows
  the report or error, collapsed to eight lines.
- **Report message**: a status header and the first eight lines. Expanding
  it shows the rest and the notes for the model (delegate number, tool
  count, session file).
- The running count reaches `agent-state.ts` on `pif:subagents`, which
  keeps the pane marked Working while children run.

### Repo overrides

A profile extension registers nothing when the project ships
`.pi/extensions/<same name>.ts` (D10), because pi exits at startup when two
extensions register one tool name. In a repo with its own `delegate.ts`, a
tier-1 child loads the repo's copy. The harness's copy has to honour
`PIF_DELEGATE_DEPTH` itself for the two-tier cap to hold there.

## Decisions

Current decisions, newest first. Earlier wording that a later decision
replaced is kept in `tasks/pif-web-research.md`.

- **D14** (2026-11-18, Kalem). Delegation nests two tiers at most: the
  driver delegates to a worker or specialist, which may delegate to
  generalists, scouts or research. Nesting is a capability for directives
  to use, not something agents are told to do.
  - Built: the depth counter, the `Agent` opt-in, the generalist listing
    `Agent`, blocking fan-out in tier 1, `· N subagents` on the card.
  - Rejected: limiting which members tier 1 may call. Once depth is
    capped, a tier-2 `research` run carries no more risk than the driver
    calling it, and an allowlist would add a front-matter field the
    harness must copy, with no observed need. A worker that picks the
    wrong member gets its directive fixed.
  - Held: every tier-1 child gets `delegate` regardless of its tools list
    (simpler, but a research brief could then spawn research children
    nobody chose). A cap on concurrent children per worker, added only if
    a real run fans out too far (six workers with five children each is
    36 processes).
  - Not covered: tier-2 runs are visible only as the count on their
    parent's card and in their own session files.
- **D13** (2026-11-18, Kalem: look like the subagent widget, plus the
  member name). The card takes the widget's header and one activity line
  between dim rules, as shown above. Tool rows use `renderShell: "self"`
  instead of pi's padded, shaded box. Session files gain a random suffix:
  six parallel generalists started in one millisecond shared a file name
  and all but one failed with EEXIST. The widget had avoided this by
  putting its subagent number in the name.
- **D12** (2026-11-18, Kalem: one hour). Every run stops after one hour.
  The cap guards against a hung or looping child nobody is watching
  (`pif -p`, harness runners, a forgotten background run); Esc and
  `delegate_stop` cover the watched case. Held: no cap; an inactivity cap,
  added only if a real hang shows an hour is too long.
- **D11** (2026-11-18, Kalem: parity with the widget, keep the delegation
  pattern). Background by default with steer delivery, `wait: true` to
  block, `delegate_continue` and `delegate_stop`. Replaced D9's blocking
  call, which froze the driver for the child's whole run: sibling tool calls
  run concurrently only within one assistant message.
- **D10** (2026-11-18, locked). A repo's `.pi/extensions/<name>.ts` wins
  over the profile extension of the same name.
- **D9** (2026-11-18, locked). `delegate.ts` is the one subagent extension.
  `subagent-widget.ts` and the `/sub` commands are retired. The child runs
  in JSON mode with a kept session, and the generalist reproduces the
  widget's child.
- **D6, D3**. Members live in `agents/subagents/`, in Claude Code's format
  plus `pi_model`, so claudef runs the same files natively. Research is a
  member, not a tool, so the search loop never lands in the driver's
  context.

## Verification

2026-11-18, laptop, pi 0.85.1:

- `node --test pi/tests/*.test.mjs`: all pass. The delegate suite covers
  child args per depth, the `Agent` opt-in, the repo-override load, the
  depth-2 no-op, the nested count and the card and row shapes.
- A real tier-1 child (`PIF_DELEGATE_DEPTH=1`, generalist args) told to
  delegate twice in one message started both tier-2 runs before either
  ended and returned `ALPHA` and `BETA`. The two tier-2 session files had
  distinct names 2 ms apart, and neither run had a `delegate` tool.
- A depth-2 child started with `-e delegate.ts --tools read,delegate`
  reported that it had no `delegate` tool.
- Not yet seen in a live pif TUI: the card colours and the unshaded tool
  rows were checked through tests and a plain-text render only.
