local H = require("helpers")
local appearance = require("canvasdiff.appearance")
local model = require("canvasdiff.diff")
local canvas = require("canvasdiff.canvas")

local T = {}

local function recover_colorscheme()
  appearance.setup({})
  vim.api.nvim_exec_autocmds("ColorScheme", {
    group = "canvasdiff.appearance",
  })
end

local OLD = table.concat({
  "local a = 1",
  "local b = 2",
  "local c = 3",
  "local d = 4",
  "local e = 5",
}, "\n") .. "\n"

local NEW = table.concat({
  "local a = 1",
  "local b = 20 -- changed",
  "local c = 3",
  "local d = 4",
  "local e = 5",
}, "\n") .. "\n"

-- --- the diff-row contrast budget -------------------------------------------
--
-- Three properties that together decide how the canvas reads, and none of which any
-- other test would notice changing.

-- `hl_eol` made an add/del tint fill the rest of the SCREEN LINE, so a three-character
-- edit painted colour to the right edge of a 200-column window -- the coloured area
-- scaled with the window, not with the change. This is the guard against it coming
-- back, which is a one-word edit in apply_section_hl and looks like nothing in review.
T["hl_rows add and del tints stop at end-of-text, never filling the window"] = function()
  local st = canvas.open({
    model.build_section("a.lua", "local a = 1\nlocal b = 2\n", "local a = 1\nlocal B = 2\n", "M", 3),
  }, {})

  local flooders, tinted = {}, 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, -1, 0, -1, { details = true })) do
    local d = m[4]
    if d and (d.hl_group == "CanvasDiffAdd" or d.hl_group == "CanvasDiffDel") then
      tinted = tinted + 1
      if d.hl_eol then flooders[#flooders + 1] = ("row %d %s"):format(m[2] + 1, d.hl_group) end
    end
  end
  assert(tinted > 0, "sanity: the diff rows are tinted at all")
  H.eq(flooders, {},
    "no add/del mark may set hl_eol -- it spends the strongest visual channel on "
    .. "'this line is involved', which is the least interesting thing on screen")
end

-- These were the last two visual elements pointing straight at standard groups, so
-- tuning the diff rows meant redefining the groups your ordinary vimdiff also uses.
T["hl_rows the row tints go through overridable CanvasDiff aliases"] = function()
  recover_colorscheme()
  for _, g in ipairs({ "CanvasDiffAdd", "CanvasDiffDel" }) do
    local direct = vim.api.nvim_get_hl(0, { name = g, link = false })
    assert(next(direct) ~= nil, g .. " must be defined, or the diff rows render unstyled")
  end
  -- `default = true` throughout, so a colourscheme that defines these wins.
  -- The shipped default is the computed elevation (a bg, no link); an
  -- override may be anything with a background.
  local linked = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = true })
  assert(linked.link == "DiffAdd" or linked.bg,
    "CanvasDiffAdd should carry a quiet tint or an override, got: "
    .. vim.inspect(linked))
end

-- --- the diff-row group values -----------------------------------------------
--
-- The field is DERIVED from the live scheme, and it is one statement per
-- channel: a single hueless elevation says "changed", a dimmed foreground
-- says "removed", and the green/red lives only on the margin (prefix and
-- gutter). These tests pin the relationships between the groups, never the
-- measured colour values -- those depend on the runner's scheme.

local config = require("canvasdiff.config")

-- Rec.709 luma, the same measure the factors were chosen by.
local function luma(rgb)
  if not rgb then return nil end
  local r = math.floor(rgb / 65536) % 256
  local g = math.floor(rgb / 256) % 256
  local b = rgb % 256
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

local function chroma(colour)
  if not colour then return 0 end
  local r = math.floor(colour / 65536) % 256
  local g = math.floor(colour / 256) % 256
  local b = colour % 256
  return math.max(r, g, b) - math.min(r, g, b)
end

local function blend(a, b, factor)
  if a == nil and b == nil then return nil end
  if a == nil or b == nil then return ("#%06x"):format(a or b) end
  local function channel(shift)
    local av = math.floor(a / shift) % 256
    local bv = math.floor(b / shift) % 256
    return math.floor(av + (bv - av) * factor + 0.5)
  end
  return ("#%02x%02x%02x"):format(
    channel(65536), channel(256), channel(1))
end

-- Every derived group the appearance manager authors. The manager's authorship
-- record is a singleton, so a group an earlier test left defined would mask a
-- broken derive; each derivation test clears them through the ColorScheme
-- recovery boundary before asserting the fresh palette.
local DIFF_GROUPS = {
  "CanvasDiffAdd", "CanvasDiffDel", "CanvasDiffGhost",
  "CanvasDiffPrefixAdd", "CanvasDiffPrefixDel",
  "CanvasDiffGutterAdd", "CanvasDiffGutterDel",
  "CanvasDiffFileBar",
  -- The minimap marks became profile-derived with mono. They must reset with
  -- the rest because redefining Normal (as the mono test does) makes Neovim
  -- 0.12 drop the `default` flag on every group, which freezes a previous
  -- test's authorship as foreign-owned unless cleared through the recovery
  -- boundary below.
  "CanvasDiffScrollAdd", "CanvasDiffScrollDel", "CanvasDiffScrollChanged",
}

local function reset_diff_groups()
  for _, g in ipairs(DIFF_GROUPS) do
    vim.api.nvim_set_hl(0, g, {})
  end
  recover_colorscheme()
end

T["hl_rows the field is one neutral elevation shared by add and del"] = function()
  reset_diff_groups()
  appearance.ensure()
  local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false })
  local del = vim.api.nvim_get_hl(0, { name = "CanvasDiffDel", link = false })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  H.eq(add.bg, del.bg, "one elevation, not two hues")
  assert(add.bg ~= normal.bg, "the elevation must differ from Normal")
  local diff_add = vim.api.nvim_get_hl(0, { name = "DiffAdd", link = false })
  assert(add.bg ~= diff_add.bg, "the elevation is not the scheme's diff wash")
  assert(add.fg == nil, "add rows keep full-contrast syntax")
  assert(del.fg ~= nil, "a deleted file's real rows read dimmed")
end

-- The elevation is quiet on purpose, which is exactly the band a scheme's own
-- quiet row tints live in. Visual paints over the field when a user selects
-- inside an added hunk, and the canvas runs with 'cursorline', so either
-- neighbour landing on the elevation makes its overlay invisible there. The
-- bar already keeps >= 8 luma from both (BAR_FACTOR's rule); these pin the
-- same rule onto the field, applied only when the collision exists.
T["hl_rows the elevation escapes a Visual that sits on it"] = function()
  local real_visual = vim.api.nvim_get_hl(0, { name = "Visual", link = false })
  local real_cursor = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
  local ok, err = xpcall(function()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    -- Park Visual exactly on the unguarded 0.04 elevation and move CursorLine
    -- out of the escape corridor: the colourscheme whose Visual is the same
    -- quiet tint the field would derive.
    local parked = tonumber(blend(normal.bg, 0xffffff, 0.04):sub(2), 16)
    vim.api.nvim_set_hl(0, "Visual", { bg = parked })
    vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x808080 })
    reset_diff_groups()
    appearance.ensure()

    local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false })
    local gap = math.abs(luma(add.bg) - luma(parked))
    assert(gap >= 8,
      ("a selection inside an added hunk must stay visible: elevation luma"
        .. " %.1f sits %.1f from Visual's"):format(luma(add.bg), gap))
    assert(luma(add.bg) > luma(normal.bg), "the escape stays an elevation")
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "Visual", real_visual)
  vim.api.nvim_set_hl(0, "CursorLine", real_cursor)
  reset_diff_groups()
  assert(ok, err)
end

T["hl_rows the elevation escapes a CursorLine that sits on it"] = function()
  local real_visual = vim.api.nvim_get_hl(0, { name = "Visual", link = false })
  local real_cursor = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
  local ok, err = xpcall(function()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local parked = tonumber(blend(normal.bg, 0xffffff, 0.04):sub(2), 16)
    vim.api.nvim_set_hl(0, "CursorLine", { bg = parked })
    vim.api.nvim_set_hl(0, "Visual", { bg = 0x808080 })
    reset_diff_groups()
    appearance.ensure()

    local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false })
    local gap = math.abs(luma(add.bg) - luma(parked))
    assert(gap >= 8,
      ("the cursor row must stay visible inside an added hunk: elevation luma"
        .. " %.1f sits %.1f from CursorLine's"):format(luma(add.bg), gap))
    assert(luma(add.bg) > luma(normal.bg), "the escape stays an elevation")
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "Visual", real_visual)
  vim.api.nvim_set_hl(0, "CursorLine", real_cursor)
  reset_diff_groups()
  assert(ok, err)
end

-- Profiles select the DEFAULT vocabulary for the diff-row groups and nothing
-- else. classic is the traditional wash: whole-row DiffAdd/DiffDelete links,
-- which the ownership chain must still let a colorscheme or an explicit
-- override displace.
T["hl_profile classic links the row field to the scheme's diff wash"] = function()
  reset_diff_groups()
  local ok, err = xpcall(function()
    appearance.setup({}, "classic")
    local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = true })
    H.eq(add.link, "DiffAdd")
    local del = vim.api.nvim_get_hl(0, { name = "CanvasDiffDel", link = true })
    H.eq(del.link, "DiffDelete")
    local ghost = vim.api.nvim_get_hl(0, { name = "CanvasDiffGhost", link = true })
    H.eq(ghost.link, "DiffDelete")
    -- The margin already carries the scheme's diff hue under quiet; classic
    -- must not disturb it.
    local prefix = vim.api.nvim_get_hl(0, { name = "CanvasDiffPrefixAdd", link = false })
    assert(prefix.fg ~= nil, "the + prefix keeps its derived foreground")
  end, debug.traceback)
  appearance.setup({})
  recover_colorscheme()
  assert(ok, err)
end

T["hl_profile classic yields to an explicit override"] = function()
  reset_diff_groups()
  local ok, err = xpcall(function()
    appearance.setup({ CanvasDiffAdd = { bg = "#123456" } }, "classic")
    H.eq(vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false }).bg,
      0x123456, "explicit highlights win over any profile")
  end, debug.traceback)
  appearance.setup({})
  recover_colorscheme()
  assert(ok, err)
end

-- mono removes hue from the entire diff vocabulary: rows and ghosts keep
-- quiet's neutral derivations, the + margin takes Normal's own foreground,
-- the - margin takes the ghost dim (dimming already says "removed"), and
-- the minimap's three marks collapse to the one neutral elevation. Normal
-- is pinned to pure greys here so "no chroma" is exact rather than
-- "no more chroma than the scheme's own text".
T["hl_profile mono spends no chroma anywhere in the diff vocabulary"] = function()
  local real_normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local real_add = vim.api.nvim_get_hl(0, { name = "DiffAdd", link = false })
  local real_del = vim.api.nvim_get_hl(0, { name = "DiffDelete", link = false })
  vim.api.nvim_set_hl(0, "Normal", { fg = 0xd0d0d0, bg = 0x1e1e1e })
  vim.api.nvim_set_hl(0, "DiffAdd", { fg = 0x2ea043, bg = 0x14261c })
  vim.api.nvim_set_hl(0, "DiffDelete", { fg = 0xdb4444, bg = 0x2d1215 })
  local ok, err = xpcall(function()
    reset_diff_groups()
    appearance.setup({}, "mono")
    local vocabulary = {
      "CanvasDiffAdd", "CanvasDiffDel", "CanvasDiffGhost", "CanvasDiffHunkDel",
      "CanvasDiffPrefixAdd", "CanvasDiffPrefixDel",
      "CanvasDiffGutterAdd", "CanvasDiffGutterDel",
      "CanvasDiffScrollAdd", "CanvasDiffScrollDel", "CanvasDiffScrollChanged",
    }
    for _, name in ipairs(vocabulary) do
      local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
      assert(next(hl) ~= nil, name .. " must still be defined")
      for _, channel in ipairs({ "fg", "bg", "sp" }) do
        local colour = hl[channel]
        assert(colour == nil or chroma(colour) == 0,
          ("%s.%s carries hue (#%06x) under mono"):format(name, channel, colour or 0))
      end
    end
    -- Direction still reads: the + margin is brighter than the - margin.
    local plus = vim.api.nvim_get_hl(0, { name = "CanvasDiffPrefixAdd", link = false })
    local minus = vim.api.nvim_get_hl(0, { name = "CanvasDiffPrefixDel", link = false })
    assert(luma(plus.fg) > luma(minus.fg),
      "the + prefix reads at full contrast, the - prefix reads dimmed")
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "Normal", real_normal)
  vim.api.nvim_set_hl(0, "DiffAdd", real_add)
  vim.api.nvim_set_hl(0, "DiffDelete", real_del)
  appearance.setup({})
  -- Redefining Normal above made Neovim drop the `default` flag on every
  -- group, so the manager now reads its own derivations as user-owned and
  -- would refuse to re-derive for whoever runs next. Clear the vocabulary
  -- so the recovery boundary hands back fresh defaults.
  reset_diff_groups()
  assert(ok, err)
end

-- The file bar borrows the scheme's Directory hue so it can be DIMMER than a
-- purely lighter bar could be: CursorLine and Visual are neutral in the schemes
-- that box the luma factor in, so chroma separates the bar from them on an axis
-- luma was standing in for. These pin both halves -- that the tint is taken when
-- there is a hue to take, and that it is refused when there is not.
local function bar_bg()
  return vim.api.nvim_get_hl(0, { name = "CanvasDiffFileBar", link = false }).bg
end

T["hl_rows the file bar spends chroma so it can spend less light"] = function()
  local real = vim.api.nvim_get_hl(0, { name = "Directory", link = false })
  vim.api.nvim_set_hl(0, "Directory", { fg = 0x8cf8f7 })  -- chroma 108
  local ok, err = xpcall(function()
    reset_diff_groups()
    appearance.ensure()
    local bar = bar_bg()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local neutral = tonumber(blend(normal.bg, 0xffffff, 0.16):sub(2), 16)

    assert(chroma(bar) >= 10,
      ("the bar must carry real hue, not a lightening (chroma %d)")
        :format(chroma(bar)))
    assert(luma(bar) < luma(neutral),
      "and it must be DIMMER than the neutral bar -- the chroma is what buys that")

    -- The elevation rule still binds: a file boundary reads above the field.
    local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false })
    assert(luma(bar) - luma(add.bg) >= 10,
      ("the bar must clear a changed row by >= 10 (got %.1f)")
        :format(luma(bar) - luma(add.bg)))

    -- The failure the earlier Title tint died on: markers sit ON the bar.
    local stale = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
    if stale.fg then
      assert(math.abs(luma(stale.fg) - luma(bar))
          >= math.abs(luma(stale.fg) - luma(neutral)),
        "a dimmer bar must not cost the stale marker contrast -- it should gain")
    end
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "Directory", real)
  assert(ok, err)
end

T["hl_rows a grey Directory is refused as a tint"] = function()
  local real = vim.api.nvim_get_hl(0, { name = "Directory", link = false })
  vim.api.nvim_set_hl(0, "Directory", { fg = 0x9b9ea4 })  -- chroma 9, a grey
  local ok, err = xpcall(function()
    reset_diff_groups()
    appearance.ensure()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    H.eq(bar_bg(), tonumber(blend(normal.bg, 0xffffff, 0.16):sub(2), 16),
      "blending toward a grey is the lightening the Title tint turned out to"
        .. " be, so the neutral bar is the honest answer")
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "Directory", real)
  assert(ok, err)
end

T["hl_rows the crumb states no colour, so it reads as text on the bar"] = function()
  vim.api.nvim_set_hl(0, "CanvasDiffCrumb", {})
  recover_colorscheme()
  local crumb = vim.api.nvim_get_hl(0, { name = "CanvasDiffCrumb", link = false })
  -- Emptiness is the whole contract and the easiest thing to lose: a fg here
  -- would freeze one scheme's colour into a group nothing recomputes, and a bg
  -- would punch a hole in the file bar the float draws underneath it.
  H.eq(crumb.fg, nil, "no foreground: the crumb takes the bar's, which is Normal's")
  H.eq(crumb.bg, nil, "no background: the bar owns that, and it must show through")
  H.eq(crumb.link, nil, "not a link either -- linking Normal would bring its background")
  H.eq(crumb.default, true, "default = true, so a colourscheme or a config wins")
end

T["hl_rows ghosts have no background and a dimmed, struck foreground"] = function()
  reset_diff_groups()
  appearance.ensure()
  local ghost = vim.api.nvim_get_hl(0, { name = "CanvasDiffGhost", link = false })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  H.eq(ghost.bg, nil)
  assert(ghost.fg and ghost.fg ~= normal.fg, "dimmed, not Normal's own fg")
  assert(luma(ghost.fg) < luma(normal.fg) and luma(ghost.fg) > luma(normal.bg),
    "dimmed means moved toward the background, not past it and not brighter")
  H.eq(ghost.strikethrough, nil,
    "not struck: the dim carries 'removed' on its own now, and the `-` prefix"
      .. " is the shape channel that outlives colour")

  -- The dim's ceiling is @comment -- a deletion must never read dimmer than
  -- one -- and with the strike gone this clearance is the whole distinction
  -- between a deleted block and a comment block. The
  -- factor is chosen to clear it with room, so the two channels split the
  -- work; drift back toward the ceiling and this fails before the docs that
  -- quote the clearance go quietly false.
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  if comment.fg then
    local bg = luma(normal.bg)
    local clearance = math.abs(luma(ghost.fg) - bg) - math.abs(luma(comment.fg) - bg)
    assert(clearance >= 15,
      ("a ghost must clear @comment by a real margin, not sit on it (got %.1f)")
        :format(clearance))
  end
end

T["hl_rows margin hue lives on the prefix and gutter groups, identically"] = function()
  reset_diff_groups()
  appearance.ensure()
  for _, pair in ipairs({
    { "CanvasDiffPrefixAdd", "CanvasDiffGutterAdd" },
    { "CanvasDiffPrefixDel", "CanvasDiffGutterDel" },
  }) do
    local prefix = vim.api.nvim_get_hl(0, { name = pair[1], link = false })
    local gutter = vim.api.nvim_get_hl(0, { name = pair[2], link = false })
    assert(prefix.fg, pair[1] .. " must carry a foreground")
    H.eq(prefix.fg, gutter.fg, "prefix and bar are the same statement")
    H.eq(prefix.bg, nil)
  end
  local ga = vim.api.nvim_get_hl(0, { name = "CanvasDiffGutterAdd", link = true })
  H.eq(ga.link, nil, "no longer a link to Added")
end

T["hl_bar the header bar is derived, not Folded's luck"] = function()
  reset_diff_groups()
  appearance.ensure()
  local bar = vim.api.nvim_get_hl(0, { name = "CanvasDiffFileBar", link = true })
  H.eq(bar.link, nil, "no longer linked to Folded")
  assert(bar.bg, "the bar is a background statement")
end

T["hl_bar the bar clears the row elevation, which clears Normal"] = function()
  reset_diff_groups()
  appearance.ensure()
  local normal = luma(vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg or 0)
  local field = luma(vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false }).bg)
  local bar = luma(vim.api.nvim_get_hl(0, { name = "CanvasDiffFileBar", link = false }).bg)
  assert(math.abs(field - normal) > 0, "sanity: the field is elevated")
  assert(math.abs(bar - normal) > math.abs(field - normal),
    "the bar must clear the field, not just Normal")
end

T["hl_rows a user's pre-defined group survives the derivation"] = function()
  reset_diff_groups()
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", { bg = 0x123456 })
  appearance.ensure()
  local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false })
  H.eq(add.bg, 0x123456, "an explicit override always wins")
  reset_diff_groups()
end

T["hl_rows a user definition of CanvasDiffAdd survives every ensure"] = function()
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", { bg = 0x123456 })
  local ok, err = pcall(function()
    config.setup({})
    canvas.open({ model.build_section("override.lua", OLD, NEW, "M") }, {})
    H.eq(vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false }).bg, 0x123456,
      "a derived default must never clobber an explicit user definition")
  end)
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", {})
  config.setup({})
  recover_colorscheme()
  assert(ok, err)
end

T["hl_profile the configured profile reaches the appearance manager"] = function()
  local ok, err = xpcall(function()
    require("canvasdiff").setup({ profile = "classic" })
    H.eq(vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = true }).link,
      "DiffAdd", "setup({ profile = ... }) must flow through App")
  end, debug.traceback)
  require("canvasdiff").setup({})
  recover_colorscheme()
  assert(ok, err)
end

return T
