# PIF web research: the basic lane

Status: built and verified 2026-11-18 (see Build notes and Verification).
Supersedes the contract
part of [`pif-tooling.md`](pif-tooling.md) PIF-001; its research findings
stay as reference. The vendor research and the content-engine side are in
the content-engine repo at
`docs/tasks/harness/research/basic-web-search.md` and its discussion ledger
(T16).

## Decisions

- D1. Exa is the vendor. Highest accuracy and lowest latency on the late-2026
  benchmarks, and one key covers search and reading an arbitrary URL.
  Brave (fresher, cheaper, no URL fetch) and Firecrawl (unreadable pages)
  are fallbacks that are not built until a run shows the miss.
- D2. Tier 1 is a pif extension, `pi/.config/pif/extensions/web.ts`, with
  two driver tools: `web_search` and `web_fetch`. Both return Exa's
  query-matched highlights under a fixed character budget, so no model call
  of our own is needed. The driver uses them for one or two targeted
  lookups. Claude Code needs nothing here; its `WebSearch` and `WebFetch`
  are native.
- D3. Tier 2 is a subagent, not a tool: `agents/subagents/research.md` in
  Claude Code's subagent front matter plus a `pi_model:` key. claudef runs
  it natively; pif runs it through a new synchronous `delegate` extension.
  The driver delegates whenever a question needs more than a couple of
  searches, so the search-refine loop never lands in the driver's context.
- D4. Separate implementations from the content-engine harness, maintained
  apart, with the same tool and member names. In that repo, project
  members win over profile members by name (Claude Code's own rule, which
  `delegate` mirrors), and the repo's extension loaders register a tool
  only when no tool of that name is loaded yet, so pif's copies stay.
  Rejected: a monorepo path loaded from pif (machines without the
  checkout), a git submodule, a shared package repo.
- D5. Keys live in a gitignored `.env` at the dotfiles root, copied by hand
  to each machine like the other worker-local credentials, exported only by
  the focus launchers (`pif`, `claudef`, `codexf`). Bare `pi`, `claude` and
  `codex` never see them. Cross-machine sync is deferred.
- D6. Subagent definitions live under `agents/subagents/`, the dotfiles
  name for what the harness calls `swarm`.
- D7. The pif `delegate` is a small synchronous extension (the child's final
  text is the tool result), not an extension of `subagent-widget.ts`.
  Reasons: a research answer is needed mid-reasoning, the harness
  `delegate` has the same shape so the two stay conceptually aligned, and
  the Disler derivative stays untouched for upstream audits.
- D9 (2026-11-18, revises D7; locked by Kalem 2026-11-18). One subagent
  extension, `delegate.ts`;
  `subagent-widget.ts` is retired. The first interactive run showed the
  synchronous tool with no progress at all ("Working" for two minutes),
  while the widget streamed its child's events into a live card. pi runs
  sibling tool calls concurrently, so the widget's background shape bought
  nothing the synchronous tool lacks. `delegate(task, agent?, model?)`
  now runs the child in `--mode json` with a kept session file under
  `sessions/delegate/`, streams tool calls and the last line of text into
  the tool's partial result and a card above the editor, emits the running
  count on `pif:subagents` as the widget did, and without an agent runs a
  generalist on the parent's model and thinking with the built-in tools
  (the widget's child shape). The `/sub` family of commands is dropped
  (unused). The card code keeps the upstream MIT notice. A member that
  lists web tools also gets the project's `.pi/extensions` loaders after
  the profile's `web.ts`, so a repo tool of the same name wins in the
  child as in the parent (see D10 for how). Prompt cost of the member
  list: name plus first description sentence per member in the tool
  description, 269 characters for the three harness members; the same
  shape as Claude Code's own `Agent` tool listing, which carries whole
  descriptions.
- D10 (2026-11-18, revises D4's tool half; Kalem: repo wins; locked by
  Kalem 2026-11-18). A profile
  extension `extensions/<name>.ts` registers nothing when the project has
  `.pi/extensions/<name>.ts`. Found at the first content-engine smoke test:
  pi reports two loaded extensions registering one tool name as an error
  and exits at startup in every mode (`Tool "web_search" conflicts with
  ...`), and `pi.getAllTools()` is not initialised during load, so neither
  D4's "register only when unclaimed" nor any last-wins order can work.
  The file name is the contract: the harness ships `.pi/extensions/web.ts`
  and later `.pi/extensions/delegate.ts`. Edge: an untrusted project whose
  loader pi refuses to load leaves pif without that tool until the project
  is trusted. Members were already project-first; this makes tools the
  same.
- D8. The deeper lane (search-primitives, social validation) is decided in
  the content-engine harness ledger first (T16). Once built there, the
  dotfiles side follows. The `research` subagent is the entry point for
  it in both runtimes: its directive will name the CLI and the subagent
  runs it over bash. Nothing of that is built here now.

## Layout

| Path | Change |
| --- | --- |
| `pi/.config/pif/extensions/web.ts` | New. Registers `web_search` and `web_fetch`. Auto-loaded by the existing `extensions` entry in `settings.json`. |
| `pi/.config/pif/extensions/delegate.ts` | New. Registers `delegate`. |
| `agents/subagents/research.md` | New. The research subagent. |
| `pi/.config/pif/agents` | New symlink to `../../../agents/subagents`, like `skills`. |
| `claude/.config/claudef/agents` | New symlink to `../../../agents/subagents`, so the plugin ships the subagent. |
| `.env` (root, gitignored already) | `EXA_API_KEY=...`. `.env.example` tracked beside it with the key names. |
| `zsh/.zshrc` `pif()` | Export `.env` into the child environment before `command pi`. |
| `claude/.local/bin/claudef`, `zsh/.zshrc` `codexf()` | Same export. |
| `setup/headless-doctor.sh` | Warn when `.env` is missing or lacks `EXA_API_KEY`. |
| `pi/tests/web.test.mjs`, `pi/tests/delegate.test.mjs` | `node --test`, request shaping and member parsing with a stubbed fetch and spawn. |
| `docs/focus-agents.md` | Pi profile bullets, Subagents section, implementation map rows. |
| `README.md` | Docs list entry for this file. |

## Tool contracts

`web_search(query, num_results?, since?)`

- Exa `POST /search`, `type: auto`, `numResults` default 5 (max 10),
  `startPublishedDate` from `since`, `contents.highlights` with the query
  (two highlights per page, three sentences each).
- Returns one block per result: title, URL, published date, highlights.
  Total result text is capped (about 3,000 characters by default); the
  result says when it was cut.
- `promptGuidelines`: use `web_search` for one or two targeted lookups;
  delegate anything that needs several searches to the `research`
  subagent through `delegate`.

`web_fetch(url, query?, max_chars?)`

- Exa `POST /contents` for the one URL. With `query`: highlights for it.
  Without: cleaned text capped at `max_chars` (default 6,000), with a
  truncation note.
- A page Exa cannot read returns a plain error line; no second provider.

`delegate(agent, task, model?)`

- Resolves `agent` to `<cwd>/.claude/agents/<agent>.md`, then
  `$PI_CODING_AGENT_DIR/agents/<agent>.md`. Parses front matter `name`,
  `description`, `model`, `pi_model`, `tools`; the body is the child's
  directive.
- Spawns `pi -p --no-session --no-skills --no-extensions`, loading
  `-e <profile>/extensions/web.ts` only when the member lists `WebSearch`
  or `WebFetch`, with `--tools` mapped from Claude Code names
  (`WebSearch` to `web_search`, `WebFetch` to `web_fetch`, `Read` to
  `read`, `Grep` to `grep`, `Glob` to `find`, `Bash` to `bash`, `Write`
  to `write`, `Edit` to `edit`), `--model` from `pi_model` or the call's
  `model`, `--thinking low`, `--append-system-prompt` with
  `communication.md` then the member body, the task as the prompt, cwd
  inherited. The child inherits `PI_CODING_AGENT_DIR`, so auth bridges
  work and `--no-extensions` keeps the other pif extensions out.
- Blocks until the child exits (10 minute cap), returns its final text.
- `promptSnippet` names the members found at startup so the driver knows
  what it can delegate to.

`agents/subagents/research.md`

```md
---
name: research
description: Multi-search web research that returns a cited brief. Use it whenever a question needs more than a couple of searches; the driver never reads raw pages itself except one intentional URL.
model: sonnet
pi_model: openai-codex/gpt-6.1-sol
tools: WebSearch, WebFetch, Read, Grep, Glob
---
```

Body: run as many searches as the question needs, refine queries on weak
results, read pages only through the fetch tool, return a short brief with
one URL and quoted sentence per claim and a list of what was not found.
Never writes files. `pi_model` is pif's current default; lower it once a
cheaper Codex model proves fine. Claude Code reads `model`, pi reads
`pi_model`.

## Build notes (2026-11-18)

- Tool parameters are plain JSON Schema objects. pi validates those
  without TypeBox, so the extensions import nothing from pi at runtime and
  `node --test` loads the real `.ts` files with type stripping, like the
  other pif tests.
- Search highlights are cut at 500 characters each. Exa treats a markdown
  block without a sentence boundary as one sentence, and the first live
  search returned one 2,900-character highlight that consumed the whole
  budget. Fetch passages are not cut per highlight: the first interactive
  run showed a Metacritic fetch cut mid-review at 500 characters, which
  cost the driver a second fetch of the same page. `max_chars` caps the
  passages as a whole instead, as it already did for page text.
- The driver's `delegate` guidelines say a research brief arrives with its
  sources checked and is to be used as the answer, with a re-fetch of a
  cited page reserved for a claim that looks off or a user asking for more.
  In the first interactive run the driver re-fetched both cited pages
  after the brief and restated it, which was a third of the wall time.
- The task reaches the child on stdin (`pi -p` merges piped input into the
  prompt), so task text starting with `-` or `@` cannot be read as an
  option or a file.
- An unreadable page throws (pi marks a tool result as an error only when
  `execute` throws); the message carries Exa's reason tag.
- Claude Code exposes a plugin `agents/` member under the plugin namespace:
  `claudef` lists `dotfiles-focus:research`. A project `.claude/agents`
  member keeps its bare name, which is why the harness member will too.
- Members whose `tools:` include a name without a pi equivalent (for
  example `Task`) run with the rest and the result notes the skipped names.
- Second pass (2026-11-18, after the first interactive run): `delegate.ts`
  rewritten per D9 (JSON-mode child, kept session, progress card,
  generalist), `subagent-widget.ts` removed, `web_fetch` passages uncut per
  highlight, a driver guideline to trust the brief, and the D10 yield to a
  project loader. The delegate test shim now emits pi JSON events; the
  pif suite is 70 tests.

## Verification

Second pass, 2026-11-18, laptop: `pif -p` from a non-repo directory ran
`delegate research` with a PONG task through the argv shim; the child argv
was `--mode json -p --session ~/.pi/agent/sessions/delegate/research-<time>.jsonl
--no-skills --no-extensions -e ~/.config/pif/extensions/web.ts --tools ...
--thinking low ...`, the session file exists, and the result carried the
`[0 tool calls; session ...]` note. From the content-engine checkout a
tool-listing probe showed `web_search` and `web_fetch` from the repo's
`.pi/extensions/web.ts` and `delegate` from the profile (outside a repo all
three from the profile), a child started as `delegate` starts it registered
the repo copy, and a real research delegation in a tmux pane showed the
card (`● research 12s tools: 4`, the last search, the last line of text)
and the tool box filling with each call; the brief came back cited and the
card cleared at the end of the turn.

Results, 2026-11-18, laptop: all seven passed.

1. `pif` in a non-repo directory: `web_search` returns highlights for a
   query; `web_fetch` returns highlights with a query and capped text
   without one; a bad URL returns the error line.
2. `delegate research "<question>"` returns a cited brief; the child's
   process args show `--no-extensions` and the single `-e web.ts`; the
   driver's transcript holds only the brief.
3. `claudef` lists `research` as a subagent from the plugin `agents/`
   directory. If plugin agent discovery does not work, the fallback is the
   launcher passing the member through `claude --agents` JSON; check that
   before changing the layout.
4. Bare `pi` and bare `claude` load none of this (focus-agents maintenance
   checks 1 and 2).
5. `node --test pi/tests/web.test.mjs pi/tests/delegate.test.mjs` pass.
6. `setup/headless-doctor.sh` on a worker without `.env` warns and names
   the fix.
7. In the content-engine checkout, `pif` still loads its own `web_search`
   and `delegate`; `delegate research` resolves the repo's member when the
   repo has one, otherwise the profile's.

Evidence: step 1 by a script calling the tools' `execute` directly against
Exa (search 1.6 s, fetch with query 0.2 s, fetch text 0.7 s, bad URL
`CRAWL_UNKNOWN_ERROR`) and by `pif -p` answering a `web_search` prompt;
step 2 by `pif -p` returning the research brief (two cited claims, one
gap) and by a `pi` PATH shim recording the child argv exactly as the
contract lists; step 3 by `claudef -p --model haiku` listing
`dotfiles-focus:research`; step 4 by `~/.pi/agent/extensions` and
`~/.claude/agents` not existing and `EXA_API_KEY` unset in an interactive
zsh; step 5 passing with 65 tests across the pif suite; step 6 by running
the doctor from a copy without `.env` and with an empty key; step 7 by
listing members from the content-engine checkout (oracle and scout from
`.claude/agents`, research from the profile).

## Exa key

Create the key in the Exa dashboard (`dashboard.exa.ai`, API keys), named
for this use (`dotfiles-pif`), and put it in `~/Developer/dotfiles/.env` as
`EXA_API_KEY=`. Copy the file to each machine's dotfiles checkout by hand.
The dashboard shows current pricing and any starting credit; the
third-party numbers in the research doc are a guide only. The content-engine
harness gets its own key later, under its GCP `read-only` role, so spend
stays attributable per side.

## Deferred

- Brave as the freshness fallback and Firecrawl for unreadable pages.
- The deeper lane and its CLI install per machine (follows the harness, D8).
- `.env` sync across machines; an `age`-encrypted copy in the repo is the
  cheap upgrade if hand-copying hurts.
- A `delegate` for `codexf`.
