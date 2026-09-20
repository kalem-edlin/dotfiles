/**
 * Derived from IndyDevDan/pi-vs-claude-code at
 * 0ed11f44932fdef29bd98467700019762298f50d.
 * Copyright (c) 2026 IndyDevDan.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * Purpose Gate — Forces the engineer to declare intent before working
 *
 * On session start, immediately asks "What is the purpose of this agent?"
 * via a text input dialog. A persistent widget shows the purpose for the
 * rest of the session, keeping focus. Blocks all prompts until answered.
 *
 * Usage: pi -e extensions/purpose-gate.ts
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { truncateToWidth } from "@mariozechner/pi-tui";

export default function (pi: ExtensionAPI) {
	let purpose: string | undefined;

	async function askForPurpose(ctx: any) {
		while (!purpose) {
			const answer = await ctx.ui.input(
				"What is the purpose of this agent?",
				"e.g. Refactor the auth module to use JWT"
			);

			if (answer && answer.trim()) {
				purpose = answer.trim();
			} else {
				ctx.ui.notify("Purpose is required.", "warning");
			}
		}

		ctx.ui.setWidget("purpose", (_tui: any, theme: any) => {
			return {
				render(width: number): string[] {
					const text = theme.fg("accent", theme.bold(`  PURPOSE: ${purpose!}`));
					const content = theme.bg("selectedBg", truncateToWidth(text, width, "", true));
					const pad = theme.bg("selectedBg", " ".repeat(width));
					return [pad, content, pad];
				},
				invalidate() {},
			};
		});
	}

	pi.on("session_start", async (_event, ctx) => {
		await askForPurpose(ctx);
	});

	pi.on("before_agent_start", async (event) => {
		if (!purpose) return;
		return {
			systemPrompt: event.systemPrompt + `\n\n<purpose>\nYour singular purpose this session: ${purpose}\nStay focused on this goal. If a request drifts from this purpose, gently remind the user.\n</purpose>`,
		};
	});

	pi.on("input", async (_event, ctx) => {
		if (!purpose) {
			ctx.ui.notify("Set a purpose first.", "warning");
			return { action: "handled" as const };
		}
		return { action: "continue" as const };
	});
}
