local M = {}

local reader_states = {}
local insert_keys = { "i", "I", "a", "A", "o", "O" }

local function is_markdown_buffer()
  return vim.bo.filetype == "markdown" or vim.b.md_render == true
end

local function reader_state()
  local bufnr = vim.api.nvim_get_current_buf()
  local source = vim.b[bufnr].dotfiles_md_reader_source or bufnr
  return reader_states[source], source
end

local function disable_reader()
  local state, source = reader_state()
  if not state then
    return false
  end

  pcall(vim.api.nvim_del_augroup_by_id, state.group)
  if vim.api.nvim_buf_is_valid(state.render) then
    pcall(vim.keymap.del, "x", "y", { buffer = state.render })
    for _, key in ipairs(insert_keys) do
      pcall(vim.keymap.del, "n", key, { buffer = state.render })
    end
    vim.b[state.render].dotfiles_md_reader_source = nil
  end
  if vim.api.nvim_buf_is_valid(source) then
    vim.b[source].dotfiles_md_reader_enabled = nil
  end

  if vim.api.nvim_get_current_buf() == state.render then
    require("md-render").preview.toggle()
  end
  reader_states[source] = nil
  return true
end

local function enable_reader()
  local preview = require("md-render").preview

  -- Clear the plugin's experimental timer-based auto mode if it survived a
  -- configuration reload, then use the event-driven reader mode below.
  preview.auto_off()
  if vim.b.md_render == true then
    preview.toggle()
  end

  local source = vim.api.nvim_get_current_buf()
  preview.toggle()

  local render = vim.api.nvim_get_current_buf()
  local group = vim.api.nvim_create_augroup("dotfiles_md_reader_" .. source, { clear = true })
  local state = { source = source, render = render, group = group }
  reader_states[source] = state
  vim.b[source].dotfiles_md_reader_enabled = true
  vim.b[render].dotfiles_md_reader_source = source
  vim.keymap.set("x", "y", function() require("markdown_source").yank() end,
    { buffer = render, silent = true, desc = "Yank raw Markdown source" })

  for _, key in ipairs(insert_keys) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_get_current_buf() ~= render then
        return
      end
      local mapping = require("markdown_source")
      local session = mapping.session()
      if not session then return end
      local cursor = vim.api.nvim_win_get_cursor(0)
      local target = mapping.position(session, cursor[1], cursor[2])
      preview.toggle()
      if target then vim.api.nvim_win_set_cursor(0, target) end
      vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
    end, {
      buffer = render,
      noremap = true,
      silent = true,
      desc = "Markdown reader: edit source with " .. key,
    })
  end

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    buffer = source,
    callback = function()
      if not reader_states[source] or vim.api.nvim_get_current_buf() ~= source then
        return
      end

      local old_mode = vim.v.event.old_mode or ""
      local new_mode = vim.v.event.new_mode or ""
      local left_insert = old_mode:sub(1, 1) == "i" and new_mode:sub(1, 1) ~= "i"
      local temporary_normal = new_mode:sub(1, 2) == "ni"
      if left_insert and not temporary_normal then
        local screen_row = vim.fn.winline()
        local source_cursor = vim.api.nvim_win_get_cursor(0)
        preview.toggle()
        local mapping = require("markdown_source")
        local session = mapping.session()
        if session then
          require("markdown_view").restore(session, vim.api.nvim_get_current_win(), {
            source = source_cursor, screen_row = screen_row,
          })
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = source,
    once = true,
    callback = function()
      reader_states[source] = nil
    end,
  })
end

function M.toggle_reader()
  if not is_markdown_buffer() then
    vim.notify("Markdown reader is only available in Markdown buffers", vim.log.levels.WARN)
    return
  end

  local peek = package.loaded.peek
  if peek and peek.is_open() then
    peek.close()
  end

  if not disable_reader() then
    enable_reader()
  end
end

function M.toggle_web()
  local peek = require("peek")
  if peek.is_open() then
    peek.close()
    return
  end

  if not disable_reader() and vim.b.md_render == true then
    require("md-render").preview.toggle()
  end

  if not is_markdown_buffer() then
    vim.notify("Markdown web preview is only available in Markdown buffers", vim.log.levels.WARN)
    return
  end

  peek.open()
end

return M
