// Basic web search for the focus agent: two driver tools over Exa.
//
// web_search runs one Exa search and returns, per result, the title, URL,
// published date and the highlights Exa extracted for the query. web_fetch
// reads one URL through Exa /contents and returns highlights for a query, or
// the cleaned page text when no query is given. Both outputs sit under a
// character budget and say when they were cut, so the driver never has to
// summarise a page itself.
//
// Multi-search questions do not belong here: the driver hands them to the
// research subagent through delegate.ts. The key is EXA_API_KEY, exported by
// the pif launcher from the dotfiles root .env.
//
// A project that ships its own copy as .pi/extensions/web.ts wins: this file
// then registers nothing, because pi exits at startup when two extensions
// register the same tool name and offers no way to ask what is loaded.

import { existsSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const PROJECT_OVERRIDE = join(".pi", "extensions", "web.ts");

export function projectOverrides(cwd = process.cwd()): boolean {
  return existsSync(join(cwd, PROJECT_OVERRIDE));
}

export const EXA_BASE_URL = "https://api.exa.ai";
export const SEARCH_DEFAULT_RESULTS = 5;
export const SEARCH_MAX_RESULTS = 10;
export const SEARCH_BUDGET_CHARS = 3000;
export const FETCH_DEFAULT_CHARS = 6000;
export const FETCH_MAX_CHARS = 20000;
const HIGHLIGHTS_PER_URL = 2;
const HIGHLIGHT_SENTENCES = 3;
// Exa counts a markdown block with no sentence boundary as one sentence, so
// a single highlight can run to thousands of characters. Search results cut
// each highlight so one page cannot take the whole budget; a fetch asked for
// that page's passages on purpose, so it is capped by max_chars as a whole.
export const HIGHLIGHT_MAX_CHARS = 500;
const REQUEST_TIMEOUT_MS = 30_000;
const MISSING_KEY = "Error: EXA_API_KEY is not set. Put it in the dotfiles root .env; pif exports it.";

export interface SearchArgs {
  query: string;
  num_results?: number;
  since?: string;
}

export interface FetchArgs {
  url: string;
  query?: string;
  max_chars?: number;
}

interface ExaResult {
  title?: string | null;
  url?: string;
  publishedDate?: string | null;
  author?: string | null;
  highlights?: string[];
  text?: string;
}

interface ExaStatus {
  id?: string;
  status?: string;
  error?: { tag?: string; httpStatusCode?: number };
}

interface ExaResponse {
  results?: ExaResult[];
  statuses?: ExaStatus[];
  error?: string;
}

// `since` is a date (YYYY-MM-DD) or a relative span: 12h, 7d, 2w, 3m, 1y.
export function parseSince(since: string | undefined, now = new Date()): string | undefined {
  if (!since) return undefined;
  const value = since.trim();
  const relative = value.match(/^(\d+)\s*([hdwmy])$/i);
  if (relative) {
    const amount = Number(relative[1]);
    const unit = relative[2].toLowerCase();
    const date = new Date(now.getTime());
    if (unit === "h") date.setUTCHours(date.getUTCHours() - amount);
    else if (unit === "d") date.setUTCDate(date.getUTCDate() - amount);
    else if (unit === "w") date.setUTCDate(date.getUTCDate() - amount * 7);
    else if (unit === "m") date.setUTCMonth(date.getUTCMonth() - amount);
    else date.setUTCFullYear(date.getUTCFullYear() - amount);
    return date.toISOString();
  }
  const absolute = new Date(value);
  if (Number.isNaN(absolute.getTime())) {
    throw new Error(`since must be a date (YYYY-MM-DD) or a span like 7d, 2w, 3m, 1y; got "${since}"`);
  }
  return absolute.toISOString();
}

export function buildSearchRequest(args: SearchArgs, now = new Date()): Record<string, unknown> {
  const query = args.query?.trim();
  if (!query) throw new Error("query is required");
  const requested = Math.trunc(args.num_results ?? SEARCH_DEFAULT_RESULTS);
  const numResults = Math.min(SEARCH_MAX_RESULTS, Math.max(1, requested));
  const request: Record<string, unknown> = {
    query,
    type: "auto",
    numResults,
    contents: {
      highlights: { query, numSentences: HIGHLIGHT_SENTENCES, highlightsPerUrl: HIGHLIGHTS_PER_URL },
    },
  };
  const startPublishedDate = parseSince(args.since, now);
  if (startPublishedDate) request.startPublishedDate = startPublishedDate;
  return request;
}

export function buildContentsRequest(args: FetchArgs): Record<string, unknown> {
  const url = args.url?.trim();
  if (!url) throw new Error("url is required");
  const query = args.query?.trim();
  if (query) {
    return {
      urls: [url],
      highlights: { query, numSentences: HIGHLIGHT_SENTENCES, highlightsPerUrl: HIGHLIGHTS_PER_URL * 2 },
    };
  }
  return { urls: [url], text: { maxCharacters: clampChars(args.max_chars) } };
}

export function clampChars(maxChars: number | undefined): number {
  const requested = Math.trunc(maxChars ?? FETCH_DEFAULT_CHARS);
  return Math.min(FETCH_MAX_CHARS, Math.max(200, requested));
}

export function cleanHighlights(highlights: string[] | undefined, maxChars = HIGHLIGHT_MAX_CHARS): string[] {
  return (highlights ?? [])
    .map((h) => h.replace(/\s+/g, " ").trim())
    .filter(Boolean)
    .map((h) => (h.length > maxChars ? `${h.slice(0, maxChars).trimEnd()}…` : h));
}

function dateOnly(value: string | null | undefined): string {
  if (!value) return "";
  return value.slice(0, 10);
}

function resultHeader(result: ExaResult): string {
  const title = (result.title ?? "").trim() || "(untitled)";
  const date = dateOnly(result.publishedDate);
  return `## ${title}${date ? ` (${date})` : ""}\n${result.url ?? ""}`;
}

// One block per result. The budget applies to the whole text; a block that
// does not fit is dropped and the cut is announced, so the driver can ask for
// fewer results or a narrower query instead of guessing.
export function formatSearchResults(response: ExaResponse, budget = SEARCH_BUDGET_CHARS): string {
  const results = response.results ?? [];
  if (results.length === 0) return "No results.";
  const blocks = results.map((result) => {
    const highlights = cleanHighlights(result.highlights);
    const body = highlights.length ? highlights.map((h) => `- ${h}`).join("\n") : "- (no highlights returned)";
    return `${resultHeader(result)}\n${body}`;
  });
  const kept: string[] = [];
  let used = 0;
  for (const block of blocks) {
    const cost = block.length + (kept.length ? 2 : 0);
    if (used + cost > budget && kept.length > 0) break;
    kept.push(block);
    used += cost;
  }
  let text = kept.join("\n\n");
  if (text.length > budget) text = `${text.slice(0, budget)}…`;
  if (kept.length < blocks.length) {
    text += `\n\n[Showing ${kept.length} of ${blocks.length} results; ${budget} character budget reached.]`;
  }
  return text;
}

export function formatContents(response: ExaResponse, args: FetchArgs): string {
  const status = response.statuses?.[0];
  const result = response.results?.[0];
  if (!result) {
    const reason = status?.error?.tag ?? status?.status ?? "no content returned";
    return `Error: Exa could not read ${args.url} (${reason}).`;
  }
  const header = resultHeader(result);
  const limit = clampChars(args.max_chars);
  if (args.query?.trim()) {
    const highlights = cleanHighlights(result.highlights, Infinity);
    if (highlights.length === 0) return `${header}\n\nNo passages on this page matched the query.`;
    const passages = highlights.map((h) => `- ${h}`).join("\n");
    if (passages.length <= limit) return `${header}\n\n${passages}`;
    return `${header}\n\n${passages.slice(0, limit)}…\n\n[Truncated at ${limit} characters; raise max_chars for the rest of these passages.]`;
  }
  const text = (result.text ?? "").trim();
  if (!text) return `Error: Exa returned no text for ${args.url}.`;
  if (text.length <= limit) return `${header}\n\n${text}`;
  return `${header}\n\n${text.slice(0, limit)}\n\n[Truncated at ${limit} characters; pass a query to get the relevant passages, or raise max_chars.]`;
}

async function exa(path: "/search" | "/contents", body: Record<string, unknown>, signal?: AbortSignal): Promise<ExaResponse> {
  const key = process.env.EXA_API_KEY?.trim();
  if (!key) throw new Error(MISSING_KEY);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  const onAbort = () => controller.abort();
  signal?.addEventListener("abort", onAbort, { once: true });
  try {
    const response = await fetch(`${EXA_BASE_URL}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": key },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    const raw = await response.text();
    let parsed: ExaResponse = {};
    try {
      parsed = raw ? (JSON.parse(raw) as ExaResponse) : {};
    } catch {
      parsed = {};
    }
    if (!response.ok) {
      const detail = parsed.error ?? raw.slice(0, 200) ?? "";
      throw new Error(`Exa ${path} failed with HTTP ${response.status}${detail ? `: ${detail}` : ""}`);
    }
    return parsed;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", onAbort);
  }
}

export default function (pi: ExtensionAPI) {
  if (projectOverrides()) return;
  pi.registerTool({
    name: "web_search",
    label: "Web search",
    description:
      "Search the web through Exa. Returns per result the title, URL, published date and the passages that match the query. For one or two targeted lookups; use delegate with the research agent for anything needing several searches.",
    promptSnippet: "Search the web and get query-matched passages per result",
    promptGuidelines: [
      "Use web_search for one or two targeted lookups. When a question needs several searches or refinement, call delegate with agent research instead of looping web_search yourself.",
      "Pass since to web_search when recency matters (a date, or 7d, 2w, 3m, 1y).",
    ],
    parameters: {
      type: "object",
      properties: {
        query: { type: "string", description: "What to search for, phrased as a full question or statement." },
        num_results: {
          type: "integer",
          minimum: 1,
          maximum: SEARCH_MAX_RESULTS,
          description: `Results to return (default ${SEARCH_DEFAULT_RESULTS}, max ${SEARCH_MAX_RESULTS}).`,
        },
        since: {
          type: "string",
          description: "Only pages published after this point: a date (YYYY-MM-DD) or a span such as 7d, 2w, 3m, 1y.",
        },
      },
      required: ["query"],
    } as any,
    async execute(_toolCallId, params: SearchArgs, signal) {
      const request = buildSearchRequest(params);
      const response = await exa("/search", request, signal);
      return { content: [{ type: "text", text: formatSearchResults(response) }] };
    },
  });

  pi.registerTool({
    name: "web_fetch",
    label: "Web fetch",
    description:
      "Read one URL through Exa. With a query, returns the passages on that page that match it; without one, returns the cleaned page text capped at max_chars. Use it for a URL you already have, not to search.",
    promptSnippet: "Read one URL as cleaned text or as passages matching a query",
    promptGuidelines: [
      "Prefer web_fetch with a query over the bare page text; the passages are what you need and cost far fewer tokens.",
    ],
    parameters: {
      type: "object",
      properties: {
        url: { type: "string", description: "The page to read." },
        query: { type: "string", description: "What to look for on the page. When set, only matching passages are returned." },
        max_chars: {
          type: "integer",
          minimum: 200,
          maximum: FETCH_MAX_CHARS,
          description: `Cap on the returned text, passages or page (default ${FETCH_DEFAULT_CHARS}).`,
        },
      },
      required: ["url"],
    } as any,
    // A page Exa cannot read is thrown, so pi marks the result as an error.
    async execute(_toolCallId, params: FetchArgs, signal) {
      const request = buildContentsRequest(params);
      const response = await exa("/contents", request, signal);
      const text = formatContents(response, params);
      if (text.startsWith("Error:")) throw new Error(text);
      return { content: [{ type: "text", text }] };
    },
  });
}
