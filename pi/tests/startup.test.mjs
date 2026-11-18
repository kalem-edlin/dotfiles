// Run with: node --test pi/tests/startup.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { test } from "node:test";
import startup, { withoutThemes } from "../.config/pif/extensions/startup.ts";

const strip = (text) => text.replace(/\x1b\[[0-9;]*m/g, "");
const art = readFileSync(new URL("../../agents/startup-art.ansi", import.meta.url), "utf8").trimEnd().split("\n");
const profile = resolve("pi/.config/pif");

function harness(mode = "tui") {
  let onStart;
  let replacement;
  let expanded = false;
  let listing = ["[Context]", "  agents/communication.md", "", "[Skills]", "  show-me", "", "[Themes]", "  personal", ""];
  const header = {
    render: () => [" pi v0.85.1", expanded ? "full help" : "short help"],
    invalidate() {},
    setExpanded: (value) => { expanded = value; },
  };
  const resources = { children: [], render: () => listing, invalidate() {} };
  const nativeRender = resources.render;
  const chat = { children: [], render: () => ["chat"], invalidate() {} };
  const document = { children: [{ children: [header] }, resources, chat] };
  const tui = { children: [document] };
  startup({ on: (event, handler) => { assert.equal(event, "session_start"); onStart = handler; } });
  return {
    start() {
      const previous = process.env.PI_CODING_AGENT_DIR;
      process.env.PI_CODING_AGENT_DIR = profile;
      try {
        onStart({ reason: "startup" }, { mode, ui: { setHeader: (factory) => { replacement = factory(tui); } } });
      } finally {
        if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
        else process.env.PI_CODING_AGENT_DIR = previous;
      }
    },
    resources, nativeRender, header, chat,
    listing: (lines) => { listing = lines; },
    custom: () => replacement,
  };
}

test("only the theme listing is hidden, not later diagnostics or indented scope groups", () => {
  assert.deepEqual(withoutThemes([
    "[Skills]", "  show-me", "", "\x1b[35m[Themes]\x1b[0m    ", "  [user]", "    personal", "",
    "[Theme conflicts]", "  keep this warning", "", "[Extensions]", "  startup.ts",
  ]), ["[Skills]", "  show-me", "", "[Theme conflicts]", "  keep this warning", "", "[Extensions]", "  startup.ts"]);
});

test("shared art follows native resources, preserving help, expansion and chat", () => {
  const h = harness();
  h.start();
  const output = h.resources.render(100);
  assert(output.includes("[Context]"));
  assert(output.includes("  show-me"));
  assert(!output.includes("[Themes]"));
  assert.deepEqual(output.slice(-12, -1), art.map((line) => ` ${line}`));
  assert.deepEqual(h.custom().render(100), [" pi v0.85.1", "short help"]);
  h.custom().setExpanded(true);
  assert.deepEqual(h.custom().render(100), [" pi v0.85.1", "full help"]);
  assert.deepEqual(h.chat.render(100), ["chat"]);
  h.custom().dispose();
  assert.equal(h.resources.render, h.nativeRender);
});

test("narrow terminals and quiet resource lists do not get oversized art", () => {
  const h = harness();
  h.start();
  assert(!h.resources.render(20).some((line) => line.includes("▀")));
  h.listing([]);
  assert.deepEqual(h.resources.render(100), []);
});

test("print, JSON and RPC modes are untouched", () => {
  for (const mode of ["print", "json", "rpc"]) {
    const h = harness(mode);
    h.start();
    assert.equal(h.custom(), undefined);
    assert.equal(h.resources.render, h.nativeRender);
  }
});

test("art asset stays within its terminal cell budget", () => {
  assert.equal(art.length, 11);
  for (const line of art) {
    assert(strip(line).length <= 32);
    assert(line.endsWith("\x1b[0m"));
  }
});
