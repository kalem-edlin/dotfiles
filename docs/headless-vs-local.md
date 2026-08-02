# Headless vs. Local Installation

This is a conceptual/reference doc: how `make setup-headless` differs from
`make setup`, and why. For the operational provisioning runbook (how to
actually bring up a worker), see `docs/headless-workers.md`.

## One shared contract, two consumers

This repo maintains one shared CLI/dotfile/provider contract that both
`make setup` (full local install) and `make setup-headless` (headless worker
install) consume. Per `docs/tasks/headless-install.md`'s "Purpose" section, a
headless machine should receive the same terminal, Git, editor, provider,
dotfile, networking, and `rw` capabilities as a local machine unless the
local machine has a deliberate platform-specific alternative. The normal
local setup may add GUI applications and focus-machine integration; it must
not be a weaker CLI installation than headless setup ("Installation parity
and ownership").

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
| Stow packages | `STOW_PACKAGES := claude codex git kindavim pi ssh vim worktrees zsh` (Makefile) | `HEADLESS_STOW_PACKAGES := claude codex git pi ssh vim worktrees zsh` (Makefile) — the only difference is `kindavim`, a macOS GUI keyboard-remapper preference plist, correctly excluded |
| macOS system preferences | `make macos` (`setup/macos.sh`) runs as part of the `setup` chain | Not run. No headless chain calls `macos` |
| tmux durability mechanism | Relies on tmux-continuum's status-line `#()` autosave interpolation, because a local machine always has a tmux client attached and rendering the status line | Headless macOS: a launchd job (`com.kalem.tmux-resurrect-save`) with an absolute Homebrew tmux path baked in as `TMUX_RESURRECT_SAVE_TMUX_BIN` (launchd's own PATH lacks Homebrew's bin dir). Headless Linux: a systemd `--user` timer (`tmux-resurrect-save.timer`, `OnUnitActiveSec=5min`) plus `loginctl enable-linger` so the user's systemd instance keeps running with no login session |
| Provider auth | Interactive, done once on the local machine | Independent per worker — never copied from the focus machine or any other host. Each of `claude`, `codex`, and `pi` must be authenticated on the worker itself (manual step, see `docs/headless-workers.md`) |
| Tailscale | Included in `Brewfile` (`tailscale-app` cask); `tailscale up` is a manual step | Default-on on both platforms. macOS: `tailscale-app` cask via `Brewfile.headless`. Linux: installed via `setup/linux-headless.sh`'s `install_tailscale` (the official install script) unless `INSTALL_TAILSCALE=0` is set. `tailscale up`/authentication stays a manual step on every platform |
| Postflight validation | None — `make setup` has no equivalent gate | `make headless-doctor` (`setup/headless-doctor.sh`), profile-aware (`local`, `headless-macos`, `headless-linux`, auto-detected from `uname -s`), read-only, and gates the success banner: `setup-linux-headless` is literally `setup-linux-headless-run headless-doctor` in the Makefile, and `setup/macos-headless.sh` runs `headless-doctor` as its last step before printing "Headless setup complete!" |
| Linux init-system boundary | N/A (macOS only) | v1 is systemd-only. `setup/linux-headless.sh`'s `check_systemd_support` runs first, before `detect_package_manager`/any package install, and exits nonzero if `systemctl` is missing or `systemctl --user show-environment` can't connect — Alpine/OpenRC and non-systemd containers fail fast rather than reaching a partially-provisioned state |

## Known parity gaps

These are durable, currently-true facts about where headless and local (or
Linux and macOS headless) still diverge, as of this writing.

1. **`gh` (GitHub CLI).** Installed on macOS headless via `Brewfile.headless`
   (`brew "gh"`). On Linux, `setup/linux-headless.sh` now installs `gh` as a
   **required** package on apt, dnf, and pacman; on zypper it is listed as
   **optional** with an explicit comment ("unlike apt/dnf/pacman we are not
   confident it ships in every openSUSE default repo config") so a miss
   degrades to a warning rather than aborting the whole install; on apk it is
   likewise optional, because `gh` lives in Alpine's `community` repo, which
   is not guaranteed to be enabled (moot in practice today, since
   `check_systemd_support` already rejects non-systemd Alpine hosts before
   package installation is reached).

2. **Provider config parity.** The three provider CLIs ship very different
   first-run experiences via their stowed dotfiles:
   - `claude`'s shipped `claude/.claude/settings.json` now includes a
     `"theme": "dark"` key, so theme selection is no longer a first-run
     prompt.
   - `codex` ships only `codex/.codex/hooks.json` and
     `codex/.codex/AGENTS.md` — no settings/config file and no theme key at
     all — so a first-run wizard is effectively guaranteed on every fresh
     machine.
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
   consequence: the worker-sync procedure in
   `docs/tasks/headless-install.md`'s smoke test requires a clean tree
   (`git status --porcelain` must be empty) before syncing `main` — a worker
   whose tree got dirtied by a provider's own runtime write will halt the
   next provisioning run until the dirtied file is checked out or committed.

## Why the durability mechanisms differ

tmux-continuum's autosave isn't a background service — it's a status-line
`#()` command interpolation (`continuum_save.sh`) that tmux itself re-runs
every time the status line redraws. That only happens while a client is
attached and rendering the status bar. A fully detached worker tmux server
has no client, so the status line never redraws, and the interpolation never
fires — hence the separate launchd/systemd timers described above, which
invoke the save script directly and don't depend on any client being
attached.

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

## See also

- `docs/headless-workers.md` — the operational provisioning runbook: how to
  actually bring up and register a worker.
- `README.md` — quick start for both local and headless setup.
