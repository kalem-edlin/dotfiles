-- nvim --headless -u NONE -l nvim/tests/md_render_tmux.lua
package.path = vim.fn.getcwd() .. "/nvim/lua/?.lua;" .. package.path
local transport = require("md_render_tmux").transport
local e = string.char(27)
local packets, visible = {}, true
local write, clear = transport(function(data) packets[#packets + 1] = data end,
  function() return { left = 42, top = 3, visible = true } end,
  function() return visible end, 100000)
local function decoded()
  local result = {}
  for _, data in ipairs(packets) do
    assert(data:sub(1, 7) == e .. "Ptmux;", "missing passthrough prefix")
    result[#result + 1] = data:sub(8, -3):gsub(e .. e, e)
  end
  packets = {}
  return table.concat(result)
end
write(e .. "[s" .. e .. "[2;4H" .. e .. "_Ga=T,f=100,t=f,i=101;YWJj" .. e .. "\\" .. e .. "[u")
local output = decoded()
assert(output:find(e .. "[5;46H", 1, true), "split-pane coordinates not translated")
assert(output:find("i=100101", 1, true), "image IDs not namespaced")
visible = false
write(e .. "_Ga=T,f=100,t=f,i=101;YWJj" .. e .. "\\")
assert(decoded() == "", "background redraw leaked")
clear(false)
assert(decoded():find("a=d,d=i,i=100101", 1, true), "focus loss must clear only owned placements")
write(e .. "_Ga=d,d=A" .. e .. "\\")
output = decoded()
assert(output:find("a=d,d=I,i=100101", 1, true), "global deletion not scoped")
assert(not output:find("d=A", 1, true), "global deletion escaped")
visible = true
write(e .. "_Ga=d,d=a,i=101,q=2" .. e .. "\\")
assert(decoded():find("a=d,d=i,i=100101", 1, true), "placement cleanup affects other panes")
print("PASS: wrapping, split offsets, background suppression, owned image cleanup")
