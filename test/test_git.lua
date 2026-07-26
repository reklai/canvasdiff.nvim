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
      "changed_files",
      "diff_files",
      "files",
      "resolve_commit",
      "root",
      "sections",
      "show",
      "show_head",
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
}
