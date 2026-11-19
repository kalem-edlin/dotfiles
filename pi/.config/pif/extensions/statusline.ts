/**
 * Personal status line — replaces the default footer with a single-line bar
 * styled to match the user's CCometixLine config used by Claude Code.
 *
 * Layout:
 *    Model (thinking) | git branch ●/○ | ctx% · tokens | codex usage | $cost
 *
 * Codex subscription usage (5-hour and weekly windows) is read from ChatGPT's
 * usage endpoint with pi's openai-codex login when that provider is active.
 *
 * Colors are emitted as raw 256-color ANSI escapes so the status line matches
 * ccline exactly without hijacking shared theme tokens.
 */

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
  cost: 214,
  sep: 240,
  shells: 73,
} as const;

const ICON = {
  model: "\u{E26D}",
  git: "\u{F02A2}",
  ctx: "\u{F49B}",
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
const COUNTDOWN_RENDER_MS = 60 * 1000;
const CODEX_FETCH_TIMEOUT_MS = 5000;
const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";

type UsageWindow = {
  usedPct: number;
  durationMins: number;
  resetsAt: number;
};

type CodexUsage = {
  short?: UsageWindow;
  weekly?: UsageWindow;
  planType: string;
};

// One window from ChatGPT's usage endpoint: used_percent,
// limit_window_seconds and reset_at (epoch seconds).
export function parseUsageWindow(value: any): UsageWindow | undefined {
  const usedPct = Number(value?.used_percent);
  const durationMins = Number(value?.limit_window_seconds) / 60;
  const resetsAt = Number(value?.reset_at);
  if (![usedPct, durationMins, resetsAt].every(Number.isFinite)) return undefined;
  return { usedPct, durationMins, resetsAt };
}

function remainingWindow(resetsAt: number): string {
  const minutes = Math.max(0, Math.floor((resetsAt * 1000 - Date.now()) / 60_000));
  return minutes >= 60 ? `${Math.floor(minutes / 60)}h` : `${minutes}m`;
}

function weeklyResetDate(resetsAt: number): string {
  const reset = new Date(resetsAt * 1000);
  const days = Math.max(0, Math.floor((resetsAt * 1000 - Date.now()) / 86_400_000));
  return `${reset.getUTCMonth() + 1}-${reset.getUTCDate()}-${days}`;
}

function normalizeModelName(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/g, "");
}

// The ChatGPT account id sits in the access token's claims, as pi's own
// openai-codex provider reads it.
function accountIdFromToken(token: string): string | undefined {
  try {
    const payload = JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString("utf8"));
    return payload?.["https://api.openai.com/auth"]?.chatgpt_account_id || undefined;
  } catch {
    return undefined;
  }
}

// Picks the 5-hour and weekly windows from a usage response. A per-model
// limit (additional_rate_limits, matched on limit_name) wins over the
// account-wide one.
export function codexUsageFrom(body: any, modelId?: string): CodexUsage | undefined {
  const modelName = normalizeModelName(modelId ?? "");
  const extra = Array.isArray(body?.additional_rate_limits) ? body.additional_rate_limits : [];
  const modelLimit = extra.find(
    (candidate: any) =>
      candidate?.limit_name && normalizeModelName(candidate.limit_name) === modelName,
  )?.rate_limit;
  const rl = modelLimit ?? body?.rate_limit;
  if (!rl) return undefined;
  const windows = [parseUsageWindow(rl.primary_window), parseUsageWindow(rl.secondary_window)]
    .filter((window): window is UsageWindow => !!window);
  const short = windows.find((window) => window.durationMins <= 24 * 60);
  const weekly = windows
    .filter((window) => window.durationMins > 24 * 60)
    .sort((a, b) => b.durationMins - a.durationMins)[0];
  if (!short && !weekly) return undefined;
  return { short, weekly, planType: String(body?.plan_type ?? "") };
}

// Reads subscription usage with pi's own openai-codex login (the registry
// refreshes an expired token), so no codex CLI is needed.
async function fetchCodexUsage(
  registry: { getApiKeyForProvider(provider: string): Promise<string | undefined> } | undefined,
  modelId?: string,
): Promise<CodexUsage | undefined> {
  try {
    const token = await registry?.getApiKeyForProvider("openai-codex");
    if (!token) return undefined;
    const accountId = accountIdFromToken(token);
    const res = await fetch(CODEX_USAGE_URL, {
      headers: {
        Authorization: `Bearer ${token}`,
        ...(accountId ? { "ChatGPT-Account-Id": accountId } : {}),
      },
      signal: AbortSignal.timeout(CODEX_FETCH_TIMEOUT_MS),
    });
    if (!res.ok) return undefined;
    return codexUsageFrom(await res.json(), modelId);
  } catch {
    return undefined;
  }
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

function totalCost(branch: ReadonlyArray<BranchEntry>): number {
  let cost = 0;
  for (const e of branch) {
    if (e.type === "message" && e.message?.role === "assistant") {
      const m = e.message as unknown as AssistantMessage;
      cost += m.usage?.cost?.total ?? 0;
    }
  }
  return cost;
}

// The background-shells tag (shells.ts): "1 shell" / "N shells", shown
// inverted while Down has focused it.
export function shellsTag(count: number, focused = false): string {
  const label = `${count} shell${count === 1 ? "" : "s"}`;
  if (!focused) return fg(COLOR.shells, label, true);
  return `${ESC}7m${fg(COLOR.shells, ` ${label} `, true)}`;
}

function isCodexProvider(provider: string | undefined): boolean {
  if (!provider) return false;
  return provider === "openai-codex" || provider === "codex";
}

export default function (pi: ExtensionAPI) {
  // Running background shells (shells.ts), shown as "N shells", and
  // whether Down has focused that tag.
  let shells = 0;
  let shellsFocused = false;
  let shellsTui: { requestRender: () => void } | undefined;
  pi.events?.on("pif:shells", (data) => {
    const active = (data as { active?: number } | undefined)?.active;
    if (typeof active !== "number") return;
    shells = active;
    shellsTui?.requestRender();
  });
  pi.events?.on("pif:shells-focus", (data) => {
    shellsFocused = Boolean((data as { focused?: boolean } | undefined)?.focused);
    shellsTui?.requestRender();
  });

  pi.on("session_start", (_event, ctx) => {
    let dirty = false;
    let codexUsage: CodexUsage | undefined;
    let dirtyTimer: ReturnType<typeof setInterval> | undefined;
    let codexTimer: ReturnType<typeof setInterval> | undefined;
    let countdownTimer: ReturnType<typeof setInterval> | undefined;
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

    const refreshCodexUsage = async (model = ctx.model) => {
      if (!isCodexProvider(model?.provider)) {
        if (codexUsage) {
          codexUsage = undefined;
          activeTui?.requestRender();
        }
        return;
      }
      const next = await fetchCodexUsage(ctx.modelRegistry, model?.id);
      if (next) {
        codexUsage = next;
        activeTui?.requestRender();
      }
    };

    pi.on("agent_end", () => {
      void refreshCodexUsage();
    });
    pi.on("model_select", (event) => {
      void refreshCodexUsage(event.model);
    });

    ctx.ui.setFooter((tui, _theme, footerData) => {
      activeTui = tui;
      shellsTui = tui;
      const unsub = footerData.onBranchChange(() => {
        void refreshDirty();
        tui.requestRender();
      });
      void refreshDirty();
      void refreshCodexUsage();
      dirtyTimer = setInterval(() => void refreshDirty(), DIRTY_POLL_MS);
      codexTimer = setInterval(() => void refreshCodexUsage(), CODEX_POLL_MS);
      countdownTimer = setInterval(() => tui.requestRender(), COUNTDOWN_RENDER_MS);

      return {
        dispose() {
          unsub();
          if (dirtyTimer) clearInterval(dirtyTimer);
          if (codexTimer) clearInterval(codexTimer);
          if (countdownTimer) clearInterval(countdownTimer);
          activeTui = undefined;
        },
        invalidate() {},
        render(width: number): string[] {
          const branch = footerData.getGitBranch();
          const cost = totalCost(ctx.sessionManager.getBranch());

          const ctxUse = ctx.getContextUsage();
          const ctxPercent = ctxUse?.percent != null ? `${ctxUse.percent.toFixed(1)}%` : "?%";
          const ctxTokens = ctxUse?.tokens != null ? fmtTokens(ctxUse.tokens) : "?";

          const thinking = pi.getThinkingLevel();
          const thinkingLabel = thinking === "off" ? "off" : thinking;

          const segments: string[] = [
            fg(
              COLOR.model,
              `${ICON.model} ${prettyModel(ctx.model?.id)} (${thinkingLabel})`,
              true,
            ),
          ];

          if (branch) {
            const marker = dirty ? "\u{F040}" : "●";
            segments.push(fg(COLOR.git, `${ICON.git} ${branch} ${marker}`, true));
          }

          segments.push(
            fg(COLOR.ctx, `${ICON.ctx} ${ctxPercent} · ${ctxTokens} tokens`, true),
          );

          if (codexUsage) {
            const displayPct = codexUsage.short?.usedPct ?? codexUsage.weekly?.usedPct;
            if (displayPct != null) {
              const resetParts = [
                codexUsage.short ? remainingWindow(codexUsage.short.resetsAt) : undefined,
                codexUsage.weekly ? weeklyResetDate(codexUsage.weekly.resetsAt) : undefined,
              ].filter(Boolean);
              const resetLabel = resetParts.length ? ` · ${resetParts.join(" ")}` : "";
              segments.push(
                fg(COLOR.usage, `${pieIcon(displayPct)} ${displayPct}%${resetLabel}`, true),
              );
            }
          }

          segments.push(fg(COLOR.cost, `${ICON.cost} $${cost.toFixed(2)}`, true));

          if (shells > 0) segments.push(shellsTag(shells, shellsFocused));

          const line = segments.join(SEP);
          return [truncateToWidth(line, width)];
        },
      };
    });
  });
}
