local H = require("helpers")
local source = require("canvasdiff.source")
local system = require("canvasdiff.os")

local function sh(root, cmd)
  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  return res.stdout
end

local function write(root, rel, content)
  local abs = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(vim.fs.dirname(abs), "p")
  local f = assert(io.open(abs, "w"))
  f:write(content)
  f:close()
end

return {
  ["source_ facade exports exactly repository and collection operations"] = function()
    local names = vim.tbl_keys(source)
    table.sort(names)
    H.eq(names, {
      "branches",
      "buffer_modified",
      "changed_files",
      "diff_files",
      "file_stream",
      "files",
      "merge_base",
      "resolve_commit",
      "root",
      "section_stream",
      "sections",
      "show",
      "show_head",
      "stage",
      "unstage",
      "worktree_text",
    })
    for _, name in ipairs(names) do
      H.eq(type(source[name]), "function", name .. " is callable")
    end
  end,
  ["source_ legacy git module path is deleted rather than shimmed"] = function()
    package.loaded["canvasdiff.git"] = nil
    local loaded = pcall(require, "canvasdiff.git")
    assert(not loaded, "canvasdiff.git must not remain as a forwarding module")
  end,
  ["source_ legacy collect module path is deleted rather than shimmed"] = function()
    package.loaded["canvasdiff.collect"] = nil
    local loaded = pcall(require, "canvasdiff.collect")
    assert(not loaded, "canvasdiff.collect must not remain as a forwarding module")
  end,
  -- Ingestion is where a million-line changeset either fits in memory or does
  -- not. Reading every file's two sides up front is the eager convenience;
  -- these prove the streaming boundary underneath it never does that.
  ["source_ file_stream reads one file's sides at a time"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "a\n", ["b.txt"] = "b\n", ["c.txt"] = "c\n" },
      worktree = { ["a.txt"] = "A\n", ["b.txt"] = "B\n", ["c.txt"] = "C\n" },
    })
    -- Observed at the OS boundary, which is the only seam a test outside the
    -- source domain is allowed to reach.
    local reads = {}
    local real_run = system.run
    local ok, err = xpcall(function()
      system.run = function(cmd, opts)
        for index, word in ipairs(cmd) do
          if word == "show" and cmd[index + 1] then
            reads[#reads + 1] = cmd[index + 1]:match(":(.*)$")
          end
        end
        return real_run(cmd, opts)
      end
      local next_file, stream_err = source.file_stream(root, "HEAD")
      assert(next_file, stream_err)
      H.eq(reads, {}, "planning reads no file content at all")

      local first = assert(next_file())
      H.eq(first.path, "a.txt")
      H.eq(reads, { "a.txt" }, "only the file asked for was read")
      H.eq(first.old_text, "a\n")
      H.eq(first.new_text, "A\n")

      local second = assert(next_file())
      H.eq(second.path, "b.txt")
      H.eq(reads, { "a.txt", "b.txt" })

      assert(next_file(), "c.txt")
      H.eq(next_file(), nil, "the stream ends after the last planned file")
      H.eq(reads, { "a.txt", "b.txt", "c.txt" },
        "each file is read exactly once, in path order")
    end, debug.traceback)
    system.run = real_run
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
  ["source_ section_stream retains only the section it just built"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "a\n", ["b.txt"] = "b\n" },
      worktree = { ["a.txt"] = "A\n", ["b.txt"] = "B\n" },
    })
    local ok, err = xpcall(function()
      local next_section, stream_err = source.section_stream(root, "HEAD", 3)
      assert(next_section, stream_err)

      local first = assert(next_section())
      H.eq(first.path, "a.txt")
      local weak = setmetatable({ section = first }, { __mode = "v" })
      first = nil

      local second = assert(next_section())
      H.eq(second.path, "b.txt", "the stream advances in path order")
      collectgarbage("collect")
      collectgarbage("collect")
      H.eq(weak.section, nil,
        "a consumed section is not retained by the stream that produced it")
      H.eq(next_section(), nil)
    end, debug.traceback)
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
  ["source_ a failed side aborts the stream at the file that caused it"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "a\n", ["b.txt"] = "b\n" },
      worktree = { ["a.txt"] = "A\n", ["b.txt"] = "B\n" },
    })
    sh(root, { "git", "branch", "gone", "HEAD" })
    local real_run = system.run
    local ok, err = xpcall(function()
      local lens = require("canvasdiff.diff").lens
      local spec = lens.branch("gone")
      system.run = function(cmd, opts)
        for index, word in ipairs(cmd) do
          if word == "show" and (cmd[index + 1] or ""):find("b.txt", 1, true) then
            return { code = 128, stdout = nil, stderr = "injected missing blob" }
          end
        end
        return real_run(cmd, opts)
      end
      local next_file = assert(source.file_stream(root, spec))
      local first = assert(next_file())
      H.eq(first.path, "a.txt", "files before the failure still stream")
      local failed, stream_err = next_file()
      H.eq(failed, nil)
      assert(stream_err and stream_err:find("b.txt", 1, true),
        "the error names the file that caused it: " .. tostring(stream_err))

      -- And the eager collector still reports it transactionally.
      local sections, sections_err = source.sections(root, spec, 3)
      H.eq(sections, nil, "a failed side yields no partial section list")
      assert(sections_err and sections_err:find("b.txt", 1, true), sections_err)
    end, debug.traceback)
    system.run = real_run
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
  ["source_ worktree disk reads use the os facade and contain failures"] = function()
    local root = H.git_fixture({
      committed = { ["f.txt"] = "old\n" },
      worktree = { ["f.txt"] = "disk\n" },
    })
    local path = vim.fs.joinpath(root, "f.txt")
    local real_read_file = system.read_file
    local calls = {}

    local ok, err = xpcall(function()
      system.read_file = function(next_path)
        calls[#calls + 1] = next_path
        return "adapter\n"
      end
      local files, collect_err = source.files(root, "HEAD")
      assert(files, collect_err)
      H.eq(#files, 1)
      H.eq(files[1].new_text, "adapter\n")
      H.eq(calls, { path })

      system.read_file = function(next_path)
        H.eq(next_path, path)
        error("injected source disk read failure")
      end
      local fallback, fallback_err = source.files(root, "HEAD")
      assert(fallback, fallback_err)
      H.eq(fallback[1].new_text, "",
        "an unreadable worktree path keeps the legacy empty-side semantics")
    end, debug.traceback)

    system.read_file = real_read_file
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
  ["git: delegates raw process execution through the os facade"] = function()
    local real_run = system.run
    local command, opts, root
    system.run = function(next_command, next_opts)
      command, opts = next_command, next_opts
      return { code = 0, stdout = "/resolved/root\r\n", stderr = "" }
    end

    local ok, err = xpcall(function()
      root = source.root("/worktree")
    end, debug.traceback)

    system.run = real_run
    assert(ok, err)
    H.eq(root, "/resolved/root")
    H.eq(command, { "git", "-C", "/worktree", "rev-parse", "--show-toplevel" })
    H.eq(opts, { text = false })
  end,
  ["git: root finds toplevel, nil outside"] = function()
    local root = H.git_fixture({ committed = { ["a.txt"] = "x\n" } })
    H.eq(source.root(root), (vim.uv.fs_realpath(root)))
    H.eq(source.root(H.tmpdir()), nil)
  end,
  ["git: changed_files lists M, A(?), D sorted"] = function()
    local root = H.git_fixture({
      committed = { ["b.txt"] = "old\n", ["gone.txt"] = "bye\n" },
      worktree = { ["b.txt"] = "new\n", ["a_new.txt"] = "hi\n", ["gone.txt"] = false },
    })
    local files = source.changed_files(root)
    local got = {}
    for _, f in ipairs(files) do got[#got + 1] = f.path .. ":" .. f.status end
    H.eq(got, { "a_new.txt:?", "b.txt:M", "gone.txt:D" })
  end,
  ["git: show_head returns committed content, nil for untracked"] = function()
    local root = H.git_fixture({
      committed = { ["b.txt"] = "old\n" },
      worktree = { ["b.txt"] = "new\n", ["u.txt"] = "u\n" },
    })
    H.eq(source.show_head(root, "b.txt"), "old\n")
    H.eq(source.show_head(root, "u.txt"), nil)
  end,
  ["git: resolve_commit returns a canonical oid and rejects invalid refs"] = function()
    local root = H.git_fixture({ committed = { ["a.txt"] = "x\n" } })
    local expected = vim.trim(sh(root, { "git", "rev-parse", "HEAD" }))

    H.eq(source.resolve_commit(root, "HEAD"), expected)
    H.eq(source.resolve_commit(root, "main"), expected)

    local missing, err = source.resolve_commit(root, "definitely-not-a-ref")
    H.eq(missing, nil)
    assert(type(err) == "string" and err:find("does not resolve", 1, true),
      "invalid ref needs an actionable error, got: " .. tostring(err))

    local option_like, option_err =
      source.resolve_commit(root, "--definitely-not-an-option")
    H.eq(option_like, nil, "--end-of-options must make this a ref, never an option")
    assert(option_err, "option-looking invalid ref must still return an error")
  end,
  ["git: branches preserves full ref identity and classifies picker metadata"] = function()
    local root = H.git_fixture({ committed = { ["a.txt"] = "x\n" } })
    sh(root, { "git", "branch", "zeta" })
    sh(root, { "git", "branch", "alpha" })
    sh(root, { "git", "branch", "origin/topic" })
    sh(root, { "git", "commit", "--allow-empty", "-m", "distinct remote tip" })
    sh(root, { "git", "update-ref", "refs/remotes/origin/topic", "HEAD" })
    sh(root, { "git", "symbolic-ref", "refs/remotes/origin/HEAD",
      "refs/remotes/origin/topic" })

    local refs, err = source.branches(root)
    assert(refs, err)
    H.eq(refs, {
      {
        ref = "refs/heads/alpha", name = "alpha", kind = "local",
        current = false,
      },
      {
        ref = "refs/heads/origin/topic", name = "heads/origin/topic",
        kind = "local", current = false,
      },
      {
        ref = "refs/heads/main", name = "main", kind = "local",
        current = true,
      },
      {
        ref = "refs/remotes/origin/HEAD", name = "origin/HEAD",
        kind = "remote", remote_default = true,
      },
      {
        ref = "refs/remotes/origin/topic", name = "remotes/origin/topic",
        kind = "remote",
      },
      {
        ref = "refs/heads/zeta", name = "zeta", kind = "local",
        current = false,
      },
    }, "full refs prevent a same-named local and remote branch becoming ambiguous")
    local local_tip = assert(source.resolve_commit(root, "heads/origin/topic"))
    local remote_tip = assert(source.resolve_commit(root, "remotes/origin/topic"))
    assert(local_tip ~= remote_tip,
      "Git-disambiguated completion names must resolve both distinct tips")
    vim.fn.delete(root, "rf")
  end,
  ["git: merge_base resolves refs to their common commit"] = function()
    local root = H.git_fixture({ committed = { ["common.txt"] = "base\n" } })
    local base = assert(source.resolve_commit(root, "HEAD"))
    sh(root, { "git", "branch", "left" })
    write(root, "right.txt", "right\n")
    sh(root, { "git", "add", "-A" })
    sh(root, { "git", "commit", "-m", "right tip" })
    sh(root, { "git", "branch", "right" })
    sh(root, { "git", "switch", "left" })
    write(root, "left.txt", "left\n")
    sh(root, { "git", "add", "-A" })
    sh(root, { "git", "commit", "-m", "left tip" })

    H.eq(source.merge_base(root, "left", "right"), base)
    local missing, err = source.merge_base(root, "--not-an-option", "right")
    H.eq(missing, nil)
    assert(err and err:find("does not resolve", 1, true), tostring(err))
    vim.fn.delete(root, "rf")
  end,
  ["git: diff_files enumerates clean committed A D M R relative to an old commit"] = function()
    local root = H.git_fixture({
      committed = {
        ["deleted.txt"] = "delete me\n",
        ["modified.txt"] = "before\n",
        ["old-name.txt"] = "rename-only unique body\n",
      },
    })
    local base = assert(source.resolve_commit(root, "HEAD"))

    write(root, "added.txt", "added later\n")
    write(root, "modified.txt", "after\n")
    assert(vim.fn.delete(vim.fs.joinpath(root, "deleted.txt")) == 0)
    sh(root, { "git", "mv", "old-name.txt", "renamed.txt" })
    sh(root, { "git", "add", "-A" })
    sh(root, { "git", "commit", "-m", "advance fixture" })

    local files, err = source.diff_files(root, base)
    assert(files, err)
    local got = {}
    for _, f in ipairs(files) do
      got[#got + 1] = {
        path = f.path,
        old_path = f.old_path,
        status = f.status,
      }
    end
    H.eq(got, {
      { path = "added.txt", old_path = "added.txt", status = "A" },
      { path = "deleted.txt", old_path = "deleted.txt", status = "D" },
      { path = "modified.txt", old_path = "modified.txt", status = "M" },
      { path = "renamed.txt", old_path = "old-name.txt", status = "R" },
    })
  end,
  ["git: diff_files NUL parsing preserves whitespace and option-looking paths"] = function()
    local paths = {
      "-leading.txt",
      "line\nbreak.txt",
      "space name.txt",
      "tab\tname.txt",
    }
    local committed = {}
    for _, path in ipairs(paths) do
      committed[path] = "before\n"
    end
    local root = H.git_fixture({ committed = committed })
    local base = assert(source.resolve_commit(root, "HEAD"))
    for _, path in ipairs(paths) do
      write(root, path, "after\n")
    end

    local files, err = source.diff_files(root, base)
    assert(files, err)
    local got = {}
    for _, f in ipairs(files) do
      got[#got + 1] = f.path
      H.eq(f.old_path, f.path)
      H.eq(f.status, "M")
    end
    table.sort(paths)
    H.eq(got, paths, "paths are NUL fields, never whitespace-split or trimmed")
  end,
  ["git: diff_files compares two committed sides and preserves unusual paths"] = function()
    local paths = {
      "-leading.txt",
      "line\nbreak.txt",
      "space name.txt",
      "tab\tname.txt",
    }
    local committed = {}
    for _, path in ipairs(paths) do
      committed[path] = "left\n"
    end
    local root = H.git_fixture({ committed = committed })
    local left = assert(source.resolve_commit(root, "HEAD"))
    for _, path in ipairs(paths) do
      write(root, path, "right\n")
    end
    sh(root, { "git", "add", "-A" })
    sh(root, { "git", "commit", "-m", "right side" })
    local right = assert(source.resolve_commit(root, "HEAD"))
    for _, path in ipairs(paths) do
      write(root, path, "left\n")
    end

    local files, err = source.diff_files(root, left, right)
    assert(files, err)
    local got = {}
    for _, file in ipairs(files) do
      got[#got + 1] = file.path
      H.eq(file.old_path, file.path)
      H.eq(file.status, "M")
    end
    table.sort(paths)
    H.eq(got, paths)
    vim.fn.delete(root, "rf")
  end,
  ["git: porcelain rename keeps the original path"] = function()
    local root = H.git_fixture({ committed = { ["old name.txt"] = "same\n" } })
    sh(root, { "git", "mv", "old name.txt", "new name.txt" })

    local files, err = source.changed_files(root)
    assert(files, err)
    H.eq(#files, 1)
    H.eq(files[1].path, "new name.txt")
    H.eq(files[1].old_path, "old name.txt")
    H.eq(files[1].status, "R")
    H.eq(files[1].staged, "R")
    H.eq(files[1].unstaged, nil)
  end,
  ["git: stage captures the complete current disk state for mixed and unusual paths"] = function()
    local paths = { "-leading.txt", "space name.txt", "tab\tname.txt" }
    local committed = {}
    for _, path in ipairs(paths) do committed[path] = "head\n" end
    local root = H.git_fixture({ committed = committed })
    for _, path in ipairs(paths) do
      write(root, path, "index\n")
      sh(root, { "git", "add", "--", path })
      write(root, path, "disk\n")
      local ok, err = source.stage(root, { path = path, old_path = path })
      assert(ok, err)
      H.eq(source.show(root, ":0", path), "disk\n",
        "an unstaged Y column wins over the already-staged X column")
    end
    vim.fn.delete(root, "rf")
  end,
  ["git: stage treats pathspec-magic filenames literally and isolates index scope"] = function()
    local magic = ":(glob)*.txt"
    local root = H.git_fixture({
      committed = {
        [magic] = "magic head\n",
        ["victim.txt"] = "victim head\n",
      },
    })
    write(root, magic, "magic disk\n")
    write(root, "victim.txt", "victim disk\n")
    local ok, err = source.stage(root, { path = magic, unstaged = "M" })
    assert(ok, err)
    H.eq(source.show(root, ":0", magic), "magic disk\n")
    H.eq(source.show(root, ":0", "victim.txt"), "victim head\n",
      "magic-looking user data must not expand to another index entry")
    vim.fn.delete(root, "rf")
  end,
  ["git: stage rejects an old-path-only identity without widening index scope"] = function()
    local root = H.git_fixture({
      committed = {
        ["old.txt"] = "old head\n",
        ["unrelated.txt"] = "unrelated head\n",
      },
      worktree = {
        ["old.txt"] = "old disk\n",
        ["unrelated.txt"] = "unrelated disk\n",
      },
    })
    local changed, err = source.stage(root, { old_path = "old.txt" })
    H.eq(changed, nil)
    assert(err and err:find("path", 1, true), tostring(err))
    H.eq(source.show(root, ":0", "old.txt"), "old head\n")
    H.eq(source.show(root, ":0", "unrelated.txt"), "unrelated head\n",
      "malformed identity must never degrade to repository-wide git add")
    vim.fn.delete(root, "rf")
  end,
  ["git: unstage treats pathspec-magic filenames literally and isolates index scope"] = function()
    local magic = ":(glob)*.txt"
    local root = H.git_fixture({
      committed = {
        [magic] = "magic head\n",
        ["victim.txt"] = "victim head\n",
      },
    })
    write(root, magic, "magic staged\n")
    write(root, "victim.txt", "victim staged\n")
    sh(root, { "git", "add", "-A" })
    local ok, err = source.unstage(root, { path = magic, staged = "M" })
    assert(ok, err)
    local by = {}
    for _, file in ipairs(assert(source.changed_files(root))) do by[file.path] = file end
    assert(by[magic].unstaged and not by[magic].staged, vim.inspect(by[magic]))
    assert(by["victim.txt"].staged and not by["victim.txt"].unstaged,
      "literal unstage must leave the neighbouring staged entry intact")
    vim.fn.delete(root, "rf")
  end,
  ["git: stage and unstage cover additions deletions and both rename paths"] = function()
    local root = H.git_fixture({
      committed = { ["delete.txt"] = "gone\n", ["old name.txt"] = "rename\n" },
    })
    write(root, "new file.txt", "new\n")
    vim.fn.delete(vim.fs.joinpath(root, "delete.txt"))
    sh(root, { "git", "mv", "old name.txt", "new name.txt" })

    assert(source.stage(root, { path = "new file.txt", status = "?" }))
    assert(source.stage(root, { path = "delete.txt", status = "D" }))
    assert(source.stage(root, {
      path = "new name.txt", old_path = "old name.txt", status = "R",
    }))
    local staged = source.changed_files(root)
    for _, file in ipairs(staged) do
      assert(file.staged and not file.unstaged,
        "every complete disk state is staged: " .. vim.inspect(file))
    end

    for _, file in ipairs(staged) do
      assert(source.unstage(root, file))
    end
    local unstaged = source.changed_files(root)
    for _, file in ipairs(unstaged) do
      assert(file.unstaged and not file.staged,
        "unstage resets only the index and preserves worktree bytes: " .. vim.inspect(file))
    end
    H.eq(system.read_file(vim.fs.joinpath(root, "new file.txt")), "new\n")
    H.eq(system.read_file(vim.fs.joinpath(root, "new name.txt")), "rename\n")
    vim.fn.delete(root, "rf")
  end,
  ["git: unborn unstage falls back only after reset explicitly fails"] = function()
    local root = H.tmpdir()
    sh(root, { "git", "init", "-b", "main" })
    write(root, "-initial name.txt", "kept\n")
    sh(root, { "git", "add", "--", "-initial name.txt" })
    local commands = {}
    local real_run = system.run
    system.run = function(cmd, opts)
      commands[#commands + 1] = vim.deepcopy(cmd)
      if vim.tbl_contains(cmd, "reset") then
        return { code = 128, stdout = "", stderr = "ambiguous argument 'HEAD'\n" }
      end
      return real_run(cmd, opts)
    end
    local ok, err = source.unstage(root, { path = "-initial name.txt", staged = "A" })
    system.run = real_run
    assert(ok, err)
    H.eq(commands[1], {
      "git", "-C", root, "--literal-pathspecs",
      "reset", "HEAD", "--", "-initial name.txt",
    }, "unstage always tries the ordinary path-scoped reset first")
    H.eq(commands[#commands], {
      "git", "-C", root, "--literal-pathspecs",
      "rm", "--cached", "--ignore-unmatch", "--",
      "-initial name.txt",
    }, "only an unborn HEAD falls back to removing the path from the index")
    H.eq(system.read_file(vim.fs.joinpath(root, "-initial name.txt")), "kept\n")
    local files = assert(source.changed_files(root))
    H.eq(files, {
      {
        path = "-initial name.txt", status = "?", staged = nil, unstaged = "?",
      },
    })
    vim.fn.delete(root, "rf")
  end,
  ["git: successful unstage returns before probing HEAD or attempting fallback"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "head\n" },
      worktree = { ["a.txt"] = "staged\n" },
    })
    sh(root, { "git", "add", "--", "a.txt" })
    local commands = {}
    local real_run = system.run
    local ok, err = xpcall(function()
      system.run = function(cmd, opts)
        commands[#commands + 1] = vim.deepcopy(cmd)
        return real_run(cmd, opts)
      end
      assert(source.unstage(root, { path = "a.txt", staged = "M" }))
      H.eq(#commands, 1, "a successful reset is the terminal mutation")
      H.eq(commands[1], {
        "git", "-C", root, "--literal-pathspecs", "reset", "HEAD", "--", "a.txt",
      })
    end, debug.traceback)
    system.run = real_run
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
  ["git: failed HEAD probe is not classified as an unborn repository"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "head\n" },
      worktree = { ["a.txt"] = "staged\n" },
    })
    sh(root, { "git", "add", "--", "a.txt" })
    local real_run = system.run
    local saw_rm = false
    local ok, err = xpcall(function()
      system.run = function(cmd, opts)
        if vim.tbl_contains(cmd, "reset") then
          return { code = 128, stdout = "", stderr = "injected reset failure\n" }
        end
        if vim.tbl_contains(cmd, "rev-parse") then
          return { code = 128, stdout = "", stderr = "injected HEAD lock failure\n" }
        end
        if vim.tbl_contains(cmd, "rm") then saw_rm = true end
        return real_run(cmd, opts)
      end
      local changed, unstage_err = source.unstage(root, { path = "a.txt", staged = "M" })
      H.eq(changed, nil)
      assert(unstage_err and unstage_err:find("HEAD lock failure", 1, true),
        tostring(unstage_err))
      H.eq(saw_rm, false, "an uncertain HEAD must never select destructive fallback")
      assert(source.changed_files(root)[1].staged,
        "the tracked index entry remains staged after both injected failures")
    end, debug.traceback)
    system.run = real_run
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
  ["git: unborn fallback failure is returned and preserves the staged entry"] = function()
    local root = H.tmpdir()
    sh(root, { "git", "init", "-b", "main" })
    write(root, "a.txt", "kept\n")
    sh(root, { "git", "add", "--", "a.txt" })
    local real_run = system.run
    local ok, err = xpcall(function()
      system.run = function(cmd, opts)
        if vim.tbl_contains(cmd, "reset") then
          return { code = 128, stdout = "", stderr = "missing HEAD\n" }
        end
        if vim.tbl_contains(cmd, "rm") then
          return { code = 128, stdout = "", stderr = "injected index lock\n" }
        end
        return real_run(cmd, opts)
      end
      local changed, unstage_err = source.unstage(root, { path = "a.txt", staged = "A" })
      H.eq(changed, nil)
      assert(unstage_err and unstage_err:find("index lock", 1, true),
        tostring(unstage_err))
    end, debug.traceback)
    system.run = real_run
    local staged = assert(source.changed_files(root)[1])
    assert(staged.staged and not staged.unstaged, vim.inspect(staged))
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
  ["git: mutation failures are returned without claiming success"] = function()
    local root = H.git_fixture({ committed = { ["a.txt"] = "a\n" } })
    local real_run = system.run
    local ok, err = xpcall(function()
      system.run = function(cmd, opts)
        if vim.tbl_contains(cmd, "add") then
          return { code = 128, stdout = "", stderr = "injected add failure\n" }
        end
        return real_run(cmd, opts)
      end
      local changed, stage_err = source.stage(root, { path = "a.txt" })
      H.eq(changed, nil)
      assert(stage_err and stage_err:find("injected add failure", 1, true), stage_err)
    end, debug.traceback)
    system.run = real_run
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
  ["git: a failed mixed-rename add leaves the existing index snapshot byte-exact"] = function()
    local root = H.git_fixture({ committed = { ["old.txt"] = "old\n" } })
    sh(root, { "git", "mv", "old.txt", "new.txt" })
    write(root, "new.txt", "disk\n")
    local real_run = system.run
    local ok, err = xpcall(function()
      system.run = function(cmd, opts)
        if vim.tbl_contains(cmd, "add") then
          return { code = 128, stdout = "", stderr = "injected rename add failure\n" }
        end
        return real_run(cmd, opts)
      end
      local before = sh(root, { "git", "diff", "--cached", "--raw", "-z" })
      local before_blob = source.show(root, ":0", "new.txt")
      local changed, stage_err, index_changed = source.stage(root, {
        path = "new.txt", old_path = "old.txt", status = "R",
      })
      H.eq(changed, nil)
      assert(stage_err and stage_err:find("injected rename add failure", 1, true),
        stage_err)
      H.eq(index_changed, nil)
      H.eq(sh(root, { "git", "diff", "--cached", "--raw", "-z" }), before,
        "a failed add must not discard the already-staged rename")
      H.eq(source.show(root, ":0", "new.txt"), before_blob,
        "the staged blob remains byte-exact on failure")
    end, debug.traceback)
    system.run = real_run
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
  ["source: modified loaded buffers are detected by exact target identity"] = function()
    local root = H.git_fixture({ committed = { ["a.txt"] = "a\n" } })
    local path = vim.fs.joinpath(root, "a.txt")
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    H.eq(source.buffer_modified(root, { path = "a.txt" }), false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
    H.eq(source.buffer_modified(root, { path = "a.txt" }), true)
    H.eq(source.buffer_modified(root, { path = "other.txt" }), false)
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
    H.eq(vim.api.nvim_buf_is_loaded(buf), false)
    for _, stale in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(stale)
          and vim.api.nvim_buf_get_name(stale) == path then
        pcall(vim.api.nvim_set_option_value, "modified", false, { buf = stale })
        pcall(vim.api.nvim_buf_delete, stale, { force = true })
      end
    end
    vim.fn.delete(root, "rf")
  end,
  ["source: a stable replacement cannot clear a deleted target's alias history"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "head\n" },
      worktree = { ["a.txt"] = "disk\n" },
    })
    local path = vim.fs.joinpath(root, "a.txt")
    local alias = vim.fs.joinpath(root, "alias.txt")
    assert(vim.uv.fs_link(path, alias))
    local root_stat = assert(vim.uv.fs_stat(root))
    local replacement = vim.tbl_extend("force", assert(vim.uv.fs_stat(alias)), {
      dev = root_stat.dev + 1,
      ino = root_stat.ino + 1,
      type = "file",
    })
    local buf = vim.fn.bufadd(alias)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved vanished alias" })
    assert(vim.uv.fs_unlink(path))
    assert(vim.uv.fs_unlink(alias))

    local real_stat = vim.uv.fs_stat
    local real_lstat = vim.uv.fs_lstat
    local real_realpath = vim.uv.fs_realpath
    local stat_calls, lstat_calls = 0, 0
    local ok, err = xpcall(function()
      vim.uv.fs_stat = function(candidate, ...)
        if candidate == alias then
          stat_calls = stat_calls + 1
          return replacement
        end
        return real_stat(candidate, ...)
      end
      vim.uv.fs_lstat = function(candidate, ...)
        if candidate == alias then
          lstat_calls = lstat_calls + 1
          return replacement
        end
        return real_lstat(candidate, ...)
      end
      vim.uv.fs_realpath = function(candidate, ...)
        if candidate == alias then return alias end
        return real_realpath(candidate, ...)
      end
      H.eq(source.buffer_modified(root, {
        path = "a.txt",
        status = "D",
        unstaged = "D",
      }), true, "current pathname identity cannot erase loaded alias history")
      assert(stat_calls >= 1 and lstat_calls >= 1,
        "the stable replacement observation was not exercised")
    end, debug.traceback)
    vim.uv.fs_stat = real_stat
    vim.uv.fs_lstat = real_lstat
    vim.uv.fs_realpath = real_realpath
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
  ["source: deletion preflight blocks if the target is recreated before inspection"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "head\n" },
      worktree = { ["a.txt"] = "disk\n" },
    })
    local path = vim.fs.joinpath(root, "a.txt")
    local alias = vim.fs.joinpath(root, "alias.txt")
    assert(vim.uv.fs_link(path, alias))
    local buf = vim.fn.bufadd(alias)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved original inode" })
    assert(vim.uv.fs_unlink(path))
    assert(vim.uv.fs_unlink(alias))
    write(root, "a.txt", "replacement\n")

    H.eq(source.buffer_modified(root, {
      path = "a.txt",
      status = "D",
      unstaged = "D",
    }), true, "a recreated pathname cannot erase the deletion preflight identity")
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(root, "rf")
  end,
  ["source: a deleted target blocks when buffer identity changes during probes"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "head\n" },
      worktree = { ["a.txt"] = "disk\n" },
    })
    write(root, "other.txt", "unrelated\n")
    local unrelated = vim.fs.joinpath(root, "other.txt")
    local root_stat = assert(vim.uv.fs_stat(root))
    local buf = vim.fn.bufadd(unrelated)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved raced alias" })
    local name = vim.api.nvim_buf_get_name(buf)
    local observed = assert(vim.uv.fs_stat(name))
    local first = vim.tbl_extend("force", observed, {
      dev = root_stat.dev + 1,
      ino = observed.ino + 1,
      type = "file",
    })
    local replacement = vim.tbl_extend("force", observed, {
      dev = root_stat.dev,
      ino = observed.ino + 2,
      type = "file",
    })
    assert(vim.uv.fs_unlink(vim.fs.joinpath(root, "a.txt")))

    local real_stat = vim.uv.fs_stat
    local real_lstat = vim.uv.fs_lstat
    local name_stats, name_lstats = 0, 0
    local ok, err = xpcall(function()
      vim.uv.fs_stat = function(path, ...)
        if path == name then
          name_stats = name_stats + 1
          return name_stats == 1 and first or replacement
        end
        return real_stat(path, ...)
      end
      vim.uv.fs_lstat = function(path, ...)
        if path == name then
          name_lstats = name_lstats + 1
          return replacement
        end
        return real_lstat(path, ...)
      end
      H.eq(source.buffer_modified(root, {
        path = "a.txt",
        status = "D",
        unstaged = "D",
      }), true, "identity drift cannot authorize the cross-device exemption")
      assert(name_stats >= 1 and name_lstats >= 1,
        "the deterministic pathname transition was not exercised")
    end, debug.traceback)
    vim.uv.fs_stat = real_stat
    vim.uv.fs_lstat = real_lstat
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
  ["source: a deleted target blocks when a buffer component probe errors"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "head\n" },
      worktree = { ["a.txt"] = "disk\n" },
    })
    write(root, "other.txt", "unrelated\n")
    local unrelated = vim.fs.joinpath(root, "other.txt")
    local root_stat = assert(vim.uv.fs_stat(root))
    local buf = vim.fn.bufadd(unrelated)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved uncertain alias" })
    local name = vim.api.nvim_buf_get_name(buf)
    local observed = assert(vim.uv.fs_stat(name))
    local cross_device = vim.tbl_extend("force", observed, {
      dev = root_stat.dev + 1,
      ino = observed.ino + 1,
      type = "file",
    })
    assert(vim.uv.fs_unlink(vim.fs.joinpath(root, "a.txt")))

    local real_stat = vim.uv.fs_stat
    local real_lstat = vim.uv.fs_lstat
    local stat_calls, lstat_errors = 0, 0
    local ok, err = xpcall(function()
      vim.uv.fs_stat = function(path, ...)
        if path == name then
          stat_calls = stat_calls + 1
          return cross_device
        end
        return real_stat(path, ...)
      end
      vim.uv.fs_lstat = function(path, ...)
        if path == name then
          lstat_errors = lstat_errors + 1
          return nil, "EACCES: injected component probe failure", "EACCES"
        end
        return real_lstat(path, ...)
      end
      H.eq(source.buffer_modified(root, {
        path = "a.txt",
        status = "D",
        unstaged = "D",
      }), true, "a failed link probe leaves alias identity uncertain")
      assert(stat_calls >= 1 and lstat_errors >= 1,
        "the deterministic component-probe error was not exercised")
    end, debug.traceback)
    vim.uv.fs_stat = real_stat
    vim.uv.fs_lstat = real_lstat
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end,
}
