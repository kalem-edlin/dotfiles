// Background shells: pi's bash tool with two optional parameters. Contract:
// docs/tasks/pif-background-shells.md (D1 to D11).
//
// Without background or service the call runs pi's own bash tool unchanged.
// With background, the command starts in its own process group with its
// output piped to a capped log, and the call returns "Shell #N started" at
// once. The exit comes back as a "shell" message with steer delivery, like a
// delegate report. A background shell stops after DEFAULT_TIMEOUT_S unless
// the call passes timeout; a service (a dev server) has no default timeout
// and does not hold the pane at Working.
//
// "pif:shells" carries { running, active }: running counts non-service
// shells (agent-state.ts holds Working on it), active counts every running
// shell (statusline.ts shows it as "N shells"). Down or ctrl+n on an empty
// editor focuses that tag ("pif:shells-focus" { focused }), and enter then
// opens the list; ctrl+shift+s or /shells opens it directly. Opening a shell
// from the list stops pi's TUI and prints the shell's whole log to the
// terminal, then follows it, until q, esc or left hands the terminal back.
//
// Every line a component here renders is one terminal row: no newlines, no
// wider than the width it is given. A newline inside a rendered line moves
// the cursor without pi counting the row, and pi then paints the editor and
// footer over the transcript.
//
// A project that ships its own copy as .pi/extensions/shells.ts wins: this
// file then registers nothing, because pi exits at startup when two
// extensions register the same tool name.

import { spawn, type ChildProcess } from "node:child_process";
import {
  closeSync,
  existsSync,
  ftruncateSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { createBashToolDefinition, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isKeyRelease, Key, matchesKey, visibleWidth } from "@earendil-works/pi-tui";

export const DEFAULT_TIMEOUT_S = 60 * 60;
export const LOG_CAP_BYTES = 2 * 1024 * 1024;
export const LOG_KEEP_BYTES = 1024 * 1024;
export const TAIL_KEEP_CHARS = 16 * 1024;
export const REPORT_LINES = 20;
export const CARD_LINES = 5;
export const LIST_ROWS = 12;
export const KILL_GRACE_MS = 3000;
export const SHORTCUT = "ctrl+shift+s";
export const PROJECT_OVERRIDE = join(".pi", "extensions", "shells.ts");
const DROPPED = "[pif: older output dropped to keep this log under 2 MB]\n";

export function projectOverrides(cwd = process.cwd()): boolean {
  return existsSync(join(cwd, PROJECT_OVERRIDE));
}

export const logRoot = () => join(process.env.PIF_SHELLS_DIR ?? tmpdir(), "pif-shells");

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error: any) {
    return error?.code === "EPERM";
  }
};

// Deletes the log directories of pif processes that are gone (D6).
export function sweepLogs(root = logRoot()) {
  let names: string[] = [];
  try {
    names = readdirSync(root);
  } catch {
    return;
  }
  for (const name of names) {
    const pid = Number(name);
    if (!Number.isInteger(pid) || pid <= 0 || pid === process.pid || alive(pid)) continue;
    rmSync(join(root, name), { recursive: true, force: true });
  }
}

// Appends to a log file and cuts it back to its newest LOG_KEEP_BYTES, at a
// line start, once it passes LOG_CAP_BYTES.
export class CappedLog {
  private fd: number;
  size = 0;
  readonly path: string;
  readonly cap: number;
  readonly keep: number;
  constructor(path: string, cap = LOG_CAP_BYTES, keep = LOG_KEEP_BYTES) {
    this.path = path;
    this.cap = cap;
    this.keep = keep;
    this.fd = openSync(path, "a");
  }
  write(chunk: Buffer) {
    if (this.fd < 0) return;
    writeSync(this.fd, chunk);
    this.size += chunk.length;
    if (this.size <= this.cap) return;
    const data = readFileSync(this.path);
    let start = data.length - this.keep;
    const newline = data.indexOf(10, start);
    if (newline >= 0 && newline < data.length - 1) start = newline + 1;
    const kept = Buffer.concat([Buffer.from(DROPPED), data.subarray(start)]);
    ftruncateSync(this.fd, 0);
    writeSync(this.fd, kept);
    this.size = kept.length;
  }
  close() {
    if (this.fd < 0) return;
    closeSync(this.fd);
    this.fd = -1;
  }
}

type Status = "running" | "exited" | "failed" | "killed" | "timed out" | "stopped";
type StopReason = "user" | "timeout" | "session";

export type Shell = {
  id: number;
  command: string;
  service: boolean;
  timeoutS?: number;
  pid?: number;
  status: Status;
  code: number | null;
  signal: string | null;
  startedAt: number;
  endedAt?: number;
  logPath: string;
  tail: string;
  stopReason?: StopReason;
  // Removed from the list with x: its log is deleted once it has ended.
  removed?: boolean;
  child?: ChildProcess;
  log?: CappedLog;
  timer?: ReturnType<typeof setTimeout>;
  // Live readers of the output (the full-screen view), fed after the log.
  watchers?: Set<(chunk: Buffer) => void>;
  done: Promise<void>;
};

export const lastLines = (text: string, count: number) => {
  const lines = text.replace(/\n+$/, "").split("\n");
  return lines.slice(-count).join("\n");
};

const seconds = (shell: Shell) => Math.round(((shell.endedAt ?? Date.now()) - shell.startedAt) / 1000);

export function duration(totalSeconds: number) {
  if (totalSeconds < 60) return `${totalSeconds}s`;
  const m = Math.floor(totalSeconds / 60);
  if (m < 60) return `${m}m ${totalSeconds % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

export function outcome(shell: Pick<Shell, "status" | "code" | "signal" | "timeoutS">): string {
  switch (shell.status) {
    case "running":
      return "is running";
    case "exited":
      return "exited with code 0";
    case "failed":
      return `exited with code ${shell.code}`;
    case "timed out":
      return `reached its ${duration(shell.timeoutS ?? 0)} timeout and was stopped`;
    case "stopped":
      return "was stopped by the user";
    case "killed":
      return `was killed by ${shell.signal}`;
  }
}

export function report(shell: Shell): string {
  const kind = shell.service ? "service" : "shell";
  const tail = lastLines(shell.tail, REPORT_LINES);
  const output = tail.trim() ? `Last ${REPORT_LINES} lines of output:\n${tail}` : "No output.";
  return `Shell #${shell.id} (${kind}: ${shell.command}) ${outcome(shell)} after ${duration(seconds(shell))}.\n\n${output}\n\n[log: ${shell.logPath}]`;
}

export function startText(shell: Shell): string {
  const limit = shell.timeoutS ? ` It stops after ${duration(shell.timeoutS)}.` : "";
  return (
    `Shell #${shell.id} started in the background (pgid ${shell.pid}, log ${shell.logPath}).${limit} ` +
    `Its exit arrives as a "Shell #${shell.id}" message before your next model call; carry on meanwhile and do not poll or sleep for it. ` +
    `Read output with tail on the log; stop it with kill -- -${shell.pid}.`
  );
}

// ── Text that fits one row ─────────────────────────────────────────────────

const ICON: Record<Status, [string, string]> = {
  running: ["accent", "●"],
  exited: ["success", "✓"],
  failed: ["error", "✗"],
  killed: ["error", "■"],
  "timed out": ["error", "■"],
  stopped: ["warning", "■"],
};

// The message card's background, as pi paints a tool row: green for a clean
// exit, red for a failure, kill or timeout, the neutral pending shade for a
// shell the user stopped (delegate's "stopped" is the warning colour, not an
// error) or one still running.
export const CARD_BG: Record<Status, string> = {
  running: "toolPendingBg",
  exited: "toolSuccessBg",
  failed: "toolErrorBg",
  killed: "toolErrorBg",
  "timed out": "toolErrorBg",
  stopped: "toolPendingBg",
};

const ESCAPES = /\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)?|[@-Z\\-_])/g;
export const stripAnsi = (text: string) => text.replace(ESCAPES, "");

// One display row from arbitrary text: escapes and control characters
// removed, every whitespace run (newlines included) folded to one space.
export const flat = (text: string) =>
  stripAnsi(text).replace(/\s+/g, " ").replace(/[\u0000-\u001f\u007f]/g, "").trim();

// Output text as display rows: escapes removed, a carriage-return
// overwrite shown as what is left on screen, tabs as two spaces, other
// control characters dropped.
export function outputRows(text: string): string[] {
  const body = stripAnsi(text).replace(/\n+$/, "");
  if (!body.trim()) return [];
  return body.split("\n").map((line) =>
    (line.replace(/\r+$/, "").split("\r").pop() ?? "")
      .replace(/\t/g, "  ")
      .replace(/[\u0000-\u001f\u007f]/g, "")
      .trimEnd(),
  );
}

// Cuts plain text (no escapes, no newlines) to width columns, with an
// ellipsis when anything was cut.
export function fit(text: string, width: number): string {
  if (width <= 0) return "";
  if (visibleWidth(text) <= width) return text;
  let out = "";
  let used = 0;
  for (const char of text) {
    const w = visibleWidth(char);
    if (used + w > width - 1) break;
    out += char;
    used += w;
  }
  return `${out}…`;
}

// A command's first line, with " …" when more follow (a heredoc).
export function firstLine(command: string): string {
  const lines = command.split("\n").map(flat).filter(Boolean);
  return lines.length > 1 ? `${lines[0]} …` : lines[0] ?? "";
}

// The last guard on every rendered line: a row that still came out too
// wide is cut as plain text, so pi's line count stays true.
const guard = (lines: string[], width: number) =>
  lines.map((line) => (!line.includes("\n") && visibleWidth(line) <= width ? line : fit(flat(line), width)));

// ── The exit message card ──────────────────────────────────────────────────

export type CardData = {
  id: number | string;
  status: Status;
  service: boolean;
  seconds: number;
  code: number | null;
  signal: string | null;
  timeoutS?: number;
  command: string;
  output: string;
  log: string;
};

// Message details carry everything; a message from before they did is
// parsed back out of its content.
export function cardData(message: any): CardData {
  const details = message?.details ?? {};
  const content = typeof message?.content === "string"
    ? message.content
    : (message?.content ?? []).map((part: any) => part?.text ?? "").join("");
  const status: Status = ICON[details.status as Status] ? details.status : "exited";
  const command = details.command
    ?? content.match(/^Shell #\d+ \((?:shell|service): ([\s\S]*?)\) (?:is running|exited|reached|was)/)?.[1]
    ?? "";
  const log = details.log ?? content.match(/\[log: ([^\]\n]*)\]\s*$/)?.[1] ?? "";
  let output = details.output;
  if (output === undefined) {
    const marker = content.indexOf(" lines of output:\n");
    const end = content.lastIndexOf("\n\n[log: ");
    output = marker >= 0 ? content.slice(marker + " lines of output:\n".length, end > marker ? end : undefined) : "";
  }
  return {
    id: details.id ?? "?",
    status,
    service: Boolean(details.service),
    seconds: Number(details.seconds ?? 0),
    code: details.code ?? null,
    signal: details.signal ?? null,
    timeoutS: details.timeoutS,
    command,
    output,
    log,
  };
}

export function shortOutcome(data: Pick<CardData, "status" | "code" | "signal">): string {
  switch (data.status) {
    case "running":
      return "running";
    case "exited":
      return "exit 0";
    case "failed":
      return `exit ${data.code}`;
    case "killed":
      return `killed by ${data.signal}`;
    case "timed out":
      return "timed out";
    case "stopped":
      return "stopped by you";
  }
}

// The card: a block on the outcome's background, one padded row each. The
// header is icon, shell number, the command's first line, outcome and
// runtime. Collapsed it shows the last CARD_LINES output lines; expanded,
// the full command, the last REPORT_LINES lines and the log path.
export function cardLines(data: CardData, expanded: boolean, theme: any, width: number): string[] {
  const bg = CARD_BG[data.status];
  const [color, icon] = ICON[data.status];
  const inner = Math.max(0, width - 2);
  const row = (styled = "") => {
    const text = styled ? ` ${styled}` : "";
    return theme.bg(bg, text + " ".repeat(Math.max(0, width - visibleWidth(text))));
  };
  const label = `${icon} shell #${data.id}`;
  const tail = `  ${shortOutcome(data)} · ${duration(data.seconds)}${data.service ? " · service" : ""}`;
  const room = inner - visibleWidth(label) - visibleWidth(tail) - 2;
  const command = room >= 8 ? `  ${fit(firstLine(data.command), room)}` : "";
  const header = visibleWidth(label + command + tail) <= inner
    ? theme.fg(color, theme.bold(label)) + command + theme.fg("dim", tail)
    : theme.fg(color, theme.bold(fit(label + tail, inner)));
  const lines = [row(), row(header)];
  if (expanded) {
    const parts = data.command.split("\n").map((part) => stripAnsi(part).replace(/\t/g, "  ").replace(/[\u0000-\u001f\u007f]/g, ""));
    parts.forEach((part, index) => lines.push(row(theme.fg("dim", fit(`${index ? "  " : "$ "}${part}`, inner)))));
    lines.push(row());
  }
  const output = outputRows(data.output);
  const shown = expanded ? output.slice(-REPORT_LINES) : output.slice(-CARD_LINES);
  if (!output.length) lines.push(row(theme.fg("dim", "No output.")));
  else if (shown.length < output.length) {
    lines.push(row(theme.fg("dim", fit(`… ${output.length - shown.length} earlier lines`, inner))));
  }
  for (const line of shown) lines.push(row(theme.fg("toolOutput", fit(line, inner))));
  if (expanded && data.log) lines.push(row(), row(theme.fg("dim", fit(`log: ${data.log}`, inner))));
  else if (!expanded) lines.push(row(theme.fg("dim", fit("expand for the full command, more output and the log path", inner))));
  lines.push(row());
  return guard(lines, width);
}

// ── The shell list ─────────────────────────────────────────────────────────

const up = (data: string) => matchesKey(data, Key.up) || matchesKey(data, "ctrl+p");
const down = (data: string) => matchesKey(data, Key.down) || matchesKey(data, "ctrl+n");

// A centred box on a filled background: this session's shells, one row
// each. Enter resolves with the selected shell's id; esc or q with none.
export class ShellsPanel {
  selected = 0;
  private shells: () => Shell[];
  private theme: any;
  private stop: (shell: Shell) => void;
  private close: (id?: number) => void;
  constructor(shells: () => Shell[], theme: any, stop: (shell: Shell) => void, close: (id?: number) => void) {
    this.shells = shells;
    this.theme = theme;
    this.stop = stop;
    this.close = close;
    const list = shells();
    const running = list.findIndex((shell) => shell.status === "running");
    this.selected = running >= 0 ? running : Math.max(0, list.length - 1);
  }
  handleInput(data: string) {
    if (isKeyRelease(data)) return;
    const list = this.shells();
    if (matchesKey(data, Key.escape) || data === "q") return this.close();
    if (up(data) || data === "k") this.selected = Math.max(0, this.selected - 1);
    else if (down(data) || data === "j") this.selected = Math.min(list.length - 1, this.selected + 1);
    else if ((matchesKey(data, Key.enter) || matchesKey(data, Key.right)) && list[this.selected]) this.close(list[this.selected].id);
    else if (data === "x" && list[this.selected]) {
      // Removes the shell, running or finished, and deletes its log.
      this.stop(list[this.selected]);
      const left = this.shells().length;
      if (!left) return this.close();
      this.selected = Math.min(this.selected, left - 1);
    }
  }
  render(width: number): string[] {
    const t = this.theme;
    const fill = "toolPendingBg";
    const inner = Math.max(0, width - 4);
    const edge = (text: string) => t.bg(fill, t.fg("border", text));
    const body = (styled: string, bg = fill) => t.bg(bg, ` ${styled}${" ".repeat(Math.max(0, inner - visibleWidth(styled)))} `);
    const line = (styled = "", bg = fill) => edge("│") + body(styled, bg) + edge("│");
    const title = fit(" Background shells ", Math.max(0, width - 4));
    const top = edge("╭─") + t.bg(fill, t.fg("accent", t.bold(title))) + edge(`${"─".repeat(Math.max(0, width - 3 - visibleWidth(title)))}╮`);
    const lines = [top, line()];
    const list = this.shells();
    if (!list.length) lines.push(line(t.fg("dim", fit("No shells in this session.", inner))));
    const first = Math.max(0, Math.min(this.selected - Math.floor(LIST_ROWS / 2), list.length - LIST_ROWS));
    list.slice(first, first + LIST_ROWS).forEach((shell, offset) => {
      const selected = first + offset === this.selected;
      const [color, icon] = ICON[shell.status];
      const pointer = selected ? "› " : "  ";
      const left = `${pointer}${icon} #${shell.id}  `;
      const right = `  ${duration(seconds(shell))}${shell.service ? " · service" : ""}`;
      const room = inner - visibleWidth(left) - visibleWidth(right);
      const command = room >= 4 ? fit(firstLine(shell.command), room) : "";
      const gap = " ".repeat(Math.max(0, room - visibleWidth(command)));
      const text = visibleWidth(left + right) <= inner
        ? t.fg("accent", pointer) + t.fg(color, icon) + ` #${shell.id}  ` + (selected ? t.bold(command) : command) + gap + t.fg("dim", right)
        : fit(`${pointer}${icon} #${shell.id}`, inner);
      lines.push(line(text, selected ? "selectedBg" : fill));
    });
    if (list.length > LIST_ROWS) lines.push(line(t.fg("dim", fit(`${list.length} shells, ${first + 1} to ${Math.min(list.length, first + LIST_ROWS)} shown`, inner))));
    lines.push(line(), line(t.fg("dim", fit("↑↓ select · enter view · x remove · esc close", inner))));
    lines.push(edge(`╰${"─".repeat(Math.max(0, width - 2))}╯`));
    return guard(lines, width);
  }
  invalidate() {}
}

// ── The full-screen shell view ─────────────────────────────────────────────

export const CLEAR_ALL = "\x1b[0m\x1b[2J\x1b[H\x1b[3J";

// Text for the bare terminal: colours (SGR) kept, every other escape and
// control character but tab, newline and carriage return dropped, and each
// newline sent as CRLF.
export function forTerminal(text: string): string {
  return text
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, (seq) => (seq.endsWith("m") ? seq : ""))
    .replace(/\x1b(?!\[[0-?]*[ -/]*m)/g, "")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001a\u001c-\u001f\u007f]/g, "")
    .replace(/\r?\n/g, "\r\n");
}

export function detailHeader(shell: Shell, theme: any): string[] {
  const [color] = ICON[shell.status];
  const label = (name: string, value: string) => `${theme.bold(name.padEnd(10))}${value}`;
  const lines = [
    theme.fg("accent", theme.bold(`Shell #${shell.id}`)) + theme.fg("dim", shell.service ? "  service" : "  shell"),
    "",
    label("Status:", theme.fg(color, outcome(shell))),
    label("Runtime:", duration(seconds(shell))),
  ];
  if (shell.timeoutS) lines.push(label("Timeout:", duration(shell.timeoutS)));
  lines.push(label("Pgid:", String(shell.pid ?? "?")), label("Log:", shell.logPath));
  shell.command.split("\n").forEach((part, index) => lines.push(label(index ? "" : "Command:", part)));
  lines.push("", theme.fg("dim", "x stop · q, esc or ← back to pi"), theme.fg("dim", "─── output ───"));
  return lines.map(forTerminal);
}

export type ViewIO = {
  stdin: { on(event: "data", fn: (data: any) => void): any; off(event: "data", fn: (data: any) => void): any; setRawMode?(raw: boolean): any; setEncoding?(encoding: string): any; resume?(): any; pause?(): any };
  stdout: { write(text: string): any };
};

// Hands the terminal to one shell: stops pi's TUI (nothing renders while it
// is stopped), prints a header and the whole log into the normal screen
// buffer so the terminal's own scrollback and tmux copy mode read it, then
// prints new output as it arrives. q, esc, left or ctrl+c clear the screen
// and scrollback and start pi's TUI again with a full redraw.
export class ShellView {
  closed = false;
  private shell: Shell;
  private tui: any;
  private theme: any;
  private stopShell: (shell: Shell) => void;
  private io: ViewIO;
  private onClose: () => void;
  private decoder = new StringDecoder("utf8");
  private carry = "";
  private started = false;
  private readonly onKey = (data: any) => this.key(String(data));
  private readonly onOutput = (chunk: Buffer) => this.print(chunk);
  constructor(shell: Shell, tui: any, theme: any, stopShell: (shell: Shell) => void, io: ViewIO, onClose: () => void = () => {}) {
    this.shell = shell;
    this.tui = tui;
    this.theme = theme;
    this.stopShell = stopShell;
    this.io = io;
    this.onClose = onClose;
  }
  open(readLog: (path: string) => Buffer = readFileSync) {
    try {
      this.tui.stop();
      this.started = true;
      const { stdin, stdout } = this.io;
      stdin.setRawMode?.(true);
      stdin.setEncoding?.("utf8");
      stdin.on("data", this.onKey);
      stdin.resume?.();
      stdout.write(CLEAR_ALL);
      stdout.write(`${detailHeader(this.shell, this.theme).join("\r\n")}\r\n`);
      let log = Buffer.alloc(0);
      try {
        log = readLog(this.shell.logPath);
      } catch {
        // No log yet.
      }
      this.print(log);
      (this.shell.watchers ??= new Set()).add(this.onOutput);
      this.shell.done.then(() => this.ended());
    } catch (error) {
      this.close();
      throw error;
    }
  }
  private print(chunk: Buffer) {
    if (this.closed) return;
    let text = this.carry + this.decoder.write(chunk);
    // An escape cut at the chunk's end waits for the rest.
    const cut = text.match(/\x1b(?:\[[0-?]*[ -/]*|\][^\x07\x1b]*)?$/);
    this.carry = cut ? cut[0] : "";
    if (cut) text = text.slice(0, cut.index);
    if (text) this.io.stdout.write(forTerminal(text));
  }
  private ended() {
    if (this.closed) return;
    const [color] = ICON[this.shell.status];
    const t = this.theme;
    this.io.stdout.write(
      `\x1b[0m\r\n${t.fg(color, `─── Shell #${this.shell.id} ${outcome(this.shell)} after ${duration(seconds(this.shell))} ───`)}\r\n` +
        `${t.fg("dim", "q, esc or ← back to pi")}\r\n`,
    );
  }
  key(data: string) {
    if (this.closed) return;
    if (data.startsWith("\x1b")) {
      if (/^\x1b+$/.test(data) || /^\x1b(?:\[|O)D$/.test(data) || data === "\x1b[27u") this.close();
      return;
    }
    for (const char of data) {
      if (char === "q" || char === "\x03") return this.close();
      if (char === "x" && this.shell.status === "running") {
        this.stopShell(this.shell);
        this.io.stdout.write(`\x1b[0m\r\n${this.theme.fg("warning", `[stopping shell #${this.shell.id}]`)}\r\n`);
      }
    }
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    this.shell.watchers?.delete(this.onOutput);
    const { stdin, stdout } = this.io;
    try {
      stdin.off("data", this.onKey);
      stdin.setRawMode?.(false);
      stdin.pause?.();
      stdout.write(CLEAR_ALL);
    } finally {
      try {
        if (this.started) {
          this.tui.start();
          this.tui.requestRender(true);
        }
      } finally {
        this.onClose();
      }
    }
  }
}

// ── Focus on the status-line tag ───────────────────────────────────────────

export type FocusEnv = { active: number; cursorOnLastLine: boolean; editorFocused: boolean };
export type InputResult = { consume?: boolean; data?: string } | undefined;

// Down or ctrl+n in the focused editor, with the cursor on the draft's last
// line (empty or not), while a shell runs focuses the "N shells" tag. On an
// earlier line Down still moves the cursor. Focused: enter opens the list, up, ctrl+p or esc return to
// the editor, another down stays, and any other key returns to the editor
// and goes through unchanged. Key releases always go through.
export class ShellFocus {
  focused = false;
  private env: () => FocusEnv;
  private open: () => void;
  private changed: (focused: boolean) => void;
  constructor(env: () => FocusEnv, open: () => void, changed: (focused: boolean) => void) {
    this.env = env;
    this.open = open;
    this.changed = changed;
  }
  set(focused: boolean) {
    if (this.focused === focused) return;
    this.focused = focused;
    this.changed(focused);
  }
  handle(data: string): InputResult {
    if (isKeyRelease(data)) return undefined;
    if (!this.focused) {
      if (!down(data)) return undefined;
      const env = this.env();
      if (env.active < 1 || !env.editorFocused || !env.cursorOnLastLine) return undefined;
      this.set(true);
      return { consume: true };
    }
    if (this.env().active < 1) {
      this.set(false);
      return undefined;
    }
    if (matchesKey(data, Key.enter)) {
      this.set(false);
      this.open();
      return { consume: true };
    }
    if (up(data) || matchesKey(data, Key.escape)) {
      this.set(false);
      return { consume: true };
    }
    if (down(data)) return { consume: true };
    this.set(false);
    return undefined;
  }
}

export default function (pi: ExtensionAPI) {
  if (projectOverrides()) return;
  const builtin = createBashToolDefinition(process.cwd());
  const shells = new Map<number, Shell>();
  const dir = join(logRoot(), String(process.pid));
  let nextId = 1;
  let uiCtx: any;
  let mainTui: any;
  let view: ShellView | undefined;
  let unlistenInput: (() => void) | undefined;
  let last = { running: -1, active: -1 };

  const list = () => [...shells.values()];
  const activeCount = () => list().filter((shell) => shell.status === "running").length;

  const editorFocused = () => {
    if (!mainTui) return true;
    if (mainTui.hasOverlay?.()) return false;
    const focused = mainTui.getFocusedComponent?.();
    return Boolean(focused && typeof focused.getText === "function");
  };
  // The editor's cursor is on its last line; true when the editor gives no
  // cursor (an empty draft has one line).
  const cursorOnLastLine = () => {
    try {
      const editor = mainTui?.getFocusedComponent?.();
      if (typeof editor?.getCursor !== "function" || typeof editor?.getLines !== "function") return true;
      return editor.getCursor().line >= editor.getLines().length - 1;
    } catch {
      return false;
    }
  };
  const focus = new ShellFocus(
    () => ({ active: activeCount(), cursorOnLastLine: cursorOnLastLine(), editorFocused: editorFocused() }),
    // Deferred: an overlay opened inside the terminal-input handler is
    // created but never drawn (seen live 2026-11-18).
    () => void setTimeout(() => void openPanel(uiCtx), 0),
    (focused) => pi.events?.emit("pif:shells-focus", { focused }),
  );

  const emit = () => {
    const running = list().filter((shell) => shell.status === "running");
    const counts = { running: running.filter((shell) => !shell.service).length, active: running.length };
    if (!counts.active) focus.set(false);
    if (counts.running === last.running && counts.active === last.active) return;
    last = counts;
    pi.events?.emit("pif:shells", counts);
  };

  const signalGroup = (shell: Shell, signal: NodeJS.Signals) => {
    if (!shell.pid) return;
    try {
      process.kill(-shell.pid, signal);
    } catch {
      // Already gone.
    }
  };

  const stop = (shell: Shell, reason: StopReason) => {
    if (shell.status !== "running") return;
    shell.stopReason ??= reason;
    signalGroup(shell, "SIGTERM");
    setTimeout(() => {
      if (shell.status === "running") signalGroup(shell, "SIGKILL");
    }, KILL_GRACE_MS).unref?.();
  };

  // x in the list: drops the shell from this session's list and deletes its
  // log. A running shell is stopped first; its log goes once it has ended.
  const remove = (shell: Shell) => {
    shell.removed = true;
    shells.delete(shell.id);
    if (shell.status === "running") stop(shell, "user");
    else rmSync(shell.logPath, { force: true });
    emit();
  };

  const deliver = (shell: Shell) => {
    if (shell.stopReason === "session") return;
    const content = shell.removed
      ? `${report(shell).replace(/\n\n\[log: [^\n]*\]$/, "")}\n\n[removed from the shell list by the user; its log is deleted]`
      : report(shell);
    pi.sendMessage(
      {
        customType: "shell",
        content,
        display: true,
        details: {
          id: shell.id,
          status: shell.status,
          service: shell.service,
          seconds: seconds(shell),
          code: shell.code,
          signal: shell.signal,
          timeoutS: shell.timeoutS,
          command: shell.command,
          output: lastLines(shell.tail, REPORT_LINES),
          log: shell.removed ? "" : shell.logPath,
        },
      },
      { deliverAs: "steer", triggerTurn: true },
    );
  };

  const start = (command: string, cwd: string, service: boolean, timeoutS?: number): Shell => {
    mkdirSync(dir, { recursive: true });
    const id = nextId++;
    const shell = { id, command, service, timeoutS, status: "running", code: null, signal: null, startedAt: Date.now(), logPath: join(dir, `${id}.log`), tail: "" } as Shell;
    shell.log = new CappedLog(shell.logPath);
    let finish!: () => void;
    shell.done = new Promise<void>((resolve) => (finish = resolve));
    const child = spawn("bash", ["-c", command], { cwd, detached: true, stdio: ["ignore", "pipe", "pipe"], env: process.env });
    shell.child = child;
    shell.pid = child.pid;
    const onData = (chunk: Buffer | string) => {
      const buffer = typeof chunk === "string" ? Buffer.from(chunk) : chunk;
      shell.log?.write(buffer);
      shell.tail = (shell.tail + buffer.toString("utf8")).slice(-TAIL_KEEP_CHARS);
      for (const watcher of shell.watchers ?? []) watcher(buffer);
    };
    child.stdout?.on("data", onData);
    child.stderr?.on("data", onData);
    let ended = false;
    const end = (code: number | null, signal: string | null, error?: Error) => {
      if (ended) return;
      ended = true;
      if (shell.timer) clearTimeout(shell.timer);
      shell.endedAt = Date.now();
      shell.code = code;
      shell.signal = signal;
      if (error) onData(`${error.message}\n`);
      shell.log?.close();
      if (shell.stopReason === "timeout") shell.status = "timed out";
      else if (shell.stopReason) shell.status = "stopped";
      else if (signal) shell.status = "killed";
      else shell.status = code === 0 ? "exited" : "failed";
      if (error && shell.code === null) shell.code = 127;
      emit();
      deliver(shell);
      if (shell.removed) rmSync(shell.logPath, { force: true });
      finish();
    };
    child.on("error", (error) => end(null, null, error));
    child.on("close", (code, signal) => end(code, signal));
    if (timeoutS) shell.timer = setTimeout(() => stop(shell, "timeout"), timeoutS * 1000);
    shells.set(id, shell);
    emit();
    return shell;
  };

  const openView = (tui: any, theme: any, shell: Shell) => {
    if (view) return;
    const opened = new ShellView(shell, tui, theme, (target) => stop(target, "user"), { stdin: process.stdin, stdout: process.stdout }, () => {
      if (view === opened) view = undefined;
    });
    view = opened;
    try {
      opened.open();
    } catch (error: any) {
      view = undefined;
      uiCtx?.ui?.notify?.(`Could not show shell #${shell.id}: ${error?.message ?? error}`, "error");
    }
  };

  const openPanel = async (ctx: any) => {
    if (!ctx?.hasUI || view) return;
    if (!shells.size) {
      ctx.ui.notify("No background shells in this session.", "info");
      return;
    }
    let ticker: ReturnType<typeof setInterval> | undefined;
    let panelTui: any;
    let panelTheme: any;
    const id = await ctx.ui.custom(
      (tui: any, theme: any, _keybindings: any, done: (value: number | undefined) => void) => {
        panelTui = tui;
        panelTheme = theme;
        ticker = setInterval(() => tui.requestRender?.(), 1000);
        const panel = new ShellsPanel(list, theme, (shell) => {
          remove(shell);
          tui.requestRender?.();
        }, (picked) => done(picked));
        return {
          render: (width: number) => panel.render(width),
          handleInput: (data: string) => {
            panel.handleInput(data);
            tui.requestRender?.();
          },
          invalidate: () => {},
        };
      },
      { overlay: true, overlayOptions: { anchor: "center", width: "70%", minWidth: 40, maxHeight: "80%" } },
    );
    if (ticker) clearInterval(ticker);
    const shell = id === undefined ? undefined : shells.get(id);
    if (shell && panelTui) openView(panelTui, panelTheme ?? ctx.ui.theme, shell);
  };

  pi.on("session_start", (_event, ctx) => {
    uiCtx = ctx;
    sweepLogs();
    if (!ctx?.hasUI) return;
    // A widget with no rows, for the TUI handle the focus check needs.
    ctx.ui.setWidget?.("pif-shells", (tui: any) => {
      mainTui = tui;
      return { render: () => [], invalidate() {} };
    }, { placement: "belowEditor" });
    unlistenInput?.();
    unlistenInput = ctx.ui.onTerminalInput?.((data: string) => focus.handle(data));
  });

  pi.on("session_shutdown", async () => {
    view?.close();
    focus.set(false);
    unlistenInput?.();
    unlistenInput = undefined;
    const running = list().filter((shell) => shell.status === "running");
    for (const shell of running) stop(shell, "session");
    let guard: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([Promise.all(running.map((shell) => shell.done)), new Promise((r) => (guard = setTimeout(r, KILL_GRACE_MS + 500)))]);
    clearTimeout(guard);
    rmSync(dir, { recursive: true, force: true });
    shells.clear();
    emit();
  });

  pi.registerShortcut(SHORTCUT, {
    description: "Show background shells",
    handler: async (ctx: any) => openPanel(ctx ?? uiCtx),
  });

  pi.registerCommand("shells", {
    description: "Show this session's background shells",
    handler: async (_args: string, ctx: any) => openPanel(ctx ?? uiCtx),
  });

  pi.registerMessageRenderer("shell", (message: any, options: any, theme: any) => ({
    render: (width: number) => cardLines(cardData(message), Boolean(options?.expanded), theme, width),
    invalidate() {},
  }));

  const properties = (builtin.parameters as any).properties;
  pi.registerTool({
    ...builtin,
    name: "bash",
    description:
      `${builtin.description} ` +
      "With background: true it runs in the background and returns at once; its exit arrives later as a Shell #N message. A background run stops after one hour unless timeout is set.",
    parameters: {
      type: "object",
      properties: {
        ...properties,
        background: { type: "boolean", description: "Run in the background and return at once. For long jobs, watchers and monitors." },
        service: { type: "boolean", description: "With background: a long-lived process such as a dev server, with no default timeout." },
      },
      required: ["command"],
    } as any,
    async execute(toolCallId: string, params: any, signal: AbortSignal | undefined, onUpdate: any, ctx: any) {
      const background = Boolean(params.background || params.service);
      const service = Boolean(params.service);
      const cwd = ctx?.cwd ?? process.cwd();
      const tool = cwd === process.cwd() ? builtin : createBashToolDefinition(cwd);
      const plain = { command: params.command, ...(params.timeout ? { timeout: params.timeout } : {}) };
      if (!background) return tool.execute(toolCallId, plain as any, signal, onUpdate, ctx);
      // D9: without a UI nothing receives a background report, so a
      // non-service call blocks with the background default timeout.
      if (!ctx?.hasUI && !service) {
        return tool.execute(toolCallId, { command: params.command, timeout: params.timeout ?? DEFAULT_TIMEOUT_S } as any, signal, onUpdate, ctx);
      }
      const shell = start(params.command, cwd, service, params.timeout ?? (service ? undefined : DEFAULT_TIMEOUT_S));
      return { content: [{ type: "text", text: startText(shell) }], details: { shell: shell.id, background: true } as any };
    },
  } as any);
}
