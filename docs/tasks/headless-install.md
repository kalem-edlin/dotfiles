# Headless Installation Readiness Plan

Status: implemented and pushed to main (2026-08-01); on-host smoke test below
in progress (see "AI-agent smoke test")

Created: 2026-08-01

Related design: `docs/tasks/tmux-remote-workspaces/initial-plan.md`

## Purpose

Make `make setup-headless` a trustworthy, repeatable provisioning path for:

- The macOS Mini worker.
- New Linux VPS workers.
- The worker-side requirements of `tmux-remote-workspaces` and
  `tmux-workspace-resurrect`.

Also preserve one shared CLI contract across the normal local setup and the
headless setup. A headless machine should receive the same terminal, Git,
editor, provider, dotfile, networking, and `rw` capabilities as a local
machine unless the local machine has a deliberate platform-specific
alternative. The normal local setup may add GUI applications and focus-machine
integration; it must not be a weaker CLI installation than headless setup.

The target should either produce a worker that satisfies the complete contract
or exit nonzero with an actionable explanation. It must never print a success
banner after a required package, dotfile, plugin, PATH, or timer step failed.

This document records the current coverage, known holes, implementation plan,
manual steps, and acceptance tests. It intentionally separates worker
provisioning from focus-machine worker registration: installing a VPS cannot
silently edit the laptop's worker inventory.

## Installation parity and ownership

Every task below is required implementation work, not a menu of optional
enhancements. Applicability is classified as follows:

- **Shared local + headless:** packages, CLI PATH, provider CLIs, dotfiles,
  tmux plugins, Tailscale, `rw`, worktree tools, SSH client configuration, and
  postflight validation.
- **Headless worker-specific:** detached tmux durability timers, systemd
  linger, worker-owned Git credentials, and worker provider authentication.
- **Focus-machine-specific:** logical SSH routing, worker declarations in
  `tmux-remote-workspaces/config.json`, per-pane orchestration, and local
  Continuum behavior. The focus machine does not need the worker save timer
  because it has a rendering tmux client; that is a deliberate local-specific
  alternative, not missing parity.
- **GUI/local-specific:** desktop applications, macOS preferences, login
  items, accessibility permissions, and similar workstation behavior.

The shared contract should be implemented once and consumed by both `setup`
and `setup-headless`, rather than maintained as two drifting package/config
lists.

## Required worker contract

After setup, the target user must have all of the following:

1. Required commands:
   - `bash`, `zsh`, `ssh`, `git`, `git-lfs`, `stow`, `tmux`, `jq`, `rsync`,
     `tar`, `tailscale`, and a usable UUID source.
   - `node`, `npm`, `pi`, `codex`, and `claude` for agent handoff.
   - `nvim` and `ob` because they are part of the intended headless toolset.
2. Required dotfiles:
   - `~/.config/tmux` and `~/.config/nvim` linked to this repository.
   - Stowed `claude`, `codex`, `git`, `pi`, `ssh`, `vim`, `worktrees`, and
     `zsh` packages.
   - `~/.local/bin/rw`, `worktree-slot`, and `worktree-claim` available.
3. Required tmux plugins:
   - TPM itself.
   - `tmux-resurrect` and `tmux-continuum`.
   - The repository-owned `tmux-workspace-resurrect` and
     `tmux-remote-workspaces` plugin files exposed through the tmux dotfiles
     link.
4. Required durability service:
   - macOS: a loaded and functional launchd job that can find Homebrew tmux.
   - Linux: an active systemd user timer with linger enabled for the target
     user.
5. Noninteractive availability:
   - Every command used by `ssh worker '<command>'` must resolve without an
     interactive or login shell.
   - In particular: Homebrew `tmux`/`git-lfs` on macOS and fnm-managed
     `node`/`pi`/`codex` on both platforms.
6. Independent credentials:
   - A worker-owned SSH key exists.
   - The operator has registered that key with the relevant Git host.
   - Claude, Codex, and Pi are authenticated independently on the worker where
     required. Credentials are never copied from the focus machine.
7. Focus-machine registration:
   - The worker has a logical OpenSSH alias on the laptop.
   - The same alias is declared in
     `tmux/local-plugins/tmux-remote-workspaces/config.json` on the laptop.

## Coverage of the freshly provisioned VPS report

The reported VPS currently has tmux, Git, and rsync but lacks the following:

| Missing item | Does setup attempt it? | Current reality |
| --- | --- | --- |
| `jq` | Yes | Listed for apt, dnf, pacman, zypper, and apk. Individual package failures are currently warnings, so setup can still claim success without it. |
| Git LFS | Yes | `git-lfs` is listed for every package manager and `git lfs install --skip-repo` runs when available. Its absence is not currently a fatal postflight error. |
| zsh | Yes | Listed for every package manager and selected as the login shell best-effort. Shell-change failure is currently only a warning. |
| Dotfiles | Yes | Linux links nvim/tmux and stows the CLI packages. This only works if the new implementation has first been committed/pushed or otherwise copied to the VPS. |
| Tailscale | Yes, default-on | Linux headless setup now installs Tailscale unless explicitly disabled with `INSTALL_TAILSCALE=0`. Authentication remains manual and must be verified before the worker is considered reachable. |
| Worker resurrection/timer | Partially | TPM/plugins and a systemd user timer are attempted. TPM failures are ignored, non-systemd Linux skips the timer, and final timer/plugin health is not enforced. |
| `rw` runtime files | Partially | The tmux dotfiles link exposes the plugin source. The headless paths do not currently create `~/.local/bin/rw`. Registry/state files are intentionally created lazily by actual `rw` use rather than provisioned as fake state. |
| Worker registration in `config.json` | Focus-machine task | Worker setup runs on the VPS; registration belongs to the focus machine and requires a chosen logical alias. `mini` and `agents-roll` are now declared. Every subsequent VPS must still be added locally before `rw` will accept it. |

Conclusion: the installer has the right package intent, but it does not yet
guarantee the full worker contract.

## Blocking issues

### 1. Commit and distribute the implementation

The current `main` worktree contains modified and untracked setup, template,
plugin, worktree, provider, and documentation files. `origin/main` does not
contain this implementation yet. A normal clone on a new machine would install
the older repository state.

Required work:

- Review the dirty worktree and separate unrelated changes where appropriate.
- Commit the headless/remote-workspace implementation.
- Push or otherwise deliberately distribute that exact revision.
- Record the expected commit in the first installation log so worker state is
  attributable to a dotfiles revision.

### 2. Fix noninteractive PATH on both platforms

`zsh/.zshenv` currently adds `~/.local/bin` but does not expose Homebrew or
fnm. This directly violates the Phase 1 requirement that worker commands work
under noninteractive SSH.

Observed macOS-like result with a minimal SSH/launchd PATH:

- Found: system Git and `~/.local/bin/claude` when the new zshenv is sourced.
- Missing: Homebrew `tmux`, `git-lfs`, `fnm`, and fnm-managed `node`, `pi`, and
  `codex`.

Required work:

- Add `/opt/homebrew/bin` or `/usr/local/bin` when the corresponding Homebrew
  installation exists.
- On Linux, add the fnm bootstrap location used by `setup/node.sh`, currently
  `~/.local/share/fnm`.
- Initialize fnm in a noninteractive-safe way or install stable shims for the
  selected default Node and global provider CLIs.
- Avoid interactive output from `.zshenv`.
- Verify with `ssh <worker> 'command -v ...'`, not only an interactive SSH
  session.

### 3. Fix the Linux first-run environment boundary

`setup/linux-headless.sh` executes `setup/node.sh` as a child process. The fnm
and Node PATH changes made inside that child do not return to the parent. The
later Obsidian check therefore cannot find the freshly installed `ob` command.
The npm fallback for Stripe has the same defect on package managers without a
native Stripe package path.

Required work:

- Give shared setup scripts a common function for locating/activating fnm, or
  explicitly evaluate fnm in every script that consumes Node-installed tools.
- Ensure `setup/obsidian.sh` can locate fnm installed by the immediately
  preceding Node step on a completely clean Linux account.
- Ensure the Stripe npm fallback uses the same environment.
- Add a clean-HOME integration test that proves the setup reaches dotfile and
  timer installation after Node setup.

### 4. Make the macOS Make path fail fast

The Darwin branch of `setup-headless` is one compound shell recipe without
fail-fast behavior. A failed `sudo`, recursive make, timer load, or install can
be followed by successful echo commands and an overall success result.

The current structure also makes `make -n setup-headless` unsafe: the presence
of `$(MAKE)` in the compound recipe causes the outer recipe to execute. A dry
run was observed invoking `sudo` and reaching the cleanup command.

Required work:

- Prefer a dedicated `setup/macos-headless.sh` with `set -euo pipefail`, or use
  platform-specific prerequisite targets that naturally propagate failure.
- Ensure every required recursive make result is checked.
- Print the success banner only after postflight verification passes.
- Make `make -n setup-headless` genuinely non-mutating.
- Document that setup should run as the target user, not via `sudo make`; the
  scripts should acquire sudo only for the individual privileged operations.

### 5. Make package and postflight validation authoritative

Linux currently turns individual package installation failures into warnings,
checks only a small command subset, and then ignores the verifier's result.
This is incompatible with a reliable provisioning contract.

The Linux package lists also do not currently install `rsync`. The reported VPS
happens to have it already, but setup does not guarantee it on the next VPS.

Required work:

- Divide packages into required and optional sets.
- Add `rsync` to every supported Linux required-package mapping (or remove it
  from the formal contract if the final transport implementation demonstrably
  does not use it).
- Fail immediately or at the final aggregated postflight when a required
  package is missing.
- Optional tools may warn without failing, but must be labeled optional in the
  setup output and documentation.
- Verify at least:
  `zsh git git-lfs stow tmux nvim jq curl rsync tar node npm pi codex claude ob`.
- Verify `git lfs env` succeeds.
- Verify the configured login shell or print a clear manual command and treat
  the worker as incomplete until resolved.
- Return the verifier's nonzero status to Make.

### 6. Make tmux plugin installation and durability mandatory

TPM's `install_plugins` error is currently ignored. The save timer can
therefore be active while its target
`~/.config/tmux/plugins/tmux-resurrect/scripts/save.sh` does not exist.

Required work:

- Stop ignoring TPM installation failures for required plugins.
- Check the exact tmux-resurrect save entrypoint after installation.
- Check that the repository-owned workspace-resurrect plugin and hooks are
  readable.
- Run the save wrapper once as a postflight test with a temporary/private tmux
  server or another isolated test strategy.
- Confirm that both the normal Resurrect snapshot and workspace sidecar update.

### 7. Fix macOS launchd execution

The wrapper defaults to resolving `tmux` via `PATH`, while launchd does not
normally include Homebrew's bin directory. The wrapper intentionally exits zero
when tmux cannot be found, so the current job can appear healthy while never
saving anything.

Required work:

- Render the absolute result of `command -v tmux` into the launchd job, for
  example as `TMUX_RESURRECT_SAVE_TMUX_BIN`.
- Alternatively render an explicit, controlled PATH containing the selected
  Homebrew prefix; the absolute executable is preferred.
- Fail setup when the rendered tmux executable or Resurrect save script is not
  executable/readable.
- Test the wrapper using launchd's environment, not the provisioning shell's
  environment.
- Confirm the Mini's operational model maintains a GUI user domain after
  reboot. The job currently loads into `gui/$UID`; if the Mini can sit at the
  login window, decide between automatic login and a different service model.

## Required implementation tasks

All tasks in this section are required for installation readiness. “Required”
does not mean every convenience package is mandatory; it means the installer
must explicitly classify each dependency, implement the chosen behavior, and
verify the result instead of relying on an undocumented best effort.

### Unify the shared local and headless setup contract

The normal macOS setup and both headless lanes currently assemble overlapping
capabilities through different target/script sequences. That invites exactly
the drift exposed by this audit.

Required work:

- Introduce a shared CLI/package/config installation layer used by normal
  local setup and headless setup.
- Put `jq`, Git LFS, zsh, tmux, rsync, Tailscale, Node/fnm, provider CLIs,
  Neovim, shared dotfiles, TPM/plugins, `rw`, and worktree commands in that
  shared contract.
- Let normal local setup add GUI applications, workstation services, app
  settings, and macOS preferences after the shared layer.
- Let headless worker setup add the detached save timer, linger/launchd
  behavior, worker SSH key validation, and worker authentication checks after
  the shared layer.
- Keep focus-machine worker registration and per-pane orchestration out of the
  worker installer, but include them in the local/focus readiness workflow.
- Give the postflight doctor explicit `local`, `headless-macos`, and
  `headless-linux` profiles so shared checks cannot silently diverge while
  platform-specific exceptions remain intentional.

### Expose `rw` consistently

The plugin README says `make install` and `make install-headless` both link
`~/.local/bin/rw`, but only the full install currently does so.

Required work:

- Add the same idempotent `rw` link to the Makefile headless target and the
  Linux script's internal dotfile installer.
- Verify `rw --help` or an equivalent harmless command through a fresh shell.
- Do not pre-create authoritative endpoint/claim records. Runtime state should
  continue to be created lazily from real operations.

### Add an explicit focus-machine worker-registration workflow

The VPS installer cannot choose or register its own laptop-facing logical
alias. That would cross machine ownership boundaries and conflict with the
consume-never-provision design.

Required work:

- Document the manual registration pair:
  1. Add/test the logical alias in the focus machine's SSH configuration.
  2. Add the identical alias and platform to
     `tmux-remote-workspaces/config.json`.
- `agents-roll` was added to `config.json` on 2026-08-01. Add every future
  intended VPS through the same focus-machine registration step.
- Consider a read-only helper such as `rw doctor --candidate <alias>` that
  prints the JSON entry the operator could add, but does not edit config.
- Keep stable logical aliases independent of raw IPs and Tailscale addresses.

### Make Tailscale part of the default contract

Decision applied 2026-08-01: Linux headless setup now installs Tailscale by
default. `INSTALL_TAILSCALE=0` is an explicit escape hatch only for a
deliberately public/LAN-only worker. Both macOS Brewfiles already include
`tailscale-app`.

Required work:

- Treat the `tailscale` command as a required postflight check on Linux
  headless workers.
- Keep `tailscale up`/authentication a visible manual step unless an explicitly
  authorized reusable auth-key workflow is introduced.
- Verify the focus-machine logical SSH alias after Tailscale activation.
- Ensure the normal local installation retains Tailscale so shared networking
  capability does not drift between local and headless machines.
- Reconcile the macOS Brewfile description (“no GUI casks”) with its current
  `tailscale-app` cask. Either document the deliberate exception or choose a
  genuinely headless installation model.

### Remove destructive cleanup from ordinary setup

`brew bundle cleanup --force` can remove formulae or casks that were manually
installed on an existing Mini and are absent from `Brewfile.headless`.

Required work:

- Remove forced cleanup from the ordinary setup path.
- Make cleanup an explicit opt-in target.
- Show the cleanup plan before applying it and preserve a command for the
  operator to approve manually.

### Make setup idempotent

Required work:

- Replace unconditional `pipx install httpie` with install-or-upgrade logic;
  an already installed application must not fail a rerun.
- Test repeated Node/fnm, Python/pyenv, TPM, stow, timer, and SSH-key steps.
- Ensure reruns do not repeatedly overwrite the only useful `.bak` copy of a
  pre-existing configuration.
- Ensure existing SSH keys are retained and reported rather than regenerated.

### Complete Linux tool parity where configurations depend on it

The stowed Git configuration sets `delta` as its pager, but the Linux package
lane does not install Git Delta. This can make ordinary Git diff/log commands
fail even though Git itself passed verification.

Required work:

- Install Git Delta on supported Linux distributions, or conditionally render
  the Git pager configuration when Delta is available.
- Audit other stowed configs for unguarded dependencies.
- Keep guarded conveniences such as eza, bat/batcat, fd/fdfind, zsh plugins,
  trash tools, and prettyping optional unless promoted into the formal worker
  contract.
- Correct the README's “Linux package mirror” wording if full Brewfile parity
  is not intended.

### Define the supported Linux platform boundary

The package installer accepts apt, dnf, pacman, zypper, and apk, but the
durability implementation requires systemd user services. Alpine/OpenRC and
containers without a working user systemd instance do not meet that contract.

Required work:

- Decide whether v1 officially supports only systemd-based Linux workers.
- If yes, fail early and clearly on unsupported init/user-service
  environments, even if their package manager is recognized.
- If Alpine/OpenRC is required, implement and test an equivalent periodic
  worker save service before claiming support.
- Verify `systemctl --user` connectivity and linger, not merely the presence
  of the `systemctl` executable.

### Improve SSH and first-boot handling

Required work:

- Create `~/.ssh/sockets` in both macOS and Linux headless paths rather than
  waiting for a later zsh invocation.
- Set the directory and SSH config permissions explicitly.
- Treat an existing incoming SSH service as a stated VPS precondition, or add
  an explicit optional openssh-server provisioning step for console-based
  installs.
- Confirm the Mini's configured account (`alfierobertson`) before destructive
  reprovisioning, as required by the remote-workspace plan.
- Do not assume `sudo make setup-headless`; resolve `$HOME`, the target user,
  login-shell changes, linger, and service ownership consistently.

### Handle minimal VPS locale behavior

The zsh configuration forces `en_US.UTF-8`, which may not exist on minimal VPS
images.

Required work:

- Install/generate that locale on supported distributions, or use a detected
  available UTF-8 locale such as `C.UTF-8` when appropriate.
- Add the chosen locale to postflight output.

### Make repository path resolution robust

The Makefile derives `DOTFILES` from the current working directory. That works
for the documented invocation from the repo root but is fragile with `make -f`
or calls from another directory.

Required work:

- Resolve the repository from the Makefile's own location.
- Continue passing `-d "$DOTFILES_DIR"` to Stow where possible.
- Quote every path consistently.

## Proposed implementation sequence

### Phase 1: define and implement a headless postflight doctor

Build the validator first so every subsequent change has an executable
contract.

Proposed command:

```text
make headless-doctor
```

It should be read-only by default and check:

- OS, package manager, init/service environment, target user, home, and shell.
- Required commands in the current environment.
- Required commands under a minimal noninteractive environment.
- Dotfile links and Stow outputs.
- `~/.local/bin/rw`, `worktree-slot`, and `worktree-claim`.
- TPM and exact required plugin files.
- launchd/systemd timer loaded and active.
- Timer wrapper can resolve tmux and the Resurrect save entrypoint.
- SSH key presence and permissions, while reporting Git-host registration as a
  manual verification rather than attempting it.
- Provider command presence/version, while reporting authentication as a
  manual verification.

### Phase 2: repair PATH and first-run ordering

- Add common Homebrew/fnm activation suitable for noninteractive shells.
- Reuse it in Node consumers and remote provider probes.
- Fix Obsidian and Stripe first-run behavior.
- Prove clean macOS and Linux noninteractive command resolution.

### Phase 3: make platform setup fail fast

- Extract or restructure the macOS compound Make recipe.
- Split required and optional Linux packages.
- Stop swallowing required package and TPM failures.
- Run `headless-doctor` before any success banner.

### Phase 4: harden durability services

- Render an absolute Homebrew tmux path into launchd.
- Validate the GUI-domain/reboot assumption on the Mini.
- Require systemd user service plus linger on supported Linux.
- Exercise direct detached saves on both platforms.

### Phase 5: finish installation parity and safety

- Link `rw` in every headless path.
- Install or guard Git Delta.
- Fix pipx rerun behavior.
- Make Homebrew cleanup opt-in.
- Create SSH socket directories consistently.
- Validate default-on Tailscale installation/authentication reporting and
  decide the Linux-init support boundary.
- Add locale handling.

### Phase 6: document worker registration and rollout

- Document logical alias creation and local `config.json` registration.
- Keep all actual intended VPS aliases registered; `agents-roll` is the first
  Linux entry and future VPS instances require equivalent entries.
- Document Git-host key registration and provider logins.
- Update README statements to match the final supported platform matrix.

## Verification matrix

At minimum, test these environments from a clean account or disposable
machine:

| Environment | Required test |
| --- | --- |
| Apple Silicon macOS Mini | Fresh Homebrew install, noninteractive SSH PATH, launchd load, detached periodic save, reboot behavior, Xcode-worker account assumptions. |
| Ubuntu/Debian systemd VPS | apt packages, fnm first run, provider CLIs, Stow, systemd user timer, linger, logout/reboot behavior. |
| Fedora/RHEL-like systemd VPS | dnf package names, Stripe path, fnm/provider PATH, timer and linger. |
| Arch systemd VPS, if supported | pacman packages, npm Stripe fallback, timer and linger. |
| openSUSE systemd VPS, if supported | zypper packages, npm Stripe fallback, timer and linger. |
| Alpine/OpenRC, only if claimed | apk packages plus a real non-systemd durability implementation. Otherwise verify an early unsupported-platform failure. |

For each supported platform, run setup twice. The second run must succeed
without data loss, unnecessary reauthentication, duplicate services, or
replacement of the only useful backups.

## Acceptance tests

### Automated postflight

The following conceptual checks must all pass for the target user:

```sh
command -v zsh git git-lfs stow tmux nvim jq curl rsync tar tailscale
command -v node npm pi codex claude ob
command -v rw worktree-slot worktree-claim
test -x "$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh"
git lfs env >/dev/null
```

### Focus-to-worker noninteractive probe

Run from the laptop for every registered worker:

```sh
ssh <worker> 'command -v tmux git git-lfs jq node pi codex claude'
```

This must succeed without forcing an interactive shell and without output from
shell initialization.

### Timer validation

macOS:

```sh
launchctl print "gui/$UID/com.kalem.tmux-resurrect-save"
```

Linux:

```sh
systemctl --user is-enabled tmux-resurrect-save.timer
systemctl --user is-active tmux-resurrect-save.timer
loginctl show-user "$USER" -p Linger
```

Then create a disposable/private tmux session, detach it, wait for or manually
trigger the timer unit, and prove both Resurrect and workspace sidecar state
changed.

### Remote-workspace validation

1. Register the logical worker alias locally.
2. Register the same alias in `tmux-remote-workspaces/config.json`.
3. Register the worker's SSH key with the repository Git host.
4. Authenticate provider CLIs independently.
5. Run `rw doctor` from the focus machine.
6. Run `rw ensure --worker <alias>` from a disposable pane/repository.
7. Exercise SSH disconnect, endpoint reconnect, worker reboot/restore, dirty
   workspace handoff/return, and provider handoff in the order defined by the
   original remote-workspace smoke-test checklist.

## AI-agent smoke test: push, sync, prove (mini + agents-roll)

An AI agent (or the operator) runs this end-to-end from the focus machine to
prove that a worker provisioned from `origin/main` satisfies the full worker
contract. It is the headless-install counterpart of the smoke-test checklist
in `docs/tasks/tmux-remote-workspaces/initial-plan.md`, and covers only the
install path — the remote-workspace behaviors (`rw ensure`, handoff, reconnect)
stay in that checklist.

Agent execution rules:

- **Never run any tmux command against the focus machine's tmux server.**
  All tmux interaction happens on the worker over SSH, only ever creating and
  killing sessions named `smoke-*`, and only killing sessions this test
  created (`kill-session -t '=smoke-headless'` — the `=` forces exact match so
  prefix matching can never select another session; QUOTE the argument, since
  a zsh login shell on the worker otherwise intercepts the bare `=word` token
  as zsh EQUALS command-path expansion and tmux never sees it).
- Saves are non-destructive; never run a resurrect *restore* on a worker.
- Stop at the first failed REQUIRED step and report; do not improvise
  remediation beyond what the step names.
- Setup runs as the alias's login user (`mini` → `admin` since 2026-08-01,
  with NOPASSWD sudo; `agents-roll` → currently `root` per
  `ssh/.ssh/config`), never via `sudo make`. Note: running as root on
  `agents-roll` means `$HOME=/root`, root linger, and root-owned services —
  accepted for that VPS, but record it in the run report.
- **Assume no remote services are authenticated yet.** The only assumed
  credential is a working Git-host SSH key on each worker (git fetch/clone
  over SSH works). Tailscale, `claude`, `codex`, and `pi` are NOT logged in
  until the operator confirms otherwise. Presence/version checks still run;
  login-state checks do not.
- An auth-blocked or interactive-blocked step (sudo password prompt,
  `tailscale up`, provider logins, anything needing `ssh -t`) is **not a
  failure**: skip it, continue every step that doesn't depend on it, collect
  all blocked items, and report ONE consolidated operator checklist at the
  end of the run. The operator completes the checklist and confirms; only the
  blocked steps are then re-run.

### Phase A — publish (focus machine)

1. Confirm the implementation is committed and pushed directly to `main`:
   `git -C ~/Developer/dotfiles push origin main` (operator approval step —
   the agent must not push without explicit instruction). Then record
   `SHA=$(git -C ~/Developer/dotfiles rev-parse origin/main)`.
   REQUIRED: local `main` == `origin/main`.

### Phase B — per worker (run fully for `W=mini`, then `W=agents-roll`)

2. Reachability: `ssh $W true` exits 0. REQUIRED.
3. Locate the repo:
   `REPO=$(ssh $W 'for d in ~/Developer/dotfiles ~/dotfiles; do [ -d "$d/.git" ] && { echo "$d"; break; }; done')`.
   REQUIRED: non-empty. If empty, stop — clone per `docs/headless-workers.md`
   first.
4. Sync main safely:
   - `ssh $W "git -C $REPO status --porcelain"` must be EMPTY. If dirty,
     STOP and report — never `reset --hard` a dirty worker tree without
     operator approval.
   - `ssh $W "git -C $REPO fetch origin && git -C $REPO checkout main && git -C $REPO reset --hard origin/main"`
   - REQUIRED: `ssh $W "git -C $REPO rev-parse HEAD"` == `$SHA`. Record the
     SHA in the run report (installation is attributable to this revision).
5. Provision: `ssh -t $W "cd $REPO && make setup-headless"`.
   REQUIRED: exit 0, and the postflight doctor SUMMARY line reports
   `result=PASS` before the success banner. A nonzero exit with a named
   failing check is a correct failure — report it verbatim.
6. Doctor, noninteractively: `ssh $W "cd $REPO && make headless-doctor"`.
   REQUIRED: exit 0. (This itself proves the doctor and its toolchain resolve
   under a noninteractive SSH shell.)
7. Noninteractive command probe (the formal acceptance test):
   `ssh $W 'command -v zsh git git-lfs stow tmux jq curl rsync tar node npm pi codex claude nvim ob rw worktree-slot worktree-claim'`
   REQUIRED: every command resolves; output is ONLY paths (no shell-init
   noise). `tailscale` REQUIRED too unless the worker was provisioned with
   `INSTALL_TAILSCALE=0`.
8. Git LFS: `ssh $W 'git lfs env >/dev/null && echo LFS_OK'` → `LFS_OK`.
   REQUIRED.
9. Durability timer:
   - `mini` (launchd):
     - `ssh mini 'launchctl print "gui/$(id -u)/com.kalem.tmux-resurrect-save" >/dev/null && echo LOADED'`
       → `LOADED`. REQUIRED.
     - Wrapper self-check under a launchd-like environment:
       `ssh mini 'P=~/Library/LaunchAgents/com.kalem.tmux-resurrect-save.plist; WRAP=$(plutil -extract ProgramArguments.0 raw "$P"); BIN=$(plutil -extract EnvironmentVariables.TMUX_RESURRECT_SAVE_TMUX_BIN raw "$P"); env -i HOME="$HOME" PATH=/usr/bin:/bin TMUX_RESURRECT_SAVE_TMUX_BIN="$BIN" "$WRAP" --check'`
       REQUIRED: exit 0. (If `ProgramArguments.0` is an interpreter rather
       than the wrapper, use `ProgramArguments.1`.)
   - `agents-roll` (systemd; prefix with
     `XDG_RUNTIME_DIR=/run/user/$(id -u)` if `systemctl --user` cannot
     connect over plain SSH):
     - `ssh agents-roll 'systemctl --user is-enabled tmux-resurrect-save.timer && systemctl --user is-active tmux-resurrect-save.timer'`
       REQUIRED: both succeed.
     - `ssh agents-roll 'loginctl show-user "$USER" -p Linger'` →
       `Linger=yes`. REQUIRED.
10. Detached save-chain proof (disposable, worker's default tmux server):
    - Record baseline: newest file mtime in
      `~/.local/share/tmux/resurrect/` and last line of
      `~/.local/state/tmux-workspace-resurrect/workspace-resurrect.log`.
    - `ssh $W 'tmux new-session -d -s smoke-headless'`
    - Trigger the timer unit directly (no waiting):
      - mini: `ssh mini 'launchctl kickstart "gui/$(id -u)/com.kalem.tmux-resurrect-save"'`
      - agents-roll: `ssh agents-roll 'systemctl --user start tmux-resurrect-save.service'`
    - REQUIRED: within ~30s the resurrect snapshot (`last` target) mtime
      advances AND the workspace sidecar log gains a new
      `saved N pane records` line — this proves the whole chain runs with no
      attached client.
    - Clean up: `ssh $W 'tmux kill-session -t =smoke-headless'`.
11. Rerun idempotency:
    - Record before: `ssh $W 'ssh-keygen -lf ~/.ssh/id_ed25519.pub'` and
      `ssh $W 'ls ~/.zshrc.bak 2>/dev/null; ls ~/.gitconfig.bak 2>/dev/null'`.
    - `ssh -t $W "cd $REPO && make setup-headless"` a second time.
      REQUIRED: exit 0.
    - REQUIRED: SSH key fingerprint unchanged; any pre-existing `.bak` files
      unchanged (first-backup protection); no duplicated timers/services
      (`launchctl print`/`systemctl --user list-timers` show exactly one).
12. Provider presence (auth stays manual):
    `ssh $W 'claude --version; codex --version; pi --version'` — REQUIRED to
    resolve and print versions. Whether each is *authenticated* is reported
    as a manual verification, not tested here.
13. Linux-only parity spot-checks (`agents-roll`):
    - `ssh agents-roll 'command -v delta || echo DELTA-MISSING'` — if
      missing, WARN (git's pager config depends on it; optional-with-loud-
      warning by design).
    - `ssh agents-roll 'locale 2>&1 | grep -i "cannot" || echo LOCALE_OK'` →
      `LOCALE_OK`. WARN otherwise, and record the fallback locale chosen.

### Phase C — focus-machine follow-through

14. `rw doctor` from the laptop: REQUIRED that both `mini` and `agents-roll`
    report healthy/reachable.
15. Hand off to the remote-workspace smoke-test checklist in
    `docs/tasks/tmux-remote-workspaces/initial-plan.md` ("Worker provisioning
    + live smoke tests") for `rw ensure`, reconnect, reboot/restore, and
    handoff validation — out of scope for this install test.

Run report: for each worker, a pass/fail line per numbered step, the synced
commit SHA, and every WARN with its recorded detail. Both workers passing
steps 2-13 plus step 14 constitutes proof that `make setup-headless` from
`origin/main` produces contract-satisfying workers.

## Manual steps that should remain manual

- Choosing the worker's logical alias and adding it to focus-machine config.
- Registering the worker's public SSH key with GitHub/GitLab.
- Authenticating Tailscale unless an explicit auth-key workflow is approved.
- Authenticating Claude, Codex, and Pi on the worker.
- Confirming the Mini account identity, GUI login/reboot model, Xcode license,
  Simulator/signing/keychain requirements, and Remote Login configuration.
- Approving any Homebrew cleanup after reviewing what it would remove.

## Current validation evidence

- Bash syntax checks passed for the relevant setup and timer scripts.
- The launchd plist template passed `plutil -lint`.
- ShellCheck reported one minor warning: `mkdir -p -m 700` only guarantees the
  mode on the deepest created directory. This should be replaced with an
  explicit `mkdir -p` followed by `chmod 700` for clarity.
- `systemd-analyze verify` was unavailable in the macOS audit environment, so
  unit syntax still needs validation on Linux.
- Full installers were not executed during the audit because they install
  packages, change shells/services, and can invoke destructive Homebrew
  cleanup.
- A `make -n setup-headless` audit demonstrated that the current Darwin recipe
  is not a safe dry run: it invoked sudo and reached outer-recipe operations.
