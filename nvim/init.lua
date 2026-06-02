-- ~/.config/nvim/init.lua

-- Set leader key to Space
vim.g.mapleader = " "

local pynvim_host = vim.fn.expand("~/.local/share/nvim/pynvim-venv/bin/python")
if vim.fn.executable(pynvim_host) == 1 then
  vim.g.python3_host_prog = pynvim_host
end

-- Enable 24-bit color
vim.opt.termguicolors = true

-- Use system clipboard for normal yanks, deletes, and pastes.
vim.opt.clipboard = "unnamedplus"

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
  }

  for _, group in ipairs(groups) do
    vim.api.nvim_set_hl(0, group, { bg = "NONE" })
  end
end

-- Bootstrap lazy.nvim for a small, repo-owned Neovim setup.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    opts = {
      flavour = "mocha",
      transparent_background = true,
      integrations = {
        native_lsp = true,
      },
    },
    config = function(_, opts)
      require("catppuccin").setup(opts)
      vim.cmd.colorscheme("catppuccin-mocha")
      clear_background()
    end,
  },
}, {
  change_detection = {
    notify = false,
  },
})

vim.api.nvim_create_autocmd("ColorScheme", {
  callback = clear_background,
})

-- Basic settings
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.expandtab = true
vim.opt.autoindent = true
vim.opt.smartindent = true
vim.opt.wrap = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.cursorline = true
vim.opt.scrolloff = 8

if vim.env.SSH_TTY and vim.env.SSH_TTY ~= "" then
  vim.api.nvim_create_autocmd("TextYankPost", {
    callback = function()
      local text = table.concat(vim.v.event.regcontents, "\n")
      vim.fn.system(vim.fn.expand("~/.config/tmux/scripts/yank.sh"), text)
    end,
  })
end

-- Keybindings for file navigation
vim.keymap.set("n", "j", "v:count ? 'j' : 'gj'", { expr = true, silent = true })
vim.keymap.set("n", "k", "v:count ? 'k' : 'gk'", { expr = true, silent = true })
vim.keymap.set("n", "<leader>e", ":e ", { desc = "Open file" })
vim.keymap.set("n", "<leader>q", ":q", { desc = "Quit" })

-- Simple statusline
vim.opt.statusline = "%f %h%m%r%="
