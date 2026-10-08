-- Compatibility transport for md-render.nvim v3.8.3 inside local tmux.
-- The upstream module gets its own vim.api proxy; Neovim's global API and the
-- installed plugin checkout are untouched. Remove when upstream handles tmux.
local M = {}
local esc = string.char(27)

function M.transport(send, geometry, visible, id_base)
  local ids = {}
  local function mapped(id)
    ids[id] = ids[id] or (id_base + tonumber(id))
    return ids[id]
  end
  local function wrap(data)
    if data ~= "" then send(esc .. "Ptmux;" .. data:gsub(esc, esc .. esc) .. esc .. "\\") end
  end
  local function clear(remove_data, direct_send)
    local commands = {}
    for _, id in pairs(ids) do
      commands[#commands + 1] = string.format("%s_Ga=d,d=%s,i=%d,q=2%s\\", esc, remove_data and "I" or "i", id, esc)
    end
    if direct_send then direct_send(table.concat(commands)) else wrap(table.concat(commands)) end
  end
  local function write(data)
    local pos = geometry()
    local can_display = pos and pos.visible and visible()
    -- Wrap cursor movement with the image command, translating pane-local
    -- coordinates. tmux's raw passthrough does not position the cursor for us.
    data = data:gsub(esc .. "%[(%d+);(%d+)H", function(row, col)
      return string.format("%s[%d;%dH", esc, tonumber(row) + (pos and pos.top or 0), tonumber(col) + (pos and pos.left or 0))
    end)
    data = data:gsub(esc .. "_G(.-)" .. esc .. "\\", function(command)
      if command:match("^a=[Tp][,;]") and not can_display then return "" end
      -- Upstream starts IDs at 100 in every Neovim and uses terminal-wide
      -- deletes. Scope both to this process, so another pane survives cleanup.
      if command:match("^a=d,d=[aA][,;]?") and not command:match(",i=%d+") then
        clear(command:match("^a=d,d=A") ~= nil)
        return ""
      end
      command = command:gsub(",i=(%d+)", function(id) return ",i=" .. mapped(id) end)
      command = command:gsub("^a=d,d=a,", "a=d,d=i,")
      return esc .. "_G" .. command .. esc .. "\\"
    end)
    -- There is no reason to move the terminal cursor if all drawing was dropped.
    if data:find(esc .. "_G", 1, true) then wrap(data) end
  end
  return write, clear
end

function M.setup(plugin_dir)
  if not vim.env.TMUX or not vim.env.TMUX_PANE or M.installed then return end
  assert(not package.loaded["md-render.image"], "md-render tmux transport must load before the image module")
  M.installed = true
  local pane = vim.env.TMUX_PANE
  local function tmux(args)
    local result = vim.system(vim.list_extend({ "tmux" }, args), { text = true }):wait(1000)
    return result.code == 0 and vim.trim(result.stdout) or nil
  end
  local focused = true
  local client_ttys = {}
  local cached, cached_at
  local function geometry()
    local now = vim.uv.hrtime()
    if cached_at and now - cached_at < 100000000 then return cached end
    cached_at = now
    local value = tmux({ "display-message", "-p", "-t", pane,
      "#{pane_left}|#{pane_top}|#{window_active}|#{session_attached}|#{pane_in_mode}|#{status-position}|#{status}" })
    local p = value and vim.split(value, "|", { plain = true }) or {}
    if #p ~= 7 then cached = nil; return nil end
    local status_rows = p[7] == "on" and 1 or tonumber(p[7]) or 0
    cached = {
      left = tonumber(p[1]), top = tonumber(p[2]) + (p[6] == "top" and status_rows or 0),
      visible = p[3] == "1" and tonumber(p[4]) > 0 and p[5] == "0",
    }
    if cached.visible then
      local clients = tmux({ "list-clients", "-t", pane, "-F", "#{client_tty}" })
      if clients and clients ~= "" then client_ttys = vim.split(clients, "\n", { plain = true }) end
    end
    return cached
  end
  local write, clear = M.transport(vim.api.nvim_ui_send, geometry, function()
    return focused and vim.b.md_render == true
  end, vim.fn.getpid() * 4096)

  -- Once a client changes sessions, the old session has no route to its
  -- terminal. Cache the attached client's TTY while visible and send ONLY
  -- our ID-specific delete commands there on leave. No cursor movement or
  -- image placement bypasses tmux, and allow-passthrough can remain "on".
  local function clear_from_clients(remove_data)
    clear(remove_data, function(data)
      if data == "" then return end
      for _, tty in ipairs(client_ttys) do
        local stat = vim.uv.fs_stat(tty)
        if tty:match("^/dev/") and stat and stat.type == "char" then
          local fd = vim.uv.fs_open(tty, "w", 0)
          if fd then
            vim.uv.fs_write(fd, data, -1)
            vim.uv.fs_close(fd)
          end
        end
      end
    end)
  end

  package.preload["md-render.image"] = function()
    local api = setmetatable({ nvim_ui_send = write }, { __index = vim.api })
    local scoped_vim = setmetatable({ api = api }, { __index = vim })
    local loader = assert(loadfile(plugin_dir .. "/lua/md-render/image.lua"))
    setfenv(loader, setmetatable({ vim = scoped_vim }, { __index = _G }))
    return loader()
  end
  local group = vim.api.nvim_create_augroup("dotfiles_md_images_tmux", { clear = true })
  local function redisplay()
    cached_at = nil
    vim.schedule(function()
      if focused and vim.b.md_render then
        local display = require("md-render.display_utils")
        vim.api.nvim_exec_autocmds("User", { pattern = display.REPAINT_EVENT, data = { source = "tmux" } })
      end
    end)
  end
  vim.api.nvim_create_autocmd("FocusLost", { group = group, callback = function()
    focused = false
    cached_at = nil
    clear_from_clients(false)
  end })
  vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = function()
    focused = true
    redisplay()
  end })
  vim.api.nvim_create_autocmd("BufLeave", { group = group, callback = function()
    if vim.b.md_render then clear_from_clients(false) end
  end })
  vim.api.nvim_create_autocmd({ "BufEnter", "VimResized" }, { group = group, callback = redisplay })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    clear_from_clients(true)
  end })
end

return M
