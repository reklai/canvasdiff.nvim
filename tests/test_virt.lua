local H = require("helpers")
local canvas = require("galley.canvas")
local model = require("galley.model")
local virt = require("galley.virt")
local hl = require("galley.hl")

local T = {}

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

-- ~55 rows per section (6 separated hunks): sections must be taller than the
-- ~22-row headless window or topline restores would clamp and the
-- scroll-targeting assertions below would silently test the wrong section.
local function big_section(path, tag)
  local old = bigtext(60, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 10, 60, 10 do
    lines[i] = lines[i] .. " changed"
  end
  return model.build_section(path, old, table.concat(lines, "\n"), "M")
end

-- virt's LRU tick bookkeeping is module-level, keyed by path -- and every test
-- below reopens the SAME literal paths in a fresh state. Without an explicit
-- reset, an earlier test's visibility ticks could outrank anything the new
-- canvas has seen and invert the eviction order (only test execution order
-- coincidentally hides this); detach() clears them deterministically.
-- (Which collapses are virt's own needs no such care: that lives on the state,
-- and canvas.open hands back a fresh one every time.)
local function six_sections()
  return {
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
    big_section("d/four.txt", "d"),
    big_section("e/five.txt", "e"),
    big_section("f/six.txt", "f"),
  }
end

local function open_six()
  virt.detach()
  return canvas.open(six_sections(), {})
end

local function reset_view(st)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
end

local function count_collapsed(st)
  local n = 0
  for _, sec in ipairs(st.sections) do
    if st.collapsed[sec.path] then n = n + 1 end
  end
  return n
end

T["virt_ folded-away sections do not count as expanded"] = function()
  local st = open_six()
  reset_view(st)
  -- Fold two of the six away. They already occupy one row each, so virt must
  -- see four expanded sections, not six -- and must never pick one of them as
  -- an eviction candidate (that would record it as "auto" while splicing
  -- nothing, freeing zero rows and leaving the user a collapse to inherit on
  -- unfold).
  st.folded = { ["e/"] = true, ["f/"] = true }
  canvas.resync_visibility(st)

  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }
  virt.apply(st, opts)

  local n_rendered_expanded = 0
  for i = 1, 6 do
    local s, e = canvas.section_rows(st, i)
    if e - s > 1 then n_rendered_expanded = n_rendered_expanded + 1 end
  end
  H.eq(n_rendered_expanded, opts.max_expanded,
    "virt collapses down to max_expanded RENDERED-expanded sections")

  local auto = H.auto_set(st)
  H.eq(auto["e/five.txt"], nil, "never claims a folded-away path")
  H.eq(auto["f/six.txt"], nil, "never claims a folded-away path")

  st.folded = {}
  virt.detach()
end

T["virt_ unfolding leaves an auto-collapsed section as a placeholder"] = function()
  local st = open_six()
  reset_view(st)
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }
  virt.apply(st, opts)

  -- Find something virt collapsed on its own, then fold its parent over it.
  local auto = H.auto_set(st)
  local path, idx
  for i, s in ipairs(st.sections) do
    if auto[s.path] then path, idx = s.path, i break end
  end
  assert(path, "virt auto-collapsed at least one section")
  local dir = path:match("^(.-/)")

  st.folded = { [dir] = true }
  canvas.resync_visibility(st)
  st.folded = {}
  canvas.resync_visibility(st)

  local s, e = canvas.section_rows(st, idx)
  H.eq(e - s, 1, "still virt's placeholder -- unfolding only undoes the fold")
  H.eq(st.collapsed[path], "auto", "and it is still recorded as virt's own")
  virt.detach()
end

T["virt_ inactive under thresholds leaves everything expanded"] = function()
  local st = open_six()
  reset_view(st)
  virt.apply(st, { enabled = true, max_files = 100, max_lines = 1000000, margin = 10, max_expanded = 2 })
  H.eq(count_collapsed(st), 0, "under thresholds: nothing collapsed")
  for i = 1, 6 do
    local s, e = canvas.section_rows(st, i)
    assert(e - s > 1, "section " .. i .. " is not a 1-row placeholder")
  end
end

T["virt_ active collapses far sections beyond max_expanded and keeps near ones"] = function()
  local st = open_six()
  reset_view(st)
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }

  local info = vim.api.nvim_win_call(st.win, function()
    return { top0 = vim.fn.line("w0") - 1, bot0 = vim.fn.line("w$") - 1 }
  end)
  local win_lo, win_hi = info.top0 - opts.margin, info.bot0 + opts.margin
  local in_window = {}
  for i = 1, 6 do
    local srow, erow = canvas.section_rows(st, i)
    in_window[i] = srow <= win_hi and erow > win_lo
  end

  virt.apply(st, opts)

  for i = 1, 6 do
    if in_window[i] then
      H.eq(st.collapsed[st.sections[i].path], nil, "in-window section " .. i .. " stays expanded")
    end
  end
  H.eq(count_collapsed(st), 6 - opts.max_expanded, "far sections collapsed down to max_expanded")
  local n_expanded = 0
  for i = 1, 6 do
    if not st.collapsed[st.sections[i].path] then n_expanded = n_expanded + 1 end
  end
  H.eq(n_expanded, opts.max_expanded)
end

T["virt_ scroll then apply expands newly-near and collapses newly-far"] = function()
  local st = open_six()
  reset_view(st)
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }

  virt.apply(st, opts)
  -- first two sections (nearest the top-of-viewport window) survive the
  -- first apply expanded; the rest collapse to their placeholder row.
  H.eq(st.collapsed[st.sections[1].path], nil, "sanity: section 1 expanded after first apply")
  H.eq(st.collapsed[st.sections[2].path], nil, "sanity: section 2 expanded after first apply")
  assert(st.collapsed[st.sections[6].path], "sanity: section 6 collapsed after first apply")

  vim.api.nvim_win_call(st.win, function() vim.cmd("normal! G") end)
  local before = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)

  virt.apply(st, opts)

  local after = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)
  H.eq(after, before, "zero motion: visible top line unchanged across the apply")

  H.eq(st.collapsed[st.sections[6].path], nil, "last section expanded once near")
  assert(st.collapsed[st.sections[1].path], "first section collapsed once far")
end

T["virt_ never auto-expands a user-collapsed section"] = function()
  local st = open_six()
  reset_view(st)
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 1000, max_expanded = 6 }

  -- User-collapses a section that sits inside the viewport, via the plain
  -- canvas primitive (not virt) -- this must never be auto-expanded back.
  canvas.set_collapsed(st, 1, true)

  virt.apply(st, opts)

  assert(st.collapsed[st.sections[1].path], "user-collapsed section stays collapsed")
  H.eq(H.auto_set(st)[st.sections[1].path], nil, "auto-set never claims a user-collapsed path")
end

T["virt_ deactivation auto-expands only the auto set"] = function()
  local st = open_six()
  reset_view(st)
  local active_opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }

  virt.apply(st, active_opts)
  assert(next(H.auto_set(st)) ~= nil, "sanity: something got auto-collapsed")
  assert(st.collapsed[st.sections[1].path] == nil, "sanity: section 1 still expanded (in-window)")

  -- User-collapses the still-expanded section 1 directly.
  canvas.set_collapsed(st, 1, true)

  local auto_before = H.auto_set(st)
  local inactive_opts = { enabled = true, max_files = 100, max_lines = 1000000, margin = 10, max_expanded = 2 }
  virt.apply(st, inactive_opts)

  for path in pairs(auto_before) do
    H.eq(st.collapsed[path], nil, "auto-collapsed section " .. path .. " expanded back")
  end
  assert(st.collapsed[st.sections[1].path], "user-collapsed section 1 stays collapsed")
  H.eq(next(H.auto_set(st)), nil, "auto-set cleared")
end

-- The max_lines threshold must describe the CHANGESET, not the current
-- rendering. Six big_sections are 312 rows fully expanded; once virt
-- collapses four of them the buffer is only 108 rows. Measuring the buffer
-- would put a max_lines of 200 on the wrong side of the threshold on the
-- second pass, deactivating virt, expanding everything back, and leaving the
-- canvas oscillating between virtualized and fully rendered on every scroll.
T["virt_ stays active while its own collapses shrink the buffer"] = function()
  local st = open_six()
  reset_view(st)
  local opts = { enabled = true, max_files = 1000, max_lines = 200, margin = 10, max_expanded = 2 }

  virt.apply(st, opts)

  local collapsed_after_first = count_collapsed(st)
  assert(collapsed_after_first > 0, "sanity: the first apply auto-collapsed something")
  local rendered = vim.api.nvim_buf_line_count(st.buf)
  assert(rendered < 200,
    "sanity: collapsing dropped the buffer below max_lines (got " .. rendered .. ")")

  virt.apply(st, opts)

  H.eq(count_collapsed(st), collapsed_after_first,
    "a second apply keeps the same sections collapsed")
  assert(next(H.auto_set(st)) ~= nil, "auto-set survives the second apply")
end

T["virt_ on_shape_change fires once per mutating apply"] = function()
  local st = open_six()
  reset_view(st)
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }

  local n, seen = 0, nil
  st.hooks = st.hooks or {}
  st.hooks.on_shape_change = function(s)
    n = n + 1
    seen = s
  end

  virt.apply(st, opts)
  H.eq(n, 1, "one notification for the apply that collapsed sections")
  H.eq(seen, st, "the hook receives the state that was applied")

  virt.apply(st, opts)
  H.eq(n, 1, "an apply that changes nothing stays silent")

  st.hooks.on_shape_change = nil
end

-- hl's WinScrolled debounce (30ms) beats virt's (50ms), so a section virt
-- expands was still collapsed -- and therefore skipped -- when highlighting
-- last ran. The splice fires no further WinScrolled of its own, so without
-- the resync the expanded content would sit unhighlighted until the user
-- scrolled again.
--
-- Driven by hand rather than through the real events: WinScrolled is emitted
-- from the redraw path and never fires headlessly, so the debounce race this
-- guards against cannot be staged directly. Wiring the hook here pins the
-- contract that the race relies on instead.
T["virt_ expanded sections get their highlights back"] = function()
  local st = open_six()
  reset_view(st)
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 0, max_expanded = 1 }

  hl.attach(st, { margin = 0, debounce_ms = 30 })
  st.hooks.on_shape_change = function(s)
    hl.apply_now(s)
  end

  virt.apply(st, opts)
  local path = st.sections[6].path
  assert(st.collapsed[path], "sanity: section 6 auto-collapsed while far from the viewport")
  H.eq(st.ts.ids_by_path[path], nil, "sanity: a collapsed section carries no marks")

  local s6 = (canvas.section_rows(st, 6))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = s6 + 1, lnum = s6 + 1 })
  end)
  virt.apply(st, opts)

  H.eq(st.collapsed[path], nil, "section 6 expanded back once it was near")
  assert(st.ts.ids_by_path[path] ~= nil, "the expanded section got its highlights back")

  st.hooks.on_shape_change = nil
  hl.detach(st)
end

-- tick_of is module-level and keyed by path, but canvas.open always
-- hands back a fresh state.collapsed. Re-opening without an intervening
-- detach (reachable through M.open's sidebar-redirect branch) therefore
-- carried the previous canvas's visibility history into the new one, and
-- those stale ticks outranked everything the new canvas had actually seen --
-- so the LRU kept the FARTHEST section rendered and collapsed the nearest,
-- exactly inverting the policy.
T["virt_ attach to a new canvas forgets the previous one's history"] = function()
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }

  local st1 = open_six()
  -- Park canvas one at the BOTTOM, so its last sections look recently-seen.
  vim.api.nvim_win_call(st1.win, function()
    vim.cmd("normal! G")
  end)
  virt.apply(st1, opts)
  assert(H.auto_set(st1)["a/one.txt"], "sanity: canvas one auto-collapsed its far (top) sections")

  -- Re-open WITHOUT detaching, and look at the TOP of the new canvas.
  local st2 = canvas.open(six_sections(), {})
  reset_view(st2)
  virt.attach(st2, opts)

  H.eq(st2.collapsed[st2.sections[2].path], nil,
    "the section just below the viewport stays expanded")
  assert(st2.collapsed[st2.sections[6].path],
    "the farthest section is collapsed, not kept alive by the old canvas's ticks")

  virt.detach()
end

return T
