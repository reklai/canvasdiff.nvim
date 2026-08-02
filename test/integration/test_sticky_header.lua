-- The sticky file-header FLOAT: the one-row window pinned under the winbar
-- that mirrors the in-buffer header of the section under the topline. The
-- pure "what should it show" half is unit-tested in test_sticky_content.lua;
-- everything here is the float's lifecycle -- geometry, extmark layering,
-- hide/show, teardown, lease exactness -- driven by hand because WinScrolled
-- and WinResized never fire headlessly (see test_scrollbar.lua, whose
-- patterns these tests follow).

local H = require("helpers")
local appearance = require("canvasdiff.appearance")
local canvas = require("canvasdiff.canvas")
local render = canvas.format
local model = require("canvasdiff.diff")
local sticky = require("canvasdiff.ui").sticky_header

local T = {}

local STICKY_NS = vim.api.nvim_create_namespace("canvasdiff.sticky")

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

--- A section tall enough to scroll into, carrying both stage facts when asked
--- so the span-mirror assertions compare non-empty output.
local function big_section(path, tag, metadata)
  local old = bigtext(60, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 10, 60, 10 do lines[i] = lines[i] .. " changed" end
  return model.build_section(path, old, table.concat(lines, "\n"), "M",
    nil, metadata)
end

--- Canvas at a known topline BEFORE the lease opens: the canvas buffer is a
--- singleton that remembers its view across tests, and open() draws once --
--- an inherited topline would decide visibility for us.
local function open_pinned()
  local st = canvas.open({
    big_section("a/one.txt", "a", { staged = "M", unstaged = "M" }),
    big_section("b/two.txt", "b"),
  }, {})
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  local lease = assert(sticky.open(st, {}))
  return st, lease
end

--- Scroll the canvas so 0-based `top0` is the topline, then redraw by hand
--- (WinScrolled never fires headlessly).
local function scroll_to(st, lease, top0)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = top0 + 1, lnum = top0 + 1 })
  end)
  sticky.update(lease)
end

local function shown_line(lease)
  local fbuf = vim.api.nvim_win_get_buf(lease.win)
  return vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)[1]
end

T["sticky_win facade exposes the bounded API"] = function()
  local names = vim.tbl_keys(sticky)
  table.sort(names)
  H.eq(names, { "close", "content", "is_open", "open", "update" })
end

T["sticky_win hidden while the first header is the topline"] = function()
  local _, lease = open_pinned()
  sticky.update(lease)
  H.eq(sticky.is_open(lease), false,
    "the real header row sits at the top; pinning a copy would double it")
  sticky.close(lease)
end

T["sticky_win appears once the header scrolls off, mirroring it exactly"] = function()
  local st, lease = open_pinned()
  -- The real app always gives the canvas a winbar, and the winbar is exactly
  -- where the placement bug lived: relative="win" row 0 is ALREADY the first
  -- text row below the winbar, so any winbar-derived row offset lands the
  -- float one row too low (user screenshot, 2026-08-02). Pin the SCREEN
  -- position, not the config number.
  vim.api.nvim_set_option_value("winbar", "BAND", { win = st.win, scope = "local" })
  vim.cmd.redraw() -- headless: the winbar enters the layout only on redraw
  scroll_to(st, lease, 2) -- two rows into section 1
  H.eq(sticky.is_open(lease), true)
  local header = render.section_line(st.sections[1], 1)
  H.eq(shown_line(lease):sub(1, #header), header,
    "the file part of the pinned row is the in-buffer header, byte for byte")
  assert(shown_line(lease):find(render.glyphs.crumb .. "@@ ", 1, true),
    "and the crumb names the hunk under it: " .. shown_line(lease))

  -- float geometry: 1 row tall, canvas-wide, under the winbar, below the minimap
  local cfg = vim.api.nvim_win_get_config(lease.win)
  H.eq(cfg.height, 1)
  H.eq(cfg.width, vim.api.nvim_win_get_width(st.win))
  H.eq(cfg.relative, "win")
  assert(cfg.zindex < 40, "the minimap owns the shared top-right cell")
  H.eq(cfg.focusable, false)
  local fpos = vim.api.nvim_win_get_position(lease.win)
  local cpos = vim.api.nvim_win_get_position(st.win)
  H.eq(fpos[1], cpos[1] + vim.fn.getwininfo(st.win)[1].winbar,
    "the float's SCREEN row is the first text row under the winbar")
  H.eq(fpos[2], cpos[2], "flush with the canvas's left edge")
  H.eq(vim.api.nvim_get_current_win(), st.win, "focus stays in canvas")
  sticky.close(lease)
end

T["sticky_win swaps at a section boundary"] = function()
  local st, lease = open_pinned()
  local boundary = (canvas.section_rows(st, 2)) -- section 2's start row, live
  -- The file part is what swaps; the crumb after it tracks the scroll by
  -- design, so the identity is compared as the prefix it is.
  local one = render.section_line(st.sections[1], 1)
  local two = render.section_line(st.sections[2], 1)
  scroll_to(st, lease, boundary - 1)
  H.eq(shown_line(lease):sub(1, #one), one,
    "the last row of section 1 still pins section 1's header")
  scroll_to(st, lease, boundary + 1)
  H.eq(shown_line(lease):sub(1, #two), two,
    "one row past the boundary pins section 2's header")
  sticky.close(lease)
end

T["sticky_win row carries the bar tint and the marker spans"] = function()
  local st, lease = open_pinned()
  scroll_to(st, lease, 2)
  local line = shown_line(lease)
  local section = st.sections[1]
  local head = render.section_line(section, 1)
  -- Measured off the FILE part, which is where the stage marks are:
  -- marker_spans walks in from the end of what it is given, and the crumb now
  -- holds the end of the row.
  local spans = render.marker_spans(head, section.staged, section.unstaged, false)
  assert(#spans > 0,
    "the fixture carries both stage facts, so the layering must be exercised on real spans")
  -- The crumb wears its own group, over everything past the file identity.
  spans[#spans + 1] = { #head, #line, "CanvasDiffCrumb" }

  local fbuf = vim.api.nvim_win_get_buf(lease.win)
  local bar, header = false, false
  local span_marks = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(fbuf, STICKY_NS, 0, -1,
      { details = true })) do
    local d = m[4]
    if d.line_hl_group == "CanvasDiffFileBar" then
      bar = true
    elseif d.hl_group == "CanvasDiffFileHeader" then
      header = true
      H.eq(m[3], 0, "the header tint starts at col 0")
      H.eq(d.end_col, #line, "the header tint covers the whole line")
    elseif d.hl_group then
      span_marks[#span_marks + 1] = { m[3], d.end_col, d.hl_group }
    end
  end
  assert(bar, "the full-width CanvasDiffFileBar tint rides the pinned row")
  assert(header, "the CanvasDiffFileHeader mark sits over the text")
  table.sort(span_marks, function(x, y) return x[1] < y[1] end)
  table.sort(spans, function(x, y) return x[1] < y[1] end)
  H.eq(span_marks, spans,
    "one mark per marker span, at the same columns with the same groups")
  sticky.close(lease)
end

T["sticky_win a reconcile's new counts reach the pinned row"] = function()
  local st, lease = open_pinned()
  scroll_to(st, lease, 2)
  local before = shown_line(lease)
  -- The way a reconcile lands for this row: the section object's counts
  -- change, and the next update re-renders from the model, not from a cache.
  local section = st.sections[1]
  section.adds = section.adds + 7
  section.dels = section.dels + 3
  sticky.update(lease)
  local after = shown_line(lease)
  assert(after ~= before, "the pinned row re-renders from the live section")
  local header = render.section_line(section, 1)
  H.eq(after:sub(1, #header), header)
  sticky.close(lease)
end

T["sticky_win hides on excursion and dies with the canvas window"] = function()
  local st, lease = open_pinned()
  scroll_to(st, lease, 2)
  H.eq(sticky.is_open(lease), true)

  -- BufWinLeave path: the canvas buffer leaves its window (a jump
  -- excursion's :edit, or any buffer switch). The hide is DEFERRED -- at
  -- BufWinLeave time the window still transiently reports the old buffer --
  -- so wait for the scheduled update to land.
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(st.win, scratch)
  vim.wait(300, function() return not sticky.is_open(lease) end, 10)
  H.eq(sticky.is_open(lease), false, "float hidden while canvas not showing")

  -- The lease SURVIVES hiding: the same lease re-shows once the canvas is
  -- back and the view settles. Driven by hand here: a re-entered window's
  -- topline only settles on redraw (measured: it transiently reads 1 at
  -- BufWinEnter and on the next tick), and the WinScrolled that re-draws
  -- the row at settle time in a live session never fires headlessly.
  vim.api.nvim_win_set_buf(st.win, st.buf)
  scroll_to(st, lease, 2)
  H.eq(sticky.is_open(lease), true, "the same lease re-shows after hiding")

  -- WinClosed path: the canvas window dies, and the scheduled teardown
  -- takes the lease with it.
  local fwin = lease.win
  vim.cmd("vsplit") -- the canvas window must not be the last one
  vim.api.nvim_win_close(st.win, true)
  vim.wait(300, function() return not sticky.is_open(lease) end, 10)
  H.eq(sticky.is_open(lease), false)
  H.eq(fwin and vim.api.nvim_win_is_valid(fwin) or false, false,
    "the float window is gone with the canvas window")
  H.eq(sticky.close(lease), false,
    "the WinClosed teardown already closed the lease; exact close is idempotent")
end

T["sticky_win claim refusal allocates nothing"] = function()
  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
  }, {})
  -- Scrolled where the row WOULD show, so refusal is what keeps it away.
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 3, lnum = 3 })
  end)
  local wins_before = #vim.api.nvim_list_wins()
  local lease = sticky.open(st, {}, {
    claim = function() return false end,
  })
  H.eq(lease, nil, "a refused claim yields no lease")
  H.eq(#vim.api.nvim_list_wins(), wins_before,
    "no float (or any other window) survives a refused claim")
end

T["sticky_win open defines the groups its crumb draws with"] = function()
  -- Observed as a CALL, not as highlight state. Highlight groups are
  -- process-global and `default = true` makes a second definition a no-op, so
  -- any test that reads the groups back passes as soon as some earlier test in
  -- the same process defined them -- it would go green with this call deleted.
  -- The sidebar's own call is covered on its side; this is the half that a
  -- canvas running with `sidebar.enabled = false` depends on, and no test
  -- exercises that configuration.
  local real = appearance.ensure
  local calls = 0
  appearance.ensure = function(...)
    calls = calls + 1
    return real(...)
  end

  local ok, err = xpcall(function()
    local _, lease = open_pinned()
    assert(calls > 0,
      "SH.open must define CanvasDiffCrumb and CanvasDiffHunkDel before it can"
        .. " draw a crumb with them -- a canvas with no sidebar has no other"
        .. " chance to")
    sticky.close(lease)
  end, debug.traceback)

  appearance.ensure = real
  assert(ok, err)
end

return T
