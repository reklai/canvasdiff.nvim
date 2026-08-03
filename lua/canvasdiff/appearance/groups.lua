-- Canonical registry and default definitions for every CanvasDiff highlight.
-- Renderers choose these stable names; this owner derives their current
-- colorscheme values but never writes highlight state. Measured factors below
-- are the bounds that keep those derived channels distinguishable.
local G = {}

local ORDER = {
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

local KNOWN = {}
for _, name in ipairs(ORDER) do KNOWN[name] = true end

-- Static meanings live beside the derived palette so every CanvasDiff group
-- has one definition owner. Empty CanvasDiffCrumb deliberately carries no
-- colour: ordinary text reads through the file-bar background beneath it.
local STATIC = {
  CanvasDiffFileHeader = { link = "Title" },
  CanvasDiffHunkHeader = { link = "Comment" },
  CanvasDiffBinary = { link = "Comment" },
  CanvasDiffWinbar = { link = "WinBar" },
  CanvasDiffWinbarReadOnly = { link = "Visual" },
  -- Staged and stale both draw a filled dot, so luminance must distinguish
  -- them. Measured under tokyonight-moon, Added is #b3f6c0 (luma 228) and
  -- DiagnosticError is #c53b53 (90), a gap of 138. The stale emphasis adds a
  -- shape channel while the hollow unstaged dot is already distinct by shape.
  CanvasDiffStaged = { link = "Added" },
  CanvasDiffUnstaged = { link = "DiagnosticWarn" },
  CanvasDiffStale = { link = "DiagnosticError" },
  CanvasDiffStaleEmphasis = { bold = true },
  CanvasDiffSidebarDir = { link = "Directory" },
  CanvasDiffSidebarActive = { link = "Visual" },
  CanvasDiffSidebarHunk = { link = "Comment" },
  -- A pure-deletion label is struck through wherever a hunk is named. Linking
  -- the ghost vocabulary keeps the sidebar and pinned crumb in agreement.
  CanvasDiffHunkDel = { link = "CanvasDiffGhost" },
  CanvasDiffCrumb = {},
  CanvasDiffScrollFile = { link = "Title" },
  CanvasDiffScrollAdd = { link = "DiffAdd" },
  CanvasDiffScrollDel = { link = "DiffDelete" },
  CanvasDiffScrollChanged = { link = "DiffChange" },
  CanvasDiffScrollThumb = { link = "PmenuThumb" },
}

-- How far the field's background moves from Normal's toward the luminance
-- pole (white on a dark scheme, black on a light one). 0.04 by measurement
-- (Rec.709 luma, builtin dark scheme and stock tokyonight-moon): the budget
-- is what the OLD quiet tints already spent -- each scheme's worst probed
-- syntax-token (@comment, Function, String) contrast loss on a quiet-tinted
-- row, 22.8% builtin (its del tint) and 14.7% tokyonight-moon -- and 0.04 is
-- the largest of the 0.03..0.10 candidates whose worst loss fits both
-- budgets (6.6% builtin, 12.0% moon; 0.05 overshoots moon's by a hair,
-- 14.74% against 14.67%).
local ELEVATION_FACTOR = 0.04

-- How far the file-header bar's background moves from Normal's toward the
-- same pole -- one derivation, pushed further, so a file boundary reads
-- ABOVE the field it interrupts. 0.16 by measurement (same schemes as
-- ELEVATION_FACTOR): the smallest of the 0.12/0.14/0.16/0.20/0.24
-- candidates that, under both schemes, clears the elevation's |dL| by >= 10
-- (builtin bar dL +37.1 vs elevation +9.0; moon +34.8 vs +8.9) AND keeps
-- its luma >= 8 from both CursorLine's and Visual's bg, so the bar never
-- reads as just another cursor line (builtin gaps 13.1/22.7; moon 19.6/8.5
-- -- the thin one). 0.12 lands 3.9 from builtin's CursorLine, 0.14 lands
-- 4.5 from moon's Visual. A 15% Title-fg tint as a collision cure was
-- measured and REJECTED: builtin's Title fg is near-neutral, so tinting
-- just lightens the bar into Visual's band (gap 5.9), and under moon it
-- collapses the stale marker's contrast on the bar from 23.3 to 11.6.
--
-- Kept as the fallback for a scheme with no hue to borrow -- see
-- BAR_TINT_FACTOR, which spends chroma instead of luma when one is available.
local BAR_FACTOR = 0.16

-- The bar again, tinted rather than merely lightened, for a scheme whose
-- Directory carries real hue.
--
-- Why this works where the Title tint did not: CursorLine and Visual are
-- NEUTRAL in the schemes that box the luma factor in (builtin chroma 7 and 9),
-- so a bar that carries chroma separates from them on an axis the luma rule was
-- standing in for. That buys back the dim region 0.16 had to climb past --
-- builtin lands luma 42.5 against CursorLine's 45.9, which pure lightness could
-- never have used, and 11.6 above the elevation, still clearing the >= 10 rule.
--
-- Directory rather than Title because it is the one the SIDEBAR already spends
-- on a directory row: the scheme's own answer to "this is filesystem
-- structure", which is what a file boundary is. Measured, it also fixes the
-- Title attempt's other failure instead of repeating it -- a dimmer bar RAISES
-- the stale marker's contrast on it, 145.8 to 162.4.
local BAR_TINT_FACTOR = 0.10

-- Below this, Directory is grey and blending toward it is the lightening the
-- Title tint turned out to be, so the neutral bar above is the honest answer.
-- Builtin Directory reads 108; the bar keeps roughly a sixth of that, and 10 is
-- what it takes to out-chroma a neutral CursorLine.
local BAR_TINT_MIN_CHROMA = 60

-- The field elevation must stay legible UNDER the scheme's own quiet row
-- tints: the canvas runs with 'cursorline', and a Visual selection paints
-- over added rows, so a CursorLine or Visual background in the elevation's
-- luminance band makes that overlay invisible exactly where a review reads
-- it. The bar already keeps >= 8 luma from both (see BAR_FACTOR); the field
-- adopts the same rule, but derived at runtime because 0.04 cannot know
-- where a scheme parks its quiet tints. The factor moves only when a
-- collision exists, in 0.01 steps, taking the first candidate that clears
-- every neighbour by >= 8.
local ELEVATION_MIN_GAP = 8
local ELEVATION_ESCAPE_STEP = 0.01

-- The escape's ceiling is the top of the range ELEVATION_FACTOR was measured
-- over: past 0.10 the field starts spending the bar's >= 10 clearance and
-- syntax contrast no collision can buy back. When CursorLine and Visual box
-- the whole ladder in, the candidate keeping the largest worst-case gap is
-- the honest best effort.
local ELEVATION_ESCAPE_LIMIT = 0.10
--
-- The ceiling is still @comment: a ghost must never read dimmer than a
-- comment, and under the builtin scheme (the binding one, @comment |dL|
-- 135.9) that rules out 0.35, which reads 133.1. But sitting AT the ceiling
-- is what made the strikethrough load-bearing rather than merely helpful:
-- 0.30 reads 143.1, clearing @comment by 7.3, so the two were luminance
-- twins and the strike carried the whole distinction -- over text it also
-- had to stay legible through.
--
-- 0.20 reads 163.2: 27.4 clear of @comment and 41 below Normal's own 204.2,
-- so dimming says removed at a glance while the `-` prefix remains the shape
-- channel that survives colour blindness and a monochrome terminal.
local GHOST_DIM_FACTOR = 0.20

-- When a transparent scheme gives Normal no background there is nothing to
-- elevate from; a fixed near-Normal pair keeps the field visible.
local ELEVATION_FALLBACK_BG = { dark = 0x2c2c2c, light = 0xe4e4e4 }

-- The margin's green/red when the scheme's DiffAdd/DiffDelete carry no
-- foreground (bg-only diff groups are the common case). Never derived from
-- their bg: those are bg-tuned colours and read as mud when used as fg.
local HUE_FALLBACK_FG = { add = 0x2ea043, del = 0xdb4444 }

-- Rec.709 luma of a 24-bit colour, 0..255 -- the measure every factor above
-- was calibrated in.
local function luma(colour)
  local r = math.floor(colour / 65536) % 256
  local g = math.floor(colour / 256) % 256
  local b = colour % 256
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

-- How far a 24-bit colour sits from grey: max channel minus min, 0..255.
local function chroma(colour)
  if not colour then return 0 end
  local r = math.floor(colour / 65536) % 256
  local g = math.floor(colour / 256) % 256
  local b = colour % 256
  return math.max(r, g, b) - math.min(r, g, b)
end

-- Channelwise linear interpolation between two 24-bit RGB colours. A missing
-- endpoint yields the other unchanged, preserving transparent schemes.
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

function G.names()
  return vim.deepcopy(ORDER)
end

function G.known(name)
  return KNOWN[name] == true
end

-- One derived value per visual channel: a neutral elevation says changed, a
-- dim foreground says removed, and green/red hue lives only on the prefix and
-- gutter margin. CanvasDiffDel carries both elevation and dim foreground for
-- real deletion rows; every definition remains an overridable default.
function G.definitions()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local dark = vim.o.background == "dark"
  local pole = dark and 0xffffff or 0x000000
  local anti_pole = dark and 0x000000 or 0xffffff
  local normal_bg = normal.bg
    or ELEVATION_FALLBACK_BG[dark and "dark" or "light"]
  local elevation = tonumber(blend(normal_bg, pole, ELEVATION_FACTOR):sub(2), 16)
  local quiet = {}
  for _, name in ipairs({ "Visual", "CursorLine" }) do
    local group = vim.api.nvim_get_hl(0, { name = name, link = false })
    if group.bg then quiet[#quiet + 1] = luma(group.bg) end
  end
  local function worst_gap(colour)
    local gap = math.huge
    for _, other in ipairs(quiet) do
      gap = math.min(gap, math.abs(luma(colour) - other))
    end
    return gap
  end
  if worst_gap(elevation) < ELEVATION_MIN_GAP then
    local best, best_gap = elevation, worst_gap(elevation)
    local factor = ELEVATION_FACTOR + ELEVATION_ESCAPE_STEP
    while factor <= ELEVATION_ESCAPE_LIMIT + 1e-9 do
      local candidate = tonumber(blend(normal_bg, pole, factor):sub(2), 16)
      local gap = worst_gap(candidate)
      if gap >= ELEVATION_MIN_GAP then
        best = candidate
        break
      end
      if gap > best_gap then best, best_gap = candidate, gap end
      factor = factor + ELEVATION_ESCAPE_STEP
    end
    elevation = best
  end
  local ghost_fg = tonumber(
    blend(normal.fg or pole, normal.bg or anti_pole, GHOST_DIM_FACTOR):sub(2), 16)
  local bar = tonumber(blend(normal_bg, pole, BAR_FACTOR):sub(2), 16)
  local directory = vim.api.nvim_get_hl(0, { name = "Directory", link = false })
  if directory.fg and chroma(directory.fg) >= BAR_TINT_MIN_CHROMA then
    bar = tonumber(blend(normal_bg, directory.fg, BAR_TINT_FACTOR):sub(2), 16)
  end

  local out = vim.deepcopy(STATIC)
  out.CanvasDiffAdd = { bg = elevation }
  out.CanvasDiffDel = { bg = elevation, fg = ghost_fg }
  -- Dimmed only. The `-` prefix is already the shape channel that survives
  -- colour blindness and monochrome terminals, so a strike would duplicate it.
  out.CanvasDiffGhost = { fg = ghost_fg }
  out.CanvasDiffFileBar = { bg = bar }
  for kind, pair in pairs({
    add = { "CanvasDiffPrefixAdd", "CanvasDiffGutterAdd" },
    del = { "CanvasDiffPrefixDel", "CanvasDiffGutterDel" },
  }) do
    local source = vim.api.nvim_get_hl(0, {
      name = kind == "add" and "DiffAdd" or "DiffDelete",
      link = false,
    })
    local hue = source.fg or HUE_FALLBACK_FG[kind]
    for _, name in ipairs(pair) do
      out[name] = { fg = hue, ctermfg = source.ctermfg }
    end
  end
  return out
end

return G
