-- nvim --headless -u NONE -l nvim/tests/web_preview.lua
package.path = vim.fn.getcwd() .. "/nvim/lua/?.lua;" .. package.path
local preview = require("web_preview")
local directory = vim.fn.tempname() .. " web #preview"
vim.fn.mkdir(directory, "p")
local opened, warnings, queries, markdown = {}, {}, 0, 0
local original = { open = vim.ui.open, notify = vim.notify, system = vim.system, has = vim.fn.has }
local mac, browser_error, open_error = true, false, false
vim.notify = function(message) warnings[#warnings + 1] = message end
vim.ui.open = function(uri, opts)
  opened[#opened + 1] = { uri = uri, opts = opts }
  if open_error then return nil, "test launch failure" end
  return {}
end
vim.fn.has = function(feature)
  if feature == "mac" then return mac and 1 or 0 end
  return original.has(feature)
end
vim.system = function(command)
  assert(command[1] == "osascript" and command[3] == "JavaScript")
  queries = queries + 1
  return { wait = function()
    return browser_error and { code = 1, stderr = "test browser failure" }
      or { code = 0, stdout = "/Applications/Test Browser.app\n" }
  end }
end
package.loaded.markdown_render = { toggle_web = function() markdown = markdown + 1 end }

local function buffer(name, filetype)
  vim.cmd("enew!")
  if name then
    local path = directory .. "/" .. name
    vim.fn.writefile({ "<h1>Preview</h1>" }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
  end
  vim.bo.filetype = filetype or ""
end
local function rejects(fragment)
  local count, notices = #opened, #warnings
  preview.open()
  assert(#opened == count and #warnings == notices + 1)
  assert(warnings[#warnings]:find(fragment, 1, true), warnings[#warnings])
end

local ok, err = xpcall(function()
  for _, name in ipairs({ "page.html", "page.htm", "page.xhtml", "image.svg", "doc.xml", "doc.pdf",
    "image.PNG", "image.jpg", "image.webp", "image.avif", "audio.mp3", "video.webm", "video.mp4" }) do
    buffer(name)
    local count = #opened
    preview.open()
    assert(#opened == count + 1, name .. " did not open")
    assert(vim.uri_to_fname(opened[#opened].uri) == vim.api.nvim_buf_get_name(0), "URL round trip failed")
    assert(vim.deep_equal(opened[#opened].opts.cmd, { "open", "-a", "/Applications/Test Browser.app" }))
  end
  buffer("extensionless", "html")
  preview.open()
  assert(vim.uri_to_fname(opened[#opened].uri) == vim.api.nvim_buf_get_name(0))

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "<h1>Unsaved</h1>" })
  rejects("Save this buffer")
  assert(vim.fn.readfile(vim.api.nvim_buf_get_name(0))[1] == "<h1>Preview</h1>", "preview silently saved edits")
  buffer(nil, "html")
  rejects("Save this buffer")
  buffer("deleted.html")
  vim.fn.delete(vim.api.nvim_buf_get_name(0))
  rejects("Save this buffer")
  buffer("special.html")
  vim.bo.buftype = "nofile"
  rejects("Save this buffer")

  for _, name in ipairs({ "source.lua", "component.tsx", "component.jsx", "component.vue", "style.css" }) do
    buffer(name)
    rejects("No standalone web preview")
  end
  assert(package.loaded.peek == nil, "non-Markdown preview loaded Peek")

  buffer(nil, "markdown")
  preview.open()
  assert(markdown == 1, "Markdown did not retain its preview toggle")
  vim.bo.filetype = ""
  vim.b.md_render = true
  preview.open()
  assert(markdown == 2, "Markdown reader did not delegate to the preview toggle")
  vim.b.md_render = nil

  buffer("error.html")
  browser_error = true
  rejects("test browser failure")
  browser_error = false
  open_error = true
  preview.open()
  assert(warnings[#warnings]:find("test launch failure", 1, true))
  open_error = false

  mac = false
  local count = queries
  preview.open()
  assert(queries == count and opened[#opened].opts.cmd == nil, "non-Mac opener used macOS commands")
end, debug.traceback)
vim.ui.open, vim.notify, vim.system, vim.fn.has = original.open, original.notify, original.system, original.has
vim.cmd("enew!")
vim.fn.delete(directory, "rf")
assert(ok, err)
print("PASS: browser formats, escaped paths, saved-file guards, Markdown delegation, launch errors")
