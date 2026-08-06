-- Canvas navigation arithmetic: pure motion stepping over the rendered model.

local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")
local motions = require("canvasdiff.input").motions
local virt = require("canvasdiff.runtime").virtualizer

local T = {}

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

-- ~55 rows per section (6 separated hunks): same idiom as test_sidebar.lua's
-- big_section, tall enough that scroll-targeting assertions can't clamp to
-- the wrong section against the ~22-row headless window.
local function big_section(path, tag)
  local old = bigtext(60, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 10, 60, 10 do
    lines[i] = lines[i] .. " changed"
  end
  local new = table.concat(lines, "\n")
  return model.build_section(path, old, new, "M")
end

local function three_sections()
  return {
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
  }
end

local function canvas_top0(st)
  return vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") - 1 end)
end

-- The canvas buffer is a singleton whose window remembers its view across
-- tests, so anything asserting on a topline has to pin one first.
local function set_top(st, row0)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = row0 + 1, lnum = row0 + 1 })
  end)
end

-- 0-based canvas rows of section `i`'s hunk headers. Only valid for an
-- UNFOLDED section: a folded one renders as a single row while still carrying
-- every entry, so this arithmetic would point into the following files.
local function hunk_hdr_rows(st, i)
  local start0 = (canvas.section_rows(st, i))
  local out = {}
  for idx, entry in ipairs(st.sections[i].entries) do
    if entry.kind == "hunk_hdr" then
      out[#out + 1] = start0 + idx - 1
    end
  end
  return out
end

-- 0-based row of the LAST hunk header across all sections, and the
-- 0-based exclusive end row of the section it belongs to.
local function last_hunk_row_and_section_end(st)
  local last_row, seg_end
  for i, section in ipairs(st.sections) do
    local s0, e0 = canvas.section_rows(st, i)
    for idx, entry in ipairs(section.entries) do
      if entry.kind == "hunk_hdr" then
        last_row = s0 + idx - 1
        seg_end = e0
      end
    end
  end
  return last_row, seg_end
end

T["motions_ ]f [f move between section starts and clamp"] = function()
  local st = canvas.open(three_sections(), {})
  local b_start = (canvas.section_rows(st, 2))
  vim.api.nvim_win_set_cursor(st.win, { b_start + 3, 1 }) -- mid section 2

  motions.goto_file(st, 1, 1)
  local c_start = (canvas.section_rows(st, 3))
  H.eq(vim.api.nvim_win_get_cursor(st.win), { c_start + 1, 0 }, "moved to section 3 start")

  for _ = 1, 3 do
    motions.goto_file(st, 1, 1)
  end
  H.eq(vim.api.nvim_win_get_cursor(st.win), { c_start + 1, 0 }, "clamped at last section")

  for _ = 1, 5 do
    motions.goto_file(st, -1, 1)
  end
  local a_start = (canvas.section_rows(st, 1))
  H.eq(vim.api.nvim_win_get_cursor(st.win), { a_start + 1, 0 }, "clamped at first section")
end

-- --- navigation steps over what you folded -----------------------------

local function cursor_section(st)
  return (canvas.locate(st, vim.api.nvim_win_get_cursor(st.win)[1] - 1))
end

local function put_cursor_in(st, i, offset)
  local s = (canvas.section_rows(st, i))
  vim.api.nvim_win_set_cursor(st.win, { s + 1 + (offset or 0), 0 })
end

local function set_folds(st, dirs)
  st.folded = dirs
  canvas.resync_visibility(st)
end

-- Folded is folded: a folded file is one row, and navigation LANDS on it. That is
-- the whole point -- you arrive at the placeholder, press Tab to unfold, and carry
-- on. Navigation used to step over folded files, which quietly made folding mean
-- "I am done with this" rather than just "collapsed".
T["motions_ ]f [f land ON a folded-away section"] = function()
  local st = canvas.open(three_sections(), {})
  set_folds(st, { ["b/"] = true })

  put_cursor_in(st, 1, 3)
  motions.goto_file(st, 1, 1)
  H.eq(cursor_section(st), 2, "]f stops at the folded middle section, it does not skip it")
  local s2 = (canvas.section_rows(st, 2))
  H.eq(vim.api.nvim_win_get_cursor(st.win)[1], s2 + 1,
    "and lands exactly on its placeholder row, where Tab will unfold it")

  motions.goto_file(st, 1, 1)
  H.eq(cursor_section(st), 3, "carrying on from there works normally")
  motions.goto_file(st, -1, 1)
  H.eq(cursor_section(st), 2, "[f stops there too")
  set_folds(st, {})
end

-- Guard: passes before and after. It exists to fail if someone swaps the
-- navigation predicate for the rendering one. The virtualizer collapsing a
-- far-away section is bookkeeping, not the user putting it away, so navigation
-- must still be able to land there.
T["motions_ ]f stops at an auto-collapsed section"] = function()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_win_call(st.win, function() vim.fn.winrestview({ topline = 1, lnum = 1 }) end)
  local lease = virt.attach(st, { enabled = false })
  virt.apply(lease, { enabled = true, max_files = 1, max_lines = 1000000, margin = 0, max_expanded = 1 })
  local auto = H.auto_set(st)
  assert(auto["b/two.txt"], "sanity: virt auto-collapsed section 2")

  put_cursor_in(st, 1, 0)
  motions.goto_file(st, 1, 1)
  H.eq(cursor_section(st), 2, "]f lands on the auto-collapsed section, not past it")
  virt.detach(lease)
end

T["motions_ ]f [f still move with every section folded"] = function()
  local st = canvas.open(three_sections(), {})
  set_folds(st, { ["a/"] = true, ["b/"] = true, ["c/"] = true })

  put_cursor_in(st, 2, 0)
  motions.goto_file(st, 1, 1)
  H.eq(cursor_section(st), 3, "every section is a stop, so there is always somewhere to go")
  motions.goto_file(st, -1, 1)
  H.eq(cursor_section(st), 2, "and back")
  set_folds(st, {})
end

T["motions_ ]f counts every section, folded or not"] = function()
  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
    big_section("d/four.txt", "d"),
  }, {})
  set_folds(st, { ["b/"] = true })

  put_cursor_in(st, 1, 0)
  motions.goto_file(st, 1, 2)
  H.eq(cursor_section(st), 3, "2]f counts the folded b/ as one of the two")
  set_folds(st, {})
end

-- goto_file takes an explicit count parameter, and there is no zero-count
-- motion in Vim -- so 0 clamps to 1 rather than meaning "stay put". It
-- briefly did not: the old stepping helpers clamped while the plain-index
-- path used the count raw.
T["motions_ count = 0 clamps to 1 in goto_file"] = function()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_win_call(st.win, function() vim.fn.winrestview({ topline = 1, lnum = 1 }) end)

  put_cursor_in(st, 1, 3)
  motions.goto_file(st, 1, 0)
  H.eq(cursor_section(st), 2, "count 0 moves one section, like count1")
end

-- A folded file gets exactly ONE ]h stop: its placeholder row. So ]h walks INTO it
-- rather than over it -- arrive, press Tab, carry on. The old behaviour skipped
-- folded sections entirely, which meant a folded file was unreachable by ]h.
--
-- What it must never do is land on a row computed from a folded section's ENTRIES.
-- That part is arithmetic, not policy: the section still carries every entry while
-- rendering as one row, so `start0 + idx - 1` would point into the FOLLOWING file.
T["motions_ ]h treats a folded section as exactly one stop"] = function()
  local st = canvas.open(three_sections(), {})
  canvas.set_collapsed(st, 2, true)

  local b_start, b_end = canvas.section_rows(st, 2)
  H.eq(b_end - b_start, 1, "sanity: section 2 is a one-row placeholder")
  local c_start = (canvas.section_rows(st, 3))

  local a_start = (canvas.section_rows(st, 1))
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 })

  -- Walk forward, collecting every row ]h stops on until we reach section 3.
  local visited, prev = {}, a_start
  for _ = 1, 30 do
    motions.goto_hunk(st, 1, 1)
    local row = vim.api.nvim_win_get_cursor(st.win)[1] - 1
    if row == prev then break end
    assert(row > prev, "hunk motion must move forward")
    visited[#visited + 1] = row
    prev = row
    if row >= c_start then break end
  end

  -- Exactly one of those stops is inside section 2, and it is its placeholder row.
  local in_b = {}
  for _, row in ipairs(visited) do
    if row >= b_start and row < b_end then in_b[#in_b + 1] = row end
  end
  H.eq(in_b, { b_start },
    "the folded section contributes one stop, its placeholder -- not zero, not many")
  assert(visited[#visited] >= c_start, "and ]h carries on into section 3 afterwards")
end

T["motions_ ]h inside the last hunk's body does not reverse direction"] = function()
  local st = canvas.open(three_sections(), {})
  local last_row, seg_end = last_hunk_row_and_section_end(st)
  local body_row0 = math.min(last_row + 2, seg_end - 1)
  vim.api.nvim_win_set_cursor(st.win, { body_row0 + 1, 0 })

  local before = vim.api.nvim_win_get_cursor(st.win)
  motions.goto_hunk(st, 1, 1)
  H.eq(vim.api.nvim_win_get_cursor(st.win), before,
    "]h past the last hunk header must not move the cursor backward")
end

T["motions_ [h before the first hunk header does not reverse direction"] = function()
  local st = canvas.open(three_sections(), {})
  local a_start = (canvas.section_rows(st, 1))
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 }) -- file_hdr row, before any hunk header

  local before = vim.api.nvim_win_get_cursor(st.win)
  motions.goto_hunk(st, -1, 1)
  H.eq(vim.api.nvim_win_get_cursor(st.win), before,
    "[h before the first hunk header must not move the cursor forward")
end

T["motions_ count is honored"] = function()
  local st = canvas.open(three_sections(), {})
  local a_start = (canvas.section_rows(st, 1))
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 })

  motions.goto_file(st, 1, 2) -- explicit count param, skip section 2 -> land on 3
  local c_start = (canvas.section_rows(st, 3))
  H.eq(vim.api.nvim_win_get_cursor(st.win), { c_start + 1, 0 })
end

T["motions_ [h steps back to the previous hunk header"] = function()
  local st = canvas.open(three_sections(), {})
  local a_start = (canvas.section_rows(st, 1))
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 }) -- file_hdr row

  motions.goto_hunk(st, 1, 1)
  local first_header = vim.api.nvim_win_get_cursor(st.win)
  motions.goto_hunk(st, 1, 1)
  local second_header = vim.api.nvim_win_get_cursor(st.win)
  assert(second_header[1] > first_header[1], "sanity: forward step actually advanced")

  motions.goto_hunk(st, -1, 1)
  H.eq(vim.api.nvim_win_get_cursor(st.win), first_header, "[h steps back to the previous header")
end

T["motions_ 2]h skips one hunk header ahead"] = function()
  local st = canvas.open(three_sections(), {})
  local a_start = (canvas.section_rows(st, 1))
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 }) -- file_hdr row

  motions.goto_hunk(st, 1, 1)
  local one_step = vim.api.nvim_win_get_cursor(st.win)

  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 }) -- reset
  motions.goto_hunk(st, 1, 2)
  local two_step = vim.api.nvim_win_get_cursor(st.win)

  assert(two_step[1] > one_step[1], "2]h must land further than a single ]h step")
end

-- --- the hunk stop list, shared by ]h and Ctrl+N ------------------------

-- A file header is where hunks live, not a destination -- so it is never a
-- stop. A FOLDED file is exactly one: its placeholder row, the only row it
-- actually owns.
T["motions_ hunk_stops make a folded file exactly one stop"] = function()
  local st = canvas.open(three_sections(), {})
  canvas.set_collapsed(st, 2, true)

  local b_start, b_end = canvas.section_rows(st, 2)
  H.eq(b_end - b_start, 1, "sanity: section 2 is a one-row placeholder")

  local expected = {}
  for _, row in ipairs(hunk_hdr_rows(st, 1)) do expected[#expected + 1] = row end
  expected[#expected + 1] = b_start
  for _, row in ipairs(hunk_hdr_rows(st, 3)) do expected[#expected + 1] = row end
  assert(#expected > 3, "sanity: the fixture has several hunks per file")

  H.eq(motions.hunk_stops(st), expected,
    "every hunk header in reading order, the folded file's placeholder, nothing else")
end

-- One home for the arithmetic: ]h does not compute its own list, it walks
-- this one. Extracting the loop that changed what ]h stops on would be an
-- extraction that changed behaviour.
T["motions_ ]h walks exactly the hunk_stops list"] = function()
  local st = canvas.open(three_sections(), {})
  -- With a fold in the middle, so a second list that merely LOOKS the same on
  -- an all-unfolded review cannot pass this.
  canvas.set_collapsed(st, 2, true)
  local stops = motions.hunk_stops(st)
  assert(#stops > 3, "sanity: several stops to walk")

  vim.api.nvim_win_set_cursor(st.win, { 1, 0 })
  local visited = {}
  for _ = 1, #stops + 2 do
    motions.goto_hunk(st, 1, 1)
    local row = vim.api.nvim_win_get_cursor(st.win)[1] - 1
    if visited[#visited] == row then
      break
    end
    visited[#visited + 1] = row
  end
  H.eq(visited, stops, "]h visits the stop list in order and then clamps at its end")
end

-- --- Ctrl+N / Ctrl+P: the wrapping walk --------------------------------

T["motions_ cycle_hunk scrolls stop by stop and wraps at both ends"] = function()
  local st = canvas.open(three_sections(), {})
  local stops = motions.hunk_stops(st)
  set_top(st, 0)

  local visited = {}
  for _ = 1, #stops do
    local landed = motions.cycle_hunk(st, st.win, 1)
    visited[#visited + 1] = landed
    H.eq(canvas_top0(st), landed, "the landed stop becomes the topline")
  end
  H.eq(visited, stops,
    "one press per stop walks the whole list in order, crossing file boundaries")

  H.eq(motions.cycle_hunk(st, st.win, 1), stops[1],
    "past the last stop it wraps to the first rather than clamping")
  H.eq(motions.cycle_hunk(st, st.win, -1), stops[#stops],
    "and backwards off the front it wraps to the last")
end

-- Clamping is what makes "I have seen every hunk" detectable, so ]h keeps its
-- finish line while Ctrl+N is the free-scrolling walk over the same stops.
T["motions_ ]h clamps at the last stop where cycle_hunk wraps"] = function()
  local st = canvas.open(three_sections(), {})
  local stops = motions.hunk_stops(st)
  local last = stops[#stops]

  vim.api.nvim_win_set_cursor(st.win, { last + 1, 0 })
  motions.goto_hunk(st, 1, 1)
  H.eq(vim.api.nvim_win_get_cursor(st.win)[1] - 1, last, "]h stays put at the end")

  set_top(st, last)
  H.eq(motions.cycle_hunk(st, st.win, 1), stops[1], "Ctrl+N wraps instead")
end

-- The rows above the first file's first hunk header belong to no stop, which
-- is the one position the section cycle never has to think about -- locate()
-- puts every row in some section. Backwards from there must reach the LAST
-- stop, not the one before it.
T["motions_ cycle_hunk above the first stop still wraps onto the last"] = function()
  local st = canvas.open(three_sections(), {})
  local stops = motions.hunk_stops(st)
  assert(stops[1] > 0, "sanity: the file header row is above every stop")

  set_top(st, 0)
  H.eq(motions.cycle_hunk(st, st.win, -1), stops[#stops],
    "Ctrl+P at the very top of the review reaches the last hunk")
  set_top(st, 0)
  H.eq(motions.cycle_hunk(st, st.win, 1), stops[1], "and Ctrl+N reaches the first")
end

T["motions_ cycle_hunk lands on a folded file's placeholder"] = function()
  local st = canvas.open(three_sections(), {})
  canvas.set_collapsed(st, 2, true)
  local b_start = (canvas.section_rows(st, 2))
  local a_rows = hunk_hdr_rows(st, 1)
  local last_a = a_rows[#a_rows]

  set_top(st, last_a)
  H.eq(motions.cycle_hunk(st, st.win, 1), b_start,
    "the folded file is one stop -- its placeholder, not zero stops and not its hidden hunks")
  H.eq(canvas_top0(st), b_start, "and the view really scrolled there")
  H.eq(motions.cycle_hunk(st, st.win, -1), last_a, "and one press back out of it")
end

T["motions_ cycle_hunk honors a count"] = function()
  local st = canvas.open(three_sections(), {})
  local stops = motions.hunk_stops(st)
  assert(#stops >= 5, "sanity: enough stops to count over")

  set_top(st, stops[1])
  H.eq(motions.cycle_hunk(st, st.win, 1, 3), stops[4], "3<C-n> moves three stops")
  H.eq(motions.cycle_hunk(st, st.win, -1, 2), stops[2], "and 2<C-p> two back")

  set_top(st, stops[1])
  H.eq(motions.cycle_hunk(st, st.win, 1, 0), stops[2],
    "count 0 clamps to 1 here too -- there is no zero-count motion")
end

T["motions_ cycle_hunk declines a window that is not showing the canvas"] = function()
  local st = canvas.open(three_sections(), {})
  set_top(st, 0)
  local before = canvas_top0(st)

  vim.cmd("split")
  local other = vim.api.nvim_get_current_win()
  vim.cmd("enew")
  H.eq(motions.cycle_hunk(st, other, 1), nil, "a foreign window is not a canvas to scroll")
  H.close_windows(other)
  H.eq(canvas_top0(st), before, "and the canvas was left where it was")
end

return T
