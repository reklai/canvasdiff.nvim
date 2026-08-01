local config = require("canvasdiff.config")

local R = {}

-- Formatting reads the config owner's live glyph table. Keeping the reference
-- stable makes an override immediately visible without a reverse config -> canvas
-- dependency or a second copy of presentation state.
local GLYPHS = config.glyphs
local PREFIX = GLYPHS

--- A filename rendered as one printable buffer-row fragment.
---
--- Git paths may contain every byte except NUL and `/` within one component.
--- In particular, passing a literal newline to nvim_buf_set_lines either splits
--- a structural row or errors, while a tab makes the tree/header geometry
--- depend on tabstop. Keep the raw path on the model for identity and I/O; only
--- this display boundary escapes backslash and ASCII controls.
function R.escape_path(path)
  local escaped = {}
  for i = 1, #(path or "") do
    local c = path:sub(i, i)
    local byte = string.byte(c)
    if c == "\\" then
      escaped[#escaped + 1] = "\\\\"
    elseif c == "\n" then
      escaped[#escaped + 1] = "\\n"
    elseif c == "\t" then
      escaped[#escaped + 1] = "\\t"
    elseif c == "\r" then
      escaped[#escaped + 1] = "\\r"
    elseif byte < 32 or byte == 127 then
      escaped[#escaped + 1] = ("\\x%02X"):format(byte)
    else
      escaped[#escaped + 1] = c
    end
  end
  return table.concat(escaped)
end

--- Display identity for a section. old_path is absent on legacy hand-built
--- sections and equal to path for ordinary files.
function R.section_path(section)
  local new_path = R.escape_path(section.path)
  if section.old_path and section.old_path ~= section.path then
    return R.escape_path(section.old_path) .. " → " .. new_path
  end
  return new_path
end

local HL_GROUP = {
  file_hdr = "CanvasDiffFileHeader",
  hunk_hdr = "CanvasDiffHunkHeader",
  binary = "CanvasDiffBinary",
  -- Aliased rather than pointing straight at DiffDelete/DiffAdd, which is what these
  -- were. Two reasons. Every other visual element in canvasdiff goes through an
  -- overridable CanvasDiff* group, and these were the last exceptions -- so tuning the
  -- diff rows meant redefining the groups your full-window vimdiff also uses. And the
  -- defaults a colourscheme picks for DiffAdd/DiffDelete are chosen for a two-pane
  -- vimdiff, where a whole-window wash is the point; here they sit under
  -- syntax-highlighted code and compete with the word-diff marks on top of them.
  del = "CanvasDiffDel",
  add = "CanvasDiffAdd",
}

--- The row group for one entry kind, the single lookup both the eager canvas
--- and the paged projection resolve through. The statuscolumn bar and the row
--- tint are two channels of ONE rendering, not alternatives, so nothing here
--- trades a group away for the bar.
local function row_group(kind)
  return HL_GROUP[kind]
end

--- The sidebar's stage-mark block, ready to append to a header or placeholder:
--- one leading space before the marks, nothing at all when the section carries
--- no status facts (a range lens's sections never do -- collect's range branch
--- reads no porcelain -- which is what keeps READ-ONLY comparisons bare here
--- and on the sidebar rows for the same reason rather than by convention).
local function stage_suffix(section)
  local stage = R.stage_mark(section.staged, section.unstaged)
  if stage == "" then
    return ""
  end
  return " " .. stage
end

function R.section_line(section, index)
  local e = section.entries[index]
  if not e then
    return nil
  end
  if e.kind == "file_hdr" then
      -- "(+0 −0)" on a binary file would read as "nothing changed", which is
      -- the opposite of the truth -- it changed, we just won't show how.
    local counts
    if section.rename_only then
      counts = "  (renamed)"
    elseif section.binary then
      counts = "  (binary)"
    else
      counts = ("  (+%d " .. GLYPHS.minus .. "%d)"):format(section.adds, section.dels)
    end
    -- The SAME stage marks the sidebar row carries, so closing the sidebar
    -- loses no information about what a file's changes are.
    return GLYPHS.file .. " " .. R.section_path(section) .. counts .. stage_suffix(section)
  elseif e.kind == "hunk_hdr" then
    return e.content
  elseif e.kind == "binary" then
    return "  " .. e.content
  end
  return PREFIX[e.kind] .. e.content
end

function R.section_lines(section)
  local lines = {}
  for i = 1, #section.entries do
    lines[i] = R.section_line(section, i)
  end
  return lines
end


--- The stage-state marker for a file, from git's own XY pair. "" when we were given
--- neither, so a caller with no status information renders nothing rather than
--- claiming the file is clean.
---
--- Note this DISCARDS which letter git reported (M/A/D/R/C/T/?) and keeps only
--- whether each column was occupied, so a rename and an added file render alike.
--- A deliberate trade for a narrow marker column; the letters are still on the
--- entry if a future row format wants them.
function R.stage_mark(staged, unstaged)
  if staged and unstaged then
    return GLYPHS.staged .. GLYPHS.unstaged
  elseif staged then
    return GLYPHS.staged
  elseif unstaged then
    return GLYPHS.unstaged
  end
  return ""
end

--- Highlight groups for the three marker glyphs, defined here beside the glyphs
--- themselves because the canvas and the sidebar both draw them.
---
--- ONE definition on purpose. Two `default = true` calls for the same group is a
--- trap: `default` means "only if not already set", so whichever window opened first
--- would silently win and any divergence between the copies would show up as
--- colour that depends on open order. It lived in both modules and had to be edited
--- in both to stay honest; now it cannot drift.
---
--- Green / yellow / red, in that order: staged is done, unstaged is pending, stale
--- wants your attention.
---
--- CanvasDiffStaged vs CanvasDiffStale is the pair that MATTERS -- both draw `●` (see the
--- note on GLYPHS.stale), so these links are the only thing telling a staged file from one
--- that changed behind a fold. The choice is LUMINANCE, not hue: measured under
--- tokyonight-moon, `Added` is #b3f6c0 (luminance 228) against `DiagnosticError`'s
--- #c53b53 (90), a gap of 138. `DiagnosticWarn` (#ffc777, 205) was the earlier pick
--- and gave a gap of 23 -- fine for normal vision, nothing to fall back on otherwise,
--- since red/green colour blindness confuses hue while leaving brightness intact. A
--- light dot against a dark dot survives that; two light dots do not.
---
--- CanvasDiffUnstaged is the least load-bearing of the three: `○` is hollow, so shape
--- already separates it from both filled markers whatever colour it lands on.
--- DiagnosticWarn rather than `Changed` because `Changed` is cyan in several popular
--- schemes (tokyonight included), which breaks the progression for no gain.
function R.ensure_marker_hl()
  vim.api.nvim_set_hl(0, "CanvasDiffStale", { link = "DiagnosticError", default = true })
  -- Layered over CanvasDiffStale, carrying an attribute and no colour of its own, so the
  -- stale marker stays distinguishable from the identically-shaped staged marker under
  -- any colourscheme. See the note in R.marker_spans for the measurement.
  vim.api.nvim_set_hl(0, "CanvasDiffStaleEmphasis", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffStaged", { link = "Added", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffUnstaged", { link = "DiagnosticWarn", default = true })
end

--- Channelwise linear interpolation between two 24-bit RGB colours.
---
--- `factor` is the fraction moved from `bg_a` toward `bg_b`: 0 is `bg_a`
--- unchanged, 1 is `bg_b`. Either endpoint may be nil -- a transparent scheme
--- has no Normal background to blend toward, and builtin DiffDelete carries no
--- background at all -- in which case the OTHER endpoint comes back unchanged
--- rather than inventing black or erroring. Returns "#rrggbb", or nil when
--- both endpoints are missing.
function R.blend(bg_a, bg_b, factor)
  if bg_a == nil and bg_b == nil then
    return nil
  end
  if bg_a == nil or bg_b == nil then
    return ("#%06x"):format(bg_a or bg_b)
  end
  local function channel(shift)
    local a = math.floor(bg_a / shift) % 256
    local b = math.floor(bg_b / shift) % 256
    return math.floor(a + (b - a) * factor + 0.5)
  end
  return ("#%02x%02x%02x"):format(channel(65536), channel(256), channel(1))
end

-- How far a quiet tint moves from the scheme's diff background toward
-- Normal's. 0.6 by measurement (Rec.709 luma, builtin dark scheme and
-- tokyonight-moon): at 0.6 every probed syntax token -- @comment as the dim
-- extreme, Function and String as bright ones -- keeps its luminance delta on
-- a tinted row within 15% of its delta on an untinted one (worst case
-- @comment on a tokyonight-moon added row: 74.1 untinted vs 63.2 tinted,
-- -14.7%). At 0.5 that same case degrades by 19.1%, so 0.6 is the least
-- blending that meets the budget.
local QUIET_FACTOR = 0.6

-- What quiet derives from when the scheme's own group carries no background.
-- Not hypothetical: builtin DiffDelete is foreground-only (discovered in the
-- winbar work), and blending nothing toward Normal would return Normal's own
-- background -- an INVISIBLE deletion tint. A fixed green/red pair blended
-- 60% toward Normal lands close to what schemes that do tint their diff rows
-- pick anyway.
local QUIET_FALLBACK_BG = { add = 0x2ea043, del = 0xdb4444 }

-- What this module itself last defined each diff group as, keyed by group
-- name, stored as the nvim_get_hl readback. The quiet tints are COMPUTED
-- values, and `default = true` means "only if the group is not already
-- defined" -- so without this record a mode switch (or a re-derive against a
-- changed scheme) would be a silent no-op: the second default call cannot
-- replace the first. Comparing the group's current definition against this
-- record is what lets ensure_diff_hl force-replace exactly the definitions it
-- authored while never touching a user's or a colourscheme's.
local applied_diff_hl = {}

-- The comparison shape for "is this definition the one we authored?".
--
-- The `default` marker is stripped before comparing, and that is load-bearing
-- for colourscheme switches: `:hi clear` (which schemes run first) restores a
-- group to its registered default VALUE but reports it without the flag, so
-- comparing flags too would misread our own surviving definition as a foreign
-- override and leave a stale tint derived from the previous scheme in place.
-- Values still separate ours from everyone else's: a user or scheme override
-- carries different attributes, or it changes nothing.
local function authorship_shape(definition)
  local shape = {}
  for key, value in pairs(definition or {}) do
    if key ~= "default" then
      shape[key] = value
    end
  end
  return shape
end

--- Define one diff group as a default, replacing only our own prior authorship.
local function set_diff_default(group, spec)
  local current = authorship_shape(
    vim.api.nvim_get_hl(0, { name = group, link = true }))
  if next(current) ~= nil then
    if not vim.deep_equal(current, applied_diff_hl[group]) then
      -- Someone else defined this group -- a user, a colourscheme, or an
      -- earlier explicit override. Theirs always wins over a derived default.
      return
    end
    if vim.deep_equal(current, authorship_shape(spec)) then
      return
    end
    -- Ours, and stale (the derived colour changed). `force` is how a
    -- default-flagged definition replaces an existing one; it is safe here
    -- ONLY because the current value just proved to be our own.
    spec = vim.tbl_extend("force", spec, { force = true })
  end
  vim.api.nvim_set_hl(0, group, spec)
  applied_diff_hl[group] = authorship_shape(
    vim.api.nvim_get_hl(0, { name = group, link = true }))
end

--- Define the diff-row groups: derived low-intensity tints, the scheme's
--- DiffAdd/DiffDelete background blended QUIET_FACTOR toward Normal's (the
--- quiet derivation, until the palette rework replaces its values).
--- Colourschemes tune those groups for a two-pane vimdiff where a
--- whole-window wash is the point; on a canvas most of the screen is tinted,
--- so the raw wash spends the strongest visual channel on the least
--- interesting fact. All definitions are defaults: an explicit user or
--- colourscheme definition of any CanvasDiff* group always wins.
function R.ensure_diff_hl()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  for kind, group in pairs({ add = "CanvasDiffAdd", del = "CanvasDiffDel" }) do
    local source = vim.api.nvim_get_hl(0, {
      name = kind == "add" and "DiffAdd" or "DiffDelete",
      link = false,
    })
    local tint =
      R.blend(source.bg or QUIET_FALLBACK_BG[kind], normal.bg, QUIET_FACTOR)
    -- As a number, matching the nvim_get_hl readback shape, so the
    -- "already exactly this" comparison in set_diff_default can hold.
    local spec = { bg = tonumber(tint:sub(2), 16), default = true }
    -- gui colours cannot be blended into cterm indices; carry the source's
    -- cterm background through unchanged so a 256-colour terminal keeps
    -- loud tints rather than invisible ones.
    spec.ctermbg = source.ctermbg
    set_diff_default(group, spec)
  end
  -- The bar the statuscolumn draws per add/del row. Added/Removed rather than
  -- DiffAdd/DiffDelete: the bar is one glyph of FOREGROUND, and Added/Removed
  -- are the standard foreground-carrying statements of the same two facts.
  set_diff_default("CanvasDiffGutterAdd", { link = "Added", default = true })
  set_diff_default("CanvasDiffGutterDel", { link = "Removed", default = true })
end

--- Byte spans of the trailing marker glyphs on a sidebar row, a canvas file
--- header, or a folded placeholder, each with the highlight group it needs,
--- innermost-last order irrelevant to the caller.
---
--- Pure, and deliberately fed the SAME four inputs the line builder used, walking
--- in from the end in the reverse of the order they were appended
--- (`… stage_mark(staged, unstaged) .. STALE`). That is the only thing keeping the
--- colours on the right characters -- if you change any of those layouts, change
--- this with it; test_sidebar's and test_model's span tests will tell you if you
--- didn't.
---
--- The colours are LOAD-BEARING here, not decoration: STALE and STAGED are the same
--- character (`●`), so a stale staged file renders `● ●` and the highlight is the
--- only thing separating them. That is a deliberate choice -- see the note on
--- GLYPHS.stale -- but it means a span that lands one glyph off is a silent wrong answer,
--- not a cosmetic slip.
function R.marker_spans(line, staged, unstaged, stale)
  local spans = {}
  local col = #line
  local function take(glyph, group)
    col = col - #glyph
    spans[#spans + 1] = { col, col + #glyph, group }
  end
  if stale then
    -- TWO spans over the same range: the colour, and a bold layer on top.
    --
    -- The bold is what makes this robust rather than lucky. STALE and STAGED are the
    -- same `●`, so colour is the only thing separating "staged" from "changed behind a
    -- fold" -- and how well it separates them is entirely up to the colourscheme.
    -- Measured: CanvasDiffStaged against CanvasDiffStale is 138 luminance apart under
    -- tokyonight-moon but only 23 under Neovim's builtin scheme, where DiagnosticError
    -- resolves to a pale salmon rather than a dark red. Two pale pastels 23 apart is
    -- not a distinction, and it is the one place in the sidebar where getting it wrong
    -- means reading the wrong fact about a file.
    --
    -- Bold cannot lose that contest because it is not in it: it composes over whatever
    -- colour is underneath, identically under every scheme. Same conclusion the
    -- word-diff marks reached, for the same reason.
    take(GLYPHS.stale, "CanvasDiffStale")
    local s = spans[#spans]
    spans[#spans + 1] = { s[1], s[2], "CanvasDiffStaleEmphasis" }
  end
  if unstaged then
    take(GLYPHS.unstaged, "CanvasDiffUnstaged")
  end
  if staged then
    take(GLYPHS.staged, "CanvasDiffStaged")
  end
  return spans
end

--- Single-line summary shown in place of a collapsed section's body. `stale` marks
--- it as no longer matching what the user saw when they set it aside (fold.stale).
---
--- Marker order is the sidebar row's, by contract: stage marks first, stale LAST,
--- so a trailing `●` keeps meaning exactly one thing in every window. It also has
--- to be this order for R.marker_spans to work unchanged -- the spans walk in from
--- the END of the line in the reverse of append order.
function R.placeholder(section, stale)
  local mark = (stale and GLYPHS.stale or "")
  local marks = stage_suffix(section) .. mark
  if section.rename_only then
    return GLYPHS.folded .. " " .. R.section_path(section) .. "  (renamed)" .. marks
  end
  if section.binary then
    return GLYPHS.folded .. " " .. R.section_path(section) .. "  (binary)" .. marks
  end
  return GLYPHS.folded .. " " .. R.section_path(section)
    .. ("  (%d hunks, +%d " .. GLYPHS.minus .. "%d)"):format(section.nhunks, section.adds, section.dels)
    .. marks
end

--- `virt_lines` chunk spec for an entry's deleted lines, or nil when it has none.
---
--- `which` is "ghosts" (deletions that came BEFORE this row) or "ghosts_after" (ones
--- with no row after them at all -- a delete-only hunk, or end of file).
---
--- Shape is what nvim_buf_set_extmark wants: a list of lines, each a list of
--- `{ text, hl }` chunks. One chunk per line here, so a deleted line renders whole.
--- Intra-line word-diff on the ghost side is deliberately NOT attempted: extmarks
--- cannot reach into virtual text, so it would mean splitting each ghost into
--- unchanged/changed/unchanged chunks at render time. The ADD side keeps its
--- word-diff marks, which is the half that says what the code became.
---
--- Keeps the `-` prefix so a ghost still reads as a deletion at a glance, and so the
--- column of content lines up with the ` `/`+` rows around it.
function R.ghost_lines(entry, which)
  local ghosts = entry and entry[which or "ghosts"]
  if not ghosts or #ghosts == 0 then
    return nil
  end
  local lines = {}
  for i, g in ipairs(ghosts) do
    lines[i] = { { PREFIX.del .. (g.content or ""), "CanvasDiffGhost" } }
  end
  return lines
end

function R.section_hl(section)
  local marks = {}
  for i, e in ipairs(section.entries) do
    local group = row_group(e.kind)
    if group then
      marks[#marks + 1] = { row = i - 1, group = group }
    end
  end
  return marks
end

function R.entry_hl(entry)
  return entry and row_group(entry.kind) or nil
end

return R
