#!/usr/bin/env bash
# Runs every tests/test_*.sh. No tmux server, no ssh, no network: see lib.sh.
#
# Usage: tests/run.sh [test-name-substring]

set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
ran=0
for t in "$dir"/test_*.sh; do
  case "$(basename "$t")" in *"${1:-}"*) : ;; *) continue ;; esac
  ran=$((ran + 1))
  printf '== %s\n' "$(basename "$t")"
  if ! bash "$t"; then
    failed=$((failed + 1))
  fi
  echo
done
printf 'rw tests: %d file(s), %d failed\n' "$ran" "$failed"
[ "$failed" -eq 0 ]
