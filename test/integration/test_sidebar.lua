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

-- Hunk metadata as the model publishes it (test_model pins that shape);
-- build_entries reads section.hunks straight through, so hand-built rows are
-- the whole input a tree needs.
local function hunky()
  return {
    { path = "src/a.lua", adds = 3, dels = 1, nhunks = 2, hunks = {
        { new_lo = 3, adds = 2, dels = 1, label = "THREE", pure_del = false },
        { new_lo = 9, adds = 1, dels = 0, label = "NINE", pure_del = false } } },
    { path = "src/b.lua", adds = 0, dels = 4, nhunks = 1, hunks = {
        { new_lo = nil, adds = 0, dels = 4, label = "GONE", pure_del = true } } },
  }
end

T["sidebar_entries an unfolded file lists its hunks, a folded one summarizes them"] = function()
  local minus = render.glyphs.minus
  local entries = sidebar.build_entries(hunky(), {}, { ["src/b.lua"] = true }, {})
  local shape = {}
  for i, e in ipairs(entries) do
    shape[i] = { e.kind, e.name }
  end
  H.eq(shape, {
    { "dir", "src/" },
    { "file", "a.lua" },
    { "hunk", "@@ 3  THREE" },
    { "hunk", "@@ 9  NINE" },
    { "file", "b.lua" },
  }, "the folded file is one row here exactly as it is one row on the canvas")

  H.eq(entries[3].counts, "+2 " .. minus .. "1")
  H.eq(entries[3].path, "src/a.lua", "a hunk row names the file it belongs to")
  H.eq(entries[3].hunk, 1, "and its index into section.hunks")
  H.eq(entries[4].hunk, 2)
  H.eq(entries[3].depth, entries[2].depth + 1, "one level under its file")
  H.eq(entries[2].summary, nil, "an unfolded file summarizes nothing -- its hunks are right there")
  H.eq(entries[5].summary, "(1 hunks, +0 " .. minus .. "4)",
    "the folded one carries the count of what it hides")
end

-- A pure deletion writes no new-side line, so it has no line number to show and
-- its label is old-side text. Both facts have to survive into the row.
T["sidebar_entries a pure-deletion hunk row is labelled from the old side"] = function()
  local entries = sidebar.build_entries(hunky(), {}, {}, {})
  H.eq(entries[6].kind, "hunk")
  H.eq(entries[6].pure_del, true)
  H.eq(entries[6].name, "@@ GONE", "no new-side line, so no line number")
  H.eq(entries[6].label, "GONE", "the removed line, kept apart so rendering can strike it")
  H.eq(entries[3].pure_del, false, "an ordinary hunk is not marked")
end

T["sidebar_entries a folded dir summarizes the files it hides"] = function()
  local minus = render.glyphs.minus
  local secs = hunky()
  secs[#secs + 1] = { path = "top.md", adds = 7, dels = 7, nhunks = 1, hunks = {
    { new_lo = 1, adds = 7, dels = 7, label = "TOP", pure_del = false } } }

  local entries = sidebar.build_entries(secs, { ["src/"] = true }, {}, {})
  H.eq(entries[1].kind, "dir")
  H.eq(entries[1].summary, "(2 files, +3 " .. minus .. "5)",
    "the aggregate is what the fold HIDES, not what is left on screen")
  H.eq(entries[2].path, "top.md", "sanity: src/'s files really are hidden")
  H.eq(entries[2].summary, nil)
  H.eq(entries[3].kind, "hunk", "a file outside the fold keeps its hunk rows")
  H.eq(#entries, 3)

  H.eq(sidebar.build_entries(secs, {}, {}, {})[1].summary, nil,
    "an open dir hides nothing, so it has nothing to summarize")
end

T["sidebar_render hunk rows sit one step under their file"] = function()
  local minus = render.glyphs.minus
  local lines = sidebar.render_lines(sidebar.build_entries(hunky(), {}, {}, {}))
  H.eq(lines, {
    "▾ src/",
    "    a.lua  +3 " .. minus .. "1",
    "      @@ 3  THREE  +2 " .. minus .. "1",
    "      @@ 9  NINE  +1 " .. minus .. "0",
    "    b.lua  +0 " .. minus .. "4",
    "      @@ GONE  +0 " .. minus .. "4",
  }, "the `@@` sits inside the file name, not under it")
end

T["sidebar_render a pure-deletion hunk row is struck through the ghost group"] = function()
  local entries = sidebar.build_entries(hunky(), {}, {}, {})
  local lines, spans = sidebar.render_lines(entries)
  H.eq(spans[1], nil, "dir rows keep the groups they already had")
  H.eq(spans[2], nil, "and so do file rows")

  H.eq(spans[3], { { 0, #lines[3], "CanvasDiffSidebarHunk" } },
    "an ordinary hunk row is dimmed whole and struck nowhere")

  local del = spans[6]
  H.eq(#del, 2, "the row's own dimming, and the strike over its label")
  H.eq(del[1], { 0, #lines[6], "CanvasDiffSidebarHunk" })
  H.eq(del[2][3], "CanvasDiffSidebarHunkDel")
  H.eq(lines[6]:sub(del[2][1] + 1, del[2][2]), "GONE",
    "the strike covers the old-side text and nothing else -- not the @@, not the counts")
end

-- A label is a line of source: it arrives indented, it can be longer than the
-- window, and it can carry bytes that would tab-align or split the row.
T["sidebar_render a hunk label is trimmed, escaped and cut to the sidebar width"] = function()
  local minus = render.glyphs.minus
  local secs = { { path = "a.lua", adds = 1, dels = 0, nhunks = 1, hunks = {
    { new_lo = 7, adds = 1, dels = 0, label = "\t\treturn compute(alpha, beta)",
      pure_del = false } } } }
  local lines, spans = sidebar.render_lines(sidebar.build_entries(secs, {}, {}, {}), 30)
  H.eq(lines[1], "  a.lua  +1 " .. minus .. "0", "file rows are never cut -- a path is identity")
  H.eq(lines[2], "    @@ 7  return comput  +1 " .. minus .. "0",
    "leading indentation is dropped, and the counts survive the cut")
  H.eq(vim.fn.strdisplaywidth(lines[2]), 30,
    "the label is cut so the row fills the sidebar exactly")
  H.eq(spans[2][1], { 0, #lines[2], "CanvasDiffSidebarHunk" },
    "the span follows the row it was cut to")

  local wide = sidebar.render_lines(sidebar.build_entries(secs, {}, {}, {}), 300)
  H.eq(wide[2], "    @@ 7  return compute(alpha, beta)  +1 " .. minus .. "0",
    "given room, the whole label shows")
end

-- The strike is measured off the label, and the label is what the cut shortens.
-- Measuring it before the cut would run the span past end-of-line, which no
-- other assertion here would notice: the TEXT would still be right.
T["sidebar_render a cut pure-deletion row strikes only what is left of it"] = function()
  local label = "    self.previous_configuration = nil"
  local secs = { { path = "a.lua", adds = 0, dels = 1, nhunks = 1, hunks = {
    { new_lo = nil, adds = 0, dels = 1, label = label, pure_del = true } } } }
  local lines, spans = sidebar.render_lines(sidebar.build_entries(secs, {}, {}, {}), 30)
  local line, strike = lines[2], spans[2][2]
  local lead, tail = "    @@ ", "  +0 " .. render.glyphs.minus .. "1"
  assert(#line < #lead + #label + #tail, "sanity: the label really was cut: " .. line)

  H.eq(strike[3], "CanvasDiffSidebarHunkDel")
  H.eq(line:sub(strike[1] + 1, strike[2]), line:sub(#lead + 1, #line - #tail),
    "the strike covers the label that SURVIVED the cut, not the one that arrived")
  assert(strike[2] < #line, "so it stops short of the counts: " .. line)
end

-- A folded file is one row in BOTH windows, so the two have to say the same
-- thing -- including where counts would lie. "(0 hunks, +0 −0)" on a binary file
-- reads as "nothing changed", which is the opposite of the truth, and the canvas
-- has said "(binary)" since it landed. Asserted against render.summary itself
-- rather than a copied literal: a copy here could drift with the original and
-- still pass.
T["sidebar_render a folded file reads as its canvas placeholder does"] = function()
  local BIN = "\0\1\2binary\0content\n"
  local for_each = {
    ["src/a.lua"] = model.build_section(
      "src/a.lua", "one\ntwo\nthree\n", "one\nTWO\nthree\n", "M"),
    ["src/img.png"] = model.build_section("src/img.png", "\0old\0", BIN, "M"),
    ["src/new.zip"] = model.build_section(
      "src/new.zip", BIN, BIN, "R", 3, { old_path = "src/old.zip" }),
  }
  local shapes = {}
  for path, s in pairs(for_each) do
    assert(s, "sanity: " .. path .. " really is a section")
    local summary = render.summary(s)
    assert(render.placeholder(s):find(summary, 1, true),
      "sanity: the canvas placeholder is built from this summary: " .. summary)
    local lines = sidebar.render_lines(
      sidebar.build_entries({ s }, {}, { [path] = true }, {}))
    H.eq(#lines, 2, "the src/ row, and one row for the file -- whatever kind of file it is")
    H.eq(lines[2], "  " .. render.glyphs.folded .. " "
      .. path:match("[^/]+$") .. "  " .. summary,
      "one row, one summary, the same text in both windows")
    shapes[#shapes + 1] = summary
  end
  table.sort(shapes)
  H.eq(shapes, { "(1 hunks, +1 " .. render.glyphs.minus .. "1)", "(binary)", "(renamed)" },
    "all three shapes reached the tree -- counts, and the two cases where counts would lie")
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
    "▸ src/  (1 files, +1 −2) ●",
    "  root.md  +0 −5",
  }, "a folded dir reports what it hides -- and that something under it moved on")
end

T["sidebar_render marks user-folded files with the placeholder glyph"] = function()
  local away = sec("root.md", 0, 5)
  away.nhunks = 3
  local lines = sidebar.render_lines(sidebar.build_entries(
    { sec("lua/a.lua", 1, 2), away }, {}, { ["root.md"] = true }))
  H.eq(lines, {
    "▾ lua/",
    "    a.lua  +1 −2",
    "▸ root.md  (3 hunks, +0 −5)",
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
  s.nhunks = 2
  local entries = sidebar.build_entries({ s }, {}, { ["a.txt"] = true }, { ["a.txt"] = true })
  local line = sidebar.render_lines(entries)[1]
  H.eq(line, "▸ a.txt  (2 hunks, +2 −2) ● ●",
    "sanity: two identical glyphs, staged then stale, after the fold's own summary")

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
  H.eq(line, "▸ src/  (1 files, +2 −2) ●",
    "the dir reports what it hides, and that something under it moved on")
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
    "  ▸ mod/  (1 files, +12 −3)",
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
  H.eq(vim.api.nvim_get_option_value("winbar", { win = side_win }),
    "%#CanvasDiffWinbar#Files changed (3)  +18 −18")
  local side_buf = vim.api.nvim_win_get_buf(side_win)
  H.eq(#vim.api.nvim_buf_get_lines(side_buf, 0, -1, false), 24,
    "three dirs, three files, six hunks each -- and the title is none of them")
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

local function sidebar_winbar(lease, tab)
  return vim.api.nvim_get_option_value(
    "winbar", { win = assert(sidebar_win(lease, tab)) })
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
  -- Each file lists its six hunks, so rows 0..23 read:
  -- a/(0) one.txt(1) its hunks(2..7) b/(8) two.txt(9) its hunks(10..15)
  -- c/(16) three.txt(17) its hunks(18..23)
  H.eq(active_row(sbuf), 1, "first file active at top")

  local b_start = (canvas.section_rows(st, 2))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = b_start + 2, lnum = b_start + 2 })
  end)
  sidebar.sync(lease)
  H.eq(active_row(sbuf), 9, "second file active after scroll")
  sidebar.close(lease)
end

T["sidebar_win select on a file scrolls the canvas, never refocuses"] = function()
  local st, lease = open_with_sidebar()
  local sbuf = sidebar_buf(lease)
  local side_win = sidebar_win(lease)
  vim.api.nvim_win_set_cursor(side_win, { 18, 0 }) -- c/three.txt row (1-based 18)
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
  H.eq(sidebar_winbar(lease), "%#CanvasDiffWinbar#Files changed (3)  +18 −18")
  sidebar.select(lease)
  H.eq(sidebar_winbar(lease), "%#CanvasDiffWinbar#Files changed (3)  +18 −18",
    "folding tree rows does not change the file count")
  local lines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
  H.eq(lines[1], "▸ a/  (1 files, +6 −6)", "dir folded, and it says what it took away")
  H.eq(#lines, 17, "a/one.txt and its six hunk rows hidden")
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
  -- rows: 1 "x/", 2 new.txt, 3-8 its hunks, 9 "y/", 10 other.txt
  vim.api.nvim_win_set_cursor(side_win, { 10, 0 }) -- y/other.txt row
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
  H.eq(active_row(sbuf), 9, "sidebar followed")

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
  H.eq(sidebar_winbar(lease), "%#CanvasDiffWinbar#Files changed (1)  +1 −1")
  H.eq(#vim.api.nvim_buf_get_lines(sbuf, 0, -1, false), 3,
    "dir + one file + the one hunk it changed")

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
  H.eq(sidebar_winbar(lease), "%#CanvasDiffWinbar#Files changed (2)  +2 −1",
    "the title follows the refreshed section count and diffstat")
  H.eq(#lines, 5, "new file appears in the sidebar after reconcile, hunk row and all")
  assert(lines[4]:find("b.txt", 1, true), "b.txt rendered: " .. lines[4])
  sidebar.close(lease)
end

T["sidebar_integration title follows lens section counts"] = function()
  local orig_cwd = vim.fn.getcwd()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a0\n", ["b.txt"] = "b0\n" },
    worktree = { ["a.txt"] = "a1\n", ["b.txt"] = "b1\n" },
  })
  assert(require("canvasdiff.source").stage(root, {
    path = "b.txt", unstaged = "M",
  }))
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.setup({ watch = { enabled = false }, session = { enabled = false } })
  local ok, err = xpcall(function()
    local lenses = require("canvasdiff.diff").lens
    local st = assert(fm.open({ lens = lenses.get("unstaged") }))
    local lease = assert(st.surface.controllers.sidebar)

    H.eq(sidebar_winbar(lease), "%#CanvasDiffWinbar#Files changed (1)  +1 −1")
    assert(fm.set_lens(lenses.get("all")))
    H.eq(sidebar_winbar(lease), "%#CanvasDiffWinbar#Files changed (2)  +2 −2",
      "the title follows the newly published lens sections")
  end, debug.traceback)
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(orig_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
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

T["sidebar_win refresh preserves a foreign winbar replacement"] = function()
  local _, lease = open_with_sidebar()
  local win = assert(sidebar_win(lease))
  vim.api.nvim_set_option_value("winbar", "Foreign title", {
    win = win, scope = "local",
  })

  sidebar.refresh(lease)
  H.eq(vim.api.nvim_get_option_value("winbar", { win = win }), "Foreign title")
  sidebar.close(lease)
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

T["sidebar_integration stage and unstage decline directories and mutate file rows"] = function()
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

    vim.api.nvim_win_set_cursor(side_win, { 2, 0 }) -- src/a.txt, staged lens
    vim.api.nvim_feedkeys(vim.keycode("u"), "x", false)
    local reversed = assert(require("canvasdiff.source").changed_files(root)[1])
    assert(reversed.unstaged and not reversed.staged, vim.inspect(reversed))
    H.eq(st.lens.id, "unstaged", "u from the sidebar unstages through the same policy")
  end, debug.traceback)
  vim.notify = real_notify
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(orig_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["sidebar_integration stage routes recreated rename-source row exactly"] = function()
  local orig_cwd = vim.fn.getcwd()
  local root = H.git_fixture({ committed = { ["old.txt"] = "rename body\n" } })
  assert(vim.system({ "git", "mv", "old.txt", "new.txt" }, { cwd = root }):wait().code == 0)
  local recreated = assert(io.open(vim.fs.joinpath(root, "old.txt"), "w"))
  recreated:write("recreated\n"); recreated:close()
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.setup({ watch = { enabled = false }, session = { enabled = false } })
  local st = assert(fm.open())
  local lease = assert(st.surface.controllers.sidebar)
  local side_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if sidebar.is_sidebar_win(lease, win) then side_win = win end
  end
  assert(side_win)
  local ok, err = xpcall(function()
    vim.api.nvim_set_current_win(side_win)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(side_win), 0, -1, false)
    local row
    for i, line in ipairs(lines) do
      if line:find("old.txt", 1, true) and not line:find("→", 1, true) then row = i end
    end
    assert(row, "the recreated untracked source has its own visible sidebar row")
    vim.api.nvim_win_set_cursor(side_win, { row, 0 })
    vim.api.nvim_feedkeys(vim.keycode("s"), "x", false)
    local by = {}
    for _, file in ipairs(require("canvasdiff.source").changed_files(root)) do
      by[file.path] = file
    end
    assert(by["new.txt"] and by["new.txt"].staged,
      "the selected old row must not unstage the rename destination")
    assert(by["old.txt"] and by["old.txt"].staged,
      "the selected recreated source itself is staged")
  end, debug.traceback)
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
  vim.api.nvim_set_option_value("winbar", "Host title", {
    win = st.win, scope = "local",
  })
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
  H.eq(vim.api.nvim_get_option_value("winbar", { win = win }), "",
    "the replacement scratch keeps its own winbar once the installed title is no longer live")
  local buf = vim.api.nvim_win_get_buf(win)
  H.eq(vim.api.nvim_get_option_value("modifiable", { buf = buf }), true, "usable scratch buffer left behind")
end

T["sidebar_win lifecycle creation aborts after BufWinEnter steals the buffer"] = function()
  vim.cmd("silent only")
  local st = canvas.open({ big_section("a/one.txt", "a") }, {})
  local foreign = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(
    foreign, "canvasdiff-test://sidebar-create-foreign/" .. tostring(vim.uv.hrtime()))
  vim.api.nvim_buf_set_lines(foreign, 0, -1, false, { "foreign content" })
  local invaded_win
  local group = vim.api.nvim_create_augroup(
    "canvasdiff.test.sidebar.create." .. tostring(vim.uv.hrtime()), { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    pattern = "canvasdiff://sidebar/*",
    once = true,
    callback = function(event)
      local win = vim.fn.bufwinid(event.buf)
      assert(win ~= -1, "the new sidebar buffer is displayed during BufWinEnter")
      invaded_win = win
      vim.api.nvim_set_option_value("bufhidden", "hide", { buf = event.buf })
      vim.api.nvim_win_set_buf(win, foreign)
      vim.api.nvim_set_option_value("winbar", "Foreign title", {
        win = win, scope = "local",
      })
      vim.api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
    end,
  })

  local ok, result = pcall(sidebar.open, st, { width = 30 })
  pcall(vim.api.nvim_del_augroup_by_id, group)
  local observed = {
    opened = ok,
    buffer = invaded_win and vim.api.nvim_win_get_buf(invaded_win) or nil,
    winbar = invaded_win
      and vim.api.nvim_get_option_value("winbar", { win = invaded_win })
      or nil,
    wrap = invaded_win
      and vim.api.nvim_get_option_value("wrap", { win = invaded_win })
      or nil,
  }
  if ok then
    pcall(sidebar.close, result)
  end
  if invaded_win and vim.api.nvim_win_is_valid(invaded_win) then
    pcall(vim.api.nvim_win_close, invaded_win, true)
  end
  if vim.api.nvim_buf_is_valid(foreign) then
    vim.api.nvim_buf_delete(foreign, { force = true })
  end

  H.eq(observed, {
    opened = false,
    buffer = foreign,
    winbar = "Foreign title",
    wrap = true,
  }, "open aborts fail-closed without claiming or mutating the foreign pair")
end

T["sidebar_win lifecycle teardown preserves a BufEnter winbar replacement"] = function()
  vim.cmd("silent only")
  local st = canvas.open({ big_section("a/one.txt", "a") }, {})
  vim.api.nvim_set_option_value("winbar", "Host title", {
    win = st.win, scope = "local",
  })
  local lease = assert(sidebar.open(st, { width = 30 }))
  vim.api.nvim_win_close(st.win, true)
  local win = vim.api.nvim_tabpage_list_wins(0)[1]
  local group = vim.api.nvim_create_augroup(
    "canvasdiff.test.sidebar.close-title." .. tostring(vim.uv.hrtime()), { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    once = true,
    callback = function()
      vim.api.nvim_set_option_value("winbar", "Foreign title", {
        win = win, scope = "local",
      })
    end,
  })

  sidebar.close(lease)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  local actual = vim.api.nvim_get_option_value("winbar", { win = win })
  vim.api.nvim_set_option_value("winbar", "", { win = win, scope = "local" })

  H.eq(actual, "Foreign title",
    "teardown does not replay a stale CanvasDiff title over a BufEnter replacement")
end

T["sidebar_win lifecycle teardown preserves a BufEnter buffer replacement"] = function()
  vim.cmd("silent only")
  local st = canvas.open({ big_section("a/one.txt", "a") }, {})
  vim.api.nvim_set_option_value("winbar", "Host title", {
    win = st.win, scope = "local",
  })
  local lease = assert(sidebar.open(st, { width = 30 }))
  vim.api.nvim_win_close(st.win, true)
  local win = vim.api.nvim_tabpage_list_wins(0)[1]
  local foreign = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(
    foreign, "canvasdiff-test://sidebar-close-foreign/" .. tostring(vim.uv.hrtime()))
  vim.api.nvim_buf_set_lines(foreign, 0, -1, false, { "foreign content" })
  local fired = false
  local group = vim.api.nvim_create_augroup(
    "canvasdiff.test.sidebar.close-buffer." .. tostring(vim.uv.hrtime()), { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function()
      if fired then
        return
      end
      fired = true
      vim.api.nvim_win_set_buf(win, foreign)
      vim.api.nvim_set_option_value("winbar", "Foreign title", {
        win = win, scope = "local",
      })
    end,
  })

  sidebar.close(lease)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  local observed = {
    buffer = vim.api.nvim_win_get_buf(win),
    lines = vim.api.nvim_buf_get_lines(foreign, 0, -1, false),
    winbar = vim.api.nvim_get_option_value("winbar", { win = win }),
  }
  local scratch = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, scratch)
  if vim.api.nvim_buf_is_valid(foreign) then
    vim.api.nvim_buf_delete(foreign, { force = true })
  end

  H.eq(observed, {
    buffer = foreign,
    lines = { "foreign content" },
    winbar = "Foreign title",
  }, "teardown stops restoring once BufEnter replaces the expected scratch")
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
-- Every file lists its six hunks, so the rows are:
--   1 "a/", 2 one.txt, 3-8 its hunks, 9 two.txt, 10-15 its hunks,
--   16 "b/", 17 three.txt, 18-23 its hunks.
local A_DIR_ROW, B_THREE_ROW = 1, 17

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
  H.eq(lines[1], "▸ a/  (2 files, +12 −12)", "the tree reopens folded")
  H.eq(#lines, 9, "a/'s two files, and their hunk rows, are still hidden")
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

--- How many `@@` rows the live tree is showing.
local function tree_hunks(lease)
  local n = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(sidebar_buf(lease), 0, -1, false)) do
    if line:find("@@", 1, true) then
      n = n + 1
    end
  end
  return n
end

-- The governing rule: the tree mirrors the canvas, and only the USER moves it.
-- Auto-collapses happen while you scroll -- if they took hunk rows away, every
-- scroll would reflow the tree under the cursor.
T["sidebar_fold hunk rows follow your folds, never virt's own collapses"] = function()
  local st, side_lease = open_ab()
  H.eq(tree_hunks(side_lease), 18, "sanity: three files, six hunks each")

  canvas.set_collapsed(st, 3, true)
  sidebar.refresh(side_lease)
  H.eq(tree_hunks(side_lease), 12, "a file you fold takes its hunk rows with it")

  canvas.set_collapsed(st, 3, false)
  local lease = virt.attach(st, { enabled = false })
  virt.apply(lease, { enabled = true, max_files = 1, max_lines = 1000000, margin = 0, max_expanded = 1 })
  assert(next(H.auto_set(st)), "sanity: virt auto-collapsed something")
  sidebar.refresh(side_lease)
  H.eq(tree_hunks(side_lease), 18,
    "virt's collapses are its own bookkeeping: the tree must not ripple under them")

  virt.detach(lease)
  done(st, side_lease)
end

T["sidebar_fold a folded dir hides its hunk rows and counts what it hid"] = function()
  local st, lease = open_ab()
  select_row(lease, A_DIR_ROW)
  local lines = vim.api.nvim_buf_get_lines(sidebar_buf(lease), 0, -1, false)
  H.eq(lines[1], "▸ a/  (2 files, +12 " .. render.glyphs.minus .. "12)",
    "the fold reports the two files and the churn it put away")
  H.eq(tree_hunks(lease), 6, "only b/three.txt's hunks are left")
  done(st, lease)
end

T["sidebar_fold hunk rows carry the dim group, and a deletion the ghost"] = function()
  local st = canvas.open({
    model.build_section("a.lua", "one\ntwo\nthree\n", "one\nTWO\nthree\n", "M"),
    model.build_section("b.lua", "keep\nGONE\nkeep2\n", "keep\nkeep2\n", "M"),
  }, {})
  local lease = assert(sidebar.open(st, { width = 30 }))
  H.eq(vim.api.nvim_get_hl(0, { name = "CanvasDiffSidebarHunk" }).link, "Comment",
    "one step dimmer than the file rows, on the canvas's own de-emphasis channel")
  H.eq(vim.api.nvim_get_hl(0, { name = "CanvasDiffSidebarHunkDel" }).link, "CanvasDiffGhost",
    "and a removed line is struck exactly as the canvas strikes its ghosts")

  local groups = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(
    sidebar_buf(lease), SIDE_NS, 0, -1, { details = true })) do
    local group = m[4] and m[4].hl_group
    if group and group:find("SidebarHunk", 1, true) then
      groups[#groups + 1] = { m[2], group }
    end
  end
  H.eq(groups, {
    { 1, "CanvasDiffSidebarHunk" },
    { 3, "CanvasDiffSidebarHunk" },
    { 3, "CanvasDiffSidebarHunkDel" },
  }, "row 1 is a.lua's hunk; row 3 is b.lua's, struck because it only removes")
  done(st, lease)
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
  H.eq((canvas.locate(st, canvas_top0(st))), 3,
    "a count of 2 on the file cycle moves two sections")
  done(st)
end

--- A two-file review opened through the App, so a test presses the INSTALLED
--- keymap rather than calling the motion behind it. `opts` is merged over the
--- quiet defaults (no file watcher, no session file).
local function with_review(opts, body)
  local function changed(tag)
    local lines = vim.split(bigtext(60, tag), "\n", { plain = true })
    for i = 10, 60, 10 do
      lines[i] = lines[i] .. " changed"
    end
    return table.concat(lines, "\n")
  end
  local root = H.git_fixture({
    committed = { ["a/one.txt"] = bigtext(60, "a"), ["b/two.txt"] = bigtext(60, "b") },
    worktree = { ["a/one.txt"] = changed("a"), ["b/two.txt"] = changed("b") },
  })
  local orig_cwd = vim.fn.getcwd()
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  local quiet = { watch = { enabled = false }, session = { enabled = false } }
  fm.setup(vim.tbl_deep_extend("force", vim.deepcopy(quiet), opts or {}))
  local ok, err = xpcall(function()
    local st = assert(fm.open())
    vim.api.nvim_win_call(st.win, function()
      vim.fn.winrestview({ topline = 1, lnum = 1 })
    end)
    vim.api.nvim_set_current_win(st.win)
    body(st, assert(st.surface.controllers.sidebar))
  end, debug.traceback)
  pcall(fm.close)
  fm.setup(quiet) -- drop any keymap override before the next test
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(orig_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

--- 0-based canvas rows of section `i`'s hunk headers.
local function hunk_rows(st, i)
  local start0 = (canvas.section_rows(st, i))
  local out = {}
  for idx, entry in ipairs(st.sections[i].entries) do
    if entry.kind == "hunk_hdr" then
      out[#out + 1] = start0 + idx - 1
    end
  end
  return out
end

local function press(lhs)
  vim.api.nvim_feedkeys(vim.keycode(lhs), "x", false)
end

-- Ctrl+N's stops are hunks now. From the top of the review it lands on the
-- first file's first HUNK instead of scrolling the whole file away, and it
-- crosses into the next file at that file's first hunk, never at its header.
T["sidebar_cycle Ctrl+N walks hunk stops and the sidebar follows"] = function()
  with_review(nil, function(st, lease)
    local a_hunks, b_hunks = hunk_rows(st, 1), hunk_rows(st, 2)
    assert(#a_hunks >= 3 and #b_hunks >= 1, "sanity: both files have several hunks")
    local file_two = (canvas.section_rows(st, 2))
    assert(a_hunks[1] < file_two, "sanity: the first file's hunks precede the second file")

    press("<C-n>")
    H.eq(canvas_top0(st), a_hunks[1],
      "the first press lands on a hunk of the file we are already in, not on the next file")

    for _ = 2, #a_hunks do
      press("<C-n>")
    end
    H.eq(canvas_top0(st), a_hunks[#a_hunks], "one press per hunk, all the way down the file")

    press("<C-n>")
    H.eq(canvas_top0(st), b_hunks[1],
      "the walk crosses the file boundary onto the next file's first hunk, not its header")
    -- rows: 0 "a/", 1 one.txt, 2-7 its hunks, 8 "b/", 9 two.txt
    H.eq(active_row(sidebar_buf(lease)), 9, "and the sidebar followed to b/two.txt")

    press("2<C-p>")
    H.eq(canvas_top0(st), a_hunks[#a_hunks - 1], "a typed count still applies to the press")
  end)
end

-- The file axis Ctrl+N used to walk is one config line away, and that line has
-- to install a working map: an action with no handler in App silently maps
-- nothing at all, which would look exactly like the option not existing.
T["sidebar_cycle a bound cycle_file_next still scrolls whole files"] = function()
  with_review({ keymaps = { canvas = { cycle_file_next = "<C-y>" } } }, function(st)
    local mapped = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(st.buf, "n")) do
      if H.norm_lhs(m.lhs) == H.norm_lhs("<C-y>") then
        mapped = true
      end
    end
    assert(mapped, "binding the action must install a canvas map")

    press("<C-y>")
    H.eq(canvas_top0(st), (canvas.section_rows(st, 2)),
      "the restored action scrolls to the next FILE, exactly as Ctrl+N used to")
    press("<C-y>")
    H.eq(canvas_top0(st), (canvas.section_rows(st, 1)), "and wraps, as it always did")
  end)
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

-- --- the sidebar toggle (o, :CanvasDiff sidebar, .sidebar()) -------------

T["sidebar_ o closes and reopens the sidebar without touching the canvas"] = function()
  local orig_cwd = vim.fn.getcwd()
  local root = H.git_fixture({
    committed = { ["a.txt"] = bigtext(40, "a") },
    worktree = { ["a.txt"] = (bigtext(40, "a"):gsub("a line 5", "a line 5 X")) },
  })
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.setup({ watch = { enabled = false }, session = { enabled = false } })
  local ok, err = xpcall(function()
    local st = assert(fm.open())
    local lease = assert(st.surface.controllers.sidebar)
    assert(sidebar_win(lease), "the sidebar auto-opened with the canvas")
    local top_before = vim.api.nvim_win_call(st.win, function()
      return vim.fn.line("w0")
    end)

    -- `o` on the canvas closes the sidebar; the canvas is untouched.
    vim.api.nvim_set_current_win(st.win)
    vim.api.nvim_feedkeys("o", "x", false)
    H.eq(sidebar.is_open(lease), false, "o closed the sidebar")
    H.eq(st.surface.controllers.sidebar, nil, "and released the lease")
    H.eq(vim.api.nvim_win_get_buf(st.win), st.buf, "the canvas window keeps its buffer")
    H.eq(vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end),
      top_before, "and did not scroll")

    -- Toggling again brings it back, tracking the same canvas.
    fm.sidebar()
    local lease2 = assert(st.surface.controllers.sidebar, "a fresh lease was claimed")
    local win2 = assert(sidebar_win(lease2), "the sidebar window is back")
    sidebar.sync(lease2)
    assert(active_row(vim.api.nvim_win_get_buf(win2)) ~= nil,
      "the reopened sidebar tracks the canvas (active row present)")
    H.eq(vim.api.nvim_win_get_buf(st.win), st.buf, "the canvas is still untouched")
  end, debug.traceback)
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(orig_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["sidebar_ the command toggles and warns without a canvas"] = function()
  local orig_cwd = vim.fn.getcwd()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a\n" },
    worktree = { ["a.txt"] = "A\n" },
  })
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.setup({ watch = { enabled = false }, session = { enabled = false } })
  local real_notify = vim.notify
  local messages = {}
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end
  local ok, err = xpcall(function()
    -- No canvas: one warn in the existing vocabulary, nothing opens.
    local wins_before = #vim.api.nvim_tabpage_list_wins(0)
    fm.command({ "sidebar" })
    H.eq(#messages, 1, vim.inspect(messages))
    assert(messages[1].message:find("no live diff canvas", 1, true),
      vim.inspect(messages))
    H.eq(messages[1].level, vim.log.levels.WARN)
    H.eq(#vim.api.nvim_tabpage_list_wins(0), wins_before, "nothing opened")

    -- With a canvas: twice through the command closes, then reopens.
    local st = assert(fm.open())
    local lease = assert(st.surface.controllers.sidebar)
    assert(sidebar_win(lease), "sanity: the sidebar is open")
    fm.command({ "sidebar" })
    H.eq(sidebar.is_open(lease), false, ":CanvasDiff sidebar closed it")
    fm.command({ "sidebar" })
    local lease2 = assert(st.surface.controllers.sidebar, ":CanvasDiff sidebar reopened it")
    assert(sidebar_win(lease2), "and its window exists")
  end, debug.traceback)
  vim.notify = real_notify
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(orig_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["sidebar_ toggle works when sidebar.enabled = false"] = function()
  local orig_cwd = vim.fn.getcwd()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a\n" },
    worktree = { ["a.txt"] = "A\n" },
  })
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.setup({
    sidebar = { enabled = false },
    watch = { enabled = false },
    session = { enabled = false },
  })
  local ok, err = xpcall(function()
    local st = assert(fm.open())
    H.eq(st.surface.controllers.sidebar, nil,
      "sidebar.enabled = false means no auto-open")

    -- The flag governs auto-open only; an explicit toggle still opens.
    fm.sidebar()
    local lease = assert(st.surface.controllers.sidebar,
      "the explicit toggle claims a lease despite enabled = false")
    assert(sidebar_win(lease), "and the sidebar window opened")
  end, debug.traceback)
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(orig_cwd)
  vim.fn.delete(root, "rf")
  -- This test disabled the sidebar in live config; put the shared config
  -- back the way this suite's other full-plugin tests leave it.
  fm.setup({ watch = { enabled = false }, session = { enabled = false } })
  assert(ok, err)
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
