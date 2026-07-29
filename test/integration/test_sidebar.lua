local H = require("helpers")
local sidebar = require("canvasdiff.ui").sidebar
local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")
local render = require("canvasdiff.canvas").format
local runtime = require("canvasdiff.runtime")
local virt = runtime.virtualizer
local motions = require("canvasdiff.input").motions

local T = {}

local function sec(path, adds, dels)
  return { path = path, adds = adds or 1, dels = dels or 0 }
end

T["sidebar_entries flat root files need no dir rows"] = function()
  local entries = sidebar.build_entries({ sec("a.txt"), sec("b.txt") }, {})
  H.eq(#entries, 2)
  H.eq(entries[1], { kind = "file", path = "a.txt", name = "a.txt", depth = 0,
    section_i = 1, adds = 1, dels = 0, aside = false, stale = false })
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

T["sidebar_entries a user-folded file is flagged"] = function()
  local entries = sidebar.build_entries(
    { sec("a.txt"), sec("b.txt") }, {}, { ["b.txt"] = true })
  H.eq(entries[1].aside, false, "a.txt is in play")
  H.eq(entries[2].aside, true, "b.txt is folded")
  H.eq(sidebar.build_entries({ sec("a.txt") }, {})[1].aside, false,
    "omitting the set means nothing is folded")
end

T["sidebar_entries a stale file is flagged, and so is the folded dir above it"] = function()
  local secs = { sec("src/a.txt"), sec("src/b.txt"), sec("top.md") }
  local entries = sidebar.build_entries(secs, {}, {}, { ["src/a.txt"] = true })
  H.eq(entries[1].kind, "dir")
  H.eq(entries[1].stale, false,
    "an OPEN dir says nothing -- its own rows carry the marker, so repeating it is noise")
  H.eq(entries[2].stale, true, "src/a.txt changed since it was folded")
  H.eq(entries[3].stale, false, "src/b.txt did not")

  -- Folded: the children emit no rows at all, so the dir row is the only place the
  -- signal can appear.
  local folded = sidebar.build_entries(secs, { ["src/"] = true }, {}, { ["src/a.txt"] = true })
  H.eq(folded[1].kind, "dir")
  H.eq(folded[1].stale, true, "something under the folded dir changed")
  H.eq(folded[2].path, "top.md", "sanity: the children really are hidden")
  H.eq(folded[2].stale, false)

  H.eq(sidebar.build_entries({ sec("a.txt") }, {})[1].stale, false,
    "omitting the set means nothing is stale")
end

T["sidebar_render marks a stale file and a stale folded dir"] = function()
  local secs = { sec("src/a.lua", 1, 2), sec("root.md", 0, 5) }
  H.eq(sidebar.render_lines(sidebar.build_entries(secs, {}, {}, { ["src/a.lua"] = true })), {
    "▾ src/",
    "    a.lua  +1 −2 ●",
    "  root.md  +0 −5",
  }, "the marker trails the counts, leaving the ▸ gutter alone")

  H.eq(sidebar.render_lines(sidebar.build_entries(
    secs, { ["src/"] = true }, {}, { ["src/a.lua"] = true })), {
    "▸ src/ ●",
    "  root.md  +0 −5",
  }, "a folded dir reports that something under it moved on")
end

T["sidebar_render marks user-folded files with the placeholder glyph"] = function()
  local lines = sidebar.render_lines(sidebar.build_entries(
    { sec("lua/a.lua", 1, 2), sec("root.md", 0, 5) }, {}, { ["root.md"] = true }))
  H.eq(lines, {
    "▾ lua/",
    "    a.lua  +1 −2",
    "▸ root.md  +0 −5",
  }, "the same ▸ that marks a folded dir and a collapsed section in the canvas")
end

T["sidebar_render escapes control bytes without changing entry identity"] = function()
  local path = "dir\t/\nfile.txt"
  local entries = sidebar.build_entries({ sec(path, 2, 1) }, {})
  H.eq(entries[2].path, path, "navigation retains the raw git path")
  H.eq(sidebar.render_lines(entries), {
    "▾ dir\\t/",
    "    \\nfile.txt  +2 −1",
  }, "a path component can never split or tab-align a sidebar row")
end

-- STALE and STAGED are the SAME character (`●`), so a staged file that has since
-- changed behind a fold renders `● ●` and the highlight is the only thing telling
-- the two apart. That makes the span arithmetic load-bearing rather than cosmetic:
-- a span one glyph out of place does not look broken, it silently reports the wrong
-- fact about the file. These assert each span lands on the right OCCURRENCE, not
-- merely on a character that happens to match.
T["sidebar_render marker spans colour the right ● in a staged-and-stale row"] = function()
  local s = sec("a.txt", 2, 2)
  s.staged = "M" -- staged only: worktree matches the index, so no `○`
  local entries = sidebar.build_entries({ s }, {}, { ["a.txt"] = true }, { ["a.txt"] = true })
  local line = sidebar.render_lines(entries)[1]
  H.eq(line, "▸ a.txt  +2 −2 ● ●", "sanity: two identical glyphs, staged then stale")

  local spans = render.marker_spans(line, s.staged, s.unstaged, true)
  -- 3, not 2: the stale marker gets a colour span AND a bold span over the same range,
  -- so it stays distinguishable from the identically-shaped staged marker whatever the
  -- colourscheme does. Measured: those two groups are 138 luminance apart under
  -- tokyonight and 23 under Neovim's builtin, where DiagnosticError is a pale salmon.
  H.eq(#spans, 3, "staged, stale colour, stale emphasis -- and none for the absent ○")

  local at = {}
  for _, sp in ipairs(spans) do
    at[sp[3]] = { col = sp[1], text = line:sub(sp[1] + 1, sp[2]) }
  end
  H.eq(at.CanvasDiffStaged.text, render.glyphs.staged, "the staged span covers exactly one ●")
  H.eq(at.CanvasDiffStale.text, render.glyphs.stale, "the stale span covers the space and its ●")
  H.eq(at.CanvasDiffStaleEmphasis.text, render.glyphs.stale,
    "and the bold layer covers exactly the same range as the colour")
  H.eq(at.CanvasDiffStaleEmphasis.col, at.CanvasDiffStale.col,
    "same start too -- a bold layer offset from its colour would be worse than none")
  assert(at.CanvasDiffStaged.col ~= at.CanvasDiffStale.col,
    "the two spans must not point at the SAME ● -- that is the whole failure mode")
  assert(at.CanvasDiffStaged.col < at.CanvasDiffStale.col,
    "staged is appended before stale, so its span sits to the left")
  -- The stale span must reach the end of the line; anything shorter means the
  -- trailing ● is uncoloured and reads as a second staged marker.
  H.eq(spans[1][2], #line, "the last span ends at end-of-line")
end

T["sidebar_render marker spans handle every combination of the three facts"] = function()
  local function row(staged, unstaged, stale)
    local s = sec("a.txt", 2, 2)
    s.staged, s.unstaged = staged, unstaged
    local entries = sidebar.build_entries(
      { s }, {}, {}, stale and { ["a.txt"] = true } or {})
    local line = sidebar.render_lines(entries)[1]
    local got = {}
    for _, sp in ipairs(render.marker_spans(line, staged, unstaged, stale)) do
      got[#got + 1] = sp[3]:gsub("^CanvasDiff", "") .. "=" .. line:sub(sp[1] + 1, sp[2])
    end
    table.sort(got)
    return line, table.concat(got, " ")
  end

  local line, got = row("M", "M", true)
  H.eq(line, "  a.txt  +2 −2 ●○ ●")
  H.eq(got, "Staged=● Stale= ● StaleEmphasis= ● Unstaged=○")

  line, got = row("M", "M", false)
  H.eq(line, "  a.txt  +2 −2 ●○")
  H.eq(got, "Staged=● Unstaged=○")

  line, got = row(nil, "M", true)
  H.eq(line, "  a.txt  +2 −2 ○ ●")
  H.eq(got, "Stale= ● StaleEmphasis= ● Unstaged=○",
    "no staged span when the index column is empty")

  line, got = row(nil, nil, false)
  H.eq(line, "  a.txt  +2 −2")
  H.eq(got, "", "a file with no status information gets no spans at all")
end

-- Dir rows carry only staleness; their stage columns are passed as nil regardless of
-- what the entry holds, so a span can never land on the directory name.
T["sidebar_render a stale dir row gets exactly one span, over its marker"] = function()
  local s = sec("src/a.txt", 2, 2)
  s.staged, s.unstaged = "M", "M"
  local entries = sidebar.build_entries(
    { s }, { ["src/"] = true }, {}, { ["src/a.txt"] = true })
  local line = sidebar.render_lines(entries)[1]
  H.eq(line, "▸ src/ ●", "the dir reports that something under it moved on")
  local spans = render.marker_spans(line, nil, nil, true)
  H.eq(#spans, 2, "the colour span and its bold layer")
  for _, sp in ipairs(spans) do
    H.eq(line:sub(sp[1] + 1, sp[2]), render.glyphs.stale, "both cover exactly the marker")
  end
  H.eq(spans[1][3], "CanvasDiffStale")
  H.eq(spans[2][3], "CanvasDiffStaleEmphasis")
end

T["sidebar_render formats dirs, files, indent, and counts"] = function()
  local entries = sidebar.build_entries({
    sec("lua/mod/a.lua", 12, 3), sec("root.md", 0, 5),
  }, { ["lua/mod/"] = true })
  local lines = sidebar.render_lines(entries)
  H.eq(lines, {
    "▾ lua/",
    "  ▸ mod/",
    "  root.md  +0 −5",
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
  local lease = assert(sidebar.open(st, { width = 30 }))
  return st, lease
end

T["sidebar_win opens fixed non-focused split; canvas keeps winfixbuf off"] = function()
  local st, lease = open_with_sidebar()
  assert(sidebar.is_open(lease))
  local side_win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if sidebar.is_sidebar_win(lease, w) then side_win = w end
  end
  assert(side_win, "sidebar window exists")
  H.eq(vim.api.nvim_get_current_win(), st.win, "focus stays in canvas")
  H.eq(vim.api.nvim_win_get_width(side_win), 30)
  H.eq(vim.api.nvim_get_option_value("winfixbuf", { win = side_win }), true)
  H.eq(vim.api.nvim_get_option_value("winfixwidth", { win = side_win }), true)
  H.eq(vim.api.nvim_get_option_value("winfixbuf", { win = st.win }), false,
    "canvas window must never get winfixbuf")
  sidebar.close(lease)
  H.eq(sidebar.is_open(lease), false)
end

local SIDE_NS = vim.api.nvim_create_namespace("canvasdiff.sidebar")

local function active_row(side_buf)
  local marks = vim.api.nvim_buf_get_extmarks(side_buf, SIDE_NS, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    if m[4] and m[4].line_hl_group == "CanvasDiffSidebarActive" then
      return m[2]
    end
  end
  return nil
end

local function sidebar_win(lease, tab)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab or 0)) do
    if sidebar.is_sidebar_win(lease, win) then
      return win
    end
  end
end

local function sidebar_buf(lease, tab)
  local win = sidebar_win(lease, tab)
  return win and vim.api.nvim_win_get_buf(win) or nil
end

T["sidebar_win sync tracks the section under the canvas topline"] = function()
  local st, lease = open_with_sidebar()
  local sbuf = sidebar_buf(lease)
  -- canvas.open() reuses the same window+buffer pair across tests (as
  -- test_canvas.lua's suite already relies on), and Neovim restores that
  -- window's last view for a buffer it previously displayed -- so an
  -- earlier test's scroll would otherwise leak in here. Pin the view
  -- explicitly, as every other test in this suite that cares about a
  -- specific topline already does.
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  sidebar.sync(lease)
  -- entries: a/(0) one.txt(1) b/(2) two.txt(3) c/(4) three.txt(5) -> rows 0..5
  H.eq(active_row(sbuf), 1, "first file active at top")

  local b_start = (canvas.section_rows(st, 2))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = b_start + 2, lnum = b_start + 2 })
  end)
  sidebar.sync(lease)
  H.eq(active_row(sbuf), 3, "second file active after scroll")
  sidebar.close(lease)
end

T["sidebar_win select on a file scrolls the canvas, never refocuses"] = function()
  local st, lease = open_with_sidebar()
  local sbuf = sidebar_buf(lease)
  local side_win = sidebar_win(lease)
  vim.api.nvim_win_set_cursor(side_win, { 6, 0 }) -- c/three.txt row (1-based 6)
  local focused_before = vim.api.nvim_get_current_win()
  sidebar.select(lease)
  local c_start = (canvas.section_rows(st, 3))
  local top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, c_start + 1, "canvas scrolled to the selected section")
  H.eq(vim.api.nvim_win_get_buf(st.win), st.buf, "canvas window buffer untouched")
  H.eq(vim.api.nvim_get_current_win(), focused_before, "focus unchanged")
  sidebar.close(lease)
end

T["sidebar_win select on a dir folds it and active falls back to the dir"] = function()
  local st, lease = open_with_sidebar()
  local sbuf = sidebar_buf(lease)
  local side_win = sidebar_win(lease)
  vim.api.nvim_win_set_cursor(side_win, { 1, 0 }) -- a/ dir row
  sidebar.select(lease)
  local lines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
  H.eq(lines[1], "▸ a/", "dir folded")
  H.eq(#lines, 5, "a/one.txt hidden")
  -- canvas still at top (section 1 = a/one.txt, now folded away): active
  -- falls back to the deepest visible ancestor dir
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  sidebar.sync(lease)
  H.eq(active_row(sbuf), 0, "folded ancestor dir is the active entry")
  sidebar.close(lease)
end

T["sidebar_win manual :close removes its view without stranding the lease"] = function()
  local _, lease = open_with_sidebar()
  local side_win = sidebar_win(lease)
  vim.api.nvim_win_close(side_win, true)
  H.eq(sidebar.is_open(lease), false, "WinClosed cleaned up")
  -- and everything stays nil-safe afterwards
  sidebar.refresh(lease)
  sidebar.sync(lease)
  sidebar.close(lease)
end

T["sidebar_win reopen rebinds callbacks to the new state"] = function()
  local st1, lease1 = open_with_sidebar()
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
  local canvas_mod = require("canvasdiff.canvas")
  local st2 = canvas_mod.open(secs, {})
  H.eq(st2.win, win_b, "sanity: st2 opened in the new window, not win_a")

  H.eq(sidebar.close(lease1), true, "replacement owner retires its exact predecessor")
  local lease2 = assert(sidebar.open(st2, { width = 30 }))
  H.eq(sidebar.is_open(lease1), false, "replacement retires the preceding exact lease")
  local sbuf = sidebar_buf(lease2)
  local side_win = sidebar_win(lease2)
  vim.api.nvim_win_set_cursor(side_win, { 4, 0 }) -- y/other.txt row
  vim.api.nvim_set_current_win(side_win)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

  local top_b = vim.api.nvim_win_call(win_b, function() return vim.fn.line("w0") end)
  H.eq(top_b, (canvas_mod.section_rows(st2, 2)) + 1, "keymap scrolled the NEW state's window")
  local top_a_after = vim.api.nvim_win_call(win_a, function() return vim.fn.line("w0") end)
  H.eq(top_a_after, top_a_before, "old canvas window must be untouched by the rebound keymap")

  sidebar.close(lease2)
end

T["sidebar_win select survives a dead canvas window"] = function()
  local st, lease = open_with_sidebar()
  local side_win = sidebar_win(lease)
  -- Keep a third, plain window alive so that (a) closing st.win below never
  -- makes the sidebar the tabpage's last window, and (b) sidebar.close()'s
  -- own window-close never hits "last window" either -- leaving a clean,
  -- non-winfixbuf window behind for whatever test runs next.
  vim.api.nvim_set_current_win(st.win)
  vim.cmd("split")
  -- kill the canvas window out from under the sidebar (not via close())
  vim.api.nvim_win_close(st.win, true)
  vim.api.nvim_win_set_cursor(side_win, { 2, 0 }) -- a file row
  local ok, err = pcall(sidebar.select, lease)
  H.eq(ok, true, "select must not throw on a dead canvas window: " .. tostring(err))
  sidebar.close(lease)
end

T["sidebar_cycle moves canvas by sections and wraps"] = function()
  local st, lease = open_with_sidebar()
  local sbuf = sidebar_buf(lease)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)

  motions.cycle(st, st.win, 1)
  sidebar.sync(lease)
  local top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 2)) + 1, "moved to section 2")
  H.eq(active_row(sbuf), 3, "sidebar followed")

  motions.cycle(st, st.win, 1)
  sidebar.sync(lease)
  motions.cycle(st, st.win, 1) -- wraps past the last section
  sidebar.sync(lease)
  top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 1)) + 1, "wrapped to section 1")

  motions.cycle(st, st.win, -1) -- wraps backwards
  sidebar.sync(lease)
  top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 3)) + 1, "wrapped to last section")
  sidebar.close(lease)
end

T["sidebar_cycle works without a sidebar open"] = function()
  local secs = { big_section("a/one.txt", "a"), big_section("b/two.txt", "b") }
  local st = canvas.open(secs, {})
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  motions.cycle(st, st.win, 1)
  local top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 2)) + 1)
end

T["sidebar_integration reconcile refreshes the tree"] = function()
  local watch = runtime.watch
  local root = H.git_fixture({
    committed = { ["m/a.txt"] = bigtext(40, "a") },
    worktree = { ["m/a.txt"] = (bigtext(40, "a"):gsub("a line 5", "a line 5 X")) },
  })
  local st = canvas.open(require("canvasdiff.diff").build(
    require("canvasdiff.source").files(root), 3), {})
  st.root = root
  local lease = assert(sidebar.open(st, { width = 30 }))
  local sbuf = sidebar_buf(lease)
  H.eq(#vim.api.nvim_buf_get_lines(sbuf, 0, -1, false), 2, "dir + one file")

  local abs = vim.fs.joinpath(root, "m", "b.txt")
  local f = assert(io.open(abs, "w")); f:write("new\n"); f:close()
  local ok, result = watch.reconcile(st, {
    on_change = function(state)
      H.eq(state, st)
      sidebar.refresh(lease)
    end,
  })
  H.eq(ok, true)
  H.eq(result.empty, false)

  local lines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
  H.eq(#lines, 3, "new file appears in the sidebar after reconcile")
  assert(lines[3]:find("b.txt", 1, true), "b.txt rendered: " .. lines[3])
  sidebar.close(lease)
end

-- --- Final-review regression tests: window-lifecycle traps -------------

T["sidebar_win is_sidebar_win identifies only the live sidebar window"] = function()
  local st, lease = open_with_sidebar()
  local side_win = sidebar_win(lease)
  H.eq(sidebar.is_sidebar_win(lease, side_win), true)
  H.eq(sidebar.is_sidebar_win(lease, st.win), false)
  H.eq(sidebar.is_sidebar_win(lease, -1), false)
  sidebar.close(lease)
  H.eq(sidebar.is_sidebar_win(lease, side_win), false, "false once the sidebar is closed")
end

T["sidebar_integration toggle from inside the sidebar redirects instead of throwing E1513"] = function()
  local orig_cwd = vim.fn.getcwd()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a\n" },
    worktree = { ["a.txt"] = "A\n" },
  })
  vim.cmd("tabnew") -- isolate from whatever windows earlier tests left behind
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  local st = assert(fm.open())
  local lease = assert(st.surface.controllers.sidebar)

  local canvas_mod = require("canvasdiff.canvas")
  -- Identify the sidebar window specifically (not just "any non-canvas
  -- window"): the scrollbar float is also a non-canvas window in this
  -- tabpage now, and picking it here would set focus on a non-focusable
  -- float instead of the sidebar, defeating the point of the test.
  local side_win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if sidebar.is_sidebar_win(lease, w) then
      side_win = w
    end
  end
  assert(side_win, "sidebar window should exist after open() with sidebar enabled")
  vim.api.nvim_set_current_win(side_win)

  local ok, err = pcall(fm.toggle)
  H.eq(ok, true, "toggle from inside the sidebar must not throw E1513: " .. tostring(err))
  H.eq(sidebar.is_open(lease), false, "toggle closed the sidebar along with the canvas")
  H.eq(canvas_mod.is_canvas_buf(vim.api.nvim_get_current_buf()), false,
    "canvas closed; the focused window no longer shows it")

  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(orig_cwd)
end

T["sidebar_integration stage_cycle declines directories and mutates file rows"] = function()
  local orig_cwd = vim.fn.getcwd()
  local root = H.git_fixture({
    committed = { ["src/a.txt"] = "head\n" },
    worktree = { ["src/a.txt"] = "disk\n" },
  })
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.setup({ watch = { enabled = false }, session = { enabled = false } })
  local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("unstaged") }))
  local lease = assert(st.surface.controllers.sidebar)
  local side_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if sidebar.is_sidebar_win(lease, win) then side_win = win end
  end
  assert(side_win)
  local real_notify = vim.notify
  local messages = {}
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end
  local ok, err = xpcall(function()
    vim.api.nvim_set_current_win(side_win)
    vim.api.nvim_win_set_cursor(side_win, { 1, 0 }) -- src/
    vim.api.nvim_feedkeys(vim.keycode("s"), "x", false)
    assert(require("canvasdiff.source").changed_files(root)[1].unstaged,
      "a directory row cannot mutate its descendants")
    assert(messages[#messages].message:find("directory", 1, true),
      vim.inspect(messages))

    vim.api.nvim_win_set_cursor(side_win, { 2, 0 }) -- src/a.txt
    vim.api.nvim_feedkeys(vim.keycode("s"), "x", false)
    local file = assert(require("canvasdiff.source").changed_files(root)[1])
    assert(file.staged and not file.unstaged, vim.inspect(file))
    H.eq(st.lens.id, "staged", "sidebar follows the same App-owned lens policy")
  end, debug.traceback)
  vim.notify = real_notify
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(orig_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["sidebar_win close() recovers a stranded last-window sidebar instead of erroring"] = function()
  -- `nvim_win_close` on the last window of a NON-final tab just closes the
  -- tab (no error) -- that would silently defeat this test. `:only` instead
  -- collapses down to a single window in the session's one and only tab, so
  -- killing the canvas window genuinely leaves the sidebar as the last
  -- window in the whole editor, and close() really does hit E444.
  vim.cmd("silent only")
  local st = canvas.open({ big_section("a/one.txt", "a") }, {})
  local lease = assert(sidebar.open(st, { width = 30 }))
  H.eq(#vim.api.nvim_tabpage_list_wins(0), 2, "canvas + sidebar are the session's only two windows")

  vim.api.nvim_win_close(st.win, true) -- canvas dies; sidebar becomes the LAST window
  H.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
  local win = vim.api.nvim_tabpage_list_wins(0)[1]

  local ok, err = pcall(sidebar.close, lease)
  H.eq(ok, true, "close() on a last-window sidebar must not throw (E444): " .. tostring(err))
  H.eq(sidebar.is_open(lease), false)
  H.eq(vim.api.nvim_win_is_valid(win), true, "the stranded window survives, recovered rather than abandoned")
  H.eq(vim.api.nvim_get_option_value("winfixbuf", { win = win }), false, "winfixbuf cleared")
  local buf = vim.api.nvim_win_get_buf(win)
  H.eq(vim.api.nvim_get_option_value("modifiable", { buf = buf }), true, "usable scratch buffer left behind")
end

T["sidebar_win canvas WinClosed cleans up a stranded sidebar"] = function()
  vim.cmd("silent only")
  local st = canvas.open({ big_section("a/one.txt", "a") }, {})
  local lease = assert(sidebar.open(st, { width = 30 }))
  vim.api.nvim_set_current_win(st.win)
  vim.cmd("split") -- extra scratch split so closing the canvas isn't closing the last-but-one
  H.eq(#vim.api.nvim_tabpage_list_wins(0), 3)

  vim.api.nvim_win_close(st.win, true)
  vim.wait(100, function() return not sidebar.is_open(lease) end)
  H.eq(sidebar.is_open(lease), false, "the canvas window's WinClosed cleaned the sidebar up")
  sidebar.close(lease)
end

-- The canvas has bound <2-LeftMouse> since the scrollbar landed, but the
-- sidebar never did -- so clicking a file in the tree did nothing, which is
-- the opposite of what every file tree trains you to expect.
T["sidebar_win double-click selects, same as <CR>"] = function()
  local st, lease = open_with_sidebar()
  local sbuf = sidebar_buf(lease)
  local side_win = sidebar_win(lease)

  local dbl
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(sbuf, "n")) do
    if m.lhs == "<2-LeftMouse>" then dbl = m.callback end
  end
  assert(dbl, "the sidebar must bind <2-LeftMouse>")

  -- a file row scrolls the canvas to that section
  local file_row
  for i, e in ipairs(require("canvasdiff.ui").sidebar.build_entries(st.sections, {})) do
    if e.kind == "file" and e.section_i == #st.sections then file_row = i end
  end
  assert(file_row, "a file row for the last section")
  vim.api.nvim_win_set_cursor(side_win, { file_row, 0 })
  dbl()
  local top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") - 1 end)
  H.eq((canvas.locate(st, top)), #st.sections, "canvas scrolled to the clicked file")

  -- a dir row folds instead, exactly as <CR> does there
  local dir_row
  for i, e in ipairs(require("canvasdiff.ui").sidebar.build_entries(st.sections, {})) do
    if e.kind == "dir" then dir_row = i break end
  end
  if dir_row then
    local before = #vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
    vim.api.nvim_win_set_cursor(side_win, { dir_row, 0 })
    dbl()
    assert(#vim.api.nvim_buf_get_lines(sbuf, 0, -1, false) < before,
      "double-clicking a directory folds it rather than scrolling")
  end
  -- This test deliberately scrolls the canvas to its last section, and the
  -- canvas buffer is a name-keyed singleton that REMEMBERS its cursor across
  -- close/open. Leaving it parked at the bottom leaks into whichever test
  -- opens the canvas next. Put it back.
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  sidebar.close(lease)
end

-- --- folds drive the canvas ---------------------------------------------
--
-- Two files under one directory, so folding it affects more than one section.
-- Rows: 1 "a/", 2 one.txt, 3 two.txt, 4 "b/", 5 three.txt.
local A_DIR_ROW, B_THREE_ROW = 1, 5

local function open_ab()
  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("a/two.txt", "b"),
    big_section("b/three.txt", "c"),
  }, {})
  local lease = assert(sidebar.open(st, { width = 30 }))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  return st, lease
end

--- Click sidebar row `row` (1-based) the way <CR> does.
local function select_row(lease, row)
  vim.api.nvim_win_set_cursor(sidebar_win(lease), { row, 0 })
  sidebar.select(lease)
end

local function span(st, i)
  local s, e = canvas.section_rows(st, i)
  return e - s
end

local function canvas_top0(st)
  return vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") - 1 end)
end

--- Leave the canvas singleton where the next test expects it, then drop the
--- sidebar. Its cursor survives close/open, so a scrolled test leaks.
local function done(st, lease)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  if lease then sidebar.close(lease) end
end

T["sidebar_fold folding a dir sets its canvas sections aside"] = function()
  local st, lease = open_ab()
  select_row(lease, A_DIR_ROW)

  H.eq(span(st, 1), 1, "a/one.txt renders as its placeholder")
  H.eq(span(st, 2), 1, "a/two.txt renders as its placeholder")
  assert(span(st, 3) > 1, "b/three.txt is untouched")

  local s1 = (canvas.section_rows(st, 1))
  H.eq(vim.api.nvim_buf_get_lines(st.buf, s1, s1 + 1, false)[1],
    render.placeholder(st.sections[1]), "the buffer really holds the placeholder")

  -- The whole point of deriving visibility instead of storing it.
  H.eq(st.collapsed, {}, "folding must never write into state.collapsed")
  H.eq(st.folded, { ["a/"] = true }, "the fold lives on the shared state")
  done(st, lease)
end

T["sidebar_fold unfolding restores the exact pre-fold collapse state"] = function()
  local st, lease = open_ab()
  -- Collapse one of the two by hand FIRST, then fold their parent over it.
  canvas.set_collapsed(st, 1, true)
  select_row(lease, A_DIR_ROW)
  H.eq(span(st, 1), 1, "both are placeholders while folded")
  H.eq(span(st, 2), 1, "both are placeholders while folded")

  select_row(lease, A_DIR_ROW) -- unfold
  H.eq(span(st, 1), 1, "the hand-collapsed one stays collapsed")
  assert(span(st, 2) > 1, "the merely-folded one comes back expanded")
  H.eq(st.collapsed, { ["a/one.txt"] = "user" }, "only the hand collapse survives")
  done(st, lease)
end

T["sidebar_fold folds survive closing and reopening the sidebar"] = function()
  local st, lease = open_ab()
  select_row(lease, A_DIR_ROW)
  sidebar.close(lease)

  lease = assert(sidebar.open(st, { width = 30 }))
  local lines = vim.api.nvim_buf_get_lines(sidebar_buf(lease), 0, -1, false)
  H.eq(lines[1], "▸ a/", "the tree reopens folded")
  H.eq(#lines, 3, "a/'s two files are still hidden")
  H.eq(span(st, 1), 1, "and the canvas still shows them folded")
  done(st, lease)
end

-- Selecting is navigation, and navigation never changes fold state. It used to
-- expand first, on the theory that "take me there" implies "let me read it" -- but
-- that made Enter in the tree silently unfold, which is Tab's job on the canvas.
T["sidebar_fold select on a folded file scrolls there without unfolding"] = function()
  local st, lease = open_ab()
  canvas.set_collapsed(st, 3, true)
  H.eq(span(st, 3), 1, "folded to start with")

  select_row(lease, B_THREE_ROW)
  H.eq(span(st, 3), 1, "still folded -- selecting it does not unfold it")
  H.eq(st.collapsed, { ["b/three.txt"] = "user" }, "and the fold is untouched")
  H.eq((canvas.locate(st, canvas_top0(st))), 3, "but the canvas did scroll to it")
  done(st, lease)
end

T["sidebar_fold folding above the viewport keeps the visible top pinned"] = function()
  local st, lease = open_ab()
  local b_start = (canvas.section_rows(st, 3))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = b_start + 3, lnum = b_start + 3 })
  end)
  local before = vim.api.nvim_buf_get_lines(st.buf, canvas_top0(st), canvas_top0(st) + 1, false)[1]

  select_row(lease, A_DIR_ROW)

  -- Both halves matter. The span assertions prove the fold actually reached
  -- the canvas; the text assertion proves it did so without moving what the
  -- user was reading (niri). Either one alone passes for the wrong reason.
  H.eq(span(st, 1), 1, "the folded sections did collapse")
  H.eq(span(st, 2), 1, "the folded sections did collapse")
  H.eq(vim.api.nvim_buf_get_lines(st.buf, canvas_top0(st), canvas_top0(st) + 1, false)[1],
    before, "the line at the viewport top is unchanged")
  done(st, lease)
end

T["sidebar_fold folding the section you are reading lands on its placeholder"] = function()
  local st, lease = open_ab()
  local two_start = (canvas.section_rows(st, 2))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = two_start + 1, lnum = two_start + 1 })
  end)

  select_row(lease, A_DIR_ROW)

  local s2 = (canvas.section_rows(st, 2))
  H.eq(canvas_top0(st), s2, "viewport top sits on a/two.txt's placeholder row")
  H.eq(vim.api.nvim_buf_get_lines(st.buf, s2, s2 + 1, false)[1],
    render.placeholder(st.sections[2]), "and that row is the placeholder")
  done(st, lease)
end

T["sidebar_fold the tree marks what you folded, but not virt's own work"] = function()
  local st, side_lease = open_ab()

  -- Collapse b/three.txt by hand: its tree row should say so, otherwise ]f
  -- skips past a file with nothing on screen to explain why.
  canvas.set_collapsed(st, 3, true)
  sidebar.refresh(side_lease)
  local lines = vim.api.nvim_buf_get_lines(sidebar_buf(side_lease), 0, -1, false)
  assert(lines[B_THREE_ROW]:match("^%s*▸ three%.txt"),
    "the hand-collapsed file is marked: " .. lines[B_THREE_ROW])
  assert(lines[2]:match("^%s+one%.txt"), "the others are not: " .. lines[2])

  -- virt collapsing something is bookkeeping, not a decision the user made,
  -- so it must not churn markers across the tree on every scroll.
  canvas.set_collapsed(st, 3, false)
  local lease = virt.attach(st, { enabled = false })
  virt.apply(lease, { enabled = true, max_files = 1, max_lines = 1000000, margin = 0, max_expanded = 1 })
  assert(next(H.auto_set(st)), "sanity: virt auto-collapsed something")
  sidebar.refresh(side_lease)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(sidebar_buf(side_lease), 0, -1, false)) do
    if not line:match("/$") then -- skip dir rows, whose ▸ means "folded"
      assert(not line:match("^%s*▸"), "virt's collapses must not be marked: " .. line)
    end
  end

  virt.detach(lease)
  done(st, side_lease)
end

T["sidebar_fold cycle stops on folded sections too, and still wraps"] = function()
  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("a/two.txt", "b"),
    big_section("b/three.txt", "c"),
    big_section("c/four.txt", "d"),
  }, {})
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  st.folded = { ["a/"] = true }
  canvas.resync_visibility(st)

  local function top_section()
    return (canvas.locate(st, canvas_top0(st)))
  end
  -- Park on the last section, so one step forward has to wrap onto a FOLDED one.
  local s4 = (canvas.section_rows(st, 4))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = s4 + 1, lnum = s4 + 1 })
  end)

  motions.cycle(st, st.win, 1)
  H.eq(top_section(), 1, "wraps onto the folded a/one.txt rather than past it")
  motions.cycle(st, st.win, 1)
  H.eq(top_section(), 2, "and onto the second folded one")
  motions.cycle(st, st.win, -1)
  H.eq(top_section(), 1, "backwards lands on folded sections too")

  st.folded = {}
  canvas.resync_visibility(st)
  done(st)
end

T["sidebar_fold cycle honors a count"] = function()
  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
    big_section("d/four.txt", "d"),
  }, {})
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  motions.cycle(st, st.win, 1, 2)
  H.eq((canvas.locate(st, canvas_top0(st))), 3, "2<C-n> moves two sections")
  done(st)
end

-- The file branch has guarded against a dead canvas since it landed; the dir
-- branch splices the canvas too and never did. The sidebar outlives a wiped
-- canvas buffer (its WinClosed pattern watches state.win, not state.buf), so
-- <CR> on a dir row reached nvim_buf_get_extmark_by_id on an invalid buffer.
T["sidebar_fold select on a dir survives a wiped canvas buffer"] = function()
  local st, lease = open_ab()
  local buf = st.buf
  vim.api.nvim_win_call(st.win, function() vim.cmd("enew") end)
  vim.api.nvim_buf_delete(buf, { force = true })

  vim.api.nvim_win_set_cursor(sidebar_win(lease), { A_DIR_ROW, 0 })
  local ok, err = pcall(sidebar.select, lease)
  H.eq(ok, true, "select must not throw on a wiped canvas buffer: " .. tostring(err))
  H.eq(st.folded, {}, "and must not record a fold it could not apply")
  sidebar.close(lease)
end

T["sidebar_fold a nested fold hides only its own subtree"] = function()
  local st = canvas.open({
    big_section("lua/mod/a.lua", "a"),
    big_section("lua/modules/b.lua", "b"),
  }, {})
  local lease = assert(sidebar.open(st, { width = 30 }))
  -- rows: 1 "lua/", 2 "mod/", 3 a.lua, 4 "modules/", 5 b.lua
  select_row(lease, 2)
  H.eq(span(st, 1), 1, "lua/mod/a.lua is folded")
  assert(span(st, 2) > 1, "lua/modules/b.lua is NOT -- modules/ is not mod/")
  done(st, lease)
end

return T
