// Run with: node --test pi/tests/web.test.mjs
// Loads the real TypeScript extension with Node's type stripping. The pi
// import is type-only; fetch is stubbed, so no request leaves the process.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import web, {
  FETCH_DEFAULT_CHARS,
  HIGHLIGHT_MAX_CHARS,
  SEARCH_BUDGET_CHARS,
  buildContentsRequest,
  buildSearchRequest,
  formatContents,
  formatSearchResults,
  parseSince,
  projectOverrides,
} from "../.config/pif/extensions/web.ts";

const now = new Date("2026-11-18T12:00:00.000Z");

function register() {
  const tools = new Map();
  web({ registerTool: (tool) => tools.set(tool.name, tool) });
  return tools;
}

function stubFetch(handler) {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, headers: init.headers, body });
    const reply = await handler(url, body);
    return {
      ok: reply.status === undefined || reply.status < 400,
      status: reply.status ?? 200,
      text: async () => JSON.stringify(reply.json ?? {}),
    };
  };
  return { calls, restore: () => { globalThis.fetch = original; } };
}

test("since accepts spans and dates and rejects junk", () => {
  assert.equal(parseSince(undefined), undefined);
  assert.equal(parseSince("7d", now), "2026-11-11T12:00:00.000Z");
  assert.equal(parseSince("2w", now), "2026-11-04T12:00:00.000Z");
  assert.equal(parseSince("3m", now), "2026-08-18T12:00:00.000Z");
  assert.equal(parseSince("1y", now), "2025-11-18T12:00:00.000Z");
  assert.equal(parseSince("2026-10-01", now), "2026-10-01T00:00:00.000Z");
  assert.throws(() => parseSince("last tuesday", now), /since must be/);
});

test("search request uses auto type, clamped results and query highlights", () => {
  const request = buildSearchRequest({ query: "  pi coding agent extensions ", num_results: 50, since: "7d" }, now);
  assert.deepEqual(request, {
    query: "pi coding agent extensions",
    type: "auto",
    numResults: 10,
    startPublishedDate: "2026-11-11T12:00:00.000Z",
    contents: { highlights: { query: "pi coding agent extensions", numSentences: 3, highlightsPerUrl: 2 } },
  });
  assert.equal(buildSearchRequest({ query: "x" }).numResults, 5);
  assert.equal(buildSearchRequest({ query: "x", num_results: 0 }).numResults, 1);
  assert.equal("startPublishedDate" in buildSearchRequest({ query: "x" }), false);
  assert.throws(() => buildSearchRequest({ query: "   " }), /query is required/);
});

test("contents request asks for highlights with a query and capped text without", () => {
  assert.deepEqual(buildContentsRequest({ url: "https://a.test/p", query: "pricing" }), {
    urls: ["https://a.test/p"],
    highlights: { query: "pricing", numSentences: 3, highlightsPerUrl: 4 },
  });
  assert.deepEqual(buildContentsRequest({ url: "https://a.test/p" }), {
    urls: ["https://a.test/p"],
    text: { maxCharacters: FETCH_DEFAULT_CHARS },
  });
  assert.deepEqual(buildContentsRequest({ url: "https://a.test/p", max_chars: 10 }).text, { maxCharacters: 200 });
  assert.deepEqual(buildContentsRequest({ url: "https://a.test/p", max_chars: 1e9 }).text, { maxCharacters: 20000 });
  assert.throws(() => buildContentsRequest({ url: "" }), /url is required/);
});

test("search results render one block per result and announce a budget cut", () => {
  const results = [
    { title: "First", url: "https://a.test/1", publishedDate: "2026-11-10T08:00:00.000Z", highlights: ["One. Two.", " Three. "] },
    { title: "", url: "https://a.test/2", publishedDate: null, highlights: [] },
  ];
  const text = formatSearchResults({ results });
  assert.equal(text, [
    "## First (2026-11-10)", "https://a.test/1", "- One. Two.", "- Three.", "",
    "## (untitled)", "https://a.test/2", "- (no highlights returned)",
  ].join("\n"));
  assert.equal(formatSearchResults({ results: [] }), "No results.");

  const wall = formatSearchResults({ results: [{ title: "Wall", url: "https://a.test/w", highlights: [`${"word ".repeat(300)}end`] }] });
  assert(wall.length < HIGHLIGHT_MAX_CHARS + 60);
  assert.match(wall, /…$/);
  assert.equal(formatSearchResults({ results: [{ title: "Ws", url: "u", highlights: ["a\n\n  b\tc"] }] }), "## Ws\nu\n- a b c");

  const long = Array.from({ length: 6 }, (_, i) => ({
    title: `R${i}`, url: `https://a.test/${i}`, highlights: ["x".repeat(900), "y".repeat(900)],
  }));
  const cut = formatSearchResults({ results: long });
  assert(cut.length <= SEARCH_BUDGET_CHARS + 80);
  assert.match(cut, /\[Showing 2 of 6 results; 3000 character budget reached\.\]$/);
  assert(cut.includes("## R1"));
  assert(!cut.includes("## R2"));
});

test("fetch output is highlights with a query, capped text without, and an error line when unreadable", () => {
  const page = { title: "Doc", url: "https://a.test/doc", publishedDate: "2026-01-02", highlights: ["Match one.", "Match two."], text: "abcdef".repeat(2000) };
  assert.equal(
    formatContents({ results: [page] }, { url: "https://a.test/doc", query: "match" }),
    "## Doc (2026-01-02)\nhttps://a.test/doc\n\n- Match one.\n- Match two.",
  );
  // A fetched page's passages are not cut per highlight; max_chars caps the whole.
  const block = `${"review ".repeat(300)}end.`;
  const whole = formatContents({ results: [{ ...page, highlights: [block] }] }, { url: "https://a.test/doc", query: "review" });
  assert(whole.length > HIGHLIGHT_MAX_CHARS + 100);
  assert(whole.endsWith("end."));
  const capped = formatContents({ results: [{ ...page, highlights: [block, block] }] }, { url: "https://a.test/doc", query: "review", max_chars: 1000 });
  assert(capped.length < 1200);
  assert.match(capped, /…\n\n\[Truncated at 1000 characters; raise max_chars for the rest of these passages\.\]$/);
  assert.match(
    formatContents({ results: [{ ...page, highlights: [] }] }, { url: "https://a.test/doc", query: "nothing" }),
    /No passages on this page matched the query\./,
  );
  const plain = formatContents({ results: [page] }, { url: "https://a.test/doc", max_chars: 500 });
  assert(plain.startsWith("## Doc (2026-01-02)\nhttps://a.test/doc\n\nabcdef"));
  assert.match(plain, /\[Truncated at 500 characters; pass a query/);
  assert.equal(
    formatContents({ results: [], statuses: [{ id: "https://a.test/x", status: "error", error: { tag: "CRAWL_NOT_FOUND", httpStatusCode: 404 } }] }, { url: "https://a.test/x" }),
    "Error: Exa could not read https://a.test/x (CRAWL_NOT_FOUND).",
  );
});

test("the extension registers nothing when the project ships its own .pi/extensions/web.ts", () => {
  const cwd = mkdtempSync(join(tmpdir(), "web-override-"));
  assert.equal(projectOverrides(cwd), false);
  mkdirSync(join(cwd, ".pi", "extensions"), { recursive: true });
  writeFileSync(join(cwd, ".pi", "extensions", "web.ts"), "export default () => {};\n");
  assert.equal(projectOverrides(cwd), true);
  const previous = process.cwd();
  process.chdir(cwd);
  try {
    assert.equal(register().size, 0);
  } finally {
    process.chdir(previous);
  }
  assert.equal(register().size, 2);
});

test("tools are registered with prompt metadata and plain JSON schema parameters", () => {
  const tools = register();
  assert.deepEqual([...tools.keys()], ["web_search", "web_fetch"]);
  for (const tool of tools.values()) {
    assert.equal(typeof tool.promptSnippet, "string");
    assert(Array.isArray(tool.promptGuidelines) && tool.promptGuidelines.length > 0);
    assert.equal(tool.parameters.type, "object");
  }
  assert.deepEqual(tools.get("web_search").parameters.required, ["query"]);
  assert.deepEqual(tools.get("web_fetch").parameters.required, ["url"]);
  assert.match(tools.get("web_search").promptGuidelines[0], /delegate with agent research/);
});

test("execute sends the key header to Exa and fails plainly without a key or on HTTP errors", async () => {
  const tools = register();
  const previous = process.env.EXA_API_KEY;
  delete process.env.EXA_API_KEY;
  const stub = stubFetch(async (url, body) => {
    if (url.endsWith("/search")) {
      return { json: { results: [{ title: "T", url: "https://a.test/t", highlights: [`hit for ${body.query}`] }] } };
    }
    return { status: 422, json: { error: "unsupported url" } };
  });
  try {
    await assert.rejects(tools.get("web_search").execute("c1", { query: "q" }), /EXA_API_KEY is not set/);
    assert.equal(stub.calls.length, 0);

    process.env.EXA_API_KEY = "test-key";
    const result = await tools.get("web_search").execute("c2", { query: "q", since: "7d" });
    assert.equal(result.content[0].text, "## T\nhttps://a.test/t\n- hit for q");
    assert.equal(stub.calls[0].url, "https://api.exa.ai/search");
    assert.equal(stub.calls[0].headers["x-api-key"], "test-key");
    assert.equal(stub.calls[0].body.type, "auto");
    assert.equal(typeof stub.calls[0].body.startPublishedDate, "string");

    await assert.rejects(tools.get("web_fetch").execute("c3", { url: "https://a.test/bad" }), /Exa \/contents failed with HTTP 422: unsupported url/);
  } finally {
    stub.restore();
    if (previous === undefined) delete process.env.EXA_API_KEY;
    else process.env.EXA_API_KEY = previous;
  }
});
