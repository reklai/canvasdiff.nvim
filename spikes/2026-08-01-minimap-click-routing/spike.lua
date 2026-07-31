-- Spike: mouse-click routing over the non-focusable minimap float.
--
-- Run: nvim --headless --clean -l spikes/2026-08-01-minimap-click-routing/spike.lua
--
-- Questions (Task 4's thumb dragging depends on the answers):
--   Q1 Which window/buffer receives <LeftMouse> when the pointer is over the
--      non-focusable scrollbar float -- the float or the canvas beneath?
--   Q2 What does getmousepos() report over the float?
--   Q3 Do <LeftDrag> events keep firing as the pointer moves (vertically along
--      the bar, and after leaving the float), and what does getmousepos()
--      report mid-drag?
--   Q4 Can nvim_input_mouse drive press/drag/release headlessly for Task 4's
--      integration tests?
--
-- Method: a REAL canvas + REAL scrollbar float, opened through the plugin's
-- own open path in a throwaway git fixture. Two phases:
--   Phase A (in-process, this -l script): nvim_input_mouse queues the event but
--     a -l script never runs the main input loop, so no mapping can fire here.
--     getchar(0) CAN consume the queued event, which updates the position that
--     getmousepos() reads -- the in-process test recipe.
--   Phase B (child `nvim --headless --embed` driven over RPC): the child's main
--     loop runs between requests, so queued mouse events dispatch real
--     mappings -- the full end-to-end recipe.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local ROOT = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here)))

local failures = {}
local function check(ok, label)
  print(("  %s %s"):format(ok and "ok  " or "FAIL", label))
  if not ok then
    failures[#failures + 1] = label
  end
end
local function flat(value)
  return (vim.inspect(value):gsub("%s+", " "))
end

-- Shared by both phases: build a git fixture, open the plugin's real canvas in
-- it, register probe mappings on BOTH the canvas and the scrollbar buffers,
-- and report the geometry. Kept as a string so the parent can load() it and
-- the child can nvim_exec_lua() the very same code.
local SETUP = [==[
local root = ...
vim.opt.runtimepath:prepend(root)
-- session persistence writes under stdpath("state"); never touch the real one
vim.env.XDG_STATE_HOME =
  vim.fs.joinpath(vim.uv.os_tmpdir(), "canvasdiff_spike_state_" .. vim.uv.hrtime())

-- git fixture (mirrors test/helpers.git_fixture, inlined to stay standalone)
local dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "canvasdiff_spike_" .. vim.uv.hrtime())
vim.fn.mkdir(dir, "p")
local function sh(cmd)
  local res = vim.system(cmd, { cwd = dir, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
end
local function write(rel, text)
  local f = assert(io.open(vim.fs.joinpath(dir, rel), "w"))
  f:write(text)
  f:close()
end
local function body(tag, changed)
  local out = {}
  for i = 1, 150 do
    out[i] = ("%s line %d"):format(tag, i)
    if changed and i % 8 == 0 then
      out[i] = out[i] .. " CHANGED"
    end
  end
  return table.concat(out, "\n") .. "\n"
end
sh({ "git", "init", "-b", "main" })
sh({ "git", "config", "user.email", "s@s" })
sh({ "git", "config", "user.name", "s" })
write("a.txt", body("a"))
write("b.txt", body("b"))
sh({ "git", "add", "-A" })
sh({ "git", "commit", "-m", "fixture" })
write("a.txt", body("a", true))
write("b.txt", body("b", true))
vim.api.nvim_set_current_dir(dir)

local fm = require("canvasdiff")
fm.setup({})
local st = fm.open()
assert(type(st) == "table" and st.surface, "open returned a state with a surface")
local lease = st.surface.controllers.scrollbar
assert(lease and lease.win and vim.api.nvim_win_is_valid(lease.win),
  "the scrollbar float is open")

_G.spike = {
  dir = dir,
  st = st,
  lease = lease,
  log = {},
  canvas_win = vim.api.nvim_get_current_win(),
  canvas_buf = vim.api.nvim_get_current_buf(),
}

local function probe(tag, buf)
  local events = { ["<LeftMouse>"] = "press", ["<LeftDrag>"] = "drag", ["<LeftRelease>"] = "release" }
  for lhs, ev in pairs(events) do
    vim.keymap.set("n", lhs, function()
      local s = _G.spike
      s.log[#s.log + 1] = {
        owner = tag,
        event = ev,
        pos = vim.fn.getmousepos(),
        curwin = vim.api.nvim_get_current_win(),
      }
    end, { buffer = buf })
  end
end
probe("canvas", _G.spike.canvas_buf)
probe("scrollbar", lease.buf)

-- thumb rows straight off the float's own extmarks
local ns = vim.api.nvim_create_namespace("canvasdiff.scrollbar")
local thumb = {}
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(lease.buf, ns, 0, -1, { details = true })) do
  if m[4].line_hl_group == "CanvasDiffScrollThumb" then
    thumb[#thumb + 1] = m[2] + 1
  end
end

local cfg = vim.api.nvim_win_get_config(lease.win)
return {
  mouse_default = vim.o.mouse,
  screen = { vim.o.columns, vim.o.lines },
  canvas = {
    win = _G.spike.canvas_win,
    buf = _G.spike.canvas_buf,
    width = vim.api.nvim_win_get_width(_G.spike.canvas_win),
    winbar = vim.fn.getwininfo(_G.spike.canvas_win)[1].winbar,
    screenpos = vim.fn.win_screenpos(_G.spike.canvas_win),
  },
  float = {
    win = lease.win,
    buf = lease.buf,
    focusable = cfg.focusable,
    zindex = cfg.zindex,
    height = vim.api.nvim_win_get_height(lease.win),
    screenpos = vim.fn.win_screenpos(lease.win),
  },
  thumb_rows = thumb,
}
]==]

-- ---------------------------------------------------------------------------
-- Phase A: in-process (-l script). No main loop => mappings cannot fire; the
-- getchar(0) consumption recipe still resolves positions for getmousepos().
-- ---------------------------------------------------------------------------
print("Phase A: in-process -l script (getchar consumption recipe)")
local info_a = assert(load(SETUP, "spike-setup"))(ROOT)
print("  geometry: " .. flat(info_a))
local A = _G.spike

local frow, fcol = info_a.float.screenpos[1], info_a.float.screenpos[2]
local thumb_row = info_a.thumb_rows[1] or 1

check(info_a.float.focusable == false, "A: float reports focusable=false")
check(#info_a.thumb_rows > 0, "A: the bar has a thumb to aim at")

-- press on the thumb; prove no flush strategy dispatches a mapping in -l
vim.api.nvim_input_mouse("left", "press", "", 0, (frow - 1) + (thumb_row - 1), fcol - 1)
vim.api.nvim_feedkeys("", "x", false)
vim.wait(50)
check(#A.log == 0, "A: queued press dispatches NO mapping in a -l script "
  .. "(feedkeys x + vim.wait both fail to pump input)")

-- getchar(0) consumes the queued event and sets the mouse position
local raw = vim.fn.getchar(0)
check(raw ~= 0, "A: getchar(0) consumed the queued press (raw key, mappings bypassed)")
check(#A.log == 0, "A: consuming via getchar(0) fired no mapping either")
local pos = vim.fn.getmousepos()
print("  getmousepos after consumed press on thumb: " .. flat(pos))
check(pos.winid == A.canvas_win,
  "A: getmousepos().winid is the CANVAS window, not the float (float is mouse-transparent)")
check(pos.wincol == info_a.canvas.width,
  "A: wincol == canvas width (the float column IS the canvas's last column)")
check(pos.winrow == info_a.canvas.winbar + thumb_row,
  "A: winrow == winbar rows + bar row (bar row = winrow - winbar)")

-- the in-process recipe Task 4's tests can use: consume, then call the
-- canvas-buffer mapping callback directly; it sees the synthesized position
local cb
for _, m in ipairs(vim.api.nvim_buf_get_keymap(A.canvas_buf, "n")) do
  if m.lhs == "<LeftMouse>" then
    cb = m.callback
  end
end
check(cb ~= nil, "A: the canvas <LeftMouse> mapping callback is retrievable")
cb()
check(#A.log == 1 and A.log[1].owner == "canvas"
    and vim.deep_equal(A.log[1].pos, pos),
  "A: calling the callback after consumption sees the same getmousepos payload")

-- drags consume the same way and update the position
vim.api.nvim_input_mouse("left", "drag", "", 0, (frow - 1) + (thumb_row + 2), fcol - 1)
vim.fn.getchar(0)
local dragpos = vim.fn.getmousepos()
print("  getmousepos after consumed drag 3 rows down:   " .. flat(dragpos))
check(dragpos.winrow == pos.winrow + 3 and dragpos.wincol == pos.wincol,
  "A: a consumed drag event moves getmousepos vertically as synthesized")
vim.api.nvim_input_mouse("left", "release", "", 0, (frow - 1) + (thumb_row + 2), fcol - 1)
vim.fn.getchar(0)

require("canvasdiff").close()
vim.fn.delete(A.dir, "rf")

-- ---------------------------------------------------------------------------
-- Phase B: child `nvim --headless --embed --clean` over RPC. The child's main
-- loop dispatches queued mouse input between requests: real mapping routing.
-- ---------------------------------------------------------------------------
print("Phase B: child --embed nvim over RPC (real mapping dispatch)")
local chan = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "--clean" }, { rpc = true })
assert(chan > 0, "child nvim started")
local function lua(code, ...)
  return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
end

local info = lua(SETUP, ROOT)
print("  geometry: " .. flat(info))
check(info.float.focusable == false, "B: float reports focusable=false")
check(#info.thumb_rows > 0, "B: the bar has a thumb to aim at")

frow, fcol = info.float.screenpos[1], info.float.screenpos[2]
thumb_row = info.thumb_rows[1]

local function mouse(action, srow, scol) -- 1-based screen coords in
  vim.rpcrequest(chan, "nvim_input_mouse", "left", action, "", 0, srow - 1, scol - 1)
end
local function wait_log(n)
  local deadline = vim.uv.hrtime() + 2e9
  while vim.uv.hrtime() < deadline do
    if lua("return #_G.spike.log") >= n then
      return true
    end
    vim.wait(10)
  end
  return false
end

-- the drag journey Task 4 implements: press the thumb, drag it down the bar,
-- wander off the column, release; then a press on a non-thumb bar row; then a
-- plain canvas click for contrast
mouse("press", frow + (thumb_row - 1), fcol)
check(wait_log(1), "B: <LeftMouse> press over the float DISPATCHED a mapping")
mouse("drag", frow + (thumb_row + 2), fcol)
check(wait_log(2), "B: <LeftDrag> 3 rows down the bar fired")
mouse("drag", frow + (thumb_row + 5), fcol)
check(wait_log(3), "B: <LeftDrag> 6 rows down the bar fired (drags KEEP firing)")
mouse("drag", frow + (thumb_row + 5), fcol - 10)
check(wait_log(4), "B: <LeftDrag> off the float into the canvas body still fired")
mouse("release", frow + (thumb_row + 5), fcol - 10)
check(wait_log(5), "B: <LeftRelease> fired")
mouse("press", frow + info.float.height - 1, fcol)
mouse("release", frow + info.float.height - 1, fcol)
check(wait_log(7), "B: press+release on the bar's last row fired")
mouse("press", frow + 2, fcol - 30)
mouse("release", frow + 2, fcol - 30)
check(wait_log(9), "B: plain canvas press+release fired")

local log = lua("return _G.spike.log")
for i, e in ipairs(log) do
  print(("  %d owner=%-6s event=%-7s curwin=%d pos=%s")
    :format(i, e.owner, e.event, e.curwin, flat(e.pos)))
end

local all_canvas, focus_stable, float_col_ok = true, true, true
for _, e in ipairs(log) do
  all_canvas = all_canvas and e.owner == "canvas"
  focus_stable = focus_stable and e.curwin == info.canvas.win
  if e.pos.screencol == fcol then
    float_col_ok = float_col_ok
      and e.pos.winid == info.canvas.win
      and e.pos.wincol == info.canvas.width
  end
end
check(all_canvas,
  "B: every event ran the CANVAS buffer's mapping; the float's mappings NEVER fired")
check(focus_stable, "B: focus stayed on the canvas window throughout")
check(float_col_ok,
  "B: over the float, getmousepos reports the canvas window with wincol == canvas width")
check(log[1].pos.winrow == info.canvas.winbar + thumb_row,
  "B: press winrow == winbar + thumb row")
check(log[2].pos.winrow == log[1].pos.winrow + 3
    and log[3].pos.winrow == log[1].pos.winrow + 6,
  "B: mid-drag getmousepos tracks the live pointer row")
check(log[4].pos.wincol == info.canvas.width - 10,
  "B: a drag that leaves the float reports the real canvas column")

-- default behavior with NO mapping: the click passes through the float and
-- moves the CANVAS cursor; the float is never focused
lua([[
  for _, lhs in ipairs({ "<LeftMouse>", "<LeftDrag>", "<LeftRelease>" }) do
    vim.keymap.del("n", lhs, { buffer = _G.spike.canvas_buf })
  end
]])
local before = lua("return { win = vim.api.nvim_get_current_win(), cur = vim.api.nvim_win_get_cursor(0) }")
-- same coordinates as log entry 6, whose mapped probe recorded which canvas
-- LINE lives under that screen row -- the default click should land there
mouse("press", frow + info.float.height - 1, fcol)
mouse("release", frow + info.float.height - 1, fcol)
vim.wait(200)
local after = lua([[return {
  win = vim.api.nvim_get_current_win(),
  buf = vim.api.nvim_get_current_buf(),
  cur = vim.api.nvim_win_get_cursor(0),
  float_cur = vim.api.nvim_win_get_cursor(_G.spike.lease.win),
}]])
print("  unmapped click on float: before=" .. flat(before) .. " after=" .. flat(after))
check(after.win == before.win and after.buf == info.canvas.buf,
  "B: an UNMAPPED click on the float does not focus it (focusable=false honored)")
check(after.cur[1] == log[6].pos.line and after.cur[1] ~= before.cur[1],
  "B: ...but it DOES move the canvas cursor to the line under the pointer "
  .. "(default click passes through the float)")

lua("require('canvasdiff').close(); vim.fn.delete(_G.spike.dir, 'rf')")
vim.fn.jobstop(chan)

print(#failures == 0 and "SPIKE PASS" or ("SPIKE FAIL: " .. #failures .. " check(s)"))
os.exit(#failures == 0 and 0 or 1)
