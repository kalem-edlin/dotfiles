---
name: focus-agents
description: Use when a bot that builds systems (dotfiles, content-engine and so on) is about to start or steer coding, investigation or spec work through Kalem's tmux claudef/pif focus agents. It covers picking the work tier, asking Kalem first, and splitting roles between the bot and the focus agent.
---
# Focus agents

Focus agents are `claudef` (Claude Code) or `pif` (pi) chats running in tmux worktrees on Kalem's Macs. Only bots responsible for building systems use this skill. Most bots never touch code.

## 1. Ask for the tier first
Before you start any focus-agent work, recommend a tier and ask Kalem to confirm. Use tiers 1 and 2 by default. Use tier 3 when the scope sounds large or Kalem asks for it.

| Tier | When | Planning / spec | Execution |
|---|---|---|---|
| 1 | Tedious, low risk, no planning or decision rounds | pif `deepseek-v4-flash-0731 (high)` for every stage | same |
| 2 | Not a major pivot, but needs critical thinking, research and correct answers | pif `GPT-5.6-SOL (high)` driver with pif `GPT-5.6-TERRA (medium)` subagents | claudef `Opus 5.5 (high)` driver with `Sonnet 5.5 (high)` workers |
| 3 | Intense work that needs heavy intelligence | claudef `Fable 5.1 (high)` driver with `Sonnet 5.5 (high)` workers | claudef `Opus 5.5 (high)` driver with `Opus 5.5 (high)` workers |

## 2. Split the roles
- The bot owns intent. The focus agent owns grounding and writing.
- The focus agent conversation that investigated writes the spec, task file or Linear ticket. The bot never writes them.
- The bot confirms intent with the focus agent before it writes. Intent means Kalem's decisions plus the bot's own knowledge.
- The bot answers the focus agent's questions itself when its intent context covers them, and passes only real decisions to Kalem.
- Prototype first. Build behind a flag or in isolation, validate, and then propose integration.

## 3. Mechanics
- Start a thread in its own tmux session named after the work, and give it a brief file (intent, rules, where to write output). Tell the agent to end its reply with `Awaiting your input.`
- Send follow-ups as a file pasted into the pane, until the dotfiles prompt-injection command exists.
- Read only the final message or the report, never the full transcript.
