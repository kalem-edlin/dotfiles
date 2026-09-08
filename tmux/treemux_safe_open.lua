-- Safe local file-open bridge for Treemux.
--
-- nvim-tree-remote currently builds `nvim --listen ...` as several shell
-- invocations of `tmux send-keys`. A dash-leading chunk is parsed as a tmux
-- flag on newer tmux releases, and stderr is written directly over Neovim's
-- TUI. This wrapper uses argv-based tmux calls, reuses an existing editor
-- RPC server, and starts a new editor without ever exposing command fragments
-- to tmux's option parser.

if vim.g.treemux_safe_open_installed then
  return
end

local uv = vim.uv or vim.loop

local function run(argv)
  local result = vim.system(argv, { text = true }):wait()
  return result.code == 0, vim.trim(result.stdout or ""), vim.trim(result.stderr or "")
end

local function tmux(argv)
  local command = { "tmux" }
  vim.list_extend(command, argv)
  return run(command)
end

local function notify_error(message)
  vim.schedule(function()
    vim.notify(message, vim.log.levels.ERROR, { title = "Treemux", timeout = 5000 })
  end)
end

local function socket_alive(socket)
  if not socket or socket == "" then
    return false
  end
  local ok, channel = pcall(vim.fn.sockconnect, "pipe", socket, { rpc = true })
  if ok and channel and channel > 0 then
    pcall(vim.fn.chanclose, channel)
    return true
  end
  return false
end

local function target_panes(target)
  if not target or target == "" then
    return {}
  end
  local ok, output = tmux({
    "list-panes",
    "-t",
    target,
    "-F",
    "#{pane_id}\t#{@workspace-nvim-server}\t#{pane_current_command}",
  })
  if not ok then
    return {}
  end

  local panes = {}
  for line in output:gmatch("[^\n]+") do
    local pane, server, command = line:match("^([^\t]+)\t([^\t]*)\t(.*)$")
    if pane then
      table.insert(panes, { pane = pane, server = server, command = command })
    end
  end
  return panes
end

local function existing_editor(target, preferred_socket)
  if socket_alive(preferred_socket) then
    for _, candidate in ipairs(target_panes(target)) do
      if candidate.server == preferred_socket then
        return preferred_socket, candidate.pane
      end
    end
    return preferred_socket, nil
  end

  local tree_pane = vim.env.TMUX_PANE
  local candidates = target_panes(target)
  table.sort(candidates, function(a, b)
    if a.pane == target then
      return true
    end
    if b.pane == target then
      return false
    end
    return a.pane < b.pane
  end)
  for _, candidate in ipairs(candidates) do
    if candidate.pane ~= tree_pane and candidate.command == "nvim" and socket_alive(candidate.server) then
      return candidate.server, candidate.pane
    end
  end
  return nil, nil
end

local function focus_editor(transport, socket, pane)
  if pane and pane ~= "" then
    tmux({ "select-pane", "-t", pane })
    return
  end
  -- The target Neovim knows its own TMUX_PANE even when no pane metadata was
  -- available to the tree process.
  pcall(transport.exec, 'call system("tmux select-pane -t $TMUX_PANE")', socket, 0)
end

local function shell_command(socket)
  local executable = vim.fn.exepath("nvim")
  if executable == "" then
    executable = "nvim"
  end
  local parts = { vim.fn.shellescape(executable), "--listen", vim.fn.shellescape(socket) }
  local init = vim.g.nvim_tree_remote_editor_init_file
  if init and init ~= "" then
    vim.list_extend(parts, { "-u", vim.fn.shellescape(init) })
  end
  return "exec " .. table.concat(parts, " ")
end

local function register_sidebar(editor_pane, tree_pane)
  local root = vim.g.nvim_tree_remote_treemux_path
  if not root or root == "" or not editor_pane or editor_pane == "" then
    return
  end
  local script = vim.fs.joinpath(root, "scripts", "register_sidebar.sh")
  if vim.fn.executable(script) == 1 then
    run({ script, editor_pane, tree_pane })
  end
end

local function start_editor(target, tmux_opts, socket)
  local command = shell_command(socket)
  local position = tmux_opts.split_position or ""
  local size = tmux_opts.split_size or ""
  local tree_pane = vim.env.TMUX_PANE or ""

  if position == "" then
    local scripts = require("nvim_tree_remote.tmux_scripts")
    if scripts.get_tmux_pane_running_command(target) ~= "" then
      return nil, "the target pane is busy and no editor split was requested"
    end
    local ok, _, err = tmux({ "send-keys", "-t", target, "C-c" })
    if not ok then
      return nil, err
    end
    ok, _, err = tmux({ "send-keys", "-l", "-t", target, command })
    if not ok then
      return nil, err
    end
    ok, _, err = tmux({ "send-keys", "-t", target, "Enter" })
    if not ok then
      return nil, err
    end
    return target, nil
  end

  local args = { "split-window", "-d", "-P", "-F", "#{pane_id}" }
  if position == "top" or position == "bottom" then
    vim.list_extend(args, { "-v" })
  else
    vim.list_extend(args, { "-h" })
  end
  if position == "top" or position == "left" then
    vim.list_extend(args, { "-b" })
  end
  if size ~= "" then
    vim.list_extend(args, { "-l", size })
  end
  vim.list_extend(args, { "-t", target, command })

  local ok, pane, err = tmux(args)
  if not ok or pane == "" then
    return nil, err ~= "" and err or "tmux did not return the new pane id"
  end
  register_sidebar(pane, tree_pane)
  return pane, nil
end

local function open_when_ready(transport, socket, pane, open_cmd, path, focus)
  local waited = 0
  local timer = uv.new_timer()
  timer:start(50, 100, vim.schedule_wrap(function()
    waited = waited + 100
    if socket_alive(socket) then
      timer:stop()
      timer:close()
      local ok, err = pcall(transport.open, path, open_cmd, socket, 0)
      if not ok then
        notify_error("Could not open the file in Neovim: " .. tostring(err))
        return
      end
      if focus == "editor" then
        focus_editor(transport, socket, pane)
      end
    elseif waited >= 10000 then
      timer:stop()
      timer:close()
      notify_error("Neovim did not become ready; the file tree is still active")
    end
  end))
end

local function install()
  local ok, remote = pcall(require, "nvim_tree_remote")
  if not ok or rawget(remote, "__treemux_safe_open") then
    return ok
  end
  local transport = require("nvim_tree_remote.transport")

  remote.remote_nvim_open = function(socket, open_cmd, path, tmux_opts)
    tmux_opts = tmux_opts or remote.tmux_defaults()
    if open_cmd == "tabnew_main_pane" then
      open_cmd = "edit"
    end

    local live_socket, live_pane = existing_editor(tmux_opts.pane, socket)
    if live_socket then
      local opened, err = pcall(transport.open, path, open_cmd, live_socket, 0)
      if not opened then
        notify_error("Could not reuse the existing Neovim pane: " .. tostring(err))
        return
      end
      if tmux_opts.focus == "editor" then
        focus_editor(transport, live_socket, live_pane)
      end
      return
    end

    local new_socket = vim.fn.tempname() .. ".treemux-editor"
    local pane, err = start_editor(tmux_opts.pane, tmux_opts, new_socket)
    if not pane then
      notify_error("Could not open an editor pane: " .. tostring(err))
      return
    end
    open_when_ready(transport, new_socket, pane, open_cmd, path, tmux_opts.focus)
  end

  rawset(remote, "__treemux_safe_open", true)
  vim.g.treemux_safe_open_installed = true
  return true
end

if not install() then
  vim.api.nvim_create_autocmd("User", { pattern = "VeryLazy", once = true, callback = install })
  vim.defer_fn(install, 1500)
end
