local M = {}

-- Standalone formats browsers can render without a build step or app server.
local extensions = {
  html = true, htm = true, xhtml = true, svg = true, xml = true,
  pdf = true, png = true, jpg = true, jpeg = true, gif = true,
  webp = true, avif = true, bmp = true, ico = true,
  mp3 = true, wav = true, ogg = true, flac = true, m4a = true,
  mp4 = true, webm = true, ogv = true, mov = true,
}
local filetypes = { html = true, xhtml = true, svg = true, xml = true }

local function warn(message)
  vim.notify(message, vim.log.levels.WARN)
end

function M.open()
  if vim.bo.filetype == "markdown" or vim.b.md_render == true then
    require("markdown_render").toggle_web()
    return
  end

  local path = vim.api.nvim_buf_get_name(0)
  local extension = vim.fn.fnamemodify(path, ":e"):lower()
  if not extensions[extension] and not filetypes[vim.bo.filetype] then
    warn("No standalone web preview for this file type. App components need a running dev server.")
    return
  end
  if vim.bo.buftype ~= "" or path == "" or vim.fn.filereadable(path) ~= 1 or vim.bo.modified then
    warn("Save this buffer to a local file before opening its web preview.")
    return
  end

  local opts = {}
  if vim.fn.has("mac") == 1 then
    -- Opening a file URL normally uses its file association, which may be
    -- Neovim or Preview. Explicitly target the default HTTPS browser instead.
    local browser = vim.system({ "osascript", "-l", "JavaScript", "-e", [[
      ObjC.import('AppKit');
      $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL(
        $.NSURL.URLWithString('https://example.com')
      ).path.js;
    ]] }, { text = true }):wait()
    local app = vim.trim(browser.stdout or "")
    if browser.code ~= 0 or app == "" then
      warn("Could not find the default web browser: " .. vim.trim(browser.stderr or ""))
      return
    end
    opts.cmd = { "open", "-a", app }
  end

  local _, err = vim.ui.open(vim.uri_from_fname(path), opts)
  if err then warn("Could not open web preview: " .. err) end
end

return M
