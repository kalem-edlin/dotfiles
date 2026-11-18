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
import { after, before, test } from "node:test";

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
  return {
    api: {
      registerTool: (tool) => tools.set(tool.name, tool),
      on: (name, handler) => events.push({ name, handler }),
      events: { emit: (name, data) => events.push({ name, data }) },
      getThinkingLevel: () => thinking,
    },
    events,
    ctx: (cwd) => ({ cwd, hasUI: false, model, ui: { setWidget() {} } }),
  };
}

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
  return { tool: tools.get("delegate"), fake };
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
  assert.match(defaultSession, new RegExp(`^${sessions.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/delegate/research-\\d+\\.jsonl$`));

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
  const plan = helpers.buildChildArgs(member, { cwd: project({}, ["search.ts"]), thinking: "high" });
  assert(!plan.args.includes("-e"));
  assert.deepEqual(plan.args.slice(7, 13), ["--tools", "read,write,edit,bash,grep,find,ls", "--model", "openai-codex/gpt-6.1-sol", "--thinking", "high"]);
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
  assert.match(helpers.progressText("research", progress, 84_000), /^research running for 84s, 3 tool calls\n  web_search: pi coding agent\n/);
});

test("delegate runs the child in the caller's cwd, feeds the task on stdin, streams progress and returns the final message", async () => {
  const cwd = project();
  const { tool, fake } = register(cwd);
  assert.match(tool.promptSnippet, /without an agent, a generalist on your own model\. Members: research \(Multi-search web research that returns a cited brief\)/);
  assert.match(tool.promptGuidelines[1], /treat it as the answer/);
  assert.deepEqual(tool.parameters.required, ["task"]);
  assert.match(tool.parameters.properties.agent.description, /research.*omit for a generalist/);
  nextChild = fakeChild({
    stdout: toolStart("web_search", { query: "is it" }) + textDelta("Thinking") + finalMessage("Answer: yes.\nEvidence:\n- https://a.test\n"),
  });
  const updates = [];
  const result = await tool.execute("c1", { agent: "research", task: "Is it?" }, undefined, (u) => updates.push(u.content[0].text), fake.ctx(cwd));
  assert.match(result.content[0].text, /^Answer: yes\.\nEvidence:\n- https:\/\/a\.test\n\n\[1 tool calls; session .*\/delegate\/research-\d+\.jsonl\.\]$/);
  assert.match(updates[0], /^research running for \d+s, 1 tool calls\n  web_search: is it$/);
  const spawn = spawns.at(-1);
  assert.equal(spawn.file, "pi");
  assert.equal(spawn.options.cwd, cwd);
  assert.deepEqual(spawn.args.slice(0, 3), ["--mode", "json", "-p"]);
  assert(spawn.args.includes("--no-extensions"));
  assert.equal(spawn.args.filter((arg) => arg === "-e").length, 1);
  assert.deepEqual(nextChild.stdin.chunks, ["Is it?"]);
  const counts = fake.events.filter((e) => e.name === "pif:subagents").map((e) => e.data.running);
  assert.deepEqual(counts, [1, 0]);
  assert.equal(fake.events.find((e) => e.name === "agent_end")?.name, "agent_end", "cards clear when the parent's turn ends");
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
  assert.match(result.content[0].text, /^Done\.\n\n\[0 tool calls; session .*\/delegate\/generalist-\d+\.jsonl\.\]$/);
  const args = spawns.at(-1).args;
  assert.deepEqual(args.slice(args.indexOf("--tools"), args.indexOf("--tools") + 6), [
    "--tools", "read,write,edit,bash,grep,find,ls", "--model", "openai-codex/gpt-6.1-sol", "--thinking", "high",
  ]);
  assert.equal(args.at(-1), helpers.GENERALIST_DIRECTIVE);
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
