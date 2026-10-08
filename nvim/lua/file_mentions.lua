-- A Blink source for @relative/path mentions in prose buffers. Blink owns the
-- completion menu; this module supplies files and directories.
local M = {}

local uv = vim.uv or vim.loop
local defaults = {
  filetypes = { "markdown", "text" },
  include_hidden = true,
  max_items = 150,
  cache_ttl_ms = 4000,
  rank_delay_ms = 25,
  excludes = {
    ".git", ".DS_Store", "node_modules", "dist", "build", "out", "target", "coverage",
    ".next", ".nuxt", ".svelte-kit", ".turbo", ".vite", ".cache", ".parcel-cache",
    ".pytest_cache", "__pycache__", ".mypy_cache", ".ruff_cache", ".venv", "venv",
  },
}

local cache, runner = {}, nil
local now = function() return uv.now() end

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
    at, query = before:match("()@([^%s@]*)$")
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

local function argv_for(opts)
  local fd = vim.fn.exepath("fd")
  if fd == "" then fd = vim.fn.exepath("fdfind") end
  if fd ~= "" then
    local argv = { fd, "--type", "f", "--type", "d", "--color", "never", "--print0" }
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
    callback(response(completion_items(paths, parsed, self.opts)))
  end

  local function rank(entry)
    if parsed.query == "" or #entry.paths == 0 then return finish(entry.paths) end
    local fzf = vim.fn.exepath("fzf")
    if fzf == "" then return finish({}, "install fzf to rank @ file suggestions") end
    -- Coalesce rapid typing. Both file discovery and ranking run outside
    -- Neovim's event loop; cancellation covers either stage and this delay.
    vim.defer_fn(function()
      if not current() then return end
      request.handle = vim.system({ fzf, "--read0", "--print0", "--filter=" .. parsed.query }, {
        stdin = entry.input,
        text = false,
        -- Shell-picker settings must not change this noninteractive protocol.
        env = { FZF_DEFAULT_OPTS = "", FZF_DEFAULT_OPTS_FILE = "" },
      }, function(result)
        vim.schedule(function()
          if result.code ~= 0 and result.code ~= 1 then
            return finish({}, result.stderr or "fzf failed")
          end
          finish(vim.split(result.stdout or "", "\0", { plain = true, trimempty = true }))
        end)
      end)
    end, self.opts.rank_delay_ms)
  end

  local entry = cache[root]
  if entry and entry.expires > now() then
    rank(entry)
  else
    local argv, infer_directories = argv_for(self.opts)
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
          entry = {
            paths = candidates,
            input = table.concat(candidates, "\0") .. "\0",
            expires = now() + self.opts.cache_ttl_ms,
          }
          cache[root] = entry
          rank(entry)
        end)
      end)
    end
  end
  -- Blink invokes this on edits, dismissal, or a switch to another buffer.
  return function() request:kill() end
end

function M.clear_cache() cache = {} end

M._test = {
  parse = M.parse,
  root = M.root,
  completion_items = completion_items,
  set_runner = function(value) runner = value end,
  set_now = function(value) now = value end,
  reset = function()
    cache, runner, now = {}, nil, function() return uv.now() end
  end,
}

-- Blink loads this table as the provider module.  Keep the small operational
-- helpers here too, so the Lazy spec and a refresh command need no second
-- module just to test enablement or clear a stale directory listing.
source.is_enabled = M.is_enabled
source.clear_cache = M.clear_cache
source.root = M.root
source._test = M._test

return source
