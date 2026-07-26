local H = require("helpers")
local model = require("canvasdiff.diff")
local canvas = require("canvasdiff.canvas")

-- Big generated fixture: the headless window is ~24 rows tall, so sections
-- must be MUCH taller for "above/below viewport" cases to be real.
-- a.txt: 300 lines, every 10th line changed -> ~30 hunks, ~240 canvas rows.
local function bigtexts(edit_extra)
  local old, new = {}, {}
  for i = 1, 300 do
    old[i] = "a" .. i
    if i % 10 == 0 then
      new[#new + 1] = "A" .. i
      if edit_extra and i == 20 then
        new[#new + 1] = "EXTRA1"
        new[#new + 1] = "EXTRA2"
        new[#new + 1] = "EXTRA3"
      end
    else
      new[#new + 1] = "a" .. i
    end
  end
  return table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n"
end

local function two_sections(edit_extra)
  local aold, anew = bigtexts(edit_extra)
  return model.build({
    { path = "a.txt", old_text = aold, new_text = anew, status = "M" },
    { path = "b.txt", old_text = "9\n", new_text = "9\nplus\n", status = "M" },
  })
end

return {
  ["canvas: facade exports exactly the supported domain API"] = function()
    local names = vim.tbl_keys(canvas)
    table.sort(names)
    H.eq(names, {
      "format",
      "insert_section",
      "is_canvas_buf",
      "locate",
      "open",
      "project",
      "reconcile_sections",
      "render_all",
      "replace_section",
      "resync_visibility",
      "section_rows",
      "set_collapsed",
      "show",
    })

    local format_names = vim.tbl_keys(canvas.format)
    table.sort(format_names)
    H.eq(format_names, {
      "ensure_marker_hl",
      "escape_path",
      "ghost_lines",
      "glyphs",
      "marker_spans",
      "placeholder",
      "section_hl",
      "section_lines",
      "section_path",
      "stage_mark",
    })
  end,
  ["canvas: renders sections with anchors, locate works"] = function()
    local st = canvas.open(two_sections(), {})
    local s1, _ = canvas.section_rows(st, 1)
    local s2, e2 = canvas.section_rows(st, 2)
    H.eq(s1, 0)
    assert(s2 > 100 and e2 > s2, "a.txt section should be tall")
    local i, off = canvas.locate(st, s2)
    H.eq(i, 2); H.eq(off, 1)
    local i1, off1 = canvas.locate(st, 2)
    H.eq(i1, 1); H.eq(off1, 3)
  end,
  ["canvas: replace_section below viewport does not move view"] = function()
    local st = canvas.open(two_sections(), {})
    vim.api.nvim_win_call(st.win, function() vim.fn.winrestview({ topline = 1, lnum = 1 }) end)
    local before = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    local bigger = model.build_section("b.txt", "9\n", "9\nplus\nmore\nlines\n", "M")
    canvas.replace_section(st, 2, bigger)
    local after = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    H.eq(after.topline, before.topline)
    H.eq(after.lnum, before.lnum)
    H.eq(st.sections[2].adds, 3)
    -- anchors still consistent
    local s2 = select(1, canvas.section_rows(st, 2))
    H.eq(canvas.locate(st, s2), 2)
  end,
  ["canvas: replace_section above viewport keeps visible text still"] = function()
    local st = canvas.open(two_sections(), {})
    -- scroll deep into a.txt so plenty of section content sits above the viewport
    local _, e1 = canvas.section_rows(st, 1)
    local deep = e1 - 10  -- near the end of a.txt's tall section
    vim.api.nvim_win_call(st.win, function()
      vim.fn.winrestview({ topline = deep, lnum = deep })
    end)
    local first_text_before = vim.api.nvim_win_call(st.win, function()
      return vim.fn.getline(vim.fn.line("w0"))
    end)
    -- regenerate a.txt with 3 extra added lines near its TOP (above viewport)
    local aold, anew = bigtexts(true)
    local bigger = model.build_section("a.txt", aold, anew, "M")
    canvas.replace_section(st, 1, bigger)
    local first_text_after = vim.api.nvim_win_call(st.win, function()
      return vim.fn.getline(vim.fn.line("w0"))
    end)
    H.eq(first_text_after, first_text_before)
  end,
  ["canvas: replace_section poking into viewport bottom preserves top"] = function()
    local st = canvas.open(two_sections(), {})
    -- section2 (b.txt) starts a few rows below the current viewport top --
    -- the viewport top itself sits inside section1, untouched by the
    -- coming edit; section2 only pokes into the BOTTOM of the viewport.
    local s2 = select(1, canvas.section_rows(st, 2)) -- 0-based row
    local top0 = s2 - 5 -- 0-based: 5 rows before section2 starts
    local topline = top0 + 1 -- winrestview's topline field is 1-based
    vim.api.nvim_win_call(st.win, function()
      vim.fn.winrestview({ topline = topline, lnum = topline })
    end)
    local before = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    local first_text_before = vim.api.nvim_win_call(st.win, function()
      return vim.fn.getline(vim.fn.line("w0"))
    end)
    local bigger = model.build_section("b.txt", "9\n", "9\nplus\nmore\nlines\nhere\ntoo\n", "M")
    canvas.replace_section(st, 2, bigger)
    local after = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    local first_text_after = vim.api.nvim_win_call(st.win, function()
      return vim.fn.getline(vim.fn.line("w0"))
    end)
    H.eq(after.topline, before.topline)
    H.eq(first_text_after, first_text_before)
  end,
  ["canvas: delete section"] = function()
    local st = canvas.open(two_sections(), {})
    canvas.replace_section(st, 1, nil)
    H.eq(#st.sections, 1)
    H.eq(st.sections[1].path, "b.txt")
    H.eq(canvas.locate(st, 0), 1)
  end,
  ["canvas_insert keeps order, anchors, and rows consistent"] = function()
    local a = model.build_section("a.lua", "x\n", "x\ny\n", "M")
    local c = model.build_section("c.lua", "x\n", "x\nz\n", "M")
    local b = model.build_section("b.lua", "x\n", "x\nw\n", "M")
    local st = canvas.open({ a, c }, {})

    canvas.insert_section(st, 2, b)

    H.eq(#st.sections, 3)
    H.eq({ st.sections[1].path, st.sections[2].path, st.sections[3].path },
      { "a.lua", "b.lua", "c.lua" })
    -- rows are contiguous and non-overlapping, resolved live from anchors
    local prev_end = 0
    for i = 1, 3 do
      local srow, erow = canvas.section_rows(st, i)
      H.eq(srow, prev_end, "section " .. i .. " starts where previous ended")
      assert(erow > srow, "non-empty section")
      prev_end = erow
    end
    -- the inserted section's rendered lines are actually at its rows
    local srow = (canvas.section_rows(st, 2))
    local first = vim.api.nvim_buf_get_lines(st.buf, srow, srow + 1, false)[1]
    assert(first:find("b.lua", 1, true), "b.lua header at inserted rows, got: " .. first)
    -- EOF sentinel intact: locate on the last row maps into section 3
    local last_row0 = vim.api.nvim_buf_line_count(st.buf) - 1
    local li = (canvas.locate(st, last_row0))
    H.eq(li, 3)
  end,
  ["canvas_insert appends at EOF with i = n + 1"] = function()
    local a = model.build_section("a.lua", "x\n", "x\ny\n", "M")
    local d = model.build_section("d.lua", "x\n", "x\nq\n", "M")
    local st = canvas.open({ a }, {})
    canvas.insert_section(st, 2, d)
    H.eq(#st.sections, 2)
    H.eq(st.sections[2].path, "d.lua")
    local srow, erow = canvas.section_rows(st, 2)
    H.eq(erow, vim.api.nvim_buf_line_count(st.buf), "section 2 ends at EOF")
    assert(srow < erow)
  end,
  ["canvas_insert above viewport keeps visible text pinned"] = function()
    -- two big sections; scroll into the second, insert before it
    local big = {}
    for i = 1, 120 do big[i] = ("line %d"):format(i) end
    local old = table.concat(big, "\n") .. "\n"
    local new = old:gsub("line 60", "line 60 changed")
    local a = model.build_section("a.txt", old, new, "M")
    local z = model.build_section("z.txt", old, new, "M")
    local m = model.build_section("m.txt", old, new, "M")
    local st = canvas.open({ a, z }, {})

    -- scroll so the viewport sits inside section 2 (z.txt)
    local z_start = (canvas.section_rows(st, 2))
    vim.api.nvim_win_call(st.win, function()
      vim.fn.winrestview({ topline = z_start + 2, lnum = z_start + 2 })
    end)
    local before_top = vim.api.nvim_win_call(st.win, function()
      return vim.fn.getline(vim.fn.line("w0"))
    end)

    canvas.insert_section(st, 2, m) -- lands entirely above the viewport

    local after_top = vim.api.nvim_win_call(st.win, function()
      return vim.fn.getline(vim.fn.line("w0"))
    end)
    H.eq(after_top, before_top, "topmost visible line must not change")
  end,
  ["canvas_insert below viewport leaves the view untouched"] = function()
    local a = model.build_section("a.lua", "x\n", "x\ny\n", "M")
    local d = model.build_section("d.lua", "x\n", "x\nq\n", "M")
    local st = canvas.open({ a }, {})
    vim.api.nvim_win_call(st.win, function()
      vim.fn.winrestview({ topline = 1, lnum = 1 })
    end)
    local before = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    canvas.insert_section(st, 2, d)
    local after = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    H.eq(after.topline, before.topline)
    H.eq(after.lnum, before.lnum)
  end,
  ["canvas_reconcile replaces on every render or navigation identity field"] = function()
    local base = {
      path = "new.txt",
      old_path = "old.txt",
      old_rev = "rev-a",
      status = "R",
      staged = "R",
      unstaged = nil,
      old_text = "before\n",
      new_text = "after\n",
    }
    local cases = {
      { field = "old_path", value = "older.txt" },
      { field = "old_rev", value = "rev-b" },
      { field = "status", value = "M" },
      { field = "staged", value = "M" },
      { field = "unstaged", value = "M" },
      { field = "old_text", value = "different old\n" },
      { field = "new_text", value = "different new\n" },
    }

    for _, case in ipairs(cases) do
      local before_file = vim.deepcopy(base)
      local after_file = vim.deepcopy(base)
      after_file[case.field] = case.value
      local before = assert(model.build({ before_file }, 3)[1])
      local desired = assert(model.build({ after_file }, 3)[1])
      local st = canvas.open({ before }, {})
      local replaced = 0
      st.hooks = {
        on_section_replaced = function(path)
          H.eq(path, "new.txt")
          replaced = replaced + 1
        end,
      }

      local full = canvas.reconcile_sections(st, { desired })
      H.eq(full, false, case.field .. " must use the in-place reconcile path")
      H.eq(replaced, 1,
        case.field .. " changed with identical path and must replace the section")
      H.eq(st.sections[1][case.field], case.value)
    end
  end,
}
