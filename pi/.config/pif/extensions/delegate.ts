// Delegation to a subagent: a profiled member defined in Claude Code's front
// matter format (name, description, model, tools) plus a pi_model key naming
// the pi model to run it on, or, with no agent named, a generalist on the
// parent's model with the built-in tools.
//
// Members resolve project first, then profile: <cwd>/.claude/agents/<name>.md
// and $PI_CODING_AGENT_DIR/agents/<name>.md. Claude Code applies the same
// precedence, so a repo that ships its own member of the same name wins in
// both runtimes.
//
// The child is a separate `pi -p --mode json` with --no-extensions, so none
// of the pif extensions load in it. A member that lists WebSearch or WebFetch
// gets web.ts with -e, followed by the project's own .pi/extensions loaders,
// so a repo tool of the same name replaces the profile copy in the child as
// it does in the parent. The child's event stream feeds a card above the
// editor.
//
// In the interactive UI a delegation runs in the background: the tool
// returns a delegate number at once and the parent keeps working. The
// child's last assistant message comes back as a "delegate" message with
// steer delivery, which lands before the parent's next model call or starts
// a turn when the parent is idle. wait: true, or a parent without a UI
// (pif -p), blocks the tool call until the child exits and returns the
// report as the tool result. delegate_continue resumes a finished child's
// kept session with a follow-up; delegate_stop ends a running one. Every
// run is stopped after CHILD_TIMEOUT_MS.
//
// A project that ships its own copy as .pi/extensions/delegate.ts wins: this
// file then registers nothing, because pi exits at startup when two
// extensions register the same tool name.
//
// The progress card is derived from IndyDevDan/pi-vs-claude-code at
// 0ed11f44932fdef29bd98467700019762298f50d, copyright (c) 2026 IndyDevDan,
// MIT licence: permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, subject to
// this notice being included in all copies or substantial portions of the
// Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Every run, background or waited, stops after an hour (D12): a guard for a
// hung or looping child nobody is watching, not a budget for normal work.
// The session is kept, so delegate_continue resumes a capped run.
export const CHILD_TIMEOUT_MS = 60 * 60 * 1000;
export const MEMBER_THINKING = "low";
export const RESULT_CAP_CHARS = 24_000;
export const GENERALIST_NAME = "generalist";
export const PROJECT_OVERRIDE = join(".pi", "extensions", "delegate.ts");

export function projectOverrides(cwd = process.cwd()): boolean {
  return existsSync(join(cwd, PROJECT_OVERRIDE));
}
export const GENERALIST_TOOLS = ["Read", "Write", "Edit", "Bash", "Grep", "Glob", "Ls", "Agent"];

// Two tiers at most (D14): the driver is depth 0, its delegates depth 1 and
// theirs depth 2. A child learns its depth from DEPTH_ENV; only a child
// below MAX_DEPTH whose member lists Agent gets this extension and the
// delegate tool, and a copy loaded at MAX_DEPTH registers nothing.
export const MAX_DEPTH = 2;
export const DEPTH_ENV = "PIF_DELEGATE_DEPTH";
export const DELEGATE_TOOL = "Agent";

export function currentDepth(env: NodeJS.ProcessEnv = process.env): number {
  const depth = Number(env[DEPTH_ENV]);
  return Number.isInteger(depth) && depth > 0 ? depth : 0;
}
export const GENERALIST_DIRECTIVE = [
  "You are a delegated implementation and research subagent.",
  "Stay within the task and files delegated by the parent. You may create or modify files when the task asks for implementation.",
  "Do not revert unrelated changes or edit files assigned to concurrent agents. Run relevant checks.",
  "Report changed files, checks run, and unresolved concerns.",
].join(" ");

// Claude Code tool names to pi tool names. Names outside this map are
// reported back rather than silently dropped.
export const TOOL_MAP: Record<string, string> = {
  WebSearch: "web_search",
  WebFetch: "web_fetch",
  Read: "read",
  Grep: "grep",
  Glob: "find",
  Bash: "bash",
  Write: "write",
  Edit: "edit",
  Ls: "ls",
};
const WEB_TOOLS = new Set(["WebSearch", "WebFetch"]);

export interface Member {
  name: string;
  description: string;
  model?: string;
  piModel?: string;
  tools: string[];
  body: string;
  path: string;
}

export function parseMember(source: string, path: string): Member {
  const match = source.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!match) throw new Error(`${path} has no front matter`);
  const fields: Record<string, string> = {};
  for (const line of match[1].split(/\r?\n/)) {
    const pair = line.match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
    if (pair) fields[pair[1]] = pair[2].trim().replace(/^(['"])(.*)\1$/, "$2");
  }
  const tools = (fields.tools ?? "")
    .split(",")
    .map((tool) => tool.trim())
    .filter(Boolean);
  return {
    name: fields.name || basename(path, ".md"),
    description: fields.description ?? "",
    model: fields.model || undefined,
    piModel: fields.pi_model || undefined,
    tools,
    body: match[2].trim(),
    path,
  };
}

// The generalist is the parent's own model and thinking with the built-in
// tools; it exists so a task with no fitting member still runs apart.
export function generalistMember(parentModel?: string): Member {
  return {
    name: GENERALIST_NAME,
    description: "Generalist on the parent's model with the built-in file and shell tools.",
    piModel: parentModel,
    tools: GENERALIST_TOOLS,
    body: GENERALIST_DIRECTIVE,
    path: "",
  };
}

export function profileDir(): string {
  return process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".config", "pif");
}

export function sessionsDir(): string {
  return process.env.PI_CODING_AGENT_SESSION_DIR ?? join(profileDir(), "sessions");
}

export function memberDirs(cwd: string): string[] {
  return [join(cwd, ".claude", "agents"), join(profileDir(), "agents")];
}

export function resolveMember(name: string, cwd: string): string | undefined {
  if (!/^[\w-]+$/.test(name)) return undefined;
  for (const dir of memberDirs(cwd)) {
    const candidate = join(dir, `${name}.md`);
    if (existsSync(candidate)) return candidate;
  }
  return undefined;
}

// Project members shadow profile members of the same name.
export function listMembers(cwd: string): Member[] {
  const seen = new Map<string, Member>();
  for (const dir of memberDirs(cwd)) {
    let files: string[] = [];
    try {
      files = readdirSync(dir).filter((file) => file.endsWith(".md")).sort();
    } catch {
      continue;
    }
    for (const file of files) {
      const path = join(dir, file);
      try {
        const member = parseMember(readFileSync(path, "utf8"), path);
        if (!seen.has(member.name)) seen.set(member.name, member);
      } catch {
        // A malformed member is skipped here and reported when called.
      }
    }
  }
  return [...seen.values()];
}

// The project's own pi extension loaders, passed to a child after the
// profile's web.ts so the repo's tool of the same name wins there too.
export function projectLoaders(cwd: string): string[] {
  const dir = join(cwd, ".pi", "extensions");
  try {
    return readdirSync(dir)
      .filter((file) => file.endsWith(".ts") || file.endsWith(".js"))
      .sort()
      .map((file) => join(dir, file));
  } catch {
    return [];
  }
}

export interface ChildOptions {
  cwd: string;
  modelOverride?: string;
  thinking?: string;
  sessionFile?: string;
  // The caller's own depth; currentDepth() when unset.
  depth?: number;
}

export interface ChildPlan {
  args: string[];
  unmappedTools: string[];
  sessionFile: string;
  env: Record<string, string>;
  nested: boolean;
  // What the child runs on, for the tool row: the --model value (unset
  // means pi's default) and the thinking level.
  model?: string;
  thinking: string;
}

// The random suffix keeps parallel delegations started in the same
// millisecond on separate files: pi refuses a session file that another
// child created first (EEXIST).
export function sessionFileFor(name: string, now = Date.now()): string {
  return join(sessionsDir(), "delegate", `${name}-${now}-${randomBytes(3).toString("hex")}.jsonl`);
}

export function buildChildArgs(member: Member, options: ChildOptions): ChildPlan {
  const sessionFile = options.sessionFile ?? sessionFileFor(member.name);
  const args = ["--mode", "json", "-p", "--session", sessionFile, "--no-skills", "--no-extensions"];
  const profile = profileDir();
  const needsWeb = member.tools.some((tool) => WEB_TOOLS.has(tool));
  const depth = (options.depth ?? currentDepth()) + 1;
  const nested = member.tools.includes(DELEGATE_TOOL) && depth < MAX_DEPTH;
  if (needsWeb) {
    args.push("-e", join(profile, "extensions", "web.ts"));
    for (const loader of projectLoaders(options.cwd)) args.push("-e", loader);
  }
  // The repo's own delegate.ts wins as in the parent; a web member already
  // loaded it with the repo loaders.
  if (nested && !(needsWeb && projectOverrides(options.cwd))) {
    args.push("-e", projectOverrides(options.cwd) ? join(options.cwd, PROJECT_OVERRIDE) : join(profile, "extensions", "delegate.ts"));
  }
  const mapped: string[] = [];
  const unmappedTools: string[] = [];
  for (const tool of member.tools) {
    // At the depth cap Agent is dropped, not reported: the cap is policy.
    if (tool === DELEGATE_TOOL) {
      if (nested) mapped.push("delegate");
      continue;
    }
    const piName = TOOL_MAP[tool];
    if (piName) mapped.push(piName);
    else unmappedTools.push(tool);
  }
  if (member.tools.length > 0) args.push("--tools", mapped.join(","));
  const model = options.modelOverride?.trim() || member.piModel;
  if (model) args.push("--model", model);
  const thinking = options.thinking ?? MEMBER_THINKING;
  args.push("--thinking", thinking);
  const communication = join(profile, "communication.md");
  if (existsSync(communication)) args.push("--append-system-prompt", communication);
  if (member.body) args.push("--append-system-prompt", member.body);
  return { args, unmappedTools, sessionFile, env: { [DEPTH_ENV]: String(depth) }, nested, model, thinking };
}

// One line per tool call for the progress card and the partial result.
export function describeToolCall(toolName: string, args: unknown): string {
  const a = (args ?? {}) as Record<string, unknown>;
  const detail = [a.query, a.url, a.command, a.path, a.pattern, a.agent, a.task]
    .find((value) => typeof value === "string" && value.trim());
  const text = typeof detail === "string" ? detail.replace(/\s+/g, " ").trim() : "";
  return text ? `${toolName}: ${text.length > 100 ? `${text.slice(0, 97)}…` : text}` : toolName;
}


export interface ChildProgress {
  toolCalls: string[];
  lastText: string;
  // Which of the two came last, so the card shows the newest activity.
  lastKind?: "tool" | "text";
  // The child's own delegate calls still running (a tier-1 member fanning out).
  subagents?: number;
  finalText?: string;
  // Set when an assistant message ends, so the next message's text starts a
  // fresh line instead of running on from the last one.
  messageEnded?: boolean;
}

// Reads one JSON-mode event line into the progress record. Non-JSON lines
// are kept as text so a child that fails before its event stream starts
// still reports something.
export function consumeEvent(progress: ChildProgress, line: string): "tool" | "text" | "final" | undefined {
  if (!line.trim()) return undefined;
  let event: any;
  try {
    event = JSON.parse(line);
  } catch {
    progress.lastText = line.trim();
    progress.lastKind = "text";
    return "text";
  }
  if (event?.type === "tool_execution_start") {
    progress.toolCalls.push(describeToolCall(String(event.toolName ?? "tool"), event.args));
    progress.lastKind = "tool";
    if (event.toolName === "delegate") progress.subagents = (progress.subagents ?? 0) + 1;
    return "tool";
  }
  if (event?.type === "tool_execution_end" && event.toolName === "delegate") {
    progress.subagents = Math.max(0, (progress.subagents ?? 0) - 1);
    return "tool";
  }
  if (event?.type === "message_update" && event.assistantMessageEvent?.type === "text_delta") {
    const delta = String(event.assistantMessageEvent.delta ?? "");
    const base = progress.messageEnded ? "" : progress.lastText;
    progress.messageEnded = false;
    const lines = `${base}${delta}`.split("\n").filter((l) => l.trim());
    progress.lastText = lines.length ? lines[lines.length - 1].slice(-200) : "";
    progress.lastKind = "text";
    return "text";
  }
  if (event?.type === "message_end" && event.message?.role === "assistant") {
    const parts = Array.isArray(event.message.content) ? event.message.content : [];
    const text = parts
      .filter((part: any) => part?.type === "text" && typeof part.text === "string")
      .map((part: any) => part.text)
      .join("");
    if (text.trim()) progress.finalText = text;
    progress.messageEnded = true;
    return "final";
  }
  return undefined;
}

export interface RunResult {
  progress: ChildProgress;
  stderr: string;
  code: number | null;
  timedOut: boolean;
  aborted: boolean;
}

export interface RunHooks {
  signal?: AbortSignal;
  timeoutMs?: number;
  env?: Record<string, string>;
  onProgress?: (progress: ChildProgress) => void;
}

// The task goes in on stdin: pi -p merges piped input into the prompt, and
// argv stays free of task text that could start with - or @. Without
// timeoutMs the child runs until it exits or the signal aborts it.
export function runChild(args: string[], task: string, cwd: string, hooks: RunHooks = {}): Promise<RunResult> {
  return new Promise((resolve) => {
    const child = spawn("pi", args, { cwd, env: { ...process.env, ...hooks.env }, stdio: ["pipe", "pipe", "pipe"] });
    const progress: ChildProgress = { toolCalls: [], lastText: "" };
    let buffer = "";
    let stderr = "";
    let timedOut = false;
    let aborted = false;
    let settled = false;
    const timer = hooks.timeoutMs
      ? setTimeout(() => {
          timedOut = true;
          child.kill("SIGTERM");
        }, hooks.timeoutMs)
      : undefined;
    const onAbort = () => {
      aborted = true;
      child.kill("SIGTERM");
    };
    if (hooks.signal?.aborted) onAbort();
    else hooks.signal?.addEventListener("abort", onAbort, { once: true });

    const consume = (line: string) => {
      if (consumeEvent(progress, line)) hooks.onProgress?.(progress);
    };
    const finish = (code: number | null) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      hooks.signal?.removeEventListener("abort", onAbort);
      if (buffer.trim()) consume(buffer);
      buffer = "";
      resolve({ progress, stderr, code, timedOut, aborted });
    };

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      buffer += chunk;
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) consume(line);
    });
    child.stderr.on("data", (chunk: string) => (stderr += chunk));
    child.on("error", (error) => {
      stderr += error.message;
      finish(null);
    });
    child.on("close", (code) => finish(code));
    child.stdin.end(task);
  });
}

// ── Rendering ──────────────────────────────────────────────────────────────
// Plain components ({ render, invalidate }) so the extension imports nothing
// from pi at runtime and node --test can load it.

type Status = "running" | "done" | "error" | "stopped";
const STATUS: Record<Status, [color: string, icon: string, verb: string]> = {
  running: ["accent", "●", "is running"],
  done: ["success", "✓", "finished"],
  error: ["error", "✗", "failed"],
  stopped: ["warning", "■", "was stopped"],
};
export const COLLAPSED_REPORT_LINES = 8;
export const CARDS_WIDGET = "delegate-cards";

const flat = (text: string) => text.replace(/\s+/g, " ").trim();

export function truncate(text: string, width: number): string {
  if (width <= 0) return "";
  const chars = Array.from(text);
  return chars.length <= width ? text : `${chars.slice(0, Math.max(0, width - 1)).join("")}…`;
}

// Word-wraps to width, breaking a word only when it is longer than a line.
export function wrap(text: string, width: number): string[] {
  const w = Math.max(1, width);
  const out: string[] = [];
  for (const raw of text.replace(/\t/g, "  ").split("\n")) {
    let rest = Array.from(raw.trimEnd());
    while (rest.length > w) {
      let cut = rest.lastIndexOf(" ", w);
      if (cut <= 0) cut = w;
      out.push(rest.slice(0, cut).join("").trimEnd());
      rest = Array.from(rest.slice(cut).join("").trimStart());
    }
    out.push(rest.join(""));
  }
  return out;
}

export interface CardState {
  id: number;
  name: string;
  task: string;
  turn: number;
  status: Status;
  startedAt: number;
  endedAt?: number;
  progress: ChildProgress;
  wait?: boolean;
}

// One delegate's card, in the subagent widget's shape: a blank line, a dim
// rule, the header, the newest activity line, a dim rule. The header is the
// widget's "● Subagent #1 · Turn 2  task  (12s) | Tools: 5" with the member
// name after the number, "· wait" for a blocking call and "· 2 subagents"
// while a tier-1 delegate's own delegations run.
export const CARD_TASK_CHARS = 40;
export function cardLines(card: CardState, width: number, theme: any, now = Date.now()): string[] {
  const inner = Math.max(10, width - 2);
  const len = (text: string) => Array.from(text).length;
  const [color, icon] = STATUS[card.status];
  const seconds = Math.round(((card.endedAt ?? now) - card.startedAt) / 1000);
  const label = `${icon} Delegate #${card.id} · ${card.name}`;
  const subs = card.status === "running" ? card.progress.subagents ?? 0 : 0;
  const tags = `${card.wait ? " · wait" : ""}${card.turn > 1 ? ` · Turn ${card.turn}` : ""}${subs ? ` · ${subs} subagent${subs > 1 ? "s" : ""}` : ""}`;
  const stats = `  (${seconds}s) | Tools: ${card.progress.toolCalls.length}`;
  const taskRoom = Math.min(CARD_TASK_CHARS, inner - len(label + tags + stats) - 2);
  const task = taskRoom > 8 && card.task ? `  ${truncate(flat(card.task), taskRoom)}` : "";
  const header = len(label + tags + task + stats) <= inner
    ? theme.fg(color, label) + theme.fg("dim", tags + task + stats)
    : theme.fg(color, truncate(label + tags + stats, inner));
  const lines = [` ${header}`];
  const lastTool = card.progress.toolCalls.at(-1);
  const activity = card.progress.lastKind === "tool" ? lastTool : card.progress.lastText || lastTool;
  if (activity) lines.push(` ${theme.fg("muted", `  ${truncate(flat(activity), inner - 2)}`)}`);
  const rule = theme.fg("dim", "─".repeat(Math.max(1, width)));
  return ["", rule, ...lines, rule];
}

// Every visible card in one widget, sharing the rule between neighbours:
// separate widgets left a blank line and a doubled rule between cards.
export function cardStack(cards: CardState[], width: number, theme: any, now = Date.now()): string[] {
  return cards.flatMap((card, index) => cardLines(card, width, theme, now).slice(index ? 2 : 0));
}

// One row on a background colour, padded to the full width with a space
// either side, as pi paints a tool row and shells.ts its cards. plain is
// the unstyled text, for the width count.
export function paintRow(theme: any, bg: string, width: number, plain = "", styled = plain): string {
  const text = plain ? ` ${styled}` : "";
  const used = plain ? Array.from(plain).length + 1 : 0;
  return theme.bg(bg, text + " ".repeat(Math.max(0, width - used)));
}

// Report and tool-row backgrounds, matching shells.ts: green for a clean
// finish, red for a failure, the neutral pending shade otherwise.
export const REPORT_BG: Record<Status, string> = {
  running: "toolPendingBg",
  done: "toolSuccessBg",
  error: "toolErrorBg",
  stopped: "toolPendingBg",
};
export const ROW_BG = "toolPendingBg";

// line on the gray pending shade with a padding row above (renderShell
// "self", so pi adds no box of its own and the block stays compact). Until
// a result arrives the row also closes the block with a padding row; the
// result rows take over that padding once resultRows marks the row's shared
// renderer state.
export function callRow(title: string, target: string, flags: string, task: unknown, context?: any) {
  return (theme: any) => ({
    render(width: number): string[] {
      const inner = Math.max(10, width - 2);
      const head = `${title}${target ? ` ${target}` : ""}${flags}`;
      const styledHead = theme.fg("toolTitle", theme.bold(title)) + (target ? theme.fg("accent", ` ${target}`) : "") + theme.fg("dim", flags);
      const room = inner - Array.from(head).length - 2;
      const text = flat(String(task ?? ""));
      const row = room > 8 && text
        ? paintRow(theme, ROW_BG, width, `${head}  ${truncate(text, room)}`, `${styledHead}${theme.fg("dim", `  ${truncate(text, room)}`)}`)
        : paintRow(theme, ROW_BG, width, truncate(head, inner), Array.from(head).length <= inner ? styledHead : truncate(head, inner));
      const closing = context?.state?.hasResult ? [] : [paintRow(theme, ROW_BG, width)];
      return [paintRow(theme, ROW_BG, width), row, ...closing];
    },
    invalidate() {},
  });
}

// "gpt-6.1-sol (high)": the model id without its provider, as the status
// line shows it, and the thinking level.
export function modelLabel(model: string | undefined, thinking: string | undefined): string {
  const id = model ? model.slice(model.indexOf("/") + 1) : "default model";
  return thinking ? `${id} (${thinking})` : id;
}

// Under the call row, still on its gray: "↳ Delegate #N <state> · <model>
// (<thinking>)" and a padding row. A background run stops there (its card
// and report message show the rest). A blocking run's report, or any
// error, follows as its own block after a blank line, on green or red,
// collapsed like the delegate message. The run's details arrive with the
// first partial update and are kept in the row's shared renderer state, so
// an error result, which carries none, still names the run.
export function resultRows(result: any, options: any, theme: any, context?: any) {
  const details = result?.details ?? {};
  if (context?.state) {
    context.state.hasResult = true;
    if (details.id) context.state.meta = details;
  }
  const meta = details.id ? details : context?.state?.meta ?? {};
  return {
    render(width: number): string[] {
      const inner = Math.max(10, width - 2);
      const isError = Boolean(context?.isError);
      const verb = details.background ? "started" : options?.isPartial ? "running" : isError ? "failed" : "finished";
      const rows: string[] = [];
      if (meta.id) {
        const plain = truncate(`  ↳ Delegate #${meta.id} ${verb} · ${modelLabel(meta.model, meta.thinking)}`, inner);
        rows.push(paintRow(theme, ROW_BG, width, plain, theme.fg("dim", plain)));
      }
      rows.push(paintRow(theme, ROW_BG, width));
      if (details.background || options?.isPartial) return rows;
      const content = (result?.content ?? []).map((part: any) => part?.text ?? "").join("").trim();
      // The bracketed notes are for the model; the collapsed view leaves them out.
      const text = options?.expanded ? content : content.replace(/(\n*\[[^\n]*\])+\s*$/, "");
      if (!text) return rows;
      const bg = isError ? REPORT_BG.error : REPORT_BG.done;
      const body = wrap(text, inner);
      const shown = options?.expanded ? body : body.slice(0, COLLAPSED_REPORT_LINES);
      rows.push("", paintRow(theme, bg, width));
      for (const line of shown) rows.push(paintRow(theme, bg, width, line, theme.fg("toolOutput", line)));
      if (shown.length < body.length) {
        const more = `… ${body.length - shown.length} more lines, expand to read`;
        rows.push(paintRow(theme, bg, width, more, theme.fg("dim", more)));
      }
      rows.push(paintRow(theme, bg, width));
      return rows;
    },
    invalidate() {},
  };
}

// The report message, painted like a shells.ts card: a padding row, the
// status header, the report (eight lines collapsed), a padding row.
export function reportLines(details: any, report: string, expanded: boolean, theme: any, width: number): string[] {
  const status: Status = STATUS[details.status as Status] ? details.status : "done";
  const [color, icon] = STATUS[status];
  const bg = REPORT_BG[status];
  const inner = Math.max(10, width - 2);
  const label = `${icon} delegate #${details.id ?? "?"} ${details.name ?? ""}`;
  const stats = `  ${details.seconds ?? "?"}s · ${details.toolCalls ?? 0} tools${details.turn > 1 ? ` · turn ${details.turn}` : ""}`;
  const header = Array.from(label + stats).length <= inner
    ? paintRow(theme, bg, width, label + stats, theme.fg(color, theme.bold(label)) + theme.fg("dim", stats))
    : paintRow(theme, bg, width, truncate(label, inner), theme.fg(color, theme.bold(truncate(label, inner))));
  const lines = [paintRow(theme, bg, width), header];
  // The bracketed notes (delegate number, tool count, session file) are
  // for the model; the collapsed view leaves them out.
  const text = expanded ? report : report.replace(/(\n*\[[^\n]*\])+\s*$/, "");
  const body = wrap(text, inner);
  const shown = expanded ? body : body.slice(0, COLLAPSED_REPORT_LINES);
  for (const line of shown) lines.push(paintRow(theme, bg, width, line, theme.fg("toolOutput", line)));
  if (shown.length < body.length) {
    const more = `… ${body.length - shown.length} more lines, expand to read`;
    lines.push(paintRow(theme, bg, width, more, theme.fg("dim", more)));
  }
  lines.push(paintRow(theme, bg, width));
  return lines;
}

function snippet(members: Member[]): string {
  const names = members.map((member) => `${member.name} (${member.description.split(/\.\s|\n/)[0].trim()})`);
  const list = names.length ? ` Members: ${names.join("; ")}.` : "";
  return `Run a subagent in the background and get its report as a message when it finishes; without an agent, a generalist on your own model.${list}`;
}

interface Run extends CardState {
  member: Member;
  cwd: string;
  thinking?: string;
  modelOverride?: string;
  sessionFile: string;
  hidden: boolean;
  controller?: AbortController;
  pending?: Promise<Outcome>;
  cancelled?: boolean;
  stopRequested?: boolean;
  dropped?: boolean;
}

interface Outcome {
  ok: boolean;
  text: string;
}

export default function (pi: ExtensionAPI) {
  if (projectOverrides()) return;
  if (currentDepth() >= MAX_DEPTH) return;
  // A tier-1 child has no UI, so its delegate calls block; several in one
  // message still run side by side.
  const nested = currentDepth() > 0;
  const members = listMembers(process.cwd());
  const runs = new Map<number, Run>();
  let nextId = 1;
  let uiCtx: any;
  let tui: any;
  let ticker: ReturnType<typeof setInterval> | undefined;

  const runningCount = () => [...runs.values()].filter((run) => run.status === "running").length;
  let lastRunning = 0;
  const emitRunning = () => {
    const count = runningCount();
    if (count === lastRunning) return;
    lastRunning = count;
    pi.events?.emit("pif:subagents", { running: count });
  };
  const redraw = () => {
    emitRunning();
    if (runningCount() === 0 && ticker) {
      clearInterval(ticker);
      ticker = undefined;
    }
    tui?.requestRender?.();
  };
  // One widget holds every visible card, in delegate order.
  const visibleRuns = () => [...runs.values()].filter((run) => !run.hidden).sort((a, b) => a.id - b.id);
  const syncCards = () => {
    try {
      if (!uiCtx?.hasUI) return;
      if (!visibleRuns().length) return uiCtx.ui.setWidget(CARDS_WIDGET, undefined);
      uiCtx.ui.setWidget(CARDS_WIDGET, (widgetTui: any, theme: any) => {
        tui = widgetTui;
        return { render: (width: number) => cardStack(visibleRuns(), width, theme), invalidate() {} };
      });
    } catch {
      // The UI is gone at shutdown.
    }
  };
  const showCard = (run: Run) => {
    run.hidden = false;
    syncCards();
  };
  const hideCard = (run: Run) => {
    run.hidden = true;
    syncCards();
  };

  // Turns a finished child into the report text, and marks the card.
  const settle = (run: Run, result: RunResult, unmappedTools: string[]): Outcome => {
    const text = (result.progress.finalText ?? result.progress.lastText).trim();
    const name = run.member.name;
    run.progress = result.progress;
    run.endedAt = Date.now();
    run.controller = undefined;
    const stderrLast = result.stderr.trim().split("\n").filter((l) => l.trim()).at(-1);
    let outcome: Outcome;
    if (result.aborted) {
      run.status = "stopped";
      const verb = run.cancelled ? "cancelled" : "stopped";
      outcome = { ok: false, text: `${name} was ${verb}.${text ? `\n\nPartial output:\n${text}` : ""}` };
    } else if (result.timedOut) {
      run.status = "stopped";
      outcome = {
        ok: false,
        text: `${name} reached the ${CHILD_TIMEOUT_MS / 60000} minute cap and was stopped. Its session is kept: delegate_continue with id ${run.id} resumes it.${text ? `\n\nPartial output:\n${text}` : ""}`,
      };
    } else if (result.code !== 0 && !text) {
      run.status = "error";
      // The card's activity line shows why it failed, as the widget did.
      if (stderrLast) {
        run.progress.lastText = stderrLast;
        run.progress.lastKind = "text";
      }
      outcome = {
        ok: false,
        text: `${name} exited with code ${result.code ?? "unknown"}.${result.stderr.trim() ? `\n\n${result.stderr.trim()}` : ""}`,
      };
    } else {
      run.status = result.code === 0 ? "done" : "error";
      const notes: string[] = [];
      if (unmappedTools.length) notes.push(`Tools without a pi equivalent were skipped: ${unmappedTools.join(", ")}.`);
      if (result.code !== 0) notes.push(`The subagent exited with code ${result.code}; its output may be incomplete.`);
      notes.push(`delegate #${run.id}; ${result.progress.toolCalls.length} tool calls; session ${run.sessionFile}.`);
      const body = text.length > RESULT_CAP_CHARS ? `${text.slice(0, RESULT_CAP_CHARS)}\n\n[Report truncated at ${RESULT_CAP_CHARS} characters.]` : text;
      outcome = { ok: true, text: `${body || "(the subagent returned no text)"}\n\n${notes.map((note) => `[${note}]`).join("\n")}` };
    }
    redraw();
    return outcome;
  };

  // A background report lands before the parent's next model call, or
  // starts a turn when the parent is idle.
  const deliver = (run: Run, outcome: Outcome) => {
    if (run.dropped || run.stopRequested) return;
    const seconds = Math.round(((run.endedAt ?? Date.now()) - run.startedAt) / 1000);
    const turn = run.turn > 1 ? `, turn ${run.turn}` : "";
    const header = `Delegate #${run.id} (${run.member.name}${turn}) ${STATUS[run.status][2]} after ${seconds}s.`;
    pi.sendMessage(
      {
        customType: "delegate",
        content: `${header}\n\n${outcome.text}`,
        display: true,
        details: { id: run.id, name: run.member.name, status: run.status, seconds, toolCalls: run.progress.toolCalls.length, turn: run.turn },
      },
      { deliverAs: "steer", triggerTurn: true },
    );
  };

  const start = async (run: Run, plan: ChildPlan, task: string, wait: boolean, signal?: AbortSignal, onUpdate?: (partial: any) => void) => {
    const meta = { id: run.id, model: plan.model, thinking: plan.thinking };
    mkdirSync(join(plan.sessionFile, ".."), { recursive: true });
    run.status = "running";
    run.task = task;
    run.startedAt = Date.now();
    run.endedAt = undefined;
    run.progress = { toolCalls: [], lastText: "" };
    run.cancelled = false;
    run.stopRequested = false;
    run.wait = wait;
    run.controller = new AbortController();
    const controller = run.controller;
    showCard(run);
    if (!ticker) ticker = setInterval(redraw, 1000);
    redraw();
    if (wait) {
      signal?.addEventListener(
        "abort",
        () => {
          run.cancelled = true;
          controller.abort();
        },
        { once: true },
      );
    }
    run.pending = runChild(plan.args, task, run.cwd, {
      signal: controller.signal,
      timeoutMs: CHILD_TIMEOUT_MS,
      env: plan.env,
      onProgress: (progress) => {
        run.progress = progress;
        tui?.requestRender?.();
      },
    }).then((result) => settle(run, result, plan.unmappedTools));
    if (wait) {
      // Names the run and its model on the row while the call blocks.
      onUpdate?.({ content: [{ type: "text", text: "" }], details: meta });
      const outcome = await run.pending;
      if (!outcome.ok) throw new Error(outcome.text);
      return { content: [{ type: "text", text: outcome.text }], details: meta };
    }
    run.pending.then((outcome) => deliver(run, outcome));
    return {
      content: [
        {
          type: "text",
          text: `Delegate #${run.id} (${run.member.name}) started in the background. Its report arrives as a "Delegate #${run.id}" message when it finishes; carry on meanwhile.`,
        },
      ],
      details: { ...meta, background: true },
    };
  };

  const dropAll = () => {
    for (const run of runs.values()) {
      run.dropped = true;
      run.controller?.abort();
      run.hidden = true;
    }
    syncCards();
    runs.clear();
    nextId = 1;
    redraw();
  };

  pi.on?.("session_start", () => dropAll());
  pi.on?.("session_shutdown", () => dropAll());
  // Finished cards stay until the user's next prompt; reports arriving as
  // messages do not dismiss them.
  pi.on?.("input", (event: any, ctx: any) => {
    if (event?.source === "extension") return;
    if (ctx?.hasUI) uiCtx = ctx;
    for (const run of runs.values()) if (run.status !== "running") run.hidden = true;
    syncCards();
  });

  pi.registerMessageRenderer?.("delegate", (message: any, options: any, theme: any) => ({
    render(width: number): string[] {
      const content = typeof message.content === "string"
        ? message.content
        : (message.content ?? []).map((part: any) => part?.text ?? "").join("");
      const report = content.split("\n").slice(2).join("\n").trim();
      return reportLines(message.details ?? {}, report, Boolean(options?.expanded), theme, width);
    },
    invalidate() {},
  }));

  pi.registerTool({
    name: "delegate",
    label: "Delegate",
    description: nested
      ? "Run a subagent on a task in a separate pi process and return its final report. With agent, a named member with the tools its definition lists; without, a generalist on your own model with the built-in file and shell tools. The subagent does not see this conversation, so the task must carry everything it needs, and it cannot delegate further. Several delegate calls in one message run side by side."
      : "Run a subagent on a task in a separate pi process. By default it runs in the background: this returns a delegate number at once, you keep working (other tools, more delegations), and the subagent's final report arrives later as a \"Delegate #N\" message. With wait: true the call blocks and returns the report instead. With agent, a named member with the tools its definition lists; without, a generalist on your own model with the built-in file and shell tools. The subagent does not see this conversation, so the task must carry everything it needs. A run is stopped after an hour; delegate_continue resumes it from its kept session.",
    promptSnippet: snippet(members),
    promptGuidelines: nested ? [
      "Use delegate with agent research for any question that needs more than a couple of web searches; give it the full question and what a good answer looks like, and work from its brief instead of searching yourself.",
      "Delegate without an agent for a bounded piece of your task you want done apart; name the files and the checks to run. Partition concurrent writing delegations by file or subsystem.",
      "Here delegate blocks until the subagent finishes and returns its report. To run several at once, put the delegate calls in one message.",
    ] : [
      "Use delegate with agent research for any question that needs more than a couple of web searches; give it the full question and what a good answer looks like, and work from its brief instead of searching yourself.",
      "A research brief already carries its sources and quotes; treat it as the answer and build on it. Fetch a cited page again when a claim in it looks off or the user wants more from that source, not as a routine check.",
      "Delegate without an agent for a bounded piece of work you want done apart from this conversation; name the files and the checks to run. Partition concurrent writing delegations by file or subsystem.",
      "delegate returns at once and the report arrives later as a Delegate #N message, before your next model call. Keep working or delegate more meanwhile; when nothing else is useful, end your turn with a one-line note so the user can keep talking. Do not poll, sleep or check for the report.",
      "Pass wait: true only when your very next step needs the report and nothing else can run first.",
      "delegate_continue sends a follow-up to a finished delegate, which keeps its session; delegate_stop ends one that is off track or no longer needed.",
    ],
    parameters: {
      type: "object",
      properties: {
        task: { type: "string", description: "The complete task, self-contained: the subagent has no access to this conversation." },
        agent: {
          type: "string",
          description: `Member name${members.length ? ` (one of: ${members.map((member) => member.name).join(", ")})` : ""}; omit for a generalist.`,
        },
        model: { type: "string", description: "Optional provider/model override for this run. Leave unset unless the user asked." },
        wait: { type: "boolean", description: "Block until the subagent finishes and return its report as this tool's result. Default false: run in the background." },
      },
      required: ["task"],
    } as any,
    renderShell: "self",
    // While the arguments stream, an absent agent may still be on its way.
    renderCall: (args: any, theme: any, context?: any) =>
      callRow("delegate", args?.agent?.trim() || (context?.argsComplete === false ? "" : GENERALIST_NAME), args?.wait ? " · wait" : "", args?.task, context)(theme),
    renderResult: resultRows,
    async execute(_toolCallId, params: { task: string; agent?: string; model?: string; wait?: boolean }, signal, onUpdate, ctx) {
      const cwd = ctx.cwd ?? process.cwd();
      if (ctx?.hasUI) uiCtx = ctx;
      let member: Member;
      let thinking: string | undefined;
      if (params.agent?.trim()) {
        const path = resolveMember(params.agent.trim(), cwd);
        if (!path) throw new Error(`No subagent named "${params.agent}" under ${memberDirs(cwd).join(", ")}.`);
        member = parseMember(readFileSync(path, "utf8"), path);
      } else {
        const model = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
        member = generalistMember(model);
        thinking = pi.getThinkingLevel?.() ?? undefined;
      }
      const plan = buildChildArgs(member, { cwd, modelOverride: params.model, thinking });
      const run: Run = {
        id: nextId++,
        name: member.name,
        task: params.task,
        turn: 1,
        status: "running",
        startedAt: Date.now(),
        progress: { toolCalls: [], lastText: "" },
        member,
        cwd,
        thinking,
        modelOverride: params.model,
        sessionFile: plan.sessionFile,
        hidden: false,
      };
      runs.set(run.id, run);
      // Without a UI (pif -p) nothing would receive a background report.
      return start(run, plan, params.task, Boolean(params.wait) || !ctx?.hasUI, signal, onUpdate);
    },
  });

  pi.registerTool({
    name: "delegate_continue",
    label: "Delegate continue",
    description:
      "Send a follow-up task to a finished delegate. It resumes the subagent's kept session, so it remembers its earlier work. Runs in the background like delegate unless wait is true.",
    parameters: {
      type: "object",
      properties: {
        id: { type: "number", description: "The delegate number, from Delegate #N." },
        task: { type: "string", description: "The follow-up instructions." },
        model: { type: "string", description: "Optional provider/model override for this turn. Leave unset unless the user asked." },
        wait: { type: "boolean", description: "Block until the subagent finishes and return its report. Default false." },
      },
      required: ["id", "task"],
    } as any,
    renderShell: "self",
    renderCall: (args: any, theme: any, context?: any) => callRow("delegate_continue", `#${args?.id ?? "?"}`, args?.wait ? " · wait" : "", args?.task, context)(theme),
    renderResult: resultRows,
    async execute(_toolCallId, params: { id: number; task: string; model?: string; wait?: boolean }, signal, onUpdate, ctx) {
      if (ctx?.hasUI) uiCtx = ctx;
      const run = runs.get(Number(params.id));
      if (!run) throw new Error(`No delegate #${params.id} in this session.`);
      if (run.status === "running") throw new Error(`Delegate #${run.id} is still running; wait for its report or stop it.`);
      const plan = buildChildArgs(run.member, {
        cwd: run.cwd,
        modelOverride: params.model ?? run.modelOverride,
        thinking: run.thinking,
        sessionFile: run.sessionFile,
      });
      run.turn += 1;
      return start(run, plan, params.task, Boolean(params.wait) || !ctx?.hasUI, signal, onUpdate);
    },
  });

  pi.registerTool({
    name: "delegate_stop",
    label: "Delegate stop",
    description: "Stop a running delegate and return whatever it had written so far. Its session is kept, so delegate_continue can pick it up again.",
    parameters: {
      type: "object",
      properties: { id: { type: "number", description: "The delegate number, from Delegate #N." } },
      required: ["id"],
    } as any,
    renderShell: "self",
    renderCall: (args: any, theme: any, context?: any) => callRow("delegate_stop", `#${args?.id ?? "?"}`, "", "", context)(theme),
    renderResult: resultRows,
    async execute(_toolCallId, params: { id: number }) {
      const run = runs.get(Number(params.id));
      if (!run) throw new Error(`No delegate #${params.id} in this session.`);
      if (run.status !== "running") return { content: [{ type: "text", text: `Delegate #${run.id} is not running; it ${STATUS[run.status][2]}.` }] };
      run.stopRequested = true;
      run.controller?.abort();
      const outcome = await run.pending!;
      return { content: [{ type: "text", text: outcome.text }] };
    },
  });
}
