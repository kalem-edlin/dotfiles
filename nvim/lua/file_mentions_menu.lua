-- Blink v1's trigger and cached-item filtering assume word completions. An @
-- mention instead spans slashes, punctuation and (when quoted) spaces. Keep
-- its menu alive while fzf refreshes, without exposing stale text edits.
local M = {}

function M.setup()
  local mentions = require("file_mentions")
  local parse = mentions.parse
  local context = require("blink.cmp.completion.trigger.context")
  local trigger = require("blink.cmp.completion.trigger")
  local fuzzy = require("blink.cmp.fuzzy")
  local list = require("blink.cmp.completion.list")
  local menu = require("blink.cmp.completion.windows.menu")
  local loading_timer = vim.uv.new_timer()
  local function is_loading()
    return require("blink.cmp.sources.lib").get_provider_by_id("file_mentions").module.pending ~= nil
  end
  local function clear_loading()
    loading_timer:stop()
    if menu.win:is_open() then
      local title = vim.api.nvim_win_get_config(menu.win:get_win()).title
      if title and #title > 0 then menu.win:set_win_config({ title = "" }) end
    end
  end

  local function token_at_cursor()
    if not vim.api.nvim_get_mode().mode:match("^i") or not mentions.is_enabled(0) then return end
    return parse(context.get_line(), context.get_cursor()[2])
  end

  -- Blink also refreshes contexts after ignored cursor events (selection and
  -- acceptance). Those events must still dismiss a mention that was removed.
  local trigger_show = trigger.show
  trigger.show = function(opts)
    if not token_at_cursor() then return trigger.hide() end
    return trigger_show(opts)
  end

  -- Treat all characters inside a mention as query input. Outside mentions,
  -- Blink retains its normal trigger rules and the source returns no items.
  local is_keyword_character = fuzzy.is_keyword_character
  fuzzy.is_keyword_character = function(char)
    return token_at_cursor() ~= nil or is_keyword_character(char)
  end

  local get_bounds = context.get_bounds
  context.get_bounds = function(range)
    local token = token_at_cursor()
    if not token then return get_bounds(range) end
    local cursor = context.get_cursor()
    return {
      line = context.get_line(), line_number = cursor[1],
      start_col = token.start_col + 1, length = cursor[2] - token.start_col,
    }
  end

  local within_query_bounds = context.within_query_bounds
  context.within_query_bounds = function(self, cursor, include_start_bound)
    if self.bounds.line:sub(self.bounds.start_col, self.bounds.start_col) == "@" then
      local token = token_at_cursor()
      return token ~= nil and cursor[1] == self.bounds.line_number
        and token.start_col + 1 == self.bounds.start_col
    end
    return within_query_bounds(self, cursor, include_start_bound)
  end

  local function status(ctx, label)
    -- This row belongs only to the renderer, never to the completion list.
    -- Selection and acceptance therefore cannot insert it into the buffer.
    menu.open_with_items(ctx, { {
      label = label, kind = vim.lsp.protocol.CompletionItemKind.Text,
      kind_name = "", kind_icon = "", kind_hl = "", source_id = "file_mentions",
      source_name = "Files", cursor_column = ctx.cursor[2], score = 0,
    } })
    menu.set_selected_item_idx(nil)
  end

  local close = menu.close
  menu.close = function()
    clear_loading()
    if trigger.context and token_at_cursor() then
      status(trigger.context, "No matches")
    else
      close()
    end
  end

  local show = list.show
  list.show = function(ctx, items_by_source)
    local active = trigger.context
    -- Blink schedules responses and only checks the context ID. A newer edit
    -- can share that ID, so also reject responses for an older line/cursor.
    if not active or ctx.line ~= active.line or not vim.deep_equal(ctx.cursor, active.cursor) then return end
    local token = token_at_cursor()
    if not token then
      list.hide()
      return
    end
    local items = items_by_source.file_mentions or {}
    if is_loading() or (#items > 0 and items[1].filterText ~= ctx.line:sub(1, ctx.cursor[2])) then
      list.context, list.items, list.selected_item_idx = ctx, {}, nil
      list.is_explicitly_selected = false
      menu.set_selected_item_idx(nil)
      -- Keep the existing rows during the refresh, but make them unselectable.
      return
    end
    clear_loading()
    show(ctx, items_by_source)
  end

  -- Acceptance is scheduled independently of TextChangedI. Check the actual
  -- buffer too, covering a quick edit followed immediately by Tab or Enter.
  local accept = list.accept
  list.accept = function(opts)
    local item = list.items[(opts and opts.index) or list.selected_item_idx]
    local cursor = context.get_cursor()
    if not token_at_cursor() or not item or not list.context
      or list.context.bufnr ~= vim.api.nvim_get_current_buf()
      or list.context.cursor[1] ~= cursor[1]
      or item.filterText ~= context.get_line():sub(1, cursor[2]) then
      return false
    end
    -- Accepting a directory continues the mention, so search inside it
    -- immediately instead of closing the menu.
    if item.label:sub(-1) ~= "/" then return accept(opts) end
    local done = opts and opts.callback
    return accept(vim.tbl_extend("force", opts or {}, { callback = function()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      -- A quoted directory is inserted balanced; reopen it before the quote.
      if vim.api.nvim_get_current_line():sub(col, col) == '"' and not token_at_cursor() then
        vim.api.nvim_win_set_cursor(0, { row, col - 1 })
      end
      if token_at_cursor() then trigger.show({ trigger_kind = "manual", force = true }) end
      if done then done() end
    end }))
  end

  -- Disable old selections as soon as an edit starts, before any scheduled
  -- cached response or user acceptance can apply an obsolete text-edit range.
  trigger.show_emitter:on(function(event)
    if not token_at_cursor() then
      trigger.hide()
      return
    end
    clear_loading()
    local ctx = event.context
    -- A delayed, static label avoids animating on every keystroke. Keep the
    -- existing rows and dimensions while a slow search is in progress.
    loading_timer:start(150, 0, vim.schedule_wrap(function()
      local active = trigger.context
      if not active or active.line ~= ctx.line or not vim.deep_equal(active.cursor, ctx.cursor)
        or not token_at_cursor() or not is_loading() then return end
      if menu.win:is_open() then
        menu.win:set_win_config({ title = " Searching... ", title_pos = "center" })
      else
        status(ctx, "Searching...")
      end
    end))
    local item = list.items[1]
    if item and item.filterText ~= event.context.line:sub(1, event.context.cursor[2]) then
      list.items, list.selected_item_idx = {}, nil
      list.is_explicitly_selected = false
      menu.set_selected_item_idx(nil)
    end
  end)
  trigger.hide_emitter:on(clear_loading)
end

return M
