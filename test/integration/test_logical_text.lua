-- The eager/paged oracle.
--
-- A page-backed canvas is only substitutable for the eager one if it answers
-- "what text is at logical rows N..M" identically -- for every range, after
-- every shape change, and at every boundary. That equivalence is the
-- precondition for swapping the display over, so it is pinned here before
-- anything depends on it.
--
-- The eager side reads real buffer lines; the paged side reads a PageList
-- through a Projection, which holds a blank skeleton buffer and never has the
-- text in a buffer at all.

local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")

local T = {}

local function bigtext(n, tag)
  local out = {}
  for i = 1, n do
    out[i] = ("%s line %d"):format(tag, i)
  end
  return table.concat(out, "\n") .. "\n"
end

local function section(path, tag, rows)
  local old = bigtext(rows or 40, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 5, rows or 40, 5 do
    if lines[i] and lines[i] ~= "" then
      lines[i] = lines[i] .. " changed"
    end
  end
  return model.build_section(path, old, table.concat(lines, "\n"), "M")
end

local function three_sections()
  return {
    section("a/one.txt", "a"),
    section("b/two.txt", "b"),
    section("c/three.txt", "c"),
  }
end

--- A paged view of exactly the rows the eager canvas is showing.
---
--- Built from the eager canvas's own logical text, which is the only way the
--- two can be compared without reimplementing rendering twice.
local function paged_from(eager)
  local rows = assert(eager.rows(0, eager.row_count()))
  local list, list_err = canvas.paginate(rows)
  assert(list, list_err)
  local projection, projection_err = canvas.project(list)
  assert(projection, projection_err)
  return projection, list
end

--- Every way of asking must agree, over the whole canvas and over ranges.
local function assert_agrees(eager, projection, label)
  local total = eager.row_count()
  H.eq(projection:row_count(), total, label .. ": row counts agree")

  local eager_all = assert(eager.rows(0, total))
  local paged_all = assert(projection:rows(0, total))
  H.eq(paged_all, eager_all, label .. ": every logical row agrees")

  for _, row0 in ipairs({ 0, 1, math.floor(total / 2), total - 1 }) do
    if row0 >= 0 and row0 < total then
      H.eq(projection:row(row0), assert(eager.row(row0)),
        ("%s: row %d agrees"):format(label, row0))
    end
  end

  -- Deterministic pseudo-random ranges: a fixed walk, so a failure replays.
  local cursor = 7
  for _ = 1, 40 do
    cursor = (cursor * 31 + 17) % (total > 0 and total or 1)
    local start0 = cursor
    local count = (cursor * 13 + 3) % (total - start0 + 1)
    H.eq(assert(projection:rows(start0, count)),
      assert(eager.rows(start0, count)),
      ("%s: rows(%d, %d) agree"):format(label, start0, count))
    H.eq(assert(projection:export(start0, count)),
      assert(eager.export(start0, count)),
      ("%s: export(%d, %d) agrees"):format(label, start0, count))
    H.eq(assert(projection:export(start0, count, { terminal_eol = true })),
      assert(eager.export(start0, count, { terminal_eol = true })),
      ("%s: export(%d, %d) with a terminal newline agrees"):format(
        label, start0, count))
  end

  -- The empty range and the whole canvas are the two boundaries every
  -- off-by-one lands on.
  H.eq(assert(projection:rows(0, 0)), assert(eager.rows(0, 0)),
    label .. ": the empty range agrees")
  H.eq(assert(projection:export(0, total)), assert(eager.export(0, total)),
    label .. ": exporting the whole canvas agrees")

  -- And both refuse the same over-long range rather than truncating it.
  H.eq(eager.rows(0, total + 1), nil, label .. ": eager refuses to over-read")
  H.eq(projection:rows(0, total + 1), nil, label .. ": paged refuses too")
end

T["logical_ a paged view reproduces the eager canvas byte for byte"] = function()
  local st = canvas.open(three_sections(), {})
  local eager = canvas.logical(st)
  local projection = paged_from(eager)
  local ok, err = xpcall(function()
    assert(eager.row_count() > 100, "sanity: a canvas worth paging")
    assert_agrees(eager, projection, "as rendered")
  end, debug.traceback)
  projection:dispose(true)
  assert(ok, err)
end

T["logical_ the oracle holds across folds and splices"] = function()
  local st = canvas.open(three_sections(), {})
  local eager = canvas.logical(st)

  local shapes = {
    { "collapsed", function() canvas.set_collapsed(st, 1, true) end },
    { "expanded again", function() canvas.set_collapsed(st, 1, false) end },
    { "two collapsed", function()
      canvas.set_collapsed(st, 2, true)
      canvas.set_collapsed(st, 3, true)
    end },
    { "replaced section", function()
      canvas.replace_section(st, 1, section("a/one.txt", "a", 25))
    end },
    { "re-rendered", function()
      canvas.render_all(st, { section("only.txt", "z", 30) })
    end },
    { "emptied", function() canvas.render_all(st, {}) end },
  }

  for _, shape in ipairs(shapes) do
    shape[2]()
    local projection = paged_from(eager)
    local ok, err = xpcall(function()
      assert_agrees(eager, projection, shape[1])
    end, debug.traceback)
    projection:dispose(true)
    assert(ok, err)
  end
end

T["logical_ the eager view refuses the same malformed asks the paged one does"] = function()
  local st = canvas.open(three_sections(), {})
  local eager = canvas.logical(st)

  for _, case in ipairs({
    { -1, 1, "a negative start" },
    { 0, -1, "a negative count" },
    { 1.5, 1, "a fractional start" },
    { 0, 1.5, "a fractional count" },
    { "0", 1, "a start that is not a number" },
    { 0, "1", "a count that is not a number" },
  }) do
    local rows, err = eager.rows(case[1], case[2])
    H.eq(rows, nil, case[3] .. " is refused")
    assert(type(err) == "string" and err ~= "", case[3] .. " says why")
  end

  local exported, export_err = eager.export(0, 1, { separator = 7 })
  H.eq(exported, nil, "a non-string separator is refused")
  assert(export_err:find("separator", 1, true), export_err)
  local eol, eol_err = eager.export(0, 1, { terminal_eol = "yes" })
  H.eq(eol, nil, "a non-boolean terminal_eol is refused")
  assert(eol_err:find("terminal_eol", 1, true), eol_err)
end

T["logical_ a canvas whose buffer is gone reports rather than throws"] = function()
  local st = canvas.open(three_sections(), {})
  local eager = canvas.logical(st)
  assert(eager.row_count() > 0, "sanity")

  local doomed = st.buf
  st.buf = -1
  H.eq(eager.row_count(), 0, "an invalid buffer has no logical rows")
  local rows, err = eager.rows(0, 1)
  H.eq(rows, nil)
  assert(err:find("unavailable", 1, true), err)
  H.eq(eager.row(0), nil, "and no row to read")
  st.buf = doomed
end

return T
