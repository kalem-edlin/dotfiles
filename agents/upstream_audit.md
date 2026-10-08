# Upstream audit

This audit reports whether a tracked upstream file changed after its last
reviewed commit. It never edits local files or the manifest.

Run the audit from the repository root:

```sh
python3 scripts/audit-upstreams.py
```

Exit codes:

- `0`: every tracked path matches its reviewed baseline.
- `2`: the manifest, local files, Git operation, or network request failed.
- `3`: at least one tracked upstream path changed and needs review.

## Reviewing a change

1. Read the listed commits and diff the two commits in an upstream clone.
2. Compare the change with the listed local paths.
3. Apply and test any useful changes.
4. Update `baselineCommit` only after the review is complete.
