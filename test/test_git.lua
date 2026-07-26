local H = require("helpers")
local git = require("canvasdiff.git")

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
  ["git: root finds toplevel, nil outside"] = function()
    local root = H.git_fixture({ committed = { ["a.txt"] = "x\n" } })
    H.eq(git.root(root), (vim.uv.fs_realpath(root)))
    H.eq(git.root(H.tmpdir()), nil)
  end,
  ["git: changed_files lists M, A(?), D sorted"] = function()
    local root = H.git_fixture({
      committed = { ["b.txt"] = "old\n", ["gone.txt"] = "bye\n" },
      worktree = { ["b.txt"] = "new\n", ["a_new.txt"] = "hi\n", ["gone.txt"] = false },
    })
    local files = git.changed_files(root)
    local got = {}
    for _, f in ipairs(files) do got[#got + 1] = f.path .. ":" .. f.status end
    H.eq(got, { "a_new.txt:?", "b.txt:M", "gone.txt:D" })
  end,
  ["git: show_head returns committed content, nil for untracked"] = function()
    local root = H.git_fixture({
      committed = { ["b.txt"] = "old\n" },
      worktree = { ["b.txt"] = "new\n", ["u.txt"] = "u\n" },
    })
    H.eq(git.show_head(root, "b.txt"), "old\n")
    H.eq(git.show_head(root, "u.txt"), nil)
  end,
  ["git: resolve_commit returns a canonical oid and rejects invalid refs"] = function()
    local root = H.git_fixture({ committed = { ["a.txt"] = "x\n" } })
    local expected = vim.trim(sh(root, { "git", "rev-parse", "HEAD" }))

    H.eq(git.resolve_commit(root, "HEAD"), expected)
    H.eq(git.resolve_commit(root, "main"), expected)

    local missing, err = git.resolve_commit(root, "definitely-not-a-ref")
    H.eq(missing, nil)
    assert(type(err) == "string" and err:find("does not resolve", 1, true),
      "invalid ref needs an actionable error, got: " .. tostring(err))

    local option_like, option_err = git.resolve_commit(root, "--definitely-not-an-option")
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
    local base = assert(git.resolve_commit(root, "HEAD"))

    write(root, "added.txt", "added later\n")
    write(root, "modified.txt", "after\n")
    assert(vim.fn.delete(vim.fs.joinpath(root, "deleted.txt")) == 0)
    sh(root, { "git", "mv", "old-name.txt", "renamed.txt" })
    sh(root, { "git", "add", "-A" })
    sh(root, { "git", "commit", "-m", "advance fixture" })

    local files, err = git.diff_files(root, base)
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
    local base = assert(git.resolve_commit(root, "HEAD"))
    for _, path in ipairs(paths) do
      write(root, path, "after\n")
    end

    local files, err = git.diff_files(root, base)
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

    local files, err = git.changed_files(root)
    assert(files, err)
    H.eq(#files, 1)
    H.eq(files[1].path, "new name.txt")
    H.eq(files[1].old_path, "old name.txt")
    H.eq(files[1].status, "R")
    H.eq(files[1].staged, "R")
    H.eq(files[1].unstaged, nil)
  end,
}
