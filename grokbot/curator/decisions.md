# Curator decisions log

- 2026-11-21 Curator is this bot (formerly the default Grok Bot).
- 2026-11-21 Use the `gh` CLI for GitHub, never the connector.
- 2026-11-21 Bro communication standard by default for all Grok Bot bots.
- 2026-11-21 Canonical config lives in `dotfiles/grokbot/`, loaded by one saved rule per bot.
- 2026-11-21 No STATE.md. Each bot's `AGENTS.md` points to other files with notes on when to read them.
- 2026-11-21 Tailscale reaches the Macs only for now. exe.dev comes later, with visibility via the control VM.
- 2026-11-21 Curator builds systems and doesn't own focus accountability. A separate bot (name open) owns pushing threads forward when Kalem is idle.
- 2026-11-21 D1 accepted: hosts expose thread status, including the agent's final message when awaiting or done and its current message when working. Grok only reads it, so the same status also serves Hermes later.
- 2026-11-21 D2 accepted in principle: an idle-gated routine that does nothing while Kalem is active, run by the focus accountability bot.
- 2026-11-21 D4: no bot per thread.
- 2026-11-21 D5 accepted: a dotfiles command to inject a prompt into a running pane, which focus agents will build. Kalem has given permission for prompts to focus agents for now.
- 2026-11-21 Handoff must never make Kalem pick a host ("push to remote"). Manual handoff before leaving was rejected because he won't remember to do it.
