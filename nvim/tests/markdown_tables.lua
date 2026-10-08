-- nvim --headless -u NONE -l nvim/tests/markdown_tables.lua
package.path = vim.fn.getcwd() .. "/nvim/lua/?.lua;" .. package.path
local plugin = vim.fn.stdpath("data") .. "/lazy/md-render.nvim"
vim.opt.rtp:append(plugin)
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/site")
local tables = require("markdown_tables")
tables.setup(plugin)
require("markdown_source").setup(plugin)
require("markdown_view").setup(plugin)
local preview = require("md-render").preview
local source = {
  "| Criterion | Short | Verbose | Third |", "| --- | --- | --- | --- |",
  "| LABEL | yes | " .. string.rep("description ", 15) .. " | no |",
  "| SPLIT | abcdefghijklmnopqrstuvwxyz | [link](./relative.md) | `my_identifier` |",
}
local function render(state)
  return preview.build_content(source, { max_width = 70, expand_state = { [1] = state } })
end
local compact, equal, proportional = render(false), render("equal"), render("proportional")
assert(compact.expandable_regions[1].dotfiles_table)
assert(equal.expandable_regions[1].expanded == "equal")
assert(proportional.expandable_regions[1].expanded == "proportional")
assert(not vim.deep_equal(equal.lines, proportional.lines), "profiles have identical layout")
local widths = tables.equal_widths({ 9, 5, 180, 14 }, "  ", 70)
assert(math.abs(widths[2] - widths[3]) <= 1 and math.abs(widths[3] - widths[4]) <= 1)
for _, content in ipairs({ equal, proportional }) do
  for _, line in ipairs(content.lines) do
    assert(vim.api.nvim_strwidth(line) <= 70, "table exceeds available width: " .. line)
  end
  assert(table.concat(content.lines, "\n"):find("↪", 1, true), "missing forced-wrap marker")
end
local wraps = tables.wrap("abcdefghijklmnopqrstuvwxyz", 7)
local restored = {}
for _, wrap in ipairs(wraps) do
  local plain = wrap.text:sub(1, wrap.source_bytes or #wrap.text)
  assert(plain == ("abcdefghijklmnopqrstuvwxyz"):sub(wrap.byte_start + 1, wrap.byte_start + #plain))
  assert(vim.api.nvim_strwidth(wrap.text) <= 7)
  restored[#restored + 1] = plain
end
assert(table.concat(restored) == "abcdefghijklmnopqrstuvwxyz", "forced wrap lost text")
for _, wrap in ipairs(tables.wrap("one two three", 7)) do
  assert(not wrap.continuation, "ordinary word wrap was marked as a split word")
end
for _, wrap in ipairs(tables.wrap("éééééééé", 4)) do
  assert(vim.api.nvim_strwidth(wrap.text) <= 4, "Unicode wrap exceeds column")
end
local cjk = {}
for _, wrap in ipairs(tables.wrap("日本語日本語", 2)) do
  assert(vim.api.nvim_strwidth(wrap.text) <= 2)
  cjk[#cjk + 1] = wrap.text:sub(1, wrap.source_bytes or #wrap.text)
end
assert(table.concat(cjk) == "日本語日本語")
local map = require("markdown_source")
local session = { source_lines = source, content = equal }
local first = map.render_position(session, 4, source[4]:find("abcdefghijklmnopqrstuvwxyz", 1, true) - 1)
local last = map.render_position(session, 4, source[4]:find("abcdefghijklmnopqrstuvwxyz", 1, true) + 24)
local copied = map.selection(session, first, last, "v")
assert(copied and table.concat(copied, "\n") == "abcdefghijklmnopqrstuvwxyz",
  vim.inspect({ copied = copied, first = first, last = last, lines = equal.lines }))
for _, content in ipairs({ equal, proportional }) do
  session.content = content
  for col = source[4]:find("abcdefghijklmnopqrstuvwxyz", 1, true) - 1,
    source[4]:find("abcdefghijklmnopqrstuvwxyz", 1, true) + 24 do
    local rendered = map.render_position(session, 4, col)
    assert(vim.deep_equal(map.position(session, rendered[1], rendered[2]), { 4, col }), "cell character failed round trip")
  end
end
-- Small tables still expose the cycle even when compact has no ellipsis.
local small = preview.build_content({ "| A | B |", "| - | - |", "| x | y |" }, { max_width = 80 })
assert(small.expandable_regions[1].dotfiles_table)
print("PASS: table profiles, widths, continuation markers, raw source yanks, small tables")
