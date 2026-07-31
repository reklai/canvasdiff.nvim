local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")
local render = require("canvasdiff.canvas").format
local scrollbar = require("canvasdiff.ui").scrollbar
local hl = require("canvasdiff.ui").highlight
local fold = model.fold

local T = {}

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

-- ~55 rows per section (6 separated hunks): sections must be taller than the
-- ~22-row headless window or topline restores would clamp and the
-- scroll-targeting assertions below would silently test the wrong section.
local function big_section(path, tag)
  local old = bigtext(60, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 10, 60, 10 do
    lines[i] = lines[i] .. " changed"
  end
  return model.build_section(path, old, table.concat(lines, "\n"), "M")
end

local function open_three()
  return canvas.open({
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
  }, {})
end

local function reset_view(st)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
end

-- A pure rename invalidates the old row-count shortcut: its expanded header
-- and collapsed placeholder are both exactly one row. resplice must track the
-- form, not infer it from height, or both collapse and expand silently no-op.
T["collapse_ one-row pure rename toggles header and placeholder"] = function()
  local sec = model.build_section(
    "new.txt", "same\n", "same\n", "R", 3,
    { old_path = "old.txt", old_rev = "HEAD" })
  H.eq(#render.section_lines(sec), 1, "expanded pure rename is header-only")
  local st = canvas.open({ sec }, {})
  local function only_line()
    return vim.api.nvim_buf_get_lines(st.buf, 0, 1, false)[1]
  end

  H.eq(only_line(), "▎ old.txt → new.txt  (renamed)")
  canvas.set_collapsed(st, 1, true)
  H.eq(select(2, canvas.section_rows(st, 1)) - (canvas.section_rows(st, 1)), 1,
    "the placeholder has the same height")
  H.eq(only_line(), "▸ old.txt → new.txt  (renamed)",
    "collapse still changes the one-row rendered form")

  canvas.set_collapsed(st, 1, false)
  H.eq(only_line(), "▎ old.txt → new.txt  (renamed)",
    "expand restores the one-row file header")
end

T["collapse_ renders one placeholder row and restores on expand"] = function()
  local st = open_three()
  reset_view(st)
  local sec = st.sections[2]
  local orig_lines = render.section_lines(sec)

  canvas.set_collapsed(st, 2, true)
  local s2, e2 = canvas.section_rows(st, 2)
  H.eq(e2 - s2, 1, "collapsed section spans exactly 1 row")
  local line = vim.api.nvim_buf_get_lines(st.buf, s2, s2 + 1, false)[1]
  H.eq(line, render.placeholder(sec), "buffer line equals the placeholder")

  -- rows stay contiguous across all three sections
  local prev_end
  for i = 1, 3 do
    local s, e = canvas.section_rows(st, i)
    if prev_end then
      H.eq(s, prev_end, "section " .. i .. " starts exactly where the prior one ends")
    end
    prev_end = e
  end

  canvas.set_collapsed(st, 2, false)
  local s2b, e2b = canvas.section_rows(st, 2)
  H.eq(e2b - s2b, #orig_lines, "expand restores the original row span")
  local body = vim.api.nvim_buf_get_lines(st.buf, s2b, e2b, false)
  H.eq(body[1], orig_lines[1], "first body line restored")
  H.eq(body[#body], orig_lines[#orig_lines], "last body line restored")
end

T["collapse_ above viewport keeps visible text pinned"] = function()
  local st = open_three()
  local s3 = (canvas.section_rows(st, 3))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = s3 + 3, lnum = s3 + 3 })
  end)
  local function w0_text()
    return vim.api.nvim_win_call(st.win, function()
      return vim.fn.getline(vim.fn.line("w0"))
    end)
  end
  local before = w0_text()

  canvas.set_collapsed(st, 1, true)
  H.eq(w0_text(), before, "collapsing a section above the viewport leaves visible text pinned")

  canvas.set_collapsed(st, 1, false)
  H.eq(w0_text(), before, "expanding it back leaves visible text pinned")
end

T["collapse_ locate maps the placeholder to offset 1"] = function()
  local st = open_three()
  canvas.set_collapsed(st, 2, true)
  local s2 = (canvas.section_rows(st, 2))
  local i, off = canvas.locate(st, s2)
  H.eq({ i, off }, { 2, 1 })
end

T["collapse_ scrollbar kinds shrink to one hdr"] = function()
  local st = open_three()
  local full_total = #scrollbar.line_kinds(st.sections)
  local sec1_rows = #render.section_lines(st.sections[1])
  local sec2_rows = #render.section_lines(st.sections[2])

  canvas.set_collapsed(st, 2, true)
  local kinds = scrollbar.line_kinds(st.sections, st.collapsed)
  H.eq(#kinds, full_total - (sec2_rows - 1))
  H.eq(kinds[sec1_rows + 1], "hdr", "the placeholder position is hdr")
end

T["collapse_ hl never marks a collapsed section"] = function()
  local st = open_three()
  reset_view(st)
  local lease = hl.attach(st, { margin = 1000 })
  assert(lease.ids_by_path["a/one.txt"] and #lease.ids_by_path["a/one.txt"] > 0,
    "sanity: attach marked section 1 before collapsing")

  canvas.set_collapsed(st, 1, true)
  hl.apply_now(lease)
  H.eq(lease.ids_by_path["a/one.txt"], nil,
    "ids_by_path has no entry for the collapsed section")

  local ns = vim.api.nvim_create_namespace("canvasdiff.canvas.ts")
  local s1, e1 = canvas.section_rows(st, 1)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, ns, 0, -1, {})) do
    assert(not (m[2] >= s1 and m[2] < e1), "no TS-namespace mark within the collapsed section's rows")
  end
  hl.detach(lease)
end

-- --- folds and collapse are one predicate --------------------------------

T["collapse_ set_collapsed on a folded-away section splices nothing"] = function()
  local st = open_three()
  reset_view(st)
  st.folded = { ["b/"] = true }
  canvas.resync_visibility(st, fold.indices_under(st.sections, "b/"))
  H.eq(select(2, canvas.section_rows(st, 2)) - (canvas.section_rows(st, 2)), 1,
    "the fold reduced it to one row")

  local fired = 0
  st.hooks = st.hooks or {}
  local prev = st.hooks.on_section_replaced
  st.hooks.on_section_replaced = function() fired = fired + 1 end

  canvas.set_collapsed(st, 2, true)
  H.eq(fired, 0, "already one row, so there is nothing to re-splice")
  H.eq(st.collapsed["b/two.txt"], "user", "but the intent is recorded")
  local s, e = canvas.section_rows(st, 2)
  H.eq(e - s, 1, "still exactly one row")

  -- And the OR still holds after unfolding, so it stays a placeholder.
  st.folded = {}
  canvas.resync_visibility(st)
  s, e = canvas.section_rows(st, 2)
  H.eq(e - s, 1, "unfolding does not expand what was also collapsed outright")

  st.hooks.on_section_replaced = prev
  st.collapsed = {}
  canvas.resync_visibility(st)
end

T["collapse_ the minimap depicts the folded canvas, not the model"] = function()
  local st = open_three()
  reset_view(st)
  st.folded = { ["b/"] = true }
  canvas.resync_visibility(st, fold.indices_under(st.sections, "b/"))

  local hidden = fold.hidden_set(st.sections, st.collapsed, st.folded)
  H.eq(#scrollbar.line_kinds(st.sections, hidden),
    vim.api.nvim_buf_line_count(st.buf),
    "one kind per real buffer line -- a stale minimap misplaces every cell")

  st.folded = {}
  canvas.resync_visibility(st)
end

T["collapse_ hl never marks a folded-away section"] = function()
  local st = open_three()
  reset_view(st)
  local lease = hl.attach(st, { margin = 1000 })
  assert(lease.ids_by_path["b/two.txt"] and #lease.ids_by_path["b/two.txt"] > 0,
    "sanity: attach marked section 2 before folding")

  st.folded = { ["b/"] = true }
  canvas.resync_visibility(st, fold.indices_under(st.sections, "b/"))
  hl.apply_now(lease)
  H.eq(lease.ids_by_path["b/two.txt"], nil, "no ids tracked for a folded-away section")

  -- The real failure mode: a section that renders as one row still carries all
  -- its entries, so a reader that thinks it expanded writes marks at
  -- srow + m.row -- inside the FOLLOWING file.
  local ns = vim.api.nvim_create_namespace("canvasdiff.canvas.ts")
  local s2, e2 = canvas.section_rows(st, 2)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, ns, 0, -1, {})) do
    assert(not (m[2] >= s2 and m[2] < e2),
      "no TS-namespace mark within the folded-away section's rows")
  end
  hl.detach(lease)
  st.folded = {}
  canvas.resync_visibility(st)
end

T["collapse_ replace_section keeps a collapsed section collapsed"] = function()
  local st = open_three()
  canvas.set_collapsed(st, 2, true)
  local old_sec = st.sections[2]
  local old = old_sec.old_text

  local lines = vim.split(old, "\n", { plain = true })
  for i = 5, 60, 5 do
    lines[i] = lines[i] .. " Z"
  end
  local new_text = table.concat(lines, "\n")
  local new_sec = model.build_section(old_sec.path, old, new_text, "M")
  assert(render.placeholder(new_sec) ~= render.placeholder(old_sec),
    "sanity: the replacement actually has different hunk/add/del counts")

  canvas.replace_section(st, 2, new_sec)

  local s2, e2 = canvas.section_rows(st, 2)
  H.eq(e2 - s2, 1, "still collapsed to 1 row after replace")
  local line = vim.api.nvim_buf_get_lines(st.buf, s2, s2 + 1, false)[1]
  -- Stale, and correctly so: the section was collapsed and then its content
  -- changed underneath, which is exactly what the marker is for.
  H.eq(line, render.placeholder(new_sec, true), "placeholder text reflects the NEW counts")
end

-- The header markers are real characters sitting ON the tinted CanvasDiffFileBar
-- row, so their colour must be col-ranged and sit above both the bar (99) and the
-- header's own hl_eol group (100), or the tint swallows them.
T["collapse_ stage markers are highlighted on the header bar and the placeholder"] = function()
  local sec = model.build_section("f.txt", "a\n", "b\n", "M", 3,
    { staged = "M", unstaged = "M" })
  local st = canvas.open({ sec }, {})
  local ns = vim.api.nvim_create_namespace("canvasdiff.canvas.hl")

  --- Marker marks on row0, keyed by group, plus whether the row carries the bar.
  local MARKER_GROUPS = {
    CanvasDiffStaged = true, CanvasDiffUnstaged = true,
    CanvasDiffStale = true, CanvasDiffStaleEmphasis = true,
  }
  local function row_marks(row0)
    local out, bar = {}, false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, ns, 0, -1, { details = true })) do
      if m[2] == row0 then
        local d = m[4]
        if d.line_hl_group == "CanvasDiffFileBar" then
          bar = true
        end
        if MARKER_GROUPS[d.hl_group] and d.end_row == row0 then
          out[d.hl_group] = { col = m[3], end_col = d.end_col, priority = d.priority }
        end
      end
    end
    return out, bar
  end

  local line = vim.api.nvim_buf_get_lines(st.buf, 0, 1, false)[1]
  H.eq(line, "▎ f.txt  (+1 −1) ●○", "sanity: the header carries both marks")
  local at, bar = row_marks(0)
  H.eq(bar, true, "the full-width bar tint is still on the header row")
  assert(at.CanvasDiffStaged and at.CanvasDiffUnstaged, "both marker spans are placed")
  H.eq(line:sub(at.CanvasDiffStaged.col + 1, at.CanvasDiffStaged.end_col), render.glyphs.staged)
  H.eq(line:sub(at.CanvasDiffUnstaged.col + 1, at.CanvasDiffUnstaged.end_col), render.glyphs.unstaged)
  H.eq(at.CanvasDiffUnstaged.end_col, #line, "the marker block ends at end-of-line")
  assert(at.CanvasDiffStaged.priority > 100 and at.CanvasDiffUnstaged.priority > 100,
    "marker colour must win over the header group at 100")

  -- Collapse: the placeholder carries the same marks, still highlighted.
  canvas.set_collapsed(st, 1, true)
  local prow = vim.api.nvim_buf_get_lines(st.buf, 0, 1, false)[1]
  H.eq(prow, render.placeholder(sec), "sanity: collapsed to the placeholder")
  local pat = row_marks(0)
  assert(pat.CanvasDiffStaged and pat.CanvasDiffUnstaged,
    "the placeholder's marks are highlighted too")
  H.eq(pat.CanvasDiffUnstaged.end_col, #prow)

  -- Change it behind the fold: stale joins, LAST, without stealing a stage span.
  local changed = model.build_section("f.txt", "a\n", "c\n", "M", 3,
    { staged = "M", unstaged = "M" })
  canvas.replace_section(st, 1, changed)
  local srow = vim.api.nvim_buf_get_lines(st.buf, 0, 1, false)[1]
  H.eq(srow, render.placeholder(changed, true), "sanity: the placeholder went stale")
  local sat = row_marks(0)
  assert(sat.CanvasDiffStale and sat.CanvasDiffStaleEmphasis, "stale colour and its bold layer")
  H.eq(sat.CanvasDiffStale.end_col, #srow, "stale is the LAST span")
  H.eq(sat.CanvasDiffStaleEmphasis.col, sat.CanvasDiffStale.col)
  assert(sat.CanvasDiffStaged.col < sat.CanvasDiffStale.col,
    "the staged ● and the stale ● are different glyph occurrences")
end

return T
