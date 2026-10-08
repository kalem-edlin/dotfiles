"""Isolated real-Neovim regression for workspace session generations."""

import atexit, hashlib, json, os, pathlib, subprocess, tempfile, time

REPO=pathlib.Path(__file__).resolve().parents[2]

with tempfile.TemporaryDirectory(prefix="nvim-workspace-resurrect-") as directory:
    root=pathlib.Path(directory); state=root/"state"; state.mkdir(); source=root/"named.md"
    source.write_text("old disk\n")
    socket="workspace-nvim-test-"+str(os.getpid())
    init=root/"init.lua"
    init.write_text(f'vim.opt.rtp:prepend({json.dumps(str(REPO / "nvim"))})\nrequire("tmux_workspace_resurrect").setup()\n')
    env=dict(os.environ, XDG_STATE_HOME=str(state), XDG_DATA_HOME=str(root/"data"), XDG_CONFIG_HOME=str(root/"config"))
    env.pop("NVIM",None); env.pop("TMUX",None); env.pop("TMUX_PANE",None)

    def tmux(*args): return subprocess.check_output(["tmux","-L",socket,*args],env=env,text=True).strip()
    def cleanup_tmux():
        subprocess.run(["tmux","-L",socket,"kill-server"],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    atexit.register(cleanup_tmux)
    def wait_server(path):
        end=time.time()+8
        while time.time()<end:
            if pathlib.Path(path).exists(): return
            time.sleep(.05)
        raise AssertionError("Neovim server did not appear")
    def expr(server, expression):
        return subprocess.check_output(["nvim","--server",server,"--remote-expr",expression],env=env,text=True).strip()

    server1=str(root/"one.sock")
    tmux("-f","/dev/null","new-session","-d","-s","test",f"nvim --listen {server1} -u {init} {source}")
    wait_server(server1); time.sleep(.3)
    expr(server1, 'luaeval("vim.api.nvim_buf_set_lines(0,0,-1,false,{\\\"latest named\\\",\\\"unsaved\\\"})")')
    expr(server1, 'luaeval("(function() for _,text in ipairs({\\\"unnamed one\\\",\\\"unnamed two\\\"}) do local b=vim.api.nvim_create_buf(true,false); vim.api.nvim_buf_set_lines(b,0,-1,false,{text}); vim.cmd(\\\"split\\\"); vim.api.nvim_win_set_buf(0,b) end return true end)()")')
    expr(server1,'luaeval("require(\\\"tmux_workspace_resurrect\\\").save()")')
    session=tmux("show-option","-pt","test:0.0","-qv","@workspace-nvim-session")
    end=time.time()+3
    while time.time()<end and not pathlib.Path(session).is_file(): time.sleep(.05)
    assert pathlib.Path(session).is_file()
    before_reload=expr(server1,'luaeval("vim.json.encode(vim.tbl_map(function(w) local b=vim.api.nvim_win_get_buf(w); return {lines=vim.api.nvim_buf_get_lines(b,0,-1,false),modified=vim.bo[b].modified} end,vim.api.nvim_tabpage_list_wins(0)))")')
    expr(server1,'luaeval("(function() package.loaded[\\\"tmux_workspace_resurrect\\\"]=nil; require(\\\"tmux_workspace_resurrect\\\").setup(); return true end)()")')
    time.sleep(.2)
    assert tmux("show-option","-pt","test:0.0","-qv","@workspace-nvim-session")==session
    assert expr(server1,'luaeval("vim.json.encode(vim.tbl_map(function(w) local b=vim.api.nvim_win_get_buf(w); return {lines=vim.api.nvim_buf_get_lines(b,0,-1,false),modified=vim.bo[b].modified} end,vim.api.nvim_tabpage_list_wins(0)))")')==before_reload
    original_hash=hashlib.sha256(pathlib.Path(session).read_bytes()).hexdigest()
    expr(server1,'luaeval("(function() local old=vim.cmd; vim.cmd=function() error(\\\"forced mksession failure\\\") end; local ok=require(\\\"tmux_workspace_resurrect\\\").save(); vim.cmd=old; return ok end)()")')
    assert hashlib.sha256(pathlib.Path(session).read_bytes()).hexdigest()==original_hash
    expr(server1,'luaeval("(function() for _,b in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_get_name(b)~=\\\"\\\" then vim.api.nvim_buf_set_lines(b,0,-1,false,{\\\"timer newest\\\",\\\"without full save\\\"}); vim.api.nvim_exec_autocmds(\\\"TextChanged\\\",{buffer=b}); return true end end end)()")')
    time.sleep(1.1)
    timer_hash=hashlib.sha256(pathlib.Path(session).read_bytes()).hexdigest()
    assert timer_hash != original_hash, "debounced text snapshot did not publish"
    fixture_pid=int(tmux("display-message","-pt","test:0.0","-F","#{pane_pid}"))
    os.kill(fixture_pid,9)
    time.sleep(.1)
    subprocess.run(["tmux","-L",socket,"kill-server"],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    source.write_text("different disk\n")

    server2=str(root/"two.sock")
    tmux("-f","/dev/null","new-session","-d","-s","test",f"nvim --listen {server2} -u {init} -S {session}")
    wait_server(server2); time.sleep(.5)
    result=json.loads(expr(server2,'luaeval("vim.json.encode(vim.tbl_map(function(b) return {name=vim.api.nvim_buf_get_name(b),lines=vim.api.nvim_buf_get_lines(b,0,-1,false),modified=vim.bo[b].modified} end,vim.tbl_filter(vim.api.nvim_buf_is_loaded,vim.api.nvim_list_bufs())))")'))
    visible=json.loads(expr(server2,'luaeval("vim.json.encode(vim.tbl_map(function(w) local b=vim.api.nvim_win_get_buf(w); return {lines=vim.api.nvim_buf_get_lines(b,0,-1,false),cursor=vim.api.nvim_win_get_cursor(w)} end,vim.api.nvim_tabpage_list_wins(0)))")'))
    named=[b for b in result if b["name"] and pathlib.Path(b["name"]).resolve()==source.resolve()]
    unnamed=[b for b in result if not b["name"] and b["lines"] in (["unnamed one"],["unnamed two"])]
    assert named and named[0]["lines"]==["timer newest","without full save"] and named[0]["modified"], result
    assert len(unnamed)==2 and all(b["modified"] for b in unnamed), result
    assert ["unnamed one"] in [v["lines"] for v in visible] and ["unnamed two"] in [v["lines"] for v in visible], visible
    assert source.read_text()=="different disk\n", "restore overwrote user file"
    assert hashlib.sha256(pathlib.Path(session).read_bytes()).hexdigest()==timer_hash, "startup overwrote its -S source"
    new_session=tmux("show-option","-pt","test:0.0","-qv","@workspace-nvim-session")
    assert new_session != session
    tmux("kill-server")

print("PASS: stable generation, named modified text, unnamed text, and no disk overwrite")
