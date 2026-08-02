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

--- The widest prefix of `text` that fits `cells` display columns, cut on a
--- character boundary: the text being cut is a line of source, and splitting a
--- multibyte character mid-sequence would put invalid bytes in a buffer.
---
--- Shared rather than copied: the sidebar's hunk rows and the pinned header's
--- crumb cut the same labels to two different widths, and a second
--- implementation would be a second answer to "does this fit".
function R.fit(text, cells)
  if cells <= 0 then
    return ""
  end
  -- Every character is at least one cell wide, so `cells` characters is already
  -- an upper bound on what can fit -- the walk below is bounded by the width
  -- being cut to rather than by the length of the line being cut.
  local n = math.min(vim.fn.strchars(text), cells)
  while n > 0 do
    local cut = vim.fn.strcharpart(text, 0, n)
    if vim.fn.strdisplaywidth(cut) <= cells then
      return cut
    end
    n = n - 1
  end
  return ""
end

--- One hunk's identity as text: the `@@` marker naming its new-side line, and
--- the first line the hunk writes.
---
--- ONE format wherever a hunk is named -- the sidebar's tree rows and the
--- pinned header's crumb are the same fact read in two windows, and a hunk that
--- answered to two names would read as two hunks.
---
--- Returned in two pieces because both callers need the LABEL's own bytes: they
--- are what a narrow window cuts, and what a pure deletion strikes through.
--- Leading indentation is dropped -- it is noise in a row that NAMES the hunk
--- rather than reproducing the line.
---
--- The number is new_lo, which a pure deletion has not got: it writes no
--- new-side line, so there is nothing to number. Which SIDE the label was taken
--- from is a different question, and `pure_del` is what answers it.
function R.hunk_name(hunk)
  local label = ((hunk.label or ""):gsub("^%s+", ""))
  local marker = hunk.new_lo and ("@@ %d  "):format(hunk.new_lo) or "@@ "
  return marker, label
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
  -- syntax-highlighted code that has to stay readable through them.
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
    -- colour is underneath, identically under every scheme.
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
--- The shape of the change a folded section is hiding: "(2 hunks, +3 −5)", or
--- what it is instead when counts would lie.
---
--- Read by the canvas placeholder AND by the sidebar's folded file row, because
--- a folded file is one row in both windows and has to read as the same row in
--- both. Two copies of this phrasing would drift, and the drift would be
--- invisible until someone had the tree and the canvas open side by side.
---
--- "(+0 −0)" on a binary file would read as "nothing changed", which is the
--- opposite of the truth -- it changed, we just won't show how. A rename-only
--- section says so for the same reason: its counts are zero and its identity is
--- the whole story.
function R.summary(section)
  if section.rename_only then
    return "(renamed)"
  end
  if section.binary then
    return "(binary)"
  end
  return ("(%d hunks, +%d " .. GLYPHS.minus .. "%d)")
    :format(section.nhunks or 0, section.adds or 0, section.dels or 0)
end

function R.placeholder(section, stale)
  local mark = (stale and GLYPHS.stale or "")
  local marks = stage_suffix(section) .. mark
  return GLYPHS.folded .. " " .. R.section_path(section)
    .. "  " .. R.summary(section) .. marks
end

--- `virt_lines` chunk spec for an entry's deleted lines, or nil when it has none.
---
--- `which` is "ghosts" (deletions that came BEFORE this row) or "ghosts_after" (ones
--- with no row after them at all -- a delete-only hunk, or end of file).
---
--- Shape is what nvim_buf_set_extmark wants: a list of lines, each a list of
--- `{ text, hl }` chunks. Two chunks per line: the prefix, then the content whole.
--- Nothing is highlighted WITHIN a ghost: extmarks cannot reach into virtual text,
--- so it would mean splitting each ghost into chunks at render time. That constraint
--- is what left intra-line marking able to speak for only one of the two sides, and
--- eventually why it was removed -- see docs/design.md.
---
--- Keeps the `-` prefix so a ghost still reads as a deletion at a glance, and so the
--- column of content lines up with the ` `/`+` rows around it. The prefix is its own
--- chunk because it carries the margin hue -- the red that says "removed" lives on
--- the one-glyph margin, here exactly as on real del rows.
function R.ghost_lines(entry, which)
  local ghosts = entry and entry[which or "ghosts"]
  if not ghosts or #ghosts == 0 then
    return nil
  end
  local lines = {}
  for i, g in ipairs(ghosts) do
    lines[i] = {
      { PREFIX.del, "CanvasDiffPrefixDel" },
      { g.content or "", "CanvasDiffGhost" },
    }
  end
  return lines
end

local PREFIX_GROUP = { add = "CanvasDiffPrefixAdd", del = "CanvasDiffPrefixDel" }

--- The margin-hue group and byte length of an entry's prefix cell, or nil
--- for kinds whose prefix carries no hue (context, headers, binary).
---
--- The byte length is `#PREFIX[kind]` at call time, never a constant: glyphs
--- are user-overridable and may be multi-byte, and a span cut at the wrong
--- byte puts the hue on the wrong cells.
function R.prefix_hl(entry)
  local group = entry and PREFIX_GROUP[entry.kind] or nil
  if not group then
    return nil
  end
  return group, #PREFIX[entry.kind]
end

--- Marks come in two shapes: `{ row, group }` colours the whole row, and
--- `{ row, group, end_col }` colours only bytes `[0, end_col)` -- the prefix
--- cell, where the green/red margin hue lives.
function R.section_hl(section)
  local marks = {}
  for i, e in ipairs(section.entries) do
    local group = row_group(e.kind)
    if group then
      marks[#marks + 1] = { row = i - 1, group = group }
    end
    local prefix_group, prefix_len = R.prefix_hl(e)
    if prefix_group then
      marks[#marks + 1] = { row = i - 1, group = prefix_group, end_col = prefix_len }
    end
  end
  return marks
end

function R.entry_hl(entry)
  return entry and row_group(entry.kind) or nil
end

return R
