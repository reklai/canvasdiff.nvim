local H = require("helpers")
local winbar = require("canvasdiff.ui").winbar
local lens = require("canvasdiff.diff").lens

local T = {}

T["winbar_ text is the comparison label alone, band-tinted"] = function()
  local st = { lens = lens.get("all") }
  H.eq(winbar.text(st), "%#CanvasDiffWinbar#HEAD → WORKTREE")
end

T["winbar_ text escapes percent signs in refs"] = function()
  local st = { lens = lens.range("a%b", "topic", "..") }
  H.eq(winbar.text(st), "%#CanvasDiffWinbarReadOnly#READ-ONLY  a%%b → topic")
end

T["winbar_ a range lens tints the whole bar read-only"] = function()
  local st = { lens = lens.range("main", "topic", "...") }
  H.eq(winbar.text(st, nil),
    "%#CanvasDiffWinbarReadOnly#READ-ONLY  main → topic")
end

T["winbar_ ensure_hl_groups defines both groups as defaults"] = function()
  winbar.ensure_hl_groups()
  local base = vim.api.nvim_get_hl(0, { name = "CanvasDiffWinbar" })
  local ro = vim.api.nvim_get_hl(0, { name = "CanvasDiffWinbarReadOnly" })
  H.eq(base.link, "WinBar")
  H.eq(type(ro.link), "string")
end

return T
