import { getSupportedThinkingLevels } from "@earendil-works/pi-ai";
import {
  SettingsManager,
  ThinkingSelectorComponent,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import type { ThinkingLevel } from "@earendil-works/pi-agent-core";

const THINKING_SELECTOR_SHORTCUT = "ctrl+shift+l";
const ALL_THINKING_LEVELS: ThinkingLevel[] = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
];

export default function (pi: ExtensionAPI) {
  pi.registerShortcut(THINKING_SELECTOR_SHORTCUT, {
    description: "Open thinking level selector without clearing the draft",
    handler: async (ctx) => {
      if (ctx.mode !== "tui") return;

      const levels = ctx.model
        ? getSupportedThinkingLevels(ctx.model)
        : ALL_THINKING_LEVELS;
      const settings = SettingsManager.create(ctx.cwd);

      await ctx.ui.custom<void>((tui, _theme, _keybindings, done) => {
        const select = (level: ThinkingLevel, persist: boolean) => {
          pi.setThinkingLevel(level);
          if (persist) settings.setDefaultThinkingLevel(level);
          ctx.ui.notify(
            persist
              ? `Default thinking level: ${level}`
              : `Thinking level: ${level}`,
            "info",
          );
          done(undefined);
        };

        const selector = new ThinkingSelectorComponent(
          pi.getThinkingLevel(),
          levels,
          (level) => select(level, false),
          () => done(undefined),
          (level) => select(level, true),
          settings.getDefaultThinkingLevel(),
        );

        const handleInput = selector.handleInput.bind(selector);
        selector.handleInput = (data: string) => {
          handleInput(data);
          tui.requestRender();
        };

        return selector;
      });
    },
  });
}
