// Run with: node --test pi/tests/agent-state.test.mjs
// Load the real TypeScript extension with Node's type stripping. The old
// @mariozechner import is type-only, so no Pi package or model is started.
import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { after, before, test } from "node:test";

const chainKey = Symbol.for("pif.agent-state.chain");
const marker = "Awaiting your input.";
const calls = [];
let inFlight = 0;
let maxInFlight = 0;
let extension;
const originalExecFile = childProcess.execFile;
const originalEnvironment = { TMUX: process.env.TMUX, TMUX_PANE: process.env.TMUX_PANE };

before(async () => {
  // Install the shim BEFORE importing the extension. No command ever reaches
  // the real child_process implementation, even when the caller is in tmux.
  delete process.env.TMUX;
  delete process.env.TMUX_PANE;
  childProcess.execFile = (file, args, options, callback) => {
    assert.equal(file, "tmux");
    assert.equal(options.timeout, 5000);
    calls.push([...args]);
    maxInFlight = Math.max(maxInFlight, ++inFlight);
    setImmediate(() => {
      inFlight--;
      callback(null, "", "");
    });
  };
  syncBuiltinESMExports();
  extension = (await import("../.config/pif/extensions/agent-state.ts")).default;
  process.env.TMUX = `/agent-state-test-only,${process.pid},0`;
  process.env.TMUX_PANE = "%agent-state-test-only";
});

after(async () => {
  await drain();
  childProcess.execFile = originalExecFile;
  syncBuiltinESMExports();
  for (const [key, value] of Object.entries(originalEnvironment)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  delete globalThis[chainKey];
});

async function drain() {
  await globalThis[chainKey];
}

function message(role, content) {
  return { type: "message", message: { role, content } };
}
const user = (text = "A sufficiently long user prompt") => message("user", text);
const assistant = (text) => message("assistant", [{ type: "text", text }]);
const toolCall = { type: "toolCall", id: "call-1", name: "bash", arguments: { command: marker } };
const toolResult = () => message("toolResult", [{ type: "text", text: marker }]);

function harness(initialBranch = [], { name = "Existing title", entries = initialBranch } = {}) {
  let branch = initialBranch;
  const handlers = new Map();
  const bus = new Map();
  const commands = new Map();
  const api = {
    on(event, handler) {
      const list = handlers.get(event) ?? [];
      list.push(handler);
      handlers.set(event, list);
    },
    events: { on: (event, handler) => bus.set(event, handler) },
    registerCommand: (name, command) => commands.set(name, command),
    getSessionName: () => name,
    setSessionName: () => assert.fail("State tests must not change the session title"),
    appendEntry: () => assert.fail("State tests must not append title entries"),
  };
  const ctx = {
    cwd: "/test/project",
    isIdle: () => true,
    sessionManager: {
      getBranch: () => branch,
      getEntries: () => entries,
      getSessionId: () => "test-session",
    },
    modelRegistry: {
      getAvailable: () => [],
      complete: () => assert.fail("Tests must never call a model"),
    },
  };
  extension(api);
  return {
    ctx,
    commands,
    branch: (value) => { branch = value; },
    async emit(type, event = {}) {
      for (const handler of handlers.get(type) ?? []) await handler({ type, ...event }, ctx);
    },
    subagents: (running) => bus.get("pif:subagents")({ running }),
  };
}

function tmuxCommands(args) {
  const result = [[]];
  for (const arg of args) {
    if (arg === ";") result.push([]);
    else result.at(-1).push(arg);
  }
  return result;
}

function optionValue(option, call = calls.at(-1)) {
  const command = tmuxCommands(call).find((command) => command[0] === "set" && command[4] === option);
  assert.ok(command, `Missing ${option}: ${JSON.stringify(call)}`);
  return command[1] === "-pu" ? undefined : command[5];
}

async function start(h, reason = "startup") {
  await h.emit("session_start", { reason });
  await drain();
}

function assertState(state) {
  assert.equal(optionValue("@agent_state"), state);
  assert.match(optionValue("@agent_state_at"), new RegExp(`@agent_state},${state}`));
  assert.match(optionValue("@agent_at"), /^\d+$/);
}

test("reopened marker restores awaiting for all session_start reasons", async (t) => {
  // CLI --continue/--session, CLI picker, and resurrected processes all reach
  // startup with the loaded branch. /resume uses resume on its new runtime.
  for (const reason of ["startup", "resume", "reload", "fork"]) {
    await t.test(reason, async () => {
      const h = harness([user(), assistant(`Which choice?\n${marker}`)]);
      const before = calls.length;
      await start(h, reason);
      assert.equal(calls.length, before + 1, "one serial tmux invocation per start");
      assertState("awaiting");
      assert.equal(optionValue("@agent_kind"), "pi");
      assert.equal(optionValue("@agent_pid"), String(process.pid));
      assert.equal(optionValue("@agent_subs"), "0");
      assert.equal(optionValue("@agent_name"), "Existing title");
      assert.equal(optionValue("@agent_cwd"), "/test/project");
      assert.equal(optionValue("@agent_empty"), undefined);
      assert.ok(h.commands.has("retitle"));
    });
  }
});

test("fresh, clear, plain and interrupted newer turns restore idle", async (t) => {
  const cases = [
    ["empty", [], "1"],
    ["metadata only", [{ type: "session_info", name: marker }], "1"],
    ["plain response", [user(), assistant("Done.")]],
    ["newer plain response", [user(), assistant(marker), assistant("Done.")]],
    ["newer empty assistant", [user(), assistant(marker), assistant("")]],
    ["newer user", [user(), assistant(marker), user("Continue")]],
    ["newer tool result", [user(), assistant(marker), toolResult()]],
    ["newer tool call", [user(), assistant(marker), message("assistant", [toolCall])]],
    ["marker text while calling a tool", [user(), message("assistant", [{ type: "text", text: marker }, toolCall])]],
    ["newer shell command", [user(), assistant(marker), { type: "message", message: { role: "bashExecution", output: marker } }]],
  ];
  for (const [label, branch, empty] of cases) {
    await t.test(label, async () => {
      await start(harness(branch), label === "empty" ? "new" : "startup");
      assertState("idle");
      assert.equal(optionValue("@agent_empty"), empty);
    });
  }
});

test("marker matches only the exact last nonempty trimmed assistant text line", async (t) => {
  const cases = [
    ["exact", [{ type: "text", text: marker }], true],
    // Current Pi uses assistant content arrays. Preserve the string shape
    // accepted by the previous lastAssistantText/textOf implementation too.
    ["legacy-compatible string marker", `Question?\n ${marker} \n\n`, true],
    ["legacy-compatible plain string", "Done.", false],
    ["trimmed CRLF and blank lines", [{ type: "text", text: `Question?\r\n \t${marker} \t\r\n \r\n\t` }], true],
    ["several text blocks", [{ type: "text", text: "Question?\n" }, { type: "text", text: marker }], true],
    ["trailing thinking ignored", [{ type: "text", text: marker }, { type: "thinking", thinking: "Still thinking" }], true],
    ["extra final line", [{ type: "text", text: `${marker}\nDone.` }], false],
    ["missing punctuation", [{ type: "text", text: "Awaiting your input" }], false],
    ["wrong case", [{ type: "text", text: "awaiting your input." }], false],
    ["inline suffix", [{ type: "text", text: `Please reply. ${marker}` }], false],
    ["quoted", [{ type: "text", text: `"${marker}"` }], false],
    ["markdown", [{ type: "text", text: `**${marker}**` }], false],
    ["thinking only", [{ type: "thinking", thinking: marker, text: marker }], false],
    ["tool arguments only", [toolCall], false],
  ];
  for (const [label, content, awaiting] of cases) {
    await t.test(label, async () => {
      await start(harness([user(), message("assistant", content)]));
      assertState(awaiting ? "awaiting" : "idle");
    });
  }
});

test("only completed responses can await, at restore and settle", async (t) => {
  for (const stopReason of [undefined, "stop", "aborted", "error", "toolUse", "length", "pending", "deferred"]) {
    await t.test(String(stopReason), async () => {
      const current = assistant(marker);
      if (stopReason !== undefined) current.message.stopReason = stopReason;
      // An older valid marker must not override a newer nonfinal response.
      const h = harness([user(), assistant(marker), user("Continue"), current]);
      const completed = stopReason === undefined || stopReason === "stop";
      await start(h);
      assertState(completed ? "awaiting" : "idle");
      await h.emit("agent_settled");
      await drain();
      if (completed) {
        assertState("awaiting");
      } else {
        const [command] = tmuxCommands(calls.at(-1));
        assert.equal(command[0], "if");
        assert.match(command[5], /@agent_state idle/);
        assert.match(command[6], /@agent_state finished/);
      }
    });
  }
});

test("metadata and extension notices do not hide the current response", async () => {
  await start(harness([
    user(), assistant(marker),
    { type: "custom", customType: "agent-state-title", data: { name: "Topic" } },
    { type: "session_info", name: "Topic" },
    { type: "label", label: "Bookmark" },
    { type: "compaction", summary: "Summary" },
    { type: "branch_summary", summary: "Other branch" },
    { type: "custom_message", content: "Notice" },
    message("custom", "Notice"),
  ]));
  assertState("awaiting");
});

test("active branch wins over other entries and /tree updates in both directions", async () => {
  const waiting = [user(), assistant(marker)];
  const plain = [user(), assistant("Done.")];
  const h = harness(plain, { entries: [...waiting, ...plain, assistant(marker)] });
  await start(h);
  assertState("idle");
  h.branch(waiting);
  await h.emit("session_tree", { newLeafId: "waiting", oldLeafId: "plain" });
  await drain();
  assertState("awaiting");
  assert.equal(optionValue("@agent_empty"), undefined);
  h.branch(plain);
  await h.emit("session_tree", { newLeafId: "plain", oldLeafId: "waiting" });
  await drain();
  assertState("idle");
  h.branch([]);
  await h.emit("session_tree", { newLeafId: null, oldLeafId: "plain" });
  await drain();
  assertState("idle");
  assert.equal(optionValue("@agent_empty"), "1");
});

test("same-process /resume shutdown cannot overtake replacement start", async () => {
  const first = harness([user(), assistant(marker)]);
  await start(first);
  const before = calls.length;
  const shutdown = first.emit("session_shutdown", { reason: "resume" });
  const second = harness([user(), assistant("Done.")]);
  await second.emit("session_start", { reason: "resume", previousSessionFile: "/first.jsonl" });
  await shutdown;
  await drain();
  assert.equal(calls.length, before + 2);
  assert.ok(tmuxCommands(calls[before]).every((command) => command[1] === "-pu"));
  assertState("idle");
  const shutdownAgain = second.emit("session_shutdown", { reason: "resume" });
  await first.emit("session_start", { reason: "resume" });
  await shutdownAgain;
  await drain();
  assertState("awaiting");
  assert.equal(maxInFlight, 1, "tmux writes remain serialized across runtimes");
});

test("the next turn works, then settles using only its current response", async () => {
  const h = harness([user(), assistant(marker)]);
  await start(h);
  await h.emit("agent_start");
  await drain();
  assertState("working");
  assert.equal(optionValue("@agent_empty"), undefined);
  h.branch([user(), assistant(marker), user("Continue"), assistant(`Choose again?\n${marker}`)]);
  await h.emit("agent_settled");
  await drain();
  assertState("awaiting");
  h.branch([user(), assistant(marker), user("Continue"), toolResult()]);
  await h.emit("agent_settled");
  await drain();
  const [command] = tmuxCommands(calls.at(-1));
  assert.equal(command[0], "if");
  assert.match(command[5], /@agent_state idle/);
  assert.match(command[6], /@agent_state finished/);
});

test("subagents still hold working at settle and survive branch navigation", async () => {
  const h = harness([user(), assistant("Done.")]);
  await start(h);
  h.subagents(2);
  await h.emit("agent_settled");
  await drain();
  assertState("working");
  await h.emit("session_tree");
  await drain();
  assertState("working");
  assert.ok(!calls.at(-1).includes("@agent_subs"), "tree must not reset subagent count");
  h.branch([user(), assistant(marker)]);
  await h.emit("agent_settled");
  await drain();
  assertState("awaiting");
});

test("branch read errors fall back to nonempty idle without breaking startup", async () => {
  const h = harness();
  h.ctx.sessionManager.getBranch = () => { throw new Error("unavailable"); };
  await start(h);
  assertState("idle");
  assert.equal(optionValue("@agent_empty"), undefined);
});

test("the extension does not invoke tmux outside a tmux environment", async () => {
  const tmux = process.env.TMUX;
  delete process.env.TMUX;
  try {
    const before = calls.length;
    await start(harness([user(), assistant(marker)]));
    assert.equal(calls.length, before);
  } finally {
    process.env.TMUX = tmux;
  }
});
