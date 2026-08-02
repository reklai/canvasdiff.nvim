-- What the sticky file-header row should SHOW: pure resolution from a canvas
-- state and a 0-based topline to a header line plus marker spans, or nil for
-- "pin nothing". The float that renders this answer is Task 7's integration
-- concern; every state here is built through the real canvas open path so
-- locate and fold see the invariants they expect -- never a hand-rolled st.

local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local render = canvas.format
local config = require("canvasdiff.config")
local model = require("canvasdiff.diff")
local ui = require("canvasdiff.ui")
local sticky = ui.sticky_header

local T = {}

--- Two small sections through the real open path: section 1 occupies rows
--- 0..N-1 and section 2 starts at N (always resolved live via
--- canvas.section_rows, never assumed). Section 1 carries both status facts
--- so the span assertion compares non-empty output; section 2 carries none,
--- the shape a range lens produces.
local function two_file_state()
  local a = model.build_section("a/one.txt",
    "a1\na2\na3\na4\na5\n", "a1\na2\nA3\na4\na5\n", "M",
    nil, { staged = "M", unstaged = "M" })
  local b = model.build_section("b/two.txt",
    "b1\nb2\nb3\nb4\nb5\n", "b1\nB2\nb3\nb4\nb5\n", "M")
  return canvas.open({ a, b }, {})
end

--- One section with two hunks, far enough apart that the default context
--- window cannot merge them, so the ordinal has something to count. The second
--- label is deliberately long: it is the elastic part of the crumb, and a short
--- one would leave the truncation assertions nothing to cut.
local function two_hunk_state()
  local old, new = {}, {}
  for i = 1, 24 do
    old[i] = ("line %d"):format(i)
    new[i] = old[i]
  end
  new[2] = "SECOND"
  new[20] = "local reconfigured = compute(alpha, beta, gamma)"
  return canvas.open({ model.build_section("src/two.lua",
    table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", "M",
    nil, { staged = "M", unstaged = "M" }) }, {})
end

--- A hunk that only removes lines: it writes no new-side line, so it has no
--- number for the crumb and its label is old-side text.
local function deletion_state()
  return canvas.open({ model.build_section("src/gone.lua",
    "keep 1\nkeep 2\nremoved line\nkeep 4\nkeep 5\n",
    "keep 1\nkeep 2\nkeep 4\nkeep 5\n", "M") }, {})
end

--- The 0-based canvas row one past hunk `gi`'s header in section `i` -- a body
--- row of that hunk, resolved live rather than counted by hand.
local function inside_hunk(st, i, gi)
  return assert(canvas.context.hunk_row(st, i, gi)) + 1
end

--- The ordinal as the row spells it, from the live glyph table -- a
--- `glyphs = "ascii"` config must not be able to break these expectations.
local function ordinal(n, total)
  return ("%s%d/%d"):format(render.glyphs.crumb_sep, n, total)
end

--- What the sidebar's own tree row calls hunk `gi` of `path`. The crumb has to
--- agree with it character for character: one identity format for hunks
--- everywhere is the whole reason a closed sidebar loses nothing.
local function sidebar_name(st, path, gi)
  for _, e in ipairs(ui.sidebar.build_entries(st.sections, {}, {}, {})) do
    if e.kind == "hunk" and e.path == path and e.hunk == gi then
      return e.name
    end
  end
  error("no sidebar hunk row for " .. path .. " #" .. gi)
end

T["sticky_ content mid-file answers that file's own header line and spans"] = function()
  local st = two_file_state()
  local got = sticky.content(st, 2) -- topline two rows into section 1
  local section = st.sections[1]
  local header = render.section_line(section, 1)
  H.eq(got.line:sub(1, #header), header,
    "the file part is a verbatim mirror of the header row the float covers")
  -- Measured off the FILE line, never the crumbed one: marker_spans walks in
  -- from the end of what it is given, so feeding it the whole row would put
  -- the stage marks on the crumb's last bytes.
  local marks = render.marker_spans(header, section.staged, section.unstaged, false)
  assert(#marks > 0,
    "the fixture carries status facts, so the mirror contract must be exercised on real spans")
  for i, span in ipairs(marks) do
    H.eq(got.spans[i], span, "the stage marks stay on the file part's own bytes")
  end
end

T["sticky_ content is nil when the header row itself is the topline"] = function()
  local st = two_file_state()
  H.eq(sticky.content(st, 0), nil)
end

T["sticky_ content swaps at the section boundary"] = function()
  local st = two_file_state()
  local boundary = (canvas.section_rows(st, 2)) -- section 2's start row, live
  local one = render.section_line(st.sections[1], 1)
  local two = render.section_line(st.sections[2], 1)
  H.eq(sticky.content(st, boundary - 1).line:sub(1, #one), one,
    "the last row of section 1 still pins section 1's header")
  H.eq(sticky.content(st, boundary + 1).line:sub(1, #two), two,
    "one row past the boundary pins section 2's header")
end

T["sticky_ content is nil on an empty canvas and off the end"] = function()
  H.eq(sticky.content({ sections = {} }, 0), nil)
  -- Every row of an empty canvas is off the end; there is nothing to resolve.
  H.eq(sticky.content({ sections = {} }, 42), nil)
end

T["sticky_ content is nil when the section under the top is folded"] = function()
  local st = two_file_state()
  canvas.set_collapsed(st, 1, true)
  -- Section 1's single placeholder row IS its header now: nothing to pin.
  H.eq(sticky.content(st, 0), nil)
  -- The fold hides only its own section: one row past section 2's start
  -- (which now sits right below the placeholder) still answers its header.
  local boundary = (canvas.section_rows(st, 2))
  local two = render.section_line(st.sections[2], 1)
  H.eq(sticky.content(st, boundary + 1).line:sub(1, #two), two)
end

T["sticky_ mid-hunk content carries the crumb and ordinal"] = function()
  local st = two_hunk_state()
  local section = st.sections[1]
  local got = sticky.content(st, inside_hunk(st, 1, 2))
  assert(got.line:find(render.glyphs.crumb .. "@@ ", 1, true),
    "crumb present: " .. got.line)
  assert(got.line:find(ordinal(2, 2), 1, true), "ordinal present: " .. got.line)
  H.eq(got.line,
    render.section_line(section, 1)
      .. render.glyphs.crumb .. sidebar_name(st, section.path, 2) .. ordinal(2, 2),
    "the whole row: the file header, then the sidebar's own name for the hunk")

  -- The hunk the topline is INSIDE, not the nearest one in either direction.
  local first = sticky.content(st, inside_hunk(st, 1, 1))
  assert(first.line:find(ordinal(1, 2), 1, true), "ordinal counts from 1: " .. first.line)
  H.eq(first.line,
    render.section_line(section, 1)
      .. render.glyphs.crumb .. sidebar_name(st, section.path, 1) .. ordinal(1, 2))
end

T["sticky_ the hunk header row is already inside its own hunk"] = function()
  local st = two_hunk_state()
  -- The float COVERS the top text row, so the `@@` row under it is exactly the
  -- one the crumb has to name -- "at or above the topline", not strictly above.
  local got = sticky.content(st, assert(canvas.context.hunk_row(st, 1, 2)))
  assert(got.line:find(ordinal(2, 2), 1, true), "ordinal present: " .. got.line)
end

T["sticky_ the file lead-in is file-only"] = function()
  -- A binary file is the reachable lead-in: build_section puts the first hunk
  -- header immediately after the file header, so the rows with no hunk at or
  -- above them are the ones a section publishes outside its hunks entirely.
  local st = canvas.open({ model.build_section("bin/blob.dat",
    "old\0bytes", "new\0bytes", "M", nil, { staged = "M" }) }, {})
  local section = st.sections[1]
  H.eq(#section.hunks, 0, "sanity: this section publishes no hunks at all")
  local got = sticky.content(st, 1) -- the binary notice row
  H.eq(got.line, render.section_line(section, 1),
    "no hunk at or above the topline, so the row is the file header and nothing more")
  H.eq(got.spans,
    render.marker_spans(got.line, section.staged, section.unstaged, false))
end

T["sticky_ a pure-deletion current hunk strikes its label"] = function()
  local st = deletion_state()
  local section = st.sections[1]
  local hunk = section.hunks[1]
  H.eq(hunk.pure_del, true, "sanity: the fixture's only hunk removes and adds nothing")
  H.eq(hunk.new_lo, nil, "sanity: it writes no new-side line, so it has no number")

  local got = sticky.content(st, inside_hunk(st, 1, 1))
  H.eq(got.line,
    render.section_line(section, 1)
      .. render.glyphs.crumb .. sidebar_name(st, section.path, 1) .. ordinal(1, 1))

  local struck = {}
  for _, span in ipairs(got.spans) do
    if span[3] == "CanvasDiffHunkDel" then
      struck[#struck + 1] = span
    end
  end
  H.eq(#struck, 1, "one strike, over the label")
  H.eq(got.line:sub(struck[1][1] + 1, struck[1][2]), "removed line",
    "the strike covers the old-side text and nothing else -- not the @@, not the ordinal")

  -- The crumb's own group runs under it, over the whole crumb.
  local crumb_start = #render.section_line(section, 1)
  H.eq(got.spans[#got.spans - 1],
    { crumb_start, #got.line, "CanvasDiffCrumb" },
    "the crumb wears its own group, and the strike layers over it")
end

T["sticky_ an ordinary current hunk is struck nowhere"] = function()
  local st = two_hunk_state()
  local got = sticky.content(st, inside_hunk(st, 1, 2))
  for _, span in ipairs(got.spans) do
    assert(span[3] ~= "CanvasDiffHunkDel",
      "a hunk that adds is not a deletion: " .. span[3])
  end
  H.eq(got.spans[#got.spans],
    { #render.section_line(st.sections[1], 1), #got.line, "CanvasDiffCrumb" })
end

T["sticky_ the crumb's label is the only part a narrow window cuts"] = function()
  local st = two_hunk_state()
  local row = inside_hunk(st, 1, 2)
  local header = render.section_line(st.sections[1], 1)
  local full = sticky.content(st, row).line
  local room = vim.fn.strdisplaywidth(full) - 12

  local got = sticky.content(st, row, room)
  assert(vim.fn.strdisplaywidth(got.line) <= room,
    "the row is cut to the window: " .. got.line)
  H.eq(got.line:sub(1, #header), header, "the file identity is never cut")
  H.eq(got.line:sub(-#ordinal(2, 2)), ordinal(2, 2), "nor is the ordinal")
  assert(#got.line < #full, "something gave way: " .. got.line)
  assert(got.line:find("local recon", 1, true),
    "and what gave way was the tail of the label: " .. got.line)

  -- The strike-range arithmetic has to follow the cut, not the label that
  -- arrived: a span measured before it would run past end-of-line. The count
  -- is asserted first because the loop below is vacuously true over none.
  assert(#got.spans > 0, "a cut row still carries its spans")
  for _, span in ipairs(got.spans) do
    assert(span[2] <= #got.line, "every span stays inside the row it was cut to")
  end
  H.eq(sticky.content(st, row, vim.fn.strdisplaywidth(full)).line, full,
    "given exactly enough room, nothing is cut")
end

-- The preset exists for a restricted font or a framebuffer console, where a
-- character it cannot draw comes out as a box. Every character the crumb
-- introduces has to come from the glyph table, or the one row this feature
-- exists for is the row that shows the box.
T["sticky_ the crumb is spelled with the configured glyphs"] = function()
  local st = two_hunk_state()
  local row = inside_hunk(st, 1, 2)
  local ok, err = pcall(function()
    config.setup({ glyphs = "ascii" })
    local line = sticky.content(st, row).line
    assert(line:find(" -> @@ ", 1, true), "the crumb separator is the preset's: " .. line)
    assert(line:find(" | 2/2", 1, true), "and so is the ordinal's: " .. line)
    assert(not line:find("·", 1, true), "no middle dot survives the preset: " .. line)
    assert(not line:find("→", 1, true), "nor an arrow: " .. line)
  end)
  -- Glyphs are live process state, so the restore has to happen even on failure.
  config.setup({})
  assert(ok, err)
end

T["sticky_ a window with no room for the crumb keeps the file alone"] = function()
  local st = two_hunk_state()
  local section = st.sections[1]
  local header = render.section_line(section, 1)
  -- Room for a few cells past the file identity: not enough for the marker and
  -- the ordinal even with the label gone.
  local got = sticky.content(st, inside_hunk(st, 1, 2),
    vim.fn.strdisplaywidth(header) + 6)
  H.eq(got.line, header,
    "a crumb whose ordinal the window would clip is worse than no crumb")
  H.eq(got.spans,
    render.marker_spans(header, section.staged, section.unstaged, false),
    "and the file part keeps its own spans, unchanged")
end

return T
