local H = require("helpers")
local model = require("finding_myself.model")
local canvas = require("finding_myself.canvas")

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
}
