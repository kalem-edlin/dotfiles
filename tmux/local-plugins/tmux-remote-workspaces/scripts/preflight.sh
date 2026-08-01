#!/usr/bin/env bash
# Consume-never-provision preflight for a single configured worker.
#
# Prints a JSON report to stdout in every case (even failure, best-effort) and
# exits non-zero with an actionable stderr message when the worker is not
# usable. Never installs or configures anything on the worker.
#
# Usage: preflight.sh --worker <alias> [--check-lfs] [--repo-remote <url>]
#
# --repo-remote, when passed (by a caller whose operation involves a
# repository workspace), adds a worker-side git-host authentication check:
# a short-timeout `git ls-remote --heads <url> HEAD` run FROM the worker
# (never from here) -- consume-never-provision's "worker-side git SSH
# authentication for the repository host" preflight item. A failure aborts
# with the exact worker-key registration step, never an attempt to provision
# credentials itself.
#
# Testable without a reachable worker:
#   - An alias absent from config.json fails fast with no ssh attempt.
#   - RW_SSH_BIN can point at a fake ssh executable so the ssh-dependent path
#     (including the --repo-remote git-host-auth probe) can be exercised
#     with a worker that deliberately fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

rw_need_jq

worker=""
check_lfs="false"
repo_remote=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worker)
      worker="${2:?--worker requires a value}"
      shift 2
      ;;
    --check-lfs)
      check_lfs="true"
      shift
      ;;
    --repo-remote)
      repo_remote="${2:?--repo-remote requires a value}"
      shift 2
      ;;
    *)
      rw_die "preflight: unknown argument: $1" 64
      ;;
  esac
done
[ -n "$worker" ] || rw_die "preflight: --worker is required" 64

if ! rw_config_valid; then
  rw_die "preflight: $RW_CONFIG_FILE is invalid or unreadable"
fi

if ! rw_worker_known "$worker"; then
  jq -nc --arg worker "$worker" \
    '{ok: false, worker: $worker, ssh_reachable: false, error: "not_declared"}'
  rw_warn "preflight failed: worker '$worker' is not declared in config.json."
  rw_warn "Add it under .workers[] (alias/platform/notes) before use -- see README.md."
  exit 1
fi

timeout_s="$(rw_ssh_preflight_timeout)"

# A tiny, read-only remote probe. Never writes, installs, or mutates
# anything on the worker.
remote_probe='
  ok=1
  have() { command -v "$1" >/dev/null 2>&1; }
  if have tmux; then tmux_ok=true; else tmux_ok=false; ok=0; fi
  if have git; then git_ok=true; else git_ok=false; ok=0; fi
  if have git-lfs; then lfs_ok=true; else lfs_ok=false; fi
  printf "ok=%s\ntmux=%s\ngit=%s\ngit_lfs=%s\nhome=%s\nhostname=%s\n" \
    "$ok" "$tmux_ok" "$git_ok" "$lfs_ok" "$HOME" "$(hostname 2>/dev/null)"
'

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-remote-workspaces-preflight.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
start_ts="$(rw_now_epoch)"

if ! output="$(rw_ssh_batch "$worker" "$timeout_s" "$remote_probe" 2>"$work_dir/err")"; then
  duration_ms="$(rw_elapsed_ms "$start_ts")"
  err="$(cat "$work_dir/err" 2>/dev/null)"
  jq -nc --arg worker "$worker" --arg err "$err" --argjson duration_ms "$duration_ms" \
    '{ok: false, worker: $worker, ssh_reachable: false, error: $err, duration_ms: $duration_ms}'
  rw_warn "preflight failed: cannot reach worker '$worker' over ssh (${err:-timed out})."
  rw_warn "This plugin never provisions workers -- run 'make setup-headless' on '$worker' (or fix SSH/Tailscale reachability) and retry."
  rw_log_event "preflight" "" "$worker" "$duration_ms" "fail" "ssh_unreachable"
  exit 1
fi
duration_ms="$(rw_elapsed_ms "$start_ts")"

tmux_ok=false; git_ok=false; lfs_ok=false; home=""; hostname=""
while IFS='=' read -r key value; do
  case "$key" in
    ok) : ;; # remote-side summary bit; missing[] is recomputed locally below
    tmux) tmux_ok="$value" ;;
    git) git_ok="$value" ;;
    git_lfs) lfs_ok="$value" ;;
    home) home="$value" ;;
    hostname) hostname="$value" ;;
  esac
done <<<"$output"

# Git-host auth preflight (initial-plan.md, "Consume, never provision":
# "worker-side git SSH authentication for the repository host ... a private
# clone/fetch fails without the worker's own registered key"). Only
# attempted when the caller passed a repo remote AND the worker actually
# has git -- a short-timeout `git ls-remote` from the WORKER (never from
# here) proves the worker's own key/known_hosts, not this machine's.
git_host=""
git_host_auth_failed="false"
if [ -n "$repo_remote" ] && [ "$git_ok" = "true" ]; then
  git_host="$(rw_normalize_git_remote "$repo_remote")"
  git_host="${git_host%%/*}"
  pf_shquote() {
    local s="$1"
    printf "'%s'" "${s//\'/\'\\\'\'}"
  }
  auth_probe="if command -v timeout >/dev/null 2>&1; then timeout 10 git ls-remote --heads $(pf_shquote "$repo_remote") HEAD; else git ls-remote --heads $(pf_shquote "$repo_remote") HEAD; fi"
  if ! rw_ssh_batch "$worker" "$timeout_s" "$auth_probe" >/dev/null 2>"$work_dir/git-auth.err"; then
    git_host_auth_failed="true"
  fi
fi

missing=()
[ "$tmux_ok" = "true" ] || missing+=("tmux")
[ "$git_ok" = "true" ] || missing+=("git")
if [ "$check_lfs" = "true" ] && [ "$lfs_ok" != "true" ]; then
  missing+=("git-lfs")
fi
[ "$git_host_auth_failed" = "true" ] && missing+=("git-host-auth:${git_host}")

duration_ms="$(rw_elapsed_ms "$start_ts")"

report="$(jq -nc \
  --arg worker "$worker" \
  --argjson ssh_reachable true \
  --argjson tmux "$tmux_ok" \
  --argjson git "$git_ok" \
  --argjson git_lfs "$lfs_ok" \
  --arg home "$home" \
  --arg hostname "$hostname" \
  --argjson duration_ms "$duration_ms" \
  --arg git_host "$git_host" \
  --argjson git_host_auth_failed "$git_host_auth_failed" \
  --argjson missing "$(printf '%s\n' "${missing[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')" \
  '{
    ok: ($missing | length == 0),
    worker: $worker,
    ssh_reachable: $ssh_reachable,
    tmux: $tmux,
    git: $git,
    git_lfs: $git_lfs,
    home: $home,
    hostname: $hostname,
    duration_ms: $duration_ms,
    git_host: (if $git_host == "" then null else $git_host end),
    git_host_auth_failed: $git_host_auth_failed,
    missing: $missing
  }')"
printf '%s\n' "$report"

if [ "${#missing[@]}" -gt 0 ]; then
  rw_warn "preflight failed on '$worker': missing $(
    IFS=,
    echo "${missing[*]}"
  )."
  if [ "$git_host_auth_failed" = "true" ]; then
    rw_warn "Worker-side git host authentication to '$git_host' failed ('$worker' could not git ls-remote it within the timeout)."
    rw_warn "This plugin never provisions credentials -- register the WORKER's own SSH key with '$git_host' (setup-headless already generated a worker key under ~/.ssh there; add its public key to the host, e.g. https://github.com/settings/keys for GitHub), then retry."
  fi
  if [ "$git_host_auth_failed" != "true" ] || [ "${#missing[@]}" -gt 1 ]; then
    rw_warn "This plugin never installs anything -- run 'make setup-headless' on '$worker' to provision it, then retry."
  fi
  rw_log_event "preflight" "" "$worker" "$duration_ms" "fail" "missing:${missing[*]}"
  exit 1
fi

rw_log_event "preflight" "" "$worker" "$duration_ms" "success" ""
exit 0
