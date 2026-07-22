local H = require("helpers")
local git = require("finding_myself.git")
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
}
