-- Repo-owned treemux init wrapper.
--
-- The upstream treemux init file bootstraps the sidebar plugins and keymaps.
-- This wrapper keeps that behavior while swapping its hardcoded theme for
-- transparent Catppuccin Mocha.

local upstream_init = vim.fn.expand("~/.config/tmux/plugins/treemux/configs/treemux_init.lua")
local lines = vim.fn.readfile(upstream_init)
local source = table.concat(lines, "\n")

-- Treemux uses its own minimal Neovim config, so it does not inherit the
-- remote clipboard provider from ~/.config/nvim/init.lua. On an rw worker,
-- force writes to the + register through OSC 52 so they traverse the nested
-- tmux/SSH chain and land on the focus machine's clipboard.
vim.opt.clipboard = "unnamedplus"
if (vim.env.SSH_TTY or vim.env.SSH_CONNECTION) and vim.fn.has("nvim-0.10") == 1 then
  local osc52 = require("vim.ui.clipboard.osc52")
  local function paste_reg()
    return { vim.split(vim.fn.getreg('"'), "\n"), vim.fn.getregtype('"') }
  end
  vim.g.clipboard = {
    name = "OSC 52",
    copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
    paste = { ["+"] = paste_reg, ["*"] = paste_reg },
  }
end

local catppuccin_spec = [[
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    opts = {
      flavour = "mocha",
      transparent_background = true,
      integrations = {
        neo_tree = true,
        nvimtree = true,
        notify = true,
      },
    },
    config = function(_, opts)
      require("catppuccin").setup(opts)
    end,
  },]]

local plugin_count
source, plugin_count = source:gsub('%s*"folke/tokyonight%.nvim",', "\n" .. catppuccin_spec, 1)
if plugin_count ~= 1 then
  error("Could not replace treemux tokyonight plugin spec")
end

local icon_count
source, icon_count = source:gsub('"nvim%-tree/nvim%-web%-devicons"', '"DaikyXendo/nvim-material-icon"')
if icon_count == 0 then
  error("Could not replace treemux devicons plugin")
end

local colorscheme_count
source, colorscheme_count = source:gsub("vim%.cmd%(%[%[ colorscheme tokyonight%-night %]%]%)", 'vim.cmd.colorscheme("catppuccin-mocha")', 1)
if colorscheme_count ~= 1 then
  error("Could not replace treemux colorscheme")
end

local nvim_tree_filter_count
source, nvim_tree_filter_count = source:gsub(
  'filters = {%s*\n%s*custom = { "%.git" },%s*\n%s*},',
  [[filters = {
          git_ignored = false,
          dotfiles = false,
          custom = {
            ".git",
            ".DS_Store",
            "node_modules",
            "dist",
            "build",
            "out",
            "target",
            "coverage",
            ".next",
            ".nuxt",
            ".svelte-kit",
            ".turbo",
            ".vite",
            ".cache",
            ".parcel-cache",
            ".pytest_cache",
            "__pycache__",
            ".mypy_cache",
            ".ruff_cache",
            ".venv",
            "venv",
          },
        },]],
  1
)
if nvim_tree_filter_count ~= 1 then
  error("Could not patch treemux nvim-tree filters")
end

local neo_tree_filter_count
source, neo_tree_filter_count = source:gsub(
  'filesystem = {%s*\n%s*hijack_netrw_behavior = "disabled",',
  [[filesystem = {
          hijack_netrw_behavior = "disabled",
          use_libuv_file_watcher = true,
          filtered_items = {
            visible = true,
            hide_dotfiles = false,
            hide_gitignored = true,
            hide_ignored = false,
            always_show = {
              ".env",
              ".env.local",
              ".env.development",
              ".env.production",
              ".env.test",
              ".npmrc",
              ".nvmrc",
              ".node-version",
              ".python-version",
              ".ruby-version",
            },
            always_show_by_pattern = {
              ".env.*",
              ".yarnrc*",
            },
            never_show = {
              ".git",
              ".DS_Store",
              "node_modules",
              "dist",
              "build",
              "out",
              "target",
              "coverage",
              ".next",
              ".nuxt",
              ".svelte-kit",
              ".turbo",
              ".vite",
              ".cache",
              ".parcel-cache",
              ".pytest_cache",
              "__pycache__",
              ".mypy_cache",
              ".ruff_cache",
              ".venv",
              "venv",
            },
          },]],
  1
)
if neo_tree_filter_count ~= 1 then
  error("Could not patch treemux neo-tree filters")
end

local neo_tree_git_mapping_count
source, neo_tree_git_mapping_count = source:gsub(
  '%["q"%] = "noop",',
  [[["q"] = "noop",
              ["R"] = "refresh",
              ["z"] = "noop",
              ["zz"] = { function() vim.cmd("normal! zz") end, desc = "center row" },
              ["zt"] = { function() vim.cmd("normal! zt") end, desc = "row to top" },
              ["zb"] = { function() vim.cmd("normal! zb") end, desc = "row to bottom" },
              ["g"] = { "show_help", nowait = false, config = { title = "Git", prefix_key = "g" } },
              ["gy"] = {
                function(state)
                  local node = state.tree and state.tree:get_node()
                  local path = node and node:get_id()
                  if not path then
                    return
                  end
                  vim.fn.setreg("+", path)
                  vim.notify("Copied absolute path: " .. path)
                end,
                desc = "copy absolute path",
              },
              ["Y"] = {
                function(state)
                  local node = state.tree and state.tree:get_node()
                  local path = node and node:get_id()
                  local root = state.path
                  if not path or not root then
                    return
                  end

                  path = vim.fs.normalize(path)
                  root = vim.fs.normalize(root)
                  local relative_path = "."
                  if path ~= root then
                    local root_prefix = root:sub(-1) == "/" and root or (root .. "/")
                    relative_path = path:sub(1, #root_prefix) == root_prefix
                        and path:sub(#root_prefix + 1)
                      or path
                  end

                  vim.fn.setreg("+", relative_path)
                  vim.notify("Copied root-relative path: " .. relative_path)
                end,
                desc = "copy root-relative path",
              },
              ["ga"] = { "git_add_file", desc = "stage" },
              ["gu"] = { "git_unstage_file", desc = "unstage" },
              ["gt"] = { "git_toggle_file_stage", desc = "toggle stage" },
              ["gr"] = { "git_revert_file", desc = "revert" },]],
  1
)
if neo_tree_git_mapping_count ~= 1 then
  error("Could not patch treemux neo-tree git mappings")
end

local chunk, err = load(source, "@treemux_init_with_catppuccin")
if not chunk then
  error(err)
end
chunk()

local neo_tree_events = require("neo-tree.events")

neo_tree_events.subscribe({
  event = neo_tree_events.GIT_EVENT,
  id = "treemux_force_filesystem_git_refresh",
  handler = function()
    vim.defer_fn(function()
      local ok_manager, manager = pcall(require, "neo-tree.sources.manager")
      local ok_git, git = pcall(require, "neo-tree.git")
      if not ok_manager or not ok_git then
        return
      end

      manager._for_each_state("filesystem", function(state)
        if state.path then
          pcall(git.status, state.path, state.git_base_by_worktree, false)
        end
      end)
      pcall(manager.refresh, "filesystem")
      vim.defer_fn(function()
        pcall(manager.redraw, "filesystem")
      end, 100)
    end, 20)
  end,
})

require("nvim-web-devicons").setup({
  color_icons = true,
  default = true,
})

neo_tree_events.subscribe({
  event = neo_tree_events.NEO_TREE_POPUP_INPUT_READY,
  id = "treemux_select_popup_input",
  handler = function(args)
    vim.schedule(function()
      local winid = args and args.winid
      local bufnr = args and args.bufnr
      if not winid or not bufnr or not vim.api.nvim_win_is_valid(winid) then
        return
      end

      vim.api.nvim_set_current_win(winid)
      vim.cmd("stopinsert")

      local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
      local start_col = line:match("^ ") and 1 or 0
      if #line <= start_col then
        vim.api.nvim_win_set_cursor(winid, { 1, start_col })
        return
      end

      vim.api.nvim_win_set_cursor(winid, { 1, start_col })
      vim.cmd("normal! v$")
    end)
  end,
})

local function clear_background()
  local groups = {
    "Normal",
    "NormalNC",
    "NormalFloat",
    "FloatBorder",
    "SignColumn",
    "StatusLine",
    "StatusLineNC",
    "TabLine",
    "TabLineFill",
    "WinBar",
    "WinBarNC",
    "Pmenu",
    "NeoTreeNormal",
    "NeoTreeNormalNC",
    "NeoTreeEndOfBuffer",
    "NeoTreeFloatNormal",
    "NeoTreeFloatBorder",
    "NvimTreeNormal",
    "NvimTreeNormalNC",
    "NvimTreeEndOfBuffer",
  }

  for _, group in ipairs(groups) do
    vim.api.nvim_set_hl(0, group, { bg = "NONE" })
  end

  vim.api.nvim_set_hl(0, "NeoTreeGitIgnored", { fg = "#585b70", bg = "NONE" })
end

clear_background()

vim.api.nvim_create_autocmd("ColorScheme", {
  callback = clear_background,
})
