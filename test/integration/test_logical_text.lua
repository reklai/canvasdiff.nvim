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

T["logical_ reads and exports buffer rows across folds and splices"] = function()
  local st = canvas.open(three_sections(), {})
  local logical = canvas.logical(st)

  local shapes = {
    { "as rendered", function() end },
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
    local buf_lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
    local total = logical.row_count()
    H.eq(total, #buf_lines, shape[1] .. ": row count matches buffer")
    H.eq(assert(logical.rows(0, total)), buf_lines, shape[1] .. ": rows match buffer")
    H.eq(assert(logical.rows(0, 0)), {}, shape[1] .. ": empty range")
    H.eq(assert(logical.export(0, total)), table.concat(buf_lines, "\n"),
      shape[1] .. ": export matches joined buffer lines")
    if total > 0 then
      H.eq(assert(logical.row(0)), buf_lines[1], shape[1] .. ": row 0")
      H.eq(assert(logical.export(0, total, { terminal_eol = true })),
        table.concat(buf_lines, "\n") .. "\n", shape[1] .. ": terminal_eol")
    end
    H.eq(logical.rows(0, total + 1), nil, shape[1] .. ": refuses over-read")
  end
end

T["logical_ refuses malformed asks"] = function()
  local st = canvas.open(three_sections(), {})
  local logical = canvas.logical(st)

  for _, case in ipairs({
    { -1, 1, "a negative start" },
    { 0, -1, "a negative count" },
    { 1.5, 1, "a fractional start" },
    { 0, 1.5, "a fractional count" },
    { "0", 1, "a start that is not a number" },
    { 0, "1", "a count that is not a number" },
  }) do
    local rows, err = logical.rows(case[1], case[2])
    H.eq(rows, nil, case[3] .. " is refused")
    assert(type(err) == "string" and err ~= "", case[3] .. " says why")
  end

  local exported, export_err = logical.export(0, 1, { separator = 7 })
  H.eq(exported, nil, "a non-string separator is refused")
  assert(export_err:find("separator", 1, true), export_err)
  local eol, eol_err = logical.export(0, 1, { terminal_eol = "yes" })
  H.eq(eol, nil, "a non-boolean terminal_eol is refused")
  assert(eol_err:find("terminal_eol", 1, true), eol_err)
end

T["logical_ a canvas whose buffer is gone reports rather than throws"] = function()
  local st = canvas.open(three_sections(), {})
  local logical = canvas.logical(st)
  assert(logical.row_count() > 0, "sanity")

  local doomed = st.buf
  st.buf = -1
  H.eq(logical.row_count(), 0, "an invalid buffer has no logical rows")
  local rows, err = logical.rows(0, 1)
  H.eq(rows, nil)
  assert(err:find("unavailable", 1, true), err)
  H.eq(logical.row(0), nil, "and no row to read")
  st.buf = doomed
end

return T
