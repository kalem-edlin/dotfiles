-- Keep a source anchor and its viewport row across generated-buffer rebuilds.
local M = {}

function M.restore(session, win, anchor)
  if not anchor or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= session.buf then return end
  local source = anchor.source
  if anchor.mark then
    local pos = vim.api.nvim_buf_get_extmark_by_id(session.source_bufnr, session._view_ns, anchor.mark, {})
    if #pos == 2 then source = { pos[1] + 1, pos[2] } end
  end
  local target = require("markdown_source").render_position(session, source[1], source[2])
  vim.api.nvim_win_call(win, function()
    local row = math.min(anchor.screen_row, vim.fn.winheight(0))
    vim.fn.winrestview({ lnum = target[1], col = target[2],
      topline = math.max(1, target[1] - row + 1), skipcol = 0,
      leftcol = anchor.leftcol or 0, curswant = target[2] })
    -- Generated rows can still soft-wrap (notably with 'linebreak'). Count
    -- screen lines, not buffer lines, when choosing the new viewport top.
    local low, high = math.max(1, target[1] - row + 1), target[1]
    local end_col = vim.fn.virtcol(".")
    while low < high do
      local mid = math.floor((low + high) / 2)
      local height = vim.api.nvim_win_text_height(win, {
        start_row = mid - 1, end_row = target[1] - 1,
        end_vcol = end_col, max_height = row + 1,
      }).all
      if height > row then low = mid + 1 else high = mid end
    end
    vim.fn.winrestview({ topline = low, skipcol = 0 })
  end)
end

local function capture(session, win)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= session.buf then return end
  local previous = session._view_anchors[win]
  local width, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
  -- Neovim may already have scrolled/clamped the old generated buffer by the
  -- time WinResized runs. Retain the last view from before the size changed.
  if previous and (previous.width ~= width or previous.height ~= height) then return previous end
  return vim.api.nvim_win_call(win, function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local old = { content = session.content, source_lines = session._view_source_lines }
    local source = require("markdown_source").position(old, cursor[1], cursor[2])
    if not source then return previous end
    local anchor = { source = source, screen_row = vim.fn.winline(), leftcol = vim.fn.winsaveview().leftcol,
      width = width, height = height }
    -- Reuse a source extmark so edits in another window move the anchor with
    -- its text, rather than leaving it at an obsolete source line number.
    if vim.deep_equal(session._view_source_lines, vim.api.nvim_buf_get_lines(session.source_bufnr, 0, -1, false)) then
      anchor.mark = vim.api.nvim_buf_set_extmark(session.source_bufnr, session._view_ns,
        source[1] - 1, source[2], { id = previous and previous.mark, right_gravity = false, strict = false })
    elseif previous then
      return previous
    end
    session._view_anchors[win] = anchor
    return anchor
  end)
end

function M.capture_all(session)
  local anchors = {}
  for _, win in ipairs(vim.fn.win_findbuf(session.buf)) do anchors[win] = capture(session, win) end
  return anchors
end

function M.restore_all(session, anchors)
  session._view_source_lines = vim.deepcopy(session.source_lines)
  for win, anchor in pairs(anchors) do
    M.restore(session, win, anchor)
    -- Replace the old-size snapshot only after restoring the source anchor.
    session._view_anchors[win] = nil
    if anchor.mark then
      pcall(vim.api.nvim_buf_del_extmark, session.source_bufnr, session._view_ns, anchor.mark)
    end
    capture(session, win)
  end
end

function M.attach(session)
  session._view_ns = vim.api.nvim_create_namespace("dotfiles_md_view_" .. session.buf)
  session._view_anchors = {}
  session._view_source_lines = vim.deepcopy(session.source_lines)
  local rebuild = session.rebuild
  session.rebuild = function(self)
    local anchors = M.capture_all(self)
    self._view_rebuilding = true
    local ok, err = pcall(function()
      rebuild(self)
      M.restore_all(self, anchors)
      require("markdown_tables").after_rebuild(self)
    end)
    self._view_rebuilding = false
    if not ok then error(err) end
  end
  local group = vim.api.nvim_create_augroup("dotfiles_md_view_" .. session.buf, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled", "BufEnter" }, {
    group = group,
    callback = function()
      if not session._view_rebuilding then M.capture_all(session) end
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", { group = group, callback = function()
    local anchors = {}
    for _, win in ipairs(vim.fn.win_findbuf(session.buf)) do
      local previous = session._view_anchors[win]
      if previous and previous.width == vim.api.nvim_win_get_width(win)
        and previous.height ~= vim.api.nvim_win_get_height(win) then
        anchors[win] = previous
      end
    end
    -- Upstream rebuilds for width changes only. A height-only resize still
    -- needs its old anchor restored after Neovim's automatic view adjustment.
    M.restore_all(session, anchors)
  end })
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = session.buf, once = true, callback = function()
    if vim.api.nvim_buf_is_valid(session.source_bufnr) then
      vim.api.nvim_buf_clear_namespace(session.source_bufnr, session._view_ns, 0, -1)
    end
    vim.api.nvim_del_augroup_by_id(group)
  end })
end

function M.setup(plugin_dir)
  assert(not package.loaded["md-render.preview"], "Viewport adapter must load before md-render.preview")
  package.preload["md-render.preview"] = function()
    local path = plugin_dir .. "/lua/md-render/preview.lua"
    local source = table.concat(vim.fn.readfile(path), "\n")
    local function replace(old, new, expected)
      local count, offset = 0, 1
      while true do
        local a, b = source:find(old, offset, true)
        if not a then break end
        source = source:sub(1, a - 1) .. new .. source:sub(b + 1)
        count, offset = count + 1, a + #new
      end
      assert(count == expected, "md-render changed; review viewport patch: " .. old)
    end
    replace("math.min(usable_win_width(win), DEFAULT_MAX_WIDTH)", "usable_win_width(win)", 2)
    -- Expansion exposes full code lines. Upstream switches the whole preview
    -- to horizontal scrolling; keep native soft wrapping at each window's
    -- current text width instead. Tables already emit their own wrapped rows.
    replace([[  if self.win and vim.api.nvim_win_is_valid(self.win) then
    local any_expanded = false
    for _, v in pairs(self.expand_state) do
      if v then
        any_expanded = true
        break
      end
    end
    vim.api.nvim_set_option_value("wrap", not any_expanded, { win = self.win })
  end]], [[  for _, render_win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(render_win) then
      vim.api.nvim_set_option_value("wrap", true, { win = render_win })
    end
  end]], 1)
    replace("MdPreview._sessions[self.buf] = self", 'MdPreview._sessions[self.buf] = self\n  require("markdown_view").attach(self)', 1)
    -- Image downloads can also change the number of rendered rows. Apply the
    -- same source-anchor restoration around that separate rebuild route.
    replace("build_content = function()\n      self.opts.fold_state", 'build_content = function()\n      self._download_view_anchors = require("markdown_view").capture_all(self)\n      self.opts.fold_state', 1)
    replace("on_content_applied = function(new_content)\n      self.text_size_state", 'on_content_applied = function(new_content)\n      require("markdown_view").restore_all(self, self._download_view_anchors or {})\n      self._download_view_anchors = nil\n      self.text_size_state', 1)
    source = require("markdown_tables").patch_preview(source)
    return assert(loadstring(source, "@" .. path))()
  end
end

return M
