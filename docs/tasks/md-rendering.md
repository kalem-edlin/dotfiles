# Markdown rendering investigation

## Goal

Provide two explicit Markdown reading paths from Neovim:

- `<leader>mr`, currently `Space m r`, toggles a terminal-native rendered reader.
- `<leader>mw`, currently `Space m w`, toggles a web-rendered preview.

Neovim's existing Markdown colors are sufficient for headings, emphasis, lists, links, blockquotes, code, and math while editing. A fallback renderer does not need to replace those. Its required jobs are readable wrapped tables and Mermaid diagrams or images.

## Current trial

### `md-render.nvim`

Repository: <https://github.com/delphinus/md-render.nvim>

Status: installed at `v3.8.3` for testing.

The trial uses the plugin's in-place rendered buffer with a small event-driven controller. It swaps the current Markdown source buffer for a separate read-only rendered buffer. The source buffer remains unchanged. Normal and Visual movement, search, and selection operate in the rendered buffer. Visual `y` copies the corresponding raw Markdown from the source. Pressing `i`, `I`, `a`, `A`, `o`, or `O` returns to the source and enters Insert mode. Leaving Insert mode through `<Esc>`, `<C-c>`, or another real mode change re-renders on Neovim's `ModeChanged` event. There is no timed re-entry. Pressing `<leader>mr` again disables reader mode and returns to the source.

### Source cursor and raw copying, 2026-09-10

`markdown_source.lua` supplies source-position lookup and the reader's buffer-local Visual `y` mapping. Insert-entry keys use the owning source block and match the rendered cursor's text within it. They no longer use the plugin's interpolated scroll position or discard the source column. `I`, `A`, `o`, and `O` retain their usual Vim meanings after returning to that source position.

Returning from Insert now preserves the editing cursor's screen row instead of accepting upstream's unconditional centering. The controller captures `winline()` before the buffer swap, maps the source character to its rendered row and column, and restores the rendered viewport synchronously. This also prevents returning to the first row of a wrapped paragraph when editing a later part. There is no deferred scroll correction or timer. Exact screen-row preservation is limited by the start of the rendered document and Neovim's normal scrolling constraints. The real Neovim/tmux test verifies a long wrapped paragraph with the cursor off-center, using both Escape and Ctrl-C.

The cursor investigation also found an upstream source-map corruption bug. Mermaid and PlantUML replacement removes rendered code lines without removing the matching `source_line_map` entries. Every later mapping can drift. A guarded in-memory patch for the pinned v3.8.3 removes those entries together and attributes diagram rows to their opening fence. The installed upstream checkout is unchanged. The patch deliberately errors if its expected implementation changes, so review it before changing the pin.

Copy behavior and limits:

- `V` then `y` copies complete underlying source lines. Several wrapped screen rows can correspond to one source line, so this can copy more text than the selected screen rows. Selecting a diagram region this way copies its fenced Mermaid block.
- `v` then `y` copies a source fragment. Selecting an entire bold phrase or link includes its hidden Markdown markers or destination. Partial selections preserve source fragments without inventing balancing Markdown syntax; those fragments need not be valid standalone Markdown.
- Selection boundaries on image pixels, generated borders, or other unmapped decorations are rejected with a message to use `V`. Rectangular Visual selections are also rejected because rendered rectangles have no consistent source equivalent.
- Character matching is best effort within the owning block. The plugin has no precise source-column metadata. Repeated text and complex rearranged layouts remain limits; use linewise copying when exact complete source is important.
- Yanks honor the selected register and normal clipboard configuration. Rendering stays enabled. This mapping affects Visual `y`; Normal-mode yank operators and terminal/tmux copy mode retain their own behavior.

`nvim --headless -u NONE -l nvim/tests/markdown_source.lua` passes for full/partial inline syntax, links, reversed selections, wrapped text, complete diagram source, and cursor position after diagrams. The real Neovim/tmux integration test also verifies `i` at the matching source character after a Mermaid block, return to rendering on Escape, Visual raw-Markdown yanks, and a named register. Reopen Neovim to load these changes.

Useful behavior already provided:

- prose and headings wrap;
- expanded tables render cells over multiple physical lines;
- Mermaid fences render as images through `mmdc`;
- cursor position maps between source and rendered buffers;
- Insert-entry keys switch to the editable source automatically, so the rendered buffer never needs to become modifiable.

### Pane width and rebuild positioning, 2026-09-10

The pinned preview explicitly clamps automatic width to 80 columns in both initial window binding and resize handling. `markdown_view.lua` removes those two clamps in memory, so layout receives the Neovim window's usable text width. Expanded table cells can use that width. Table toggles now use the profiles below; code-block toggles remain unchanged. The installed plugin checkout is unchanged.

The cursor jumps share a structural cause: this plugin replaces a generated buffer when it reflows, but restores old **rendered** cursor/topline numbers. Those numbers can now refer to different source text. `markdown_view.lua` wraps session rebuilds with source-character anchors and the cursor's screen row. It retains the pre-resize snapshot before Neovim clamps the old layout, restores against the new source map, and accounts for Neovim's additional word wrapping when choosing the viewport top. Source extmarks follow edits made before the anchor. Height-only resizes and the separate image-download rebuild route use the same restoration helper. Insert exit also uses that helper. No new timer is introduced; width reflow retains upstream's existing debounce.

Verification: the isolated Neovim/tmux integration test checks repeated pane-width changes between 45 and 110 columns, a rapid resize burst, full usable layout width, expanded table width above 80 columns, cursor screen-row and source-character stability both in prose and inside an expanded table, expansion/collapse above the cursor, a source insertion before the anchor followed by a live-update event, and a height-only resize. Existing Escape/Ctrl-C, source-yank, and image-transport checks remain in the same test. Source-mapping and image-transport unit tests also pass. Image-download rebuild positioning uses the shared helper but has not been separately exercised with a delayed remote download.

Limits: exact source-column matching is still best effort because upstream exposes line ownership rather than character mappings. Generated borders, collapsed/hidden content, images, repeated text, and very large blocks can require a nearest-source fallback. Document boundaries, a pane shorter than the requested cursor row, and Neovim scrolling constraints can prevent exact screen-row preservation. Simultaneous previews of the same generated buffer share a layout width; this does not create independent per-window render buffers. Active Visual selection endpoints are not remapped by this change.

Known gaps:

- **Fixed locally, 2026-09-10:** The pinned plugin omitted tmux's graphics passthrough wrapper, leaving blank image rows. `nvim/lua/md_render_tmux.lua` now supplies a plugin-local transport. Restart Neovim after this configuration change.
- **Fixed locally, 2026-09-10:** automatic layout uses the pane's usable width instead of the upstream 80-column cap;
- compact oversized tables and code lines use ellipses until expanded;
- there is no public `expand all by default` option;
- terminal images still use the Kitty graphics protocol and must be tested across Ghostty and tmux window changes.

The upstream width limitation is tracked in <https://github.com/delphinus/md-render.nvim/issues/31>. Local compatibility patches are guarded against the pinned implementation and must be reviewed before upgrading.

### Per-table viewing profiles, 2026-09-10

Inside a pipe table, Enter or `za` cycles **compact → equal → proportional → compact**. The plugin's table-click action follows the same cycle. The choice is per table, not global. The command area reports the chosen profile. `<leader>mr` still toggles the whole reader. Code blocks retain their ordinary two-state expansion and callout folds are unchanged. Small tables also expose the cycle, even when they have no truncated cells.

- Compact retains the upstream proportional/truncated presentation.
- Equal wraps all cells, sizes the first column for row labels with a cap, and divides the remaining available width equally among comparison columns, within one terminal cell for rounding. The label cap is the larger of one equal share or one quarter of the cell-width budget. This profile deliberately treats the first column as labels; use proportional for tables where that assumption does not fit.
- Proportional wraps all cells using upstream's content-based allocation. Both expanded profiles use the available pane width.

Oversized words show a `↪` continuation marker in `NonText` highlight. Ordinary wrapping between words has no marker. Markers do not modify Markdown source and are excluded from raw source yanks. Terminal/tmux copy mode still sees the displayed marker. A two-cell-wide Unicode glyph in a two-cell column has no spare cell for a marker; its content is retained. Tables with more columns than can physically fit their borders and minimum cell widths can still exceed an extremely narrow pane.

`markdown_tables.lua` applies guarded runtime patches to the pinned renderer. No additional plugin, CLI dependency, or timer was added. Table source matching now works cell by cell, because wrapped rows interleave columns and cannot reliably be matched as one text stream. This keeps source characters in their own cells when changing profiles and prevents marker characters from entering raw yanks.

Cycling preserves the logical source anchor and cursor screen row through the existing viewport helper. If compact mode hides that character, the cursor uses the nearest visible position in the same cell and the cycle remembers the original character for re-expansion. Cycling from a different cursor position or screen row, or after editing the source, starts a fresh anchor. Normal document-edge and window-height constraints still apply. Profile state is session-local and follows upstream's source-line block IDs, so inserting/removing source lines above a table can reset its chosen profile.

Verification: `nvim --headless -u NONE -l nvim/tests/markdown_tables.lua` covers layout differences, equal shares, width bounds, continuation markers, Unicode, source-character round trips, raw yanks, and untruncated tables. `python3 nvim/tests/md_render_tmux_integration.py` exercises the actual Enter and `za` mappings in Neovim/tmux, checks cursor and screen-row preservation including hidden compact text, independent table choices, and unchanged code-block toggles. The existing source, image, resize, and mode-transition checks remain included. Mouse cycling shares the dispatch but has not been separately driven in the test.

### Expanded fenced-block wrapping, 2026-09-10

The reported off-screen expanded text was a separate upstream policy, not another width cap. Fenced blocks expose their complete original lines when expanded, and `Session:rebuild()` then sets `wrap=false` whenever any block is expanded. That makes expanded code horizontally scroll instead of wrapping. Tables looked correct because their cell wrapper generates multiple physical rows itself.

The viewport adapter now keeps `wrap=true` in every window displaying the rebuilt reader buffer. Expanded code uses Neovim's native soft wrapping at the current window width, retaining the existing `linebreak` and `breakindent` settings. No physical newlines are inserted, so syntax highlighting, URL ranges, raw copying, and source-line mappings keep their original coordinates. Compact code still uses ellipses and Enter/`za` still toggles it. Table profile allocation is unchanged.

The earlier code-block smoke test checked expansion state, not whether the expanded tail was visible. The integration test now checks native screen-row height for typed code and the actual captured tmux grid for the tails of untyped fences and fences inside blockquotes, after expanding and resizing the pane. It also checks source cursor/screen-row stability, no horizontal scroll offset, and successful re-compaction. This is terminal-grid verification, not a desktop Ghostty screenshot.

### Image failure verification, 2026-09-10

The original smoke checks did not establish visible images in Ghostty through tmux. The user's reports exposed that gap. The first `flowchart LR` in `content-engine-5/docs/tasks/carousels/synthesis.md` generated a valid 1568 × 954 PNG through the installed plugin. Its screenshot asset `shot-2026-09-08-1-42-24-am.png` is a valid 536 × 1134 PNG. Both files were visually inspected outside the terminal and contain the expected content. Capturing the plugin's output confirmed that both transmit and display commands lack the tmux wrapper. This establishes a shared transport failure, independent of Mermaid generation or screenshot decoding.

The installed compatibility module loads only `md-render.image` with a scoped output API. It leaves Neovim's global API and the installed plugin checkout unchanged. It wraps graphics and their cursor movements, translates coordinates for tmux pane offsets and a top status bar, namespaces image IDs per process, and replaces terminal-wide deletes with deletes of owned images. Focus loss and leaving the reader clear placements; returning redraws them. Background redraws are suppressed.

Session-switch testing found that the old session cannot deliver cleanup through a client that has switched sessions. The module caches attached client TTY paths while visible and sends only owned-image deletion commands directly to those terminals on leave. All image drawing still goes through tmux with `allow-passthrough on`; no global or pane option is broadened.

Verification commands:

```sh
nvim --headless -u NONE -l nvim/tests/md_render_tmux.lua
python3 nvim/tests/md_render_tmux_integration.py
```

Both pass. The integration test launches real Neovim inside an isolated tmux server and captures its attached terminal output. It checks PNG and Mermaid display commands, split-pane and top-status offsets, cleanup on window and session switches, suppression of background placements, redisplay on return, and cleanup when toggled off. It closes its test processes afterward. These are graphics-transport checks, not a visual Ghostty pass. Direct Ghostty UI inspection was denied by the computer-control tool, so the user's terminal remains the final visual check. This adapter targets local tmux; remote SSH image-file transport and nested multiplexers are not verified.

Relevant sources: [pinned image output implementation](https://github.com/delphinus/md-render.nvim/blob/03545aee6f1c14838f0be2979b50553fa1df646c/lua/md-render/image.lua), [Neovim 0.12.2 TUI output](https://github.com/neovim/neovim/blob/v0.12.2/src/nvim/tui/tui.c).

Do not build a Markdown renderer from scratch. A small controller or a narrow pinned patch for pane width, default expansion, and code wrapping is reasonable. Reimplementing Markdown layout, source mapping, Unicode width handling, image lifecycle, and Mermaid rendering is not reasonable for this dotfiles repository.

### `peek.nvim`

Repository: <https://github.com/toppair/peek.nvim>

Status: installed for testing with its supported native webview.

`<leader>mw` opens or closes Peek. Its webview provides browser-grade Markdown, responsive tables, TeX, Mermaid, live updates, and synchronized scrolling. While focused, Peek supports `j`, `k`, `u`, `d`, `g`, and `G` scrolling.

The controller keeps the trials mutually exclusive. Opening Peek from an `md-render.nvim` view first returns the Neovim window to its source buffer. Opening the terminal reader closes Peek if it is running.

Peek's supported targets are a native webview window or a browser. It does not embed a browser inside a Neovim or tmux pane. The webview window is titled `Peek preview`, so Aerospace rules can target it if the default window behavior becomes annoying.

Peek currently disables ordinary link navigation in its renderer by replacing generated link targets with `javascript:return`; only same-document anchors receive a click handler. Its supported focused-window keys cover scrolling, not opening links. Making local and external links usable in Peek therefore needs an upstream change or a maintained fork, not another Neovim link plugin.

Peek has no `focus = false` or background-webview option, but an AeroSpace window-creation rule now restores focus after it opens. `aerospace/aerospace.toml` matches the `deno` application with the exact window title `Peek preview`, tiles that window, and runs a single `focus-back-and-forth` command if Peek is still focused. The original floating decision was corrected on 2026-09-10 because it hid the hands-free preview behind the terminal. The rule is reloaded and the already-open Peek window was changed to tiling, confirmed as `h_tiles`. The rule excludes AeroSpace startup. It requires no Peek patch, timer, or persistent watcher, and later intentional navigation into Peek works normally. `<leader>mw` continues to open and close the preview while cursor mirroring runs in Neovim.

This corrects the earlier investigation. AeroSpace's warning concerns changing focus inside its **focus-change callbacks**, not a blanket prohibition on automation after window creation. The implementation uses `exec-and-forget` to run the focus command outside the creation callback. See the [callback documentation](https://nikitabobko.github.io/AeroSpace/guide#callbacks) and [focus-back-and-forth command](https://nikitabobko.github.io/AeroSpace/commands#focus-back-and-forth).

This is focus restoration, not suppression of Cocoa activation. A brief focus flicker remains possible. AeroSpace also warns that window titles can arrive after creation matching; the current pinned Peek successfully matched in three live launches on AeroSpace `0.20.3-Beta`. Recheck this after either application changes. The older app-name rule matching `preview` does not match Peek, whose application name is `deno`.

## Link and path navigation investigation

Neovim 0.12 already defines the general conventions:

- `gf` opens the file under the cursor in Neovim. `gF` also consumes a following line number. Relative lookup uses `'path'`; dot-relative paths such as `../nvim/init.lua` resolve from the current file, and escaped spaces such as `some\ file.md` are supported.
- Visual `gf` opens the exact selected path, including spaces and special characters.
- `gx` and Visual `gx` send a path, URI, LSP `documentLink`, or selection to `vim.ui.open()`. On macOS this uses the system `open` handler.
- `gd` means "go to local declaration" in Vim and is commonly reused for LSP definitions. Do not replace it globally with link following.

The strongest established Markdown-specific option is `tadmccorkle/markdown.nvim`. Its `gx` follows headings and Markdown files inside Neovim, opens URLs in the browser, and exposes a separate `<Plug>(markdown_follow_link_default_app)` mapping that sends non-Markdown destinations such as images and PDFs to their system application. It handles Markdown source through Tree-sitter, so it cannot see links in `md-render.nvim`'s generated reader buffer. Install it only if one-key dispatch by destination type is worth adding; Neovim already covers direct path opening with `gf` and system opening with `gx`.

`jghauser/follow-md-links.nvim` is simpler but always opens local files in Neovim. `Nedra1998/nvim-mdlink` and `jakewvincent/mkdnflow.nvim` can dispatch binary files to system applications, but the former is narrower and less established while the latter adds a full notebook workflow. `chrishrb/gx.nvim` is useful for GitHub, package, and web-search patterns, but Neovim 0.12 already owns the basic `gx` behavior.

`md-render.nvim` stores each rendered link destination in an extmark. Neovim 0.12's built-in `gx` reads URL extmarks, so `gx` already opens rendered links without an adapter. `gf` only sees the visible label and cannot recover the hidden destination. Relative destinations remain unresolved strings, so `gx` passes them to macOS relative to Neovim's working directory rather than the source Markdown file's directory.

Revealing a file in native Finder is distinct from opening it with its default application. Neovim's `gx` uses `open <path>`; Finder reveal requires macOS `open -R <path>`. File-tree plugins can reveal paths inside their own Neovim explorers, but no focused, maintained plugin found in this investigation adds Finder reveal for arbitrary full, relative, escaped, or visually selected paths. If this remains desirable, a small global mapping around `open -R` is less maintenance than installing a file-tree plugin solely for that command.

## Rejected terminal-browser experiment

Do not add Carbonyl, Carboxyl, Browsh, or a patched Peek launcher merely to force a browser into tmux. None is an easy, supported Ghostty and tmux integration for this setup.

`TWeb` claims to run Electron or macOS WebKit inside a tmux pane on stock Ghostty: <https://github.com/keyolk/tweb>. It is not accepted for this configuration because it currently has no releases, no visible adoption, an unvalidated macOS WebKit path, a roughly 295 MB Electron runtime, and renders frames through Kitty graphics. That last point preserves the same class of terminal-overlay risk already observed with Mermaid images.

Reconsider an embedded webview only when Ghostty, tmux, or a mature project documents and supports the integration. Terminal embedding is a preference, not a requirement. A small Aerospace-managed Peek window is the supported fallback.

## Observed failures in the first implementation

The first implementation combined `render-markdown.nvim`, `diagram.nvim`, and `image.nvim`.

- Long table rows overflowed or appeared as raw pipe syntax.
- Table layout was difficult to read because extmarks and conceal cannot turn one source line into several real table rows.
- Mermaid output was too small.
- Mermaid source remained visible beside the image.
- Syntax reappeared around the cursor and while selecting text.
- Kitty image placements leaked across tmux windows and over unrelated Neovim views.

The cause was structural. `render-markdown.nvim` decorates the editable source buffer. It is not a separate reader. `diagram.nvim` renders an image alongside the fenced source. `image.nvim` places graphics outside Neovim's text grid through the terminal graphics protocol.

## Viable fallback

If `md-render.nvim` and Peek are both rejected, use this narrower stack:

- `ice345/markdown-table-wrap.nvim` for protected reader buffers and multiline table-cell wrapping;
- `3rd/diagram.nvim` for extracting Mermaid fences;
- `3rd/image.nvim` for displaying the generated diagrams.

Repository: <https://github.com/ice345/markdown-table-wrap.nvim>

This fallback is valid because native Neovim Markdown highlighting already covers the remaining syntax. `SCJangra/table-nvim` is not a renderer. It edits and aligns Markdown table source while typing, so it may be useful for authoring but does not replace `markdown-table-wrap.nvim`.

The fallback retains the known Ghostty and tmux image-placement risk. It must not become the active configuration until the image lifecycle passes a window-switch test.

## Dependencies already available

- Neovim 0.12.2 satisfies `md-render.nvim`'s minimum version.
- Deno is installed for Peek.
- `mmdc` is installed for Mermaid conversion.
- ImageMagick is available for image conversion.
- the `markdown` and `markdown_inline` Tree-sitter parsers are managed by the Neovim configuration.
- tmux has `allow-passthrough on`, `focus-events on`, and `visual-activity off`.

`utftex` remains installed, but neither current trial depends on it for the core reader behavior.

## Test checklist

Use real documents containing long tables and Mermaid diagrams.

### `Space m r`

- toggle auto mode from source to the read-only `md-render.nvim` view and back;
- move with Normal-mode keys;
- select and yank visible text;
- press `i`, `I`, `a`, `A`, `o`, and `O`; each should restore the source and enter Insert mode, then `<Esc>` and `<C-c>` should each re-render immediately;
- expand long tables and code with `<CR>` or `za`;
- resize the tmux pane and inspect wrapping;
- switch tmux windows and sessions, then confirm Mermaid images do not remain over other content;
- return to the source and confirm cursor position and buffer contents are unchanged.

### `Space m w`

- open and close the Peek webview with the same key;
- confirm focus returns to the originating terminal window while Peek remains visible, then deliberately focus Peek to confirm the rule does not pull focus back again;
- verify table wrapping, Mermaid, math, and local image paths;
- use `j`, `k`, `u`, `d`, `g`, and `G` while the preview has focus;
- switch between Neovim and `Peek preview` with existing Aerospace bindings;
- decide whether the extra OS window is acceptable.

## Installation verification

- `md-render.nvim` is pinned to `v3.8.3`; its complete upstream test suite passes locally.
- The Neovim mappings resolve to the intended controller functions. An interactive Neovim session verified reader enable, `i` switching to the source, immediate re-render after both `<Esc>` and `<C-c>`, and disable back to source.
- Peek's documented `deno task --quiet build:fast` build succeeds. A native webview smoke test launched both the preview server and `Peek preview`, then closed both cleanly through the configured controller.
- The Peek focus rule passes AeroSpace's configuration validation and is loaded. Three live launches returned focus to Ghostty; a control launch with the rule disabled left focus in Peek. Explicitly focusing the open preview still worked. The final rule also restricts the application name to `deno`.
- A standalone strict `deno check` reports upstream TypeScript errors with the installed Deno 2.8. Peek's own build and runtime deliberately use `--no-check`, so this did not block the supported path, but it is a maintenance warning to retain while evaluating the plugin.
- Visual quality, clipboard behavior, responsive layout, and real Ghostty, tmux, and Aerospace interaction still require the hands-on checks above.

## Next decisions

1. Test the event-driven `md-render.nvim` Insert transition with `<Esc>`, `<C-c>`, and the user's usual Insert exit mappings.
2. Test Peek's supported webview and decide whether Aerospace makes the separate window cheap enough to use.
3. Decide whether to install `tadmccorkle/markdown.nvim` for source-buffer Markdown links while retaining Neovim's standard `gx` convention.
4. Decide whether rendered-buffer keyboard links and native Finder reveal justify two small adapters or should first become upstream feature requests.
5. Try the local pane-width and source-anchor fixes on real documents. Decide separately whether default table expansion is still wanted.
6. If neither trial works, activate the `markdown-table-wrap.nvim`, `diagram.nvim`, and `image.nvim` fallback and repeat the tmux image-leak test.
7. Remove dependencies that no surviving implementation needs after the final choice.

## Rollback

To undo only the table profiles and split-word markers, remove `require("markdown_tables").setup(plugin.dir)` from the plugin configuration callback and restart Neovim. Keep the helper file because the other compatibility modules call its inactive hooks. This restores upstream's two-state tables without removing the pane-width, viewport, image, or diagram-source-map fixes.

To undo only the pane-width/rebuild adapter, remove the `require("markdown_view").setup(plugin.dir)` line from the `md-render.nvim` configuration callback, then restart Neovim. Retain the helper file because the reader controller also uses its `restore` function for Insert exit. This restores upstream's width cap and rebuild positioning without removing the image or source-map fixes.

To undo only native wrapping of expanded blocks, remove the guarded replacement beneath the `Expansion exposes full code lines` comment in `markdown_view.lua`, then restart Neovim. The width-cap and position fixes remain, but upstream's horizontal-scroll behavior returns.

To undo only the tmux image adapter, remove only the `require("md_render_tmux").setup(plugin.dir)` line from that callback, preserving its other setup calls, then restart Neovim. The upstream checkout has no local patch to reverse. Without the adapter, the confirmed blank-image problem in tmux returns.

To undo only Peek focus restoration, remove the `on-window-detected` block matching `deno` and `Peek preview` from `aerospace/aerospace.toml`, then run `aerospace reload-config`. Peek returns to its normal focus behavior; the Neovim plugins are unaffected.

The remaining trial is isolated to the two Lazy plugin specifications, their lockfile entries, and `nvim/lua/markdown_render.lua`. Rollback removes those exact entries and restores no unrelated files. Lazy can then clean the plugin directories. System tools such as `mmdc`, ImageMagick, Deno, Tree-sitter CLI, and `utftex` should only be removed after checking whether another workflow uses them.
