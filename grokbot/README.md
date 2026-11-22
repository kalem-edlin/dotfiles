# grokbot

Canonical config for Kalem's Grok Bot bots. The files here are the source of truth. Grok Bot does not load them on its own.

## How the files get loaded

- Each bot clones this repo on its computer at `/home/box/dotfiles` and runs `git pull` at the start of a thread.
- Each bot has one saved rule (Grok Bot memory, which is in context every turn and survives compaction): "At the start of every substantive turn, read `grokbot/AGENTS.md` and `grokbot/<bot>/AGENTS.md`."
- Hosted Grok Bot bots don't auto-load an `AGENTS.md`, `~/.grok` or `.agents/` file, so symlinks don't help here.

## Layout

- `AGENTS.md`: global rules for every Grok Bot bot.
- `<bot>/AGENTS.md`: that bot's charter (responsibilities, ownership, intent, decisions log).
- `<bot>/skills/<skill>/SKILL.md`: canonical skills for that bot. Curator mirrors them into Grok Bot's skill library when they change. Grok Bot's library can't be symlinked.
- `<bot>/STATE.md`: config that lives in Grok Bot rather than in files (saved rules, routines, connectors, linked machines). Curator keeps it current so nothing that shapes a bot is hidden.

## Adding a bot

1. Create `grokbot/<bot>/AGENTS.md`.
2. Ask Curator to create or seed the bot. Curator gives it the one saved rule that points at its folder, then writes its `STATE.md`.
