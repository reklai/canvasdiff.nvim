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

local function ghost_marks(buffer)
  return #API.nvim_buf_get_extmarks(buffer, Paged.GHOST_NS, 0, -1, {})
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

T["paged_ ghosts render for the visible range and stay bounded by it"] =
  function()
    -- A deleted line has no row of its own on either canvas: it is drawn as a
    -- virtual line above the row that replaced it. On a paged canvas that
    -- cannot be ephemeral -- measured: an ephemeral mark silently ignores
    -- virt_lines -- so ghosts are persistent marks for the VISIBLE range, and
    -- what matters is that their number tracks the window rather than the
    -- canvas.
    local sections = { section("deep.txt", "d", 400) }
    local paged, err = Paged.render(sections)
    assert(paged, err)
    local original = API.nvim_get_current_buf()
    local ok, failure = xpcall(function()
      API.nvim_set_current_buf(paged.buffer)
      local window = API.nvim_get_current_win()
      API.nvim_win_set_cursor(window, { 1, 0 })
      API.nvim_win_call(window, function() vim.cmd("normal! zt") end)
      assert(paged.projection:redraw())

      local placed = assert(Paged.refresh_ghosts(paged, window))
      local height = API.nvim_win_get_height(window)
      local total = paged.list:row_count()
      assert(total > height * 4,
        "sanity: the canvas must be much taller than the window")
      H.eq(ghost_marks(paged.buffer), placed,
        "refresh_ghosts reported a different count than it placed")
      assert(placed <= height + 1, (
        "%d ghosts for a %d-row window is not bounded by the viewport"
      ):format(placed, height))

      -- Scrolling rebuilds the set rather than adding to it.
      API.nvim_win_set_cursor(window, { math.floor(total / 2), 0 })
      API.nvim_win_call(window, function() vim.cmd("normal! zt") end)
      assert(paged.projection:redraw())
      local moved = assert(Paged.refresh_ghosts(paged, window))
      H.eq(ghost_marks(paged.buffer), moved,
        "scrolling left stale ghosts behind")
      assert(moved <= height + 1,
        "the ghost set grew as the canvas was scrolled")

      -- Every ghost sits inside the range the placement was computed from.
      -- It is measured before the refresh on purpose: placing virtual lines
      -- occupies screen rows, so fewer logical rows fit afterwards, and the
      -- set is deliberately a slight superset of what ends up visible.
      local before = API.nvim_win_call(window, function()
        return { vim.fn.line("w0") - 1, vim.fn.line("w$") - 1 }
      end)
      assert(Paged.refresh_ghosts(paged, window))
      for _, mark in ipairs(API.nvim_buf_get_extmarks(
        paged.buffer, Paged.GHOST_NS, 0, -1, {})) do
        local row0 = mark[2]
        assert(row0 >= before[1] and row0 <= before[2], (
          "a ghost was placed at row %d, outside the range %d..%d it was computed from"
        ):format(row0, before[1], before[2]))
      end
    end, debug.traceback)
    if API.nvim_buf_is_valid(original) then
      pcall(API.nvim_set_current_buf, original)
    end
    Paged.dispose(paged)
    assert(ok, failure)
  end

T["paged_ ghosts are cleared for a window that no longer shows the canvas"] =
  function()
    local paged, err = Paged.render({ section("deep.txt", "d", 200) })
    assert(paged, err)
    local original = API.nvim_get_current_buf()
    local ok, failure = xpcall(function()
      API.nvim_set_current_buf(paged.buffer)
      local window = API.nvim_get_current_win()
      assert(paged.projection:redraw())
      assert(Paged.refresh_ghosts(paged, window))

      -- Point the window somewhere else: the canvas is no longer displayed,
      -- which is an ordinary teardown state, not a fault.
      local other = API.nvim_create_buf(false, true)
      API.nvim_win_set_buf(window, other)
      H.eq(Paged.refresh_ghosts(paged, window), 0,
        "ghosts survived the canvas leaving the window")
      H.eq(ghost_marks(paged.buffer), 0)

      H.eq(Paged.refresh_ghosts(paged, -1), 0, "an invalid window is not a fault")
      H.eq(Paged.refresh_ghosts(nil, window), nil, "a missing canvas is refused")
    end, debug.traceback)
    if API.nvim_buf_is_valid(original) then
      pcall(API.nvim_set_current_buf, original)
    end
    Paged.dispose(paged)
    assert(ok, failure)
  end

T["paged_ section_rows agrees with the eager canvas for every section"] =
  function()
    local sections = three_sections()
    local eager_state = canvas.open(sections, {})
    local paged, err = Paged.render(sections)
    assert(paged, err)
    local ok, failure = xpcall(function()
      for index = 1, #sections do
        local eager_start, eager_end = canvas.section_rows(eager_state, index)
        local start0, end0 = Paged.section_rows(paged, index)
        H.eq(start0, eager_start, ("section %d starts elsewhere"):format(index))
        H.eq(end0, eager_end, ("section %d ends elsewhere"):format(index))
      end
      H.eq(Paged.section_rows(paged, #sections + 1), nil,
        "a section that does not exist has no rows")
      H.eq(Paged.section_rows(paged, "one"), nil,
        "a non-numeric index has no rows")
    end, debug.traceback)
    Paged.dispose(paged)
    assert(ok, failure)
  end

T["paged_ collapsing splices only that section and keeps the rest exact"] =
  function()
    -- The point of paging: folding one file must cost that file's rows, not a
    -- re-render. Correctness is checked against an eager canvas told to do the
    -- same thing.
    local sections = three_sections()
    local paged, err = Paged.render(sections)
    assert(paged, err)
    local ok, failure = xpcall(function()
      local before = assert(paged.list:rows(0, paged.list:row_count()))
      local start0, end0 = Paged.section_rows(paged, 2)

      H.eq(Paged.set_collapsed(paged, 2, true), true)

      local eager_state = canvas.open(three_sections(), {})
      canvas.set_collapsed(eager_state, 2, true)
      local eager = canvas.logical(eager_state)
      local total = eager.row_count()
      H.eq(paged.list:row_count(), total, "collapsing produced a different size")
      H.eq(assert(paged.list:rows(0, total)), assert(eager.rows(0, total)),
        "a collapsed paged canvas disagrees with the eager one")

      -- The rows before the spliced section are untouched, byte for byte.
      H.eq(assert(paged.list:rows(0, start0)),
        vim.list_slice(before, 1, start0),
        "collapsing disturbed the sections above it")

      -- And the starts moved by exactly the difference.
      local new_start = Paged.section_rows(paged, 3)
      H.eq(new_start, start0 + 1,
        "the section after a collapse did not move to where its rows are")

      -- Expanding again returns exactly what was there.
      H.eq(Paged.set_collapsed(paged, 2, false), true)
      H.eq(assert(paged.list:rows(0, paged.list:row_count())), before,
        "expanding did not restore the original text")
      local restored_start, restored_end = Paged.section_rows(paged, 2)
      H.eq(restored_start, start0)
      H.eq(restored_end, end0)

      -- Asking for the state it is already in is not a change and not an error.
      H.eq(Paged.set_collapsed(paged, 2, false), false)
      H.eq(paged.projection:validate(), true)
    end, debug.traceback)
    Paged.dispose(paged)
    assert(ok, failure)
  end

T["paged_ collapsing a section that does not exist is an ordinary error"] =
  function()
    local paged, err = Paged.render(three_sections())
    assert(paged, err)
    local ok, failure = xpcall(function()
      local changed, message = Paged.set_collapsed(paged, 99, true)
      H.eq(changed, nil)
      assert(type(message) == "string" and message ~= "", tostring(message))
      H.eq(Paged.set_collapsed(nil, 1, true), nil, "a missing canvas is refused")
    end, debug.traceback)
    Paged.dispose(paged)
    assert(ok, failure)
  end

T["paged_ the canvas API dispatches to the store when the state is paged"] =
  function()
    -- The switchover is a flag, not a rewrite: with `state.paged` set, the
    -- same facade calls the display stack already makes go to the store.
    local sections = three_sections()
    local eager_state = canvas.open(sections, {})
    local paged, err = Paged.render(sections)
    assert(paged, err)
    local ok, failure = xpcall(function()
      for index = 1, #sections do
        local eager_start, eager_end = canvas.section_rows(eager_state, index)
        local start0, end0 = canvas.section_rows(paged.state, index)
        H.eq(start0, eager_start, ("section %d starts elsewhere"):format(index))
        H.eq(end0, eager_end, ("section %d ends elsewhere"):format(index))
      end

      local start2 = canvas.section_rows(paged.state, 2)
      local index, offset = canvas.locate(paged.state, start2)
      H.eq(index, 2, "locate through the facade found the wrong section")
      H.eq(offset, 0)
      H.eq(canvas.locate(paged.state, 0), 1)

      -- And folding through the facade splices the store.
      canvas.set_collapsed(paged.state, 2, true)
      H.eq(paged.collapsed[2], true, "the facade did not fold the paged section")
      H.eq(paged.state.collapsed[sections[2].path], "user",
        "the facade did not record the fold intent")

      local folded = canvas.open(three_sections(), {})
      canvas.set_collapsed(folded, 2, true)
      local eager = canvas.logical(folded)
      local total = eager.row_count()
      H.eq(paged.list:row_count(), total)
      H.eq(assert(paged.list:rows(0, total)), assert(eager.rows(0, total)),
        "folding through the facade disagreed with the eager canvas")
    end, debug.traceback)
    Paged.dispose(paged)
    assert(ok, failure)
  end

T["paged_ replacing a section splices only its rows"] = function()
  local sections = three_sections()
  local paged, err = Paged.render(sections)
  assert(paged, err)
  local ok, failure = xpcall(function()
    local before = assert(paged.list:rows(0, paged.list:row_count()))
    local start0 = Paged.section_rows(paged, 2)

    local bigger = section("b/two.txt", "b", 60)
    H.eq(Paged.replace_section(paged, 2, bigger), true)

    local eager_state = canvas.open(three_sections(), {})
    canvas.replace_section(eager_state, 2, bigger)
    local eager = canvas.logical(eager_state)
    local total = eager.row_count()
    H.eq(paged.list:row_count(), total, "the replacement produced a different size")
    H.eq(assert(paged.list:rows(0, total)), assert(eager.rows(0, total)),
      "a replaced paged section disagrees with the eager canvas")

    -- Everything above the replaced section is untouched.
    H.eq(assert(paged.list:rows(0, start0)), vim.list_slice(before, 1, start0),
      "replacing disturbed the sections above it")
    H.eq(paged.sections[2], bigger, "the section list was not updated")
    H.eq(paged.state.sections[2], bigger, "the state's section list went stale")
    H.eq(paged.projection:validate(), true)
  end, debug.traceback)
  Paged.dispose(paged)
  assert(ok, failure)
end

T["paged_ deleting a section removes it and closes the gap"] = function()
  local sections = three_sections()
  local paged, err = Paged.render(sections)
  assert(paged, err)
  local ok, failure = xpcall(function()
    H.eq(Paged.replace_section(paged, 1, nil), true)

    local eager_state = canvas.open(three_sections(), {})
    canvas.replace_section(eager_state, 1, nil)
    local eager = canvas.logical(eager_state)
    local total = eager.row_count()
    H.eq(#paged.sections, 2, "the deleted section is still in the list")
    H.eq(paged.sections[1].path, "b/two.txt")
    H.eq(paged.list:row_count(), total, "deletion produced a different size")
    H.eq(assert(paged.list:rows(0, total)), assert(eager.rows(0, total)),
      "a deletion disagrees with the eager canvas")
    H.eq(Paged.section_rows(paged, 1), 0,
      "the section that moved up did not move to row zero")
    H.eq(canvas.locate(paged.state, 0), 1)
  end, debug.traceback)
  Paged.dispose(paged)
  assert(ok, failure)
end

T["paged_ deleting the last section leaves a canvas that still exists"] =
  function()
    local paged, err = Paged.render({ section("only.txt", "o", 20) })
    assert(paged, err)
    local ok, failure = xpcall(function()
      H.eq(Paged.replace_section(paged, 1, nil), true)
      -- The eager canvas cannot have a zero-line buffer either.
      H.eq(paged.list:row_count(), 1, "the canvas vanished entirely")
      H.eq(paged.list:row(0), "")
      H.eq(paged.projection:validate(), true)
    end, debug.traceback)
    Paged.dispose(paged)
    assert(ok, failure)
  end

T["paged_ replacing a section that does not exist is an ordinary error"] =
  function()
    local paged, err = Paged.render(three_sections())
    assert(paged, err)
    local ok, failure = xpcall(function()
      local changed, message = Paged.replace_section(paged, 99, nil)
      H.eq(changed, nil)
      assert(type(message) == "string" and message ~= "", tostring(message))
      H.eq(Paged.replace_section(nil, 1, nil), nil, "a missing canvas is refused")
    end, debug.traceback)
    Paged.dispose(paged)
    assert(ok, failure)
  end

T["paged_ search finds text that the buffer does not contain"] = function()
  -- The gap this closes, measured: on a paged canvas the buffer holds one
  -- BLANK line per logical row, so Neovim's own `/` matches nothing on a
  -- canvas that plainly contains the text.
  local sections = { section("f.txt", "alpha", 300) }
  local paged, err = Paged.render(sections)
  assert(paged, err)
  local ok, failure = xpcall(function()
    local total = paged.list:row_count()
    local rows = assert(paged.list:rows(0, total))
    local needle
    for index, row in ipairs(rows) do
      if row:find("changed", 1, true) then
        needle = index - 1
        break
      end
    end
    assert(needle, "sanity: the fixture must contain a changed line")

    -- Neovim itself cannot find it, because the buffer line really is blank.
    H.eq(API.nvim_buf_get_lines(paged.buffer, needle, needle + 1, false)[1], "",
      "the skeleton is not blank, so this test proves nothing")

    H.eq(Paged.search(paged, "changed"), needle,
      "the paged canvas could not find its own text")

    -- Searching from the match moves on to the next one, and wraps.
    local next_match = Paged.search(paged, "changed", { from0 = needle })
    assert(next_match and next_match > needle, "search did not advance")
    local wrapped = Paged.search(paged, "changed", { from0 = total - 1 })
    assert(wrapped ~= nil and wrapped < total, "search did not wrap")

    -- Backwards too.
    local back = Paged.search(paged, "changed", {
      from0 = next_match, backward = true,
    })
    H.eq(back, needle, "backward search found the wrong row")

    -- A pattern that matches nothing terminates rather than looping.
    H.eq(Paged.search(paged, "ABSENT_NEEDLE_XYZ"), nil)
  end, debug.traceback)
  Paged.dispose(paged)
  assert(ok, failure)
end

T["paged_ search refuses what it cannot search"] = function()
  local paged, err = Paged.render(three_sections())
  assert(paged, err)
  local ok, failure = xpcall(function()
    H.eq(Paged.search(paged, ""), nil, "an empty pattern is refused")
    H.eq(Paged.search(paged, 7), nil, "a non-string pattern is refused")
    H.eq(Paged.search(nil, "x"), nil, "a missing canvas is refused")
    local found, message = Paged.search(paged, "x", { from0 = 1.5 })
    H.eq(found, nil)
    assert(type(message) == "string" and message ~= "", tostring(message))
    -- An unmatchable-but-valid pattern is simply not found, not an error.
    local absent, absent_err = Paged.search(paged, "ZZZ_NOT_HERE")
    H.eq(absent, nil)
    H.eq(absent_err, nil)
  end, debug.traceback)
  Paged.dispose(paged)
  assert(ok, failure)
end

T["paged_ yank puts real text in the register, not blank lines"] = function()
  local paged, err = Paged.render(three_sections())
  assert(paged, err)
  local ok, failure = xpcall(function()
    local total = paged.list:row_count()
    local text = assert(Paged.yank(paged, 0, total, { register = "z" }))
    H.eq(vim.fn.getreg("z"), text, "the register did not receive the export")
    H.eq(vim.fn.getregtype("z"), "V", "a range of canvas rows must be linewise")

    local rows = assert(paged.list:rows(0, total))
    H.eq(text, table.concat(rows, "\n") .. "\n",
      "the yanked text is not the canvas text")
    assert(#text > total,
      "the yank produced roughly one byte per row, which means blank lines")

    -- A partial range yanks exactly that range.
    local part = assert(Paged.yank(paged, 2, 3, { register = "z" }))
    H.eq(part, table.concat(vim.list_slice(rows, 3, 5), "\n") .. "\n")
  end, debug.traceback)
  Paged.dispose(paged)
  assert(ok, failure)
end

T["paged_ yank refuses a bad range or register"] = function()
  local paged, err = Paged.render(three_sections())
  assert(paged, err)
  local ok, failure = xpcall(function()
    H.eq(Paged.yank(paged, 0, paged.list:row_count() + 1), nil,
      "yanking past the end is refused")
    H.eq(Paged.yank(paged, -1, 1), nil, "a negative start is refused")
    H.eq(Paged.yank(paged, 0, 1, { register = "toolong" }), nil,
      "a multi-character register is refused")
    H.eq(Paged.yank(nil, 0, 1), nil, "a missing canvas is refused")
  end, debug.traceback)
  Paged.dispose(paged)
  assert(ok, failure)
end

T["paged_ open_paged produces a state the eager code path drives"] = function()
  -- The switchover in one test: build a paged review through the canvas
  -- facade, then drive it with the SAME calls the eager path uses, and check
  -- every answer against an eager canvas told to do the same thing.
  local sections = three_sections()
  local original = API.nvim_get_current_buf()
  local state, err = canvas.open_paged(sections, {})
  assert(state, err)
  local ok, failure = xpcall(function()
    H.eq(state.paged ~= nil, true, "open_paged did not produce a paged state")
    H.eq(API.nvim_buf_is_valid(state.buf), true)
    H.eq(API.nvim_win_get_buf(state.win), state.buf,
      "the paged canvas is not in its window")
    H.eq(#state.anchor_ids, 0, "a paged canvas has nothing to anchor")

    local eager = canvas.open(three_sections(), {})
    local function agrees(label)
      local mine = canvas.logical(state)
      local theirs = canvas.logical(eager)
      H.eq(mine.row_count(), theirs.row_count(), label .. ": row counts")
      local total = theirs.row_count()
      H.eq(assert(mine.rows(0, total)), assert(theirs.rows(0, total)),
        label .. ": text")
      for index = 1, #state.sections do
        local a, b = canvas.section_rows(state, index)
        local c, d = canvas.section_rows(eager, index)
        H.eq({ a, b }, { c, d }, label .. ": section " .. index .. " rows")
      end
    end
    agrees("as opened")

    canvas.set_collapsed(state, 2, true)
    canvas.set_collapsed(eager, 2, true)
    agrees("after collapsing")

    canvas.set_collapsed(state, 2, false)
    canvas.set_collapsed(eager, 2, false)
    agrees("after expanding again")

    -- reconcile_sections is built entirely on render_all, replace_section and
    -- insert_section, so it comes for free once those dispatch -- which is
    -- exactly the claim being checked here.
    local desired = {
      section("a/one.txt", "a", 25),
      section("b/two.txt", "b"),
      section("d/four.txt", "d", 18),
    }
    canvas.reconcile_sections(state, desired)
    canvas.reconcile_sections(eager, vim.deepcopy(desired))
    agrees("after reconciling a change, a deletion and an insertion")
    H.eq(#state.sections, 3)
    H.eq(state.sections[3].path, "d/four.txt")

    canvas.render_all(state, three_sections())
    canvas.render_all(eager, three_sections())
    agrees("after a full re-render")

    -- The invariant, through the production path.
    H.eq(persistent_marks(state.buf), 0,
      "driving the paged canvas through the facade persisted a mark")
  end, debug.traceback)
  canvas.dispose(state)
  if API.nvim_buf_is_valid(original) then
    pcall(API.nvim_set_current_buf, original)
  end
  assert(ok, failure)
end

T["paged_ dispose releases the store and is safe on an eager state"] = function()
  local state = assert(canvas.open_paged(three_sections(), {}))
  local buffer = state.buf
  H.eq(canvas.dispose(state), true)
  H.eq(state.paged, nil, "dispose kept the store")
  H.eq(API.nvim_buf_is_valid(buffer), false, "dispose left the skeleton behind")
  H.eq(canvas.dispose(state), true, "disposing twice must be harmless")
  H.eq(canvas.dispose(canvas.open(three_sections(), {})), true,
    "disposing an eager canvas must be harmless")
end

T["paged_ the store gets a compactor that activity defers"] = function()
  local paged, err = Paged.render(three_sections())
  assert(paged, err)
  local ok, failure = xpcall(function()
    assert(paged.scheduler, "a paged canvas has no compactor")
    local stats = paged.scheduler:stats()
    assert(stats, "the compactor has no state")
    H.eq(stats.disposed, false)

    -- Touching is what a user scrolling does, and it must be accepted by both
    -- kinds of canvas so no activity hook has to know which it has.
    H.eq(Paged.touch(paged), true)
    H.eq(Paged.touch(nil), true, "touching a canvas with no store is harmless")
    H.eq(canvas.touch(paged.state), true)
    H.eq(canvas.touch(canvas.open(three_sections(), {})), true,
      "touching an eager canvas is harmless")
  end, debug.traceback)
  Paged.dispose(paged)
  assert(ok, failure)
end

T["paged_ disposal takes the compactor with the projection"] = function()
  local paged, err = Paged.render(three_sections())
  assert(paged, err)
  local scheduler = paged.scheduler
  assert(Paged.dispose(paged))
  H.eq(paged.scheduler, nil, "disposal kept the compactor")
  local stats = scheduler:stats()
  assert(stats and stats.disposed,
    "the compactor outlived the canvas it belonged to")
end

return T
