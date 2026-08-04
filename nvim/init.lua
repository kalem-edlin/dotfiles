-- ~/.config/nvim/init.lua

-- Set leader key to Space
vim.g.mapleader = " "

require("tmux_workspace_resurrect").setup()

local pynvim_host = vim.fn.expand("~/.local/share/nvim/pynvim-venv/bin/python")
if vim.fn.executable(pynvim_host) == 1 then
  vim.g.python3_host_prog = pynvim_host
end

-- Enable 24-bit color
vim.opt.termguicolors = true

-- Match Vim's terminal cursor behavior: keep a block cursor in every mode.
vim.opt.guicursor = "a:block"

-- Use system clipboard for normal yanks, deletes, and pastes.
vim.opt.clipboard = "unnamedplus"

-- Over ssh (rw endpoints included), default provider resolution finds the
-- REMOTE machine's clipboard tool (pbcopy on a Mac worker) and yanks die
-- there. Emit OSC 52 instead so yanks travel remote tmux -> ssh -> local
-- tmux -> local clipboard, the same path tmux.conf's clipboard
-- terminal-feature enables. Paste never queries the terminal: tmux answers
-- OSC 52 reads only when it already holds a paste buffer and hangs the
-- editor otherwise, and the LOCAL clipboard is unreadable from remote
-- either way (reads stop at the first tmux). Pasting the unnamed register
-- keeps `p` working for anything yanked in this nvim.
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

local mocha = {
  text = "#cdd6f4",
  subtext0 = "#a6adc8",
  overlay0 = "#6c7086",
  surface1 = "#45475a",
  surface2 = "#585b70",
  blue = "#89b4fa",
  green = "#a6e3a1",
  peach = "#fab387",
  red = "#f38ba8",
  yellow = "#f9e2af",
  mauve = "#cba6f7",
}

local function apply_editor_chrome()
  local transparent_groups = {
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
    "FoldColumn",
    "ColorColumn",
    "EndOfBuffer",
  }

  for _, group in ipairs(transparent_groups) do
    vim.api.nvim_set_hl(0, group, { bg = "NONE" })
  end

  vim.api.nvim_set_hl(0, "Normal", { fg = mocha.text, bg = "NONE" })
  vim.api.nvim_set_hl(0, "NormalNC", { fg = mocha.subtext0, bg = "NONE" })
  vim.api.nvim_set_hl(0, "WinSeparator", { fg = mocha.surface2, bg = "NONE" })
  vim.api.nvim_set_hl(0, "StatusLine", { fg = mocha.text, bg = "NONE", bold = true })
  vim.api.nvim_set_hl(0, "StatusLineNC", { fg = mocha.overlay0, bg = "NONE" })
  vim.api.nvim_set_hl(0, "WinBar", { fg = mocha.blue, bg = "NONE", bold = true })
  vim.api.nvim_set_hl(0, "WinBarNC", { fg = mocha.overlay0, bg = "NONE" })
  vim.api.nvim_set_hl(0, "EditorRule", { fg = mocha.blue, bg = "NONE", bold = true })
  vim.api.nvim_set_hl(0, "EditorRuleLine", { fg = mocha.blue, bg = "NONE" })
  vim.api.nvim_set_hl(0, "CursorLine", { bg = "NONE" })
  vim.api.nvim_set_hl(0, "LineNr", { fg = mocha.surface1, bg = "NONE" })
  vim.api.nvim_set_hl(0, "CursorLineNr", { fg = mocha.mauve, bg = "NONE", bold = true })
  vim.api.nvim_set_hl(0, "SignColumn", { bg = "NONE" })
  vim.api.nvim_set_hl(0, "EndOfBuffer", { fg = mocha.surface1, bg = "NONE" })
  vim.api.nvim_set_hl(0, "ScrollbarHandle", { fg = mocha.surface2, bg = "NONE" })
  vim.api.nvim_set_hl(0, "ScrollbarCursor", { fg = mocha.blue, bg = "NONE" })
  vim.api.nvim_set_hl(0, "ScrollbarCursorHandle", { fg = mocha.blue, bg = "NONE" })
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

local misc_file_excludes = {
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
}

local function telescope_file_ignore_patterns(include_misc)
  local patterns = {
    "/%.git/",
    "%.DS_Store$",
  }

  if include_misc then
    return patterns
  end

  for _, name in ipairs(misc_file_excludes) do
    if name ~= ".git" and name ~= ".DS_Store" then
      table.insert(patterns, "/" .. vim.pesc(name) .. "/")
    end
  end

  return patterns
end

local function fd_find_command(include_misc)
  local command = {
    "fd",
    "--type",
    "f",
    "--color",
    "never",
    "--hidden",
    "--exclude",
    ".git",
    "--exclude",
    ".DS_Store",
  }

  if include_misc then
    table.insert(command, "--no-ignore")
    return command
  end

  for _, name in ipairs(misc_file_excludes) do
    if name ~= ".git" and name ~= ".DS_Store" then
      table.insert(command, "--exclude")
      table.insert(command, name)
    end
  end

  return command
end

local function ripgrep_misc_args(include_misc)
  local args = {
    "--hidden",
    "--glob",
    "!**/.git/**",
    "--glob",
    "!**/.DS_Store",
  }

  if include_misc then
    table.insert(args, "--no-ignore")
    return args
  end

  for _, name in ipairs(misc_file_excludes) do
    if name ~= ".git" and name ~= ".DS_Store" then
      table.insert(args, "--glob")
      table.insert(args, "!**/" .. name .. "/**")
    end
  end

  return args
end

local function telescope_project_files_title(include_misc)
  return include_misc and "All files (Ctrl-e: code only)" or "Project files (Ctrl-e: include misc)"
end

local function telescope_grep_title(include_misc)
  return include_misc and "Grep all files (Ctrl-e: code only)" or "Grep project files (Ctrl-e: include misc)"
end

local function telescope_set_prompt_title(picker, title)
  picker.prompt_title = title
  if picker.layout and picker.layout.prompt and picker.layout.prompt.border then
    picker.layout.prompt.border:change_title(title)
  end
end

local function extend_list(base, extra)
  local result = vim.deepcopy(base)
  vim.list_extend(result, extra)
  return result
end

local function telescope_file_picker_opts(include_misc, opts)
  local make_entry = require("telescope.make_entry")

  opts = vim.tbl_extend("force", {
    hidden = true,
    no_ignore = include_misc,
    file_ignore_patterns = telescope_file_ignore_patterns(include_misc),
    prompt_title = telescope_project_files_title(include_misc),
  }, opts or {})
  opts.entry_maker = opts.entry_maker or make_entry.gen_from_file(opts)

  return opts
end

local function telescope_file_finder(include_misc, opts)
  local finders = require("telescope.finders")
  return finders.new_oneshot_job(fd_find_command(include_misc), opts)
end

local telescope_project_files
telescope_project_files = function(include_misc, opts)
  local action_state = require("telescope.actions.state")
  local conf = require("telescope.config").values
  local pickers = require("telescope.pickers")

  if vim.fn.executable("fd") ~= 1 then
    require("telescope.builtin").find_files({ hidden = true })
    return
  end

  local current_include_misc = include_misc
  local picker_opts = telescope_file_picker_opts(current_include_misc, opts)

  pickers.new(picker_opts, {
    prompt_title = telescope_project_files_title(current_include_misc),
    finder = telescope_file_finder(current_include_misc, picker_opts),
    previewer = conf.grep_previewer(picker_opts),
    sorter = conf.file_sorter(picker_opts),
    attach_mappings = function(prompt_bufnr, map)
      local toggle_misc = function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        current_include_misc = not current_include_misc
        local refreshed_opts = telescope_file_picker_opts(current_include_misc, opts)
        telescope_set_prompt_title(picker, telescope_project_files_title(current_include_misc))
        picker:refresh(telescope_file_finder(current_include_misc, refreshed_opts), { reset_prompt = false })
      end

      map("i", "<C-e>", toggle_misc)
      map("n", "<C-e>", toggle_misc)
      return true
    end,
  }):find()
end

local function telescope_grep_picker_opts(include_misc, opts)
  local make_entry = require("telescope.make_entry")

  opts = vim.tbl_extend("force", {
    hidden = true,
    prompt_title = telescope_grep_title(include_misc),
  }, opts or {})
  opts.cwd = opts.cwd or vim.uv.cwd()
  opts.entry_maker = opts.entry_maker or make_entry.gen_from_vimgrep(opts)

  return opts
end

local function telescope_grep_finder(include_misc, opts)
  local conf = require("telescope.config").values
  local finders = require("telescope.finders")
  local args = extend_list(opts.vimgrep_arguments or conf.vimgrep_arguments, ripgrep_misc_args(include_misc))

  return finders.new_job(function(prompt)
    if not prompt or prompt == "" then
      return nil
    end

    return extend_list(extend_list(args, { "--", prompt }), opts.search_dirs or {})
  end, opts.entry_maker, nil, opts.cwd)
end

local telescope_live_grep
telescope_live_grep = function(include_misc, opts)
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local conf = require("telescope.config").values
  local pickers = require("telescope.pickers")
  local sorters = require("telescope.sorters")

  local current_include_misc = include_misc
  local picker_opts = telescope_grep_picker_opts(current_include_misc, opts)

  pickers.new(picker_opts, {
    prompt_title = telescope_grep_title(current_include_misc),
    finder = telescope_grep_finder(current_include_misc, picker_opts),
    previewer = conf.grep_previewer(picker_opts),
    sorter = sorters.highlighter_only(picker_opts),
    attach_mappings = function(prompt_bufnr, map)
      local toggle_misc = function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        current_include_misc = not current_include_misc
        local refreshed_opts = telescope_grep_picker_opts(current_include_misc, opts)
        telescope_set_prompt_title(picker, telescope_grep_title(current_include_misc))
        picker:refresh(telescope_grep_finder(current_include_misc, refreshed_opts), { reset_prompt = false })
      end

      map("i", "<C-Space>", actions.to_fuzzy_refine)
      map("i", "<C-e>", toggle_misc)
      map("n", "<C-e>", toggle_misc)
      return true
    end,
    push_cursor_on_edit = true,
  }):find()
end

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
      apply_editor_chrome()
    end,
  },
  {
    "nvim-telescope/telescope.nvim",
    branch = "master",
    cmd = "Telescope",
    dependencies = {
      "nvim-lua/plenary.nvim",
      {
        "nvim-telescope/telescope-fzf-native.nvim",
        build = "make",
        cond = function()
          return vim.fn.executable("make") == 1
        end,
      },
    },
    keys = {
      {
        "<leader>fp",
        function()
          telescope_project_files(false)
        end,
        desc = "Find files",
      },
      {
        "<leader>fo",
        function()
          require("telescope.builtin").buffers({
            sort_mru = true,
            ignore_current_buffer = true,
          })
        end,
        desc = "Find open buffers",
      },
      {
        "<leader>/",
        function()
          telescope_live_grep(false)
        end,
        desc = "Live grep",
      },
    },
    opts = function()
      local actions = require("telescope.actions")

      return {
        defaults = {
          prompt_prefix = "  ",
          selection_caret = "> ",
          path_display = { "truncate" },
          mappings = {
            i = {
              ["<C-h>"] = "which_key",
              ["<C-j>"] = actions.move_selection_next,
              ["<C-k>"] = actions.move_selection_previous,
              ["<C-q>"] = actions.smart_send_to_qflist + actions.open_qflist,
            },
            n = {
              ["q"] = actions.close,
              ["j"] = actions.move_selection_next,
              ["k"] = actions.move_selection_previous,
              ["<C-q>"] = actions.smart_send_to_qflist + actions.open_qflist,
            },
          },
        },
        pickers = {
          buffers = {
            sort_mru = true,
            ignore_current_buffer = true,
          },
        },
      }
    end,
    config = function(_, opts)
      local telescope = require("telescope")
      telescope.setup(opts)
      pcall(telescope.load_extension, "fzf")
    end,
  },
  {
    "petertriho/nvim-scrollbar",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
      show = true,
      show_in_active_only = true,
      hide_if_all_visible = true,
      set_highlights = false,
      handle = {
        text = "▌",
        blend = 0,
        color = mocha.surface2,
        hide_if_all_visible = true,
      },
      marks = {
        Cursor = { text = "▌", color = mocha.blue },
        Search = { text = { "─", "═" }, color = mocha.mauve },
        Error = { text = { "─", "═" }, color = mocha.red },
        Warn = { text = { "─", "═" }, color = mocha.yellow },
        Info = { text = { "─", "═" }, color = mocha.blue },
        Hint = { text = { "─", "═" }, color = mocha.green },
        Misc = { text = { "─", "═" }, color = mocha.peach },
      },
      excluded_buftypes = {
        "terminal",
      },
      handlers = {
        cursor = true,
        diagnostic = true,
        gitsigns = false,
        handle = true,
        search = false,
        ale = false,
      },
    },
    config = function(_, opts)
      require("scrollbar").setup(opts)
      apply_editor_chrome()

      local function sync_scrollbar_for_wrap()
        local scrollbar_config = require("scrollbar.config").get()
        scrollbar_config.show = not vim.wo.wrap
        require("scrollbar").render()
      end

      local scrollbar_wrap_group = vim.api.nvim_create_augroup("editor_scrollbar_wrap", { clear = true })
      vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "VimResized" }, {
        group = scrollbar_wrap_group,
        callback = sync_scrollbar_for_wrap,
      })
      vim.api.nvim_create_autocmd("OptionSet", {
        group = scrollbar_wrap_group,
        pattern = "wrap",
        callback = function()
          vim.schedule(sync_scrollbar_for_wrap)
        end,
      })
      sync_scrollbar_for_wrap()
    end,
  },
}, {
  change_detection = {
    notify = false,
  },
})

vim.api.nvim_create_autocmd("ColorScheme", {
  callback = apply_editor_chrome,
})

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
  command = "checktime",
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
vim.opt.linebreak = true
vim.opt.breakindent = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.cursorline = true
vim.opt.scrolloff = 8
vim.opt.autoread = true
vim.opt.laststatus = 2
vim.opt.ruler = false
vim.opt.fillchars = {
  eob = " ",
  horiz = "-",
  horizdown = "+",
  horizup = "+",
  vert = "|",
  vertleft = "+",
  vertright = "+",
  verthoriz = "+",
}

local function editor_window_id()
  local winid = vim.g.statusline_winid
  if type(winid) ~= "number" or winid == 0 or not vim.api.nvim_win_is_valid(winid) then
    winid = vim.api.nvim_get_current_win()
  end

  return winid
end

local function left_truncate(text, max_width)
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end

  local prefix = "..."
  local target = math.max(0, max_width - vim.fn.strdisplaywidth(prefix))
  local truncated = text
  while vim.fn.strdisplaywidth(truncated) > target and truncated ~= "" do
    truncated = vim.fn.strcharpart(truncated, 1)
  end

  return prefix .. truncated
end

local function escape_statusline(text)
  return text:gsub("%%", "%%%%")
end

function _G.EditorStatusline()
  local winid = editor_window_id()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local path = name ~= "" and vim.fn.fnamemodify(name, ":.") or "[No Name]"
  if path == "" then
    path = "[No Name]"
  end

  local modified = vim.bo[bufnr].modified and " +" or ""
  local width = vim.api.nvim_win_get_width(winid)
  local max_path_width = math.max(10, math.floor(width / 2))
  local label = " " .. left_truncate(path, max_path_width) .. modified .. " "
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local position = " " .. math.max(cursor[1], 1) .. ":" .. (cursor[2] + 1) .. " "
  local fill = math.max(0, width - vim.fn.strdisplaywidth(label) - vim.fn.strdisplaywidth(position))

  return "%#EditorRule#"
    .. escape_statusline(label)
    .. "%#EditorRuleLine#"
    .. string.rep("─", fill)
    .. "%#EditorRule#"
    .. escape_statusline(position)
end

vim.opt.winbar = ""

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

-- Bottom editor rule: relative path, divider, and cursor position.
vim.opt.statusline = "%!v:lua.EditorStatusline()"
