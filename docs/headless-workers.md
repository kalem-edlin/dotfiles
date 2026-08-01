# Headless Worker Runbook

Operator steps for bringing up a headless worker (macOS Mini, Linux VPS) and
registering it with a focus machine so `rw` can orchestrate it. See
`docs/tasks/headless-install.md` for the design rationale and acceptance
criteria this runbook implements.

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
