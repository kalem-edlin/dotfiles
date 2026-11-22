# What lives inside Grok Bot vs in files

Grok Bot holds some config that can't be a file. Curator reflects it here and changes it only through Grok Bot's own tools.

| Thing | Where it lives | Visible to other bots | Notes |
|---|---|---|---|
| Saved rules, facts, workstreams (memory) | Grok Bot, per bot | No | Always in that bot's context. Holds only the loader rule plus small facts, and the real rules go in `AGENTS.md`. |
| Shared profile facts | Grok Bot, per user | Yes | Name, timezone, role. |
| Routines (scheduled/triggered prompts) | Grok Bot, per bot | No | Each routine's prompt should point at a skill or file here. |
| Skills | Grok Bot skill library (shared) or per bot | Shared ones are | Canonical copy in `<bot>/skills/`, mirrored by Curator. |
| Connectors (Gmail, Slack, Linear...) | Grok Bot account | Yes | Installed and authenticated through the app. |
| Linked machines | Grok Bot app on that machine | Yes | Commands need approval, and the machine must be online with the app running. |
| Bot name/description | Grok Bot profile | n/a | Short. Not used for rules. |
| Files, CLIs, repos, logins | Grok Bot computer (`/home/box`) | Yes, shared computer | `gh` auth and this clone live here. |

Rule: if it can be a file, it goes here. Grok Bot memory holds only what has to be in context every turn.
