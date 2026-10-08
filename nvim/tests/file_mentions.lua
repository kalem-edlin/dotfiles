-- Run with: nvim --headless -u NONE -l nvim/tests/file_mentions.lua
-- These tests exercise the file-mention contract without loading the user's
-- plugin manager or a Blink UI.
package.path = vim.fn.getcwd() .. "/nvim/lua/?.lua;" .. package.path

local source = require("file_mentions")
local test = source._test

local failures = {}

local function check(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    failures[#failures + 1] = name .. "\n" .. err
  end
end

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or "values differ") .. "\nactual: " .. vim.inspect(actual) .. "\nexpected: " .. vim.inspect(expected))
end

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
end

local function item_with_label(items, label)
  for _, item in ipairs(items) do
    if item.label == label then return item end
  end
  error("missing completion item: " .. label)
end

local function canonical(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function make_dir()
  local path = vim.fn.tempname()
  assert(vim.fn.mkdir(path, "p") == 1)
  return path
end

local function make_home_dir()
  local path = vim.fn.expand("~/.file-mentions-test-") .. tostring(vim.uv.hrtime())
  assert(vim.fn.mkdir(path, "p") == 1)
  return path
end

local function cleanup(path)
  vim.fn.delete(path, "rf")
end

local function buffer(name)
  local bufnr = vim.api.nvim_create_buf(false, true)
  if name then vim.api.nvim_buf_set_name(bufnr, name) end
  return bufnr
end

local function context(bufnr, line, byte_col)
  return { bufnr = bufnr, line = line, cursor = { 1, byte_col } }
end

local function wait_for(predicate)
  assert(vim.wait(500, predicate, 10), "timed out waiting for scheduled completion")
end

check("parses only a mention token at a valid boundary", function()
  equal(test.parse("see @src/inxts", #"see @src/inxts"), {
    start_col = 4, end_col = 14, query = "src/inxts", quoted = false,
  })
  equal(test.parse("(@docs/guide", #"(@docs/guide"), {
    start_col = 1, end_col = 12, query = "docs/guide", quoted = false,
  })

  assert(test.parse("mail me@example.com", #"mail me@example.com") == nil)
  assert(test.parse("literal @@todo", #"literal @@todo") == nil)
  assert(test.parse("identifier foo@bar", #"identifier foo@bar") == nil)
  assert(test.parse("escaped \\@todo", #"escaped \\@todo") == nil)
end)

check("keeps quoted and unicode queries intact", function()
  equal(test.parse('open @"folder with sp', #'open @"folder with sp'), {
    start_col = 5, end_col = #'open @"folder with sp', query = "folder with sp", quoted = true,
  })

  local line = "read @dokumente/überblick.md"
  equal(test.parse(line, #line), {
    start_col = 5, end_col = #line, query = "dokumente/überblick.md", quoted = false,
  })
end)

check("builds Pi-compatible, balanced file mentions", function()
  local token = { query = "", quoted = false, start_col = 4, end_col = 5, line = 0 }
  local items = test.completion_items({ "plain.md", "folder with spaces/note.md", "dokumente/überblick.md" }, token, { max_items = 10 })
  equal(item_with_label(items, "plain.md").textEdit.newText, "@plain.md")
  local spaced = item_with_label(items, "folder with spaces/note.md")
  equal(spaced.textEdit.newText, '@"folder with spaces/note.md"')
  equal(item_with_label(items, "dokumente/überblick.md").textEdit.newText, "@dokumente/überblick.md")
  assert(spaced.textEdit.range.start.character == 4)
  assert(spaced.textEdit.range["end"].character == 5)

  token.quoted = true
  equal(test.completion_items({ "plain.md" }, token, { max_items = 10 })[1].textEdit.newText, '@"plain.md"')
end)

check("builds directory mentions with folder kinds and balanced quotes", function()
  local token = { quoted = false, start_col = 4, end_col = 8, line = 0 }
  local items = test.completion_items({ "src/", "folder with spaces/", "plain.md" }, token, { max_items = 10 })
  local directory = item_with_label(items, "src/")
  equal(directory.kind, vim.lsp.protocol.CompletionItemKind.Folder)
  equal(directory.textEdit.newText, "@src/")
  equal(item_with_label(items, "folder with spaces/").textEdit.newText, '@"folder with spaces/"')
  equal(item_with_label(items, "plain.md").kind, vim.lsp.protocol.CompletionItemKind.File)
end)

check("infers roots for repositories, standalone files, prompts, unnamed buffers, and overrides", function()
  local original_cwd = vim.fn.getcwd()
  local repo = make_dir()
  local standalone = make_home_dir()
  local project_cwd = make_dir()
  local temp = vim.fn.tempname() .. ".md"
  vim.fn.mkdir(repo .. "/.git", "p")
  vim.fn.mkdir(repo .. "/nested", "p")
  vim.fn.writefile({ "" }, repo .. "/nested/note.md")
  vim.fn.writefile({ "" }, standalone .. "/note.md")
  vim.fn.writefile({ "" }, temp)
  vim.cmd.cd(project_cwd)

  local repo_buf = buffer(repo .. "/nested/note.md")
  local standalone_buf = buffer(standalone .. "/note.md")
  local temp_buf = buffer(temp)
  local unnamed_buf = buffer()
  local override_buf = buffer(standalone .. "/other.md")
  vim.b[override_buf].file_mentions_root = repo

  equal(test.root(repo_buf), canonical(repo))
  equal(test.root(standalone_buf), canonical(standalone))
  equal(test.root(temp_buf), vim.uv.cwd())
  equal(test.root(unnamed_buf), vim.uv.cwd())
  equal(test.root(override_buf), vim.fs.normalize(repo))

  vim.cmd.cd(original_cwd)
  cleanup(repo)
  cleanup(standalone)
  cleanup(project_cwd)
  vim.fn.delete(temp)
end)

check("scanner includes hidden files, honours fd ignores, and excludes generated trees", function()
  test.reset()
  local root = make_dir()
  local bufnr = buffer(root .. "/prompt.md")
  vim.b[bufnr].file_mentions_root = root
  local calls, results = {}, {}

  test.set_runner(function(argv, opts, done)
    calls[#calls + 1] = { argv = argv, opts = opts }
    done({ ".hidden.md", "kept.md" })
    return { kill = function() end }
  end)
  source.new():get_completions(context(bufnr, "@h", 2), function(value)
    results[#results + 1] = value
  end)
  wait_for(function() return #results == 1 end)

  local argv = calls[1].argv
  assert(contains(argv, "f") and contains(argv, "d"), "fd must include files and directories")
  assert(contains(argv, "--hidden"), "fd must include hidden files")
  assert(not contains(argv, "--no-ignore"), "fd must retain .gitignore handling")
  for _, excluded in ipairs({ ".git", "node_modules", "dist", ".cache", ".venv" }) do
    local found = false
    for index = 1, #argv - 1 do
      if argv[index] == "--exclude" and argv[index + 1] == excluded then found = true end
    end
    assert(found, "missing generated-tree exclusion: " .. excluded)
  end
  equal(calls[1].opts.cwd, vim.fs.normalize(root))
  equal(results[1].items[1].textEdit.newText, "@.hidden.md")
  cleanup(root)
end)

local real_exepath = vim.fn.exepath
check("discovers directories with fd and infers visible parents with ripgrep", function()
  local root = make_dir()
  vim.fn.mkdir(root .. "/.git", "p")
  for _, path in ipairs({ "src/nested", "empty", "folder with spaces", ".config", "ignored", "node_modules" }) do
    vim.fn.mkdir(root .. "/" .. path, "p")
  end
  for _, path in ipairs({ "src/nested/one.lua", "src/nested/two.lua", ".config/tool.json", "ignored/noise", "node_modules/noise" }) do
    vim.fn.writefile({ "fixture" }, root .. "/" .. path)
  end
  vim.fn.writefile({ "ignored/" }, root .. "/.gitignore")
  local bufnr = buffer(root .. "/prompt.md")
  vim.b[bufnr].file_mentions_root = root
  for _, fallback in ipairs({ false, true }) do
    test.reset()
    vim.fn.exepath = function(command)
      if fallback and (command == "fd" or command == "fdfind") then return "" end
      return real_exepath(command)
    end
    local result
    source.new():get_completions(context(bufnr, "@", 1), function(value) result = value end)
    wait_for(function() return result ~= nil end)
    local labels = vim.tbl_map(function(item) return item.label end, result.items)
    for _, path in ipairs({ "src/", "src/nested/", "src/nested/one.lua", ".config/" }) do
      assert(contains(labels, path), "missing path: " .. path)
    end
    equal(#vim.tbl_filter(function(path) return path == "src/" end, labels), 1)
    for _, path in ipairs({ ".git/", "ignored/", "ignored/noise", "node_modules/", "node_modules/noise" }) do
      assert(not contains(labels, path), "excluded path: " .. path)
    end
    if not fallback then
      assert(contains(labels, "empty/"), "fd must include empty directories")
      assert(contains(labels, "folder with spaces/"), "fd must include spaced directories")
    end
  end
  cleanup(root)
end)
vim.fn.exepath = real_exepath

check("cancels stale scans and caches only the root that completed", function()
  test.reset()
  local root_a, root_b = make_dir(), make_dir()
  local bufnr = buffer(root_a .. "/prompt.md")
  local jobs, results = {}, {}
  local clock = 100
  test.set_now(function() return clock end)
  test.set_runner(function(argv, opts, done)
    local job = { argv = argv, opts = opts, done = done, killed = false }
    jobs[#jobs + 1] = job
    return { kill = function() job.killed = true end }
  end)
  local provider = source.new({ cache_ttl_ms = 4000 })
  local function request(root, query)
    vim.b[bufnr].file_mentions_root = root
    provider:get_completions(context(bufnr, query, #query), function(value)
      results[#results + 1] = value
    end)
  end

  request(root_a, "@old")
  request(root_b, "@fresh")
  assert(jobs[1].killed, "changing roots must cancel the in-flight scan")
  jobs[1].done({ "stale-from-a.md" })
  jobs[2].done({ "fresh-from-b.md" })
  wait_for(function() return #results == 1 end)
  equal(results[1].items[1].textEdit.newText, "@fresh-from-b.md")

  request(root_b, "@fresh")
  wait_for(function() return #results == 2 end)
  assert(#jobs == 2, "completed root B should come from its own cache")
  equal(results[2].items[1].textEdit.newText, "@fresh-from-b.md")

  request(root_a, "@fresh")
  assert(#jobs == 3, "stale root A callback must not seed A's cache")
  jobs[3].done({ "fresh-from-a.md" })
  wait_for(function() return #results == 3 end)
  equal(results[3].items[1].textEdit.newText, "@fresh-from-a.md")

  clock = 5000
  request(root_b, "@new")
  assert(#jobs == 4, "expired cache must scan again")
  jobs[4].done({ "new-from-b.md" })
  wait_for(function() return #results == 4 end)
  equal(results[4].items[1].textEdit.newText, "@new-from-b.md")
  cleanup(root_a)
  cleanup(root_b)
end)

check("preserves real fzf ranking and extended query results before capping", function()
  test.reset()
  local root = make_dir()
  local bufnr = buffer(root .. "/prompt.md")
  vim.b[bufnr].file_mentions_root = root
  local paths = { "docs/hello world.md", "src/handler.lua", "README.md", "docs/reader.md" }
  test.set_runner(function(_, _, done)
    done(vim.deepcopy(paths))
    return { kill = function() end }
  end)
  local provider = source.new({ max_items = 2, rank_delay_ms = 0 })
  table.sort(paths)
  local original_opts = vim.env.FZF_DEFAULT_OPTS
  -- An interactive shell preference must not reverse or otherwise alter results.
  vim.env.FZF_DEFAULT_OPTS = "--no-sort --tac"
  for _, query in ipairs({ "rd", "world hello", "README | hello", "!README md$" }) do
    local expected = vim.system({ "fzf", "--read0", "--print0", "--filter=" .. query }, {
      stdin = table.concat(paths, "\0") .. "\0",
      env = { FZF_DEFAULT_OPTS = "", FZF_DEFAULT_OPTS_FILE = "" },
    }):wait()
    assert(expected.code == 0)
    local labels = vim.split(expected.stdout, "\0", { plain = true, trimempty = true })
    while #labels > 2 do table.remove(labels) end
    local result
    local line = '@"' .. query
    provider:get_completions(context(bufnr, line, #line), function(value) result = value end)
    wait_for(function() return result ~= nil end)
    equal(vim.tbl_map(function(item) return item.label end, result.items), labels)
  end
  vim.env.FZF_DEFAULT_OPTS = original_opts
  cleanup(root)
end)

local real_system = vim.system
check("kills obsolete fzf jobs and rejects their late results", function()
  test.reset()
  local root = make_dir()
  local bufnr = buffer(root .. "/prompt.md")
  vim.b[bufnr].file_mentions_root = root
  local jobs, results = {}, {}
  test.set_runner(function(_, _, done)
    done({ "old.md", "new.md" })
    return { kill = function() end }
  end)
  vim.system = function(argv, opts, done)
    local job = { argv = argv, opts = opts, done = done }
    jobs[#jobs + 1] = job
    return { kill = function() job.killed = true end }
  end
  local provider = source.new({ rank_delay_ms = 0 })
  local cancel = provider:get_completions(context(bufnr, "@old", 4), function(value)
    results[#results + 1] = value
  end)
  wait_for(function() return #jobs == 1 end)
  cancel()
  assert(jobs[1].killed)
  provider:get_completions(context(bufnr, "@new", 4), function(value)
    results[#results + 1] = value
  end)
  wait_for(function() return #jobs == 2 end)
  jobs[2].done({ code = 0, stdout = "new.md\0" })
  jobs[1].done({ code = 0, stdout = "old.md\0" })
  wait_for(function() return #results == 1 end)
  equal(results[1].items[1].label, "new.md")
  cleanup(root)
end)
vim.system = real_system

test.reset()
if #failures > 0 then
  error(table.concat(failures, "\n\n"))
end

print("file_mentions tests passed")
