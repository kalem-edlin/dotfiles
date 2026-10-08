-- Source navigation/copy for the pinned md-render.nvim reader. Its public
-- content has line ownership, but no column map. Align only the owning block,
-- never the entire document, and refuse character yanks on generated content.
local M = {}

function M.setup(plugin_dir)
  if M.installed then return end
  assert(not package.loaded["md-render.content_builder"], "Source-map fix must load before md-render")
  M.installed = true
  -- Guarded compatibility patch for v3.8.3. Diagram replacement removes
  -- text rows without their map entries, shifting every subsequent mapping.
  package.preload["md-render.content_builder"] = function()
    local path = plugin_dir .. "/lua/md-render/content_builder.lua"
    local source = table.concat(vim.fn.readfile(path), "\n")
    local count
    source, count = source:gsub("table%.remove%(self%.lines%)", "table.remove(self.lines)\n              table.remove(self.source_line_map)")
    assert(count == 2, "md-render changed; review the pinned diagram source-map patch")
    for _, label in ipairs({ "Mermaid", "PlantUML" }) do
      local original = 'local header = indent .. "' .. label .. '"'
      local start = source:find(original, 1, true)
      assert(start, "md-render diagram header changed: " .. label)
      source = source:sub(1, start - 1)
        .. "self:set_source_line(src_indices[code_block_id] + source_line_offset)\n            "
        .. source:sub(start)
    end
    source = require("markdown_tables").patch_builder(source)
    return assert(loadstring(source, "@" .. path))()
  end
end

local function tokens(lines, first, last)
  local result, encoded = {}, {}
  for row = first, last do
    local col = 0
    for char in lines[row]:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      result[#result + 1] = { row, col, char }
      encoded[#encoded + 1] = (char:gsub(".", function(c) return string.format("%02x", c:byte()) end))
      col = col + #char
    end
    if row < last then
      result[#result + 1] = { row, col, "\n" }
      encoded[#encoded + 1] = "0a"
    end
  end
  return result, table.concat(encoded, "\n") .. "\n"
end

function M.block(session, row)
  local map = session.content.source_line_map
  local owner = map[row]
  if not owner or owner == 0 then
    for i = row, 1, -1 do if map[i] and map[i] > 0 then owner = map[i]; break end end
  end
  if not owner or owner < 1 then return nil end
  local first, last = row, row
  while first > 1 and (map[first - 1] == owner or map[first - 1] == 0) do first = first - 1 end
  while last < #map and (map[last + 1] == owner or map[last + 1] == 0) do last = last + 1 end
  local finish = #session.source_lines
  for i = last + 1, #map do
    if map[i] > owner then finish = map[i] - 1; break end
  end
  while finish > owner and session.source_lines[finish]:match("^%s*$") do finish = finish - 1 end
  return { first = first, last = last, source_first = owner, source_last = finish }
end

local function match_tokens(source, a, rendered, b)
  local changes = vim.diff(a, b, { result_type = "indices", algorithm = "histogram" })
  local map, ai, bi = {}, 1, 1
  for _, h in ipairs(changes) do
    local sa, sb = h[1] + (h[2] == 0 and 1 or 0), h[3] + (h[4] == 0 and 1 or 0)
    while ai < sa and bi < sb do map[bi] = ai; ai = ai + 1; bi = bi + 1 end
    ai, bi = sa + h[2], sb + h[4]
  end
  while ai <= #source and bi <= #rendered do map[bi] = ai; ai = ai + 1; bi = bi + 1 end
  return map
end

-- Group a wrapped table row by cell before matching. Screen order interleaves
-- columns, whereas source order finishes one cell before starting the next.
local function cell_spans(line, delimiter)
  local borders, offset = {}, 1
  while true do
    local a, b = line:find(delimiter, offset, true)
    if not a then break end
    local escapes = line:sub(1, a - 1):match("\\*$") or ""
    if delimiter ~= "|" or #escapes % 2 == 0 then borders[#borders + 1] = { a, b } end
    offset = b + 1
  end
  if delimiter == "|" and #borders > 0 and line:sub(borders[#borders][2] + 1):match("%S") then
    borders[#borders + 1] = { #line + 1, #line + 1 }
  end
  local spans = {}
  for i = 1, #borders - 1 do
    local first, last = borders[i][2] + 1, borders[i + 1][1] - 1
    local text = line:sub(first, last)
    local leading = #(text:match("^%s*") or "")
    spans[i] = { text = text:match("^%s*(.-)%s*$"), offset = first - 1 + leading }
  end
  return spans
end

local function table_alignment(session, block)
  local is_table = false
  for _, region in ipairs(session.content.expandable_regions or {}) do
    if region.dotfiles_table and block.first <= region.end_line + 1 and block.last > region.start_line then
      is_table = true; break
    end
  end
  if not is_table then return end
  local cells = cell_spans(session.source_lines[block.source_first], "|")
  if #cells == 0 then return end
  local rendered_cells = {}
  for row = block.first, block.last do
    rendered_cells[row] = cell_spans(session.content.lines[row], "│")
    if #rendered_cells[row] ~= #cells then return end
  end
  local source, rendered, map = {}, {}, {}
  for col, cell in ipairs(cells) do
    local cell_source, a = tokens({ cell.text }, 1, 1)
    local lines = {}
    for row = block.first, block.last do lines[#lines + 1] = rendered_cells[row][col].text end
    local cell_rendered, b = tokens(lines, 1, #lines)
    if #cell_source > 12000 or #cell_rendered > 12000 then return end
    local matches = match_tokens(cell_source, a, cell_rendered, b)
    local source_offset, rendered_offset = #source, #rendered
    for _, token in ipairs(cell_source) do
      token[1], token[2] = block.source_first, token[2] + cell.offset
      token[4] = col
      source[#source + 1] = token
    end
    for i, token in ipairs(cell_rendered) do
      local row = block.first + token[1] - 1
      token[1], token[2] = row, token[2] + rendered_cells[row][col].offset
      token[4] = col
      rendered[#rendered + 1] = token
      if matches[i] then map[rendered_offset + i] = source_offset + matches[i] end
    end
  end
  return source, rendered, map
end

local function alignment(session, row)
  local block = M.block(session, row)
  if not block then return end
  local raw = session.source_lines[block.source_first]
  if raw:match("^%s*```%s*mermaid") or raw:match("^%s*~~~%s*mermaid") then
    return block -- An image has no selectable source characters.
  end
  local source, rendered, map = table_alignment(session, block)
  if source then return block, source, rendered, map end
  local a, b
  source, a = tokens(session.source_lines, block.source_first, block.source_last)
  rendered, b = tokens(session.content.lines, block.first, block.last)
  if #source > 12000 or #rendered > 12000 then return block end
  return block, source, rendered, match_tokens(source, a, rendered, b)
end

function M.position(session, row, col, exact)
  local block, source, rendered, map = alignment(session, row)
  if not block then return end
  local closest, distance
  for i, token in ipairs(rendered or {}) do
    if token[1] == row and token[3] ~= "\n" and map[i] then
      local d = math.abs(token[2] - col)
      if not distance or d < distance then closest, distance = source[map[i]], d end
    end
  end
  if closest and (not exact or distance == 0) then return { closest[1], closest[2] }, #closest[3] end
  if not exact then return { block.source_first, 0 }, 1 end
end

function M.render_position(session, row, col)
  local owner, first
  for i, source_row in ipairs(session.content.source_line_map) do
    if source_row > 0 and source_row <= row and (not owner or source_row > owner) then
      owner, first = source_row, i
    end
  end
  if not first then return { 1, 0 } end
  local _, source, rendered, map = alignment(session, first)
  local closest, distance, cell, cell_fallback
  for _, token in ipairs(source or {}) do
    if token[1] == row and token[2] == col then cell = token[4]; break end
  end
  for i, token in ipairs(rendered or {}) do
    local src = map[i] and source[map[i]]
    if cell and token[4] == cell and token[3] ~= "\n" and not cell_fallback then cell_fallback = token end
    if src and token[3] ~= "\n" and (not cell or src[4] == cell) then
      local d = math.abs(src[1] - row) * 1000000 + math.abs(src[2] - col)
      if not distance or d < distance then closest, distance = token, d end
    end
  end
  closest = closest or cell_fallback
  return closest and { closest[1], closest[2] } or { first, 0 }
end

function M.session()
  local session = require("md-render").preview._sessions[vim.api.nvim_get_current_buf()]
  if not session then return end
  local current = vim.api.nvim_buf_get_lines(session.source_bufnr, 0, -1, false)
  if not vim.deep_equal(current, session.source_lines) then
    vim.notify("Markdown source changed; toggle rendering off/on before copying or editing", vim.log.levels.WARN)
    return
  end
  return session
end

local function before(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end

-- Include hidden syntax when a complete inline item is selected, e.g.
-- **bold** or [label](url). A partial selection remains a raw source fragment.
local function expand_inline(session, start, finish, visible)
  local raw = table.concat(session.source_lines, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, raw, "markdown_inline")
  if not ok then return start, finish end
  local kinds = { strong_emphasis = true, emphasis = true, inline_link = true, code_span = true, strikethrough = true, image = true }
  local function visit(node)
    for child in node:iter_children() do visit(child) end
    if not kinds[node:type()] then return end
    local sr, sc, er, ec = node:range()
    local first, last = { sr + 1, sc }, { er + 1, ec }
    local text = vim.treesitter.get_node_text(node, raw)
    local plain = require("md-render").Markdown.render(text)
    if plain == "" then return end
    if not before(start, first) and before(start, last) and visible:sub(1, #plain) == plain then start = first end
    if before(first, finish) and not before(last, finish) and visible:sub(-#plain) == plain then finish = last end
  end
  visit(parser:parse()[1]:root())
  return start, finish
end

function M.selection(session, first, last, mode)
  if before(last, first) then first, last = last, first end
  if mode == "V" then
    local a, b = M.block(session, first[1]), M.block(session, last[1])
    if not a or not b then return nil, "No Markdown source for these lines" end
    return vim.list_slice(session.source_lines, a.source_first, b.source_last), "V"
  end
  if mode ~= "v" then return nil, "Rectangular selections have no raw Markdown equivalent; use v or V" end
  local start = M.position(session, first[1], first[2], true)
  local finish, size = M.position(session, last[1], last[2], true)
  if not start or not finish or before(finish, start) then
    return nil, "Selection touches generated layout or an image; use V to copy its source lines"
  end
  finish[2] = finish[2] + size
  local selected = vim.list_slice(session.content.lines, first[1], last[1])
  selected[#selected] = selected[#selected]:sub(1, last[2] + size)
  selected[1] = selected[1]:sub(first[2] + 1)
  start, finish = expand_inline(session, start, finish, table.concat(selected, "\n"))
  local result = vim.list_slice(session.source_lines, start[1], finish[1])
  result[#result] = result[#result]:sub(1, finish[2])
  result[1] = result[1]:sub(start[2] + 1)
  return result, "v"
end

function M.yank()
  local session = M.session()
  if not session then return end
  local anchor = vim.fn.getpos("v")
  local first, last = { anchor[2], anchor[3] - 1 }, vim.api.nvim_win_get_cursor(0)
  local mode = vim.fn.mode():sub(1, 1)
  if mode == "v" and vim.o.selection == "exclusive" and not vim.deep_equal(first, last) then
    -- Convert the excluded end to the previous complete UTF-8 character.
    local endpoint = before(first, last) and last or first
    local line = session.content.lines[endpoint[1]]:sub(1, endpoint[2])
    local char = line:match("[%z\1-\127\194-\244][\128-\191]*$")
    if char then
      endpoint[2] = endpoint[2] - #char
    elseif endpoint[2] == 0 and endpoint[1] > 1 then
      endpoint[1] = endpoint[1] - 1
      local previous = session.content.lines[endpoint[1]]
      char = previous:match("[%z\1-\127\194-\244][\128-\191]*$")
      endpoint[2] = math.max(0, #previous - #(char or ""))
    end
  end
  local text, kind = M.selection(session, first, last, mode)
  if not text then vim.notify(kind, vim.log.levels.WARN); return end
  local register = vim.v.register
  if register ~= "_" then
    vim.fn.setreg(register, text, kind)
    if register ~= '"' then vim.fn.setreg('"', { points_to = register:lower() }) end
    if register == '"' then
      vim.fn.setreg("0", text, kind)
      if vim.o.clipboard:find("unnamedplus", 1, true) then vim.fn.setreg("+", text, kind)
      elseif vim.o.clipboard:find("unnamed", 1, true) then vim.fn.setreg("*", text, kind) end
    end
  end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "n", false)
end

return M
