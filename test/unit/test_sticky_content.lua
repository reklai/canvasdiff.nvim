-- What the sticky file-header row should SHOW: pure resolution from a canvas
-- state and a 0-based topline to a header line plus marker spans, or nil for
-- "pin nothing". The float that renders this answer is Task 7's integration
-- concern; every state here is built through the real canvas open path so
-- locate and fold see the invariants they expect -- never a hand-rolled st.

local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local render = canvas.format
local model = require("canvasdiff.diff")
local sticky = require("canvasdiff.ui").sticky_header

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

T["sticky_ content mid-file answers that file's own header line and spans"] = function()
  local st = two_file_state()
  local got = sticky.content(st, 2) -- topline two rows into section 1
  local section = st.sections[1]
  H.eq(got.line, render.section_line(section, 1))
  H.eq(got.spans,
    render.marker_spans(got.line, section.staged, section.unstaged, false))
  assert(#got.spans > 0,
    "the fixture carries status facts, so the mirror contract must be exercised on real spans")
end

T["sticky_ content is nil when the header row itself is the topline"] = function()
  local st = two_file_state()
  H.eq(sticky.content(st, 0), nil)
end

T["sticky_ content swaps at the section boundary"] = function()
  local st = two_file_state()
  local boundary = (canvas.section_rows(st, 2)) -- section 2's start row, live
  H.eq(sticky.content(st, boundary - 1).line,
    render.section_line(st.sections[1], 1),
    "the last row of section 1 still pins section 1's header")
  H.eq(sticky.content(st, boundary + 1).line,
    render.section_line(st.sections[2], 1),
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
  H.eq(sticky.content(st, boundary + 1).line,
    render.section_line(st.sections[2], 1))
end

return T
