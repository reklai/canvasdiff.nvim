local H = require("helpers")
local model = require("galley.model")
local scrollbar = require("galley.scrollbar")
local canvas = require("galley.canvas")

local T = {}

T["scroll_kinds flattens sections in render order"] = function()
  -- one modified line, context 3. The del is no longer a row -- it rides on the add as
  -- a ghost -- so that row reports "mod", which the density pass counts as add AND del.
  -- Without that the minimap would lose every trace of deletion.
  local s = model.build_section("a.txt",
    "l1\nl2\nl3\nl4\nl5\n", "l1\nl2x\nl3\nl4\nl5\n", "M")
  local kinds = scrollbar.line_kinds({ s, s })
  H.eq(#kinds, 14)
  H.eq(vim.list_slice(kinds, 1, 7),
    { "hdr", "ctx", "ctx", "mod", "ctx", "ctx", "ctx" })
  H.eq(kinds[8], "hdr")
end

T["scroll_column buckets density and file boundaries"] = function()
  -- 40 lines, height 4: buckets of 10
  local kinds = {}
  for i = 1, 40 do kinds[i] = "ctx" end
  kinds[1] = "hdr"        -- bucket 1: file boundary wins
  kinds[15] = "add"       -- bucket 2: adds only
  kinds[25] = "del"       -- bucket 3: dels only
  kinds[35] = "add"
  kinds[36] = "del"       -- bucket 4: mixed
  local cells = scrollbar.column(kinds, 4, 100, 100) -- viewport far away: no thumb
  H.eq(#cells, 4)
  H.eq({ cells[1].char, cells[1].hl }, { "─", "GalleyScrollFile" })
  H.eq({ cells[2].char, cells[2].hl }, { "│", "GalleyScrollAdd" })
  H.eq({ cells[3].char, cells[3].hl }, { "│", "GalleyScrollDel" })
  H.eq({ cells[4].char, cells[4].hl }, { "│", "GalleyScrollChanged" })
  for r = 1, 4 do H.eq(cells[r].thumb, false) end
end

T["scroll_column blank buckets render empty"] = function()
  local kinds = {}
  for i = 1, 20 do kinds[i] = "ctx" end
  local cells = scrollbar.column(kinds, 2, 100, 100)
  H.eq(cells[1], { char = " ", hl = nil, thumb = false })
  H.eq(cells[2], { char = " ", hl = nil, thumb = false })
end

T["scroll_column thumb covers viewport-intersecting rows only"] = function()
  local kinds = {}
  for i = 1, 100 do kinds[i] = "ctx" end
  -- height 10: row r covers lines [(r-1)*10, r*10); viewport lines 35..54
  local cells = scrollbar.column(kinds, 10, 35, 54)
  local thumbs = {}
  for r = 1, 10 do thumbs[r] = cells[r].thumb end
  H.eq(thumbs, { false, false, false, true, true, true, false, false, false, false })
end

T["scroll_column degenerate inputs are safe"] = function()
  H.eq(scrollbar.column({}, 0, 0, 0), {})
  local cells = scrollbar.column({}, 3, 0, 10)
  H.eq(#cells, 3)
  for r = 1, 3 do
    H.eq(cells[r], { char = " ", hl = nil, thumb = false })
  end
  -- fewer lines than rows: line 1 lands in a well-defined bucket, no crash
  local one = scrollbar.column({ "add" }, 4, 0, 0)
  H.eq(#one, 4)
end

T["scroll_column empty buckets never claim the thumb"] = function()
  -- n=2, height=5: buckets r1=[0,0) r2=[0,0) r3=[0,1) r4=[1,1) r5=[1,2);
  -- viewport [0,1] covers both lines; only the NON-empty buckets r3/r5 thumb
  local cells = scrollbar.column({ "ctx", "ctx" }, 5, 0, 1)
  local thumbs = {}
  for r = 1, 5 do thumbs[r] = cells[r].thumb end
  H.eq(thumbs, { false, false, true, false, true })
end

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

local function big_section(path, tag)
  local old = bigtext(60, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 10, 60, 10 do lines[i] = lines[i] .. " changed" end
  return model.build_section(path, old, table.concat(lines, "\n"), "M")
end

local function open_with_bar()
  local st = canvas.open({ big_section("a.txt", "a"), big_section("b.txt", "b") }, {})
  scrollbar.close()
  scrollbar.open(st, {})
  return st
end

local function bar_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative == "win" and cfg.width == 1 then
      return w
    end
  end
end

local SCROLL_NS = vim.api.nvim_create_namespace("galley.scrollbar")

local function thumb_rows(bbuf)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bbuf, SCROLL_NS, 0, -1, { details = true })) do
    if m[4] and m[4].line_hl_group == "GalleyScrollThumb" then
      rows[#rows + 1] = m[2]
    end
  end
  return rows
end

T["scroll_win opens a 1-col non-focusable float on the canvas"] = function()
  local st = open_with_bar()
  assert(scrollbar.is_open())
  local w = bar_win()
  assert(w, "float exists")
  local cfg = vim.api.nvim_win_get_config(w)
  H.eq(cfg.relative, "win")
  H.eq(cfg.width, 1)
  H.eq(cfg.focusable, false)
  H.eq(vim.api.nvim_win_get_height(w), vim.api.nvim_win_get_height(st.win))
  H.eq(vim.api.nvim_get_current_win(), st.win, "focus stays in canvas")
  scrollbar.close()
  H.eq(scrollbar.is_open(), false)
end

T["scroll_win thumb tracks the viewport"] = function()
  local st = open_with_bar()
  local w = bar_win()
  local bbuf = vim.api.nvim_win_get_buf(w)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  scrollbar.update(st)
  local top_thumbs = thumb_rows(bbuf)
  assert(#top_thumbs > 0, "thumb present")
  H.eq(top_thumbs[1], 0, "thumb starts at the top row when scrolled to top")

  vim.api.nvim_win_call(st.win, function() vim.cmd("normal! G") end)
  scrollbar.update(st)
  local bot_thumbs = thumb_rows(bbuf)
  assert(#bot_thumbs > 0)
  local h = vim.api.nvim_win_get_height(w)
  H.eq(bot_thumbs[#bot_thumbs], h - 1, "thumb ends at the bottom row when scrolled to bottom")
  assert(bot_thumbs[1] > top_thumbs[1], "thumb moved down")
  scrollbar.close()
end

T["scroll_win hides during an excursion and re-shows after"] = function()
  local st = open_with_bar()
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(st.win, scratch) -- simulate jump.enter
  scrollbar.update(st)
  H.eq(scrollbar.is_open(), false, "float hidden while canvas not showing")

  vim.api.nvim_win_set_buf(st.win, st.buf) -- BufWinEnter fires
  vim.wait(200, function() return scrollbar.is_open() end, 10)
  H.eq(scrollbar.is_open(), true, "float re-shown on canvas re-show")
  scrollbar.close()
end

T["scroll_win hides on :edit excursion without manual update"] = function()
  local st = open_with_bar()
  local tmp = vim.fn.tempname()
  local f = assert(io.open(tmp, "w")); f:write("hello\n"); f:close()
  vim.api.nvim_win_call(st.win, function()
    vim.cmd.edit({ tmp, mods = { keepalt = true } })
  end)
  vim.wait(300, function() return not scrollbar.is_open() end, 10)
  H.eq(scrollbar.is_open(), false, "float hidden after :edit with no manual update call")
  -- and the BufWinEnter re-show still works
  vim.api.nvim_win_set_buf(st.win, st.buf)
  vim.wait(300, function() return scrollbar.is_open() end, 10)
  H.eq(scrollbar.is_open(), true)
  scrollbar.close()
end

T["scroll_win canvas WinClosed tears the bar down"] = function()
  local st = open_with_bar()
  vim.cmd("vsplit") -- ensure the canvas window isn't the last one
  vim.api.nvim_win_close(st.win, true)
  vim.wait(300, function() return not scrollbar.is_open() end, 10)
  H.eq(scrollbar.is_open(), false, "bar cleaned up after canvas window closed")
end

T["scroll_win file boundary rows are drawn"] = function()
  open_with_bar()
  local w = bar_win()
  local bbuf = vim.api.nvim_win_get_buf(w)
  local lines = vim.api.nvim_buf_get_lines(bbuf, 0, -1, false)
  local dashes = 0
  for _, l in ipairs(lines) do
    if l == "─" then dashes = dashes + 1 end
  end
  H.eq(dashes, 2, "two file-boundary rows for two sections")
  scrollbar.close()
end

T["scroll_win zero-height canvas window hides instead of erroring"] = function()
  local st = open_with_bar()
  vim.cmd("set winminheight=0")
  vim.cmd("split") -- need a second window so the canvas can be squashed
  vim.api.nvim_win_set_height(st.win, 0)
  local ok, err = pcall(scrollbar.update, st)
  H.eq(ok, true, "update must not throw on zero-height window: " .. tostring(err))
  H.eq(scrollbar.is_open(), false, "bar hidden while squashed")
  vim.api.nvim_win_set_height(st.win, 10)
  scrollbar.update(st)
  H.eq(scrollbar.is_open(), true, "bar re-shows once height returns")
  vim.cmd("only")
  scrollbar.close()
end

return T
