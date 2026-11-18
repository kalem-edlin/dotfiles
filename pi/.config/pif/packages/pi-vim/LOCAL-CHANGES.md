# Local changes

Vendored from `@burneikis/pi-vim` 1.7.0 (MIT) so every machine runs the same
edited copy. pif loads it from `settings.json` as `./packages/pi-vim`.

- `vim-editor.ts`: block cursor in every mode (no bar in insert).
- `modes/insert.ts`: Ctrl+[ enters visual mode; Escape still goes to normal.
- `modes/visual.ts`: `i`, `a`, `I`, `A` in visual mode jump into insert mode.
