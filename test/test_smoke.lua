local H = require("helpers")
local U = require("galley.util")
return {
  ["smoke: util.clamp"] = function()
    H.eq(U.clamp(5, 1, 3), 3)
    H.eq(U.clamp(-1, 1, 3), 1)
    H.eq(U.clamp(2, 1, 3), 2)
  end,
  ["smoke: git fixture builds"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "one\n" },
      worktree = { ["a.txt"] = "one\ntwo\n" },
    })
    local res = vim.system({ "git", "status", "--porcelain" }, { cwd = root, text = true }):wait()
    assert(res.stdout:find("a.txt"), "expected dirty a.txt, got: " .. res.stdout)
  end,
}
