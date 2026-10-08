"""Real Neovim -> tmux -> attached PTY test. No desktop UI or user panes.

Run from the dotfiles root: python3 nvim/tests/md_render_tmux_integration.py
Requires the installed md-render.nvim plugin and the user's Neovim config.
"""
import fcntl
import json
import os
import pathlib
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

with tempfile.TemporaryDirectory(prefix="md-render-tmux-") as directory:
    socket = directory + "/tmux.sock"
    nvim_socket = directory + "/nvim.sock"
    env = dict(os.environ, TERM="xterm-256color", TERM_PROGRAM="ghostty")
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)

    def tmux(*args):
        return subprocess.check_output(["tmux", "-S", socket, *args], env=env).decode().strip()

    def lua(code):
        # A Vim single-quoted string escapes quotes by doubling them.
        expression = "luaeval('" + code.replace("'", "''") + "')"
        return subprocess.check_output(["nvim", "--server", nvim_socket, "--remote-expr", expression]).decode()

    tmux("-f", "/dev/null", "new-session", "-d", "-s", "test", "sleep", "120")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 960, 640))
    tmux("set-option", "-g", "focus-events", "on")
    tmux("set-option", "-g", "allow-passthrough", "on")
    tmux("set-option", "-g", "status-position", "top")
    client = subprocess.Popen(["tmux", "-S", socket, "attach-session", "-t", "test"],
                              stdin=slave, stdout=slave, stderr=slave, env=env)

    def capture(seconds):
        data = b""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if select.select([master], [], [], max(0, end - time.monotonic()))[0]:
                data += os.read(master, 65536)
        return data

    try:
        capture(0.3)
        pane = tmux("split-window", "-h", "-P", "-F", "#{pane_id}", "-t", "test",
                    "nvim", "--listen", nvim_socket, directory + "/test.md")
        deadline = time.monotonic() + 8
        while not pathlib.Path(nvim_socket).exists():
            capture(0.1)
            assert time.monotonic() < deadline, "Neovim did not start"
        capture(1)
        lua('vim.api.nvim_buf_set_lines(0,0,-1,false,{"# Image test", "",'
            '"![PNG]("..vim.fn.stdpath("data").."/lazy/md-render.nvim/assets/demo/test.png)",'
            '"", "```mermaid", "graph LR; Start-->Finish", "```", "",'
            '"A **bold** word and a [label](./file.md)."})')
        lua('require("markdown_render").toggle_reader()')
        data = capture(5)
        assert b"\x1b_Ga=T" in data, "no graphics display reached the terminal"
        assert b"\x1bPtmux;" not in data, "tmux did not unwrap graphics"
        import re
        ids = set(re.findall(rb"\x1b_Ga=T[^;]*,i=(\d+)", data))
        assert len(ids) >= 2, "PNG and Mermaid did not both display"
        left = int(tmux("display-message", "-p", "-t", pane, "#{pane_left}"))
        positions = re.findall(rb"\x1b\[(\d+);(\d+)H\x1b_Ga=T", data)
        assert positions and all(int(col) > left and int(row) > 1 for row, col in positions), "wrong split/status offsets"
        assert lua('vim.b.md_render') == "true", "reader not active"
        tmux("new-window", "-t", "test", "-n", "other", "sleep", "120")
        lost = capture(0.8)
        assert b"\x1b_Ga=d,d=i" in lost, "window switch did not clear images"
        lua('vim.api.nvim_exec_autocmds("User",{pattern="MdRenderRepaint",data={source="test"}})')
        assert b"\x1b_Ga=T" not in capture(0.5), "inactive window repainted images"
        tmux("select-window", "-t", "test:0")
        assert b"\x1b_Ga=T" in capture(1), "return to reader did not restore images"
        tmux("new-session", "-d", "-s", "other-session", "sleep", "120")
        tmux("switch-client", "-t", "other-session")
        assert b"\x1b_Ga=d,d=i" in capture(0.8), "session switch did not clear images"
        tmux("switch-client", "-t", "test")
        assert b"\x1b_Ga=T" in capture(1), "session return did not restore images"
        # Exercise the actual Insert and Visual-yank mappings after a diagram,
        # where upstream's stale source-map entries caused document jumps.
        lua('vim.api.nvim_set_option_value("clipboard", "", {})')
        def cursor_on(text):
            lua('(function() for row,line in ipairs(vim.api.nvim_buf_get_lines(0,0,-1,false)) do '
                'local col=line:find("' + text + '",1,true); if col then '
                'vim.api.nvim_win_set_cursor(0,{row,col-1}); return end end error("missing text") end)()')
        cursor_on("bold")
        tmux("send-keys", "-t", pane, "i")
        capture(0.3)
        assert lua('vim.fn.mode()') == "i", "Insert key did not enter source Insert mode"
        assert lua('vim.json.encode(vim.api.nvim_win_get_cursor(0))') == "[9,4]", "Insert jumped from selected source text"
        tmux("send-keys", "-t", pane, "Escape")
        capture(0.4)
        assert lua('vim.b.md_render') == "true", "Insert exit did not return to rendering"
        cursor_on("bold")
        tmux("send-keys", "-l", "-t", pane, "v3ly")
        capture(0.3)
        assert lua('vim.fn.getreg("0")') == "**bold**", "Visual yank lost Markdown markers"
        cursor_on("label")
        tmux("send-keys", "-l", "-t", pane, 'v4l"ay')
        capture(0.3)
        assert lua('vim.fn.getreg("a")') == "[label](./file.md)", "named-register yank lost link destination"
        assert lua('vim.b.md_render') == "true", "yanking left the reader"
        lua('require("markdown_render").toggle_reader()')
        assert b"\x1b_Ga=d" in capture(0.5), "toggle off did not clean up"
        lua('(function() local lines={} for i=1,40 do lines[#lines+1]="Before paragraph "..i; lines[#lines+1]="" end '
            'lines[#lines+1]="| Column | Description |"; lines[#lines+1]="| --- | --- |"; '
            'lines[#lines+1]="| CELL | "..string.rep("widecell ",30).." |"; lines[#lines+1]=""; '
            'lines[#lines+1]=string.rep("wrapped prose ",12).."ANCHOR keeps its screen row."; lines[#lines+1]=""; '
            'for i=1,40 do lines[#lines+1]="After paragraph "..i; lines[#lines+1]="" end '
            'vim.api.nvim_buf_set_lines(0,0,-1,false,lines) end)()')
        lua('require("markdown_render").toggle_reader()')
        capture(0.3)
        for exit_key in ("Escape", "C-c"):
            cursor_on("ANCHOR")
            lua('(function() local p=vim.api.nvim_win_get_cursor(0); p[2]=p[2]+3; vim.api.nvim_win_set_cursor(0,p) end)()')
            lua('vim.fn.winrestview({topline=vim.api.nvim_win_get_cursor(0)[1]-10})')
            capture(0.2)
            tmux("send-keys", "-t", pane, "i")
            capture(0.3)
            # Deliberately place the Insert cursor off-center. Rendering must
            # keep this screen row, including the source line's soft wrapping.
            screen_row = lua('vim.fn.winline()')
            tmux("send-keys", "-t", pane, exit_key)
            capture(0.4)
            assert lua('vim.b.md_render') == "true"
            assert lua('vim.fn.winline()') == screen_row, "Insert exit recentered the cursor"
            assert "ANCHOR" in lua('vim.api.nvim_get_current_line()'), "return lost wrapped source location"
        def reader_position():
            return json.loads(lua('(function() local s=require("markdown_source").session(); '
                'local p=vim.api.nvim_win_get_cursor(0); return vim.json.encode({'
                'source=require("markdown_source").position(s,p[1],p[2]), '
                'row=vim.fn.winline(), width=s.opts.max_width, view=vim.fn.winsaveview(), '
                'cached=s._view_anchors[vim.api.nvim_get_current_win()], '
                'usable=vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].width-'
                'vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff}) end)()'))

        before = reader_position()
        for width in (100, 45, 110, 60, 90):
            tmux("resize-pane", "-t", pane, "-x", str(width))
            capture(0.6)
            after = reader_position()
            assert after["width"] == after["usable"], f"reader width still capped: {after}"
            assert after["source"] == before["source"], f"resize changed source character: {before} -> {after}"
            assert after["row"] == before["row"], f"resize changed cursor screen row: {before} -> {after}"
        assert after["width"] > 80, "test never exceeded old width cap"
        for width in (105, 40, 90):
            tmux("resize-pane", "-t", pane, "-x", str(width))
            capture(0.025)
        capture(0.6)
        after = reader_position()
        assert after["source"] == before["source"], "rapid resize lost source anchor"
        assert after["row"] == before["row"], "rapid resize scrolled the cursor"
        # Table expansion above the cursor changes the generated row numbers.
        for expanded in ("true", "false", "true"):
            lua('(function() local s=require("markdown_source").session(); '
                'local region=assert(s.content.expandable_regions[1]); '
                's.expand_state[region.block_id]=' + expanded + '; s:rebuild() end)()')
            capture(0.3)
            after = reader_position()
            assert after["source"] == before["source"], "table expansion moved source anchor"
            assert after["row"] == before["row"], "table expansion scrolled the cursor"
        table_width = int(lua('(function() local s=require("markdown_source").session(); '
            'local r=s.content.expandable_regions[1]; local width=0; '
            'for i=r.start_line+1,r.end_line+1 do '
            'width=math.max(width,vim.fn.strdisplaywidth(s.content.lines[i])) end return width end)()'))
        assert 80 < table_width <= after["usable"], f"expanded table did not use available width: {table_width}"
        # Source edits before the anchor must move its extmark, not leave an
        # obsolete source line number behind for the next live rebuild.
        lua('(function() local s=require("markdown_source").session(); '
            'vim.api.nvim_buf_set_lines(s.source_bufnr,0,0,false,{"Inserted above", ""}); '
            'vim.api.nvim_exec_autocmds("TextChanged",{buffer=s.source_bufnr}) end)()')
        capture(0.6)
        after = reader_position()
        assert after["source"] == [before["source"][0] + 2, before["source"][1]], "source edit lost anchor"
        assert after["row"] == before["row"], "source edit scrolled the cursor"
        before = after
        tmux("resize-window", "-t", "test:0", "-y", "32")
        capture(0.6)
        after = reader_position()
        assert after["source"] == before["source"], "height resize lost anchor"
        assert after["row"] == before["row"], "height resize scrolled the cursor"
        lua('(function() local s=require("markdown_source").session(); '
            's.expand_state[s.content.expandable_regions[1].block_id]=true; s:rebuild() end)()')
        capture(0.3)
        cursor_on("CELL")
        lua('vim.fn.winrestview({topline=vim.api.nvim_win_get_cursor(0)[1]-10})')
        capture(0.2)
        before = reader_position()
        for width in (45, 105):
            tmux("resize-pane", "-t", pane, "-x", str(width))
            capture(0.6)
            after = reader_position()
            assert after["source"] == before["source"], "resize lost cursor inside table cell"
            assert after["row"] == before["row"], "resize scrolled cursor inside table cell"
        # Exercise the real table keys, with repeated values in different
        # columns and a source character that compact mode hides completely.
        lua('require("markdown_render").toggle_reader()')
        lua('(function() local lines={} for i=1,30 do lines[#lines+1]="Before "..i; lines[#lines+1]="" end '
            'lines[#lines+1]="| Criterion | One | Two | Three |"; lines[#lines+1]="| --- | --- | --- | --- |"; '
            'lines[#lines+1]="| Q | yes | "..string.rep("long description ",15).." | yes |"; '
            'lines[#lines+1]="| SPLIT | abcdefghijklmnopqrstuvwxyz | [link](./test.md) | yes |"; '
            'lines[#lines+1]=""; lines[#lines+1]="| Other | Table |"; lines[#lines+1]="| --- | --- |"; '
            'lines[#lines+1]="| no | no |"; lines[#lines+1]=""; '
            'lines[#lines+1]="```lua"; lines[#lines+1]=string.rep("print(1); ",30); lines[#lines+1]="```"; '
            'for i=1,30 do lines[#lines+1]="After "..i; lines[#lines+1]="" end '
            'vim.api.nvim_buf_set_lines(0,0,-1,false,lines) end)()')
        lua('require("markdown_render").toggle_reader()')
        capture(0.3)

        def table_profile(index=1):
            return lua('(function() local s=require("markdown_source").session(); local r=s.content.expandable_regions['
                + str(index) + ']; return s.expand_state[r.block_id] or "compact" end)()')

        cursor_on("Q")
        lua('vim.fn.winrestview({topline=vim.api.nvim_win_get_cursor(0)[1]-10})')
        capture(0.2)
        before = reader_position()
        for key, expected in (("Enter", "equal"), ("za", "proportional"), ("Enter", "compact"), ("za", "equal")):
            tmux("send-keys", "-t", pane, key)
            capture(0.3)
            after = reader_position()
            assert table_profile() == expected, f"{key} did not cycle to {expected}"
            assert table_profile(2) == "compact", "cycling changed another table"
            assert after["source"] == before["source"], f"{expected} lost source position"
            assert after["row"] == before["row"], f"{expected} scrolled cursor"

        # Last character of an oversized cell stays logically anchored even
        # while compact mode can only show an earlier part of that cell.
        lua('(function() local s=require("markdown_source").session(); local raw=s.source_lines[64]; '
            'local col=raw:find("abcdefghijklmnopqrstuvwxyz",1,true)+24; '
            'vim.api.nvim_win_set_cursor(0,require("markdown_source").render_position(s,64,col)) end)()')
        lua('vim.fn.winrestview({topline=vim.api.nvim_win_get_cursor(0)[1]-10})')
        capture(0.2)
        before = reader_position()
        for expected in ("proportional", "compact", "equal"):
            tmux("send-keys", "-t", pane, "Enter")
            capture(0.3)
            after = reader_position()
            assert table_profile() == expected
            assert after["row"] == before["row"], f"hidden-cell cycle scrolled in {expected}"
            if expected != "compact":
                assert after["source"] == before["source"], f"hidden-cell cycle lost character in {expected}"
        # Leaving the table for another block must retain ordinary two-state
        # code expansion and preserve the first table's profile.
        cursor_on("print")
        tmux("send-keys", "-t", pane, "Enter")
        capture(0.3)
        assert table_profile(3) == "true", "code block did not expand normally"
        assert lua('vim.wo.wrap') == "true", "code expansion disabled wrapping"
        assert int(lua('(function() local row=vim.api.nvim_win_get_cursor(0)[1]-1; '
            'return vim.api.nvim_win_text_height(0,{start_row=row,end_row=row}).all end)()')) > 1, "expanded code stayed on one screen row"
        tmux("send-keys", "-t", pane, "za")
        capture(0.3)
        assert table_profile(3) == "compact", "code block did not compact normally"
        assert table_profile() == "equal"
        lua('require("markdown_render").toggle_reader()')
        lua('(function() local lines={} for i=1,30 do lines[#lines+1]="Before "..i; lines[#lines+1]="" end '
            'lines[#lines+1]="```"; '
            'lines[#lines+1]="Template -> Draft: apps/expo/src/utils/template2draft.ts "..string.rep("device only ",12).."VISIBLE_TAIL"; '
            'lines[#lines+1]="```"; lines[#lines+1]=""; '
            'lines[#lines+1]="> ```text"; '
            'lines[#lines+1]="> Snapshot: "..string.rep("persistDraft ",12).."QUOTE_TAIL"; '
            'lines[#lines+1]="> ```"; lines[#lines+1]=""; '
            'for i=1,30 do lines[#lines+1]="After "..i; lines[#lines+1]="" end '
            'vim.api.nvim_buf_set_lines(0,0,-1,false,lines) end)()')
        lua('require("markdown_render").toggle_reader()')
        capture(0.3)
        # This fixture replaces the entire source buffer. Do not inherit the
        # earlier table's source-line-keyed expansion state at the same row.
        lua('(function() local s=require("markdown_source").session(); s.expand_state={}; s:rebuild() end)()')
        capture(0.2)
        for text, tail in (("Template", "VISIBLE_TAIL"), ("Snapshot", "QUOTE_TAIL")):
            cursor_on(text)
            lua('vim.fn.winrestview({topline=vim.api.nvim_win_get_cursor(0)[1]-7})')
            capture(0.2)
            before = reader_position()
            assert "…" in lua('vim.api.nvim_get_current_line()'), "fixture did not start compact"
            tmux("send-keys", "-t", pane, "Enter")
            capture(0.3)
            assert lua('vim.wo.wrap') == "true", "expanded fence disables wrap"
            assert tail in lua('vim.api.nvim_get_current_line()'), "expanded fence lost its tail"
            for width in (65, 110, 80):
                tmux("resize-pane", "-t", pane, "-x", str(width))
                capture(0.6)
                after = reader_position()
                assert after["source"] == before["source"], "expanded fence resize moved cursor"
                assert after["row"] == before["row"], "expanded fence resize scrolled cursor"
                position = json.loads(lua('(function() local row=vim.api.nvim_win_get_cursor(0)[1]; '
                    'local col=vim.api.nvim_get_current_line():find("' + tail + '",1,true); '
                    'return vim.json.encode(vim.fn.screenpos(0,row,col)) end)()'))
                assert position["row"] > 0 and position["col"] > 0, "expanded tail is off-screen"
                assert lua('vim.fn.winsaveview().leftcol') == "0", "expanded fence scrolls horizontally"
                # Check what the real tmux terminal grid contains, not just
                # the logical buffer text or the value of the wrap option.
                grid = tmux("capture-pane", "-p", "-t", pane)
                assert tail in grid, "expanded tail did not reach the visible terminal grid"
            tmux("send-keys", "-t", pane, "za")
            capture(0.3)
            assert "…" in lua('vim.api.nvim_get_current_line()'), "fence no longer compacts"
        print("PASS: images; raw yanks; viewport; table profiles; expanded fences wrap visibly across pane resizes")
    finally:
        tmux("kill-server")
        capture(0.1)
        try:
            client.wait(timeout=3)
        except subprocess.TimeoutExpired:
            client.terminate()
            client.wait(timeout=3)
        os.close(slave)
        os.close(master)
