-- Repo-owned treemux init wrapper.
--
-- The upstream treemux init file bootstraps the sidebar plugins and keymaps.
-- This wrapper keeps that behavior while swapping its hardcoded theme for
-- transparent Catppuccin Mocha.

local upstream_init = vim.fn.expand("~/.config/tmux/plugins/treemux/configs/treemux_init.lua")
local lines = vim.fn.readfile(upstream_init)
local source = table.concat(lines, "\n")

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

local colorscheme_count
source, colorscheme_count = source:gsub("vim%.cmd%(%[%[ colorscheme tokyonight%-night %]%]%)", 'vim.cmd.colorscheme("catppuccin-mocha")', 1)
if colorscheme_count ~= 1 then
  error("Could not replace treemux colorscheme")
end

local chunk, err = load(source, "@treemux_init_with_catppuccin")
if not chunk then
  error(err)
end
chunk()

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
end

clear_background()

vim.api.nvim_create_autocmd("ColorScheme", {
  callback = clear_background,
})
