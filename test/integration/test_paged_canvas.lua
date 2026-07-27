-- The page-backed canvas, against the eager one.
--
-- A paged canvas is only a substitute for the eager canvas if it renders the
-- same text at the same logical rows and colours the same rows the same way.
-- The first is checked byte for byte against the eager canvas itself; the
-- second is checked by asking where each highlight lands rather than by
-- trusting that the same function was called.
--
-- The invariant that makes it worth doing at all is checked too: a paged
-- canvas holds no persistent extmark, at any row, ever.

local H = require("helpers")
local Paged = require("canvasdiff.canvas.paged")
local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")

local API = vim.api

local T = {}

local function bigtext(n, tag)
  local out = {}
  for index = 1, n do
    out[index] = ("%s line %d"):format(tag, index)
  end
  return table.concat(out, "\n") .. "\n"
end

local function section(path, tag, rows)
  rows = rows or 40
  local old = bigtext(rows, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for index = 5, rows, 5 do
    if lines[index] and lines[index] ~= "" then
      lines[index] = lines[index] .. " changed"
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

local function persistent_marks(buffer)
  local total = 0
  for _, namespace in pairs(API.nvim_get_namespaces()) do
    local ok, marks = pcall(
      API.nvim_buf_get_extmarks, buffer, namespace, 0, -1, {})
    if ok then
      total = total + #marks
    end
  end
  return total
end

T["paged_ renders the same text as the eager canvas, byte for byte"] = function()
  local sections = three_sections()
  local eager_state = canvas.open(sections, {})
  local eager = canvas.logical(eager_state)

  local paged, err = Paged.render(sections)
  assert(paged, err)
  local ok, failure = xpcall(function()
    local logical = Paged.logical(paged)
    local total = eager.row_count()
    assert(total > 100, "sanity: a canvas worth paging")
    H.eq(logical.row_count(), total, "row counts agree")
    H.eq(assert(logical.rows(0, total)), assert(eager.rows(0, total)),
      "every logical row agrees with the eager canvas")

    -- And range reads agree at the boundaries an off-by-one lands on.
    H.eq(assert(logical.rows(0, 0)), assert(eager.rows(0, 0)))
    H.eq(logical.rows(0, total + 1), nil, "the paged canvas refuses to over-read")
    H.eq(assert(logical.row(total - 1)), assert(eager.row(total - 1)))
  end, debug.traceback)
  Paged.dispose(paged)
  assert(ok, failure)
end

T["paged_ collapsed sections render their placeholder, as the eager canvas does"] =
  function()
    local sections = three_sections()
    local eager_state = canvas.open(sections, {})
    canvas.set_collapsed(eager_state, 2, true)
    local eager = canvas.logical(eager_state)

    local paged, err = Paged.render(sections, {
      collapsed = function(path) return path == "b/two.txt" end,
    })
    assert(paged, err)
    local ok, failure = xpcall(function()
      local logical = Paged.logical(paged)
      local total = eager.row_count()
      H.eq(logical.row_count(), total, "a collapsed section costs the same rows")
      H.eq(assert(logical.rows(0, total)), assert(eager.rows(0, total)),
        "every row agrees with the collapsed eager canvas")
    end, debug.traceback)
    Paged.dispose(paged)
    assert(ok, failure)
  end

T["paged_ locates the section and offset for any logical row"] = function()
  local sections = three_sections()
  local paged, err = Paged.render(sections)
  assert(paged, err)
  local ok, failure = xpcall(function()
    for index = 1, #sections do
      local start0 = paged.starts[index]
      local located, offset = Paged.locate(paged, start0)
      H.eq(located, index, ("row %d belongs to section %d"):format(start0, index))
      H.eq(offset, 0, "a section starts at its own offset zero")
    end
    -- The last row of the canvas belongs to the last section.
    local last = paged.list:row_count() - 1
    H.eq(Paged.locate(paged, last), #sections)
    H.eq(Paged.locate(paged, -1), nil, "a row before the canvas belongs to nothing")
  end, debug.traceback)
  Paged.dispose(paged)
  assert(ok, failure)
end

T["paged_ holds no persistent extmark, before or after being displayed"] =
  function()
    local paged, err = Paged.render(three_sections())
    assert(paged, err)
    local original = API.nvim_get_current_buf()
    local ok, failure = xpcall(function()
      H.eq(persistent_marks(paged.buffer), 0,
        "a freshly rendered paged canvas already carries marks")

      API.nvim_set_current_buf(paged.buffer)
      local window = API.nvim_get_current_win()
      API.nvim_win_set_cursor(window, { 1, 0 })
      assert(paged.projection:redraw())
      H.eq(persistent_marks(paged.buffer), 0,
        "displaying the canvas persisted a mark")

      -- Scroll somewhere else and redraw again: whatever the decoration
      -- provider drew for the first viewport must not have survived it.
      local total = paged.list:row_count()
      API.nvim_win_set_cursor(window, { math.floor(total / 2), 0 })
      API.nvim_win_call(window, function() vim.cmd("normal! zt") end)
      assert(paged.projection:redraw())
      H.eq(persistent_marks(paged.buffer), 0,
        "scrolling the canvas persisted a mark")

      H.eq(paged.projection:validate(), true)
    end, debug.traceback)
    if API.nvim_buf_is_valid(original) then
      pcall(API.nvim_set_current_buf, original)
    end
    Paged.dispose(paged)
    assert(ok, failure)
  end

T["paged_ colours the rows the eager canvas colours"] = function()
  local sections = three_sections()
  local paged, err = Paged.render(sections)
  assert(paged, err)
  local ok, failure = xpcall(function()
    local render = require("canvasdiff.canvas.format")
    for index, sec in ipairs(sections) do
      local expected = {}
      for _, mark in ipairs(render.section_hl(sec)) do
        expected[mark.row] = mark.group
      end
      local styles = paged.styles[index]

      -- The header row carries the full-width bar as well as its own group.
      H.eq(styles[0].line_hl_group, "CanvasDiffFileBar",
        "the file header lost its bar")
      H.eq(styles[0].hl_group, expected[0],
        "the file header lost its own group")

      for row, group in pairs(expected) do
        if row ~= 0 then
          H.eq(styles[row] and styles[row].hl_group, group, (
            "section %d row %d should be %s"
          ):format(index, row, group))
        end
      end
    end
  end, debug.traceback)
  Paged.dispose(paged)
  assert(ok, failure)
end

T["paged_ an empty review is one blank row, as the eager canvas is"] = function()
  local eager_state = canvas.open({}, {})
  local eager = canvas.logical(eager_state)
  local paged, err = Paged.render({})
  assert(paged, err)
  local ok, failure = xpcall(function()
    H.eq(paged.list:row_count(), eager.row_count(),
      "an empty paged canvas and an empty eager canvas differ in size")
    H.eq(Paged.locate(paged, 0), nil, "an empty canvas locates nothing")
  end, debug.traceback)
  Paged.dispose(paged)
  assert(ok, failure)
end

T["paged_ malformed construction is an ordinary error"] = function()
  H.eq(Paged.render(nil), nil, "a missing section list is refused")
  H.eq(Paged.render({}, "nope"), nil, "non-table options are refused")
  H.eq(Paged.render({}, { collapsed = "nope" }), nil,
    "a non-function collapsed predicate is refused")
  local _, err = Paged.render({}, { stale = 7 })
  assert(type(err) == "string" and err:find("function", 1, true), tostring(err))
end

T["paged_ disposal releases the projection and is idempotent"] = function()
  local paged, err = Paged.render(three_sections())
  assert(paged, err)
  local buffer = paged.buffer
  local projection = paged.projection
  assert(Paged.dispose(paged))
  H.eq(paged.projection, nil, "disposal kept the projection")
  assert(Paged.dispose(paged), "disposing twice must be harmless")
  assert(Paged.dispose(nil), "disposing nothing must be harmless")
  -- A disposed projection still validates, and that is the invariant: its
  -- validator checks that the disposal itself is consistent -- deregistered,
  -- finalized, holding no text and no leases -- rather than that the object
  -- is still usable.
  H.eq(projection:validate(), true,
    "a disposed projection did not validate its own disposal")
  H.eq(API.nvim_buf_is_valid(buffer), false,
    "disposal left the skeleton buffer behind")
end

return T
