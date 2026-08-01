local M = {}

local pane_id = vim.env.TMUX_PANE
local enabled = pane_id ~= nil
  and pane_id ~= ""
  and vim.env.NVIM_APPNAME ~= "nvim-treemux"

local function state_dir()
  return vim.fn.stdpath("state") .. "/tmux-workspace-resurrect"
end

local function safe_pane_id()
  return (pane_id or "outside-tmux"):gsub("[^%w_.-]", "_")
end

local function session_file()
  return state_dir() .. "/pane-" .. safe_pane_id() .. ".vim"
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

function M.save()
  if not enabled then
    return false
  end

  vim.fn.mkdir(state_dir(), "p", "0700")
  local path = session_file()
  local current_buffer = vim.api.nvim_buf_get_name(0)

  local ok = pcall(vim.cmd, "silent! mksession! " .. vim.fn.fnameescape(path))
  if ok then
    vim.fn.setfperm(path, "rw-------")
    set_pane_option("@workspace-nvim-session", path)
    set_pane_option("@workspace-nvim-active-file", current_buffer)
  end
  return ok
end

function M.setup()
  if not enabled then
    return
  end

  set_pane_option("@workspace-nvim-server", ensure_server())
  set_pane_option("@workspace-nvim-session", session_file())
  set_pane_option("@workspace-nvim-active-file", vim.api.nvim_buf_get_name(0))

  local group = vim.api.nvim_create_augroup("TmuxWorkspaceResurrect", { clear = true })
  vim.api.nvim_create_autocmd(
    { "BufEnter", "BufWritePost", "WinNew", "WinClosed", "TabNew", "TabClosed", "VimLeavePre" },
    {
      group = group,
      callback = function()
        vim.schedule(M.save)
      end,
    }
  )

  vim.schedule(M.save)
end

return M
