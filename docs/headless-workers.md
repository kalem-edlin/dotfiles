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
  `rsync`, `tar`, `unzip`, `tailscale` (unless provisioned with
  `INSTALL_TAILSCALE=0`), and a usable UUID source; `node`, `npm`, `pi`,
  `codex`, and `claude` for agent handoff; Neovim `nvim >= 0.10` (required
  by the managed config and remote Treemux) and `ob` as part of the intended
  headless toolset. On Linux, provisioning installs the official upstream
  stable tarball under `~/.local/opt` and links it into `~/.local/bin` when
  the distribution package is older than that minimum. `go` builds the
  tmux-agent-sessions picker (`bin/agent-picker`). On Linux, `setup/go.sh`
  installs a pinned, checksum-verified upstream tarball the same way,
  because distribution packages are too old.
- **Dotfiles:** `~/.config/tmux` and `~/.config/nvim` linked to this
  repository; the `claude`, `git`, `pi`, `ssh`, `vim`, and `zsh`
  packages stowed; `~/.local/bin/rw` available. Codex CLI remains installed,
  but has no repo-managed config or hooks, and setup does not seed
  `~/.codex/config.toml`. `codexf` loads shared instructions directly from
  `$DOTFILES/agents/communication.md`.
- **tmux plugins:** TPM itself, `tmux-resurrect` and `tmux-continuum`, and
  this repository's own `tmux-workspace-resurrect` and
  `tmux-remote-workspaces` plugin files exposed through the tmux dotfiles
  link. Live Codex session IDs are recovered from the native process and
  its open rollout file, without installing or trusting a Codex hook.
- **REA and its tools** (`make rea`, `setup/rea.sh`; the last install step
  of both headless lanes and of `make setup`):
  - `~/Developer/rea`: a clone of `git@github.com:morluto/rea.git` with its
    submodules, `node_modules` from `npm ci` under the Node in REA's
    `.nvmrc` (fnm), and `dist/` from `npm run build`. Consumers spawn
    `node dist/main.js` from the checkout. REA's `install.sh`, its global
    skills and `.mcp.json` rendering are deliberately not run. The clone is
    over SSH, so the worker's key must already be registered with GitHub.
  - `~/Developer/tools/jdk-21.0.12.1+1`: Eclipse Temurin JDK 21, and
    `~/Developer/tools/ghidra_12.1.4_PUBLIC`: Ghidra 12.1.4. Both are
    pinned sha256 archives from the vendors' GitHub releases (JDK per OS and
    arch: macOS and Linux, aarch64 and x86_64), the `setup/go.sh` pattern.
    Ghidra's zip ships the decompiler native only for Linux x86_64, so on
    macOS and Linux aarch64 the script builds it from the zip's own sources
    (`make` plus a C++ compiler: Xcode CLT, or the Linux build toolchain).
  - `zsh/.zshenv` exports `JAVA_HOME` (the JDK's `Contents/Home` on macOS,
    its root on Linux), puts its `bin` first on `PATH`, and exports
    `GHIDRA_INSTALL_DIR`, each only when the directory exists, so
    noninteractive `ssh worker '...'` jobs see them.
- **Power policy (macOS):** `setup/macos-headless.sh` runs
  `sudo pmset -a sleep 0 autorestart 1 womp 1` right after priming sudo, so
  the worker never system-sleeps (`displaysleep 0` alone does not hold it
  awake), boots again after a power failure, and wakes for network access.
  Auto-login as the worker user and FileVault off stay manual (see below);
  the doctor checks all three.
- **Durability service:** on macOS, a loaded launchd job that can find
  Homebrew tmux; on Linux, an active systemd user timer with linger enabled
  for the target user.
- **Boot-time restore:** on macOS, the loaded RunAtLoad launchd agent
  `com.kalem.tmux-resurrect-restore`; on Linux, the enabled user service
  `tmux-resurrect-restore.service`. See "Boot-time restore" below.
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

## Boot-time restore

A worker brings its tmux server back by itself after a reboot, before any
laptop connects, so parked roots (`rw handoff`) have their `rw-*` sessions
and agents running again. Headless setup installs it; `make install` on a
laptop never does.

- **Units.** macOS: launchd agent `com.kalem.tmux-resurrect-restore`
  (template `setup/templates/com.kalem.tmux-resurrect-restore.plist`,
  `RunAtLoad`, loaded into `gui/$UID`, so it fires at the auto-login after a
  reboot; this is why auto-login is required). Linux: user service
  `tmux-resurrect-restore.service` (oneshot, `WantedBy=default.target`, runs
  when the lingering user manager starts at boot). Both are installed by
  `install_tmux_resurrect_restore_agent` in `setup/lib.sh`, called from
  `setup/misc-headless.sh` (macOS) and `setup/linux-headless.sh`. Rerunning
  setup on macOS boots the agent out and back in, which runs the wrapper
  once; on Linux the service is only enabled, not started.
- **Wrapper** `setup/templates/tmux-resurrect-restore.sh`. The laptop attach
  loop also runs it when it finds no tmux server on the worker, and so does
  every rw command that needs a server there (`--start <session> <dir>`,
  below). A server on a worker is only ever started through this wrapper. A
  bare `tmux new-session` loads `tmux.conf`, whose Continuum restore lands in
  the new session's server, fails, and leaves the incomplete-restore marker,
  so the worker's saves are refused from then on.
  1. Takes the boot lock `~/.local/state/tmux-workspace-resurrect/boot-restore.lock`
     (owner pid and boot time; bounded wait). A lock whose owner is dead, or
     that was taken before the current boot (the directory survives a
     reboot and its pid may be recycled), is stale and reclaimed. Concurrent
     callers (the agent and several laptop panes) queue here; the first
     restores, the rest find a live server and do nothing. The verified save
     (`tmux/scripts/resurrect_save.sh`) refuses to run while the lock has a
     live owner. Holding the lock, it deletes incomplete-restore markers
     (`tmux-resurrect-<pid>-restore-incomplete` in `$TMPDIR`, `/tmp` and the
     macOS per-user temp dir) whose pid is not a live tmux process. Those
     markers are left by servers that have exited, and nothing reads them
     again.
  2. Live server: waits for a guarded restore that is running on it. If the
     only session left is the bootstrap one (a restore died before restoring
     anything), it restores again. If other sessions exist and the last
     restore did not complete, it exits 1 rather than restore over a
     partial landscape. Otherwise a no-op.
  3. No server and no snapshot: exit 0. With `--start <session>` it starts
     the server anyway, waits up to 10 seconds for Continuum's empty restore
     attempt, removes the marker that attempt leaves (there is no snapshot
     to protect), creates the session and exits 0. Otherwise it starts the server with
     `~/.config/tmux/tmux.conf` and a bootstrap session, publishes the
     incomplete-restore marker for the new server pid (so no save can
     capture the bootstrap landscape), and lets Continuum's restore-on-start
     run the guarded restore (`tmux/scripts/resurrect_restore.sh`, which holds
     the lifecycle lock `<TMPDIR>/tmux-resurrect-<pid>-verified-save.lock`
     shared with the verified save; both name it from the server's own
     TMPDIR). If Continuum does not start one within 10 seconds, the
     wrapper runs the guarded restore itself, and retries once when an
     attempt restored nothing. Success is the guarded restore clearing the
     marker. With `--start <session> <dir>`, the session is created next,
     before the bootstrap session is dropped, so the server never exits in
     between.
  4. Runs `tmux-remote-workspaces/scripts/rw-worker-post-restore.sh`: drops
     the bootstrap session, re-applies the hidden endpoint options
     (`prefix None`, `prefix2 None`, `status off`, `mouse off`,
     `detach-on-destroy on`) to every `rw-*` session, and writes
     `restored.json` (`restored_at`, `restored_endpoints`) beside each
     mirror record under `~/.local/state/tmux-remote-workspaces/owned/<root_id>/`.
     `record.json` itself is never written (the laptop owns it). The same
     script is chained into tmux-resurrect's post-restore-all hook
     (`--hook`, acts only where `rw-*` sessions exist), so it also runs
     inside every guarded restore, including the Continuum restore the
     wrapper's own server start fires, and drops the bootstrap session
     before the marker clears.
- **Laptop side:** while the worker is restoring (bootstrap session present,
  boot lock live, guarded restore running, or incomplete-restore marker
  set), the attach loop's probe reports `restoring` and the pane waits
  instead of closing or rebuilding its endpoint. Whether an absent session
  was closed on the worker is decided from the worker server instance
  (start time and pid) the session was last seen on, persisted per endpoint
  in `~/.local/state/tmux-remote-workspaces/attach-seen/`; with no record the
  loop recreates the session, never closes it. `rw handoff` and `rw open`
  read the wrapper's `--state`. With no server they run `--start`, and they
  wait up to 120 s (`RW_WORKER_START_TIMEOUT`) for a restore in progress or
  for exit 75. They refuse a live server whose last restore did not complete
  with one line naming the marker and the remedy, because no session made
  there would ever be saved.
- **Log:** `~/.local/state/tmux-workspace-resurrect/boot-restore.log`. Save
  results go to `workspace-resurrect.log` in the same directory;
  `launchd-save.log` only captures the save wrapper's own stderr and stays
  empty on success. Exit status: 0 on restore, no-op or
  nothing to restore; 75 when another caller held the boot lock past the
  timeout (the attach loop retries, never builds an empty session); 1 on a
  restore that did not complete (saves stay blocked for that server until a
  guarded restore succeeds) or a live server whose last restore failed.
- **Checks:** `make headless-doctor` reports `timer:restore-loaded` and
  `tmux:restore-complete` (fails while the live server has an
  incomplete-restore marker, i.e. saves are blocked).
  `setup/templates/tmux-resurrect-restore.sh --check` validates the tmux
  binary, the upstream and guarded restore scripts and the worker
  post-restore without side effects; `--restoring` exits 0 while a restore
  is in progress or incomplete. `--state` prints `none`, `restoring`,
  `incomplete <marker>` or `ready`, with no side effects. On the laptop,
  `rw doctor` prints that state for each worker. It fails on `incomplete`
  and lists markers of servers that have exited.

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
  - Confirm the Mini account identity (the `User` in `~/.ssh/config.local`) before any destructive
    reprovisioning.
  - Turn FileVault off and enable auto-login as the worker user (System
    Settings > Users & Groups > Automatically log in as). The durability
    timer loads into `gui/$UID`, which exists only after a login, and macOS
    refuses auto-login while FileVault is on. `make headless-doctor` fails
    `power:autologin` and `power:filevault` until both are done.
  - Confirm Xcode license acceptance, Simulator/signing/keychain
    requirements, and that Remote Login (SSH) is enabled in System Settings.
  - The `tailscale-app` cask (installed as part of the required contract,
    see `Brewfile.headless`) requires a system/kernel-extension approval in
    System Settings → Privacy & Security on its first install. This needs
    console or Screen Sharing interaction (or MDM pre-approval of the
    extension) — it is not unattended-safe, and `sudo tailscale up` will
    not surface or satisfy this approval for you.

## Updating a worker (rerun is the contract)

There is no `update` target: rerunning the installer is the update. From the
focus machine (`W` the worker alias, `REPO` its dotfiles checkout):

```sh
ssh $W "git -C $REPO fetch origin && git -C $REPO reset --hard origin/main"
ssh $W "make -C $REPO setup-headless"
ssh $W "make -C $REPO headless-doctor"
```

Check `git -C $REPO status --porcelain` first (see "Full validation" step 1);
`reset --hard` discards whatever dirtied the tree. What a rerun does for each
piece:

- Homebrew or distro packages, Node globals (`pi`, `codex`), `claude`,
  dotfile links and timers: brought to what the repo declares.
- `~/Developer/rea`: `git fetch` and `git submodule update --init
  --recursive` only. The branch, HEAD and working tree are never reset,
  merged or rebased; pull it yourself to move REA forward. `npm ci` runs
  only when `package-lock.json` is newer than `node_modules`, and
  `npm run build` after any `npm ci` or when `dist/main.js` is missing.
- JDK and Ghidra: skipped while the pinned directory exists. A new pin in
  `setup/rea.sh` installs side by side under its own directory name; update
  the matching names in `zsh/.zshenv` in the same commit (the doctor's
  `env:jdk-ghidra` check fails until they agree), and remove the old
  directory by hand.
- `pmset`: reapplied (idempotent).

Job state that lives outside these paths (Ghidra projects, frozen output) is
copied by hand.

## Focus-machine registration

The worker installer never edits the laptop. Registering a worker with the
focus machine is a separate, manual, focus-machine-side pair of edits:

1. **Add and test a logical SSH alias** in the laptop's untracked
   `~/.ssh/config.local` (mode 600). The tracked `ssh/.ssh/config` only
   `Include`s it and keeps reusable settings; real host entries never go in
   the repo. Keep the alias stable and independent of the underlying route —
   the `mini` pattern below is a LAN-preferred / Tailscale-fallback host that
   still resolves to one logical alias (addresses are placeholders):

   ```sshconfig
   # Prefer LAN when reachable; Tailscale is the fallback route. The logical
   # alias stays `mini` on both routes.
   Match originalhost mini exec "~/.ssh/mini-lan-available my-mini.local"
       HostName my-mini.local

   Match all

   Host mini
       HostName 100.64.0.10
       HostKeyAlias 100.64.0.10
       User <mini-user>
   ```

   A plain VPS worker (`agents-roll`) is simpler — a single `Host` block is
   enough when there is only one route:

   ```sshconfig
   Host agents-roll
       HostName 203.0.113.10
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
ssh <worker> 'command -v tmux git git-lfs jq node pi codex claude go'
```

Durability timer, per platform:

```sh
# macOS
launchctl print "gui/$UID/com.kalem.tmux-resurrect-save"
launchctl print "gui/$UID/com.kalem.tmux-resurrect-restore"

# Linux (systemd)
systemctl --user is-enabled tmux-resurrect-save.timer
systemctl --user is-active tmux-resurrect-save.timer
systemctl --user is-enabled tmux-resurrect-restore.service
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
   `ssh $W 'command -v zsh git git-lfs stow tmux jq curl rsync tar unzip node npm pi codex claude nvim ob go rw java'` —
   every command must resolve, and the output must be paths only, with no
   shell-init noise. `tailscale` too, unless the worker was provisioned with
   `INSTALL_TAILSCALE=0`.
   `ssh $W 'nvim --version | sed -n 1p'` must report Neovim 0.10 or newer,
   and `ssh $W 'java -version'` must report the pinned JDK (resolved from
   `JAVA_HOME`, not a system Java). On macOS, `ssh $W 'pmset -g'` shows
   `sleep 0`, `autorestart 1` and `womp 1`.
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
    reboot/restore) is recorded with its validation history in
    `docs/tmux-remote-workspaces.md`.
