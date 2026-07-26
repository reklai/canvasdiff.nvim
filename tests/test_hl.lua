local H = require("helpers")
local model = require("galley.model")
local hl = require("galley.hl")
local canvas = require("galley.canvas")

local T = {}

local OLD = table.concat({
  "local a = 1",
  "local b = 2",
  "local c = 3",
  "local d = 4",
  "local e = 5",
}, "\n") .. "\n"

local NEW = table.concat({
  "local a = 1",
  "local b = 20 -- changed",
  "local c = 3",
  "local d = 4",
  "local e = 5",
}, "\n") .. "\n"

T["hl_lang_for maps lua files"] = function()
  H.eq(hl.lang_for("foo/bar.lua"), "lua")
end

T["hl_lang_for unknown extension is nil"] = function()
  H.eq(hl.lang_for("foo/bar.qqqzzz"), nil)
end

T["hl_section carries whole-file texts"] = function()
  local s = model.build_section("a.lua", OLD, NEW, "M")
  H.eq(s.old_text, OLD)
  H.eq(s.new_text, NEW)
end

T["hl_ts_marks land on content rows with +1 col offset"] = function()
  -- entries: file_hdr(1) hunk_hdr(2) ctx(3) del(4) add(5) ctx(6) ctx(7) ctx(8)
  local s = model.build_section("a.lua", OLD, NEW, "M")
  local marks = hl.section_ts_marks(s)
  assert(#marks > 0, "expected some marks")
  local by_row = {}
  for _, m in ipairs(marks) do
    by_row[m.row] = by_row[m.row] or {}
    table.insert(by_row[m.row], m)
    H.eq(m.priority, 110)
    assert(m.col >= 1, "col must include the 1-byte prefix offset")
    assert(m.end_col > m.col, "non-empty span")
    assert(m.group:sub(1, 1) == "@", "treesitter group: " .. m.group)
    assert(m.group:sub(-4) == ".lua", "lang-suffixed group: " .. m.group)
  end
  assert(by_row[2], "ctx row (entry 3) highlighted from new side")
  assert(by_row[3], "del row (entry 4) highlighted from old side")
  assert(by_row[4], "add row (entry 5) highlighted from new side")
  H.eq(by_row[0], nil, "file_hdr row never highlighted")
  H.eq(by_row[1], nil, "hunk_hdr row never highlighted")

  -- Known-capture correctness: "local a = 1" has a number capture on the "1"
  -- (source byte col 10) -> buffer cols [11, 12) after the prefix shift.
  local found_number = false
  for _, m in ipairs(by_row[2]) do
    if m.group:find("number", 1, true) then
      found_number = true
      H.eq(m.col, 11, "number starts after 'local a = ' plus prefix")
      H.eq(m.end_col, 12)
    end
  end
  assert(found_number, "expected a @number capture on the ctx line")
end

T["hl_ts_marks unknown language returns empty"] = function()
  local s = model.build_section("a.qqqzzz", OLD, NEW, "M")
  H.eq(hl.section_ts_marks(s), {})
end

T["hl_ts_marks clip multiline captures per displayed row"] = function()
  local old = "local x = 1\n"
  local new = "local x = 1\nlocal s = [[\nhello\nworld\n]]\n"
  -- entries: file_hdr(1) hunk_hdr(2) ctx(3, lnum 1) add(4..7, lnums 2..5)
  local s = model.build_section("ml.lua", old, new, "M")
  local marks = hl.section_ts_marks(s)
  local function full_row_string_mark(row, text)
    for _, m in ipairs(marks) do
      if m.row == row and m.group:find("string", 1, true)
        and m.col == 1 and m.end_col == #text + 1 then
        return true
      end
    end
    return false
  end
  -- middle lines of the [[...]] string ("hello" row 4, "world" row 5) must be
  -- fully covered by per-row clipped @string marks
  assert(full_row_string_mark(4, "hello"), "hello row covered")
  assert(full_row_string_mark(5, "world"), "world row covered")
end

T["hl_cache evicts LRU at capacity and invalidate drops one entry"] = function()
  -- fill well past capacity with distinct paths
  for k = 1, 25 do
    local s = model.build_section(("cache%d.lua"):format(k), OLD, NEW, "M")
    hl.section_ts_marks(s)
  end
  H.eq(hl._cache_size(), 20, "cache bounded at CACHE_CAP")
  hl.invalidate("cache25.lua")
  H.eq(hl._cache_size(), 19, "invalidate drops a cached path")
  hl.invalidate("cache25.lua")
  H.eq(hl._cache_size(), 19, "double invalidate is a no-op")
  hl.invalidate("no-such-path.lua")
  H.eq(hl._cache_size(), 19, "invalidating an unknown path is a no-op")
end

T["hl_cache evicted path still produces correct marks on re-request"] = function()
  local s1 = model.build_section("evictme.lua", OLD, NEW, "M")
  local before = hl.section_ts_marks(s1)
  for k = 1, 21 do
    hl.section_ts_marks(model.build_section(("refill%d.lua"):format(k), OLD, NEW, "M"))
  end
  local after = hl.section_ts_marks(s1)
  H.eq(after, before, "reparse after eviction yields identical marks")
end

-- ~90-row sections: 100 lines with a change every 10th line = 10 separated
-- hunks (context 3), each ~9 rows, plus headers.
local function big_lua(n, seed)
  local t = {}
  for i = 1, n do
    t[i] = ("local v%d_%d = %d"):format(seed, i, i)
  end
  return table.concat(t, "\n") .. "\n"
end

local function changed_every(text, step)
  local lines = vim.split(text, "\n", { plain = true })
  for i = step, #lines, step do
    if lines[i] ~= "" then
      lines[i] = lines[i] .. " + 1"
    end
  end
  return table.concat(lines, "\n")
end

local function big_sections()
  local secs = {}
  for k = 1, 3 do
    local old = big_lua(100, k)
    secs[k] = model.build_section(("f%d.lua"):format(k), old, changed_every(old, 10), "M")
  end
  return secs
end

-- canvas.lua caches its scratch buffer at module scope and reuses it across
-- `canvas.open` calls, so Neovim's per-(window, buffer) remembered view can
-- carry a scroll position left behind by an earlier test in this same
-- headless process into this test's "top of viewport" assumption. Pin the
-- view deterministically, matching the same idiom test_canvas.lua already
-- uses for this exact reason.
--
-- Likewise, `render_all`'s TS_NS clear only fires through `state.hooks`,
-- which belongs to whichever *state table* last called `hl.attach` -- and
-- `canvas.open` always builds a brand-new state table, so a fresh attach's
-- first `render_all` runs before its own hook exists. Across many
-- `canvas.open` calls sharing this one process's singleton scratch buffer,
-- that leaves an earlier test's TS_NS marks sitting in the buffer for a
-- later test to trip over. Clearing it here isolates each test the same
-- way a truly first-ever `canvas.open` in a real session would start clean.
local TS_NS = vim.api.nvim_create_namespace("galley.canvas.ts")

local function reset_view(st)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  vim.api.nvim_buf_clear_namespace(st.buf, TS_NS, 0, -1)
end

T["hl_engine marks visible sections and skips far ones"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  hl.attach(st, { margin = 5 })
  assert(st.ts.ids_by_path["f1.lua"] and #st.ts.ids_by_path["f1.lua"] > 0,
    "section under viewport highlighted on attach")
  H.eq(st.ts.ids_by_path["f3.lua"], nil, "far section untouched")
end

T["hl_engine applies on scroll and evicts at 2x margin"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  hl.attach(st, { margin = 5 })
  vim.api.nvim_win_call(st.win, function()
    vim.cmd("normal! G")
  end)
  hl.apply_now(st)
  assert(st.ts.ids_by_path["f3.lua"] and #st.ts.ids_by_path["f3.lua"] > 0,
    "bottom section highlighted after scroll")
  H.eq(st.ts.ids_by_path["f1.lua"], nil, "top section evicted beyond 2x margin")
end

T["hl_engine replace_section invalidates and reapplies inside new rows"] = function()
  local old = big_lua(30, 9)
  local sec = model.build_section("r.lua", old, changed_every(old, 5), "M")
  local st = canvas.open({ sec }, {})
  reset_view(st)
  hl.attach(st, { margin = 200 })
  assert(st.ts.ids_by_path["r.lua"] and #st.ts.ids_by_path["r.lua"] > 0)

  local sec2 = model.build_section("r.lua", old, changed_every(old, 7), "M")
  canvas.replace_section(st, 1, sec2)
  H.eq(st.ts.ids_by_path["r.lua"], nil, "hook cleared marks on splice")

  hl.apply_now(st)
  assert(st.ts.ids_by_path["r.lua"] and #st.ts.ids_by_path["r.lua"] > 0, "reapplied")

  local srow, erow = canvas.section_rows(st, 1)
  local ns = vim.api.nvim_create_namespace("galley.canvas.ts")
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, ns, 0, -1, {})) do
    assert(m[2] >= srow and m[2] < erow,
      ("stale mark at row %d outside [%d, %d)"):format(m[2], srow, erow))
  end
end

T["hl_engine render_all clears the ts namespace via hook"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  hl.attach(st, { margin = 5 })
  canvas.render_all(st, big_sections())
  local ns = vim.api.nvim_create_namespace("galley.canvas.ts")
  H.eq(vim.api.nvim_buf_get_extmarks(st.buf, ns, 0, -1, {}), {}, "namespace cleared")
  H.eq(next(st.ts.ids_by_path), nil, "bookkeeping reset")
  hl.apply_now(st)
  assert(st.ts.ids_by_path["f1.lua"], "reapplies after re-render")
end

T["hl_engine reattach after reopen leaves no stale marks"] = function()
  local st1 = canvas.open(big_sections(), {})
  hl.attach(st1, { margin = 50 })
  -- reopen on the same cached buffer: render_all runs on a hookless fresh
  -- state, then attach must start from a clean namespace
  local st2 = canvas.open(big_sections(), {})
  hl.attach(st2, { margin = 50 })
  local ns = vim.api.nvim_create_namespace("galley.canvas.ts")
  local total = #vim.api.nvim_buf_get_extmarks(st2.buf, ns, 0, -1, {})
  local tracked = 0
  for _, ids in pairs(st2.ts.ids_by_path) do
    tracked = tracked + #ids
  end
  H.eq(total, tracked, "every mark in the namespace is tracked by the live state")
  assert(total > 0, "sanity: attach applied marks")
end

T["hl_engine stale state apply is a no-op after reattach"] = function()
  local st1 = canvas.open(big_sections(), {})
  hl.attach(st1, { margin = 5 })
  local st2 = canvas.open(big_sections(), {})
  hl.attach(st2, { margin = 5 })

  -- Move the viewport far from the sections both states applied at attach
  -- time (f1), so a stale apply would evict f1 (deleting ids that alias the
  -- live state's marks) and apply f3 (marks tracked only by the dead state).
  vim.api.nvim_win_call(st2.win, function()
    vim.cmd("normal! G")
  end)

  local ns = vim.api.nvim_create_namespace("galley.canvas.ts")
  local before = vim.api.nvim_buf_get_extmarks(st2.buf, ns, 0, -1, {})

  hl.apply_now(st1) -- simulated stale debounce callback

  local after = vim.api.nvim_buf_get_extmarks(st2.buf, ns, 0, -1, {})
  H.eq(after, before, "stale-state apply changed the namespace")

  local tracked = 0
  for _, ids in pairs(st2.ts.ids_by_path) do
    tracked = tracked + #ids
  end
  H.eq(#after, tracked, "live state tracks every mark in the namespace")
end

T["hl_engine BufWinEnter reapplies marks after a hidden splice"] = function()
  local old = big_lua(30, 21)
  local sec = model.build_section("hidden.lua", old, changed_every(old, 5), "M")
  local st = canvas.open({ sec }, {})
  reset_view(st)
  hl.attach(st, { margin = 200 })
  assert(st.ts.ids_by_path["hidden.lua"] and #st.ts.ids_by_path["hidden.lua"] > 0,
    "sanity: attach applied marks")

  -- hide the canvas: show a scratch buffer in its window
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(st.win, scratch)

  -- splice while hidden: the on_section_replaced hook still deletes the old
  -- marks, but the trailing apply_now no-ops (window no longer shows the
  -- canvas), so nothing re-applies them.
  local sec2 = model.build_section("hidden.lua", old, changed_every(old, 7), "M")
  canvas.replace_section(st, 1, sec2)
  H.eq(st.ts.ids_by_path["hidden.lua"], nil, "hook cleared marks on the hidden splice")

  -- re-show the canvas buffer in the window: nvim_win_set_buf fires
  -- BufWinEnter, which must re-apply without an explicit apply_now call.
  vim.api.nvim_win_set_buf(st.win, st.buf)

  assert(st.ts.ids_by_path["hidden.lua"] and #st.ts.ids_by_path["hidden.lua"] > 0,
    "BufWinEnter re-applied marks with nobody calling apply_now manually")
  H.eq(st.win, vim.api.nvim_get_current_win(),
    "BufWinEnter updated state.win to the window now showing the canvas")
end

-- --- the diff-row contrast budget -------------------------------------------
--
-- Three properties that together decide how the canvas reads, and none of which any
-- other test would notice changing.

-- `hl_eol` made an add/del tint fill the rest of the SCREEN LINE, so a three-character
-- edit painted colour to the right edge of a 200-column window -- the coloured area
-- scaled with the window, not with the change. This is the guard against it coming
-- back, which is a one-word edit in apply_section_hl and looks like nothing in review.
T["hl_rows add and del tints stop at end-of-text, never filling the window"] = function()
  local st = canvas.open({
    model.build_section("a.lua", "local a = 1\nlocal b = 2\n", "local a = 1\nlocal B = 2\n", "M", 3),
  }, {})

  local flooders, tinted = {}, 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, -1, 0, -1, { details = true })) do
    local d = m[4]
    if d and (d.hl_group == "GalleyAdd" or d.hl_group == "GalleyDel") then
      tinted = tinted + 1
      if d.hl_eol then flooders[#flooders + 1] = ("row %d %s"):format(m[2] + 1, d.hl_group) end
    end
  end
  assert(tinted > 0, "sanity: the diff rows are tinted at all")
  H.eq(flooders, {},
    "no add/del mark may set hl_eol -- it spends the strongest visual channel on "
    .. "'this line is involved', which is the least interesting thing on screen")
end

-- These were the last two visual elements pointing straight at standard groups, so
-- tuning the diff rows meant redefining the groups your ordinary vimdiff also uses.
T["hl_rows the row tints go through overridable Galley aliases"] = function()
  for _, g in ipairs({ "GalleyAdd", "GalleyDel" }) do
    local direct = vim.api.nvim_get_hl(0, { name = g, link = false })
    assert(next(direct) ~= nil, g .. " must be defined, or the diff rows render unstyled")
  end
  -- `default = true` throughout, so a colourscheme that defines these wins.
  local linked = vim.api.nvim_get_hl(0, { name = "GalleyAdd", link = true })
  assert(linked.link == "DiffAdd" or linked.bg,
    "GalleyAdd should default to DiffAdd (or be overridden), got: " .. vim.inspect(linked))
end

-- The word-diff marks have to beat the row tint they sit inside, and a BACKGROUND
-- cannot be relied on to: which one wins is colourscheme luck. Measured both ways --
-- under tokyonight-moon DiffText clears an added row by 9 and Search by 39, and under
-- Neovim's builtin scheme that reverses to 28 and 19, with the row itself clearing
-- Normal by 41 so neither dominates.
--
-- So the requirement is that these carry ATTRIBUTES and NO background: attributes
-- compose over whatever is underneath instead of competing with it, which is the only
-- form of this that holds under every colourscheme. This test is therefore structural
-- on purpose -- a luminance assertion here would pass or fail on the test runner's
-- colourscheme rather than on anything galley decides.
T["hl_rows word-diff marks emphasise by attribute, not by a competing background"] = function()
  for _, name in ipairs({ "GalleyWordAdd", "GalleyWordDel" }) do
    local h = vim.api.nvim_get_hl(0, { name = name, link = false })
    assert(next(h) ~= nil, name .. " must be defined, or changed spans get no mark at all")
    assert(h.bg == nil, name .. " must not set a background: it sits inside the row tint, "
      .. "so a background competes with one that already claimed the contrast range "
      .. "(linking back to DiffText or Search is what breaks this)")
    assert(h.bold or h.underline or h.reverse or h.italic or h.undercurl,
      name .. " must carry at least one attribute, or it marks nothing")
  end
end

return T
