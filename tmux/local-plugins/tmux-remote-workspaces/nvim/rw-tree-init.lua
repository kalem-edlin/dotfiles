-- rw-tree-init.lua -- worker-side init for a tmux-remote-workspaces tree
-- endpoint (rw-treemux.sh deploys this file to the worker and launches the
-- tree Neovim with `-u` pointing here).
--
-- Loads the worker's ordinary treemux init (full plugin setup), then
-- monkeypatches nvim_tree_remote.remote_nvim_open -- the single funnel every
-- open path goes through (neo-tree's file_open_requested handler and all
-- nvim-tree keymaps) -- with rw's open policy:
--
--   1. A previously-established editor nvim is alive  -> RPC the file into it.
--   2. The associated shell pane exists and is idle   -> take the pane over
--      with `nvim --listen <sock>` (upstream split_position="" mode; the
--      worker window NEVER gains a second pane).
--   3. Shell busy, or no shell at all (orphaned tree) -> write a request file
--      the focus-side listener (rw-tree-listener.sh) polls; it creates a new
--      editor endpoint (its own local pane + worker session) and records the
--      socket in the state file; we then RPC the open into it.
--
-- State file (RW_TREE_STATE env, JSON): {shell_pane, editor_pane,
-- editor_socket}. Written by rw-treemux.sh at creation, updated here on
-- takeover and by the listener on editor-endpoint creation.

local upstream = os.getenv("RW_TREE_UPSTREAM_INIT")
  or (os.getenv("HOME") .. "/.config/tmux/treemux_init.lua")
dofile(upstream)

local state_file = os.getenv("RW_TREE_STATE")
if not state_file then
  return
end

local function read_state()
  local f = io.open(state_file, "r")
  if not f then
    return {}
  end
  local raw = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return {}
end

local function write_state(st)
  local tmp = state_file .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return
  end
  f:write(vim.json.encode(st))
  f:close()
  os.rename(tmp, state_file)
end

local function pane_alive(pane)
  if not pane or pane == "" then
    return false
  end
  -- NOT display-message -pt: tmux happily evaluates the format for a dead
  -- pane target (falls back to a default context, exit 0), which made this
  -- always-true and sent takeovers at ghost panes (2026-08-05). Exact-match
  -- against the real pane list instead.
  local h = io.popen("tmux list-panes -a -F '#{pane_id}' 2>/dev/null")
  if not h then
    return false
  end
  local out = h:read("*a")
  h:close()
  for id in out:gmatch("[^\n]+") do
    if id == pane then
      return true
    end
  end
  return false
end

local function socket_alive(sock)
  if not sock or sock == "" then
    return false
  end
  local ok, chan = pcall(vim.fn.sockconnect, "pipe", sock, { rpc = true })
  if ok and chan and chan > 0 then
    pcall(vim.fn.chanclose, chan)
    return true
  end
  return false
end

local function editor_tmux_opts(st)
  return { pane = st.editor_pane, split_position = "", split_size = "", focus = "editor" }
end

local function patch()
  local ok, nt = pcall(require, "nvim_tree_remote")
  -- rawget/rawset: the module table carries an __index metamethod that
  -- ERRORS on unknown keys, so a plain nt.__rw_patched read raises.
  if not ok or rawget(nt, "__rw_patched") then
    return ok
  end
  local tmux_scripts = require("nvim_tree_remote.tmux_scripts")
  local orig = nt.remote_nvim_open

  nt.remote_nvim_open = function(_, open_cmd, path, _)
    -- upstream's tabnew_main_pane quirk sends a pseudo-command; normalize.
    if open_cmd == "tabnew_main_pane" then
      open_cmd = "edit"
    end
    local st = read_state()

    -- 1. Established editor still alive: plain RPC open.
    if socket_alive(st.editor_socket) then
      return orig(st.editor_socket, open_cmd, path, editor_tmux_opts(st))
    end

    -- 2. Associated shell pane idle: take it over (never splits). Not via
    -- orig()'s own takeover branch: upstream types `nvim` and `--listen ...`
    -- as SEPARATE send-keys arguments and tmux rejects the dash-leading one
    -- as an unknown flag (verified tmux 3.4, 2026-08-05) -- the editor came
    -- up plain with no socket. Type the whole command as one literal chunk
    -- behind `--`, then RPC the open in like every other path.
    if pane_alive(st.shell_pane) then
      local running = tmux_scripts.get_tmux_pane_running_command(st.shell_pane)
      if running == "" then
        local sock = vim.fn.tempname() .. ".rw-editor"
        os.execute("tmux send-keys -t '" .. st.shell_pane .. "' C-c")
        os.execute("tmux send-keys -l -t '" .. st.shell_pane .. "' -- \"nvim --listen '" .. sock .. "'\"")
        os.execute("tmux send-keys -t '" .. st.shell_pane .. "' Enter")
        local transport = require("nvim_tree_remote.transport")
        local opened = pcall(transport.open, path, open_cmd, sock, 10)
        if opened then
          st.editor_pane = st.shell_pane
          st.editor_socket = sock
          write_state(st)
        else
          vim.notify("rw: editor takeover of " .. st.shell_pane .. " failed", vim.log.levels.ERROR)
        end
        return
      end
    end

    -- 3. Shell busy or absent: ask the focus machine for an editor pane.
    local req_tmp = state_file .. ".request.tmp"
    local f = io.open(req_tmp, "w")
    if f then
      f:write(vim.json.encode({ ts = os.time(), path = path }))
      f:close()
      os.rename(req_tmp, state_file .. ".request")
    end
    vim.notify("rw: requesting an editor pane from the focus machine...", vim.log.levels.INFO)

    local waited = 0
    local timer = (vim.uv or vim.loop).new_timer()
    timer:start(
      300,
      300,
      vim.schedule_wrap(function()
        waited = waited + 300
        local st2 = read_state()
        if socket_alive(st2.editor_socket) then
          timer:stop()
          timer:close()
          orig(st2.editor_socket, open_cmd, path, editor_tmux_opts(st2))
        elseif waited >= 15000 then
          timer:stop()
          timer:close()
          vim.notify(
            "rw: no editor pane arrived -- focus-side listener not responding; toggle the tree off/on",
            vim.log.levels.ERROR
          )
        end
      end)
    )
  end

  rawset(nt, "__rw_patched", true)
  return true
end

-- The nvim_tree_remote module may not be require-able until lazy.nvim
-- finishes; try now, then again on VeryLazy and a timed fallback.
if not patch() then
  vim.api.nvim_create_autocmd("User", { pattern = "VeryLazy", once = true, callback = patch })
  vim.defer_fn(function()
    patch()
  end, 1500)
end
