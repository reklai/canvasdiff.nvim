local H = require("helpers")
local render = require("canvasdiff.canvas").format
local model = require("canvasdiff.diff")
local scrollbar = require("canvasdiff.ui").scrollbar
local canvas = require("canvasdiff.canvas")

local T = {}

T["scrollbar facade exposes the bounded API and no flat compatibility path"] = function()
  local names = vim.tbl_keys(scrollbar)
  table.sort(names)
  H.eq(names, { "close", "column", "is_open", "line_kinds", "locate", "open", "update" })
  H.eq(package.searchpath("canvasdiff.scrollbar", package.path), nil,
    "consumers must enter through require('canvasdiff.ui').scrollbar")
end

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
  H.eq({ cells[1].char, cells[1].hl }, { render.glyphs.scroll_file, "CanvasDiffScrollFile" })
  H.eq({ cells[2].char, cells[2].hl }, { render.glyphs.scroll_bar, "CanvasDiffScrollAdd" })
  H.eq({ cells[3].char, cells[3].hl }, { render.glyphs.scroll_bar, "CanvasDiffScrollDel" })
  H.eq({ cells[4].char, cells[4].hl }, { render.glyphs.scroll_bar, "CanvasDiffScrollChanged" })
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

-- The minimap float is ONE column wide, so a glyph that renders as two cells cannot
-- fit in it. Every box-drawing and block-element character is East Asian Ambiguous
-- and doubles under `ambiwidth=double` -- a legitimate setting CJK users have, not a
-- misconfiguration. The original ─ and │ put a two-cell glyph in 13 of 21 rows there.
--
-- This is the guard against someone swapping in a better-looking ─, │, ▏, ▎, ━ or ┃:
-- all of them pass every other test in this file and silently break that setup.
T["scroll_column its glyphs stay one cell under ambiwidth=double"] = function()
  local saved = vim.o.ambiwidth
  local ok, err = pcall(function()
    for _, aw in ipairs({ "single", "double" }) do
      vim.o.ambiwidth = aw
      for _, name in ipairs({ "scroll_file", "scroll_bar" }) do
        H.eq(vim.fn.strwidth(render.glyphs[name]), 1,
          ("%s must be 1 cell at ambiwidth=%s; it cannot fit a width-1 float otherwise")
            :format(name, aw))
      end
    end

    -- And end to end, through the real bucketing: no cell may exceed the float width.
    vim.o.ambiwidth = "double"
    local kinds = {}
    for i = 1, 60 do kinds[i] = "ctx" end
    kinds[1], kinds[20] = "hdr", "hdr"
    kinds[10], kinds[40] = "add", "add"
    kinds[30] = "del"
    kinds[45], kinds[46] = "add", "del"
    local over = {}
    for r, c in ipairs(scrollbar.column(kinds, 12, 1, 12)) do
      if vim.fn.strwidth(c.char) > 1 then over[#over + 1] = ("row %d = %q"):format(r, c.char) end
    end
    H.eq(over, {}, "no minimap cell may be wider than the one column it is drawn in")
  end)
  vim.o.ambiwidth = saved
  assert(ok, err)
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
  local lease = assert(scrollbar.open(st, {}))
  return st, lease
end

local function bar_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative == "win" and cfg.width == 1 then
      return w
    end
  end
end

local SCROLL_NS = vim.api.nvim_create_namespace("canvasdiff.scrollbar")

local function thumb_rows(bbuf)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bbuf, SCROLL_NS, 0, -1, { details = true })) do
    if m[4] and m[4].line_hl_group == "CanvasDiffScrollThumb" then
      rows[#rows + 1] = m[2]
    end
  end
  return rows
end

T["scroll_win opens a 1-col non-focusable float on the canvas"] = function()
  local st, lease = open_with_bar()
  assert(scrollbar.is_open(lease))
  local w = bar_win()
  assert(w, "float exists")
  local cfg = vim.api.nvim_win_get_config(w)
  H.eq(cfg.relative, "win")
  H.eq(cfg.width, 1)
  H.eq(cfg.focusable, false)
  H.eq(vim.api.nvim_win_get_height(w), vim.api.nvim_win_get_height(st.win))
  H.eq(vim.api.nvim_get_current_win(), st.win, "focus stays in canvas")
  scrollbar.close(lease)
  H.eq(scrollbar.is_open(lease), false)
end

T["scroll_win a winbar never pushes the bar off the text area"] = function()
  -- relative="win" row 0 is already the first text row BELOW the winbar, so
  -- the bar needs no winbar offset: with one, it sat a row low and its last
  -- cell landed on the statusline (found via the sticky header's screenshot,
  -- 2026-08-02 -- the two floats shared the bug). Screen positions, not
  -- config numbers: the config row is meaningless without knowing the base.
  local st, lease = open_with_bar()
  vim.api.nvim_set_option_value("winbar", "BAND", { win = st.win, scope = "local" })
  vim.cmd.redraw() -- headless: the winbar enters the layout only on redraw
  scrollbar.update(lease)
  local w = assert(bar_win(), "float exists")
  local info = vim.fn.getwininfo(st.win)[1]
  local fpos = vim.api.nvim_win_get_position(w)
  local cpos = vim.api.nvim_win_get_position(st.win)
  H.eq(fpos[1], cpos[1] + info.winbar,
    "the bar's top cell is the first text row under the winbar")
  H.eq(vim.api.nvim_win_get_height(w), info.height,
    "the bar spans exactly the text rows")
  H.eq(fpos[1] + vim.api.nvim_win_get_height(w) - 1,
    cpos[1] + info.winbar + info.height - 1,
    "the bar's last cell is the last text row, never the statusline")
  scrollbar.close(lease)
end

T["scroll_win thumb tracks the viewport"] = function()
  local st, lease = open_with_bar()
  local w = bar_win()
  local bbuf = vim.api.nvim_win_get_buf(w)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  scrollbar.update(lease, st)
  local top_thumbs = thumb_rows(bbuf)
  assert(#top_thumbs > 0, "thumb present")
  H.eq(top_thumbs[1], 0, "thumb starts at the top row when scrolled to top")

  vim.api.nvim_win_call(st.win, function() vim.cmd("normal! G") end)
  scrollbar.update(lease, st)
  local bot_thumbs = thumb_rows(bbuf)
  assert(#bot_thumbs > 0)
  local h = vim.api.nvim_win_get_height(w)
  H.eq(bot_thumbs[#bot_thumbs], h - 1, "thumb ends at the bottom row when scrolled to bottom")
  assert(bot_thumbs[1] > top_thumbs[1], "thumb moved down")
  scrollbar.close(lease)
end

T["scroll_win hides during an excursion and re-shows after"] = function()
  local st, lease = open_with_bar()
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(st.win, scratch) -- simulate jump.enter
  scrollbar.update(lease, st)
  H.eq(scrollbar.is_open(lease), false, "float hidden while canvas not showing")

  vim.api.nvim_win_set_buf(st.win, st.buf) -- BufWinEnter fires
  vim.wait(200, function() return scrollbar.is_open(lease) end, 10)
  H.eq(scrollbar.is_open(lease), true, "float re-shown on canvas re-show")
  scrollbar.close(lease)
end

T["scroll_win hides on :edit excursion without manual update"] = function()
  local st, lease = open_with_bar()
  local tmp = vim.fn.tempname()
  local f = assert(io.open(tmp, "w")); f:write("hello\n"); f:close()
  vim.api.nvim_win_call(st.win, function()
    vim.cmd.edit({ tmp, mods = { keepalt = true } })
  end)
  vim.wait(300, function() return not scrollbar.is_open(lease) end, 10)
  H.eq(scrollbar.is_open(lease), false, "float hidden after :edit with no manual update call")
  -- and the BufWinEnter re-show still works
  vim.api.nvim_win_set_buf(st.win, st.buf)
  vim.wait(300, function() return scrollbar.is_open(lease) end, 10)
  H.eq(scrollbar.is_open(lease), true)
  scrollbar.close(lease)
end

T["scroll_win canvas WinClosed tears the bar down"] = function()
  local st, lease = open_with_bar()
  vim.cmd("vsplit") -- ensure the canvas window isn't the last one
  vim.api.nvim_win_close(st.win, true)
  vim.wait(300, function() return not scrollbar.is_open(lease) end, 10)
  H.eq(scrollbar.is_open(lease), false, "bar cleaned up after canvas window closed")
end

T["scroll_win file boundary rows are drawn"] = function()
  local _, lease = open_with_bar()
  local w = bar_win()
  local bbuf = vim.api.nvim_win_get_buf(w)
  local lines = vim.api.nvim_buf_get_lines(bbuf, 0, -1, false)
  local dashes = 0
  for _, l in ipairs(lines) do
    if l == render.glyphs.scroll_file then dashes = dashes + 1 end
  end
  H.eq(dashes, 2, "two file-boundary rows for two sections")
  scrollbar.close(lease)
end

T["scroll_win zero-height canvas window hides instead of erroring"] = function()
  local st, lease = open_with_bar()
  vim.cmd("set winminheight=0")
  vim.cmd("split") -- need a second window so the canvas can be squashed
  vim.api.nvim_win_set_height(st.win, 0)
  local ok, err = pcall(scrollbar.update, lease, st)
  H.eq(ok, true, "update must not throw on zero-height window: " .. tostring(err))
  H.eq(scrollbar.is_open(lease), false, "bar hidden while squashed")
  vim.api.nvim_win_set_height(st.win, 10)
  scrollbar.update(lease, st)
  H.eq(scrollbar.is_open(lease), true, "bar re-shows once height returns")
  vim.cmd("only")
  scrollbar.close(lease)
end

-- ---------------------------------------------------------------------------
-- Mouse: thumb dragging and track jumps.
--
-- These use the spike's IN-PROCESS recipe (spikes/2026-08-01-minimap-click-
-- routing): a -l test process never runs the main input loop, so a queued
-- mouse event can never dispatch a mapping here. nvim_input_mouse queues the
-- event, getchar(0) consumes it RAW -- which updates the position that
-- getmousepos() reads -- and then the canvas buffer's mapping callback is
-- invoked directly. That exercises the handlers against real position
-- resolution (including the float's mouse transparency); real end-to-end
-- dispatch is covered by the child --embed case at the bottom.
-- ---------------------------------------------------------------------------

--- The canvas buffer's expr-mapping callback for `lhs`, or nil.
local function mouse_cb(buf, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if H.norm_lhs(m.lhs) == H.norm_lhs(lhs) then
      return m.callback
    end
  end
end

--- Queue one mouse event at 1-based SCREEN coordinates and consume it raw,
--- so getmousepos() reports exactly this event to the next callback call.
local function feed_mouse(action, srow, scol)
  vim.api.nvim_input_mouse("left", action, "", 0, srow - 1, scol - 1)
  assert(vim.fn.getchar(0) ~= 0, "the queued mouse event was consumed")
end

--- The scrub is applied via vim.schedule (expr evaluation holds the
--- textlock, where a view change silently does not stick); run the queue dry
--- before asserting on the viewport.
local function drain_schedule()
  local done = false
  vim.schedule(function() done = true end)
  assert(vim.wait(1000, function() return done end, 5), "main loop drained")
end

local function topline(win)
  return vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
end

--- Canvas at the top, thumb re-rendered, and the geometry every mouse test
--- needs: float screen position, bar height, canvas line count.
local function mouse_stage(st, lease)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  scrollbar.update(lease, st)
  local w = assert(bar_win(), "the scrollbar float is open")
  local fpos = vim.fn.win_screenpos(w)
  local height = vim.api.nvim_win_get_height(w)
  local total = vim.api.nvim_buf_line_count(st.buf)
  assert(total > height, "the canvas must be taller than the bar to scroll")
  return { frow = fpos[1], fcol = fpos[2], height = height, total = total }
end

T["scroll_mouse press on the track jumps the viewport once"] = function()
  local st, lease = open_with_bar()
  local geo = mouse_stage(st, lease)
  local press = assert(mouse_cb(st.buf, "<LeftMouse>"),
    "the canvas buffer owns a <LeftMouse> mapping")
  local release = assert(mouse_cb(st.buf, "<LeftRelease>"))

  -- scrolled to the top, the thumb hugs the top rows: the bar's LAST row is
  -- bare track
  feed_mouse("press", geo.frow + geo.height - 1, geo.fcol)
  H.eq(press(), "<Ignore>", "a press on the bar is consumed, not forwarded")
  drain_schedule()
  H.eq(topline(st.win), scrollbar.locate(geo.height, geo.height, geo.total),
    "the viewport jumped to the pressed row's proportional position")
  H.eq(topline(st.win), geo.total - geo.height + 1,
    "the bottom track row means the last full screen")

  feed_mouse("release", geo.frow + geo.height - 1, geo.fcol)
  H.eq(release(), "<Ignore>", "the release that ends a bar gesture is consumed")
  scrollbar.close(lease)
end

T["scroll_mouse dragging the thumb scrubs live, clamped, until release"] = function()
  local st, lease = open_with_bar()
  local geo = mouse_stage(st, lease)
  local press = assert(mouse_cb(st.buf, "<LeftMouse>"))
  local drag = assert(mouse_cb(st.buf, "<LeftDrag>"))
  local release = assert(mouse_cb(st.buf, "<LeftRelease>"))

  -- at the top the thumb occupies bar row 1: pressing it arms without moving
  feed_mouse("press", geo.frow, geo.fcol)
  H.eq(press(), "<Ignore>", "a press on the thumb is consumed")
  drain_schedule()
  H.eq(topline(st.win), 1, "arming the drag does not jump the viewport")

  local mid = math.floor(geo.height / 2)
  feed_mouse("drag", geo.frow + mid - 1, geo.fcol)
  H.eq(drag(), "<Ignore>", "an armed drag is consumed")
  drain_schedule()
  H.eq(topline(st.win), scrollbar.locate(mid, geo.height, geo.total),
    "a mid-bar drag scrubs the viewport proportionally")

  -- drags keep firing after the pointer leaves the bar (spike Q3): clamp.
  -- Bottom screen row, 20 columns into the canvas body.
  feed_mouse("drag", vim.o.lines, math.max(geo.fcol - 20, 1))
  H.eq(drag(), "<Ignore>", "an off-bar drag still belongs to the armed gesture")
  drain_schedule()
  H.eq(topline(st.win), geo.total - geo.height + 1,
    "a drag past the bar's end clamps to the last full screen")

  feed_mouse("release", vim.o.lines, math.max(geo.fcol - 20, 1))
  H.eq(release(), "<Ignore>", "the release disarms the drag")
  local before = topline(st.win)
  feed_mouse("drag", geo.frow + 1, geo.fcol)
  H.eq(drag(), "<LeftDrag>", "a drag after release falls through untouched")
  drain_schedule()
  H.eq(topline(st.win), before, "a disarmed drag never scrubs")
  scrollbar.close(lease)
end

T["scroll_mouse off-bar events fall through untouched"] = function()
  local st, lease = open_with_bar()
  local geo = mouse_stage(st, lease)
  local press = assert(mouse_cb(st.buf, "<LeftMouse>"))
  local drag = assert(mouse_cb(st.buf, "<LeftDrag>"))
  local release = assert(mouse_cb(st.buf, "<LeftRelease>"))

  -- canvas body, well left of the bar column
  feed_mouse("press", geo.frow + 3, math.max(geo.fcol - 25, 1))
  H.eq(press(), "<LeftMouse>",
    "an off-bar press is returned for the default click to handle")
  drain_schedule()
  H.eq(topline(st.win), 1, "no scrub was scheduled for an off-bar press")
  H.eq(drag(), "<LeftDrag>", "an unarmed drag falls through")
  H.eq(release(), "<LeftRelease>", "an unarmed release falls through")

  -- the bar COLUMN but off the canvas window entirely (the command-line row
  -- at the bottom of the screen): still never a bar hit
  feed_mouse("press", vim.o.lines, geo.fcol)
  H.eq(press(), "<LeftMouse>",
    "a press below the canvas window falls through even on the bar column")
  drain_schedule()
  H.eq(topline(st.win), 1)
  scrollbar.close(lease)
end

T["scroll_mouse mappings and drag state die with the lease"] = function()
  local st, lease = open_with_bar()
  local geo = mouse_stage(st, lease)
  assert(mouse_cb(st.buf, "<LeftMouse>"), "open installs the press mapping")
  assert(mouse_cb(st.buf, "<LeftDrag>"), "open installs the drag mapping")
  assert(mouse_cb(st.buf, "<LeftRelease>"), "open installs the release mapping")

  -- arm a drag, then tear the lease down mid-gesture
  local press = mouse_cb(st.buf, "<LeftMouse>")
  feed_mouse("press", geo.frow, geo.fcol)
  H.eq(press(), "<Ignore>")
  scrollbar.close(lease)

  H.eq(mouse_cb(st.buf, "<LeftMouse>"), nil, "close removes the press mapping")
  H.eq(mouse_cb(st.buf, "<LeftDrag>"), nil, "close removes the drag mapping")
  H.eq(mouse_cb(st.buf, "<LeftRelease>"), nil, "close removes the release mapping")
  drain_schedule()
  H.eq(topline(st.win), 1, "no stale scrub survives the lease")
end

T["scroll_mouse never clobbers an existing canvas mouse mapping"] = function()
  local st = canvas.open({ big_section("a.txt", "a"), big_section("b.txt", "b") }, {})
  local fired = 0
  vim.keymap.set("n", "<LeftMouse>", function() fired = fired + 1 end,
    { buffer = st.buf })
  local lease = assert(scrollbar.open(st, {}))

  local cb = assert(mouse_cb(st.buf, "<LeftMouse>"))
  cb()
  H.eq(fired, 1, "the pre-existing mapping is still the one installed")

  scrollbar.close(lease)
  assert(mouse_cb(st.buf, "<LeftMouse>"),
    "close removes only the mappings the lease itself installed")
  vim.keymap.del("n", "<LeftMouse>", { buffer = st.buf })
end

T["scroll_mouse far scrub on a virtualized canvas lands on an auto-expanded section"] = function()
  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
    big_section("d/four.txt", "d"),
    big_section("e/five.txt", "e"),
    big_section("f/six.txt", "f"),
  }, {})
  local lease = assert(scrollbar.open(st, {}))
  local virt = require("canvasdiff.runtime").virtualizer
  local vlease = virt.attach(st, { enabled = false })
  local opts = {
    enabled = true, max_files = 3, max_lines = 1000000,
    margin = 10, max_expanded = 2,
  }

  local ok, err = xpcall(function()
    local geo = mouse_stage(st, lease)
    virt.apply(vlease, opts)
    local last = st.sections[6].path
    assert(st.collapsed[last], "sanity: the far bottom section auto-collapsed")

    -- the collapse shrank the canvas: re-stage so the drag speaks the
    -- virtualized geometry, then scrub from the thumb to the bar's bottom
    geo = mouse_stage(st, lease)
    local press = assert(mouse_cb(st.buf, "<LeftMouse>"))
    local drag = assert(mouse_cb(st.buf, "<LeftDrag>"))
    local release = assert(mouse_cb(st.buf, "<LeftRelease>"))
    feed_mouse("press", geo.frow, geo.fcol)
    H.eq(press(), "<Ignore>")
    feed_mouse("drag", geo.frow + geo.height - 1, geo.fcol)
    H.eq(drag(), "<Ignore>")
    drain_schedule()
    H.eq(topline(st.win), geo.total - geo.height + 1,
      "the drag scrubbed to the bottom of the virtualized canvas")
    feed_mouse("release", geo.frow + geo.height - 1, geo.fcol)
    H.eq(release(), "<Ignore>")

    -- the scroll-driven virtualizer pass (WinScrolled never fires headlessly)
    virt.apply(vlease, opts)
    H.eq(st.collapsed[last], nil,
      "the section under the scrubbed viewport was auto-expanded")
    assert(st.collapsed[st.sections[1].path],
      "the newly-far top collapsed in its place")
  end, debug.traceback)
  pcall(virt.detach, vlease)
  pcall(scrollbar.close, lease)
  assert(ok, err)
end

-- ---------------------------------------------------------------------------
-- End-to-end: the spike's CHILD --embed recipe. The child's main loop
-- dispatches queued mouse input between RPC requests, so this is real mapping
-- dispatch through the real plugin -- pinning that a plain click still places
-- the cursor and <2-LeftMouse> still jumps with the bar's mappings installed.
-- ---------------------------------------------------------------------------

local CHILD_SETUP = [==[
local root, repo = ...
vim.opt.runtimepath:prepend(root)
vim.env.XDG_STATE_HOME = vim.fs.joinpath(
  vim.uv.os_tmpdir(), "canvasdiff_mouse_state_" .. vim.uv.hrtime())
vim.api.nvim_set_current_dir(repo)
local fm = require("canvasdiff")
fm.setup({})
local st = fm.open()
assert(type(st) == "table" and st.surface, "open returned a live state")
local lease = st.surface.controllers.scrollbar
assert(lease and lease.win and vim.api.nvim_win_is_valid(lease.win),
  "the scrollbar float is open")
_G.st = st
vim.api.nvim_win_call(st.win, function()
  vim.fn.winrestview({ topline = 1, lnum = 1 })
end)
vim.api.nvim_win_set_cursor(st.win, { 1, 0 })
local info = vim.fn.getwininfo(st.win)[1]
return {
  canvas = {
    win = st.win,
    buf = st.buf,
    winbar = info.winbar,
    screenpos = vim.fn.win_screenpos(st.win),
    total = vim.api.nvim_buf_line_count(st.buf),
  },
  float = {
    height = vim.api.nvim_win_get_height(lease.win),
    screenpos = vim.fn.win_screenpos(lease.win),
  },
}
]==]

T["scroll_mouse end-to-end default click and double-click jump keep working"] = function()
  local function lines150(tag, changed)
    local out = {}
    for i = 1, 150 do
      out[i] = ("%s line %d"):format(tag, i)
      if changed and i % 8 == 0 then
        out[i] = out[i] .. " CHANGED"
      end
    end
    return table.concat(out, "\n") .. "\n"
  end
  local repo = H.git_fixture({
    committed = { ["a.txt"] = lines150("a"), ["b.txt"] = lines150("b") },
    worktree = {
      ["a.txt"] = lines150("a", true),
      ["b.txt"] = lines150("b", true),
    },
  })
  local chan = vim.fn.jobstart(
    { vim.v.progpath, "--headless", "--embed", "--clean" }, { rpc = true })
  assert(chan > 0, "child nvim started")

  local ok, err = xpcall(function()
    local function lua(code, ...)
      return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
    end
    local function mouse(action, srow, scol) -- 1-based screen coordinates
      vim.rpcrequest(chan, "nvim_input_mouse", "left", action, "", 0,
        srow - 1, scol - 1)
    end
    local function wait_child(code, what)
      local deadline = vim.uv.hrtime() + 5e9
      while vim.uv.hrtime() < deadline do
        local value = lua(code)
        if value ~= nil and value ~= false and value ~= vim.NIL then
          return value
        end
        vim.wait(20)
      end
      error("timed out waiting for: " .. what)
    end

    local info = lua(CHILD_SETUP, H.project_root, repo)
    local crow, ccol = info.canvas.screenpos[1], info.canvas.screenpos[2]
    local frow, fcol = info.float.screenpos[1], info.float.screenpos[2]

    -- 1. an off-bar click passes THROUGH the installed <LeftMouse> mapping
    --    and places the cursor, exactly as with no mapping at all
    local target_row = crow + info.canvas.winbar + 7
    mouse("press", target_row, ccol + 3)
    mouse("release", target_row, ccol + 3)
    local landed = wait_child(
      ("local c = vim.api.nvim_win_get_cursor(%d); return c[1] > 1 and c[1]")
        :format(info.canvas.win),
      "the default click to move the canvas cursor")
    H.eq(landed, lua("return vim.fn.getmousepos().line"),
      "the cursor sits on the buffer line under the pointer")

    -- 2. a track press on the bar scrubs the viewport (real dispatch of the
    --    mapping plus its scheduled apply)
    mouse("press", frow + info.float.height - 1, fcol)
    mouse("release", frow + info.float.height - 1, fcol)
    local expected = scrollbar.locate(
      info.float.height, info.float.height, info.canvas.total)
    local top = wait_child(
      ("local t = vim.api.nvim_win_call(%d, function() return vim.fn.line('w0') end); return t > 1 and t")
        :format(info.canvas.win),
      "the bar press to scrub the viewport")
    H.eq(top, expected, "the track press jumped to the proportional position")

    -- 3. double-click on a canvas row still runs the jump action: the canvas
    --    window ends up showing the real file (an excursion)
    local dbl_row = crow + info.canvas.winbar + 2
    for _ = 1, 2 do
      mouse("press", dbl_row, ccol + 3)
      mouse("release", dbl_row, ccol + 3)
    end
    local name = wait_child(
      ([[local b = vim.api.nvim_win_get_buf(%d)
         if b == %d then return false end
         return vim.api.nvim_buf_get_name(b)]])
        :format(info.canvas.win, info.canvas.buf),
      "the double-click jump to open the real file")
    assert(name:find("%.txt$"),
      "the jump landed in a fixture file, got: " .. tostring(name))
  end, debug.traceback)

  pcall(vim.fn.jobstop, chan)
  pcall(vim.fn.delete, repo, "rf")
  assert(ok, err)
end

local function plain_state(win, label)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "canvasdiff-test-scrollbar-" .. label)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { label, label .. " two" })
  vim.api.nvim_win_set_buf(win, buf)
  return {
    win = win,
    buf = buf,
    sections = {},
    collapsed = {},
    folded = {},
  }
end

local function with_two_bars(body)
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local first = vim.api.nvim_get_current_win()
  local state_a = plain_state(first, "a-" .. vim.uv.hrtime())
  vim.cmd("vnew")
  local second = vim.api.nvim_get_current_win()
  local state_b = plain_state(second, "b-" .. vim.uv.hrtime())
  local lease_a = assert(scrollbar.open(state_a, {}))
  local lease_b = assert(scrollbar.open(state_b, {}))

  local ok, err = xpcall(function()
    body({
      lease_a = lease_a,
      lease_b = lease_b,
      state_a = state_a,
      state_b = state_b,
    })
  end, debug.traceback)
  pcall(scrollbar.close, lease_a)
  pcall(scrollbar.close, lease_b)
  if vim.api.nvim_tabpage_is_valid(tab) then
    pcall(vim.api.nvim_set_current_tabpage, tab)
    pcall(vim.cmd, "tabclose!")
  end
  assert(ok, err)
end

T["scroll_lease two concurrent owners close independently"] = function()
  with_two_bars(function(ctx)
    assert(ctx.lease_a ~= ctx.lease_b)
    assert(ctx.lease_a.group_name ~= ctx.lease_b.group_name,
      "each lease owns a unique autocmd group")
    H.eq(scrollbar.is_open(ctx.lease_a), true)
    H.eq(scrollbar.is_open(ctx.lease_b), true)

    H.eq(scrollbar.close(ctx.lease_a), true)
    H.eq(scrollbar.close(ctx.lease_a), false, "exact close is idempotent")
    H.eq(scrollbar.update(ctx.lease_a), false, "a disposed lease cannot redraw")
    H.eq(scrollbar.is_open(ctx.lease_b), true,
      "closing one lease cannot hide its peer")
  end)
end

T["scroll_lease forged shells cannot update or tear down a peer"] = function()
  with_two_bars(function(ctx)
    local peer = ctx.lease_b
    local forged = {
      id = peer.id,
      phase = peer.phase,
      disposed = peer.disposed,
      state = peer.state,
      callbacks = peer.callbacks,
      group_name = peer.group_name,
      group_id = peer.group_id,
      autocmd_ids = peer.autocmd_ids,
      schedule_ticket = peer.schedule_ticket,
      buf = peer.buf,
      win = peer.win,
    }

    H.eq(scrollbar.is_open(forged), false)
    H.eq(scrollbar.update(forged, ctx.state_a), false)
    H.eq(scrollbar.close(forged), false)
    H.eq(scrollbar.is_open(peer), true,
      "copied resource fields do not authenticate a lease")
  end)
end

T["scroll_lease stale scheduled work cannot reach a replacement"] = function()
  with_two_bars(function(ctx)
    local real_update = scrollbar.update
    local stale_updates = 0
    scrollbar.update = function(lease, ...)
      if lease == ctx.lease_a then
        stale_updates = stale_updates + 1
      end
      return real_update(lease, ...)
    end

    local ok, err = xpcall(function()
      local scratch = vim.api.nvim_create_buf(false, true)
      -- BufWinLeave queues a redraw while the old lease is still live.
      vim.api.nvim_win_set_buf(ctx.state_a.win, scratch)
      H.eq(scrollbar.close(ctx.lease_a), true)
      local drained = false
      vim.schedule(function() drained = true end)
      assert(vim.wait(300, function() return drained end, 10))
    end, debug.traceback)
    scrollbar.update = real_update
    assert(ok, err)

    H.eq(stale_updates, 0, "the queued callback rejects its disposed identity")
    H.eq(scrollbar.is_open(ctx.lease_b), true,
      "stale work cannot redirect through module-global state to a peer")
  end)
end

T["scroll_lease teardown invalidates before owner release reenters"] = function()
  with_two_bars(function(ctx)
    local reentered
    local peer_was_open
    ctx.lease_a.callbacks.release = function(lease)
      reentered = scrollbar.close(lease)
      peer_was_open = scrollbar.is_open(ctx.lease_b)
    end

    H.eq(scrollbar.close(ctx.lease_a), true)
    H.eq(reentered, false,
      "release observes the closing lease as already unauthenticated")
    H.eq(peer_was_open, true,
      "reentrant teardown cannot select or disturb another lease")
  end)
end

return T
