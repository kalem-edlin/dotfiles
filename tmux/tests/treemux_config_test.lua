-- Run with: nvim --headless --clean -l tmux/tests/treemux_config_test.lua
-- Execute the real wrapper and upstream config with plugin/network work mocked.
local configs, subscriptions = {}, {}
local original_stat = vim.uv.fs_stat
vim.uv.fs_stat = function(path, ...)
  if path:match("/lazy/lazy.nvim$") then return { type = "directory" } end
  return original_stat(path, ...)
end
vim.fn.system = function() error("Unexpected subprocess in config test") end
vim.cmd.colorscheme = function() end
vim.g.treemux_safe_open_installed = true
package.preload["nvim-tree"] = function()
  return { setup = function(opts) configs.tree = opts end }
end
package.preload["neo-tree"] = function()
  return { setup = function(opts) configs.neo = opts end }
end
package.preload["nvim-web-devicons"] = function()
  return { setup = function() end }
end
package.preload["neo-tree.events"] = function()
  return {
    GIT_EVENT = "git_event",
    NEO_TREE_POPUP_INPUT_READY = "popup_ready",
    subscribe = function(handler) subscriptions[#subscriptions + 1] = handler end,
  }
end
package.preload["lazy"] = function()
  return { setup = function(specs)
    for _, spec in ipairs(specs) do
      if type(spec) == "table" and
        (spec[1] == "nvim-tree/nvim-tree.lua" or spec[1] == "nvim-neo-tree/neo-tree.nvim") then
        spec.config()
      end
    end
  end }
end

dofile("tmux/treemux_init.lua")
assert(configs.tree and configs.neo, "Both upstream tree configurations must execute")
assert(configs.tree.git.enable == false)
assert(configs.tree.filesystem_watchers.enable == false)
assert(configs.neo.enable_git_status == false)
assert(configs.neo.filesystem.use_libuv_file_watcher == false)
assert(configs.neo.filesystem.filtered_items.hide_gitignored == false)
assert(not vim.tbl_contains(configs.neo.sources, "git_status"))
local maps = configs.neo.filesystem.window.mappings
for _, key in ipairs({ "ga", "gu", "gt", "gr" }) do
  assert(maps[key] == nil, "Removed Git binding remains: " .. key)
end
assert(maps.R == "refresh", "Manual refresh must remain available")
assert(maps.Y and maps.gy, "Path copying must remain available")
for _, handler in ipairs(subscriptions) do
  assert(handler.event ~= "git_event", "Custom Git refresh subscription remains")
end
print("Treemux config test passed: Git and continuous watchers disabled; navigation retained")
