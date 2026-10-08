#!/usr/bin/env python3
"""Report tracked upstream path changes without modifying local files."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

ERROR = 2
REVIEW_NEEDED = 3
REQUIRED = {
    "id",
    "repository",
    "ref",
    "baselineCommit",
    "upstreamPath",
    "localPaths",
}
SHA = re.compile(r"^[0-9a-f]{40}$")


def git(*args: str, cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(
            ["git", *args], cwd=cwd, text=True, capture_output=True, check=True
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        raise RuntimeError(detail.strip()) from exc
    return result.stdout.strip()


def validate(path: Path) -> list[dict[str, Any]]:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read manifest: {exc}") from exc

    if not isinstance(data, list):
        raise ValueError("manifest must be an array")

    root = path.resolve().parent
    seen: set[str] = set()
    for index, source in enumerate(data):
        if not isinstance(source, dict) or not REQUIRED.issubset(source):
            missing = sorted(REQUIRED - set(source if isinstance(source, dict) else {}))
            raise ValueError(
                f"source {index} is malformed; missing: {', '.join(missing)}"
            )
        source_id = source["id"]
        if not isinstance(source_id, str) or not source_id or source_id in seen:
            raise ValueError(f"source {index} has an empty or duplicate id")
        seen.add(source_id)
        for field in ("repository", "ref", "upstreamPath"):
            if not isinstance(source[field], str) or not source[field]:
                raise ValueError(f"{source_id}: {field} must be a non-empty string")
        baseline = source["baselineCommit"]
        if not isinstance(baseline, str) or not SHA.fullmatch(baseline):
            raise ValueError(
                f"{source_id}: baselineCommit must be a full lowercase SHA"
            )
        if not isinstance(source["localPaths"], list) or not source["localPaths"]:
            raise ValueError(f"{source_id}: localPaths must be a non-empty array")
        for local in source["localPaths"]:
            if not isinstance(local, str) or not local:
                raise ValueError(f"{source_id}: invalid local path: {local}")
            local_path = Path(local)
            if local_path.is_absolute() or ".." in local_path.parts:
                raise ValueError(f"{source_id}: invalid local path: {local}")
            if not (root / local_path).exists():
                raise ValueError(f"{source_id}: local path does not exist: {local}")
    return data


def inspect_repository(
    repository: str, ref: str, baselines: set[str], checkout: Path
) -> tuple[str, Path]:
    checkout.mkdir(parents=True)
    repo_dir = checkout / "repo"
    git(
        "clone",
        "--quiet",
        "--filter=blob:none",
        "--no-checkout",
        repository,
        str(repo_dir),
    )
    git("fetch", "--quiet", "origin", ref, cwd=repo_dir)
    latest = git("rev-parse", "FETCH_HEAD", cwd=repo_dir)
    for baseline in baselines:
        try:
            git("cat-file", "-e", f"{baseline}^{{commit}}", cwd=repo_dir)
        except RuntimeError:
            git("fetch", "--quiet", "origin", baseline, cwd=repo_dir)
    return latest, repo_dir


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default="upstream-sources.json")
    args = parser.parse_args()

    manifest = Path(args.manifest)
    try:
        sources = validate(manifest)
    except ValueError as exc:
        print(f"audit-upstreams: {exc}", file=sys.stderr)
        return ERROR

    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for source in sources:
        grouped.setdefault((source["repository"], source["ref"]), []).append(source)

    results: list[tuple[dict[str, Any], str, bool, list[str]]] = []
    try:
        with tempfile.TemporaryDirectory(prefix="upstream-audit-") as temp:
            temp_root = Path(temp)
            for number, ((repository, ref), entries) in enumerate(grouped.items()):
                latest, repo_dir = inspect_repository(
                    repository,
                    ref,
                    {entry["baselineCommit"] for entry in entries},
                    temp_root / str(number),
                )
                for source in entries:
                    baseline = source["baselineCommit"]
                    upstream_path = source["upstreamPath"]
                    try:
                        git(
                            "cat-file",
                            "-e",
                            f"{baseline}:{upstream_path}",
                            cwd=repo_dir,
                        )
                    except RuntimeError as exc:
                        raise RuntimeError(
                            f"baseline path does not exist for {source['id']}: {upstream_path}"
                        ) from exc
                    diff_result = subprocess.run(
                        [
                            "git",
                            "diff",
                            "--quiet",
                            baseline,
                            latest,
                            "--",
                            upstream_path,
                        ],
                        cwd=repo_dir,
                    )
                    if diff_result.returncode not in (0, 1):
                        raise RuntimeError(f"git diff failed for {source['id']}")
                    changed = diff_result.returncode == 1
                    commits: list[str] = []
                    if changed:
                        output = git(
                            "log",
                            "--format=%H %cI %s",
                            f"{baseline}..{latest}",
                            "--",
                            upstream_path,
                            cwd=repo_dir,
                        )
                        commits = output.splitlines() if output else []
                    results.append((source, latest, changed, commits))
    except RuntimeError as exc:
        print(f"audit-upstreams: git/network error: {exc}", file=sys.stderr)
        return ERROR

    needs_review = any(changed for _, _, changed, _ in results)
    for source, latest, changed, commits in results:
        print(f"{'REVIEW' if changed else 'CURRENT'}  {source['id']}")
        if changed:
            baseline = source["baselineCommit"]
            upstream_path = source["upstreamPath"]
            print(f"  local: {', '.join(source['localPaths'])}")
            print(f"  {baseline} -> {latest}")
            for commit in commits:
                print(f"  {commit}")
            print(f"  git diff {baseline} {latest} -- {upstream_path}")

    return REVIEW_NEEDED if needs_review else 0


if __name__ == "__main__":
    raise SystemExit(main())
