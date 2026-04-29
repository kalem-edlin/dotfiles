/**
 * Personal status line — replaces the default footer with a single-line bar
 * styled to match the user's CCometixLine config used by Claude Code.
 *
 * Layout:
 *    Model | git branch ●/○ | ctx% · tokens | codex 5h% · 7d% | thinking | $cost
 *
 * Codex subscription usage is queried via `codex app-server` (JSONRPC
 * account/rateLimits/read) when the active provider is openai-codex.
 *
 * Colors are emitted as raw 256-color ANSI escapes so the status line matches
 * ccline exactly without hijacking shared theme tokens.
 */

import { spawn } from "node:child_process";
import type { AssistantMessage } from "@mariozechner/pi-ai";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { truncateToWidth } from "@mariozechner/pi-tui";

const ESC = "\x1b[";
const RESET = `${ESC}0m`;
const BOLD = `${ESC}1m`;

const fg = (c256: number, text: string, bold = false) =>
  `${bold ? BOLD : ""}${ESC}38;5;${c256}m${text}${RESET}`;

const COLOR = {
  model: 208,
  git: 109,
  ctx: 5,
  usage: 14,
  thinking: 141,
  cost: 214,
  sep: 240,
} as const;

const ICON = {
  model: "\u{E26D}",
  git: "\u{F02A2}",
  ctx: "\u{F49B}",
  thinking: "\u{F12F5}",
  cost: "\u{EEC1}",
} as const;

const PIE = {
  empty: "\u{F0766}",
  slices: [
    "\u{F0A9E}",
    "\u{F0A9F}",
    "\u{F0AA0}",
    "\u{F0AA1}",
    "\u{F0AA2}",
    "\u{F0AA3}",
    "\u{F0AA4}",
    "\u{F0AA5}",
  ],
} as const;

function pieIcon(percent: number): string {
  if (percent <= 0) return PIE.empty;
  const idx = Math.max(1, Math.min(8, Math.ceil((percent / 100) * 8)));
  return PIE.slices[idx - 1] ?? PIE.slices[7]!;
}

const SEP = ` ${fg(COLOR.sep, "|")} `;
const DIRTY_POLL_MS = 4000;
const CODEX_POLL_MS = 5 * 60 * 1000;
const CODEX_RPC_TIMEOUT_MS = 5000;

type CodexUsage = {
  primaryPct: number;
  secondaryPct: number;
  planType: string;
};

function fetchCodexUsage(): Promise<CodexUsage | undefined> {
  return new Promise((resolve) => {
    let proc: ReturnType<typeof spawn>;
    try {
      proc = spawn("codex", ["app-server"], { stdio: ["pipe", "pipe", "ignore"] });
    } catch {
      resolve(undefined);
      return;
    }

    let buffer = "";
    let done = false;
    const finish = (value: CodexUsage | undefined) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try {
        proc.kill("SIGTERM");
      } catch {}
      resolve(value);
    };
    const timer = setTimeout(() => finish(undefined), CODEX_RPC_TIMEOUT_MS);

    proc.on("error", () => finish(undefined));
    proc.on("exit", () => finish(undefined));

    proc.stdout?.on("data", (chunk: Buffer) => {
      buffer += chunk.toString("utf8");
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const msg = JSON.parse(trimmed) as { id?: number; result?: any };
          if (msg.id === 1 && msg.result) {
            proc.stdin?.write(
              `${JSON.stringify({
                jsonrpc: "2.0",
                id: 2,
                method: "account/rateLimits/read",
                params: {},
              })}\n`,
            );
          } else if (msg.id === 2 && msg.result?.rateLimits) {
            const rl = msg.result.rateLimits;
            finish({
              primaryPct: Number(rl.primary?.usedPercent ?? 0),
              secondaryPct: Number(rl.secondary?.usedPercent ?? 0),
              planType: String(rl.planType ?? ""),
            });
            return;
          }
        } catch {
          /* ignore parse errors */
        }
      }
    });

    proc.stdin?.write(
      `${JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          capabilities: {},
          clientInfo: { name: "pi-statusline", version: "0.1.0" },
        },
      })}\n`,
    );
  });
}

function prettyModel(id: string | undefined): string {
  if (!id) return "no-model";
  const stripped = id.replace(/^[a-z]+\//, "").replace(/-\d{8}$/, "");
  const m = stripped.match(/^claude-(opus|sonnet|haiku)-(\d+)(?:-(\d+))?(?:-(\d+))?(?:-(.+))?$/i);
  if (m) {
    const [, family, major, minor, patch, suffix] = m;
    const ver = [major, minor, patch].filter(Boolean).join(".");
    const cap = family.charAt(0).toUpperCase() + family.slice(1);
    return suffix ? `${cap} ${ver} ${suffix.toUpperCase()}` : `${cap} ${ver}`;
  }
  if (/^gpt-/i.test(stripped)) return stripped.toUpperCase();
  return stripped;
}

function fmtTokens(n: number): string {
  if (n < 1000) return `${n}`;
  if (n < 1_000_000) return `${(n / 1000).toFixed(1)}k`;
  return `${(n / 1_000_000).toFixed(2)}m`;
}

type BranchEntry = { type: string; message?: { role: string } };

function totalUsage(branch: ReadonlyArray<BranchEntry>): {
  inputTokens: number;
  outputTokens: number;
  cost: number;
} {
  let inputTokens = 0;
  let outputTokens = 0;
  let cost = 0;
  for (const e of branch) {
    if (e.type === "message" && e.message?.role === "assistant") {
      const m = e.message as unknown as AssistantMessage;
      inputTokens += m.usage?.input ?? 0;
      outputTokens += m.usage?.output ?? 0;
      cost += m.usage?.cost?.total ?? 0;
    }
  }
  return { inputTokens, outputTokens, cost };
}

function isCodexProvider(provider: string | undefined): boolean {
  if (!provider) return false;
  return provider === "openai-codex" || provider === "codex";
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    let dirty = false;
    let codexUsage: CodexUsage | undefined;
    let dirtyTimer: ReturnType<typeof setInterval> | undefined;
    let codexTimer: ReturnType<typeof setInterval> | undefined;
    let activeTui: { requestRender: () => void } | undefined;

    const refreshDirty = async () => {
      const result = await pi
        .exec("git", ["status", "--porcelain"], { cwd: ctx.cwd })
        .catch(() => undefined);
      const next = !!result?.stdout.trim().length;
      if (next !== dirty) {
        dirty = next;
        activeTui?.requestRender();
      }
    };

    const refreshCodexUsage = async () => {
      if (!isCodexProvider(ctx.model?.provider)) {
        if (codexUsage) {
          codexUsage = undefined;
          activeTui?.requestRender();
        }
        return;
      }
      const next = await fetchCodexUsage();
      if (next) {
        codexUsage = next;
        activeTui?.requestRender();
      }
    };

    pi.on("agent_end", () => {
      void refreshCodexUsage();
    });

    ctx.ui.setFooter((tui, _theme, footerData) => {
      activeTui = tui;
      const unsub = footerData.onBranchChange(() => {
        void refreshDirty();
        tui.requestRender();
      });
      void refreshDirty();
      void refreshCodexUsage();
      dirtyTimer = setInterval(() => void refreshDirty(), DIRTY_POLL_MS);
      codexTimer = setInterval(() => void refreshCodexUsage(), CODEX_POLL_MS);

      return {
        dispose() {
          unsub();
          if (dirtyTimer) clearInterval(dirtyTimer);
          if (codexTimer) clearInterval(codexTimer);
          activeTui = undefined;
        },
        invalidate() {},
        render(width: number): string[] {
          const branch = footerData.getGitBranch();
          const { inputTokens, outputTokens, cost } = totalUsage(ctx.sessionManager.getBranch());
          const totalTokens = inputTokens + outputTokens;

          const ctxUse = ctx.getContextUsage();
          const ctxPercent = ctxUse?.percent != null ? `${ctxUse.percent.toFixed(1)}%` : "?%";

          const thinking = pi.getThinkingLevel();
          const thinkingLabel = thinking === "off" ? "off" : thinking;

          const segments: string[] = [
            fg(COLOR.model, `${ICON.model} ${prettyModel(ctx.model?.id)}`, true),
          ];

          if (branch) {
            const marker = dirty ? "\u{F040}" : "●";
            segments.push(fg(COLOR.git, `${ICON.git} ${branch} ${marker}`, true));
          }

          segments.push(
            fg(COLOR.ctx, `${ICON.ctx} ${ctxPercent} · ${fmtTokens(totalTokens)} tokens`, true),
          );

          if (codexUsage) {
            segments.push(
              fg(
                COLOR.usage,
                `${pieIcon(codexUsage.secondaryPct)} ${codexUsage.primaryPct}%`,
                true,
              ),
            );
          }

          segments.push(fg(COLOR.thinking, `${ICON.thinking} ${thinkingLabel}`, true));
          segments.push(fg(COLOR.cost, `${ICON.cost} $${cost.toFixed(2)}`, true));

          const line = segments.join(SEP);
          return [truncateToWidth(line, width)];
        },
      };
    });
  });
}
