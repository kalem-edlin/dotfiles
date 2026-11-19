// Run with: node --test pi/tests/delegate.test.mjs
// Loads the real TypeScript extension with Node's type stripping. The pi
// import is type-only; spawn is shimmed so no child pi ever starts.
import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { after, before, mock, test } from "node:test";

const profile = resolve("pi/.config/pif");
const sessions = mkdtempSync(join(tmpdir(), "delegate-sessions-"));
const spawns = [];
let nextChild;
let extension;
let helpers;
const originalSpawn = childProcess.spawn;
const originalProfile = process.env.PI_CODING_AGENT_DIR;
const originalSessions = process.env.PI_CODING_AGENT_SESSION_DIR;

const line = (event) => `${JSON.stringify(event)}\n`;
const finalMessage = (text) => line({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text }] } });
const toolStart = (toolName, args) => line({ type: "tool_execution_start", toolCallId: "t", toolName, args });
const textDelta = (delta) => line({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta } });

function fakeChild({ stdout = "", stderr = "", code = 0, hang = false } = {}) {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.stdout.setEncoding = () => {};
  child.stderr.setEncoding = () => {};
  child.stdin = { chunks: [], end(data) { this.chunks.push(data); } };
  child.kill = (signal) => {
    child.killed = signal;
    setImmediate(() => child.emit("close", null));
  };
  child.start = () => setImmediate(() => {
    if (stdout) child.stdout.emit("data", stdout);
    if (stderr) child.stderr.emit("data", stderr);
    if (!hang) child.emit("close", code);
  });
  return child;
}

before(async () => {
  childProcess.spawn = (file, args, options) => {
    spawns.push({ file, args, options });
    const child = nextChild ?? fakeChild();
    child.start();
    return child;
  };
  syncBuiltinESMExports();
  process.env.PI_CODING_AGENT_DIR = profile;
  process.env.PI_CODING_AGENT_SESSION_DIR = sessions;
  helpers = await import("../.config/pif/extensions/delegate.ts");
  extension = helpers.default;
});

after(() => {
  childProcess.spawn = originalSpawn;
  syncBuiltinESMExports();
  if (originalProfile === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = originalProfile;
  if (originalSessions === undefined) delete process.env.PI_CODING_AGENT_SESSION_DIR;
  else process.env.PI_CODING_AGENT_SESSION_DIR = originalSessions;
});

function project(members = {}, loaders = []) {
  const cwd = mkdtempSync(join(tmpdir(), "delegate-test-"));
  const dir = join(cwd, ".claude", "agents");
  mkdirSync(dir, { recursive: true });
  for (const [name, source] of Object.entries(members)) writeFileSync(join(dir, `${name}.md`), source);
  if (loaders.length) {
    mkdirSync(join(cwd, ".pi", "extensions"), { recursive: true });
    for (const file of loaders) writeFileSync(join(cwd, ".pi", "extensions", file), "export default () => {};\n");
  }
  return cwd;
}

// The slice of pi's extension API the extension touches at load time.
function fakePi(tools, { model, thinking = "high" } = {}) {
  const events = [];
  const messages = [];
  const renderers = new Map();
  const widgets = new Map();
  const tui = { renders: 0, requestRender() { this.renders++; } };
  return {
    api: {
      registerTool: (tool) => tools.set(tool.name, tool),
      registerMessageRenderer: (type, renderer) => renderers.set(type, renderer),
      sendMessage: (message, options) => messages.push({ message, options }),
      on: (name, handler) => events.push({ name, handler }),
      events: { emit: (name, data) => events.push({ name, data }) },
      getThinkingLevel: () => thinking,
    },
    events,
    messages,
    renderers,
    widgets,
    // The interactive UI: setWidget factories are built at once, as pi does.
    ctx: (cwd, { hasUI = false } = {}) => ({
      cwd,
      hasUI,
      model,
      ui: {
        setWidget(key, content) {
          if (content === undefined) widgets.delete(key);
          else widgets.set(key, typeof content === "function" ? content(tui, plainTheme) : content);
        },
      },
    }),
    fire: (name, ...args) => events.filter((e) => e.name === name && e.handler).forEach((e) => e.handler(...args)),
  };
}

// A theme that adds no escape codes, so rendered widths are character counts.
const plainTheme = { fg: (_color, text) => text, bold: (text) => text };
const tick = () => new Promise((done) => setImmediate(done));

function register(cwd, options) {
  const tools = new Map();
  const fake = fakePi(tools, options);
  const previousCwd = process.cwd();
  process.chdir(cwd);
  try {
    extension(fake.api);
  } finally {
    process.chdir(previousCwd);
  }
  return { tool: tools.get("delegate"), tools, fake };
}

const RESEARCH = [
  "---", "name: research", "description: Multi-search web research that returns a cited brief. Use it often.",
  "model: sonnet", "pi_model: openai-codex/gpt-6.1-sol", "tools: WebSearch, WebFetch, Read, Grep, Glob", "---",
  "", "Search, then report.", "",
].join("\n");

test("front matter parses into a member and the body is the directive", () => {
  const member = helpers.parseMember(RESEARCH, "/x/research.md");
  assert.equal(member.name, "research");
  assert.equal(member.model, "sonnet");
  assert.equal(member.piModel, "openai-codex/gpt-6.1-sol");
  assert.deepEqual(member.tools, ["WebSearch", "WebFetch", "Read", "Grep", "Glob"]);
  assert.equal(member.body, "Search, then report.");
  assert.match(member.description, /^Multi-search/);
  assert.throws(() => helpers.parseMember("no front matter", "/x/bad.md"), /no front matter/);
  assert.equal(helpers.parseMember("---\ndescription: d\n---\n", "/x/named.md").name, "named");
});

test("the shipped research member parses and names the web tools", () => {
  const members = helpers.listMembers(project());
  const research = members.find((member) => member.name === "research");
  assert(research, "research.md is reachable through the profile agents symlink");
  assert.equal(research.piModel, "openai-codex/gpt-6.1-sol");
  assert(research.tools.includes("WebSearch") && research.tools.includes("WebFetch"));
  assert(!research.tools.includes("Write") && !research.tools.includes("Bash"));
});

test("project members shadow profile members of the same name", () => {
  const cwd = project({
    research: RESEARCH.replace("pi_model: openai-codex/gpt-6.1-sol", "pi_model: openrouter/x/y"),
    scout: "---\nname: scout\ndescription: Repo lookup.\ntools: Read\n---\nLook.",
  });
  assert.equal(helpers.resolveMember("research", cwd), join(cwd, ".claude", "agents", "research.md"));
  assert.equal(helpers.resolveMember("scout", cwd), join(cwd, ".claude", "agents", "scout.md"));
  assert.equal(helpers.resolveMember("missing", cwd), undefined);
  assert.equal(helpers.resolveMember("../etc", cwd), undefined);
  const members = helpers.listMembers(cwd);
  assert.deepEqual(members.map((member) => member.name), ["research", "scout"]);
  assert.equal(members[0].piModel, "openrouter/x/y");
  assert.equal(helpers.resolveMember("research", project()), join(profile, "agents", "research.md"));
});

test("child args stream JSON into a kept session, map Claude tool names, and load web.ts then the repo loaders for web members", () => {
  const research = helpers.parseMember(RESEARCH, "/x/research.md");
  const cwd = project({}, ["search.ts", "notes.md"]);
  const plan = helpers.buildChildArgs(research, { cwd, sessionFile: "/s/research.jsonl" });
  assert.deepEqual(plan.unmappedTools, []);
  assert.deepEqual(plan.args, [
    "--mode", "json", "-p", "--session", "/s/research.jsonl", "--no-skills", "--no-extensions",
    "-e", join(profile, "extensions", "web.ts"),
    "-e", join(cwd, ".pi", "extensions", "search.ts"),
    "--tools", "web_search,web_fetch,read,grep,find",
    "--model", "openai-codex/gpt-6.1-sol",
    "--thinking", "low",
    "--append-system-prompt", join(profile, "communication.md"),
    "--append-system-prompt", "Search, then report.",
  ]);
  const override = helpers.buildChildArgs(research, { cwd: project(), modelOverride: "openrouter/a/b" }).args;
  assert.deepEqual(override.slice(override.indexOf("--model"), override.indexOf("--model") + 2), ["--model", "openrouter/a/b"]);
  assert.equal(override.filter((arg) => arg === "-e").length, 1, "no repo loaders without a .pi/extensions directory");
  const defaultSession = helpers.buildChildArgs(research, { cwd: project() }).sessionFile;
  assert.match(defaultSession, new RegExp(`^${sessions.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/delegate/research-\\d+-[0-9a-f]{6}\\.jsonl$`));
  // Parallel delegations in the same millisecond get separate session files.
  assert.notEqual(helpers.sessionFileFor("generalist", 1), helpers.sessionFileFor("generalist", 1));

  const local = helpers.parseMember("---\nname: local\ndescription: d\ntools: Read, Bash, Task\n---\nBody", "/x/local.md");
  const localPlan = helpers.buildChildArgs(local, { cwd: project({}, ["search.ts"]) });
  assert(!localPlan.args.includes("-e"), "repo loaders are not loaded for a member without web tools");
  assert(!localPlan.args.includes("--model"));
  assert.deepEqual(localPlan.args.slice(7, 9), ["--tools", "read,bash"]);
  assert.deepEqual(localPlan.unmappedTools, ["Task"]);

  const open = helpers.parseMember("---\nname: open\ndescription: d\n---\nBody", "/x/open.md");
  assert(!helpers.buildChildArgs(open, { cwd: project() }).args.includes("--tools"));
});

test("the generalist runs on the parent's model and thinking with the built-in tools", () => {
  const member = helpers.generalistMember("openai-codex/gpt-6.1-sol");
  assert.equal(member.name, "generalist");
  const plan = helpers.buildChildArgs(member, { cwd: project({}, ["search.ts"]), thinking: "high", depth: 0 });
  assert.deepEqual(plan.args.slice(7, 15), [
    "-e", join(profile, "extensions", "delegate.ts"),
    "--tools", "read,write,edit,bash,grep,find,ls,delegate", "--model", "openai-codex/gpt-6.1-sol", "--thinking", "high",
  ]);
  assert.deepEqual(plan.env, { PIF_DELEGATE_DEPTH: "1" });
  assert.equal(plan.args.at(-1), helpers.GENERALIST_DIRECTIVE);
  assert(!helpers.buildChildArgs(helpers.generalistMember(undefined), { cwd: project() }).args.includes("--model"));
});

test("JSON events become tool lines, a last line of text and the final message", () => {
  const progress = { toolCalls: [], lastText: "" };
  assert.equal(helpers.consumeEvent(progress, toolStart("web_search", { query: "  pi   coding agent " })), "tool");
  assert.equal(helpers.consumeEvent(progress, toolStart("bash", { command: "x".repeat(200) })), "tool");
  assert.equal(helpers.consumeEvent(progress, toolStart("ls", {})), "tool");
  assert.deepEqual(progress.toolCalls, ["web_search: pi coding agent", `bash: ${"x".repeat(97)}…`, "ls"]);
  helpers.consumeEvent(progress, textDelta("Looking at\nthe first"));
  helpers.consumeEvent(progress, textDelta(" source."));
  assert.equal(progress.lastText, "the first source.");
  assert.equal(helpers.consumeEvent(progress, "not json at all"), "text");
  assert.equal(progress.lastText, "not json at all");
  assert.equal(helpers.consumeEvent(progress, line({ type: "turn_end" })), undefined);
  assert.equal(helpers.consumeEvent(progress, finalMessage("## Answer\nYes.")), "final");
  assert.equal(progress.finalText, "## Answer\nYes.");
  assert.equal(helpers.consumeEvent(progress, ""), undefined);
  // A child's own delegate calls are counted while they run.
  helpers.consumeEvent(progress, toolStart("delegate", { task: "a" }));
  helpers.consumeEvent(progress, toolStart("delegate", { task: "b" }));
  assert.equal(progress.subagents, 2);
  helpers.consumeEvent(progress, line({ type: "tool_execution_end", toolCallId: "t", toolName: "delegate", result: {}, isError: false }));
  assert.equal(progress.subagents, 1);
  // The next message starts a fresh line instead of running on from "Yes."
  helpers.consumeEvent(progress, textDelta("Now the second"));
  assert.equal(progress.lastText, "Now the second");
});

test("delegate runs the child in the caller's cwd, feeds the task on stdin, streams progress and returns the final message", async () => {
  const cwd = project();
  const { tool, fake } = register(cwd);
  assert.match(tool.promptSnippet, /in the background.*without an agent, a generalist on your own model\. Members: research \(Multi-search web research that returns a cited brief\)/);
  assert.match(tool.promptGuidelines[1], /treat it as the answer/);
  assert.deepEqual(tool.parameters.required, ["task"]);
  assert.match(tool.parameters.properties.agent.description, /research.*omit for a generalist/);
  nextChild = fakeChild({
    stdout: toolStart("web_search", { query: "is it" }) + textDelta("Thinking") + finalMessage("Answer: yes.\nEvidence:\n- https://a.test\n"),
  });
  const updates = [];
  const result = await tool.execute("c1", { agent: "research", task: "Is it?" }, undefined, (u) => updates.push(u), fake.ctx(cwd));
  assert.match(result.content[0].text, /^Answer: yes\.\nEvidence:\n- https:\/\/a\.test\n\n\[delegate #1; 1 tool calls; session .*\/delegate\/research-\d+-[0-9a-f]{6}\.jsonl\.\]$/);
  assert.deepEqual(updates, [], "progress goes to the card only, not a second copy in the tool row");
  const spawn = spawns.at(-1);
  assert.equal(spawn.file, "pi");
  assert.equal(spawn.options.cwd, cwd);
  assert.deepEqual(spawn.args.slice(0, 3), ["--mode", "json", "-p"]);
  assert(spawn.args.includes("--no-extensions"));
  assert.equal(spawn.args.filter((arg) => arg === "-e").length, 1);
  assert.deepEqual(nextChild.stdin.chunks, ["Is it?"]);
  const counts = fake.events.filter((e) => e.name === "pif:subagents").map((e) => e.data.running);
  assert.deepEqual(counts, [1, 0]);
  assert.equal(fake.messages.length, 0, "a blocking run returns its report as the tool result, not a message");
});

test("the extension registers nothing when the project ships its own .pi/extensions/delegate.ts", () => {
  const cwd = project({}, ["delegate.ts"]);
  assert.equal(helpers.projectOverrides(cwd), true);
  assert.equal(register(cwd).tool, undefined);
  assert.equal(helpers.projectOverrides(project()), false);
});

test("delegate without an agent runs the generalist on the parent's model", async () => {
  const cwd = project();
  const { tool, fake } = register(cwd, { model: { provider: "openai-codex", id: "gpt-6.1-sol" }, thinking: "high" });
  nextChild = fakeChild({ stdout: finalMessage("Done.") });
  const result = await tool.execute("c1", { task: "Rename x to y in a.ts and run the tests." }, undefined, undefined, fake.ctx(cwd));
  assert.match(result.content[0].text, /^Done\.\n\n\[delegate #1; 0 tool calls; session .*\/delegate\/generalist-\d+-[0-9a-f]{6}\.jsonl\.\]$/);
  const args = spawns.at(-1).args;
  assert.deepEqual(args.slice(args.indexOf("--tools"), args.indexOf("--tools") + 6), [
    "--tools", "read,write,edit,bash,grep,find,ls,delegate", "--model", "openai-codex/gpt-6.1-sol", "--thinking", "high",
  ]);
  assert.equal(args.at(-1), helpers.GENERALIST_DIRECTIVE);
  assert.equal(spawns.at(-1).options.env.PIF_DELEGATE_DEPTH, "1");
});

test("delegation nests two tiers at most, and only for members that list Agent", () => {
  const generalist = helpers.generalistMember(undefined);
  // A tier-1 child delegates; its own children (tier 2) get no delegate tool.
  const tier1 = helpers.buildChildArgs(generalist, { cwd: project(), depth: 0 });
  assert.equal(tier1.nested, true);
  const tier2 = helpers.buildChildArgs(generalist, { cwd: project(), depth: 1 });
  assert.equal(tier2.nested, false);
  assert(!tier2.args.includes("-e"));
  assert.equal(tier2.args[tier2.args.indexOf("--tools") + 1], "read,write,edit,bash,grep,find,ls");
  assert.deepEqual(tier2.unmappedTools, [], "the cap drops Agent without reporting it");
  assert.deepEqual(tier2.env, { PIF_DELEGATE_DEPTH: "2" });
  // The depth defaults to the caller's own.
  process.env.PIF_DELEGATE_DEPTH = "1";
  try {
    assert.equal(helpers.buildChildArgs(generalist, { cwd: project() }).nested, false);
  } finally {
    delete process.env.PIF_DELEGATE_DEPTH;
  }
  // research does not list Agent, so it stays a leaf.
  const research = helpers.parseMember(RESEARCH, "/x/research.md");
  assert.equal(helpers.buildChildArgs(research, { cwd: project(), depth: 0 }).nested, false);
  // A web member with Agent in a repo that ships delegate.ts loads the repo copy once, with the loaders.
  const lead = helpers.parseMember(RESEARCH.replace("tools: WebSearch,", "tools: Agent, WebSearch,"), "/x/lead.md");
  const cwd = project({}, ["delegate.ts"]);
  const leadArgs = helpers.buildChildArgs(lead, { cwd, depth: 0 }).args;
  assert.deepEqual(leadArgs.filter((arg) => arg.endsWith("delegate.ts")), [join(cwd, ".pi", "extensions", "delegate.ts")]);
  assert.equal(leadArgs[leadArgs.indexOf("--tools") + 1], "delegate,web_search,web_fetch,read,grep,find");
  const worker = helpers.parseMember("---\nname: worker\ndescription: d\ntools: Read, Agent\n---\nWork.", "/x/worker.md");
  assert(helpers.buildChildArgs(worker, { cwd, depth: 0 }).args.includes(join(cwd, ".pi", "extensions", "delegate.ts")));
});

test("a tier-1 child gets a blocking delegate, and a tier-2 child gets none", () => {
  for (const [depth, expected] of [["1", "blocks"], ["2", undefined]]) {
    process.env.PIF_DELEGATE_DEPTH = depth;
    try {
      const { tool } = register(project());
      if (expected) assert.match(tool.promptGuidelines.join(" "), /blocks until the subagent finishes/);
      else assert.equal(tool, undefined);
    } finally {
      delete process.env.PIF_DELEGATE_DEPTH;
    }
  }
});

test("delegate reports a missing member, a failed child, partial output and a cancelled child", async () => {
  const cwd = project();
  const { tool, fake } = register(cwd);
  await assert.rejects(tool.execute("c1", { agent: "nobody", task: "t" }, undefined, undefined, fake.ctx(cwd)), /No subagent named "nobody"/);

  nextChild = fakeChild({ stderr: "boom", code: 2 });
  await assert.rejects(tool.execute("c2", { agent: "research", task: "t" }, undefined, undefined, fake.ctx(cwd)), /exited with code 2\.\n\nboom/);

  nextChild = fakeChild({ stdout: textDelta("partial"), code: 3 });
  const partial = await tool.execute("c3", { agent: "research", task: "t" }, undefined, undefined, fake.ctx(cwd));
  assert.match(partial.content[0].text, /^partial\n\n\[The subagent exited with code 3/);

  const controller = new AbortController();
  nextChild = fakeChild({ hang: true });
  const pending = tool.execute("c4", { agent: "research", task: "t" }, controller.signal, undefined, fake.ctx(cwd));
  setImmediate(() => controller.abort());
  await assert.rejects(pending, /research was cancelled\./);
  assert.equal(nextChild.killed, "SIGTERM");
});

test("in the interactive UI delegate returns at once and steers the report back when the child finishes", async () => {
  const cwd = project();
  const { tool, fake } = register(cwd);
  const ctx = fake.ctx(cwd, { hasUI: true });
  const child = fakeChild({ hang: true });
  nextChild = child;
  const result = await tool.execute("c1", { agent: "research", task: "Is it?" }, undefined, undefined, ctx);
  assert.match(result.content[0].text, /^Delegate #1 \(research\) started in the background\./);
  assert.equal(fake.messages.length, 0);
  const card = fake.widgets.get("delegate-1");
  assert(card, "a card is shown while the child runs");
  assert.match(card.render(80)[2], /^ ● Delegate #1 · research  Is it\?  \(0s\) \| Tools: 0$/);

  child.stdout.emit("data", toolStart("web_search", { query: "is it" }) + textDelta("Reading") + finalMessage("Yes."));
  child.emit("close", 0);
  await tick();
  assert.equal(fake.messages.length, 1);
  const { message, options } = fake.messages[0];
  assert.deepEqual(options, { deliverAs: "steer", triggerTurn: true });
  assert.equal(message.customType, "delegate");
  assert.match(message.content, /^Delegate #1 \(research\) finished after \d+s\.\n\nYes\.\n\n\[delegate #1; 1 tool calls; session .*\]$/);
  assert.equal(message.details.status, "done");
  assert.match(card.render(80)[2], /^ ✓ Delegate #1 · research/);
  assert.deepEqual(fake.events.filter((e) => e.name === "pif:subagents").map((e) => e.data.running), [1, 0]);

  // A report arriving as a message keeps the card; the user's next prompt clears it.
  fake.fire("input", { source: "extension" }, ctx);
  assert(fake.widgets.has("delegate-1"));
  fake.fire("input", { source: "interactive" }, ctx);
  assert(!fake.widgets.has("delegate-1"));
});

test("delegate_continue resumes the finished child's session and delegate_stop ends a running one without a message", async () => {
  const cwd = project();
  const { tool, tools, fake } = register(cwd);
  const ctx = fake.ctx(cwd, { hasUI: true });
  nextChild = fakeChild({ stdout: finalMessage("First.") });
  await tool.execute("c1", { task: "Do a." }, undefined, undefined, ctx);
  await tick();
  const firstSession = spawns.at(-1).args[spawns.at(-1).args.indexOf("--session") + 1];

  const child = fakeChild({ stdout: textDelta("half way"), hang: true });
  nextChild = child;
  await assert.rejects(tools.get("delegate_continue").execute("c2", { id: 9, task: "t" }, undefined, undefined, ctx), /No delegate #9/);
  const continued = await tools.get("delegate_continue").execute("c3", { id: 1, task: "Now b." }, undefined, undefined, ctx);
  assert.match(continued.content[0].text, /^Delegate #1 \(generalist\) started/);
  const args = spawns.at(-1).args;
  assert.equal(args[args.indexOf("--session") + 1], firstSession);
  assert.deepEqual(child.stdin.chunks, ["Now b."]);
  await assert.rejects(tools.get("delegate_continue").execute("c4", { id: 1, task: "t" }, undefined, undefined, ctx), /still running/);
  await tick();
  assert.match(fake.widgets.get("delegate-1").render(80)[2], /^ ● Delegate #1 · generalist · Turn 2  Now b\./);

  const stopped = await tools.get("delegate_stop").execute("c5", { id: 1 });
  assert.equal(child.killed, "SIGTERM");
  assert.match(stopped.content[0].text, /^generalist was stopped\.\n\nPartial output:\nhalf way$/);
  await tick();
  assert.equal(fake.messages.length, 1, "only the first run's report was delivered");
  assert.match((await tools.get("delegate_stop").execute("c6", { id: 1 })).content[0].text, /is not running; it was stopped/);
});

test("a new session stops running children and clears their cards", async () => {
  const cwd = project();
  const { tool, fake } = register(cwd);
  const ctx = fake.ctx(cwd, { hasUI: true });
  const child = fakeChild({ hang: true });
  nextChild = child;
  await tool.execute("c1", { task: "t" }, undefined, undefined, ctx);
  fake.fire("session_shutdown", { reason: "new" }, ctx);
  assert.equal(child.killed, "SIGTERM");
  assert(!fake.widgets.has("delegate-1"));
  await tick();
  assert.equal(fake.messages.length, 0);
});

test("cards and the report message fit the terminal width", () => {
  const card = {
    id: 12, name: "generalist", task: "Port the batch-6 driver ".repeat(10), turn: 1, status: "running", startedAt: 0,
    progress: { toolCalls: ["bash: " + "x".repeat(150)], lastText: "finished batch-6 data while polling. ".repeat(5) },
  };
  for (const width of [30, 80, 140]) {
    const lines = helpers.cardLines(card, width, plainTheme, 48_000);
    assert.equal(lines[0], "");
    assert.equal(lines[1], "─".repeat(width));
    assert.match(lines[2], /^ ● Delegate #12 · generalist/);
    for (const line of lines) assert(Array.from(line).length <= width, `${width}: ${line}`);
  }
  const wide = helpers.cardLines(card, 140, plainTheme, 48_000);
  assert.equal(wide[2], ` ● Delegate #12 · generalist  ${"Port the batch-6 driver Port the batch-…"}  (48s) | Tools: 1`);
  assert.equal(wide.length, 5, "blank, rule, header, one activity line, rule");
  // The activity line shows whichever came last: text, or the latest tool call.
  assert.match(wide[3], /^   finished batch-6 data/);
  const toolLast = { ...card, wait: true, turn: 2, progress: { ...card.progress, lastKind: "tool" } };
  const toolLines = helpers.cardLines(toolLast, 140, plainTheme, 48_000);
  assert.match(toolLines[2], /^ ● Delegate #12 · generalist · wait · Turn 2  /);
  const fanning = helpers.cardLines({ ...card, progress: { ...card.progress, subagents: 2 } }, 140, plainTheme, 48_000);
  assert.match(fanning[2], /^ ● Delegate #12 · generalist · 2 subagents  /);
  assert.match(toolLines[3], /^   bash: x+…$/);

  const started = helpers.resultRows({ content: [{ type: "text", text: "Delegate #4 started in the background." }], details: { id: 4, background: true } }, {}, plainTheme);
  assert.deepEqual(started.render(80), ["  ↳ Delegate #4 started"]);
  const failed = helpers.resultRows({ content: [{ type: "text", text: "generalist exited with code 1.\n\nEEXIST" }] }, {}, plainTheme, { isError: true });
  assert.deepEqual(failed.render(80), ["  generalist exited with code 1.", "  ", "  EEXIST"]);

  assert.deepEqual(helpers.wrap("one two three four", 9), ["one two", "three", "four"]);
  assert.deepEqual(helpers.wrap("abcdefghij\n\nx", 4), ["abcd", "efgh", "ij", "", "x"]);

  const { fake } = register(project());
  const render = fake.renderers.get("delegate");
  const report = Array.from({ length: 20 }, (_, i) => `line ${i}`).join("\n");
  const message = { content: `Delegate #3 (research) finished after 9s.\n\n${report}\n\n[delegate #3; 4 tool calls; session /s/r.jsonl.]`, details: { id: 3, name: "research", status: "done", seconds: 9, toolCalls: 4, turn: 1 } };
  const collapsed = render(message, { expanded: false, outputPad: 1 }, plainTheme).render(60);
  assert.equal(collapsed[0], " ✓ delegate #3 research  9s · 4 tools");
  assert.equal(collapsed[1], " line 0");
  assert.equal(collapsed.length, 1 + helpers.COLLAPSED_REPORT_LINES + 1);
  assert.match(collapsed.at(-1), /12 more lines/);
  assert(!collapsed.some((line) => line.includes("session")), "notes stay out of the collapsed view");
  const expanded = render(message, { expanded: true, outputPad: 1 }, plainTheme).render(60);
  assert.equal(expanded.length, 23);
  assert.equal(expanded.at(-1), " [delegate #3; 4 tool calls; session /s/r.jsonl.]");
});

test("every run stops at the one hour cap and says how to resume it", async () => {
  assert.equal(helpers.CHILD_TIMEOUT_MS, 60 * 60 * 1000);
  const cwd = project();
  const { tool, fake } = register(cwd);
  const ctx = fake.ctx(cwd, { hasUI: true });
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const child = fakeChild({ stdout: textDelta("still going"), hang: true });
    nextChild = child;
    await tool.execute("c1", { task: "Long job." }, undefined, undefined, ctx);
    await tick();
    mock.timers.tick(helpers.CHILD_TIMEOUT_MS - 1);
    assert.equal(child.killed, undefined, "nothing is stopped before the hour");
    mock.timers.tick(1);
    assert.equal(child.killed, "SIGTERM");
    await tick();
    await tick();
    assert.equal(fake.messages.length, 1, "a background run that hits the cap still reports");
    const { message } = fake.messages[0];
    assert.equal(message.details.status, "stopped");
    assert.match(message.content, /^Delegate #1 \(generalist\) was stopped after \d+s\.\n\ngeneralist reached the 60 minute cap and was stopped\. Its session is kept: delegate_continue with id 1 resumes it\.\n\nPartial output:\nstill going$/);

    const waited = fakeChild({ hang: true });
    nextChild = waited;
    const pending = tool.execute("c2", { task: "Long job.", wait: true }, undefined, undefined, ctx);
    await tick();
    mock.timers.tick(helpers.CHILD_TIMEOUT_MS);
    await assert.rejects(pending, /reached the 60 minute cap.*delegate_continue with id 2/s);
  } finally {
    mock.timers.reset();
  }
});
