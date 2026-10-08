-- nvim --headless -u NONE -l nvim/tests/markdown_source.lua
package.path = vim.fn.getcwd() .. "/nvim/lua/?.lua;" .. package.path
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/md-render.nvim")
-- Load parsers installed by nvim-treesitter without the full configuration.
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/site")
local mapping = require("markdown_source")
mapping.setup(vim.fn.stdpath("data") .. "/lazy/md-render.nvim")
local md = require("md-render")
local source = {
  "# Heading", "", "A **bold** word and a [label](./file.md).", "",
  "Unicode café and repeated repeated words keep their positions even when this paragraph wraps across several rendered rows.",
  "", "| Name | Value |", "| --- | --- |", "| one | two |", "",
  "```mermaid", "graph LR; A-->B", "```", "", "After the diagram.",
}
local builder = md.ContentBuilder.new()
builder:render_document(source, { max_width = 40, text_scale = false })
local session = { source_lines = source, content = builder:result() }
assert(#session.content.lines == #session.content.source_line_map, "diagram replacement corrupted the source map")
local function find(text)
  for row, line in ipairs(session.content.lines) do
    local col = line:find(text, 1, true)
    if col then return { row, col - 1 } end
  end
  error("Missing rendered text: " .. text)
end
local function yank(text, expected)
  local a = find(text)
  local b = { a[1], a[2] + #text - 1 }
  local got, kind = mapping.selection(session, a, b, "v")
  assert(got and table.concat(got, "\n") == expected, vim.inspect({ text = text, got = got, kind = kind }))
end
yank("bold", "**bold**")
yank("ol", "ol")
yank("label", "[label](./file.md)")
local bold = find("bold")
assert(vim.deep_equal(mapping.position(session, bold[1], bold[2]), { 3, 4 }))
local last = find("rows.")
local expected = assert(source[5]:find("rows.", 1, true)) - 1
assert(vim.deep_equal(mapping.position(session, last[1], last[2]), { 5, expected }), "wrapped cursor lost source position")
assert(vim.deep_equal(mapping.render_position(session, 5, expected), last), "return chose the first wrapped row instead of the source character")
local heading = find("Heading")
local lines, kind = mapping.selection(session, heading, heading, "V")
assert(kind == "V" and vim.deep_equal(lines, { "# Heading" }))
local diagram = find("Mermaid")
assert(vim.deep_equal(mapping.position(session, diagram[1], 0), { 11, 0 }))
lines, kind = mapping.selection(session, diagram, diagram, "V")
assert(vim.deep_equal(lines, { "```mermaid", "graph LR; A-->B", "```" }), vim.inspect(lines))
local no_text = mapping.selection(session, diagram, diagram, "v")
assert(no_text == nil, "image should not claim an exact character mapping")
assert(mapping.selection(session, heading, heading, string.char(22)) == nil)
local reversed = mapping.selection(session, { bold[1], bold[2] + 3 }, bold, "v")
assert(vim.deep_equal(reversed, { "**bold**" }))
local after = find("After the diagram.")
assert(vim.deep_equal(mapping.position(session, after[1], after[2]), { 15, 0 }), "cursor drift after diagram")
print("PASS: raw inline/line/block yanks; partial selections; wrapped cursor mapping; diagram fallback")
