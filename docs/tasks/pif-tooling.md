# PIF tooling

Status: research recorded, implementation pending

## Goal

Give PIF agents narrowly scoped tools without turning the focus profile into a
general agent distribution. Tools should be available only to the coordinator
or subagent that needs them. Their output must stay small enough that the final
coordinator response remains the useful result.

The first need is web and public-source research. Search Primitives is the
candidate backend, but PIF should depend on a small agent contract rather than
its full command catalog.

## Boundaries

- Bare `pi` must not inherit PIF tools or policy.
- The PIF coordinator should not receive research tools by default.
- Ordinary PIF subagents should keep the built-in file and shell tools only.
- A research subagent may receive a named research capability when the parent
  delegates a research task.
- Provider credentials stay in the Search Primitives runtime. They must not be
  copied into prompts, Pi settings, child arguments, or research artifacts.
- Retrieved text is untrusted evidence. It is never an instruction to the
  calling agent.
- Public sources remain the limit. Browser cookies, personal sessions,
  follow-gated material, and data-source OAuth remain out of scope.
- Provider calls, scraper runs, costs, and incomplete coverage must be visible
  in the result.

## Current PIF behavior

[`subagent-widget.ts`](../../pi/.config/pif/extensions/subagent-widget.ts)
starts each child with Pi's built-in tools and `--no-extensions`. This prevents
recursive loading of the parent extension directory. Skills and Bash remain
available to the child.

This makes a thin skill plus CLI the least invasive first trial. A later Pi
extension can register native research tools, but the child launcher would have
to load that extension explicitly and add its tool names to `--tools`.
Installing an extension in the parent profile is not enough.

## Outstanding needs

### PIF-001: Research tooling for selected agents

Status: research complete, contract and implementation pending

#### Need

PIF currently has no controlled way to discover current sources, read public
web pages, or run a wider evidence sweep. A coordinator can delegate repository
work to a child, but that child has no purpose-built research interface.

The required behavior is selective:

- Most agents need no network tools.
- A source-checking agent may need only URL retrieval.
- A web-research agent needs compact discovery and page retrieval.
- A recent-signal agent needs an opinionated, time-bounded sweep across web,
  code, discussion, video, and public social sources.
- A deep-research agent may need a durable multi-source run with a larger
  budget, source outcomes, and replayable evidence.

The main thread should normally delegate these jobs. Raw search results and
full pages stay in the research child's context or in files. The coordinator
receives the child's cited findings.

#### Research findings

Disler's [`pi-vs-claude-code` extensions](https://github.com/disler/pi-vs-claude-code/tree/main/extensions)
do not include a general web-search extension. The Pi Pi experts described in
the [Pi Pi specification](https://github.com/disler/pi-vs-claude-code/blob/main/specs/pi-pi.md)
retrieve known Pi documentation with Firecrawl, fall back to `curl`, inspect
local code, and report to a coordinator. This is a strong known-source pattern,
but it does not solve open discovery.

Disler's [Beyond MCP](https://github.com/disler/beyond-mcp) work supports a
CLI-first design when control and prompt cost matter. The useful Pi extensions
reviewed for this task reach the same conclusion through different designs:

- [`coctostan/pi-web-tools`](https://github.com/coctostan/pi-web-tools) keeps
  search output compact and writes full content to temporary files.
- [`wynainfo/pi-web-research`](https://github.com/wynainfo/pi-web-research)
  exposes only search and fetch, caps page reads, caches results, and isolates
  synthesis.
- [`nicobailon/pi-web-access`](https://github.com/nicobailon/pi-web-access)
  has mature provider and content coverage, but it is much larger than PIF
  should load for routine work.

The design to copy is small tool registration, file-backed full content,
bounded context, explicit provider behavior, and isolated synthesis. PIF does
not need to install any of those packages wholesale.

#### Search Primitives assessment

Search Primitives is a credible backend because it already owns:

- raw and normalized evidence;
- run manifests, source maps, and bounded context packs;
- Brave, Exa, Firecrawl, GitHub, Hacker News, YouTube, xAI, xtomd, and selected
  Apify public-social routes;
- provider-call accounting and approval gates;
- a public-only acquisition policy;
- explicit cost caps for scraper-backed social work.

Its strongest property is evidence retention. The calling agent can start with
a compact source map, open a bounded context pack, and inspect full documents
or raw responses only when needed.

It is not ready to expose directly as PIF's routine tool set. The current
catalog has many provider and maintenance commands. Its `task` coordinator is
useful, but the planner is shallow, execution is sequential, source failure is
not yet a first-class coverage verdict, time handling varies by provider, and
the ranking code combines unlike engagement signals. Existing validation proves
artifact consistency, not retrieval quality.

These limits are already recorded in Search Primitives'
[`investigation.md`](../../../search-primitives/docs/tasks/investigation.md).
Its [`decisions.md`](../../../search-primitives/docs/tasks/decisions.md) keeps
the required architecture choices in proposed state. PIF must not treat those
proposals as finished contracts.

#### Required Search Primitives direction

Search Primitives should keep its granular operations for debugging and custom
workflows. It also needs a smaller, more opinionated agent interface above
them. The caller should state the research intent and allowed authority. Code
should choose the routes, enforce policy, and record why it selected or rejected
each route.

Candidate profiles:

| Profile | Intended job | Expected source policy |
| --- | --- | --- |
| `source-fetch` | Read one known public URL | Direct HTTP or source-native retrieval, then Firecrawl if extraction fails |
| `web-research` | Find and read a few relevant sources | Brave for exact or current discovery, Exa for semantic discovery, then fetch selected pages |
| `recent-sweep` | Find meaningful activity within a strict recent window | Web, GitHub, Hacker News, YouTube, X, and qualified Reddit routes with hard timestamp verdicts |
| `social-validation` | Test whether practitioners or users confirm a claim | Qualified X, Reddit, YouTube, and explicit Instagram routes with comments and engagement kept source-specific |
| `intensive` | Produce a durable evidence set for a broad question | A reviewed multi-source plan, bounded parallel retrieval, source outcomes, fusion, and a compact final context pack |

`recent-sweep` is the local equivalent of a useful last-30-days workflow. It
must not mean "call every provider." The planner should select independent
streams that can add recent evidence, apply one strict time window after
retrieval and ranking, and state which requested sources were successful,
empty, unavailable, blocked, or failed.

Instagram needs special care. The current repository supports explicit public
post routes, while broader profile, hashtag, and search discovery remains
unvalidated. A sweep must report Instagram as unavailable or scoped to supplied
URLs until that route passes its quality gate. TikTok should remain absent
until a separate investigation approves it.

The agent interface should avoid dozens of provider switches. An optional
provider override is reasonable for evaluation and diagnosis, but ordinary
agents should choose a profile and research goal. The run record should reveal
the providers and routes that code selected.

#### Proposed PIF contract

The routine native interface should contain no more than two tools:

```text
web_search(query, mode, domains?, recency?, limit?)
web_fetch(url, question?, max_chars?)
```

`web_search` returns at most five compact records containing title, canonical
URL, publication time when known, provider, snippet, and source ID.
`web_fetch` writes the complete document to a temporary or durable evidence
file and returns its path, retrieval method, a capped excerpt, and truncation
status.

Wider work should use one code-driven operation through a thin skill or command:

```text
research_run(profile, brief, window?, source_scope?, budget?)
```

The result should return a run ID, coverage summary, costs, source-map path,
bounded context-pack path, and warnings. It should not print the entire run into
the Pi transcript.

The wrapper grants bounded authority. For example, a research-enabled child may
request `recent-sweep` within a fixed paid-call limit. It may not enable browser
cookies, select an unapproved scraper, remove the time constraint, or bypass a
social-execution confirmation. The skill explains when to call the operation.
Search Primitives code remains the authority for routing and policy.

#### Selective exposure in PIF

| Agent | Default research access |
| --- | --- |
| PIF coordinator | None. Delegate research unless the user explicitly requests direct coordinator research |
| Ordinary subagent | None |
| URL-checking subagent | `web_fetch` only |
| Web-research subagent | `web_search` and `web_fetch` |
| Recent or social research subagent | `research_run` for an allowed profile, plus bounded fetch for source inspection |
| Search Primitives maintenance agent | Local diagnostics and replay commands, with live provider calls disabled unless requested |

The first prototype should add an explicit research option to `/sub`, rather
than giving every child the same network tools. A form such as
`/sub --research web ...` or `/sub --research recent ...` makes the authority
visible at delegation time.

Implementation should begin with a short PIF skill that calls a stable
Search Primitives CLI. This works with the current child isolation because Bash
and skill discovery remain enabled. If native tool calls prove clearer, add a
small PIF extension that registers the same contract and have research children
load that one extension explicitly despite the general `--no-extensions`
setting. The extension must not reimplement routing, ranking, policy, or
artifact storage.

MCP is an evaluation candidate, not the default. It adds a persistent tool
description and another process boundary without solving the contract problem.
The same fixed tasks should decide whether native Pi tools justify that cost.

#### Alignment with the pending Search Primitives plan

The current [Search Primitives plan](../../../search-primitives/docs/tasks/plan.md)
should supply the backend in this order:

1. M1 must include PIF's real query classes. At minimum, evaluate known-source
   retrieval, focused web research, implementation research, recent sweeps,
   social validation, and recurring watchlists.
2. M2 must make capability claims operation-specific and add URL safety,
   deadlines, cancellation, failure classes, and recursive secret redaction.
3. M3 should turn the profiles above into deterministic plans with bounded
   parallel streams, shared budgets, and one `SourceOutcome` per stream.
4. M4 must enforce recent windows after fusion and keep engagement values
   source-specific. This is required before `recent-sweep` can be trusted.
5. M5 should qualify the existing YouTube, Reddit, X, full-web, and media routes
   before broad Instagram discovery or any new platform enters a default plan.
6. M6 should compare direct CLI, thin-skill-to-CLI, native Pi extension, and MCP
   calls against the same fixtures. Production integration follows stable
   contracts and quality floors.
7. M7 can decide whether a smaller reusable package should move elsewhere. PIF,
   Claude Code skills, and other wrappers should consume the same contracts
   regardless of repository location.

One sequencing change is warranted. M6's interface investigation can begin
alongside M1 as a contract prototype because PIF supplies concrete workloads
and context measurements. Production wrapper work should still wait for the
M1 through M4 contracts and the required M5 source routes. This avoids designing
the backend without its callers while keeping unstable behavior out of PIF.

The Search Primitives project also needs to settle its Agent Reach naming
collision before other tools publish durable package or command references.
That remains DEC-003 and is not a PIF decision.

#### Acceptance criteria

- An ordinary PIF session and ordinary child expose no research tools.
- A research child receives only the capability selected at delegation time.
- Search and fetch results remain within fixed result and character limits.
- Full documents and raw responses stay in files outside the coordinator
  transcript.
- A research run reports every planned source as successful, empty, degraded,
  unavailable, blocked, cancelled, or failed.
- Strict recent queries cannot present old or unknown-time items as recent.
- Citations resolve to public URLs and retain links to local raw evidence.
- Provider, scraper, paid-call, and total-cost limits are enforced in code.
- Retrieved documents pass public-URL checks and are treated as untrusted.
- Direct CLI, skill, and native Pi calls produce equivalent run artifacts for
  the same plan.
- Replay evaluation covers all supported PIF query classes without live network
  access.
- Live canaries remain small and separate from replay tests.
- The coordinator receives a compact cited report rather than child tool logs
  or full provider responses.

#### Open decisions

1. Whether the coordinator should ever receive research tools directly, or
   whether PIF should require delegation for every research request.
2. Whether `/sub --research` needs named capability levels or one research
   extension whose runtime policy derives authority from the task invocation.
3. Whether routine evidence files should use temporary session storage or a
   durable Search Primitives run.
4. What fixed context, call, cost, and time limits each profile should receive.
5. Whether native Pi tools improve model behavior enough to justify them over a
   thin skill and CLI.
6. Which representative PIF tasks become the first M1 and M6 evaluation set.

#### Next work

1. Add the PIF query classes and wrapper requirements to Search Primitives'
   investigation before accepting DEC-005, DEC-009, DEC-010, or DEC-011.
2. Choose representative PIF tasks and capture expected sources, citations,
   context use, latency, and cost.
3. Define versioned agent-facing request and result schemas without changing
   provider adapters.
4. Prototype `source-fetch`, `web-research`, and `recent-sweep` through a thin
   skill and CLI against recorded fixtures.
5. Compare the same tasks through a native Pi extension. Test selective child
   loading and prove the coordinator remains unchanged.
6. Implement live provider execution only after the relevant quality,
   security, and budget gates pass.

## References

- [Focus-agent profiles](../focus-agents.md)
- [Search Primitives protocol](../../../search-primitives/PROTOCOL.md)
- [Search Primitives investigation](../../../search-primitives/docs/tasks/investigation.md)
- [Search Primitives decisions](../../../search-primitives/docs/tasks/decisions.md)
- [Search Primitives plan](../../../search-primitives/docs/tasks/plan.md)
