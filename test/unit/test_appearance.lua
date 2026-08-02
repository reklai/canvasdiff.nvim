local H = require("helpers")
local appearance = require("canvasdiff.appearance")

local T = {}

local GROUPS = {
  "CanvasDiffAdd", "CanvasDiffDel", "CanvasDiffGhost",
  "CanvasDiffPrefixAdd", "CanvasDiffPrefixDel",
  "CanvasDiffGutterAdd", "CanvasDiffGutterDel", "CanvasDiffFileBar",
  "CanvasDiffFileHeader", "CanvasDiffHunkHeader", "CanvasDiffBinary",
  "CanvasDiffWinbar", "CanvasDiffWinbarReadOnly",
  "CanvasDiffStaged", "CanvasDiffUnstaged", "CanvasDiffStale",
  "CanvasDiffStaleEmphasis", "CanvasDiffSidebarDir",
  "CanvasDiffSidebarActive", "CanvasDiffSidebarHunk",
  "CanvasDiffHunkDel", "CanvasDiffCrumb", "CanvasDiffScrollFile",
  "CanvasDiffScrollAdd", "CanvasDiffScrollDel",
  "CanvasDiffScrollChanged", "CanvasDiffScrollThumb",
}

T["appearance registry is the exact public highlight surface"] = function()
  local facade = vim.tbl_keys(appearance)
  table.sort(facade)
  H.eq(facade, { "audit", "ensure", "names", "setup" })
  H.eq(appearance.names(), GROUPS)
  local second = appearance.names()
  second[1] = "mutated"
  H.eq(appearance.names(), GROUPS, "callers receive a copy")
end

T["appearance ensure defines every registered group"] = function()
  for _, name in ipairs(GROUPS) do
    vim.api.nvim_set_hl(0, name, {})
  end
  appearance.ensure()
  for _, name in ipairs(GROUPS) do
    local value = vim.api.nvim_get_hl(0, { name = name, link = true })
    assert(next(value) ~= nil, name .. " was not defined")
  end
end

T["appearance ensure reauthors a cleared registered group"] = function()
  appearance.ensure()
  vim.api.nvim_set_hl(0, "CanvasDiffWinbar", {})
  appearance.ensure()
  local value = vim.api.nvim_get_hl(0, {
    name = "CanvasDiffWinbar",
    link = true,
  })
  H.eq(value.link, "WinBar")
end

return T
