local H = require("helpers")
local winbar = require("canvasdiff.ui").winbar
local lens = require("canvasdiff.diff").lens

local T = {}

T["winbar_ text renders label alone when no path is under the top"] = function()
  local st = { lens = lens.get("all") }
  H.eq(winbar.text(st, nil), "HEAD → WORKTREE")
end

T["winbar_ text appends the truncatable path after a separator"] = function()
  local st = { lens = lens.get("all") }
  H.eq(winbar.text(st, "a.txt"), "HEAD → WORKTREE · %<a.txt")
end

T["winbar_ text escapes percent signs in refs and paths"] = function()
  local st = { lens = lens.range("a%b", "topic", "..") }
  H.eq(winbar.text(st, "100%.txt"),
    "READ-ONLY  a%%b → topic · %<100%%.txt")
end

return T
