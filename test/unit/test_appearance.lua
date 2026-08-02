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

T["appearance ensure preserves an identical explicit takeover during rederive"] = function()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = true })
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", {})
  vim.api.nvim_set_hl(0, "CanvasDiffDel", {})
  appearance.ensure()
  local authored = vim.api.nvim_get_hl(0, {
    name = "CanvasDiffAdd",
    link = true,
  })
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", { bg = authored.bg })

  local ok, err = xpcall(function()
    local changed = vim.deepcopy(normal)
    changed.bg = authored.bg == 0x808080 and 0x101010 or 0x808080
    changed.default = nil
    vim.api.nvim_set_hl(0, "Normal", changed)
    -- A colourscheme clear removes manager defaults before the new palette is
    -- installed. Keep one manager-owned group on that path while the identical
    -- explicit takeover remains nonempty and foreign-owned.
    vim.api.nvim_set_hl(0, "CanvasDiffDel", {})
    appearance.ensure()

    local add = vim.api.nvim_get_hl(0, {
      name = "CanvasDiffAdd",
      link = true,
    })
    local del = vim.api.nvim_get_hl(0, {
      name = "CanvasDiffDel",
      link = true,
    })
    H.eq(add.bg, authored.bg, "the identical explicit definition owns the group")
    assert(del.bg ~= authored.bg, "the manager-owned palette was rederived")
  end, debug.traceback)

  local restore = vim.deepcopy(normal)
  restore.default = nil
  restore.force = true
  vim.api.nvim_set_hl(0, "Normal", restore)
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", {})
  vim.api.nvim_set_hl(0, "CanvasDiffDel", {})
  appearance.ensure()
  assert(ok, err)
end

return T
