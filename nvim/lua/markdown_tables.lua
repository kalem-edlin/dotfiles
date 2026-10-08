-- Table-only compatibility layer for md-render.nvim v3.8.3.
local M = {}
local marker = "↪"

local function replace(source, old, new, expected)
  local count, offset = 0, 1
  while true do
    local a, b = source:find(old, offset, true)
    if not a then break end
    source = source:sub(1, a - 1) .. new .. source:sub(b + 1)
    count, offset = count + 1, a + #new
  end
  assert(count == expected, "md-render changed; review table patch: " .. old)
  return source
end

function M.equal_widths(natural, indent, max_width)
  local n = #natural
  local border = vim.api.nvim_strwidth("│")
  local budget = math.max(2 * n, max_width - vim.api.nvim_strwidth(indent) - (border + 2) * n - border)
  if n == 1 then return { budget } end
  -- Content-sized labels, capped at a quarter of the available cell space
  -- or one equal share, whichever is larger. All comparison columns equal.
  local label_cap = math.max(math.floor(budget / n), math.floor(budget / 4))
  local label = math.max(2, math.min(natural[1], label_cap))
  local result, available = { label }, budget - label
  for i = 2, n do
    result[i] = math.floor(available / (n - 1)) + (i - 2 < available % (n - 1) and 1 or 0)
  end
  return result
end

-- Retain upstream's word/CJK breaking. Only oversized segments need forced
-- splitting. Every such split reserves a cell for a display-only marker.
function M.wrap(text, width)
  local lines, starts = require("md-render.wrap").wrap_words(text, width)
  local result = {}
  for i, line in ipairs(lines) do
    local offset = 0
    while vim.api.nvim_strwidth(line) > width do
      local count, cells = 0, 0
      for _, char in ipairs(vim.fn.split(line, "\\zs")) do
        local size = vim.api.nvim_strwidth(char)
        if cells + size > math.max(1, width - vim.api.nvim_strwidth(marker)) then break end
        count, cells = count + #char, cells + size
      end
      local continuation = true
      if count == 0 then
        -- A two-cell CJK glyph can fill a two-cell column by itself. Keep
        -- the glyph rather than replacing the rest of its text with ellipsis.
        local first = vim.fn.split(line, "\\zs")[1]
        if not first or vim.api.nvim_strwidth(first) > width then break end
        count, continuation = #first, false
      end
      result[#result + 1] = { text = line:sub(1, count) .. (continuation and marker or ""),
        byte_start = starts[i] + offset, source_bytes = count, continuation = continuation }
      line, offset = line:sub(count + 1), offset + count
    end
    result[#result + 1] = { text = line, byte_start = starts[i] + offset }
  end
  return result
end

function M.advance(session, block_id, fallback)
  for _, region in ipairs(session.content.expandable_regions) do
    if region.block_id == block_id and region.dotfiles_table then
      local state = session.expand_state[block_id]
      local next_state = not state and "equal" or state == "equal" and "proportional" or false
      local win = vim.api.nvim_get_current_win()
      local anchors = require("markdown_view").capture_all(session)
      local cursor = vim.api.nvim_win_get_cursor(win)
      local previous = session._table_cycle
      if previous and previous.block_id == block_id and previous.win == win
        and vim.deep_equal(previous.cursor, cursor)
        and previous.screen_row == vim.fn.winline()
        and previous.changedtick == vim.api.nvim_buf_get_changedtick(session.source_bufnr) then
        anchors[win] = previous.anchor
      end
      -- Save values, not extmark IDs, which the rebuild adapter replaces.
      local anchor = anchors[win] and vim.deepcopy(anchors[win])
      if anchor then anchor.mark = nil end
      session._table_cycle_pending = { win = win, block_id = block_id, anchor = anchor,
        changedtick = vim.api.nvim_buf_get_changedtick(session.source_bufnr) }
      vim.api.nvim_echo({ { "Table: " .. (next_state or "compact"), "ModeMsg" } }, false, {})
      return next_state
    end
  end
  return fallback
end

function M.after_rebuild(session)
  local pending = session._table_cycle_pending
  session._table_cycle_pending = nil
  if not pending or not pending.anchor then return end
  require("markdown_view").restore(session, pending.win, pending.anchor)
  pending.cursor = vim.api.nvim_win_get_cursor(pending.win)
  pending.screen_row = vim.fn.winline()
  session._table_cycle = pending
end

function M.patch_builder(source)
  if not M.enabled then return source end
  source = replace(source, "if has_truncation or tbl_expanded then\n        table.insert",
    "if true then -- Every pipe table supports the three viewing profiles.\n        table.insert", 1)
  return replace(source, "block_id = table_buf_start_idx,",
    "block_id = table_buf_start_idx,\n          dotfiles_table = true,", 1)
end

function M.patch_preview(source)
  if not M.enabled then return source end
  source = replace(source, "self.expand_state[block_id] = expanded",
    'self.expand_state[block_id] = require("markdown_tables").advance(self, block_id, expanded)', 1)
  return replace(source, "session.expand_state[region.block_id] = not region.expanded",
    'session.expand_state[region.block_id] = require("markdown_tables").advance(session, region.block_id, not region.expanded)', 1)
end

function M.setup(plugin_dir)
  M.enabled = true
  assert(not package.loaded["md-render.markdown_table"], "Table adapter must load before md-render")
  package.preload["md-render.markdown_table"] = function()
    local path = plugin_dir .. "/lua/md-render/markdown_table.lua"
    local source = table.concat(vim.fn.readfile(path), "\n")
    local a = assert(source:find("local function wrap_cell_text(", 1, true))
    local b = assert(source:find("--- Truncate text", a, true))
    source = source:sub(1, a - 1) .. 'local function wrap_cell_text(text, width)\n'
      .. '  return require("markdown_tables").wrap(text, width)\nend\n\n' .. source:sub(b)
    source = replace(source, "  -- When expanded, ensure minimum column width",
      '  if expanded == "equal" and max_width then\n'
        .. '    col_widths = require("markdown_tables").equal_widths(parsed_table.col_widths, indent, max_width)\n'
        .. '  end\n\n  -- When expanded, ensure minimum column width', 1)
    source = replace(source, "local kept_byte_len = #display_text",
      "local kept_byte_len = wrap and wrap.source_bytes or #display_text", 1)
    source = replace(source, "        byte_pos = byte_pos + #padded",
      '        if wrap and wrap.continuation then\n'
        .. '          table.insert(hls, { col = cell_start + kept_byte_len,\n'
        .. '            end_col = cell_start + #display_text, hl = "NonText" })\n'
        .. '        end\n\n        byte_pos = byte_pos + #padded', 1)
    return assert(loadstring(source, "@" .. path))()
  end
end

return M
