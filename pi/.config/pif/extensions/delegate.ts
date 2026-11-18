// Synchronous delegation to a subagent: a profiled member defined in Claude
// Code's front matter format (name, description, model, tools) plus a
// pi_model key naming the pi model to run it on, or, with no agent named, a
// generalist on the parent's model with the built-in tools.
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
// it does in the parent. The child's event stream feeds a progress card and
// the tool's partial result while it runs; its last assistant message is the
// tool result. The call blocks until the child exits, which is what a driver
// needs mid-reasoning; pi runs sibling tool calls concurrently, so several
// delegations in one assistant message still run side by side.
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
import { existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const CHILD_TIMEOUT_MS = 10 * 60 * 1000;
export const MEMBER_THINKING = "low";
export const RESULT_CAP_CHARS = 24_000;
export const GENERALIST_NAME = "generalist";
export const PROJECT_OVERRIDE = join(".pi", "extensions", "delegate.ts");

export function projectOverrides(cwd = process.cwd()): boolean {
  return existsSync(join(cwd, PROJECT_OVERRIDE));
}
export const GENERALIST_TOOLS = ["Read", "Write", "Edit", "Bash", "Grep", "Glob", "Ls"];
export const GENERALIST_DIRECTIVE = [
  "You are a delegated implementation and research subagent.",
  "Stay within the task and files delegated by the parent. You may create or modify files when the task asks for implementation.",
  "Do not revert unrelated changes or edit files assigned to concurrent agents. Run relevant checks.",
  "Report changed files, checks run, and unresolved concerns.",
].join(" ");
const PROGRESS_LINES = 6;

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
}

export interface ChildPlan {
  args: string[];
  unmappedTools: string[];
  sessionFile: string;
}

export function sessionFileFor(name: string, now = Date.now()): string {
  return join(sessionsDir(), "delegate", `${name}-${now}.jsonl`);
}

export function buildChildArgs(member: Member, options: ChildOptions): ChildPlan {
  const sessionFile = options.sessionFile ?? sessionFileFor(member.name);
  const args = ["--mode", "json", "-p", "--session", sessionFile, "--no-skills", "--no-extensions"];
  const profile = profileDir();
  const needsWeb = member.tools.some((tool) => WEB_TOOLS.has(tool));
  if (needsWeb) {
    args.push("-e", join(profile, "extensions", "web.ts"));
    for (const loader of projectLoaders(options.cwd)) args.push("-e", loader);
  }
  const mapped: string[] = [];
  const unmappedTools: string[] = [];
  for (const tool of member.tools) {
    const piName = TOOL_MAP[tool];
    if (piName) mapped.push(piName);
    else unmappedTools.push(tool);
  }
  if (member.tools.length > 0) args.push("--tools", mapped.join(","));
  const model = options.modelOverride?.trim() || member.piModel;
  if (model) args.push("--model", model);
  args.push("--thinking", options.thinking ?? MEMBER_THINKING);
  const communication = join(profile, "communication.md");
  if (existsSync(communication)) args.push("--append-system-prompt", communication);
  if (member.body) args.push("--append-system-prompt", member.body);
  return { args, unmappedTools, sessionFile };
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
  finalText?: string;
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
    return "text";
  }
  if (event?.type === "tool_execution_start") {
    progress.toolCalls.push(describeToolCall(String(event.toolName ?? "tool"), event.args));
    return "tool";
  }
  if (event?.type === "message_update" && event.assistantMessageEvent?.type === "text_delta") {
    const delta = String(event.assistantMessageEvent.delta ?? "");
    const combined = `${progress.lastText}${delta}`;
    const lines = combined.split("\n").filter((l) => l.trim());
    progress.lastText = lines.length ? lines[lines.length - 1].slice(-200) : "";
    return "text";
  }
  if (event?.type === "message_end" && event.message?.role === "assistant") {
    const parts = Array.isArray(event.message.content) ? event.message.content : [];
    const text = parts
      .filter((part: any) => part?.type === "text" && typeof part.text === "string")
      .map((part: any) => part.text)
      .join("");
    if (text.trim()) progress.finalText = text;
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
  onProgress?: (progress: ChildProgress) => void;
}

// The task goes in on stdin: pi -p merges piped input into the prompt, and
// argv stays free of task text that could start with - or @.
export function runChild(args: string[], task: string, cwd: string, hooks: RunHooks = {}): Promise<RunResult> {
  return new Promise((resolve) => {
    const child = spawn("pi", args, { cwd, env: { ...process.env }, stdio: ["pipe", "pipe", "pipe"] });
    const progress: ChildProgress = { toolCalls: [], lastText: "" };
    let buffer = "";
    let stderr = "";
    let timedOut = false;
    let aborted = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, CHILD_TIMEOUT_MS);
    const onAbort = () => {
      aborted = true;
      child.kill("SIGTERM");
    };
    hooks.signal?.addEventListener("abort", onAbort, { once: true });
    const consume = (line: string) => {
      if (consumeEvent(progress, line)) hooks.onProgress?.(progress);
    };
    const finish = (code: number | null) => {
      clearTimeout(timer);
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

export function progressText(name: string, progress: ChildProgress, elapsedMs: number): string {
  const recent = progress.toolCalls.slice(-PROGRESS_LINES);
  const lines = [`${name} running for ${Math.round(elapsedMs / 1000)}s, ${progress.toolCalls.length} tool calls`];
  for (const call of recent) lines.push(`  ${call}`);
  if (progress.lastText) lines.push(`  > ${progress.lastText}`);
  return lines.join("\n");
}

function snippet(members: Member[]): string {
  const names = members.map((member) => `${member.name} (${member.description.split(/\.\s|\n/)[0].trim()})`);
  const list = names.length ? ` Members: ${names.join("; ")}.` : "";
  return `Run a subagent and wait for its report; without an agent, a generalist on your own model.${list}`;
}

interface Card {
  name: string;
  status: "running" | "done" | "error";
  startedAt: number;
  progress: ChildProgress;
}

export default function (pi: ExtensionAPI) {
  if (projectOverrides()) return;
  const members = listMembers(process.cwd());
  const cards = new Map<string, Card>();
  let uiCtx: any;
  let ticker: ReturnType<typeof setInterval> | undefined;

  const running = () => [...cards.values()].filter((card) => card.status === "running").length;
  let lastRunning = 0;
  const emitRunning = () => {
    const count = running();
    if (count === lastRunning) return;
    lastRunning = count;
    pi.events?.emit("pif:subagents", { running: count });
  };

  const renderCards = () => {
    emitRunning();
    if (running() === 0 && ticker) {
      clearInterval(ticker);
      ticker = undefined;
    }
    if (!uiCtx?.hasUI) return;
    for (const [key, card] of cards) {
      const icon = card.status === "running" ? "●" : card.status === "done" ? "✓" : "✗";
      const elapsed = Math.round((Date.now() - card.startedAt) / 1000);
      const lines = [`${icon} ${card.name}  ${elapsed}s  tools: ${card.progress.toolCalls.length}`];
      const last = card.progress.toolCalls.at(-1);
      if (last) lines.push(`  ${last}`);
      if (card.progress.lastText) lines.push(`  > ${card.progress.lastText.slice(0, 120)}`);
      uiCtx.ui.setWidget(key, lines);
    }
  };

  const clearCards = () => {
    for (const key of cards.keys()) uiCtx?.hasUI && uiCtx.ui.setWidget(key, undefined);
    cards.clear();
    renderCards();
  };
  // Finished cards stay visible until the parent's turn ends.
  pi.on?.("agent_end", () => clearCards());

  pi.registerTool({
    name: "delegate",
    label: "Delegate",
    description:
      "Run a subagent on a task in a separate pi process and return its final report. With agent, a named member with the tools its definition lists; without, a generalist on your own model with the built-in file and shell tools. The subagent does not see this conversation, so the task must carry everything it needs. Several delegate calls in one message run side by side.",
    promptSnippet: snippet(members),
    promptGuidelines: [
      "Use delegate with agent research for any question that needs more than a couple of web searches; give it the full question and what a good answer looks like, and work from its brief instead of searching yourself.",
      "A research brief already carries its sources and quotes; treat it as the answer and build on it. Fetch a cited page again when a claim in it looks off or the user wants more from that source, not as a routine check.",
      "Delegate without an agent for a bounded piece of work you want done apart from this conversation; name the files and the checks to run.",
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
      },
      required: ["task"],
    } as any,
    async execute(toolCallId, params: { task: string; agent?: string; model?: string }, signal, onUpdate, ctx) {
      const cwd = ctx.cwd ?? process.cwd();
      uiCtx = ctx;
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
      mkdirSync(join(plan.sessionFile, ".."), { recursive: true });

      const key = `delegate-${toolCallId}`;
      const card: Card = { name: member.name, status: "running", startedAt: Date.now(), progress: { toolCalls: [], lastText: "" } };
      cards.set(key, card);
      if (!ticker) ticker = setInterval(renderCards, 1000);
      renderCards();
      const report = (progress: ChildProgress) => {
        card.progress = progress;
        onUpdate?.({ content: [{ type: "text", text: progressText(member.name, progress, Date.now() - card.startedAt) }] });
        renderCards();
      };

      const run = await runChild(plan.args, params.task, cwd, { signal, onProgress: report });
      const text = (run.progress.finalText ?? run.progress.lastText).trim();
      card.status = run.code === 0 && !run.timedOut && !run.aborted ? "done" : "error";
      renderCards();

      if (run.aborted) throw new Error(`${member.name} was cancelled.`);
      if (run.timedOut) {
        throw new Error(`${member.name} exceeded ${CHILD_TIMEOUT_MS / 60000} minutes and was stopped.${text ? `\n\nPartial output:\n${text}` : ""}`);
      }
      if (run.code !== 0 && !text) {
        throw new Error(`${member.name} exited with code ${run.code ?? "unknown"}.${run.stderr.trim() ? `\n\n${run.stderr.trim()}` : ""}`);
      }
      const notes: string[] = [];
      if (plan.unmappedTools.length) notes.push(`Tools without a pi equivalent were skipped: ${plan.unmappedTools.join(", ")}.`);
      if (run.code !== 0) notes.push(`The subagent exited with code ${run.code}; its output may be incomplete.`);
      notes.push(`${run.progress.toolCalls.length} tool calls; session ${plan.sessionFile}.`);
      let result = text.length > RESULT_CAP_CHARS ? `${text.slice(0, RESULT_CAP_CHARS)}\n\n[Report truncated at ${RESULT_CAP_CHARS} characters.]` : text;
      result = `${result || "(the subagent returned no text)"}\n\n${notes.map((note) => `[${note}]`).join("\n")}`;
      return { content: [{ type: "text", text: result }] };
    },
  });
}
