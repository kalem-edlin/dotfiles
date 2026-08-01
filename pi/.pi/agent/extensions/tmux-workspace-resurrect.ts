import { spawn } from "node:child_process";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const recorder =
  `${process.env.HOME}/.config/tmux/local-plugins/` +
  "tmux-workspace-resurrect/scripts/record-agent-session.sh";

function recordSession(payload: Record<string, unknown>): void {
  if (!process.env.TMUX_PANE) return;

  const child = spawn("bash", [recorder, "pi"], {
    env: process.env,
    stdio: ["pipe", "ignore", "ignore"],
  });
  child.stdin.end(JSON.stringify(payload));
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (event, ctx) => {
    recordSession({
      session_id: ctx.sessionManager.getSessionId(),
      session_file: ctx.sessionManager.getSessionFile(),
      cwd: ctx.cwd,
      model: ctx.model?.id ?? "",
      provider: ctx.model?.provider ?? "",
      source: event.reason,
      hook_event_name: "SessionStart",
    });
  });
}
