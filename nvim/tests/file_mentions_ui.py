"""Exercise real insert input, Blink windows, and Peek using the dotfiles.

Run with the pynvim Python installed by setup/neovim.sh:
  ~/.local/share/nvim/pynvim-venv/bin/python nvim/tests/file_mentions_ui.py

Pass --peek from a desktop session to start Peek's real webview. The default
uses Peek's real Lua lifecycle with its Deno app boundary replaced, so this
suite remains safe in headless CI.
"""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time

import pynvim


REPO = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--peek", action="store_true", help="launch Peek's real webview")
    args = parser.parse_args()
    real_peek = args.peek
    # A test editor must never overwrite the real tmux pane's restore state.
    os.environ.pop("TMUX_PANE", None)
    with tempfile.TemporaryDirectory(prefix="nvim-mentions-ui-") as directory:
        root = Path(directory)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        for name in ["README.md", "src/handler.lua", "docs/hello world.md", ".config/tool.json",
                     "node_modules/noise.js", "dist/noise.js", ".DS_Store", "ignored.md"]:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n")
        (root / ".gitignore").write_text("ignored.md\n")
        (root / "empty").mkdir()
        (root / "folder with spaces").mkdir()
        nvim = pynvim.attach("child", argv=[
            "nvim", "--embed", "--headless", "-i", "NONE",
            "--cmd", f"set rtp^={REPO / 'nvim'}",
            "-u", str(REPO / "nvim/init.lua"),
        ])
        try:
            nvim.ui_attach(90, 28, rgb=True)
            nvim.command("cd " + nvim.funcs.fnameescape(str(root)))
            nvim.command("set noswapfile")

            def lua(code, *args):
                return nvim.exec_lua(code, *args)

            def wait_for(predicate, label, timeout=3):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    time.sleep(0.02)
                raise AssertionError(f"Timed out: {label}; line={nvim.current.line!r}; "
                                     f"messages={nvim.command_output('messages')}")

            def visible():
                return lua("return package.loaded['blink.cmp'] ~= nil and require('blink.cmp').is_visible()")

            def labels():
                return lua("return vim.tbl_map(function(x) return x.label end, "
                           "require('blink.cmp').get_items())")

            def source_ids():
                return lua("return vim.fn.sort(vim.fn.uniq(vim.tbl_map(function(x) "
                           "return x.source_id end, require('blink.cmp').get_items())))")

            # Peek's public API owns the buffer-change listeners. In the normal
            # headless run we retain that real Lua lifecycle while replacing only
            # its Deno transport. --peek keeps the transport and starts webview.
            lua("""
              local peek = require('peek')
              local app = require('peek.app')
              _G.file_mentions_peek_probe = { shows = {}, stops = 0, actual = ... }
              if ... then
                local init = app.init
                local stop = app.stop
                app.init = function(on_exit)
                  init(on_exit)
                  local show = app.show
                  app.show = function(content)
                    table.insert(_G.file_mentions_peek_probe.shows, content)
                    return show(content)
                  end
                  for index = 1, 16 do
                    local name, value = debug.getupvalue(stop, index)
                    if name == 'channel' then
                      _G.file_mentions_peek_probe.job_id = value
                      break
                    end
                  end
                end
                app.stop = function()
                  _G.file_mentions_peek_probe.stops = _G.file_mentions_peek_probe.stops + 1
                  return stop()
                end
              else
                app.init = function(on_exit)
                  _G.file_mentions_peek_probe.on_exit = on_exit
                  app.show = function(content)
                    table.insert(_G.file_mentions_peek_probe.shows, content)
                  end
                  app.base = function() end
                  app.scroll = function() end
                end
                app.stop = function()
                  _G.file_mentions_peek_probe.stops = _G.file_mentions_peek_probe.stops + 1
                  if _G.file_mentions_peek_probe.on_exit then
                    _G.file_mentions_peek_probe.on_exit()
                  end
                end
              end
              peek.setup({ auto_load = true, close_on_bdelete = true, update_on_change = true,
                app = 'webview', syntax = true, theme = 'dark' })
            """, real_peek)

            def peek_shows():
                return lua("return vim.deepcopy(_G.file_mentions_peek_probe.shows)")

            def peek_job_id():
                return lua("return _G.file_mentions_peek_probe.job_id")

            def peek_webview_pids():
                output = subprocess.run(
                    ["ps", "-ax", "-o", "pid=,command="], check=True,
                    capture_output=True, text=True,
                ).stdout.splitlines()
                return {
                    line.strip().split(maxsplit=1)[0]
                    for line in output
                    if "webview.js" in line
                }

            def reset(line="", col=None, ft="markdown"):
                nvim.input("<Esc>")
                wait_for(lambda: nvim.funcs.mode() == "n", "normal mode")
                nvim.current.buffer[:] = [line]
                nvim.current.buffer.options["filetype"] = ft
                nvim.current.window.cursor = (1, len(line.encode()) if col is None else col)
                nvim.input("A" if col is None else "i")
                wait_for(lambda: nvim.funcs.mode() == "i", "insert mode")

            reset("Inspect ")
            nvim.input("@")
            wait_for(visible, "bare @ opens popup")
            assert nvim.current.line == "Inspect @", "menu must not insert a candidate"
            assert "src/handler.lua" in labels(), labels()
            assert ".config/tool.json" in labels(), "hidden dotfiles should be offered"
            assert all(path in labels() for path in ["src/", ".config/", "empty/", "folder with spaces/"]), labels()
            assert not any(name in labels() for name in [
                "node_modules/", "dist/", ".git/", "node_modules/noise.js", "dist/noise.js", ".DS_Store", "ignored.md",
            ]), labels()
            menu_config = lua("return vim.api.nvim_win_get_config("
                              "require('blink.cmp.completion.windows.menu').win:get_win())")
            assert menu_config["relative"] != "", menu_config
            assert menu_config["row"] > 0, "menu should open below the first line"
            nvim.input("srchdl")
            wait_for(lambda: labels() == ["src/handler.lua"], "recursive fuzzy filtering")
            nvim.input("<Tab>")
            wait_for(lambda: "@src/handler.lua" in nvim.current.line, "Tab accepts first match")
            assert not visible()

            reset("Inspect ")
            nvim.input("@src")
            wait_for(lambda: visible() and labels()[0] == "src/", "directory ranks first")
            nvim.input("<Tab>")
            wait_for(lambda: nvim.current.line == "Inspect @src/", "Tab accepts directory")
            assert not visible()
            nvim.input("hdl")
            wait_for(lambda: visible() and labels() == ["src/handler.lua"], "continue inside directory")
            nvim.input("<Tab>")
            wait_for(lambda: nvim.current.line == "Inspect @src/handler.lua", "accept file inside directory")

            reset("Inspect ")
            nvim.input("@empty")
            wait_for(lambda: visible() and labels() == ["empty/"], "empty directory popup")
            nvim.input("<C-n>")
            wait_for(lambda: lua("local item = require('blink.cmp').get_selected_item(); "
                                 "return item ~= nil and item.label == 'empty/'"), "directory selected")
            nvim.input("<CR>")
            wait_for(lambda: nvim.current.line == "Inspect @empty/", "Enter accepts directory")

            reset('See @"" next', len('See @"'.encode()))
            nvim.input("folder with")
            wait_for(lambda: visible() and labels() == ["folder with spaces/"], "quoted directory popup")
            nvim.input("<Tab>")
            wait_for(lambda: nvim.current.line == 'See @"folder with spaces/" next', "quoted directory acceptance")

            reset("See ")
            nvim.input("@README")
            wait_for(visible, "second mention")
            nvim.input("<C-n>")
            time.sleep(0.05)
            assert nvim.current.line == "See @README", "selection must not edit prose"
            nvim.input("<CR>")
            wait_for(lambda: "@README.md" in nvim.current.line, "Enter accepts selection")
            assert len(nvim.current.buffer) == 1

            reset("See ")
            nvim.input("@")
            wait_for(visible, "cancel test")
            nvim.input("<C-e>")
            wait_for(lambda: not visible(), "Ctrl-e dismisses")
            assert nvim.current.line == "See @"

            reset("See ")
            nvim.input("@")
            wait_for(visible, "Enter with no selection")
            nvim.input("<CR>")
            wait_for(lambda: len(nvim.current.buffer) == 2, "Enter inserts newline")

            for text in ["user@example", r"\@README", "@@README", "ordinary prose"]:
                reset()
                nvim.input(text)
                time.sleep(0.15)
                assert not visible(), f"unexpected popup for {text!r}"

            reset("Unicode café ☕  remains", len("Unicode café ☕ ".encode()))
            nvim.input("@srchdl")
            wait_for(visible, "Unicode prefix mention")
            nvim.input("<Tab>")
            wait_for(lambda: "@src/handler.lua" in nvim.current.line, "Unicode insertion")
            assert nvim.current.line == "Unicode café ☕ @src/handler.lua remains", nvim.current.line

            reset()
            nvim.input('@"hello w')
            wait_for(lambda: visible() and labels() == ["docs/hello world.md"], "quoted query")
            nvim.input("<Tab>")
            wait_for(lambda: '@"docs/hello world.md"' in nvim.current.line, "quoted insertion")

            reset('See @"" next', len('See @"'.encode()))
            nvim.input("hello w")
            wait_for(visible, "query before an existing closing quote")
            nvim.input("<Tab>")
            wait_for(lambda: "docs/hello world.md" in nvim.current.line, "existing quote insertion")
            assert nvim.current.line == 'See @"docs/hello world.md" next', nvim.current.line

            # fzf extended mode treats whitespace-separated terms as an AND
            # query. Blink must retain the provider's result even though its
            # own keyword extraction sees only the final word.
            reset()
            nvim.input('@"world hello')
            wait_for(lambda: visible() and labels() == ["docs/hello world.md"],
                     "reverse-order fzf extended query")
            assert source_ids() == ["file_mentions"], source_ids()

            # A completion selection changes Blink state only. It must not
            # alter the Markdown buffer or send a false preview update to Peek.
            reset("Preview ")
            nvim.input("@README")
            wait_for(visible, "Peek selection popup")
            assert source_ids() == ["file_mentions"], source_ids()
            webviews_before = peek_webview_pids() if real_peek else set()
            lua("require('peek').open()")
            wait_for(lambda: lua("return require('peek').is_open()"), "Peek opens")
            wait_for(lambda: peek_shows() and peek_shows()[-1] == "Preview @README",
                     "Peek receives initial prose")
            if real_peek:
                job_id = peek_job_id()
                assert job_id and job_id > 0, "Peek did not retain its Deno job id"
                assert lua("return vim.fn.jobpid(...) > 0", job_id), "Peek did not start a Deno process"
                time.sleep(0.50)
                assert lua("return vim.fn.jobwait({...}, 0)[1] == -1", job_id), \
                    "Peek Deno job exited before its webview could start"
                assert "Peek error:" not in nvim.command_output("messages"), "Peek reported a startup error"
                wait_for(lambda: bool(peek_webview_pids() - webviews_before),
                         "Peek starts its actual webview", timeout=15)
            shows_before_selection = len(peek_shows())
            nvim.input("<C-n>")
            time.sleep(0.10)
            assert nvim.current.line == "Preview @README", "selection must not edit the preview buffer"
            assert len(peek_shows()) == shows_before_selection, "selection must not redraw Peek"
            nvim.input("<Tab>")
            wait_for(lambda: nvim.current.line == "Preview @README.md", "accepts the selected file")
            wait_for(lambda: peek_shows() and peek_shows()[-1] == "Preview @README.md",
                     "Peek receives accepted mention")
            lua("require('peek').close()")
            wait_for(lambda: not lua("return require('peek').is_open()"), "Peek closes")
            assert lua("return _G.file_mentions_peek_probe.stops") == 1
            if real_peek:
                wait_for(lambda: lua("return vim.fn.jobwait({...}, 0)[1] ~= -1", job_id),
                         "Peek Deno job exits")
                wait_for(lambda: not (peek_webview_pids() - webviews_before),
                         "Peek leaves no webview child")

            reset("See ")
            nvim.input("@README")
            wait_for(visible, "query before deleting")
            nvim.input("<BS><BS><BS><BS><BS><BS>")
            wait_for(lambda: "src/handler.lua" in labels(), "backspace broadens the list")
            nvim.input(" ")
            wait_for(lambda: not visible(), "space ends an unquoted mention")

            # The provider debounces ranking. A cancelled request must not let
            # an old fzf result reopen Blink or insert text after Esc.
            reset("Rapid ")
            nvim.input("@zz_unique_needle<BS><BS><BS><Esc>")
            wait_for(lambda: nvim.funcs.mode() == "n", "Esc cancels rapid request")
            rapid_line = nvim.current.line
            time.sleep(0.20)
            assert nvim.current.line == rapid_line, "stale completion edited prose after Esc"
            assert not visible(), "stale completion reopened Blink after Esc"

            # Force both wrapping and the above-cursor fallback in a small UI.
            nvim.ui_try_resize(48, 12)
            reset("A long wrapped prose line. " * 6)
            nvim.input("@srchdl")
            wait_for(visible, "wrapped line popup")
            assert labels() == ["src/handler.lua"], labels()
            assert nvim.current.line.endswith("@srchdl")
            nvim.input("<Esc>")
            wait_for(lambda: not visible(), "Escape exits popup")
            nvim.ui_try_resize(90, 28)

            reset(ft="lua")
            nvim.input("@README")
            time.sleep(0.15)
            assert not visible(), "code buffers must remain unaffected"

            # The real external-editor shape: file outside the project, cwd inside.
            nvim.input("<Esc>")
            external = root.parent / (root.name + "-prompt.md")
            nvim.command("enew!")
            nvim.command("file " + nvim.funcs.fnameescape(str(external)))
            reset()
            nvim.input("@srchdl")
            wait_for(visible, "temporary prompt uses project cwd")
            assert labels() == ["src/handler.lua"], labels()
            # A matching file after hundreds of unrelated paths must remain
            # searchable. This catches pre-filter truncation in a real scanner.
            bulk = root / "bulk"
            bulk.mkdir()
            for index in range(650):
                (bulk / f"entry{index:04d}.txt").touch()
            (bulk / "zz_unique_needle.txt").touch()
            nvim.input("<Esc>")
            nvim.command("FileMentionsRefresh")
            reset()
            nvim.input("@zzuniqndl")
            wait_for(lambda: visible() and labels() == ["bulk/zz_unique_needle.txt"],
                     "matches beyond the first 500 files")
            print("PASS: Blink popup, fzf ranking, typing, acceptance, cancellation, Peek, "
                  "Unicode, quoted paths, filetypes, external prompt, full file list")
        finally:
            try:
                nvim.command("qa!")
            except (EOFError, OSError):
                pass
            nvim.close()


if __name__ == "__main__":
    main()
