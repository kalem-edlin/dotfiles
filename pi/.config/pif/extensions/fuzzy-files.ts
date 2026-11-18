/**
 * fzf-ranked @file autocomplete for pi.
 *
 * A TypeScript port of nvim/lua/file_mentions.lua. Keep the constants and
 * ranking rules in step with that file so @ mentions behave the same in both.
 *
 * Replaces @burneikis/pi-fzfp, which ran an unbounded `fd` over the whole tree
 * synchronously on every keystroke (`@~/` froze the TUI for ~17s per key).
 * Here discovery and ranking are async child processes that die when pi aborts
 * the request, listings are cached briefly, and prefixes outside the project
 * are searched only a few levels deep.
 *
 * Registered through ctx.ui.addAutocompleteProvider, so it applies to
 * whichever editor is active (pi-vim's included) regardless of load order.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { AutocompleteItem, AutocompleteProvider } from "@earendil-works/pi-tui";

// Mirrors `defaults` in nvim/lua/file_mentions.lua. pi's editor already
// debounces @ requests (20ms), which covers nvim's rank_delay_ms.
const MAX_ITEMS = 150;
// Prefixes outside the project (../, ~/, /) can be huge trees, so their
// recursive search stops at this depth.
const OUTSIDE_ROOT_MAX_DEPTH = 3;
const CACHE_TTL_MS = 4000;
const EXCLUDES = [
	".git", ".DS_Store", "node_modules", "dist", "build", "out", "target", "coverage",
	".next", ".nuxt", ".svelte-kit", ".turbo", ".vite", ".cache", ".parcel-cache",
	".pytest_cache", "__pycache__", ".mypy_cache", ".ruff_cache", ".venv", "venv",
	".smart-env",
];

// Same token rules as pi-tui's CombinedAutocompleteProvider.extractAtPrefix.
const PATH_DELIMITERS = new Set([" ", "\t", '"', "'", "="]);

type Listing = { paths: string[]; directories: Set<string>; input: string; expires: number };
const cache = new Map<string, Listing>();

function findBinary(names: string[]): string | null {
	for (const dir of (process.env.PATH ?? "").split(":")) {
		for (const name of names) {
			const candidate = join(dir, name);
			try {
				if (statSync(candidate).isFile()) return candidate;
			} catch {}
		}
	}
	return null;
}

const fdPath = findBinary(["fd", "fdfind"]);
const fzfPath = findBinary(["fzf"]);

export function extractAtPrefix(text: string): string | null {
	let quoteStart = -1;
	let inQuotes = false;
	for (let i = 0; i < text.length; i++) {
		if (text[i] === '"') {
			inQuotes = !inQuotes;
			if (inQuotes) quoteStart = i;
		}
	}
	const isTokenStart = (i: number) => i === 0 || PATH_DELIMITERS.has(text[i - 1]!);
	if (inQuotes && quoteStart > 0 && text[quoteStart - 1] === "@" && isTokenStart(quoteStart - 1)) {
		return text.slice(quoteStart - 1);
	}
	let lastDelimiter = -1;
	for (let i = text.length - 1; i >= 0; i--) {
		if (PATH_DELIMITERS.has(text[i]!)) {
			lastDelimiter = i;
			break;
		}
	}
	return text[lastDelimiter + 1] === "@" ? text.slice(lastDelimiter + 1) : null;
}

function realDirectory(path: string): string | null {
	try {
		const real = realpathSync(path);
		return statSync(real).isDirectory() ? real : null;
	} catch {
		return null;
	}
}

function gitRoot(start: string): string | null {
	for (let dir = start; ; dir = dirname(dir)) {
		if (existsSync(join(dir, ".git"))) return dir;
		if (dirname(dir) === dir) return null;
	}
}

/**
 * Port of M.resolve_query. When the typed prefix names a real directory, the
 * search is scoped there and fzf sees only the rest; the completion keeps the
 * prefix exactly as typed (including ~/). Otherwise a plain relative query is
 * matched whole against every path under the root, so `lua/fm` still finds
 * nvim/lua/file_mentions.lua.
 */
export function resolveQuery(
	root: string,
	query: string,
	home = homedir(),
): { directory: string; prefix: string; query: string } | null {
	if (query === "~") query = "~/";
	const slash = query.lastIndexOf("/");
	const prefix = slash === -1 ? "" : query.slice(0, slash + 1);
	const basename = query.slice(slash + 1);
	if (/[\x00-\x1f\x7f"]/.test(prefix)) return null;
	let directory: string | null;
	if (prefix.startsWith("~/")) {
		if (!home) return null;
		directory = realDirectory(`${home}/${prefix.slice(2)}`);
	} else if (prefix.startsWith("/")) {
		directory = realDirectory(prefix);
	} else {
		directory = realDirectory(`${root}/${prefix}`);
	}
	if (!directory) {
		const explicit = /^[/~]/.test(prefix) || /\/\.\.?\//.test(`/${prefix}`);
		if (explicit) return null;
		const realRoot = realDirectory(root);
		return realRoot ? { directory: realRoot, prefix: "", query } : null;
	}
	return { directory, prefix, query: basename };
}

/**
 * Port of collapse: a matching directory stands in for everything beneath it.
 * `paths` keeps fzf's order, and directories end in a slash.
 */
export function collapse(paths: string[]): string[] {
	const matched = new Set(paths.filter((p) => p.endsWith("/")));
	return paths.filter((path) => {
		const body = path.slice(0, -1);
		for (let i = body.indexOf("/"); i !== -1; i = body.indexOf("/", i + 1)) {
			if (matched.has(path.slice(0, i + 1))) return false;
		}
		return true;
	});
}

/** Everything matches an empty query, so only the top level survives, dotfiles last. */
export function topLevel(paths: string[]): string[] {
	const visible: string[] = [];
	const hidden: string[] = [];
	for (const path of paths) {
		if (path.slice(0, -1).includes("/")) continue;
		(path.startsWith(".") ? hidden : visible).push(path);
	}
	return [...visible, ...hidden];
}

/** Collect a child's stdout; resolves null if aborted or the exit code is unexpected. */
function run(
	argv: string[],
	opts: { cwd?: string; stdin?: string; env?: NodeJS.ProcessEnv; okCodes: number[] },
	signal: AbortSignal,
): Promise<string | null> {
	return new Promise((resolvePromise) => {
		if (signal.aborted) return resolvePromise(null);
		let child: ChildProcess;
		try {
			child = spawn(argv[0]!, argv.slice(1), {
				cwd: opts.cwd,
				env: opts.env,
				stdio: [opts.stdin === undefined ? "ignore" : "pipe", "pipe", "ignore"],
			});
		} catch {
			return resolvePromise(null);
		}
		const chunks: Buffer[] = [];
		const onAbort = () => child.kill("SIGTERM");
		signal.addEventListener("abort", onAbort, { once: true });
		child.stdout!.on("data", (chunk: Buffer) => chunks.push(chunk));
		child.on("error", () => {
			signal.removeEventListener("abort", onAbort);
			resolvePromise(null);
		});
		child.on("close", (code) => {
			signal.removeEventListener("abort", onAbort);
			if (signal.aborted || code === null || !opts.okCodes.includes(code)) return resolvePromise(null);
			resolvePromise(Buffer.concat(chunks).toString("utf-8"));
		});
		if (opts.stdin !== undefined) {
			child.stdin!.on("error", () => {});
			child.stdin!.end(opts.stdin);
		}
	});
}

async function listing(directory: string, maxDepth: number | null, signal: AbortSignal): Promise<Listing | null> {
	const key = `${directory}\0${maxDepth ?? ""}`;
	const cached = cache.get(key);
	if (cached && cached.expires > Date.now()) return cached;

	const argv = [fdPath!, "--type", "f", "--type", "d", "--color", "never", "--print0", "--hidden"];
	if (maxDepth !== null) argv.push("--max-depth", String(maxDepth));
	for (const excluded of EXCLUDES) argv.push("--exclude", excluded);
	const stdout = await run(argv, { cwd: directory, okCodes: [0, 1] }, signal);
	if (stdout === null) return null;

	const seen = new Set<string>();
	for (let path of stdout.split("\0")) {
		path = path.replace(/^\.\//, "");
		if (path && !/[\x00-\x1f\x7f"]/.test(path)) seen.add(path);
	}
	const paths = [...seen].sort();
	// fzf's path scheme scores a match before the last slash as a
	// parent-directory match, which ranked Daily/ below files such as
	// .smart-env/Daily_x.json for "Daily". Rank directories by their bare
	// names and restore the slash afterwards.
	const directories = new Set<string>();
	const names = paths.map((path) => {
		if (!path.endsWith("/")) return path;
		const name = path.slice(0, -1);
		directories.add(name);
		return name;
	});
	const entry = { paths, directories, input: `${names.join("\0")}\0`, expires: Date.now() + CACHE_TTL_MS };
	cache.set(key, entry);
	return entry;
}

async function rank(entry: Listing, query: string, signal: AbortSignal): Promise<string[] | null> {
	if (query === "" || entry.paths.length === 0) return topLevel(entry.paths);
	const stdout = await run(
		[fzfPath!, "--read0", "--print0", "--scheme=path", "-i", `--filter=${query}`],
		{
			stdin: entry.input,
			// Shell-picker settings must not change this noninteractive protocol.
			env: { ...process.env, FZF_DEFAULT_OPTS: "", FZF_DEFAULT_OPTS_FILE: "" },
			okCodes: [0, 1],
		},
		signal,
	);
	if (stdout === null) return null;
	const matches = stdout.split("\0").filter(Boolean).map((p) => (entry.directories.has(p) ? `${p}/` : p));
	return collapse(matches);
}

export async function suggest(
	rawQuery: string,
	quoted: boolean,
	cwd: string,
	signal: AbortSignal,
): Promise<AutocompleteItem[] | null> {
	const resolved = resolveQuery(cwd, rawQuery);
	if (!resolved) return null;
	// Stricter than nvim's rule: with no git project around cwd (e.g. pi
	// started in ~), every search is treated as outside and depth-limited.
	const realCwd = realDirectory(cwd);
	const project = realCwd ? gitRoot(realCwd) : null;
	const inside = project !== null && `${resolved.directory}/`.startsWith(`${project}/`);
	const entry = await listing(resolved.directory, inside ? null : OUTSIDE_ROOT_MAX_DEPTH, signal);
	if (!entry) return null;
	const ranked = await rank(entry, resolved.query, signal);
	if (!ranked) return null;
	return ranked.slice(0, MAX_ITEMS).map((relative) => {
		const path = resolved.prefix + relative;
		const value = quoted || path.includes(" ") ? `@"${path}"` : `@${path}`;
		// Like nvim's menu, show only what differs from the typed prefix. pi's
		// applyCompletion treats a label ending in "/" as a directory.
		return { value, label: relative };
	});
}

// The editor pi is showing, captured so accepting a directory can reopen the
// menu on its contents the way Blink does in nvim. pi's editor closes the menu
// after every accept and offers providers no handle to reopen it.
let activeEditor: { tryTriggerAutocomplete?: () => void } | undefined;
const WRAPPED = Symbol.for("pif.fuzzy-files.wrapped");

export function wrapWithFuzzyFiles(inner: AutocompleteProvider, basePath = process.cwd()): AutocompleteProvider {
	if (!fdPath || !fzfPath || (inner as any)[WRAPPED]) return inner;
	const provider: AutocompleteProvider = {
		async getSuggestions(lines, cursorLine, cursorCol, options) {
			const before = (lines[cursorLine] ?? "").slice(0, cursorCol);
			const atPrefix = extractAtPrefix(before);
			if (!atPrefix) return inner.getSuggestions(lines, cursorLine, cursorCol, options);
			const quoted = atPrefix.startsWith('@"');
			const items = await suggest(atPrefix.slice(quoted ? 2 : 1), quoted, basePath, options.signal);
			return items && items.length > 0 ? { items, prefix: atPrefix } : null;
		},
		applyCompletion(lines, cursorLine, cursorCol, item, prefix) {
			const result = inner.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
			// The editor closes the menu right after this returns, so reopen on
			// the next tick.
			if (prefix.startsWith("@") && item.label.endsWith("/")) {
				setTimeout(() => activeEditor?.tryTriggerAutocomplete?.(), 0);
			}
			return result;
		},
		shouldTriggerFileCompletion: inner.shouldTriggerFileCompletion?.bind(inner),
		triggerCharacters: inner.triggerCharacters,
	};
	(provider as any)[WRAPPED] = true;
	return provider;
}

export default function (pi: ExtensionAPI) {
	pi.on("session_start", (_event, ctx) => {
		if (!ctx.hasUI) return;
		// pi stacks this on the provider it hands every editor, pi-vim's included.
		ctx.ui.addAutocompleteProvider((current) => wrapWithFuzzyFiles(current, ctx.cwd));
		// pi-vim installs its editor during its own session_start. Wrap that
		// factory once every handler has run, to learn which editor to reopen.
		setTimeout(() => {
			const factory = ctx.ui.getEditorComponent() as any;
			if (!factory || factory[WRAPPED]) return;
			const capturing = (...args: any[]) => (activeEditor = factory(...args));
			(capturing as any)[WRAPPED] = true;
			ctx.ui.setEditorComponent(capturing as any);
		}, 0);
	});
}
