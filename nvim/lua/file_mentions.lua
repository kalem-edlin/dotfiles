-- A Blink source for @relative/path mentions in prose buffers. Blink owns the
-- completion menu; this module supplies files and directories.
local M = {}

local uv = vim.uv or vim.loop
local defaults = {
  filetypes = { "markdown", "text" },
  include_hidden = true,
  max_items = 150,
  -- Prefixes outside the project (../, ~/, /) can be huge trees, so their
  -- recursive search stops at this depth.
  outside_root_max_depth = 3,
  cache_ttl_ms = 4000,
  rank_delay_ms = 25,
  excludes = {
    ".git", ".DS_Store", "node_modules", "dist", "build", "out", "target", "coverage",
    ".next", ".nuxt", ".svelte-kit", ".turbo", ".vite", ".cache", ".parcel-cache",
    ".pytest_cache", "__pycache__", ".mypy_cache", ".ruff_cache", ".venv", "venv",
    ".smart-env",
  },
}

local cache, runner = {}, nil
local now = function() return uv.now() end
local home = function() return uv.os_homedir() end

local function response(items)
  -- The list is filtered and capped against the complete @ token, so Blink
  -- must ask us again when that token changes in either direction.
  return { is_incomplete_forward = true, is_incomplete_backward = true, items = items }
end

function M.is_enabled(bufnr)
  bufnr = bufnr or 0
  if vim.bo[bufnr].buftype ~= "" or not vim.bo[bufnr].modifiable then return false end
  local override = vim.b[bufnr].file_mentions_enabled
  if override ~= nil then return override == true end
  return vim.tbl_contains(defaults.filetypes, vim.bo[bufnr].filetype)
end

-- Returns an LSP-style range for the @ token immediately before byte_col.
-- `byte_col` is Blink's zero-based cursor byte column.
function M.parse(line, byte_col)
  local before = line:sub(1, byte_col)
  local at, query, quoted

  -- An unfinished @"path with spaces" token.  The quote is replaced too, so
  -- accepting a candidate always leaves a balanced quoted mention.
  at, query = before:match("()@\"([^\"]*)$")
  if at then
    quoted = true
  else
    at, query = before:match('()@([^%s@"]*)$')
    quoted = false
  end
  if not at then return nil end

  local previous = at > 1 and before:sub(at - 1, at - 1) or ""
  -- Mentions begin at a word boundary only.  This excludes mail addresses,
  -- @@ escapes, and identifiers such as foo@bar while allowing prose `(@x)`.
  if previous ~= "" and not previous:match('[%s%(%[%{%<"`\']') then return nil end

  return {
    start_col = at - 1,
    -- Consume only an immediately adjacent autoclose quote.  It belongs to
    -- this token; punctuation after it remains untouched.
    end_col = quoted and line:sub(byte_col + 1, byte_col + 1) == '"' and byte_col + 1 or byte_col,
    query = query or "",
    quoted = quoted,
  }
end

function M.root(bufnr)
  bufnr = bufnr or 0
  local overridden = vim.b[bufnr].file_mentions_root
  if type(overridden) == "string" and vim.fn.isdirectory(overridden) == 1 then
    return vim.fs.normalize(overridden)
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return vim.fn.getcwd() end
  local git_root = vim.fs.root(name, { ".git" })
  if git_root then return git_root end
  -- Prompt editors commonly write a temporary Markdown file outside the
  -- project.  Their inherited cwd is the intended mention root.  Check this
  -- after git so projects deliberately created under /tmp still work.
  local temp = vim.env.TMPDIR or vim.env.TMP or vim.env.TEMP
  temp = temp and vim.fs.normalize(uv.fs_realpath(temp) or temp):gsub("/$", "")
  if name:match("^/tmp/") or name:match("^/private/tmp/")
    or name:match("^/var/folders/") or name:match("^/private/var/folders/")
    or (temp and vim.startswith(name, temp .. "/"))
  then
    return vim.fn.getcwd()
  end
  return vim.fs.dirname(name)
end

-- Resolve a typed directory prefix. When it names a real directory, the search
-- is scoped there and fzf sees only the rest; completion edits retain exactly
-- the prefix the user typed (including ~/). Otherwise a plain relative query
-- is matched whole against every path under the root, so `lua/fm` can still
-- find nvim/lua/file_mentions.lua.
function M.resolve_query(root, query)
  if query == "~" then query = "~/" end
  local prefix, basename = query:match("^(.*[/])(.*)$")
  prefix, basename = prefix or "", basename or query
  if prefix:find('[%c"]') then return nil end
  local directory
  if vim.startswith(prefix, "~/") then
    local homedir = home()
    if not homedir or homedir == "" then return nil end
    directory = homedir .. "/" .. prefix:sub(3)
  elseif vim.startswith(prefix, "/") then
    directory = prefix
  else
    directory = root .. "/" .. prefix
  end
  -- realpath handles symlinks followed by .. with filesystem semantics, and
  -- makes equivalent textual prefixes share a directory cache.
  directory = uv.fs_realpath(directory)
  if not directory or vim.fn.isdirectory(directory) ~= 1 then
    local explicit = prefix:match("^[/~]") or ("/" .. prefix):find("/%.%.?/")
    if explicit then return nil end
    directory = uv.fs_realpath(root)
    if not directory then return nil end
    return { directory = directory, prefix = "", query = query }
  end
  return { directory = directory, prefix = prefix, query = basename }
end

local function argv_for(opts, max_depth)
  local fd = vim.fn.exepath("fd")
  if fd == "" then fd = vim.fn.exepath("fdfind") end
  if fd ~= "" then
    local argv = { fd, "--type", "f", "--type", "d", "--color", "never", "--print0" }
    if max_depth then vim.list_extend(argv, { "--max-depth", tostring(max_depth) }) end
    if opts.include_hidden then table.insert(argv, "--hidden") end
    for _, excluded in ipairs(opts.excludes) do
      table.insert(argv, "--exclude")
      table.insert(argv, excluded)
    end
    return argv
  end

  local rg = vim.fn.exepath("rg")
  if rg == "" then return nil end
  local argv = { rg, "--files", "--null" }
  if max_depth then vim.list_extend(argv, { "--max-depth", tostring(max_depth) }) end
  if opts.include_hidden then table.insert(argv, "--hidden") end
  for _, excluded in ipairs(opts.excludes) do
    table.insert(argv, "--glob")
    table.insert(argv, "!**/" .. excluded)
    table.insert(argv, "--glob")
    table.insert(argv, "!**/" .. excluded .. "/**")
  end
  return argv, true
end

local function run(argv, opts, callback)
  if runner then return runner(argv, opts, callback) end
  return vim.system(argv, { cwd = opts.cwd, text = false }, function(result)
    if result.code ~= 0 and result.code ~= 1 then return callback({}, result.stderr or "scanner failed") end
    callback(vim.split(result.stdout or "", "\0", { plain = true, trimempty = true }))
  end)
end

-- A matching directory stands in for everything beneath it: fzf ranked the
-- directory itself, so a descendant adds nothing the user asked for. `paths`
-- keeps fzf's order, and directories end in a slash.
local function collapse(paths)
  local matched, kept = {}, {}
  for _, path in ipairs(paths) do
    if path:sub(-1) == "/" then matched[path] = true end
  end
  for _, path in ipairs(paths) do
    local covered = false
    for slash in path:sub(1, -2):gmatch("()/") do
      if matched[path:sub(1, slash)] then
        covered = true
        break
      end
    end
    if not covered then kept[#kept + 1] = path end
  end
  return kept
end

local function completion_items(matches, token, opts)
  local items, line = {}, token.line
  local Kind = vim.lsp.protocol.CompletionItemKind
  for index = 1, math.min(#matches, opts.max_items) do
    local path = matches[index]
    local insert = "@" .. path
    if token.quoted or path:find(" ", 1, true) then insert = '@"' .. path .. '"' end
    items[#items + 1] = {
      label = path,
      -- fzf already matched the whole query, including extended search terms.
      -- Prevent Blink's last-word matcher from dropping OR/negation matches.
      filterText = token.filter_text or ("@" .. path),
      sortText = string.format("%06d", index),
      data = { prefix = token.prefix or "", query = token.search or "" },
      kind = path:sub(-1) == "/" and Kind.Folder or Kind.File,
      textEdit = {
        newText = insert,
        range = {
          start = { line = line, character = token.start_col },
          ["end"] = { line = line, character = token.end_col },
        },
      },
    }
  end
  return items
end

local source = {}
source.__index = source

function source.new(opts)
  return setmetatable({ opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {}), pending = nil }, source)
end

function source:enabled() return M.is_enabled(vim.api.nvim_get_current_buf()) end
function source:get_trigger_characters() return { "@" } end

function source:get_completions(context, callback)
  if self.pending then self.pending:kill() end
  self.pending = nil
  local parsed = M.parse(context.line, context.cursor[2])
  if not parsed then return callback(response({})) end
  parsed.line = context.cursor[1] - 1
  parsed.filter_text = context.line:sub(1, context.cursor[2])

  local root = M.root(context.bufnr)
  if not root or root == "" then return callback(response({})) end
  local resolved = M.resolve_query(root, parsed.query)
  if not resolved then return callback(response({})) end
  root = resolved.directory
  local prefix, query = resolved.prefix, resolved.query
  parsed.prefix, parsed.search = prefix, query
  local request = {}
  function request:kill()
    self.cancelled = true
    if self.handle and self.handle.kill then pcall(self.handle.kill, self.handle, 15) end
  end
  self.pending = request
  local function current() return not request.cancelled and self.pending == request end
  local function finish(paths, err)
    if not current() then return end
    self.pending = nil
    if err then
      vim.notify_once("File mentions: " .. err, vim.log.levels.WARN)
    end
    if prefix ~= "" then
      paths = vim.tbl_map(function(path) return prefix .. path end, paths)
    end
    callback(response(completion_items(paths, parsed, self.opts)))
  end

  local function rank(entry)
    if query == "" or #entry.paths == 0 then
      -- Everything matches an empty query, so only the top level survives.
      -- Dotfiles follow the visible entries, which are the likelier picks.
      local visible, hidden = {}, {}
      for _, path in ipairs(entry.paths) do
        if not path:sub(1, -2):find("/", 1, true) then
          table.insert(path:sub(1, 1) == "." and hidden or visible, path)
        end
      end
      return finish(vim.list_extend(visible, hidden))
    end
    local fzf = vim.fn.exepath("fzf")
    if fzf == "" then return finish({}, "install fzf to rank @ file suggestions") end
    -- Coalesce rapid typing. Both file discovery and ranking run outside
    -- Neovim's event loop; cancellation covers either stage and this delay.
    vim.defer_fn(function()
      if not current() then return end
      request.handle = vim.system({ fzf, "--read0", "--print0", "--scheme=path", "-i", "--filter=" .. query }, {
        stdin = entry.input,
        text = false,
        -- Shell-picker settings must not change this noninteractive protocol.
        env = { FZF_DEFAULT_OPTS = "", FZF_DEFAULT_OPTS_FILE = "" },
      }, function(result)
        vim.schedule(function()
          if result.code ~= 0 and result.code ~= 1 then
            return finish({}, result.stderr or "fzf failed")
          end
          local matches = vim.split(result.stdout or "", "\0", { plain = true, trimempty = true })
          for index, path in ipairs(matches) do
            if entry.directories[path] then matches[index] = path .. "/" end
          end
          finish(collapse(matches))
        end)
      end)
    end, self.opts.rank_delay_ms)
  end

  -- Providers with different visibility settings must not reuse one another's
  -- listings, even when they resolve to the same directory.
  local project = uv.fs_realpath(M.root(context.bufnr))
  local inside = project and vim.startswith(root .. "/", project .. "/")
  local max_depth = not inside and self.opts.outside_root_max_depth or nil
  local cache_key = root .. "\0" .. vim.json.encode({ self.opts.include_hidden, self.opts.excludes, max_depth or false })
  local entry = cache[cache_key]
  if entry and entry.expires > now() then
    rank(entry)
  else
    local argv, infer_directories = argv_for(self.opts, max_depth)
    if not argv then
      finish({}, "file discovery needs fd/fdfind or ripgrep on PATH")
    else
      request.handle = run(argv, { cwd = root }, function(paths, err)
        vim.schedule(function()
          if not current() then return end
          if err then return finish({}, err) end
          local candidates, seen = {}, {}
          local function add(path)
            if path ~= "" and not seen[path] and not path:find('[%c"]') then
              seen[path] = true
              candidates[#candidates + 1] = path
            end
          end
          for _, path in ipairs(paths) do
            path = path:gsub("^%./", "")
            add(path)
            -- fd emits directories with a trailing slash. ripgrep only lists
            -- files, so also offer each parent of its visible file results.
            if infer_directories then
              for slash in path:gmatch("()/") do add(path:sub(1, slash)) end
            end
          end
          table.sort(candidates)
          -- fzf's path scheme scores a match before the last slash as a
          -- parent-directory match, which ranked Daily/ below files such as
          -- .smart-env/Daily_x.json for "Daily". Rank directories by their
          -- bare names and restore the slash afterwards.
          local names, directories = {}, {}
          for index, path in ipairs(candidates) do
            names[index] = path:gsub("/$", "")
            if names[index] ~= path then directories[names[index]] = true end
          end
          entry = {
            paths = candidates,
            directories = directories,
            input = table.concat(names, "\0") .. "\0",
            expires = now() + self.opts.cache_ttl_ms,
          }
          cache[cache_key] = entry
          rank(entry)
        end)
      end)
    end
  end
  -- Blink invokes this on edits, dismissal, or a switch to another buffer.
  return function() request:kill() end
end

function M.clear_cache() cache = {} end

-- Byte ranges of `text` matched by an fzf query, for highlighting only.
-- fzf --filter reports no positions, so this follows fzf's v1 scan per term:
-- forward to the first complete match, then backward to its tightest start.
-- Negated terms and | separators highlight nothing.
local function fold(value)
  return value:find("[\128-\255]") and vim.fn.tolower(value) or value:lower()
end

local function match_ranges(text, query)
  local chars = {}
  for start, char in text:gmatch("()([%z\1-\127\194-\244][\128-\191]*)") do
    chars[#chars + 1] = { start = start - 1, stop = start - 1 + #char, char = fold(char) }
  end
  local ranges = {}
  for term in query:gmatch("%S+") do
    if term ~= "|" and term:sub(1, 1) ~= "!" then
      local exact = term:sub(1, 1) == "'"
      term = fold((term:gsub("^['^]", ""):gsub("%$$", "")))
      local needle = {}
      for char in term:gmatch("[%z\1-\127\194-\244][\128-\191]*") do needle[#needle + 1] = char end
      if exact and #needle > 0 then
        local at = fold(text):find(term, 1, true)
        if at then ranges[#ranges + 1] = { at - 1, at - 1 + #term } end
      elseif #needle > 0 then
        local index, last = 1, nil
        for position, entry in ipairs(chars) do
          if entry.char == needle[index] then
            index = index + 1
            if index > #needle then last = position break end
          end
        end
        if last then
          index = #needle
          for position = last, 1, -1 do
            if chars[position].char == needle[index] then
              ranges[#ranges + 1] = { chars[position].start, chars[position].stop }
              index = index - 1
              if index == 0 then break end
            end
          end
        end
      end
    end
  end
  return ranges
end

-- Menu text and match ranges for an item. The typed directory prefix is
-- already on the line, so rows show only the part that differs, eliding from
-- the left when long. fzf matched the query against exactly that part.
function M.render(item, max_width)
  local data = item.data or {}
  local text = item.label:sub(#(data.prefix or "") + 1)
  if text == "" then text = item.label end
  local ranges = data.query and match_ranges(text, data.query) or {}
  local width = vim.fn.strchars(text)
  if max_width and width > max_width then
    local cut = #vim.fn.strcharpart(text, 0, width - max_width + 1)
    text = "…" .. text:sub(cut + 1)
    local shift = #"…" - cut
    local kept = {}
    for _, range in ipairs(ranges) do
      if range[1] >= cut then kept[#kept + 1] = { range[1] + shift, range[2] + shift } end
    end
    ranges = kept
  end
  return text, ranges
end

function M.display(item, max_width) return (M.render(item, max_width)) end

M._test = {
  parse = M.parse,
  root = M.root,
  resolve_query = M.resolve_query,
  completion_items = completion_items,
  collapse = collapse,
  set_runner = function(value) runner = value end,
  set_now = function(value) now = value end,
  set_home = function(value) home = value end,
  reset = function()
    cache, runner, now = {}, nil, function() return uv.now() end
    home = function() return uv.os_homedir() end
  end,
}

-- Blink loads this table as the provider module.  Keep the small operational
-- helpers here too, so the Lazy spec and a refresh command need no second
-- module just to test enablement or clear a stale directory listing.
source.is_enabled = M.is_enabled
source.clear_cache = M.clear_cache
source.root = M.root
source.resolve_query = M.resolve_query
source.parse = M.parse
source.display = M.display
source.render = M.render
source._test = M._test

return source
