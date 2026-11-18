import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { Component } from "@earendil-works/pi-tui";

type Tree = Component & { children?: Tree[]; setExpanded?: (expanded: boolean) => void };
const plain = (text: string) => text.replace(/\x1b\[[0-9;]*m/g, "");

export function withoutThemes(lines: string[]): string[] {
  let hidden = false;
  return lines.filter((line) => {
    const text = plain(line).trimEnd();
    if (/^\[[^\]]+\]$/.test(text)) hidden = text === "[Themes]";
    return !hidden;
  });
}

// Pi 0.85 has no resource-list rendering hook. Keep this small adapter confined
// to its resource container, retaining native context, skills, diagnostics and
// Ctrl+O expansion. Do not alter the loaded resources or the model's prompt.
function findDocument(node: Tree): Tree | undefined {
  const [header, resources, chat] = node.children ?? [];
  if (resources?.children && chat?.children && header?.children?.some(
    (child) => child.setExpanded && /^\s*pi v\d/.test(plain(child.render(120)[0] ?? "")),
  )) return node;
  for (const child of node.children ?? []) {
    const found = findDocument(child);
    if (found) return found;
  }
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    let art: string[] = [];
    try {
      const profile = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".config/pif");
      const agents = dirname(realpathSync(join(profile, "communication.md")));
      art = readFileSync(join(agents, "startup-art.ansi"), "utf8").trimEnd().split("\n");
    } catch {
      // An absent optional asset must not prevent startup.
    }
    ctx.ui.setHeader((tui) => {
      const document = findDocument(tui as unknown as Tree);
      const [header, resources] = document?.children ?? [];
      const originalHeader = header?.children?.find((child) => child.setExpanded);
      if (!resources || !originalHeader) {
        // A factory failure leaves Pi's native header in place.
        throw new Error("Startup artwork needs an update for this Pi layout.");
      }
      const originalRender = resources.render;
      const render = (width: number) => {
        const lines = withoutThemes(originalRender.call(resources, width));
        if (lines.length && art.length && width >= 34) {
          lines.push("", ...art.map((line) => ` ${line}`), "");
        }
        return lines;
      };
      resources.render = render;
      return {
        render: (width) => originalHeader.render(width),
        invalidate: () => originalHeader.invalidate(),
        setExpanded: (expanded: boolean) => originalHeader.setExpanded?.(expanded),
        dispose() {
          if (resources.render === render) resources.render = originalRender;
        },
      };
    });
  });
}
