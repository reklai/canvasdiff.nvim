local R = {}

--- Every glyph galley draws, in one place, so all of them are configurable through one
--- surface instead of five constants and four inline literals.
---
--- Written into by config.setup from `opts.glyphs`; read LIVE everywhere, never
--- snapshotted. That matters more than it looks: `stale` is used for byte arithmetic
--- (`#glyphs.stale`) when placing its highlight span, so a cached length would put the
--- mark on the wrong columns the moment anyone overrode the glyph.
---
--- `stale` includes its leading space deliberately -- it is appended to a row rather
--- than sitting in a column, and keeping the space inside the value means every
--- `#glyphs.stale` offset stays correct without callers adding 1.
---
--- Width matters here. `● ○ ▎ −` are East Asian Ambiguous and render two cells wide
--- under `ambiwidth=double`, while `▸ ▾ ‒ ❘` stay one cell in both modes. If you
--- override any of these, check `vim.fn.strwidth` under both settings -- see
--- config.ASCII_GLYPHS for a set that is one cell everywhere and needs no font beyond
--- ASCII.
local GLYPHS = {
  -- diff row prefixes
  ctx = " ",
  del = "-",
  add = "+",
  -- structure
  file = "▎",       -- canvas file header
  folded = "▸",     -- a folded file or directory, canvas and sidebar alike
  open = "▾",       -- an expanded directory in the sidebar
  minus = "−",      -- the − in "+3 −2"; a true MINUS SIGN, not an ASCII hyphen
  -- sidebar markers
  -- Two independent facts, so two independent glyphs rather than one tri-state
  -- symbol: `staged` means the index differs from HEAD, `unstaged` means the worktree
  -- differs from the index, and both together is the interesting case -- staged, then
  -- changed again.
  staged = "●",
  unstaged = "○",
  -- Appended to a row, never prefixed: the leading `folded` glyph means the same thing
  -- on a canvas placeholder and a sidebar row, so nothing may displace it.
  --
  -- DELIBERATELY the same character as `staged`, separated by highlight alone. A staged
  -- file that has since changed renders `● ●`, whose two characters are identical in
  -- the buffer TEXT -- yanked, echoed or grepped, the row is ambiguous. Chosen
  -- knowingly over a distinct glyph, so the marker column stays one cell per fact, and
  -- mitigated by layering a bold attribute over the colour (see R.marker_spans) since
  -- how well two colours separate is up to the colourscheme. If they are still hard to
  -- tell apart, `glyphs = { stale = " !" }` is the real fix -- and note the ascii preset
  -- already does exactly that.
  stale = " ●",
  -- minimap
  scroll_file = "‒",
  scroll_bar = "❘",
}

R.glyphs = GLYPHS
local PREFIX = GLYPHS

-- Pristine copy, so config.setup can start from the defaults every time instead of
-- layering each call's overrides on the last one's -- calling setup twice with
-- different glyph tables would otherwise leave a mix of both.
local DEFAULT_GLYPHS = vim.deepcopy(GLYPHS)

--- Restore every glyph to its shipped default. config.setup calls this before applying
--- overrides; nothing else should need it.
function R.reset_glyphs()
  for k, v in pairs(DEFAULT_GLYPHS) do
    GLYPHS[k] = v
  end
end

--- Is `name` a glyph slot that exists? Used by config.setup to reject typos loudly
--- rather than silently ignoring `glyphs = { fyle = "|" }`.
function R.is_glyph(name)
  return DEFAULT_GLYPHS[name] ~= nil
end

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
  file_hdr = "GalleyFileHeader",
  hunk_hdr = "GalleyHunkHeader",
  binary = "GalleyBinary",
  -- Aliased rather than pointing straight at DiffDelete/DiffAdd, which is what these
  -- were. Two reasons. Every other visual element in galley goes through an
  -- overridable Galley* group, and these were the last exceptions -- so tuning the
  -- diff rows meant redefining the groups your full-window vimdiff also uses. And the
  -- defaults a colourscheme picks for DiffAdd/DiffDelete are chosen for a two-pane
  -- vimdiff, where a whole-window wash is the point; here they sit under
  -- syntax-highlighted code and compete with the word-diff marks on top of them.
  del = "GalleyDel",
  add = "GalleyAdd",
}

function R.section_lines(section)
  local lines = {}
  for i, e in ipairs(section.entries) do
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
      lines[i] = GLYPHS.file .. " " .. R.section_path(section) .. counts
    elseif e.kind == "hunk_hdr" then
      lines[i] = e.content
    elseif e.kind == "binary" then
      lines[i] = "  " .. e.content
    else
      lines[i] = PREFIX[e.kind] .. e.content
    end
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
--- GalleyStaged vs GalleyStale is the pair that MATTERS -- both draw `●` (see the
--- note on GLYPHS.stale), so these links are the only thing telling a staged file from one
--- that changed behind a fold. The choice is LUMINANCE, not hue: measured under
--- tokyonight-moon, `Added` is #b3f6c0 (luminance 228) against `DiagnosticError`'s
--- #c53b53 (90), a gap of 138. `DiagnosticWarn` (#ffc777, 205) was the earlier pick
--- and gave a gap of 23 -- fine for normal vision, nothing to fall back on otherwise,
--- since red/green colour blindness confuses hue while leaving brightness intact. A
--- light dot against a dark dot survives that; two light dots do not.
---
--- GalleyUnstaged is the least load-bearing of the three: `○` is hollow, so shape
--- already separates it from both filled markers whatever colour it lands on.
--- DiagnosticWarn rather than `Changed` because `Changed` is cyan in several popular
--- schemes (tokyonight included), which breaks the progression for no gain.
function R.ensure_marker_hl()
  vim.api.nvim_set_hl(0, "GalleyStale", { link = "DiagnosticError", default = true })
  -- Layered over GalleyStale, carrying an attribute and no colour of its own, so the
  -- stale marker stays distinguishable from the identically-shaped staged marker under
  -- any colourscheme. See the note in R.marker_spans for the measurement.
  vim.api.nvim_set_hl(0, "GalleyStaleEmphasis", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "GalleyStaged", { link = "Added", default = true })
  vim.api.nvim_set_hl(0, "GalleyUnstaged", { link = "DiagnosticWarn", default = true })
end

--- Byte spans of the trailing marker glyphs on a sidebar row, each with the
--- highlight group it needs, innermost-last order irrelevant to the caller.
---
--- Pure, and deliberately fed the SAME four inputs S.render_lines used to build the
--- row, walking in from the end in the reverse of the order they were appended
--- (`… stage_mark(staged, unstaged) .. STALE`). That is the only thing keeping the
--- colours on the right characters -- if you change the row layout, change this with
--- it, and test_sidebar's span test will tell you if you didn't.
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
    -- Measured: GalleyStaged against GalleyStale is 138 luminance apart under
    -- tokyonight-moon but only 23 under Neovim's builtin scheme, where DiagnosticError
    -- resolves to a pale salmon rather than a dark red. Two pale pastels 23 apart is
    -- not a distinction, and it is the one place in the sidebar where getting it wrong
    -- means reading the wrong fact about a file.
    --
    -- Bold cannot lose that contest because it is not in it: it composes over whatever
    -- colour is underneath, identically under every scheme. Same conclusion the
    -- word-diff marks reached, for the same reason.
    take(GLYPHS.stale, "GalleyStale")
    local s = spans[#spans]
    spans[#spans + 1] = { s[1], s[2], "GalleyStaleEmphasis" }
  end
  if unstaged then
    take(GLYPHS.unstaged, "GalleyUnstaged")
  end
  if staged then
    take(GLYPHS.staged, "GalleyStaged")
  end
  return spans
end

--- Single-line summary shown in place of a collapsed section's body. `stale` marks
--- it as no longer matching what the user saw when they set it aside (fold.stale).
function R.placeholder(section, stale)
  local mark = stale and GLYPHS.stale or ""
  if section.rename_only then
    return GLYPHS.folded .. " " .. R.section_path(section) .. "  (renamed)" .. mark
  end
  if section.binary then
    return GLYPHS.folded .. " " .. R.section_path(section) .. "  (binary)" .. mark
  end
  return GLYPHS.folded .. " " .. R.section_path(section)
    .. ("  (%d hunks, +%d " .. GLYPHS.minus .. "%d)"):format(section.nhunks, section.adds, section.dels)
    .. mark
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
    lines[i] = { { PREFIX.del .. (g.content or ""), "GalleyGhost" } }
  end
  return lines
end

function R.section_hl(section)
  local marks = {}
  for i, e in ipairs(section.entries) do
    local group = HL_GROUP[e.kind]
    if group then
      marks[#marks + 1] = { row = i - 1, group = group }
    end
  end
  return marks
end

return R
