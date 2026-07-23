local H = require("helpers")
local sidebar = require("finding_myself.sidebar")
local canvas = require("finding_myself.canvas")
local model = require("finding_myself.model")

local T = {}

local function sec(path, adds, dels)
  return { path = path, adds = adds or 1, dels = dels or 0 }
end

T["sidebar_entries flat root files need no dir rows"] = function()
  local entries = sidebar.build_entries({ sec("a.txt"), sec("b.txt") }, {})
  H.eq(#entries, 2)
  H.eq(entries[1], { kind = "file", path = "a.txt", name = "a.txt", depth = 0,
    section_i = 1, adds = 1, dels = 0 })
  H.eq(entries[2].section_i, 2)
end

T["sidebar_entries nested dirs emitted once with correct depth"] = function()
  local entries = sidebar.build_entries({
    sec("lua/mod/a.lua"), sec("lua/mod/b.lua"), sec("lua/top.lua"), sec("root.md"),
  }, {})
  local shape = {}
  for i, e in ipairs(entries) do
    shape[i] = { e.kind, e.path, e.depth }
  end
  H.eq(shape, {
    { "dir", "lua/", 0 },
    { "dir", "lua/mod/", 1 },
    { "file", "lua/mod/a.lua", 2 },
    { "file", "lua/mod/b.lua", 2 },
    { "file", "lua/top.lua", 1 },
    { "file", "root.md", 0 },
  })
  H.eq(entries[3].section_i, 1)
  H.eq(entries[5].section_i, 3)
  H.eq(entries[6].section_i, 4)
end

T["sidebar_entries folded dir hides all descendants"] = function()
  local entries = sidebar.build_entries({
    sec("lua/mod/a.lua"), sec("lua/mod/deep/c.lua"), sec("lua/top.lua"), sec("root.md"),
  }, { ["lua/mod/"] = true })
  local shape = {}
  for i, e in ipairs(entries) do
    shape[i] = { e.kind, e.path }
  end
  H.eq(shape, {
    { "dir", "lua/" },
    { "dir", "lua/mod/" },
    { "file", "lua/top.lua" },
    { "file", "root.md" },
  })
  H.eq(entries[2].folded, true)
end

T["sidebar_render formats dirs, files, indent, and counts"] = function()
  local entries = sidebar.build_entries({
    sec("lua/mod/a.lua", 12, 3), sec("root.md", 0, 5),
  }, { ["lua/mod/"] = true })
  local lines = sidebar.render_lines(entries)
  H.eq(lines, {
    "▾ lua/",
    "  ▸ mod/",
    "root.md  +0 −5",
  })
end

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

-- ~55 rows per section (6 separated hunks): sections must be taller than
-- the ~22-row headless window or topline restores would clamp and the
-- scroll-targeting assertions below would silently test the wrong section.
local function big_section(path, tag)
  local old = bigtext(60, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 10, 60, 10 do
    lines[i] = lines[i] .. " changed"
  end
  local new = table.concat(lines, "\n")
  return model.build_section(path, old, new, "M")
end

local function open_with_sidebar()
  local secs = {
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
  }
  local st = canvas.open(secs, {})
  sidebar.close() -- reset singleton across tests
  sidebar.open(st, { width = 30 })
  return st
end

T["sidebar_win opens fixed non-focused split; canvas keeps winfixbuf off"] = function()
  local st = open_with_sidebar()
  assert(sidebar.is_open())
  local side_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= st.win and vim.api.nvim_win_get_buf(w) ~= st.buf then
      side_win = w
    end
  end
  assert(side_win, "sidebar window exists")
  H.eq(vim.api.nvim_get_current_win(), st.win, "focus stays in canvas")
  H.eq(vim.api.nvim_win_get_width(side_win), 30)
  H.eq(vim.api.nvim_get_option_value("winfixbuf", { win = side_win }), true)
  H.eq(vim.api.nvim_get_option_value("winfixwidth", { win = side_win }), true)
  H.eq(vim.api.nvim_get_option_value("winfixbuf", { win = st.win }), false,
    "canvas window must never get winfixbuf")
  sidebar.close()
  H.eq(sidebar.is_open(), false)
end

local SIDE_NS = vim.api.nvim_create_namespace("finding_myself.sidebar")

local function active_row(side_buf)
  local marks = vim.api.nvim_buf_get_extmarks(side_buf, SIDE_NS, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    if m[4] and m[4].line_hl_group == "FmSidebarActive" then
      return m[2]
    end
  end
  return nil
end

local function sidebar_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find("finding%-myself://sidebar") then
      return b
    end
  end
end

T["sidebar_win sync tracks the section under the canvas topline"] = function()
  local st = open_with_sidebar()
  local sbuf = sidebar_buf()
  -- canvas.open() reuses the same window+buffer pair across tests (as
  -- test_canvas.lua's suite already relies on), and Neovim restores that
  -- window's last view for a buffer it previously displayed -- so an
  -- earlier test's scroll would otherwise leak in here. Pin the view
  -- explicitly, as every other test in this suite that cares about a
  -- specific topline already does.
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  sidebar.sync(st)
  -- entries: a/(0) one.txt(1) b/(2) two.txt(3) c/(4) three.txt(5) -> rows 0..5
  H.eq(active_row(sbuf), 1, "first file active at top")

  local b_start = (canvas.section_rows(st, 2))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = b_start + 2, lnum = b_start + 2 })
  end)
  sidebar.sync(st)
  H.eq(active_row(sbuf), 3, "second file active after scroll")
  sidebar.close()
end

T["sidebar_win select on a file scrolls the canvas, never refocuses"] = function()
  local st = open_with_sidebar()
  local sbuf = sidebar_buf()
  local side_win = vim.fn.bufwinid(sbuf)
  vim.api.nvim_win_set_cursor(side_win, { 6, 0 }) -- c/three.txt row (1-based 6)
  local focused_before = vim.api.nvim_get_current_win()
  sidebar.select(st)
  local c_start = (canvas.section_rows(st, 3))
  local top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, c_start + 1, "canvas scrolled to the selected section")
  H.eq(vim.api.nvim_win_get_buf(st.win), st.buf, "canvas window buffer untouched")
  H.eq(vim.api.nvim_get_current_win(), focused_before, "focus unchanged")
  sidebar.close()
end

T["sidebar_win select on a dir folds it and active falls back to the dir"] = function()
  local st = open_with_sidebar()
  local sbuf = sidebar_buf()
  local side_win = vim.fn.bufwinid(sbuf)
  vim.api.nvim_win_set_cursor(side_win, { 1, 0 }) -- a/ dir row
  sidebar.select(st)
  local lines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
  H.eq(lines[1], "▸ a/", "dir folded")
  H.eq(#lines, 5, "a/one.txt hidden")
  -- canvas still at top (section 1 = a/one.txt, now folded away): active
  -- falls back to the deepest visible ancestor dir
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  sidebar.sync(st)
  H.eq(active_row(sbuf), 0, "folded ancestor dir is the active entry")
  sidebar.close()
end

T["sidebar_win manual :close of the sidebar window clears the singleton"] = function()
  local st = open_with_sidebar()
  local sbuf = sidebar_buf()
  local side_win = vim.fn.bufwinid(sbuf)
  vim.api.nvim_win_close(side_win, true)
  H.eq(sidebar.is_open(), false, "WinClosed cleaned up")
  -- and everything stays nil-safe afterwards
  sidebar.refresh(st)
  sidebar.sync(st)
end

T["sidebar_win reopen rebinds callbacks to the new state"] = function()
  local st1 = open_with_sidebar()
  local win_a = st1.win
  local top_a_before = vim.api.nvim_win_call(win_a, function() return vim.fn.line("w0") end)

  -- A second canvas.open() that reuses the SAME window would make st1 and
  -- st2 indistinguishable by win/buf, and (worse) Neovim reuses extmark ids
  -- after a clear_namespace, so st1's now-stale anchor_ids would coincidentally
  -- alias onto st2's freshly created anchors -- a false-positive pass that
  -- proves nothing. Force st2 into a genuinely different window so the
  -- rebind is the only thing that can make this test pass.
  vim.api.nvim_set_current_win(win_a)
  vim.cmd("vsplit")
  local win_b = vim.api.nvim_get_current_win()
  local secs = { big_section("x/new.txt", "x"), big_section("y/other.txt", "y") }
  local canvas_mod = require("finding_myself.canvas")
  local st2 = canvas_mod.open(secs, {})
  H.eq(st2.win, win_b, "sanity: st2 opened in the new window, not win_a")

  sidebar.open(st2, { width = 30 }) -- idempotent branch: refresh + rebind
  local sbuf = sidebar_buf()
  local side_win = vim.fn.bufwinid(sbuf)
  vim.api.nvim_win_set_cursor(side_win, { 4, 0 }) -- y/other.txt row
  vim.api.nvim_set_current_win(side_win)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

  local top_b = vim.api.nvim_win_call(win_b, function() return vim.fn.line("w0") end)
  H.eq(top_b, (canvas_mod.section_rows(st2, 2)) + 1, "keymap scrolled the NEW state's window")
  local top_a_after = vim.api.nvim_win_call(win_a, function() return vim.fn.line("w0") end)
  H.eq(top_a_after, top_a_before, "old canvas window must be untouched by the rebound keymap")

  sidebar.close()
end

T["sidebar_win select survives a dead canvas window"] = function()
  local st = open_with_sidebar()
  local sbuf = sidebar_buf()
  local side_win = vim.fn.bufwinid(sbuf)
  -- Keep a third, plain window alive so that (a) closing st.win below never
  -- makes the sidebar the tabpage's last window, and (b) sidebar.close()'s
  -- own window-close never hits "last window" either -- leaving a clean,
  -- non-winfixbuf window behind for whatever test runs next.
  vim.api.nvim_set_current_win(st.win)
  vim.cmd("split")
  -- kill the canvas window out from under the sidebar (not via close())
  vim.api.nvim_win_close(st.win, true)
  vim.api.nvim_win_set_cursor(side_win, { 2, 0 }) -- a file row
  local ok, err = pcall(sidebar.select, st)
  H.eq(ok, true, "select must not throw on a dead canvas window: " .. tostring(err))
  sidebar.close()
end

T["sidebar_cycle moves canvas by sections and wraps"] = function()
  local st = open_with_sidebar()
  local sbuf = sidebar_buf()
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)

  sidebar.cycle(st, 1)
  local top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 2)) + 1, "moved to section 2")
  H.eq(active_row(sbuf), 3, "sidebar followed")

  sidebar.cycle(st, 1)
  sidebar.cycle(st, 1) -- wraps past the last section
  top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 1)) + 1, "wrapped to section 1")

  sidebar.cycle(st, -1) -- wraps backwards
  top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 3)) + 1, "wrapped to last section")
  sidebar.close()
end

T["sidebar_cycle works without a sidebar open"] = function()
  local secs = { big_section("a/one.txt", "a"), big_section("b/two.txt", "b") }
  local st = canvas.open(secs, {})
  sidebar.close()
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  sidebar.cycle(st, 1)
  local top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 2)) + 1)
end

T["sidebar_integration reconcile refreshes the tree"] = function()
  local watch = require("finding_myself.watch")
  local root = H.git_fixture({
    committed = { ["m/a.txt"] = bigtext(40, "a") },
    worktree = { ["m/a.txt"] = (bigtext(40, "a"):gsub("a line 5", "a line 5 X")) },
  })
  local st = canvas.open(require("finding_myself.model").build(
    require("finding_myself.collect").files(root), 3), {})
  st.root = root
  sidebar.close()
  sidebar.open(st, { width = 30 })
  local sbuf = sidebar_buf()
  H.eq(#vim.api.nvim_buf_get_lines(sbuf, 0, -1, false), 2, "dir + one file")

  local abs = vim.fs.joinpath(root, "m", "b.txt")
  local f = assert(io.open(abs, "w")); f:write("new\n"); f:close()
  watch.reconcile(st)

  local lines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
  H.eq(#lines, 3, "new file appears in the sidebar after reconcile")
  assert(lines[3]:find("b.txt", 1, true), "b.txt rendered: " .. lines[3])
  sidebar.close()
end

return T
