// Publishes this pi session's agent state as tmux pane options (@agent_*) for
// the tmux-agent-sessions picker. Contract: docs/notes/tmux-agent-sessions.md
// ("Agent state contract", "State classification and transitions").
//
// Each event is one async tmux invocation (commands chained with a lone ";"
// argv element). Writes are serialized so they land in event order. Errors are
// swallowed; the agent loop never waits on tmux, except session_shutdown,
// which waits briefly so the unset lands before pi exits.
//
// Also titles the session (D46): once after the first real exchange, again
// after each compaction, and on /retitle. One cheap model call in the
// background; the title lands via pi.setSessionName, whose
// session_info_changed event publishes @agent_name. A name set with /name or
// --name is never replaced. A reopened session with an exchange but no title
// is titled at start.
//
// @agent_empty marks a chat with no prompt yet (D59), from session start to
// the first prompt. @agent_subs counts running /sub subagents
// (subagent-widget.ts, D61); a settle with subagents running stays Working.
// @agent_cwd is ctx.cwd, fixed per process, so it is published at start only.

import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";

const VISIBLE = "#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}";
const MARKER = "Awaiting your input.";
const OPTIONS = [
  "@agent_kind",
  "@agent_pid",
  "@agent_state",
  "@agent_state_at",
  "@agent_at",
  "@agent_name",
  "@agent_subs",
  "@agent_empty",
  "@agent_cwd",
];
const TMUX_TIMEOUT_MS = 5000;
const SHUTDOWN_WAIT_MS = 1000;
// A finished subagent starts a parent turn; settle only if none starts.
const SUBS_SETTLE_MS = 2000;

// Records each auto title, so a different current name means the user set it.
const TITLE_ENTRY = "agent-state-title";
const TITLE_INPUT_CHARS = 2000;
const TITLE_MIN_PROMPT_CHARS = 10;
// Cheap titlers in preference order; one on the current provider goes first.
const TITLE_MODELS = [
  ["openai-codex", "gpt-5.6-luna"],
  ["anthropic", "claude-haiku-4-5"],
  ["google", "gemini-2.5-flash-lite"],
  ["openai", "gpt-5-nano"],
];
const TITLE_PROMPT =
  "You title coding agent sessions. Reply with a short noun phrase of two to " +
  "five words naming the session's topic, in sentence case (capitalize only " +
  "the first word and proper nouns). Do not start with a request verb such " +
  "as help, fix, create, add, make or explain. No quotes and no trailing " +
  "punctuation. Reply with the title only.";

// Survives the extension runtime being rebuilt on /new, /resume and reload, so
// the old runtime's shutdown write cannot overtake the new runtime's start.
const CHAIN_KEY = Symbol.for("pif.agent-state.chain");
type ChainHolder = { [CHAIN_KEY]?: Promise<void> };

function sanitize(value: string, max: number): string {
  const clean = value
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  // A trailing ";" on an argv element is a command separator to tmux.
  return Array.from(clean).slice(0, max).join("").trim().replace(/[;\s]+$/, "");
}

// Pane ids are reused across tmux servers. An orphaned pi can still carry a
// dead server's $TMUX; the server pid is its second comma field.
function paneTarget(): string | undefined {
  const pane = process.env.TMUX_PANE;
  const tmux = process.env.TMUX;
  if (!pane || !tmux) return undefined;
  const serverPid = Number(tmux.split(",")[1]);
  if (Number.isInteger(serverPid) && serverPid > 0) {
    try {
      process.kill(serverPid, 0);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ESRCH") return undefined;
    }
  }
  return pane;
}

function now(): string {
  return String(Math.floor(Date.now() / 1000));
}

// Value format for @agent_state_at: keeps the stamp while the state is
// unchanged, else now. set -F expands it in the pane before @agent_state is
// overwritten, so the age needs no read round trip.
function stateAtFormat(state: string, at: string): string {
  return `#{?#{&&:#{==:#{@agent_state},${state}},#{@agent_state_at}},#{@agent_state_at},${at}}`;
}

function runTmux(args: string[]): Promise<void> {
  return new Promise((resolve) => {
    try {
      execFile("tmux", args, { timeout: TMUX_TIMEOUT_MS }, () => resolve());
    } catch {
      resolve();
    }
  });
}

// commands: one argv array per tmux command, joined with ";" separators.
function publish(commands: string[][]): Promise<void> {
  const holder = globalThis as ChainHolder;
  if (commands.length === 0) return holder[CHAIN_KEY] ?? Promise.resolve();
  const args: string[] = [];
  for (const command of commands) {
    if (args.length > 0) args.push(";");
    args.push(...command);
  }
  const next = (holder[CHAIN_KEY] ?? Promise.resolve()).then(() => runTmux(args));
  holder[CHAIN_KEY] = next;
  return next;
}

function textOf(content: string | { type: string; text?: string }[]): string {
  if (typeof content === "string") return content;
  return content
    .filter((part) => part.type === "text")
    .map((part) => part.text ?? "")
    .join("");
}

function lastAssistantText(ctx: ExtensionContext): string {
  const branch = ctx.sessionManager.getBranch();
  for (let i = branch.length - 1; i >= 0; i--) {
    const entry = branch[i];
    if (entry.type !== "message") continue;
    const message = entry.message;
    if (!("role" in message) || message.role !== "assistant") continue;
    return textOf(message.content);
  }
  return "";
}

function hasMarker(text: string): boolean {
  const lines = text.split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (line) return line === MARKER;
  }
  return false;
}

// Keeps the head and the tail of long text.
function clip(text: string, max: number): string {
  if (text.length <= max) return text;
  const tail = Math.floor(max / 4);
  return `${text.slice(0, max - tail - 3)} … ${text.slice(-tail)}`;
}

// The branch's first user prompt, or "" for an empty chat.
function firstPrompt(ctx: ExtensionContext): string {
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "message" || !("role" in entry.message)) continue;
    if (entry.message.role === "user") return textOf(entry.message.content).trim() || " ";
  }
  return "";
}

// The first prompt of at least TITLE_MIN_PROMPT_CHARS with a text reply,
// plus the start of that reply, so a "hi" never becomes the title.
function firstExchange(ctx: ExtensionContext): string | undefined {
  const branch = ctx.sessionManager.getBranch();
  let prompt = "";
  for (const entry of branch) {
    if (entry.type !== "message" || !("role" in entry.message)) continue;
    const message = entry.message;
    if (message.role === "user") {
      const text = textOf(message.content).trim();
      prompt = text.length >= TITLE_MIN_PROMPT_CHARS ? clip(text, 1500) : "";
    } else if (message.role === "assistant" && prompt) {
      const reply = textOf(message.content).trim();
      if (reply) return `User: ${prompt}\n\nAssistant: ${reply.slice(0, TITLE_INPUT_CHARS - prompt.length)}`;
    }
  }
  return undefined;
}

function lastCompactionSummary(ctx: ExtensionContext): string | undefined {
  const branch = ctx.sessionManager.getBranch();
  for (let i = branch.length - 1; i >= 0; i--) {
    const entry = branch[i];
    if (entry.type === "compaction") return clip(entry.summary, TITLE_INPUT_CHARS);
  }
  return undefined;
}

function lastAutoTitle(ctx: ExtensionContext): string | undefined {
  const entries = ctx.sessionManager.getEntries();
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry.type === "custom" && entry.customType === TITLE_ENTRY) {
      return (entry.data as { name?: string } | undefined)?.name;
    }
  }
  return undefined;
}

// First preferred model with auth, the current provider's first, else the
// session's own model.
function titleModel(ctx: ExtensionContext): ExtensionContext["model"] {
  const available = ctx.modelRegistry.getAvailable();
  const provider = ctx.model?.provider;
  const ordered = [
    ...TITLE_MODELS.filter(([p]) => p === provider),
    ...TITLE_MODELS.filter(([p]) => p !== provider),
  ];
  for (const [p, id] of ordered) {
    const model = available.find((m) => m.provider === p && m.id === id);
    if (model) return model;
  }
  return ctx.model;
}

// First non-empty line without quotes, markdown or a trailing period.
function cleanTitle(reply: string): string {
  const line = reply.split(/\r?\n/).find((l) => l.trim()) ?? "";
  const bare = line
    .replace(/^\s*(#+|[-*>]+)\s*/, "")
    .replace(/^\s*title\s*:\s*/i, "")
    .replace(/^["'`*_\s]+|["'`*_\s]+$/g, "")
    .replace(/\.+$/, "");
  return sanitize(bare, 60);
}

export default function (pi: ExtensionAPI) {
  let named = false;
  let pendingName = "";
  // Running /sub subagents, whether a turn is running, and whether the last
  // settle stayed Working because subagents were running.
  let subs = 0;
  let turnActive = false;
  let heldWorking = false;

  const set = (pane: string, option: string, value: string) => ["set", "-p", "-t", pane, option, value];
  const unset = (pane: string, option: string) => ["set", "-pu", "-t", pane, option];
  // State, @agent_state_at and @agent_at. @agent_state_at is stamped first,
  // while @agent_state still holds the previous state.
  const setState = (pane: string, state: string, at: string) => [
    ["set", "-pF", "-t", pane, "@agent_state_at", stateAtFormat(state, at)],
    set(pane, "@agent_state", state),
    set(pane, "@agent_at", at),
  ];
  // The same as a command string for if -F branches.
  const stateString = (pane: string, state: string, at: string) =>
    `set -pF -t ${pane} @agent_state_at "${stateAtFormat(state, at)}" ; ` +
    `set -p -t ${pane} @agent_state ${state} ; set -p -t ${pane} @agent_at ${at}`;
  const nameCommand = (pane: string, raw: string | undefined) => {
    const name = raw ? sanitize(raw, 60) : "";
    return name ? set(pane, "@agent_name", name) : unset(pane, "@agent_name");
  };

  // Idle or Finished by visibility, as a settle without the marker.
  const settleCommand = (pane: string, at: string) => [
    "if", "-F", "-t", pane, VISIBLE, stateString(pane, "idle", at), stateString(pane, "finished", at),
  ];

  pi.on("session_start", (_event, ctx) => {
    const pane = paneTarget();
    if (!pane) return;
    const sessionName = pi.getSessionName();
    named = Boolean(sessionName && sanitize(sessionName, 60));
    pendingName = "";
    subs = 0;
    turnActive = false;
    heldWorking = false;
    let prompt = "";
    try {
      prompt = firstPrompt(ctx);
    } catch {
      prompt = " ";
    }
    // A reopened session without a name shows its first prompt until titled.
    const fallback = named || !prompt.trim() ? "" : sanitize(prompt, 40);
    if (fallback) named = true;
    // Skipped when empty or unsafe as an argv element (control characters, or
    // a trailing ";" that tmux takes for a separator).
    const cwd = ctx.cwd;
    const cwdOk = Boolean(cwd) && !/[\u0000-\u001f\u007f]/.test(cwd) && !cwd.endsWith(";");
    void publish([
      set(pane, "@agent_kind", "pi"),
      set(pane, "@agent_pid", String(process.pid)),
      ...(cwdOk ? [set(pane, "@agent_cwd", cwd)] : []),
      set(pane, "@agent_subs", "0"),
      ...setState(pane, "idle", now()),
      fallback ? set(pane, "@agent_name", fallback) : nameCommand(pane, sessionName),
      prompt ? unset(pane, "@agent_empty") : set(pane, "@agent_empty", "1"),
    ]);
  });

  // agent_start carries no prompt; remember the first real user input here.
  pi.on("input", (event) => {
    if (named || pendingName || event.source === "extension") return;
    pendingName = sanitize(event.text, 40);
  });

  pi.on("agent_start", () => {
    turnActive = true;
    heldWorking = false;
    const pane = paneTarget();
    if (!pane) return;
    const commands = [...setState(pane, "working", now()), unset(pane, "@agent_empty")];
    if (!named && pendingName) {
      commands.push(set(pane, "@agent_name", pendingName));
      named = true;
    }
    void publish(commands);
  });

  pi.on("ui_prompt_start", () => {
    const pane = paneTarget();
    if (!pane) return;
    void publish(setState(pane, "awaiting", now()));
  });

  pi.on("ui_prompt_end", (_event, ctx) => {
    const pane = paneTarget();
    if (!pane || ctx.isIdle()) return;
    void publish(setState(pane, "working", now()));
  });

  pi.on("agent_settled", (_event, ctx) => {
    turnActive = false;
    const pane = paneTarget();
    if (!pane) return;
    let awaiting = false;
    try {
      awaiting = hasMarker(lastAssistantText(ctx));
    } catch {
      awaiting = false;
    }
    const at = now();
    heldWorking = !awaiting && subs > 0;
    void publish(
      awaiting ? setState(pane, "awaiting", at) : heldWorking ? setState(pane, "working", at) : [settleCommand(pane, at)],
    );
  });

  // The last subagent finishing normally starts a parent turn, which settles
  // as usual. A subagent removed with /subrm or /subclear may not, so a held
  // Working settles here when no turn has started.
  pi.events.on("pif:subagents", (data) => {
    const running = (data as { running?: number } | undefined)?.running;
    if (typeof running !== "number") return;
    subs = running;
    const pane = paneTarget();
    if (!pane) return;
    void publish([set(pane, "@agent_subs", String(running))]);
    if (running > 0 || !heldWorking) return;
    setTimeout(() => {
      if (!heldWorking || turnActive || subs > 0) return;
      heldWorking = false;
      void publish([settleCommand(pane, now())]);
    }, SUBS_SETTLE_MS);
  });

  pi.on("session_info_changed", (event) => {
    const pane = paneTarget();
    if (!pane) return;
    if (event.name && sanitize(event.name, 60)) named = true;
    void publish([nameCommand(pane, event.name)]);
  });

  // The one guard for every automatic title write: no name yet, or the name
  // is still the last auto title. Anything else came from /name or --name.
  const autoTitleAllowed = (ctx: ExtensionContext) => {
    const name = pi.getSessionName();
    return !name || name === lastAutoTitle(ctx);
  };

  // Resolves to the title set, or undefined. Callers never await it from an
  // event handler and drop its errors. force: an explicit /retitle.
  const retitle = async (ctx: ExtensionContext, input: string, force = false) => {
    if (!force && !autoTitleAllowed(ctx)) return undefined;
    const sessionId = ctx.sessionManager.getSessionId();
    const model = titleModel(ctx);
    if (!model) return undefined;
    // Reasoning off ("none"), or minimal where a model cannot turn it off;
    // non-OpenAI APIs ignore the option. The budget leaves room for reasoning.
    const options = {
      maxTokens: model.reasoning ? 256 : 40,
      cacheRetention: "none",
      sessionId: randomUUID(),
      reasoningEffort: model.thinkingLevelMap?.off === null ? "minimal" : "none",
    } as const;
    const reply = await ctx.modelRegistry.complete(
      model,
      {
        systemPrompt: TITLE_PROMPT,
        messages: [{ role: "user", content: [{ type: "text", text: `<session>\n${input}\n</session>` }], timestamp: Date.now() }],
      },
      options,
    );
    const title = cleanTitle(textOf(reply.content));
    // The runtime may have moved to another session meanwhile (/new,
    // /resume, reload); a stale ctx throws, which the caller drops.
    if (!title || ctx.sessionManager.getSessionId() !== sessionId) return undefined;
    if (!force && !autoTitleAllowed(ctx)) return undefined;
    pi.setSessionName(title);
    pi.appendEntry(TITLE_ENTRY, { name: title });
    return title;
  };

  // At most one first-title attempt per runtime, so a failing call does not
  // repeat on every settle.
  let firstTitleTried = false;
  pi.on("agent_settled", (_event, ctx) => {
    if (firstTitleTried) return;
    try {
      if (lastAutoTitle(ctx) !== undefined || !autoTitleAllowed(ctx)) return;
      const input = firstExchange(ctx);
      if (!input) return;
      firstTitleTried = true;
      retitle(ctx, input).catch(() => {});
    } catch {
      // Titles are best effort.
    }
  });

  // A reopened session with a qualifying exchange and no title gets one now.
  pi.on("session_start", (_event, ctx) => {
    try {
      if (lastAutoTitle(ctx) !== undefined || !autoTitleAllowed(ctx)) return;
      const input = firstExchange(ctx);
      if (!input) return;
      firstTitleTried = true;
      retitle(ctx, input).catch(() => {});
    } catch {
      // Titles are best effort.
    }
  });

  pi.on("session_compact", (event, ctx) => {
    retitle(ctx, clip(event.compactionEntry.summary, TITLE_INPUT_CHARS)).catch(() => {});
  });

  pi.registerCommand("retitle", {
    description: "Regenerate the session title (re-enables auto titles)",
    handler: async (_args, ctx) => {
      const input = lastCompactionSummary(ctx) ?? firstExchange(ctx);
      const notify = (message: string, type: "info" | "warning") => {
        try {
          if (ctx.hasUI) ctx.ui.notify(message, type);
        } catch {
          // The runtime may be gone.
        }
      };
      if (!input) return notify("Nothing to title yet", "warning");
      retitle(ctx, input, true).then(
        (title) => notify(title ? `Session titled: ${title}` : "No title generated", title ? "info" : "warning"),
        () => notify("Title generation failed", "warning"),
      );
    },
  });

  pi.on("session_shutdown", async () => {
    const pane = paneTarget();
    if (!pane) return;
    const done = publish(OPTIONS.map((option) => unset(pane, option)));
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([
      done,
      new Promise<void>((resolve) => {
        timer = setTimeout(resolve, SHUTDOWN_WAIT_MS);
      }),
    ]);
    if (timer) clearTimeout(timer);
  });
}
