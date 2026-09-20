# File mentions in Neovim

## Use

Restart Neovim, open any Markdown file, enter Insert mode, and type `@`.
A bordered seven-row menu appears below the cursor, or above it when space
is tight. Keep typing a fuzzy query, such as `@srchdl` for
`src/handler.lua`. The selected text becomes `@src/handler.lua`.
Directories appear with a folder icon and a trailing `/`. Accepting `src/`
inserts `@src/`; keep typing to complete a path inside it if needed.

| Key | Action |
| --- | --- |
| Tab | Accept the selected result, or the first result |
| Ctrl-n / Ctrl-p, Down / Up | Select the next / previous result |
| Enter | Accept a selected result; otherwise insert a newline |
| Ctrl-e | Dismiss the menu and keep the typed query |
| Escape | Leave Insert mode and dismiss the menu |
| Ctrl-Space | Reopen completion for the current mention |

Selection does not change the buffer until acceptance. Ordinary spaces end
an unquoted query. To search a filename containing spaces, type
`@"hello w`; acceptance inserts a balanced `@"docs/hello world.md"`.
Email addresses, escaped `\@`, and `@@` do not trigger file suggestions.

Markdown and plain-text buffers enable the source by default. This includes
unnamed buffers, which these dotfiles already mark as Markdown, and Pi's
external editor file `prompt.md`. Git commit messages, reStructuredText,
AsciiDoc, Org, and MDX are reasonable opt-ins. Enable another buffer with
`:lua vim.b.file_mentions_enabled = true`, or use `false` to disable it.
Rendered readers, terminal buffers, and other non-editable buffers are excluded.
The module does not change the separate Vim configuration.

## Search scope

For a saved file in a Git repository, completion searches that repository.
For unnamed buffers and temporary prompt files outside a repository, it
searches Neovim's current working directory, including `:lcd` and `:tcd`.
Pi inherits its project directory when launching the external editor.
A standalone document outside those cases searches its containing directory.

`:FileMentionsRoot` shows the root. `:FileMentionsRoot /path/to/project`
overrides it for this buffer; `:FileMentionsRoot!` restores automatic selection.
This also lets a prompt refer to files in a different project.

Discovery runs asynchronously through `fd`, then `fdfind` or `rg` if needed.
`fd` and `fdfind` include files and directories, including empty directories.
The `rg` fallback includes files and their parent directories; it cannot discover
empty directories or directories containing only ignored files.
Ranking uses asynchronous `fzf --filter` over that cached list. A 25 ms delay
combines rapid keystrokes; changing the query or dismissing Blink cancels
obsolete jobs. fzf never opens its own picker.
It includes hidden dotfiles, respects ignore files, and uses the same generated
folder exclusions as the existing Neovim file picker. It caches the full path
list for four seconds. `:FileMentionsRefresh` clears that cache immediately.
Filtering precedes the 150-result cap, so narrowing the query can find files
anywhere in a large project. The menu displays seven of those results at once.

Inserted paths are relative to the search root. Acceptance inserts a textual
file or directory reference. Absolute-path browsing is outside this implementation.
Paths containing control characters or double quotes are omitted because
the mention syntax cannot represent them reliably.

## Blink and Peek

Blink owns the completion window and applies the accepted text edit. Peek
continues observing the Markdown source through its normal change events.
Moving through suggestions does not edit the source or send candidate text to
the preview. Acceptance updates the source and therefore the preview.

fzf receives filenames over stdin and returns ranked filenames. It has no
terminal window and makes no buffer changes. Its query is an argument, not a
shell command. Shell-specific `FZF_DEFAULT_OPTS` and `FZF_DEFAULT_OPTS_FILE`
are cleared for this invocation so they cannot alter completion behavior.

For fzf queries containing spaces, use the quoted mention form. For example,
`@"world hello` matches both terms, and `@"README | hello` uses fzf's OR syntax.
This follows [fzf's search syntax](https://github.com/junegunn/fzf#search-syntax).
The source searches full relative paths, while Pi's provider separates a typed
directory prefix and filters within that directory, so their search scopes can
differ even though both now use fzf for ranking.

## Research and decision

This configuration had no insert-mode completion engine. It did already have
Telescope, `telescope-fzf-native.nvim`, and `fd`, but a Telescope picker moves
the user into a separate prompt. Even its cursor-relative theme is not the
cursor-anchored completion menu needed after `@` in prose.

The configuration uses [blink.cmp](https://github.com/Saghen/blink.cmp) pinned to the
current v1 line, `v1.10.2`, and the local `file_mentions` provider. Blink's
[source API](https://github.com/Saghen/blink.cmp/blob/v1.10.2/doc/development/source-boilerplate.md)
provides trigger characters, async cancellation, structured completion items,
and a cursor-anchored floating menu. Version 1 supports the repository's
Neovim 0.10 floor. Blink v2 requires Neovim 0.12 and `blink.lib`, as its
[upgrade guide](https://github.com/Saghen/blink.cmp/blob/main/UPGRADE.md)
documents.

The local provider restricts itself to ordinary prose buffers, begins only
at a valid `@` mention boundary, lists project files recursively, and ranks the
complete `@query` with fzf before limiting the results. This also matches directory
components, which Blink v1's ordinary word matching does not cover. It does
not depend on an AI plugin. That gives the same interaction in Markdown,
unnamed Markdown buffers, text files, and agent input editors.

[not-manu/filemention.nvim](https://github.com/not-manu/filemention.nvim) is
the closest ready-made plugin. It supports `@`, both Blink and nvim-cmp, a git
root with cwd fallback, hidden-file and ignore controls, and `fd`, `rg`, or
Lua file discovery. Its current implementation collects at most `max_items`
files before the completion engine fuzzy-filters them. The default is 500, so
files beyond that traversal prefix cannot be selected in a large repository.
It also falls back to Neovim's cwd for unnamed or externally located buffers,
accepts an `@` anywhere in the current non-whitespace run, and has no quoted
path grammar. Its optional `fff.nvim` mode searches an index before truncating,
but reaches into fff internals to initialize it. The project is useful
reference code, but was still small at review time, with 70 stars and its last
commit on 2026-05-30.

Two focused Blink alternatives have the same dependency on Blink but weaker
maintenance and root behavior. The original
[newtoallofthis123/blink-cmp-fuzzy-path](https://github.com/newtoallofthis123/blink-cmp-fuzzy-path)
has 11 commits, 14 stars, no release, and last changed on 2025-12-07. It
searches cwd and suggests manually setting a search directory for agent-run
Neovim. Its rewrite,
[daliusd/blink-cmp-fuzzy-path](https://github.com/daliusd/blink-cmp-fuzzy-path),
was last changed on 2026-01-21. It requires `fd`, searches cwd, caches for 30
seconds, and treats any earlier `@` on the line as active.

Native Neovim completion was also viable. `complete()` can show structured
items in the native popup menu, and
[`matchfuzzy()`](https://neovim.io/doc/user/pattern/#fuzzy-matching) can rank a
cached file list. Its automatic fuzzy completion arrived in Neovim 0.11,
however, while this repository supports 0.10. A correct 0.10 implementation
would need to own the cache, asynchronous refresh, filtering, cancellation,
and insert-mode mapping lifecycle. Blink handles menu placement, selection,
acceptance, and completion request lifetimes. The provider still owns the file
cache and fzf requests.

Primary references: [Neovim insert-mode completion](https://neovim.io/doc/user/insert/#complete-functions),
[Neovim popup-menu anchoring](https://neovim.io/doc/user/api-ui-events/#ui-popupmenu),
and [Telescope themes](https://github.com/nvim-telescope/telescope.nvim#themes).

## Validation

Run from the dotfiles root:

```sh
nvim --headless -u NONE -l nvim/tests/file_mentions.lua
~/.local/share/nvim/pynvim-venv/bin/python nvim/tests/file_mentions_ui.py
# In a desktop session, also exercise Peek's real Deno/webview process:
~/.local/share/nvim/pynvim-venv/bin/python nvim/tests/file_mentions_ui.py --peek
```

The Lua suite covers token boundaries, quoted paths, roots, scanner arguments,
cache expiry, cancellation across projects, exact agreement with fzf ranking,
and rejection of late results from cancelled fzf jobs. The Python suite attaches a
real Neovim UI and uses the installed Blink with this repository's configuration.
It checks immediate `@` completion, typing and backspacing, keyboard acceptance
and cancellation, ignored and hidden files, Unicode edits, existing closing
quotes, wrapped lines, temporary prompts, and searching beyond 500 files.
It also checks Peek's change listeners during selection and acceptance. The
default run replaces Peek's app transport for headless use; `--peek` launches
the actual preview process and checks that it closes after the test.
`setup/neovim.sh` installs the Python environment used by that suite.

On the local machine, 20 ranking requests over a synthetic 10,000-file cache
measured 40.5 ms median and 42.9 ms at the 95th percentile, including the
25 ms typing delay. This measures ranking, not initial filesystem discovery.

Blink is pinned to v1.10.2 in both the Lazy specification and lockfile.
Its Lua mode avoids a Rust binary download or compiler requirement. The provider
preserves fzf order and prevents Blink's secondary word filter from discarding
fzf's extended-search matches.
