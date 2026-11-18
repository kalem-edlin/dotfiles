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

check("public parser distinguishes open, closed, and middle-token cursors", function()
  equal(source.parse, test.parse, "public parser must expose the source's parser")
  for _, path in ipairs({ "foo", "foo/bar", "../foo", "../../folder with spaces/note.md" }) do
    local prefix = 'see @"' .. path
    local line = prefix .. '", next'
    equal(source.parse(line, #prefix), {
      start_col = 4, end_col = #prefix + 1, query = path, quoted = true,
    }, "cursor before closing quote must retain the open token and consume its quote")
    assert(source.parse(line, #prefix + 1) == nil, "cursor after closing quote must not reopen as an unquoted mention")
    assert(source.parse(prefix .. '"suffix', #prefix + #'"suffix') == nil, "closed quote followed by text must stay closed")
  end

  local quoted = 'see @"foo/bar", next'
  equal(source.parse(quoted, #'see @"'), {
    start_col = 4, end_col = #'see @"', query = "", quoted = true,
  })
  equal(source.parse(quoted, #'see @"foo'), {
    start_col = 4, end_col = #'see @"foo', query = "foo", quoted = true,
  }, "middle-token cursor must parse only the prefix without consuming the remaining path")
  equal(source.parse("see @foo/bar next", #"see @foo"), {
    start_col = 4, end_col = #"see @foo", query = "foo", quoted = false,
  })
  assert(source.parse('see @foo"bar', #'see @foo"bar') == nil, "unquoted queries must reject double quotes")
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
  assert(not contains(argv, "--max-depth"), "fd must search the whole project")
  assert(not contains(argv, "--no-ignore"), "fd must retain .gitignore handling")
  for _, excluded in ipairs({ ".git", "node_modules", "dist", ".cache", ".venv" }) do
    local found = false
    for index = 1, #argv - 1 do
      if argv[index] == "--exclude" and argv[index + 1] == excluded then found = true end
    end
    assert(found, "missing generated-tree exclusion: " .. excluded)
  end
  equal(calls[1].opts.cwd, canonical(root))
  equal(results[1].items[1].textEdit.newText, "@.hidden.md")
  cleanup(root)
end)

local real_exepath = vim.fn.exepath
check("lists only top-level entries for an empty query with either scanner", function()
  local root = make_dir()
  vim.fn.mkdir(root .. "/.git", "p")
  for _, path in ipairs({ "src/nested", "empty", "folder with spaces", ".config", "ignored", "rgignored", "negated", "node_modules", 'unsafe"dir' }) do
    vim.fn.mkdir(root .. "/" .. path, "p")
  end
  for _, path in ipairs({ "src/nested/one.lua", "src/nested/two.lua", ".config/tool.json", "ignored/noise", "node_modules/noise" }) do
    vim.fn.writefile({ "fixture" }, root .. "/" .. path)
  end
  vim.fn.writefile({ "ignored/", "negated/", "!negated/" }, root .. "/.gitignore")
  vim.fn.writefile({ "rgignored/" }, root .. "/.ignore")
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
    -- ripgrep lists only files, so its fallback cannot offer empty directories.
    local expected = { "src/", ".config/" }
    if not fallback then vim.list_extend(expected, { "empty/", "folder with spaces/", "negated/" }) end
    for _, path in ipairs(expected) do
      assert(contains(labels, path), "missing path: " .. path)
    end
    equal(#vim.tbl_filter(function(path) return path == "src/" end, labels), 1)
    for _, path in ipairs({ ".git/", "ignored/", "ignored/noise", "rgignored/", "node_modules/", "node_modules/noise", "src/nested/", "src/nested/one.lua", '.config/tool.json', 'unsafe"dir/' }) do
      assert(not contains(labels, path), "excluded path: " .. path)
    end
    local ranked
    local provider = source.new({ rank_delay_ms = 0 })
    provider:get_completions(context(bufnr, "@src", 4), function(value) ranked = value end)
    wait_for(function() return ranked ~= nil end)
    equal(vim.tbl_map(function(item) return item.label end, ranked.items), { "src/" })
    local nested
    provider:get_completions(context(bufnr, "@src/", 5), function(value) nested = value end)
    wait_for(function() return nested ~= nil end)
    equal(vim.tbl_map(function(item) return item.label end, nested.items), { "src/nested/" })
  end
  cleanup(root)
end)
vim.fn.exepath = real_exepath

check("matches anywhere in a path and collapses matches to their shallowest matching directory", function()
  local root = make_dir()
  vim.fn.mkdir(root .. "/.git", "p")
  for _, path in ipairs({
    "nvim/init.lua", "nvim/lua/file_mentions.lua", "nvim/lua/menu.lua", "nvim/tests/file_mentions.lua",
    "docs/nvim-notes.md", "tmux/agent-state/a.jsonl", "tmux/agent-state/b.jsonl", "tmux/scripts/agent-state",
  }) do
    vim.fn.mkdir(vim.fs.dirname(root .. "/" .. path), "p")
    vim.fn.writefile({ "fixture" }, root .. "/" .. path)
  end
  local bufnr = buffer(root .. "/prompt.md")
  vim.b[bufnr].file_mentions_root = root
  for _, fallback in ipairs({ false, true }) do
    test.reset()
    vim.fn.exepath = function(command)
      if fallback and (command == "fd" or command == "fdfind") then return "" end
      return real_exepath(command)
    end
    local provider = source.new({ rank_delay_ms = 0 })
    local function labels(line)
      local result
      provider:get_completions(context(bufnr, line, #line), function(value) result = value end)
      wait_for(function() return result ~= nil end)
      return vim.tbl_map(function(item) return item.label end, result.items)
    end
    local function has(list, present, absent)
      for _, path in ipairs(present) do assert(contains(list, path), "missing " .. path .. " in " .. vim.inspect(list)) end
      for _, path in ipairs(absent or {}) do assert(not contains(list, path), "unexpected " .. path .. " in " .. vim.inspect(list)) end
    end
    has(labels("@nvim"), { "nvim/", "docs/nvim-notes.md" }, { "nvim/init.lua", "nvim/lua/", "nvim/lua/menu.lua" })
    has(labels("@fment"), { "nvim/lua/file_mentions.lua", "nvim/tests/file_mentions.lua" })
    has(labels("@agent-state"), { "tmux/agent-state/", "tmux/scripts/agent-state" }, { "tmux/agent-state/a.jsonl" })
    has(labels("@lua/menu"), { "nvim/lua/menu.lua" })
    has(labels("@nvim/"), { "nvim/init.lua", "nvim/lua/", "nvim/tests/" }, { "nvim/lua/menu.lua" })
    equal(labels("@nvim/fment")[1], "nvim/lua/file_mentions.lua")
    has(labels("@FMent"), { "nvim/lua/file_mentions.lua" }, {})
  end
  vim.fn.exepath = real_exepath
  cleanup(root)
end)
vim.fn.exepath = real_exepath

check("ranks a matching directory by its name, not as a parent of its own slash", function()
  test.reset()
  local root = make_dir()
  local paths = { "Daily/", "Daily/Mon 19 Jan.md" }
  for index = 1, 20 do paths[#paths + 1] = ".smart-env/multi/Daily_" .. index .. "_md.ajson" end
  test.set_runner(function(_, _, done)
    done(vim.deepcopy(paths))
    return { kill = function() end }
  end)
  local bufnr = buffer(root .. "/prompt.md")
  vim.b[bufnr].file_mentions_root = root
  local result
  source.new({ rank_delay_ms = 0 }):get_completions(context(bufnr, "@Daily", 6), function(value) result = value end)
  wait_for(function() return result ~= nil end)
  equal(result.items[1].label, "Daily/")
  cleanup(root)
end)

check("menu text drops the typed directory prefix and elides long paths from the left", function()
  equal(source.display({ label = "~/Developer/brain/Daily/", data = { prefix = "~/Developer/brain/" } }), "Daily/")
  equal(source.display({ label = "nvim/", data = { prefix = "nvim/" } }), "nvim/")
  equal(source.display({ label = "a/b/c/long-name.md", data = { prefix = "" } }, 10), "…g-name.md")
  equal(source.display({ label = "Searching..." }), "Searching...")
end)

check("highlights the characters the query matched in the visible text", function()
  local function marked(item, width)
    local text, ranges = source.render(item, width)
    table.sort(ranges, function(a, b) return a[1] < b[1] end)
    return table.concat(vim.tbl_map(function(range) return text:sub(range[1] + 1, range[2]) end, ranges))
  end
  local item = { label = "nvim/lua/file_mentions.lua", data = { prefix = "", query = "fm" } }
  local _, ranges = source.render(item)
  table.sort(ranges, function(a, b) return a[1] < b[1] end)
  equal(ranges, { { 9, 10 }, { 14, 15 } }, "fzf's tightest match: the f of file and the m of mentions")
  equal(marked({ label = "~/Developer/brain/Daily/", data = { prefix = "~/Developer/brain/", query = "dai" } }), "Dai")
  equal(marked({ label = "docs/hello world.md", data = { prefix = "", query = "world hel !md" } }), "helworld")
  equal(marked({ label = "a/b/cccccccc/file.md", data = { prefix = "", query = "abfile" } }, 9), "file")
  equal(marked({ label = "café/Über.md", data = { prefix = "", query = "éü" } }), "éÜ")
end)

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
  local paths = { "hello world.md", "handler.lua", "README.md", "reader.md" }
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
    local expected = vim.system({ "fzf", "--read0", "--print0", "--scheme=path", "-i", "--filter=" .. query }, {
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

check("scans explicit directory prefixes and accepts nested traversal with either scanner", function()
  local tree = make_dir()
  local root = tree .. "/workspace/project"
  for _, path in ipairs({
    ".git", "workspace/project/.git", "workspace/sibling/deep", "workspace/folder with spaces",
    "workspace/node_modules", "workspace/dist", "workspace/ignored",
  }) do
    vim.fn.mkdir(tree .. "/" .. path, "p")
  end
  for _, path in ipairs({
    "ancestor.md", "workspace/LICENSE", "workspace/parent.md", "workspace/.hidden.md",
    "workspace/project/local.md", "workspace/sibling/deep/note.md",
    "workspace/folder with spaces/note.md", "workspace/node_modules/noise.md",
    "workspace/dist/noise.md", "workspace/ignored/noise.md",
  }) do
    vim.fn.writefile({ "fixture" }, tree .. "/" .. path)
  end
  vim.fn.writefile({ "ignored/" }, tree .. "/workspace/.gitignore")
  local bufnr = buffer(root .. "/prompt.md")
  equal(test.root(bufnr), canonical(root))

  for _, fallback in ipairs({ false, true }) do
    test.reset()
    vim.fn.exepath = function(command)
      if fallback and (command == "fd" or command == "fdfind") then return "" end
      return real_exepath(command)
    end
    local provider = source.new({ rank_delay_ms = 0 })
    local function complete(line, byte_col)
      local result
      provider:get_completions(context(bufnr, line, byte_col or #line), function(value) result = value end)
      wait_for(function() return result ~= nil end)
      return result.items
    end
    local function accept(line, label, expected, byte_col)
      local item = item_with_label(complete(line, byte_col), label)
      local edit = item.textEdit
      equal(line:sub(1, edit.range.start.character) .. edit.newText .. line:sub(edit.range["end"].character + 1), expected)
    end

    local labels = vim.tbl_map(function(item) return item.label end, complete("@../"))
    for _, path in ipairs({ "../LICENSE", "../parent.md", "../.hidden.md", "../sibling/", "../project/" }) do
      assert(contains(labels, path), "missing ancestor path: " .. path)
    end
    for _, path in ipairs({ "../.git/", "../project/.git/", "../node_modules/", "../node_modules/noise.md", "../dist/noise.md", "../ignored/noise.md", "../sibling/deep/note.md", "../project/local.md" }) do
      assert(not contains(labels, path), "excluded ancestor path: " .. path)
    end
    -- LICENSE contains no dot, so the ../ prefix must not reach fzf.
    accept("see @../LICENSE", "../LICENSE", "see @../LICENSE")
    accept("see @../../ancestor", "../../ancestor.md", "see @../../ancestor.md")
    accept("@../../workspace/sibling/deep/ntmd", "../../workspace/sibling/deep/note.md", "@../../workspace/sibling/deep/note.md")
    accept('open @"../folder with sp', "../folder with spaces/", 'open @"../folder with spaces/"')
    accept('open @"../folder with spaces/nt', "../folder with spaces/note.md", 'open @"../folder with spaces/note.md"')
    accept("@../sibling/../LICENSE", "../sibling/../LICENSE", "@../sibling/../LICENSE")
    accept("@../sibling/deep/../../LICENSE", "../sibling/deep/../../LICENSE", "@../sibling/deep/../../LICENSE")
    equal(complete("@missing/"), {}, "nonexistent directories must not scan the root")
    local quoted = 'read @"../../ancestor", next'
    accept(quoted, "../../ancestor.md", 'read @"../../ancestor.md", next', #'read @"../../ancestor')
    local grandparents = vim.tbl_map(function(item) return item.label end, complete("@../../"))
    assert(contains(grandparents, "../../ancestor.md"), "empty repeated traversal must list the ancestor")
    -- A prefixed response must not mutate the cached unprefixed paths.
    accept("@../LICENSE", "../LICENSE", "@../LICENSE")
    accept("@local", "local.md", "@local.md")
  end
  vim.fn.exepath = real_exepath
  cleanup(tree)
end)
vim.fn.exepath = real_exepath

check("shares ancestor caches without prefixes and cancels stale ancestor scans", function()
  test.reset()
  local tree = make_dir()
  local root = tree .. "/child/project"
  vim.fn.mkdir(root, "p")
  local bufnr = buffer(root .. "/prompt.md")
  vim.b[bufnr].file_mentions_root = root
  local jobs, results = {}, {}
  test.set_runner(function(_, opts, done)
    local job = { cwd = opts.cwd, done = done }
    jobs[#jobs + 1] = job
    return { kill = function() job.killed = true end }
  end)
  local provider = source.new({ rank_delay_ms = 0 })
  local function request(line)
    return provider:get_completions(context(bufnr, line, #line), function(value)
      results[#results + 1] = value
    end)
  end
  request("@../")
  equal(jobs[1].cwd, canonical(tree .. "/child"))
  request("@../../")
  assert(jobs[1].killed, "changing ancestor must cancel the previous scan")
  equal(jobs[2].cwd, canonical(tree))
  jobs[1].done({ "stale.md" })
  jobs[2].done({ "fresh.md" })
  wait_for(function() return #results == 1 end)
  equal(results[1].items[1].textEdit.newText, "@../../fresh.md")

  -- The same resolved root can have a different textual traversal prefix.
  vim.b[bufnr].file_mentions_root = tree .. "/child"
  request("@../")
  wait_for(function() return #results == 2 end)
  equal(#jobs, 2)
  equal(results[2].items[1].textEdit.newText, "@../fresh.md")
  -- Inside its own project the same directory is searched without a depth
  -- limit, so it must not reuse the depth-limited ancestor listing.
  vim.b[bufnr].file_mentions_root = tree
  request("@")
  equal(#jobs, 3)
  jobs[3].done({ "fresh.md" })
  wait_for(function() return #results == 3 end)
  equal(results[3].items[1].textEdit.newText, "@fresh.md")

  vim.b[bufnr].file_mentions_root = root
  local cancel = request("@../")
  equal(#jobs, 4, "cancelled ancestor must not seed its cache")
  cancel()
  assert(jobs[4].killed)
  jobs[4].done({ "cancelled.md" })
  vim.wait(30)
  equal(#results, 3)
  request("@../")
  equal(#jobs, 5)
  jobs[5].done({ "parent.md" })
  wait_for(function() return #results == 4 end)
  equal(results[4].items[1].textEdit.newText, "@../parent.md")
  cleanup(tree)
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

check("strips traversal from fzf and cancels obsolete ancestor rankings", function()
  test.reset()
  local tree = make_dir()
  local root = tree .. "/child/project"
  vim.fn.mkdir(root, "p")
  local bufnr = buffer(root .. "/prompt.md")
  vim.b[bufnr].file_mentions_root = root
  local scans, jobs, results = {}, {}, {}
  test.set_runner(function(_, opts, done)
    scans[#scans + 1] = opts.cwd
    done({ "old.md", "new.md" })
    return { kill = function() end }
  end)
  vim.system = function(argv, opts, done)
    local job = { argv = argv, opts = opts, done = done }
    jobs[#jobs + 1] = job
    return { kill = function() job.killed = true end }
  end
  local provider = source.new({ rank_delay_ms = 0 })
  local function request(line, instance)
    return (instance or provider):get_completions(context(bufnr, line, #line), function(value)
      results[#results + 1] = value
    end)
  end
  request("@../../old")
  wait_for(function() return #jobs == 1 end)
  equal(scans[1], canonical(tree))
  assert(contains(jobs[1].argv, "--filter=old"))
  equal(jobs[1].opts.stdin, "new.md\0old.md\0")
  request('@"../new')
  wait_for(function() return #jobs == 2 end)
  assert(jobs[1].killed, "changing traversal must kill obsolete fzf")
  equal(scans[2], canonical(tree .. "/child"))
  assert(contains(jobs[2].argv, "--filter=new"))
  equal(jobs[2].opts.stdin, "new.md\0old.md\0")
  jobs[1].done({ code = 0, stdout = "old.md\0" })
  jobs[2].done({ code = 0, stdout = "new.md\0" })
  wait_for(function() return #results == 1 end)
  equal(results[1].items[1].textEdit.newText, '@"../new.md"')

  local cancel = request("@../../old")
  wait_for(function() return #jobs == 3 end)
  equal(#scans, 2, "ranking must reuse the resolved ancestor cache")
  cancel()
  assert(jobs[3].killed)
  jobs[3].done({ code = 0, stdout = "old.md\0" })
  vim.wait(30)
  equal(#results, 1)

  local delayed = source.new({ rank_delay_ms = 50 })
  local cancel_delayed = request("@../../old", delayed)
  cancel_delayed()
  vim.wait(80)
  equal(#jobs, 3, "cancelled delayed ranking must not launch fzf")
  equal(#results, 1)
  cleanup(tree)
end)
vim.system = real_system

check("resolves directory prefixes with filesystem traversal and preserves their spelling", function()
  test.reset()
  equal(source.resolve_query, test.resolve_query)
  local tree = make_dir()
  local root = tree .. "/project"
  vim.fn.mkdir(root .. "/src/nested", "p")
  vim.fn.mkdir(tree .. "/elsewhere/deep", "p")
  assert(vim.uv.fs_symlink(tree .. "/elsewhere/deep", root .. "/link"))
  equal(source.resolve_query(root, "src"), { directory = canonical(root), prefix = "", query = "src" })
  equal(source.resolve_query(root, "src/nested/../../rd"), {
    directory = canonical(root), prefix = "src/nested/../../", query = "rd",
  })
  equal(source.resolve_query(root, "link/../rd"), {
    directory = canonical(tree .. "/elsewhere"), prefix = "link/../", query = "rd",
  }, ".. after a symlink must use the filesystem target's parent")
  equal(source.resolve_query(root, "does-not-exist/rd"), {
    directory = canonical(root), prefix = "", query = "does-not-exist/rd",
  }, "an unknown relative prefix is fuzzy-matched against the whole project")
  assert(source.resolve_query(root, "../does-not-exist/rd") == nil)
  assert(source.resolve_query(root, "~/does-not-exist/rd") == nil)
  vim.fn.mkdir(root .. "/bad\tdir", "p")
  assert(source.resolve_query(root, "bad\tdir/") == nil, "control characters in a typed prefix must not bypass mention safety")
  cleanup(tree)
end)

check("lists fixture home directories with literal tilde prefixes using either scanner", function()
  local root, homedir = make_dir(), make_dir()
  vim.fn.mkdir(homedir .. "/.git", "p")
  for _, path in ipairs({ "docs/nested", "empty", "folder with spaces", "ignored", "node_modules", ".config" }) do
    vim.fn.mkdir(homedir .. "/" .. path, "p")
  end
  for _, path in ipairs({ "home.md", ".hidden.md", "docs/readme.md", "docs/nested/note.md", "folder with spaces/note.md", "ignored/noise.md" }) do
    vim.fn.writefile({ "fixture" }, homedir .. "/" .. path)
  end
  vim.fn.writefile({ "ignored/" }, homedir .. "/.gitignore")
  vim.fn.writefile({ "local.md" }, root .. "/local.md")
  local bufnr = buffer(root .. "/prompt.md")
  vim.b[bufnr].file_mentions_root = root
  for _, fallback in ipairs({ false, true }) do
    test.reset()
    test.set_home(function() return homedir end)
    vim.fn.exepath = function(command)
      if fallback and (command == "fd" or command == "fdfind") then return "" end
      return real_exepath(command)
    end
    local provider = source.new({ rank_delay_ms = 0 })
    local function complete(line)
      local result
      provider:get_completions(context(bufnr, line, #line), function(value) result = value end)
      wait_for(function() return result ~= nil end)
      return result.items
    end
    local bare = complete("@~")
    equal(vim.tbl_map(function(item) return item.label end, bare),
      vim.tbl_map(function(item) return item.label end, complete("@~/")))
    for _, path in ipairs({ "~/home.md", "~/.hidden.md", "~/docs/", "~/folder with spaces/", not fallback and "~/empty/" or nil }) do
      local item = item_with_label(bare, path)
      assert(not item.textEdit.newText:find(homedir, 1, true), "never insert the expanded home path")
    end
    equal(item_with_label(bare, "~/home.md").textEdit.newText, "@~/home.md")
    local labels = vim.tbl_map(function(item) return item.label end, bare)
    for _, path in ipairs({ "~/ignored/", "~/node_modules/", "~/.git/", "~/docs/readme.md", "local.md" }) do
      assert(not contains(labels, path), "unexpected home path: " .. path)
    end
    equal(vim.tbl_map(function(item) return item.label end, complete("@~/docs/")), { "~/docs/nested/", "~/docs/readme.md" })
    equal(item_with_label(complete("@~/docs/rd"), "~/docs/readme.md").textEdit.newText, "@~/docs/readme.md")
    equal(item_with_label(complete("@~/docs/nested/nt"), "~/docs/nested/note.md").textEdit.newText, "@~/docs/nested/note.md")
    equal(item_with_label(complete("@~/docs/../hm"), "~/docs/../home.md").textEdit.newText, "@~/docs/../home.md")
    equal(item_with_label(complete('@"~/folder with spaces/nt'), "~/folder with spaces/note.md").textEdit.newText,
      '@"~/folder with spaces/note.md"')

    -- Visibility settings must not reuse a more permissive cached listing.
    provider = source.new({ include_hidden = false, rank_delay_ms = 0 })
    labels = vim.tbl_map(function(item) return item.label end, complete("@~/"))
    assert(not contains(labels, "~/.hidden.md") and not contains(labels, "~/.config/"))
    provider = source.new({ excludes = { "docs", "empty" }, rank_delay_ms = 0 })
    labels = vim.tbl_map(function(item) return item.label end, complete("@~/"))
    assert(not contains(labels, "~/docs/") and not contains(labels, "~/empty/"), "custom excludes must not reuse a permissive cached listing")
  end
  vim.fn.exepath = real_exepath
  cleanup(root)
  cleanup(homedir)
end)
vim.fn.exepath = real_exepath

check("caches resolved home and nested directories without retaining textual prefixes", function()
  test.reset()
  local root, homedir = make_dir(), make_dir()
  vim.fn.mkdir(root .. "/src", "p")
  vim.fn.mkdir(homedir .. "/docs", "p")
  test.set_home(function() return homedir end)
  local bufnr = buffer(root .. "/prompt.md")
  vim.b[bufnr].file_mentions_root = root
  local scans, results = {}, {}
  test.set_runner(function(_, opts, done)
    scans[#scans + 1] = opts.cwd
    done({ "note.md", "unsafe\"name", "bad\nname", "descendant/note.md" })
    return { kill = function() end }
  end)
  local provider = source.new({ rank_delay_ms = 0 })
  local function complete(line)
    provider:get_completions(context(bufnr, line, #line), function(value) results[#results + 1] = value end)
    wait_for(function() return #results > 0 end)
    local result = table.remove(results)
    return vim.tbl_map(function(item) return item.label end, result.items)
  end
  equal(complete("@~"), { "~/note.md" })
  equal(complete("@~/"), { "~/note.md" })
  equal(complete("@~/docs/../"), { "~/docs/../note.md" })
  equal(#scans, 1)
  equal(scans[1], canonical(homedir))
  equal(complete("@~/docs/"), { "~/docs/note.md" })
  equal(#scans, 2)
  equal(scans[2], canonical(homedir .. "/docs"))
  equal(complete("@src/"), { "src/note.md" })
  equal(#scans, 3)
  equal(scans[3], canonical(root .. "/src"))
  equal(complete("@src/../src/"), { "src/../src/note.md" })
  equal(#scans, 3)
  equal(complete("@src/../"), { "src/../note.md" })
  equal(complete("@"), { "note.md" })
  equal(#scans, 4)
  cleanup(root)
  cleanup(homedir)
end)

test.reset()
if #failures > 0 then
  error(table.concat(failures, "\n\n"))
end

print("file_mentions tests passed")
