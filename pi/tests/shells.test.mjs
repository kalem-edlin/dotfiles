// Run with: node --test pi/tests/shells.test.mjs
// Loads the real TypeScript extension with Node's type stripping. The two pi
// packages it imports are stubbed through module hooks; background shells
// run real `bash -c` children in a temporary log root.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { after, before, test } from "node:test";

const root = mkdtempSync(join(tmpdir(), "shells-test-"));
const stubs = join(root, "stubs");
mkdirSync(stubs);
writeFileSync(join(stubs, "agent.mjs"), `
export function createBashToolDefinition(cwd) {
  return {
    name: "bash", label: "bash", description: "Execute a bash command.",
    promptSnippet: "Execute bash commands",
    parameters: { type: "object", properties: { command: { type: "string" }, timeout: { type: "number" } }, required: ["command"] },
    async execute(...args) { globalThis.__bashCalls.push({ cwd, args }); return { content: [{ type: "text", text: "foreground" }] }; },
  };
}
`);
// Keys arrive as their names ("down", "ctrl+n"); "release:<key>" is a key
// release. Widths count code points with escapes removed.
writeFileSync(join(stubs, "tui.mjs"), `
export const Key = { escape: "escape", left: "left", right: "right", up: "up", down: "down", enter: "enter", backspace: "bs" };
export const matchesKey = (data, key) => data === key;
export const isKeyRelease = (data) => data.startsWith("release:");
const strip = (text) => text.replace(/\\x1b\\[[0-9;?]*[ -\\/]*[@-~]/g, "");
export const visibleWidth = (text) => Array.from(strip(text)).length;
export const truncateToWidth = (text, width) => Array.from(strip(text)).slice(0, width).join("");
`);
const stubUrls = {
  "@earendil-works/pi-coding-agent": pathToFileURL(join(stubs, "agent.mjs")).href,
  "@earendil-works/pi-tui": pathToFileURL(join(stubs, "tui.mjs")).href,
  "@mariozechner/pi-tui": pathToFileURL(join(stubs, "tui.mjs")).href,
};
registerHooks({
  resolve(specifier, context, next) {
    if (stubUrls[specifier]) return { url: stubUrls[specifier], shortCircuit: true };
    return next(specifier, context);
  },
});

let mod;
const originalDir = process.env.PIF_SHELLS_DIR;
const logs = join(root, "logs");

before(async () => {
  process.env.PIF_SHELLS_DIR = logs;
  globalThis.__bashCalls = [];
  mod = await import("../.config/pif/extensions/shells.ts");
});

after(() => {
  if (originalDir === undefined) delete process.env.PIF_SHELLS_DIR;
  else process.env.PIF_SHELLS_DIR = originalDir;
});

function harness() {
  const handlers = new Map();
  const tools = new Map();
  const commands = new Map();
  const shortcuts = new Map();
  const renderers = new Map();
  const messages = [];
  const events = [];
  let wake;
  const api = {
    on: (event, handler) => handlers.set(event, handler),
    registerTool: (tool) => tools.set(tool.name, tool),
    registerCommand: (name, command) => commands.set(name, command),
    registerShortcut: (key, shortcut) => shortcuts.set(key, shortcut),
    registerMessageRenderer: (type, renderer) => renderers.set(type, renderer),
    sendMessage: (message, options) => {
      messages.push({ message, options });
      wake?.();
    },
    events: { emit: (name, data) => events.push({ name, ...data }) },
  };
  mod.default(api);
  const ui = { hasUI: true, cwd: process.cwd(), ui: { notify() {} } };
  return {
    tools, commands, shortcuts, renderers, messages, events, handlers,
    bash: (params, ctx = ui) => tools.get("bash").execute("call", params, undefined, undefined, ctx),
    // Resolves once n shell messages have arrived.
    async messagesAt(n, ms = 10_000) {
      const deadline = Date.now() + ms;
      while (messages.length < n) {
        if (Date.now() > deadline) assert.fail(`Timed out waiting for ${n} shell messages`);
        await new Promise((resolve) => { wake = resolve; setTimeout(resolve, 50); });
      }
      return messages[n - 1];
    },
  };
}

const startPgid = (text) => Number(text.match(/pgid (\d+)/)[1]);

test("a call without background runs pi's bash tool unchanged", async () => {
  const h = harness();
  globalThis.__bashCalls = [];
  const result = await h.bash({ command: "echo hi", timeout: 5 });
  assert.equal(result.content[0].text, "foreground");
  assert.deepEqual(globalThis.__bashCalls[0].args[1], { command: "echo hi", timeout: 5 });
  const schema = h.tools.get("bash").parameters;
  assert.deepEqual(Object.keys(schema.properties), ["command", "timeout", "background", "service"]);
  assert.equal(h.tools.get("bash").promptSnippet, "Execute bash commands");
});

test("a background shell returns at once, then reports its exit with steer delivery", async () => {
  const h = harness();
  const result = await h.bash({ command: "echo one; echo two; exit 3", background: true });
  const text = result.content[0].text;
  assert.match(text, /^Shell #1 started in the background \(pgid \d+, log .*1\.log\)\. It stops after 1h 0m\./);
  assert.match(text, /kill -- -\d+/);
  assert.deepEqual(h.events[0], { name: "pif:shells", running: 1, active: 1 });
  const { message, options } = await h.messagesAt(1);
  assert.deepEqual(options, { deliverAs: "steer", triggerTurn: true });
  assert.equal(message.customType, "shell");
  assert.equal(message.details.status, "failed");
  assert.match(message.content, /^Shell #1 \(shell: echo one; echo two; exit 3\) exited with code 3 after 0s\./);
  assert.match(message.content, /one\ntwo/);
  assert.match(message.content, /\[log: .*1\.log\]$/);
  assert.deepEqual(h.events.at(-1), { name: "pif:shells", running: 0, active: 0 });
  await h.handlers.get("session_shutdown")();
});

test("a service has no default timeout and does not count as running", async () => {
  const h = harness();
  const result = await h.bash({ command: "sleep 30", service: true });
  assert.doesNotMatch(result.content[0].text, /It stops after/);
  assert.deepEqual(h.events.at(-1), { name: "pif:shells", running: 0, active: 1 });
  await h.handlers.get("session_shutdown")();
  assert.equal(h.messages.length, 0, "a shell stopped by the session ending sends no report");
});

test("a timeout stops the whole process group and says so", async () => {
  const h = harness();
  await h.bash({ command: "sleep 30 & sleep 30; wait", background: true, timeout: 1 });
  const { message } = await h.messagesAt(1);
  assert.equal(message.details.status, "timed out");
  assert.match(message.content, /reached its 1s timeout and was stopped/);
  await h.handlers.get("session_shutdown")();
});

test("the agent's kill of the process group is reported as a signal", async () => {
  const h = harness();
  const result = await h.bash({ command: "echo ready; sleep 30", background: true });
  await new Promise((resolve) => setTimeout(resolve, 200));
  process.kill(-startPgid(result.content[0].text), "SIGTERM");
  const { message } = await h.messagesAt(1);
  assert.equal(message.details.status, "killed");
  assert.match(message.content, /was killed by SIGTERM/);
  assert.match(message.content, /ready/);
  await h.handlers.get("session_shutdown")();
});

test("without a UI a non-service call blocks through pi's bash with the one hour default", async () => {
  const h = harness();
  globalThis.__bashCalls = [];
  const result = await h.bash({ command: "echo hi", background: true }, { hasUI: false, cwd: process.cwd() });
  assert.equal(result.content[0].text, "foreground");
  assert.deepEqual(globalThis.__bashCalls[0].args[1], { command: "echo hi", timeout: 3600 });
});

test("session end stops running shells and deletes this session's log directory", async () => {
  const h = harness();
  const result = await h.bash({ command: "sleep 30", background: true });
  const pgid = startPgid(result.content[0].text);
  const dir = join(logs, "pif-shells", String(process.pid));
  assert.ok(existsSync(dir));
  await h.handlers.get("session_shutdown")();
  assert.ok(!existsSync(dir));
  assert.throws(() => process.kill(-pgid, 0));
  assert.deepEqual(h.events.at(-1), { name: "pif:shells", running: 0, active: 0 });
});

const plainTheme = { fg: (_c, text) => text, bold: (text) => text, bg: (_c, text) => text };
const strip = (text) => text.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "");
const width = (line) => Array.from(strip(line)).length;
function assertRows(lines, w, label) {
  for (const line of lines) {
    assert.ok(!line.includes("\n") && !line.includes("\r"), `${label}: a line holds a line break: ${JSON.stringify(line)}`);
    assert.ok(width(line) <= w, `${label}: a line is ${width(line)} wide at width ${w}: ${JSON.stringify(line)}`);
  }
}

const HEREDOC = "python3 -u - <<'PY'\nimport time\n\nfor i in range(3):\n\tprint(i)\nPY";

test("the exit card renders a heredoc command as one-row lines at every width", async () => {
  const h = harness();
  await h.bash({ command: "cat <<'EOF'\nfirst\tline\n\nsecond line\x1b[31m red\x1b[0m\rover\nEOF\nexit 2", background: true });
  const { message } = await h.messagesAt(1);
  assert.equal(message.details.command, "cat <<'EOF'\nfirst\tline\n\nsecond line\x1b[31m red\x1b[0m\rover\nEOF\nexit 2");
  const renderer = h.renderers.get("shell");
  const legacy = { customType: "shell", content: `Shell #3 (shell: ${HEREDOC}) exited with code 0 after 4s.\n\nLast 20 lines of output:\n0\n1\n2\n\n[log: /tmp/x/3.log]`, details: { id: 3, status: "exited", service: false, seconds: 4, code: 0 } };
  for (const msg of [message, legacy]) {
    for (const expanded of [false, true]) {
      for (const w of [1, 8, 20, 40, 80, 160]) {
        const lines = renderer(msg, { expanded }, plainTheme).render(w);
        assertRows(lines, w, `width ${w}${expanded ? " expanded" : ""}`);
        if (w >= 8) for (const line of lines) assert.equal(width(line), w, "every card row fills the width");
      }
    }
  }
  const collapsed = renderer(legacy, { expanded: false }, plainTheme).render(80).map(strip);
  assert.match(collapsed[1], /^ ✓ shell #3 {2}python3 -u - <<'PY' … {2}exit 0 · 4s/);
  assert.ok(!collapsed.join("|").includes("import time"), "collapsed shows the first command line only");
  assert.deepEqual(collapsed.slice(2, 5).map((line) => line.trim()), ["0", "1", "2"]);
  const expanded = renderer(legacy, { expanded: true }, plainTheme).render(80).map((line) => strip(line).trimEnd());
  assert.ok(expanded.includes(" $ python3 -u - <<'PY'") && expanded.includes("     print(i)"));
  assert.ok(expanded.includes(" log: /tmp/x/3.log"));
  const real = renderer(message, { expanded: false }, plainTheme).render(80).map((line) => strip(line).trimEnd());
  assert.match(real[1], /^ ✗ shell #1 {2}cat <<'EOF' … {2}exit 2 · \ds$/);
  assert.ok(real.includes(" first  line") && real.includes(" over"), "tabs become spaces and a carriage return shows what is left");
  await h.handlers.get("session_shutdown")();
});

test("the exit card's background follows the outcome", () => {
  const bgFor = (status) => {
    const used = new Set();
    const theme = { ...plainTheme, bg: (color, text) => (used.add(color), text) };
    mod.cardLines({ id: 1, status, service: false, seconds: 1, code: status === "failed" ? 1 : 0, signal: "SIGTERM", command: "x", output: "", log: "" }, false, theme, 40);
    return [...used];
  };
  assert.deepEqual(bgFor("exited"), ["toolSuccessBg"]);
  assert.deepEqual(bgFor("failed"), ["toolErrorBg"]);
  assert.deepEqual(bgFor("killed"), ["toolErrorBg"]);
  assert.deepEqual(bgFor("timed out"), ["toolErrorBg"]);
  assert.deepEqual(bgFor("stopped"), ["toolPendingBg"]);
  assert.deepEqual(bgFor("running"), ["toolPendingBg"]);
});

test("Down or ctrl+n with the cursor on the last line focuses the shells tag; enter opens, up, ctrl+p and esc return", () => {
  const env = { active: 1, cursorOnLastLine: true, editorFocused: true };
  const changes = [];
  let opened = 0;
  const focus = new mod.ShellFocus(() => env, () => opened++, (focused) => changes.push(focused));
  const consumed = { consume: true };
  // Cursor above the last line, unfocused editor or no running shell: Down is the editor's.
  for (const [key, value] of [["cursorOnLastLine", false], ["editorFocused", false], ["active", 0]]) {
    const saved = env[key];
    env[key] = value;
    assert.equal(focus.handle("down"), undefined);
    assert.equal(focus.handle("ctrl+n"), undefined);
    env[key] = saved;
  }
  assert.equal(focus.handle("up"), undefined, "up passes through while unfocused");
  assert.equal(focus.handle("ctrl+p"), undefined);
  assert.equal(focus.handle("a"), undefined);
  assert.deepEqual(changes, []);
  for (const [focusKey, leaveKey] of [["down", "up"], ["ctrl+n", "ctrl+p"], ["down", "escape"], ["ctrl+n", "up"]]) {
    assert.deepEqual(focus.handle(focusKey), consumed);
    assert.equal(focus.focused, true);
    assert.equal(focus.handle(`release:${focusKey}`), undefined, "a key release changes nothing");
    assert.equal(focus.focused, true);
    assert.deepEqual(focus.handle("down"), consumed, "down again stays on the tag");
    assert.deepEqual(focus.handle("ctrl+n"), consumed);
    assert.deepEqual(focus.handle(leaveKey), consumed);
    assert.equal(focus.focused, false);
  }
  assert.deepEqual(focus.handle("down"), consumed);
  assert.deepEqual(focus.handle("enter"), consumed);
  assert.equal(opened, 1);
  assert.equal(focus.focused, false);
  assert.deepEqual(focus.handle("ctrl+n"), consumed);
  assert.equal(focus.handle("h"), undefined, "any other key returns to the editor and goes through");
  assert.equal(focus.focused, false);
  assert.deepEqual(focus.handle("down"), consumed);
  env.active = 0;
  assert.equal(focus.handle("enter"), undefined, "with no shell left the tag is gone and enter goes to the editor");
  assert.equal(focus.focused, false);
  assert.equal(opened, 1);
  assert.deepEqual(changes, [true, false, true, false, true, false, true, false, true, false, true, false, true, false]);
});

test("the focus is dropped and announced when the last shell ends", async () => {
  const h = harness();
  let listener;
  const ctx = { hasUI: true, cwd: process.cwd(), ui: { notify() {}, getEditorText: () => "", onTerminalInput: (fn) => ((listener = fn), () => {}) } };
  h.handlers.get("session_start")({}, ctx);
  await h.bash({ command: "sleep 0.3", background: true });
  assert.deepEqual(listener("down"), { consume: true });
  assert.deepEqual(h.events.at(-1), { name: "pif:shells-focus", focused: true });
  await h.messagesAt(1);
  assert.deepEqual(h.events.filter((e) => e.name === "pif:shells-focus").at(-1), { name: "pif:shells-focus", focused: false });
  assert.equal(listener("down"), undefined);
  await h.handlers.get("session_shutdown")();
});

test("the status line tag reads N shells and asks for enter when focused", async () => {
  const status = await import("../.config/pif/extensions/statusline.ts");
  assert.equal(strip(status.shellsTag(1)), "1 shell");
  assert.equal(strip(status.shellsTag(3)), "3 shells");
  assert.ok(!status.shellsTag(3).includes("ctrl+shift+s"));
  const focused = status.shellsTag(2, true);
  assert.ok(focused.startsWith("\x1b[7m"), "the focused tag is inverted");
  assert.equal(strip(focused), " 2 shells ");
});

// Lives here because this file already stubs the pi packages statusline.ts
// imports. The body mirrors a live wham/usage response (2026-11-18).
test("the status line reads codex 5-hour and weekly windows from the usage endpoint", async () => {
  const status = await import("../.config/pif/extensions/statusline.ts");
  const weekOnly = {
    plan_type: "pro",
    rate_limit: {
      primary_window: { used_percent: 3, limit_window_seconds: 604800, reset_at: 1795539718 },
      secondary_window: null,
    },
    additional_rate_limits: null,
  };
  const usage = status.codexUsageFrom(weekOnly, "gpt-5.5");
  assert.equal(usage.short, undefined);
  assert.deepEqual(usage.weekly, { usedPct: 3, durationMins: 10080, resetsAt: 1795539718 });
  const both = status.codexUsageFrom({
    rate_limit: {
      primary_window: { used_percent: 40, limit_window_seconds: 18000, reset_at: 1 },
      secondary_window: { used_percent: 12, limit_window_seconds: 604800, reset_at: 2 },
    },
    additional_rate_limits: [{
      limit_name: "GPT-6 Astra",
      rate_limit: { primary_window: { used_percent: 70, limit_window_seconds: 18000, reset_at: 3 } },
    }],
  }, "gpt-6-astra");
  assert.equal(both.short.usedPct, 70, "a per-model limit wins");
  assert.equal(status.codexUsageFrom({ rate_limit: { primary_window: null } }), undefined);
});

test("the list is a bordered, filled box of full-width rows; ctrl+n and ctrl+p move like down and up", () => {
  const stopped = [];
  const closed = [];
  const now = Date.now();
  const shells = [
    { id: 1, command: HEREDOC, service: false, status: "exited", startedAt: now - 5000, endedAt: now, logPath: "/x/1.log", tail: "" },
    { id: 2, command: "npm run dev", service: true, status: "running", startedAt: now, logPath: "/x/2.log", tail: "" },
  ];
  const fills = new Set();
  const theme = { ...plainTheme, bg: (color, text) => (fills.add(color), text) };
  const panel = new mod.ShellsPanel(() => shells, theme, (shell) => stopped.push(shell.id), (id) => closed.push(id));
  assert.equal(panel.selected, 1, "the first running shell is selected");
  for (const w of [10, 40, 90]) {
    const lines = panel.render(w);
    assertRows(lines, w, `list at ${w}`);
    for (const line of lines) assert.equal(width(line), w, "every list row fills the box");
  }
  const lines = panel.render(70).map(strip);
  assert.match(lines[0], /^╭─ Background shells ─+╮$/);
  assert.match(lines.at(-1), /^╰─+╯$/);
  assert.match(lines[2], /^│ {3}✓ #1 {2}python3 -u - <<'PY' … +5s │$/);
  assert.match(lines[3], /^│ › ● #2 {2}npm run dev +0s · service │$/);
  assert.ok(fills.has("toolPendingBg") && fills.has("selectedBg"));
  panel.handleInput("ctrl+p");
  assert.equal(panel.selected, 0);
  panel.handleInput("release:ctrl+n");
  assert.equal(panel.selected, 0);
  panel.handleInput("ctrl+n");
  assert.equal(panel.selected, 1);
  panel.handleInput("up");
  panel.handleInput("down");
  panel.handleInput("x");
  assert.deepEqual(stopped, [2]);
  panel.handleInput("up");
  panel.handleInput("x");
  assert.deepEqual(stopped, [2, 1], "x removes a finished shell too");
  panel.handleInput("down");
  panel.handleInput("enter");
  panel.handleInput("escape");
  assert.deepEqual(closed, [2, undefined]);
});

test("the full-screen view stops pi's TUI, prints the whole log, follows it and restores pi", async () => {
  const calls = [];
  const out = [];
  const listeners = new Set();
  const stdin = {
    isRaw: false,
    on: (_event, fn) => listeners.add(fn),
    off: (_event, fn) => listeners.delete(fn),
    setRawMode: (raw) => calls.push(`raw ${raw}`),
    setEncoding: () => {},
    resume: () => calls.push("resume"),
    pause: () => calls.push("pause"),
  };
  const stdout = { write: (text) => out.push(text) };
  const tui = { stop: () => calls.push("tui stop"), start: () => calls.push("tui start"), requestRender: (force) => calls.push(`render ${force}`) };
  let finish;
  const shell = {
    id: 4, command: HEREDOC, service: false, status: "running", code: null, signal: null, timeoutS: 3600,
    startedAt: Date.now(), logPath: "/x/4.log", tail: "", pid: 4242, done: new Promise((resolve) => (finish = resolve)),
  };
  const stops = [];
  let closed = 0;
  const view = new mod.ShellView(shell, tui, plainTheme, (s) => stops.push(s.id), { stdin, stdout }, () => closed++);
  view.open(() => Buffer.from("line 1\nline 2\n\x1b[31mred\x1b[0m\x1b[2Kgone\n\x1b]0;title\x07after\n"));
  assert.deepEqual(calls.slice(0, 2), ["tui stop", "raw true"], "pi's TUI stops before anything is written");
  assert.equal(out[0], mod.CLEAR_ALL);
  const shown = out.join("");
  for (const piece of ["Shell #4", "Status:   is running", "Timeout:  1h 0m", "Pgid:     4242", "Log:      /x/4.log", "Command:  python3 -u - <<'PY'\r\n          import time", "x stop · q, esc or ← back to pi"]) {
    assert.ok(shown.includes(piece), `the header shows ${JSON.stringify(piece)}`);
  }
  assert.ok(shown.includes("line 1\r\nline 2\r\n\x1b[31mred\x1b[0mgone\r\nafter\r\n"), "the log is printed with CRLF, colours kept and other escapes dropped");
  // Live output, with an escape split across chunks.
  for (const watcher of shell.watchers) watcher(Buffer.from("more\n\x1b[3"));
  for (const watcher of shell.watchers) watcher(Buffer.from("2mgreen\n"));
  assert.ok(out.join("").endsWith("more\r\n\x1b[32mgreen\r\n"));
  for (const listener of listeners) listener("x");
  assert.deepEqual(stops, [4]);
  shell.status = "stopped";
  shell.endedAt = shell.startedAt + 2000;
  finish();
  await new Promise((resolve) => setImmediate(resolve));
  assert.match(out.join(""), /Shell #4 was stopped by the user after 2s/);
  for (const listener of [...listeners]) listener("\x1b");
  assert.equal(listeners.size, 0, "the key listener is removed");
  assert.equal(shell.watchers.size, 0, "the output watcher is removed");
  assert.equal(out.at(-1), mod.CLEAR_ALL, "the screen and scrollback are cleared on the way out");
  assert.deepEqual(calls.slice(-4), ["raw false", "pause", "tui start", "render true"]);
  assert.equal(closed, 1);
  view.key("q");
  assert.equal(closed, 1, "closing twice does nothing");
});

test("the view leaves on q, left and ctrl+c, and restores pi when printing fails", () => {
  for (const key of ["q", "\x1b[D", "\x1bOD", "\x03"]) {
    const calls = [];
    const tui = { stop() {}, start: () => calls.push("start"), requestRender: () => {} };
    const io = { stdin: { on() {}, off() {} }, stdout: { write() {} } };
    const shell = { id: 1, command: "x", service: false, status: "exited", code: 0, signal: null, startedAt: 0, endedAt: 0, logPath: "/x", tail: "", done: Promise.resolve() };
    const view = new mod.ShellView(shell, tui, plainTheme, () => {}, io);
    view.open(() => Buffer.from(""));
    view.key("\x1b[A");
    assert.deepEqual(calls, []);
    view.key(key);
    assert.deepEqual(calls, ["start"], `${JSON.stringify(key)} returns to pi`);
  }
  const calls = [];
  const tui = { stop() {}, start: () => calls.push("start"), requestRender: (force) => calls.push(`render ${force}`) };
  const io = { stdin: { on() {}, off() {} }, stdout: { write(text) { if (text.includes("Shell #1")) throw new Error("EIO"); } } };
  const shell = { id: 1, command: "x", service: false, status: "exited", code: 0, signal: null, startedAt: 0, endedAt: 0, logPath: "/x", tail: "", done: Promise.resolve() };
  const view = new mod.ShellView(shell, tui, plainTheme, () => {}, io);
  assert.throws(() => view.open(() => Buffer.from("")), /EIO/);
  assert.deepEqual(calls, ["start", "render true"]);
});

test("a log past its cap keeps its newest output from a line start", () => {
  const path = join(root, "capped.log");
  const log = new mod.CappedLog(path, 100, 40);
  for (let i = 0; i < 20; i++) log.write(Buffer.from(`line ${String(i).padStart(2, "0")}\n`));
  log.close();
  const text = readFileSync(path, "utf8");
  assert.match(text, /^\[pif: older output dropped/);
  assert.match(text, /line 19\n$/);
  assert.ok(!text.includes("line 00"));
  const body = text.split("\n").slice(1).join("\n");
  assert.match(body, /^line \d\d\n/);
});

test("the startup sweep deletes only directories of pif processes that are gone", () => {
  const sweepRoot = join(root, "sweep");
  mkdirSync(join(sweepRoot, "999999"), { recursive: true });
  mkdirSync(join(sweepRoot, String(process.pid)), { recursive: true });
  mkdirSync(join(sweepRoot, String(process.ppid)), { recursive: true });
  mod.sweepLogs(sweepRoot);
  assert.ok(!existsSync(join(sweepRoot, "999999")));
  assert.ok(existsSync(join(sweepRoot, String(process.pid))));
  assert.ok(existsSync(join(sweepRoot, String(process.ppid))));
});

test("a project copy at .pi/extensions/shells.ts silences this one", () => {
  const project = join(root, "project");
  mkdirSync(join(project, ".pi", "extensions"), { recursive: true });
  writeFileSync(join(project, ".pi", "extensions", "shells.ts"), "");
  const cwd = process.cwd();
  process.chdir(project);
  try {
    const h = harness();
    assert.equal(h.tools.size, 0);
  } finally {
    process.chdir(cwd);
  }
});
