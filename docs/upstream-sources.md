# Upstream source tracking

Some files in this repository adapt work maintained elsewhere.
`upstream-sources.json` records each upstream file, its last reviewed commit,
and the local files to compare with it.

Run the audit from the repository root:

```sh
python3 scripts/audit-upstreams.py
```

The script checks each upstream file at the current tracked ref. It prints
`REVIEW` with the relevant commits and a diff command when that file changed.
It prints `CURRENT` otherwise. It does not edit local files or advance reviewed
commits.

Each manifest entry contains only the data needed for that check:

- `id`
- `repository`
- `ref`
- `baselineCommit`
- `upstreamPath`
- `localPaths`

When a file needs review, compare the two upstream revisions with every listed
local path. Apply and test useful changes, then update `baselineCommit`. Keep
copyright notices in source files where they belong. The audit does not track
licenses or descriptions of local differences.

Exit status `0` means no tracked upstream file changed. Status `3` means review
is needed. Status `2` means the manifest, a local path, Git, or the network
failed.

See [`agents/upstream_audit.md`](../agents/upstream_audit.md) for the short
operator workflow.
