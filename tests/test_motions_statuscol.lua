local H = require("helpers")
local canvas = require("galley.canvas")
local model = require("galley.model")
local motions = require("galley.motions")
local statuscol = require("galley.statuscol")
local virt = require("galley.virt")
local config = require("galley.config")
local sidebar = require("galley.sidebar")

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

-- --- navigation steps over what you set aside -----------------------------

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

T["motions_ ]f [f step over a folded-away section"] = function()
  virt.detach()
  local st = canvas.open(three_sections(), {})
  set_folds(st, { ["b/"] = true })

  put_cursor_in(st, 1, 3)
  motions.goto_file(st, 1, 1)
  H.eq(cursor_section(st), 3, "]f skipped the folded-away middle section")

  motions.goto_file(st, -1, 1)
  H.eq(cursor_section(st), 1, "[f skipped it going back too")
  set_folds(st, {})
end

-- Guard: passes before and after. It exists to fail if someone swaps the
-- navigation predicate for the rendering one. The virtualizer collapsing a
-- far-away section is bookkeeping, not the user putting it away, so navigation
-- must still be able to land there.
T["motions_ ]f stops at an auto-collapsed section"] = function()
  virt.detach()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_win_call(st.win, function() vim.fn.winrestview({ topline = 1, lnum = 1 }) end)
  virt.apply(st, { enabled = true, max_files = 1, max_lines = 1000000, margin = 0, max_expanded = 1 })
  local auto = virt.auto_set()
  assert(auto["b/two.txt"], "sanity: virt auto-collapsed section 2")

  put_cursor_in(st, 1, 0)
  motions.goto_file(st, 1, 1)
  H.eq(cursor_section(st), 2, "]f lands on the auto-collapsed section, not past it")
  virt.detach()
end

T["motions_ ]f [f from a set-aside placeholder move only in the direction of travel"] = function()
  virt.detach()
  -- TWO sections under a/, so the nearest navigable section forwards is 3 --
  -- not merely the next index, which would pass without any skipping.
  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("a/two.txt", "b"),
    big_section("b/three.txt", "c"),
  }, {})
  set_folds(st, { ["a/"] = true })

  put_cursor_in(st, 1, 0) -- on a/one.txt's placeholder row
  motions.goto_file(st, -1, 1)
  H.eq(cursor_section(st), 1, "nothing navigable backwards: never reverse, never move")

  motions.goto_file(st, 1, 1)
  H.eq(cursor_section(st), 3, "forwards it reaches the nearest navigable section")
  set_folds(st, {})
end

T["motions_ ]f [f do not move when nothing is navigable"] = function()
  virt.detach()
  local st = canvas.open(three_sections(), {})
  set_folds(st, { ["a/"] = true, ["b/"] = true, ["c/"] = true })

  put_cursor_in(st, 2, 0)
  local before = vim.api.nvim_win_get_cursor(st.win)
  motions.goto_file(st, 1, 1)
  H.eq(vim.api.nvim_win_get_cursor(st.win), before, "]f is a no-op with everything set aside")
  motions.goto_file(st, -1, 1)
  H.eq(vim.api.nvim_win_get_cursor(st.win), before, "[f too")
  set_folds(st, {})
end

T["motions_ ]f counts only navigable sections"] = function()
  virt.detach()
  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
    big_section("d/four.txt", "d"),
  }, {})
  set_folds(st, { ["b/"] = true })

  put_cursor_in(st, 1, 0)
  motions.goto_file(st, 1, 2)
  H.eq(cursor_section(st), 4, "2]f counted c/ and d/, not the folded-away b/")
  set_folds(st, {})
end

T["motions_ navigate.skip_set_aside = false restores plain index stepping"] = function()
  virt.detach()
  local st = canvas.open(three_sections(), {})
  set_folds(st, { ["b/"] = true })

  config.setup({ navigate = { skip_set_aside = false } })
  local ok, err = pcall(function()
    put_cursor_in(st, 1, 3)
    motions.goto_file(st, 1, 1)
    H.eq(cursor_section(st), 2, "with the gate off, ]f lands on the placeholder")

    -- cycle reads the TOPLINE, not the cursor, so park it deliberately.
    local s1 = (canvas.section_rows(st, 1))
    vim.api.nvim_win_call(st.win, function()
      vim.fn.winrestview({ topline = s1 + 1, lnum = s1 + 1 })
    end)
    sidebar.cycle(st, 1)
    local top0 = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") - 1 end)
    H.eq((canvas.locate(st, top0)), 2, "and cycle steps by index too")
  end)
  config.setup({})
  set_folds(st, {})
  assert(ok, err)
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
    -- Must never land inside collapsed section 2's row range. (The parens
    -- around this call used to truncate it to one value, leaving b_end nil and
    -- the assertion below unable to fire at all.)
    local b_start, b_end = canvas.section_rows(st, 2)
    assert(not (row >= b_start and row < b_end), "landed inside collapsed section 2")
    assert(row > prev_row, "hunk motion must move forward")
    prev_row = row
  end
  local final_row = vim.api.nvim_win_get_cursor(st.win)[1] - 1
  H.eq(final_row >= c_start, true, "eventually reached section 3's first hunk")
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

T["statuscol_ text maps rows to new-file numbers"] = function()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_set_current_win(st.win)
  statuscol.attach(st)

  -- Production sets g:statusline_winid to the window being drawn before
  -- evaluating the `%!` statuscolumn expression; simulate that eval context.
  vim.g.statusline_winid = st.win

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

  vim.g.statusline_winid = nil
  statuscol.detach()
end

T["statuscol_ renders for the drawn window even while focus is elsewhere"] = function()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_set_current_win(st.win)
  statuscol.attach(st)

  local a_start = (canvas.section_rows(st, 1))
  local row0 = a_start + 2
  local entry
  while true do
    local i, off = canvas.locate(st, row0)
    entry = st.sections[i].entries[off]
    if entry.kind ~= "hunk_hdr" and entry.kind ~= "file_hdr" then
      break
    end
    row0 = row0 + 1
  end
  assert(entry.new_lnum ~= nil, "sanity: found a row with a new_lnum")

  -- Focus moves to another window entirely; the canvas window (st.win) is
  -- still SHOWING st.buf, just not the current one.
  local other_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
    relative = "editor", row = 0, col = 0, width = 20, height = 5,
  })
  assert(vim.api.nvim_get_current_win() ~= st.win)
  assert(vim.api.nvim_get_current_buf() ~= st.buf)

  -- Simulate the eval context production runs under: Neovim sets
  -- g:statusline_winid to the window being DRAWN before invoking the `%!`
  -- statuscolumn expression.
  vim.g.statusline_winid = st.win
  local text = statuscol.text_for(row0 + 1)
  vim.g.statusline_winid = nil

  H.eq(text, ("%4d "):format(entry.new_lnum),
    "statuscolumn for the canvas window's own row renders even while focus is in another window")

  vim.api.nvim_win_close(other_win, true)
  statuscol.detach()
end

T["statuscol_ never leaks into a foreign buffer"] = function()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_set_current_win(st.win)
  statuscol.attach(st)

  local other_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(st.win, other_buf)

  vim.g.statusline_winid = st.win
  H.eq(statuscol.text_for(1), "", "text_for returns empty once the drawn window shows a foreign buffer")
  vim.g.statusline_winid = nil

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
    "%!v:lua.require'galley.statuscol'.text()",
    "statuscolumn restored once the canvas is showing again")

  statuscol.detach()
  pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
end

return T
