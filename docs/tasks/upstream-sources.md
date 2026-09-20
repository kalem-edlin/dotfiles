# Upstream source tracking and audit

Status: implemented and simplified

## Goal

Detect when a locally adapted upstream file has changed since its last reviewed
commit. Show the relevant commits and leave adoption to a deliberate local
review. The audit must not modify local files or depend on a permanent upstream
checkout.

## Implementation

- `upstream-sources.json` maps upstream files and reviewed commits to local
  files.
- `scripts/audit-upstreams.py` validates that mapping and checks the current
  upstream refs.
- `agents/upstream_audit.md` contains the operator workflow.

The manifest now contains only the six fields the audit uses: `id`,
`repository`, `ref`, `baselineCommit`, `upstreamPath`, and `localPaths`.
License, relationship, and notes fields are gone. License notices remain in
the source files that require them.

The script now supports only the manual review workflow. It has no versioned
manifest wrapper, machine-readable output, or separate status for repository
commits that do not touch the tracked file. Entries for the same upstream file
share one list of local paths.

## Completion criteria

- Every tracked upstream file has a full reviewed commit SHA.
- Exit status `3` identifies upstream files that need review.
- A clean audit exits `0`; manifest, local-path, Git, and network failures exit
  `2`.
- Updating a reviewed commit remains an explicit local change.
