local H = require("helpers")
return {
  ["smoke: git fixture builds"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "one\n" },
      worktree = { ["a.txt"] = "one\ntwo\n" },
    })
    local res = vim.system({ "git", "status", "--porcelain" }, { cwd = root, text = true }):wait()
    assert(res.stdout:find("a.txt"), "expected dirty a.txt, got: " .. res.stdout)
  end,
}
