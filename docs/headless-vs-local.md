# Headless vs. Local Installation

This is a conceptual/reference doc: how `make setup-headless` differs from
`make setup`, and why. For the operational provisioning runbook (how to
actually bring up a worker), see `docs/headless-workers.md`.

## One shared contract, two consumers

This repo maintains one shared CLI/dotfile/provider contract that both
`make setup` (full local install) and `make setup-headless` (headless worker
install) consume. By design, a headless machine should receive the same
terminal, Git, editor, provider, dotfile, networking, and `rw` capabilities
as a local machine unless the local machine has a deliberate
platform-specific alternative. The normal local setup may add GUI
applications and focus-machine integration; it must not be a weaker CLI
installation than headless setup.

In practice: headless is a strict CLI subset of local, plus a small set of
worker-specific durability mechanisms (save timers, linger) that local
machines don't need because a local machine always has a tmux client
rendering. Headless is never a *weaker* CLI install than local — where the
two differ, it's either GUI/workstation-only material that headless
correctly omits, or a worker-only concern that local correctly omits.

## What each install does

| Aspect | Full local (`make setup`) | Headless (`make setup-headless`) |
| --- | --- | --- |
| Entry point & target chain | `make setup` → `brew neovim node obsidian python macos install misc`, then `make reload` | `make setup-headless` dispatches on `uname -s`: Darwin → `setup/macos-headless.sh` (runs `brew-headless python neovim node obsidian install-headless misc-headless headless-doctor` via `make`); Linux → `setup-linux-headless-run` (`setup/linux-headless.sh`) then `headless-doctor` |
| Package manager & bundle file | Homebrew, `Brewfile` | macOS: Homebrew, `Brewfile.headless` (`make brew-headless` / `BREWFILE_HEADLESS=1 ./setup/brew.sh`). Linux: no Homebrew — distro package manager (apt/dnf/pacman/zypper/apk) with package lists hardcoded in `setup/linux-headless.sh`, not a Brewfile |
| CLI packages | `Brewfile`'s `brew` lines | Nearly identical to local. `Brewfile.headless` matches `Brewfile`'s CLI package list except it omits `cameroncooke/axe/axe`, `git-gui`, and `felixkratz/formulae/sketchybar` (the sketchybar formula, tied to the GUI bar) — everything else CLI-wise is the same. Linux headless installs its own required/optional package split per distro (see `setup/linux-headless.sh`), not a mirror of `Brewfile.headless` |
| GUI casks | `Brewfile` installs 19 casks: `aerospace`, `android-platform-tools`, `arc`, `chromium`, `cursor`, `orbstack`, `figma`, three fonts, `ghostty`, `kindavim`, `ngrok`, `obsidian`, `raycast`, `sf-symbols`, `spotify`, `superwhisper`, `tailscale-app`, `visual-studio-code` | `Brewfile.headless` installs exactly one cask: `tailscale-app`. The file's header comment explains why: "macOS Tailscale's auth/system-extension flow works best through the app (not the bare `tailscale` CLI/daemon), so it is installed even on headless workers." No other GUI app, font, or VS Code/Cursor extension is installed |
| Direct `~/.config` links | `CONFIG_PACKAGES := aerospace ghostty nvim sketchybar tmux` (Makefile) | `HEADLESS_CONFIG_PACKAGES := nvim tmux` (Makefile) — GUI-only packages (`aerospace`, `ghostty`, `sketchybar`) dropped |
| Stow packages | `STOW_PACKAGES := claude codex eza git kindavim pi ssh vim worktrees zsh` (Makefile) | `HEADLESS_STOW_PACKAGES := claude codex eza git pi ssh vim worktrees zsh` (Makefile) — the only difference is `kindavim`, a macOS GUI keyboard-remapper preference plist, correctly excluded |
| macOS system preferences | `make macos` (`setup/macos.sh`) runs as part of the `setup` chain | Not run. No headless chain calls `macos` |
| tmux durability mechanism | tmux-continuum's status-line `#()` autosave interpolation calls the shared verified wrapper; `prefix C-s` calls it immediately and updates the powerline only after both Resurrect and workspace sidecar validation | Headless macOS: a launchd job (`com.kalem.tmux-resurrect-save`) with an absolute Homebrew tmux path baked in as `TMUX_RESURRECT_SAVE_TMUX_BIN` (launchd's own PATH lacks Homebrew's bin dir). Headless Linux: a systemd `--user` timer (`tmux-resurrect-save.timer`, `OnUnitActiveSec=5min`) plus `loginctl enable-linger` so the user's systemd instance keeps running with no login session. Both timers use the same verified wrapper; an rw-focused `prefix C-s` also invokes it immediately on that worker. |
| Provider auth | Interactive, done once on the local machine | Independent per worker — never copied from the focus machine or any other host. Each of `claude`, `codex`, and `pi` must be authenticated on the worker itself (manual step, see `docs/headless-workers.md`) |
| Tailscale | Included in `Brewfile` (`tailscale-app` cask); `tailscale up` is a manual step | Default-on on both platforms. macOS: `tailscale-app` cask via `Brewfile.headless`. Linux: installed via `setup/linux-headless.sh`'s `install_tailscale` (the official install script) unless `INSTALL_TAILSCALE=0` is set. `tailscale up`/authentication stays a manual step on every platform |
| Postflight validation | None — `make setup` has no equivalent gate | `make headless-doctor` (`setup/headless-doctor.sh`), profile-aware (`local`, `headless-macos`, `headless-linux`, auto-detected from `uname -s`), read-only, and gates the success banner: `setup-linux-headless` is literally `setup-linux-headless-run headless-doctor` in the Makefile, and `setup/macos-headless.sh` runs `headless-doctor` as its last step before printing "Headless setup complete!" |
| Linux init-system boundary | N/A (macOS only) | v1 is systemd-only. `setup/linux-headless.sh`'s `check_systemd_support` runs first, before `detect_package_manager`/any package install, and exits nonzero if `systemctl` is missing or `systemctl --user show-environment` can't connect — Alpine/OpenRC and non-systemd containers fail fast rather than reaching a partially-provisioned state |

## Known parity gaps

These are durable, currently-true facts about where headless and local (or
Linux and macOS headless) still diverge, as of this writing.

1. **`gh` (GitHub CLI).** FIXED. Installed on macOS headless via
   `Brewfile.headless` (`brew "gh"`). On Linux, `setup/linux-headless.sh`
   installs `gh` as a **required** package on apt, dnf, and pacman; on
   zypper it is listed as **optional** with an explicit comment ("unlike
   apt/dnf/pacman we are not confident it ships in every openSUSE default
   repo config") so a miss degrades to a warning rather than aborting the
   whole install; on apk it is likewise optional, because `gh` lives in
   Alpine's `community` repo, which is not guaranteed to be enabled (moot in
   practice today, since `check_systemd_support` already rejects
   non-systemd Alpine hosts before package installation is reached).
   `headless-doctor.sh`'s `REQUIRED_CMDS` includes `gh`.

   The same forensic audit that closed this gap (2026-08-02) found the same
   under-the-radar shape recurring elsewhere — see "The parity guard" below
   for the structural fix, and this same list for what else it caught:
   - `delta` (git-delta) was OPTIONAL on Linux and absent from
     `headless-doctor.sh`'s `REQUIRED_CMDS`, even though `git/.gitconfig`
     unconditionally sets `pager = delta` — a missing delta broke ordinary
     `git log`/`git diff` outright. FIXED: `git-delta` is now REQUIRED on
     apt/dnf/pacman/zypper (package name confirmed via `apt-cache policy
     git-delta` on agents-roll, Ubuntu 24.04 — already installed there,
     0.16.5-5, from the `universe` repo), OPTIONAL on apk under the name
     `delta` (same treatment as `gh`'s apk branch, and similarly moot since
     that branch is unreachable). `headless-doctor.sh`'s `REQUIRED_CMDS` now
     includes `delta`.
   - `eza` was promised as a Linux convenience in this doc and in
     `README.md` but was in no Linux package list, and confirmed MISSING on
     the live worker (`agents-roll`). FIXED by installing it: `apt-cache
     policy eza` on agents-roll showed it available (candidate 0.18.2-1,
     `universe` repo, just not installed) — a real, low-risk convenience, so
     it was added to the OPTIONAL package list on all five Linux package
     managers rather than walking back the README's promise.
   - `zsh-autosuggestions` had a hardcoded Linux distro fallback path in
     `zsh/.zshrc` but was never installed by `setup/linux-headless.sh`, and
     was confirmed absent on the worker. FIXED by installing it: `apt-cache
     policy zsh-autosuggestions` on agents-roll showed it available
     (0.7.0-1, `universe`), so it was added to the OPTIONAL list on all five
     managers.
   - `zsh-vi-mode` has the same kind of `zsh/.zshrc` fallback path, but is
     NOT packaged by apt on Ubuntu 24.04 (confirmed absent via both
     `apt-cache policy zsh-vi-mode` and `apt-cache search zsh-vi-mode`, no
     output either way) — jeffreytse/zsh-vi-mode has no distro package on
     any mainstream Linux package manager. FIXED by correcting the
     documentation instead of installing: `zsh/.zshrc`'s plugin-loading
     comment no longer implies zsh-vi-mode is distro-packaged on Linux; its
     `source_if_exists` fallback paths (including a manual
     `~/.zsh/zsh-vi-mode/` clone location) remain and degrade silently when
     absent, same as before.
   - `pyenv`'s PATH export lived only in `zsh/.zshrc` (interactive-only), so
     the binary existed on disk (`~/.pyenv/bin/pyenv`, confirmed present on
     agents-roll) but never resolved under a noninteractive shell — the same
     failure mode `zsh/.zshenv` already solves for `~/.local/bin` and fnm.
     FIXED: `zsh/.zshenv` now exports `PYENV_ROOT` and prepends
     `$PYENV_ROOT/bin` to `PATH`, following the exact pattern already used
     for fnm's bootstrap directory in that file. `zsh/.zshrc`'s own
     `eval "$(pyenv init -)"` block is unchanged and stays interactive-only
     (shell function wrapping/completion, not something a noninteractive
     shell needs).

2. **Provider config parity.** PARTLY FIXED. The three provider CLIs still
   ship very different first-run experiences via their stowed dotfiles:
   - `claude`'s shipped `claude/.claude/settings.json` now includes a
     `"theme": "dark"` key, so theme selection is no longer a first-run
     prompt.
   - `codex` ships no `config.toml` in its stowed package **by design** —
     codex writes project-trust entries and other machine-specific cache
     state straight into that exact file, so symlinking it via stow would
     guarantee permanent working-tree dirt. `codex/.codex/` ships only
     `hooks.json` and `AGENTS.md`. Instead, `setup/lib.sh`'s
     `seed_codex_config()` copies `setup/templates/codex-config.toml` to
     `~/.codex/config.toml` **only when that file does not already exist**
     — it never overwrites an existing one. This is called from both
     `make install` / `make install-headless` (the Makefile's `install`/
     `install-headless` targets) and from `setup/linux-headless.sh`'s
     `install_headless_dotfiles`. Net effect: a brand-new machine gets the
     template's theme/model/status-line defaults and skips the first-run
     wizard; an existing machine's `~/.codex/config.toml` (with its trust
     entries and caches) is left completely alone by every rerun. Editing
     the template therefore only ever affects machines that have never been
     provisioned before.
   - `pi` ships `pi/.pi/agent/settings.json` with `"theme": "personal"` plus
     the theme definition itself at `pi/.pi/agent/themes/personal.json`, so
     it applies instantly with no prompt.

3. **Write-back through stow symlinks.** `~/.claude/settings.json` and
   `~/.pi/agent/settings.json` are symlinks straight into this tracked repo
   (via the `claude` and `pi` stow packages). Any runtime write those CLIs
   make — a theme change, a model fallback, anything they persist to their
   own settings file — writes through the symlink and dirties the dotfiles
   working tree on every machine that has them stowed. This was observed
   live on both workers (`mini`, `agents-roll`) on 2026-08-02. Operational
   consequence: the worker-sync procedure in `docs/headless-workers.md`'s
   full validation section requires a clean tree
   (`git status --porcelain` must be empty) before syncing `main` — a worker
   whose tree got dirtied by a provider's own runtime write will halt the
   next provisioning run until the dirtied file is checked out or committed.

   `setup/headless-doctor.sh` now has a non-fatal check for exactly this,
   `drift:provider-settings` (section 11, "Provider settings write-back
   drift"). It runs `git -C <dotfiles> status --porcelain -- <paths>` against
   `claude/.claude/settings.json` and `pi/.pi/agent/settings.json` and:
   - `c_optpass`es (PASS, optional) when both files are clean;
   - `c_warn`s — never `c_fail`s — when either has uncommitted changes,
     listing which file(s) drifted and the exact remediation:
     `git -C <repo> checkout -- claude/.claude/settings.json pi/.pi/agent/settings.json`.
   - degrades to a WARN (not a crash) when `git` is missing or
     `$DOTFILES_DIR` isn't a git repository.

   It is deliberately a WARN, not a FAIL: a worker where someone simply
   launched `claude` or `pi` once must not go doctor-red over an expected
   side effect of normal CLI use. The check exists so the drift is visible
   in doctor output (and thus caught before it silently blocks a `main`
   sync per the worker-sync procedure above), not to gate provisioning
   success on it.

## Why the durability mechanisms differ

tmux-continuum's autosave isn't a background service — it's a status-line
`#()` command interpolation (`continuum_save.sh`) that tmux itself re-runs
every time the status line redraws. That only happens while a client is
attached and rendering the status bar. A fully detached worker tmux server
has no client, so the status line never redraws, and the interpolation never
fires — hence the separate launchd/systemd timers described above, which
invoke the save script directly and don't depend on any client being
attached.

All four triggers now converge on `tmux/scripts/resurrect_save.sh`: local
Continuum, a clean client detach, the headless timer, and the manual
`prefix C-s` binding. The wrapper serializes overlapping attempts, validates
the authoritative Resurrect snapshot and the freshly replaced
workspace-resurrect sidecar, and only then records the completion timestamp.
For an rw-backed focused pane the manual dispatcher first verifies the outer
laptop save and then invokes the same wrapper over SSH on that pane's worker.
It writes the confirmed worker timestamp directly into the powerline cache,
so a success renders `0m` immediately. The fixed headless timer cadence does
not move; local Continuum measures its next interval from the manual save.

There's a related trap, discovered on 2026-08-01: tmux-continuum refuses to
even arm that interpolation in the first place whenever any other tmux
process is running on the machine besides the server's own attached clients
(`another_tmux_server_running`, `tmux/plugins/tmux-continuum/continuum.tmux`,
checked before the status-right update at the point it would otherwise set
the interpolation). Every `source-file` re-runs the full config (including
catppuccin, which rewrites `status-right`), so a single orphaned tmux
process — an isolated test harness, a stray `tmux new-session -d` left over
from a test run — leaves autosave silently disarmed after the very next
config reload, with no error printed anywhere. `rw doctor`
(`tmux/local-plugins/tmux-remote-workspaces/scripts/rw-doctor.sh`) now
checks for exactly this: it inspects `status-right` for the
`continuum_save.sh` interpolation, checks the age of the last recorded save,
and separately counts stray `tmux` processes against attached clients using
the same comparison continuum's own `another_tmux_server_running` uses, so a
disarmed-but-otherwise-healthy-looking worker gets flagged with its cause.

## Platform support boundary

Headless v1 is verification-tested on macOS (Apple Silicon) and
Ubuntu/Debian systemd hosts only — the two workers exercised end-to-end by
the smoke campaign (`mini`, macOS/Apple Silicon; `agents-roll`, Ubuntu
24.04). Fedora/RHEL, Arch, and openSUSE are recognized by
`setup/linux-headless.sh`'s package-manager detection (`dnf`, `pacman`,
`zypper` are all valid branches with their own package lists) but were never
verification-tested end-to-end. Alpine/OpenRC is explicitly out of contract
for v1: the durability timer requires a working `systemd --user` instance,
and `check_systemd_support` deliberately fails fast on any host — Alpine or
otherwise — that lacks one, before any package is installed.

## Other deliberate safety defaults

- **Homebrew cleanup is opt-in, not automatic.** `brew bundle cleanup
  --force` can remove formulae or casks that were installed manually and
  are simply absent from the Brewfile. Neither `make setup` nor
  `make setup-headless` calls it. `make brew-cleanup` (and its
  `brew-cleanup-headless` counterpart) only prints what would be removed;
  applying it requires the separate, explicit `make brew-cleanup-force` /
  `make brew-cleanup-headless-force`.
- **A required step failing never produces a success banner.** Both
  install chains gate their final "complete" message on
  `headless-doctor`/postflight passing, so a failed required package,
  dotfile, plugin, PATH, or timer step is always visible as a nonzero
  exit, never masked by a later step that happened to succeed.

## The tool-parity guard

The root cause behind the `gh`/`delta`/`eza`/`zsh-autosuggestions` gaps above
is structural, not a one-off oversight: `Brewfile.headless`,
`setup/linux-headless.sh`'s `required=()`/`optional=()` package arrays, and
`setup/headless-doctor.sh`'s `REQUIRED_CMDS` are three independently
hand-maintained lists. Nothing forces them to agree, so a tool added to one
can silently never make it into the others — which is exactly how `gh`
shipped on macOS headless, was absent from every Linux package list, and was
never checked by the doctor, all while the doctor still reported 61/61.

`setup/check-tool-parity.sh` is a read-only maintenance script that closes
that gap mechanically. It extracts tool names from all three sources,
canonicalizes formula/package-name variants to one identity per tool (a
single commented table in the script handles cases like `git-delta`/`delta`,
`neovim`/`nvim`, `universal-ctags`/`ctags`, `ripgrep`/`rg`,
`fd-find`/`fd`/`fdfind`-on-Debian, `bat`/`batcat`-on-Debian, and the
per-package-manager build-toolchain/openssh naming variants), then runs
three checks:

1. Every Brewfile.headless tool has *some* Linux package-list entry
   (required or optional) — catches the eza/zsh-autosuggestions shape.
2. Every Linux **required** package resolves to a `headless-doctor.sh`
   `REQUIRED_CMDS` check — catches the gh/delta shape (a package whose
   absence is fatal to the worker contract, but that nothing actually
   verifies post-install).
3. Every `headless-doctor.sh` `REQUIRED_CMDS` entry traces back to either
   source — catches a stale/orphaned doctor check with no real install path
   behind it.

Any divergence not listed in `setup/tool-parity-exceptions.txt` (one name
per line, plus a one-line reason) fails the script loudly with a nonzero
exit. The allowlist's existing categories: macOS/Xcode-only tools correctly
absent from Linux (`cocoapods`, `fastlane`, `swift`, `watchman`, `rbenv`);
things installed by a mechanism other than the package arrays (`fnm`,
`pyenv`, `tailscale`, `stripe-cli`, `yarn`, `docker`, `docker-compose`,
`node`, `npm`, `pi`, `codex`, `claude`, `ob`); native-build-toolchain/
trust-store packages that are required but not part of the interactive
command contract (`ca-certificates`, `make`, `gcc`, `g++`, `pkg-config`,
`base-devel`, `build-base`); things disabled everywhere (`zsh-autocomplete`);
things not packaged by any mainstream distro (`zsh-vi-mode`); and
known-accepted, deliberately-deferred Linux gaps kept visible as TODOs
(`actionlint`, `ast-grep`, `atac`, `cmatrix`, `git-filter-repo`, `glow`,
`go`, `lazydocker`, `prettyping`, `recall`, `sl`, `sshs`, `supabase`,
`trash-cli`, `uv`, `webp`, `httpd`).

Run it with `make check-tool-parity`. **The rule going forward:** adding a
tool to `Brewfile.headless` means also adding it to the Linux package lists
and to `headless-doctor.sh` (if it's part of the required command contract),
or adding it to `setup/tool-parity-exceptions.txt` with a reason if the
absence is intentional.

It is deliberately **not** wired into `setup`/`setup-headless` as a hard
gate — see the comment on the Makefile's `check-tool-parity` target. This is
a maintenance check for whoever is editing those three files, not a
worker-provisioning precondition; failing a real provisioning run over a
missing convenience-tool doctor check would be worse than the disease it
prevents.

## See also

- `docs/headless-workers.md` — the operational provisioning runbook: how to
  actually bring up and register a worker.
- `README.md` — quick start for both local and headless setup.
