# grokbot

Canonical config for Kalem's Grok Bot bots. Curator maintains this folder.

## How it loads

- Grok Bot does not auto-load files from disk. Each bot has one saved rule in its Grok Bot memory, which is in context every turn and survives compaction: "At the start of every substantive turn, read `grokbot/AGENTS.md` and `grokbot/<bot>/AGENTS.md`."
- The repo is cloned at `/home/box/dotfiles` on the Grok Bot computer, which every bot shares, and is refreshed with `git pull`.

## Layout

- `AGENTS.md`: global rules for every bot.
- `<bot>/AGENTS.md`: always loaded for that bot. Keep it short and point to other files with a line on when to read each one.
- `<bot>/*.md`: progressively disclosed resources, read only when `AGENTS.md` says to.
- `<bot>/skills/<skill>/SKILL.md`: canonical skills, which Curator mirrors into Grok Bot's skill library.
