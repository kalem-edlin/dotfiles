# Headless Worker Runbook

Operator steps for bringing up a headless worker (macOS Mini, Linux VPS) and
registering it with a focus machine so `rw` can orchestrate it. See
`docs/headless-vs-local.md` for the design rationale — what headless install
does differently from local install, and why.

## Preconditions

- The repository is present on the worker at the intended revision — clone it
  over HTTPS or copy it, then confirm `origin/main` actually contains the
  implementation you expect to run (a stale clone silently installs an older
  contract).
- You are logged in and operating **as the target user**, not root. Never run
  `sudo make setup-headless`. The setup scripts acquire `sudo` themselves for
  the individual steps that need it (e.g. package installation); running the
  whole thing under `sudo` changes `$HOME` and file ownership in ways the
  scripts do not expect.
- Incoming SSH is already enabled and reachable on the worker. This is a
  stated VPS precondition — setup does not provision an SSH server for you.
- `git` and `make` are installed. `make setup-headless` is the sole entry
  point, and minimal VPS images (observed: Ubuntu 24.04 on `agents-roll`,
  2026-08-01) ship without `make`. On Debian/Ubuntu:
  `apt-get update && apt-get install -y make`.

## Provision

From the repository root on the worker:

```sh
make setup-headless
```

This dispatches to the Linux or macOS headless lane automatically based on
`uname -s`.

- **Success** means the command exits zero *and* the postflight doctor gates
  the final banner — if you see the success banner, the required command,
  dotfile, plugin, PATH, and timer contract passed verification. A nonzero
  exit means the worker is incomplete; do not treat partial output as a
  usable worker.
- The install is rerun-safe. Running `make setup-headless` again on an
  already-provisioned worker should not fail, duplicate services, silently
  reauthenticate, or destroy the only useful backup of a pre-existing config.
  If a rerun fails, that is a bug in the installer, not an expected operator
  workaround.
- `INSTALL_TAILSCALE=0 make setup-headless` skips Tailscale installation.
  Use this escape hatch only for a deliberately public/LAN-only worker;
  everything else should keep Tailscale in the default contract.

## Required worker contract

After `make setup-headless` succeeds, the target user has all of the
following. `make headless-doctor` and the verification commands below prove
this contract — not just that the installer exited zero.

- **Commands:** `bash`, `zsh`, `ssh`, `git`, `git-lfs`, `stow`, `tmux`, `jq`,
  `rsync`, `tar`, `tailscale` (unless provisioned with
  `INSTALL_TAILSCALE=0`), and a usable UUID source; `node`, `npm`, `pi`,
  `codex`, and `claude` for agent handoff; Neovim `nvim >= 0.10` (required
  by the managed config and remote Treemux) and `ob` as part of the intended
  headless toolset. On Linux, provisioning installs the official upstream
  stable tarball under `~/.local/opt` and links it into `~/.local/bin` when
  the distribution package is older than that minimum.
- **Dotfiles:** `~/.config/tmux` and `~/.config/nvim` linked to this
  repository; the `claude`, `codex`, `git`, `pi`, `ssh`, `vim`, `worktrees`,
  and `zsh` packages stowed; `~/.local/bin/rw`, `worktree-slot`, and
  `worktree-claim` available.
- **tmux plugins:** TPM itself, `tmux-resurrect` and `tmux-continuum`, and
  this repository's own `tmux-workspace-resurrect` and
  `tmux-remote-workspaces` plugin files exposed through the tmux dotfiles
  link.
- **Durability service:** on macOS, a loaded launchd job that can find
  Homebrew tmux; on Linux, an active systemd user timer with linger enabled
  for the target user.
- **Noninteractive availability:** every command a focus machine invokes via
  `ssh worker '<command>'` resolves without an interactive or login shell —
  in particular Homebrew `tmux`/`git-lfs` on macOS and fnm-managed
  `node`/`pi`/`codex` on both platforms.
- **Independent credentials:** a worker-owned SSH key exists and is
  registered with the Git host, and `claude`, `codex`, and `pi` are
  authenticated independently on the worker — never copied from the focus
  machine.
- **Focus-machine registration:** the worker has a logical OpenSSH alias on
  the laptop, and the same alias is declared in
  `tmux/local-plugins/tmux-remote-workspaces/config.json` (see "Focus-machine
  registration" below).

## Manual steps (these stay manual)

The installer intentionally does not automate the following. Do them
yourself, in this rough order:

- **Register the worker's SSH key with the Git host** (GitHub/GitLab). The
  installer creates/reports a worker-owned key; it does not push it anywhere.
- **`tailscale up`** — authenticate Tailscale on the worker interactively
  (or via an explicitly approved auth-key workflow). The installer only
  installs the client.
- **Authenticate `claude`, `codex`, and `pi` independently on the worker.**
  Credentials are never copied from the focus machine or any other host —
  each provider CLI must be logged in on the worker itself.
- **Mac mini-specific manual steps:**
  - Confirm the account identity is `alfierobertson` before any destructive
    reprovisioning.
  - Confirm the GUI login/reboot model: the durability timer loads into
    `gui/$UID`, which requires the Mini to either auto-login or otherwise
    maintain that GUI user domain across reboots. Decide and configure this
    deliberately rather than assuming it.
  - Confirm Xcode license acceptance, Simulator/signing/keychain
    requirements, and that Remote Login (SSH) is enabled in System Settings.
  - The `tailscale-app` cask (installed as part of the required contract,
    see `Brewfile.headless`) requires a system/kernel-extension approval in
    System Settings → Privacy & Security on its first install. This needs
    console or Screen Sharing interaction (or MDM pre-approval of the
    extension) — it is not unattended-safe, and `sudo tailscale up` will
    not surface or satisfy this approval for you.

## Focus-machine registration

The worker installer never edits the laptop. Registering a worker with the
focus machine is a separate, manual, focus-machine-side pair of edits:

1. **Add and test a logical SSH alias** in the laptop's `ssh/.ssh/config`.
   Keep the alias stable and independent of the underlying route — see the
   `mini` entry for the pattern of a LAN-preferred / Tailscale-fallback host
   that still resolves to one logical alias:

   ```sshconfig
   # Prefer LAN when reachable; Tailscale is the fallback route. The logical
   # alias stays `mini` on both routes.
   Match originalhost mini exec "~/.ssh/mini-lan-available"
       HostName Alfies-Mac-mini.local

   Match all

   Host mini
       HostName 100.67.127.104
       HostKeyAlias 100.67.127.104
       User alfierobertson
   ```

   A plain VPS worker (`agents-roll`) is simpler — a single `Host` block is
   enough when there is only one route:

   ```sshconfig
   Host agents-roll
       HostName 76.13.137.3
       User root
       IdentityFile ~/.ssh/id_ed25519
   ```

   Test with `ssh <alias> true` before moving on.

2. **Add the identical alias and platform** to
   `tmux/local-plugins/tmux-remote-workspaces/config.json` on the laptop.
   `mini` and `agents-roll` are the existing entries; follow the same shape:

   ```json
   {
     "alias": "your-new-worker",
     "platform": "linux",
     "notes": "One-line description of what this worker is for."
   }
   ```

   `platform` is `"darwin"` or `"linux"`. Append the object to the
   `workers` array — do not remove the existing entries.

## Verification

Run these from the laptop (focus machine) once the worker is provisioned and
registered:

```sh
# Noninteractive command-resolution probe — must succeed without an
# interactive/login shell and without shell-init output on stdout.
ssh <worker> 'command -v tmux git git-lfs jq node pi codex claude'
```

Durability timer, per platform:

```sh
# macOS
launchctl print "gui/$UID/com.kalem.tmux-resurrect-save"

# Linux (systemd)
systemctl --user is-enabled tmux-resurrect-save.timer
systemctl --user is-active tmux-resurrect-save.timer
loginctl show-user "$USER" -p Linger
```

Then, from the laptop:

```sh
rw doctor
rw ensure --worker <alias>
```

`rw doctor` should report the worker as healthy; `rw ensure` should be able
to stand up or attach to a workspace on it. If either fails, treat the worker
as not-yet-registered rather than working around it from the worker side.

## Full validation (new or updated worker)

The quick checks above are enough for routine use. When bringing up a new
worker for the first time, or after a change to the install/durability
scripts, run this fuller procedure once to prove the whole contract end to
end. Everything runs from the focus machine over SSH; nothing in this
procedure touches the focus machine's own tmux server. Every tmux command
below runs on the worker, only ever against a disposable session named
`smoke-headless` that this procedure itself creates and cleans up, and only
ever kills a session it created, with an exact-match target
(`kill-session -t '=smoke-headless'` — the leading `=` forces exact match so
prefix matching can never select another session; quote the argument, since
a zsh login shell on the worker otherwise intercepts the bare `=word` token
as zsh EQUALS command-path expansion and tmux never sees it).

Let `W` be the worker's logical alias and `REPO` the path to the dotfiles
checkout on the worker (`~/Developer/dotfiles` or `~/dotfiles`).

1. Sync `main`: confirm `ssh $W "git -C $REPO status --porcelain"` is empty
   (a dirty tree halts the sync — never `reset --hard` a dirty worker tree
   without first checking what dirtied it; a stowed provider settings
   symlink writing through to the tracked file is a known cause, see
   `docs/headless-vs-local.md`), then run
   `ssh $W "git -C $REPO fetch origin && git -C $REPO checkout main && git -C $REPO reset --hard origin/main"`
   and confirm `ssh $W "git -C $REPO rev-parse HEAD"` matches the intended
   commit.
2. Provision: `ssh -t $W "cd $REPO && make setup-headless"` exits 0.
3. Doctor, noninteractively: `ssh $W "cd $REPO && make headless-doctor"`
   exits 0 — this also proves the doctor's own toolchain resolves under a
   noninteractive SSH shell.
4. Full contract probe:
   `ssh $W 'command -v zsh git git-lfs stow tmux jq curl rsync tar node npm pi codex claude nvim ob rw worktree-slot worktree-claim'` —
   every command must resolve, and the output must be paths only, with no
   shell-init noise. `tailscale` too, unless the worker was provisioned with
   `INSTALL_TAILSCALE=0`.
   `ssh $W 'nvim --version | sed -n 1p'` must report Neovim 0.10 or newer.
5. Git LFS: `ssh $W 'git lfs env >/dev/null && echo LFS_OK'` prints
   `LFS_OK`.
6. Durability timer: the per-platform checks above (`launchctl print` /
   `systemctl --user is-enabled` plus `is-active` plus
   `loginctl show-user -p Linger`).
7. Detached save-chain proof — the strongest evidence the timer actually
   works with nobody attached, not just that it's loaded:
   - Record `~/.local/share/tmux/resurrect/.last-successful-save` and
     the last line of
     `~/.local/state/tmux-workspace-resurrect/workspace-resurrect.log`.
   - `ssh $W 'tmux new-session -d -s smoke-headless'`.
   - Trigger the timer directly instead of waiting: macOS
     `ssh $W 'launchctl kickstart "gui/$(id -u)/com.kalem.tmux-resurrect-save"'`;
     Linux `ssh $W 'systemctl --user start tmux-resurrect-save.service'`.
   - Within about 30 seconds, `.last-successful-save` must advance and the
     workspace sidecar log must gain a new `saved N pane records` line — proof
     the whole validated chain runs with no attached client, including when an
     unchanged landscape legitimately reuses its prior snapshot.
   - Clean up: `ssh $W 'tmux kill-session -t =smoke-headless'`.
8. Rerun idempotency: record the SSH key fingerprint
   (`ssh $W 'ssh-keygen -lf ~/.ssh/id_ed25519.pub'`) and any existing `.bak`
   files, run `make setup-headless` a second time, and confirm the
   fingerprint is unchanged, the `.bak` files are unchanged (first-backup
   protection), and there is exactly one timer/service registered
   (`launchctl print` / `systemctl --user list-timers`).
9. Provider presence (auth stays manual):
   `ssh $W 'claude --version; codex --version; pi --version'` must resolve
   and print versions.
10. `rw doctor` from the laptop reports the worker healthy, and
    `rw ensure --worker <alias>` can stand up or attach to a workspace on
    it — beyond that, remote-workspace behavior (handoff, reconnect,
    reboot/restore) is validated by the smoke-test checklist in
    `docs/tasks/tmux-remote-workspaces/initial-plan.md`.
