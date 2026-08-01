/**
 * Worktrees claim-enforcement extension.
 *
 * Global Pi-side enforcement half of the dotfiles worktree slot + claim
 * system (see docs/tasks/tmux-remote-workspaces/initial-plan.md,
 * "Worktree claims and editing ownership" -> "Enforcement surfaces", and
 * pi/.pi/agent/AGENTS.md for the full policy this backs up).
 *
 * Intercepts file-modifying tool calls ("write", "edit" -- Pi's only
 * built-in file-editing tools) and shells out to the global
 * `worktree-claim verify-writer` executable (installed by the dotfiles
 * `worktrees` package) before letting the call proceed. Mirrors the
 * tool-call interception pattern from the upstream
 * examples/extensions/protected-paths.ts precedent, and the SessionStart
 * subprocess pattern from ./tmux-workspace-resurrect.ts in this same repo.
 *
 * Exit code contract (stable, shared with the Claude/Codex hooks -- see
 * worktrees/.local/bin/worktree-claim's own header comment):
 *   0   ok, or non-opted-in/unclaimed repo             -> allow
 *   12  no stable tmux-session identity available       -> allow (NOT a
 *       block -- e.g. Pi running outside tmux)
 *   10  responsibility mismatch                         -> BLOCK
 *   11  active-writer host mismatch                     -> BLOCK
 *   13  claim conflicted                                -> BLOCK
 *   anything else (missing binary, usage/internal error) -> fail OPEN with
 *       a warning; a bug in this enforcement layer must never itself block
 *       ordinary editing.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const BLOCKING_CODES = new Set([10, 11, 13]);
const NON_BLOCKING_CODES = new Set([0, 12]);

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "write" && event.toolName !== "edit") {
			return undefined;
		}

		let result: { stdout: string; stderr: string; code: number; killed: boolean };
		try {
			result = await pi.exec("worktree-claim", ["verify-writer", "--path", ctx.cwd], {
				cwd: ctx.cwd,
				timeout: 5000,
			});
		} catch {
			// worktree-claim not on PATH, or exec itself failed -- fail open.
			// This layer is a backstop, not the sole guarantee (see AGENTS.md).
			return undefined;
		}

		if (NON_BLOCKING_CODES.has(result.code)) {
			return undefined;
		}

		if (BLOCKING_CODES.has(result.code)) {
			const reason = result.stderr.trim() || `worktree-claim verify-writer blocked (exit ${result.code})`;
			if (ctx.hasUI) {
				ctx.ui.notify(`Blocked by worktree-claim: ${reason}`, "warning");
			}
			return { block: true, reason };
		}

		// Any other exit (usage/internal error, e.g. 20, or something this
		// extension doesn't recognize yet) is a problem in the enforcement
		// layer itself, not evidence of an actual ownership conflict -- fail
		// open with a warning rather than blocking ordinary editing.
		if (ctx.hasUI) {
			const detail = result.stderr.trim();
			ctx.ui.notify(
				`worktree-claim verify-writer exited ${result.code} (failing open)${detail ? `: ${detail}` : ""}`,
				"warning",
			);
		}
		return undefined;
	});
}
