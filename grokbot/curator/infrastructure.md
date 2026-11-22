# Infrastructure and access

## Hosts

- MacBook Pro: Kalem's main machine. Often off or asleep. Linked to Grok Bot through the app, so commands need approval and only work while it's online.
- Mac mini: always on. The intended home for long-lived threads that Grok Bot should observe or push. Planned access is SSH over Tailscale from the Grok Bot computer.
- exe.dev fleet: Roll harness runners. Grok Bot sees it only through the `arms-control` control VM.

## Handing off work

- Use the dotfiles paths: `chat-move <worktree> --message-file <prompt>` for a session, and `/remote-handoff` (`rw bg handoff`) to move a workspace to an always-on worker.
- Threads that only exist on the laptop aren't reachable while it's off. Long-lived threads Kalem wants pushed should be handed off to the Mac mini.
- Raw `tmux send-keys` is a last resort.
