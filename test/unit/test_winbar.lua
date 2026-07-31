local H = require("helpers")
local winbar = require("canvasdiff.ui").winbar
local lens = require("canvasdiff.diff").lens

local T = {}

T["winbar_ text renders label alone when no path is under the top"] = function()
  local st = { lens = lens.get("all") }
  H.eq(winbar.text(st, nil), "%#CanvasDiffWinbar#HEAD → WORKTREE")
end

T["winbar_ text appends the truncatable path after a separator"] = function()
  local st = { lens = lens.get("all") }
  H.eq(winbar.text(st, "a.txt"), "%#CanvasDiffWinbar#HEAD → WORKTREE · %<a.txt")
end

T["winbar_ text escapes percent signs in refs and paths"] = function()
  local st = { lens = lens.range("a%b", "topic", "..") }
  H.eq(winbar.text(st, "100%.txt"),
    "%#CanvasDiffWinbarReadOnly#READ-ONLY  a%%b → topic · %<100%%.txt")
end

T["winbar_ a range lens tints the whole bar read-only"] = function()
  local st = { lens = lens.range("main", "topic", "...") }
  H.eq(winbar.text(st, nil), "%#CanvasDiffWinbarReadOnly#READ-ONLY  main → topic")
end

T["winbar_ ensure_hl_groups defines both groups as defaults"] = function()
  winbar.ensure_hl_groups()
  local base = vim.api.nvim_get_hl(0, { name = "CanvasDiffWinbar" })
  local ro = vim.api.nvim_get_hl(0, { name = "CanvasDiffWinbarReadOnly" })
  H.eq(base.link, "WinBar")
  H.eq(type(ro.link), "string")
end

return T
