# Upstream source tracking and audit

Status: ready for implementation

## Goal

Track the current upstream state for every locally maintained configuration, extension, or skill derived from another repository. Detect relevant upstream changes without making runtime behavior depend on an external checkout or automatically overwriting local adaptations.

An audit must compare against current upstream `main`, show the files and commits that changed, and leave adoption as a deliberate review.

## Initial sources

The following refs were read directly from each repository's `main` branch on 2026-09-08 UTC.

| Local resource | Upstream resource | Current `main` commit | Commit time |
| --- | --- | --- | --- |
| `agents/communication.md` | `cursor/plugins:pstack/skills/unslop/SKILL.md` | `71ed0d1076fec562c1b74ee353121a8d00f75382` | 2026-09-08 05:16 UTC |
| `agents/communication.md` | `disler/fixing-smartass-opus-5:sr_opus_5_system_prompt.md` | `5a349e87201c1987f22191fbac4ca772822aa352` | 2026-08-16 20:37 UTC |
| Pi `subagent-widget.ts` derivative | `disler/pi-vs-claude-code:extensions/subagent-widget.ts` | `0ed11f44932fdef29bd98467700019762298f50d` | 2026-07-10 16:09 UTC |
| Pi `purpose-gate.ts` derivative | `disler/pi-vs-claude-code:extensions/purpose-gate.ts` | `0ed11f44932fdef29bd98467700019762298f50d` | 2026-07-10 16:09 UTC |
| Pi `session-replay.ts` derivative | `disler/pi-vs-claude-code:extensions/session-replay.ts` | `0ed11f44932fdef29bd98467700019762298f50d` | 2026-07-10 16:09 UTC |

Repositories:

- <https://github.com/cursor/plugins>
- <https://github.com/disler/fixing-smartass-opus-5>
- <https://github.com/disler/pi-vs-claude-code>

The Cursor `unslop` source changed within the last three days. Review the current file against `agents/communication.md` before treating the existing amalgamation as current. The audit must establish the reviewed commit as the initial baseline rather than assuming the local file already incorporates it.

## Required artifacts

Create:

```text
upstream-sources.json
scripts/audit-upstreams.py
UPSTREAM_AUDIT.md
```

Also add a focus-profile skill that tells `pif` and `claudef` when to invoke the audit. The skill should call the script and point the agent to `UPSTREAM_AUDIT.md`. A Markdown file by itself is documentation and will not be selected stochastically.

Use `upstream-sources.json`, not `skill-versions.json`, because the manifest tracks extensions and configuration as well as skills.

## Manifest contract

For each source, record:

- stable source identifier
- upstream repository URL
- tracked branch or ref
- reviewed baseline commit
- upstream path
- local path or paths
- relationship such as `derived`, `adapted`, or `inspired`
- notes about intentional local differences
- license and attribution requirements

One local resource may have several inspiration sources. `agents/communication.md` must point to both sources above.

Do not use a mutable branch name as the only recorded version. The baseline must always be a full commit SHA.

## Audit behavior

The script must:

1. Validate the manifest schema and all referenced local paths.
2. Resolve the latest commit for each tracked upstream ref.
3. Report whether the tracked upstream path changed between the baseline and latest commit.
4. Print the relevant commit list and upstream diff command or URL.
5. Distinguish repository movement from changes to the tracked file.
6. Return success when everything is current.
7. Return a distinct nonzero status when review is needed.
8. Fail clearly for network, missing ref, malformed manifest, or missing local file errors.
9. Never modify local derivatives or advance baseline commits automatically.
10. Support a machine-readable output mode for doctor or CI integration.

A cached temporary clone is acceptable. The script must not depend on `/Users/kalemedlin/Developer/indydevdan/pi-vs-claude-code` or any other developer-specific checkout.

## Review workflow

For each reported source change:

1. Read the upstream file at the recorded baseline and latest commit.
2. Compare the upstream change with the local derivative.
3. Decide which behavior should be adopted.
4. Adapt and test locally rather than replacing the file blindly.
5. Record intentional differences in the manifest.
6. Advance the baseline SHA only after review and validation.
7. Preserve required copyright and license notices.

For inspiration sources such as `agents/communication.md`, review concepts and rules rather than expecting an exact textual match.

## Initial implementation validation

Before implementing the focus-agent migration:

- [ ] Review current `cursor/plugins` `unslop/SKILL.md` at `71ed0d1076fec562c1b74ee353121a8d00f75382` against `agents/communication.md` because it changed within the last three days.
- [ ] Review current `fixing-smartass-opus-5` prompt at `5a349e87201c1987f22191fbac4ca772822aa352` against the same local communication prompt.
- [ ] Re-read all three Disler extension sources at `0ed11f44932fdef29bd98467700019762298f50d` before deriving local versions.
- [ ] Verify the local extension adaptations against the installed Pi version.
- [ ] Verify the communication prompt with current interactive `pif` and `claudef` versions.
- [ ] Run the completed audit and confirm it reports no unreviewed tracked-path changes.
- [ ] Change one baseline to an older commit in a temporary manifest and confirm the audit reports the upstream path change.
- [ ] Test malformed manifest, unavailable network, missing local path, and unchanged-file cases.

## Completion criteria

- Every known derivative or inspiration source has a pinned reviewed commit.
- The audit detects current `main` changes for the tracked paths.
- A focus agent can discover and invoke the workflow through the installed skill.
- Auditing requires no external working checkout.
- Updating a baseline remains an explicit human-reviewed change.
