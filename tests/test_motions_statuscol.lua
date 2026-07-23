local H = require("helpers")
local canvas = require("finding_myself.canvas")
local model = require("finding_myself.model")
local motions = require("finding_myself.motions")
local statuscol = require("finding_myself.statuscol")

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

T["motions_ ]h steps hunk headers across sections and skips collapsed"] = function()
  local st = canvas.open(three_sections(), {})
  canvas.set_collapsed(st, 2, true)

  local a_start = (canvas.section_rows(st, 1))
  -- Section 1's first hunk header is right after the file_hdr row.
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 })

  local c_start
  local prev_row = a_start
  for _ = 1, 20 do
    motions.goto_hunk(st, 1, 1)
    local row = vim.api.nvim_win_get_cursor(st.win)[1] - 1
    if not c_start then
      c_start = (canvas.section_rows(st, 3))
    end
    if row >= c_start then
      break
    end
    -- Must never land inside collapsed section 2's row range.
    local b_start, b_end = (canvas.section_rows(st, 2))
    assert(not (row >= b_start and row < b_end), "landed inside collapsed section 2")
    assert(row > prev_row, "hunk motion must move forward")
    prev_row = row
  end
  local final_row = vim.api.nvim_win_get_cursor(st.win)[1] - 1
  H.eq(final_row >= c_start, true, "eventually reached section 3's first hunk")
end

T["motions_ count is honored"] = function()
  local st = canvas.open(three_sections(), {})
  local a_start = (canvas.section_rows(st, 1))
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 })

  motions.goto_file(st, 1, 2) -- explicit count param, skip section 2 -> land on 3
  local c_start = (canvas.section_rows(st, 3))
  H.eq(vim.api.nvim_win_get_cursor(st.win), { c_start + 1, 0 })
end

T["statuscol_ text maps rows to new-file numbers"] = function()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_set_current_win(st.win)
  statuscol.attach(st)

  -- file_hdr row (section start) -> 5 spaces.
  local a_start = (canvas.section_rows(st, 1))
  H.eq(statuscol.text_for(a_start + 1), "     ")

  -- Find a ctx/add row and check it maps to its new_lnum.
  local _, offset = canvas.locate(st, a_start + 2) -- hunk_hdr is offset 2; entries after that
  local entry
  local row0 = a_start + 2
  while true do
    local i, off = canvas.locate(st, row0)
    entry = st.sections[i].entries[off]
    if entry.kind ~= "hunk_hdr" and entry.kind ~= "file_hdr" then
      break
    end
    row0 = row0 + 1
  end
  H.eq(entry.new_lnum ~= nil, true, "found a row with a new_lnum")
  H.eq(statuscol.text_for(row0 + 1), ("%4d "):format(entry.new_lnum))

  statuscol.detach()
end

T["statuscol_ never leaks into a foreign buffer"] = function()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_set_current_win(st.win)
  statuscol.attach(st)

  local other_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(st.win, other_buf)

  H.eq(statuscol.text_for(1), "", "text_for returns empty for a foreign current buffer")

  vim.wait(300, function()
    return vim.api.nvim_get_option_value("statuscolumn", { win = st.win }) == ""
  end)
  H.eq(vim.api.nvim_get_option_value("statuscolumn", { win = st.win }), "",
    "statuscolumn cleared once the canvas left the window")

  vim.api.nvim_win_set_buf(st.win, st.buf)
  vim.wait(300, function()
    return vim.api.nvim_get_option_value("statuscolumn", { win = st.win }) ~= ""
  end)
  H.eq(vim.api.nvim_get_option_value("statuscolumn", { win = st.win }),
    "%!v:lua.require'finding_myself.statuscol'.text()",
    "statuscolumn restored once the canvas is showing again")

  statuscol.detach()
  pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
end

return T
