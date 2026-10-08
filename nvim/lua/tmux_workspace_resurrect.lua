local M = {}

local pane_id = vim.env.TMUX_PANE
local owner_pid = tostring(vim.fn.getpid())
vim.g.tmux_workspace_editor_generation = vim.g.tmux_workspace_editor_generation
  or (owner_pid .. "-" .. tostring(os.time()) .. "-" .. tostring(vim.uv.hrtime()))
local generation = vim.g.tmux_workspace_editor_generation
local save_scheduled = false
local snapshot_scheduled = false
local ready = vim.v.vim_did_enter == 1
local cached_session_lines = nil
local restore_shortmess = nil
local embedded = vim.env.NVIM ~= nil and vim.env.NVIM ~= ""
for _, arg in ipairs(vim.v.argv or {}) do
  -- Neovim's TUI core also reports an internal --embed argument, so that
  -- flag cannot distinguish a user-facing editor from an RPC child. NVIM
  -- is the reliable nested-instance marker. --headless is still explicit.
  if arg == "--headless" then
    embedded = true
    break
  end
end
local enabled = pane_id ~= nil
  and pane_id ~= ""
  and vim.env.NVIM_APPNAME ~= "nvim-treemux"
  and not embedded

local function state_dir()
  return vim.fn.stdpath("state") .. "/tmux-workspace-resurrect"
end

local function safe_pane_id()
  return (pane_id or "outside-tmux"):gsub("[^%w_.-]", "_")
end

local function session_file()
  return state_dir() .. "/pane-" .. safe_pane_id() .. "-editor-" .. generation .. ".vim"
end

local function atomic_write_lines(path, lines)
  local temporary = path .. ".tmp-" .. owner_pid
  local ok = vim.fn.writefile(lines, temporary) == 0
  if ok then
    vim.fn.setfperm(temporary, "rw-------")
    ok = vim.uv.fs_rename(temporary, path) ~= nil
  end
  if not ok then vim.fn.delete(temporary) end
  return ok
end

local function normal_windows(tab)
  return vim.tbl_filter(function(window)
    return vim.api.nvim_win_get_config(window).relative == ""
  end, vim.api.nvim_tabpage_list_wins(tab))
end

local function canonical_path(name)
  if not name or name == "" then return "" end
  local absolute = vim.fn.fnamemodify(name, ":p")
  local resolved = vim.uv.fs_realpath(absolute)
  if resolved then return resolved end
  local parent = vim.uv.fs_realpath(vim.fs.dirname(absolute))
  return vim.fs.normalize(parent and (parent .. "/" .. vim.fs.basename(absolute)) or absolute)
end

local function snapshot_buffers()
  local entries = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].buftype == "" then
      entries[#entries + 1] = {
        name = vim.api.nvim_buf_get_name(buffer),
        lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
        modified = vim.bo[buffer].modified,
        endofline = vim.bo[buffer].endofline,
        fileformat = vim.bo[buffer].fileformat,
        readonly = vim.bo[buffer].readonly,
        modifiable = vim.bo[buffer].modifiable,
        swapfile = vim.bo[buffer].swapfile,
      }
      for _, window in ipairs(vim.fn.win_findbuf(buffer)) do
        local config = vim.api.nvim_win_get_config(window)
        if config.relative == "" then
          local tab = vim.api.nvim_win_get_tabpage(window)
          local tab_index = vim.fn.index(vim.api.nvim_list_tabpages(), tab) + 1
          local window_index = vim.fn.index(normal_windows(tab), window) + 1
          entries[#entries].views = entries[#entries].views or {}
          entries[#entries].views[#entries[#entries].views + 1] = {
            tab = tab_index, window = window_index, cursor = vim.api.nvim_win_get_cursor(window),
          }
        end
      end
    end
  end
  return { version = 1, buffers = entries }
end

local function publish_session(path, body)
  if not body then return false end
  local ok, result = pcall(function()
    local encoded = vim.inspect(vim.json.encode(snapshot_buffers()))
    local lines = vim.deepcopy(body)
    table.insert(lines, 2, "lua require('tmux_workspace_resurrect').prepare_restore(vim.json.decode(" .. encoded .. "))")
    lines[#lines + 1] = "lua require('tmux_workspace_resurrect').restore_snapshot(vim.json.decode(" .. encoded .. "))"
    return atomic_write_lines(path, lines)
  end)
  return ok and result == true
end

local function ensure_server()
  if vim.v.servername ~= nil and vim.v.servername ~= "" then
    return vim.v.servername
  end

  vim.fn.mkdir(state_dir(), "p", "0700")
  local socket = state_dir() .. "/pane-" .. safe_pane_id() .. ".sock"
  local ok, server = pcall(vim.fn.serverstart, socket)
  if ok then
    return server
  end
  return ""
end

local function set_pane_option(name, value)
  if not enabled then
    return
  end
  vim.fn.system({
    "tmux",
    "set-option",
    "-pqt",
    pane_id,
    name,
    value or "",
  })
end

local function pane_option(name)
  if not enabled then
    return ""
  end
  local value = vim.fn.system({
    "tmux",
    "show-option",
    "-pqt",
    pane_id,
    "-v",
    name,
  })
  if vim.v.shell_error ~= 0 then
    return ""
  end
  return vim.trim(value)
end

local function owns_registration()
  return enabled and pane_option("@workspace-nvim-owner-pid") == owner_pid
end

local function clear_registration()
  if not owns_registration() then
    return
  end
  for _, name in ipairs({
    "@workspace-nvim-owner-pid",
    "@workspace-nvim-server",
    "@workspace-nvim-session",
    "@workspace-nvim-active-file",
  }) do
    vim.fn.system({ "tmux", "set-option", "-pqu", "-t", pane_id, name })
  end
end

local function schedule_save(delay)
  if save_scheduled or not ready then
    return
  end
  save_scheduled = true
  vim.defer_fn(function()
    save_scheduled = false
    M.save()
  end, delay or 750)
end

local function schedule_snapshot()
  if snapshot_scheduled or not ready then return end
  snapshot_scheduled = true
  vim.defer_fn(function()
    snapshot_scheduled = false
    publish_session(session_file(), cached_session_lines)
  end, 750)
end

function M.save()
  if not ready or not owns_registration() then
    return false
  end

  vim.fn.mkdir(state_dir(), "p", "0700")
  local path = session_file()
  local current_buffer = vim.api.nvim_buf_get_name(0)

  local temporary = path .. ".tmp-" .. owner_pid
  local ok = pcall(vim.cmd, "silent mksession! " .. vim.fn.fnameescape(temporary))
  if ok then
    vim.fn.setfperm(temporary, "rw-------")
    local read_ok, lines = pcall(vim.fn.readfile, temporary)
    ok = read_ok
    if ok then
      cached_session_lines = lines
      vim.fn.delete(temporary)
      ok = publish_session(path, cached_session_lines)
    end
  end
  if ok then
    vim.fn.setfperm(path, "rw-------")
    set_pane_option("@workspace-nvim-session", path)
    set_pane_option("@workspace-nvim-active-file", current_buffer)
  end
  if not ok then vim.fn.delete(temporary) end
  return ok
end

local function valid_snapshot(decoded)
  if not decoded or decoded.version ~= 1 or type(decoded.buffers) ~= "table" then return nil end
  for _, entry in ipairs(decoded.buffers) do
    if type(entry) ~= "table" or type(entry.name) ~= "string" or type(entry.lines) ~= "table" then return nil end
    for _, line in ipairs(entry.lines) do if type(line) ~= "string" then return nil end end
  end
  return decoded
end

function M.prepare_restore(path)
  local manifest = valid_snapshot(path)
  if not manifest then return false end
  local names = {}
  restore_shortmess = vim.o.shortmess
  if not vim.o.shortmess:find("A", 1, true) then vim.o.shortmess = vim.o.shortmess .. "A" end
  for _, entry in ipairs(manifest.buffers) do
    if entry.name and entry.name ~= "" then names[canonical_path(entry.name)] = true end
  end
  local group = vim.api.nvim_create_augroup("TmuxWorkspaceRestoreSwap", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
    group = group,
    callback = function(event)
      local name = vim.api.nvim_buf_get_name(event.buf)
      if name ~= "" and names[canonical_path(name)] then vim.bo[event.buf].swapfile = false end
    end,
  })
  vim.api.nvim_create_autocmd("SwapExists", {
    group = group,
    callback = function(event)
      local candidates = { event.file }
      if event.buf and vim.api.nvim_buf_is_valid(event.buf) then
        candidates[#candidates + 1] = vim.api.nvim_buf_get_name(event.buf)
      end
      for _, name in ipairs(candidates) do
        if names[canonical_path(name)] then vim.v.swapchoice = "e"; return end
      end
    end,
  })
  return true
end


function M.restore_snapshot(path)
  local manifest = valid_snapshot(path)
  if not manifest then return false end
  local named, unnamed = {}, {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buffer)
      if name == "" then unnamed[#unnamed + 1] = buffer else named[canonical_path(name)] = buffer end
    end
  end
  local unnamed_index = 1
  for _, entry in ipairs(manifest.buffers) do
    local buffer
    if entry.name and entry.name ~= "" then
      buffer = named[canonical_path(entry.name)]
      if not buffer then
        buffer = vim.api.nvim_create_buf(true, false)
        pcall(vim.api.nvim_buf_set_name, buffer, entry.name)
      end
    else
      buffer = unnamed[unnamed_index]
      unnamed_index = unnamed_index + 1
      if not buffer then buffer = vim.api.nvim_create_buf(true, false) end
    end
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      vim.bo[buffer].readonly = false
      vim.bo[buffer].modifiable = true
      vim.bo[buffer].swapfile = false
      local changed_from_loaded = not vim.deep_equal(
        vim.api.nvim_buf_get_lines(buffer, 0, -1, false), entry.lines or { "" }
      )
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, entry.lines or { "" })
      vim.bo[buffer].modified = entry.modified == true or changed_from_loaded
      vim.bo[buffer].endofline = entry.endofline ~= false
      if entry.fileformat then vim.bo[buffer].fileformat = entry.fileformat end
      vim.bo[buffer].readonly = entry.readonly == true
      vim.bo[buffer].modifiable = entry.modifiable ~= false
      for _, view in ipairs(entry.views or {}) do
        local tab = vim.api.nvim_list_tabpages()[view.tab]
        local window = tab and normal_windows(tab)[view.window]
        if window and vim.api.nvim_win_is_valid(window) then
          pcall(vim.api.nvim_win_set_buf, window, buffer)
          if view.cursor then pcall(vim.api.nvim_win_set_cursor, window, view.cursor) end
        end
      end
      if entry.swapfile ~= false then pcall(function() vim.bo[buffer].swapfile = true end) end
    end
  end
  pcall(vim.api.nvim_del_augroup_by_name, "TmuxWorkspaceRestoreSwap")
  if restore_shortmess then vim.o.shortmess = restore_shortmess; restore_shortmess = nil end
  return true
end

function M.setup()
  if not enabled then
    return
  end

  local server = ensure_server()
  if server == "" then
    return
  end

  set_pane_option("@workspace-nvim-owner-pid", owner_pid)
  set_pane_option("@workspace-nvim-server", server)
  -- Publish only an artifact that already exists. The first successful save
  -- publishes a new generation; a live module reload may reuse its existing
  -- generation without changing buffer contents.
  set_pane_option("@workspace-nvim-session", vim.fn.filereadable(session_file()) == 1 and session_file() or "")
  set_pane_option("@workspace-nvim-active-file", vim.api.nvim_buf_get_name(0))

  local group = vim.api.nvim_create_augroup("TmuxWorkspaceResurrect", { clear = true })
  vim.api.nvim_create_autocmd(
    { "BufEnter", "BufWritePost", "BufDelete", "BufWipeout", "BufFilePost",
      "WinNew", "WinClosed", "TabNew", "TabClosed" },
    {
      group = group,
      callback = function() schedule_save(750) end,
    }
  )
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "InsertLeave" }, {
    group = group,
    callback = schedule_snapshot,
  })
  vim.api.nvim_create_autocmd({ "VimEnter", "SessionLoadPost" }, {
    group = group,
    callback = function()
      ready = true
      schedule_save(100)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      ready = true
      M.save()
      clear_registration()
    end,
  })
  if ready then schedule_save(100) end
end

return M
