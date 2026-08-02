local H = require("helpers")
local model = require("canvasdiff.diff")
local hl = require("canvasdiff.ui").highlight
local canvas = require("canvasdiff.canvas")

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

-- A section may have released its two sides so a large changeset fits in
-- memory. The UI domain cannot read the repository itself, so it asks its
-- owner -- and when nobody can answer, it produces nothing rather than
-- something wrong.
T["hl_ts_marks a released side is re-read through the owner"] = function()
  local st = canvas.open({}, {})
  local section = model.build_section("a.lua", OLD, NEW, "M")
  local expected = hl.section_ts_marks(section)
  assert(#expected > 0, "sanity: the retained section highlights")

  local asked = {}
  local lease = hl.attach(st, { margin = 0 }, {
    windows = function() return {} end,
    side = function(asked_section, which)
      asked[#asked + 1] = which
      H.eq(asked_section.path, "a.lua", "the owner is asked about one section")
      return which == "new" and NEW or OLD
    end,
  })
  model.release_text(section)
  H.eq(section.new_text, nil, "sanity: the side really is gone")

  local marks = hl.section_ts_marks(section, lease)
  H.eq(marks, expected, "the owner's text produces byte-identical marks")
  table.sort(asked)
  H.eq(asked, { "new", "old" }, "each side is asked for exactly once")
  assert(hl.detach(lease))
end

T["hl_ts_marks a released side without an owner yields no marks"] = function()
  local st = canvas.open({}, {})
  local section = model.build_section("a.lua", OLD, NEW, "M")
  model.release_text(section)

  H.eq(hl.section_ts_marks(section), {},
    "no lease at all means no treesitter marks, not an error")

  local lease = hl.attach(st, { margin = 0 }, {
    windows = function() return {} end,
  })
  H.eq(hl.section_ts_marks(section, lease), {},
    "nor does a lease whose owner offers no sides")
  assert(hl.detach(lease))

  local faulty = hl.attach(st, { margin = 0 }, {
    windows = function() return {} end,
    side = function() error("injected side provider fault") end,
  })
  H.eq(hl.section_ts_marks(section, faulty), {},
    "a throwing provider degrades to no marks rather than failing the render")
  assert(hl.detach(faulty))

  local wrong = hl.attach(st, { margin = 0 }, {
    windows = function() return {} end,
    side = function() return 42 end,
  })
  H.eq(hl.section_ts_marks(section, wrong), {},
    "and so does one that answers with something that is not text")
  assert(hl.detach(wrong))
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
  local st = canvas.open({}, {})
  local lease = hl.attach(st, { margin = 0 })
  -- fill well past capacity with distinct paths
  for k = 1, 25 do
    local s = model.build_section(("cache%d.lua"):format(k), OLD, NEW, "M")
    hl.section_ts_marks(s, lease)
  end
  H.eq(hl._cache_size(lease), 20, "cache bounded at CACHE_CAP")
  hl.invalidate(lease, "cache25.lua")
  H.eq(hl._cache_size(lease), 19, "invalidate drops a cached path")
  hl.invalidate(lease, "cache25.lua")
  H.eq(hl._cache_size(lease), 19, "double invalidate is a no-op")
  hl.invalidate(lease, "no-such-path.lua")
  H.eq(hl._cache_size(lease), 19, "invalidating an unknown path is a no-op")
  assert(hl.detach(lease))
  H.eq(hl._cache_size(lease), 0, "detached cache is released")
end

T["hl_cache evicted path still produces correct marks on re-request"] = function()
  local st = canvas.open({}, {})
  local lease = hl.attach(st, { margin = 0 })
  local s1 = model.build_section("evictme.lua", OLD, NEW, "M")
  local before = hl.section_ts_marks(s1, lease)
  for k = 1, 21 do
    hl.section_ts_marks(model.build_section(("refill%d.lua"):format(k), OLD, NEW, "M"), lease)
  end
  local after = hl.section_ts_marks(s1, lease)
  H.eq(after, before, "reparse after eviction yields identical marks")
  assert(hl.detach(lease))
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
local TS_NS = vim.api.nvim_create_namespace("canvasdiff.canvas.ts")

local function reset_view(st)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
end

--- A complete review on its own buffer and its own window.
---
--- `canvas.open` creates one buffer per review now, and shows it in the
--- CURRENT window -- so two concurrent reviews need two windows, exactly as a
--- user would give them.
local function independent_canvas(sections)
  local state, win = H.in_new_window(function()
    return canvas.open(sections, {})
  end)
  vim.api.nvim_set_option_value("scrolloff", 0, { win = win, scope = "local" })
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  return state
end

local function close_canvas(state)
  H.close_windows(state.win)
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
end

T["hl_engine marks visible sections and skips far ones"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local lease = hl.attach(st, { margin = 5 })
  assert(lease.ids_by_path["f1.lua"] and #lease.ids_by_path["f1.lua"] > 0,
    "section under viewport highlighted on attach")
  H.eq(lease.ids_by_path["f3.lua"], nil, "far section untouched")
  assert(hl.detach(lease))
end

T["hl_engine applies on scroll and evicts at 2x margin"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local lease = hl.attach(st, { margin = 5 })
  vim.api.nvim_win_call(st.win, function()
    vim.cmd("normal! G")
  end)
  hl.apply_now(lease)
  assert(lease.ids_by_path["f3.lua"] and #lease.ids_by_path["f3.lua"] > 0,
    "bottom section highlighted after scroll")
  H.eq(lease.ids_by_path["f1.lua"], nil, "top section evicted beyond 2x margin")
  assert(hl.detach(lease))
end

T["hl_engine replace_section invalidates and reapplies inside new rows"] = function()
  local old = big_lua(30, 9)
  local sec = model.build_section("r.lua", old, changed_every(old, 5), "M")
  local st = canvas.open({ sec }, {})
  reset_view(st)
  local lease = hl.attach(st, { margin = 200 })
  assert(lease.ids_by_path["r.lua"] and #lease.ids_by_path["r.lua"] > 0)

  local sec2 = model.build_section("r.lua", old, changed_every(old, 7), "M")
  canvas.replace_section(st, 1, sec2)
  H.eq(lease.ids_by_path["r.lua"], nil, "hook cleared marks on splice")

  hl.apply_now(lease)
  assert(lease.ids_by_path["r.lua"] and #lease.ids_by_path["r.lua"] > 0, "reapplied")

  local srow, erow = canvas.section_rows(st, 1)
  local ns = vim.api.nvim_create_namespace("canvasdiff.canvas.ts")
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, ns, 0, -1, {})) do
    assert(m[2] >= srow and m[2] < erow,
      ("stale mark at row %d outside [%d, %d)"):format(m[2], srow, erow))
  end
  assert(hl.detach(lease))
end

T["hl_engine render_all clears the ts namespace via hook"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local lease = hl.attach(st, { margin = 5 })
  assert(hl._cache_size(lease) > 0, "initial apply populated the lease cache")
  canvas.render_all(st, big_sections())
  local ns = vim.api.nvim_create_namespace("canvasdiff.canvas.ts")
  H.eq(vim.api.nvim_buf_get_extmarks(st.buf, ns, 0, -1, {}), {}, "namespace cleared")
  H.eq(next(lease.ids_by_path), nil, "bookkeeping reset")
  H.eq(hl._cache_size(lease), 0, "full render releases cached source/tree graph")
  hl.apply_now(lease)
  assert(lease.ids_by_path["f1.lua"], "reapplies after re-render")
  assert(hl.detach(lease))
end

T["hl_engine reattach after reopen leaves no stale marks"] = function()
  local st1 = canvas.open(big_sections(), {})
  local lease1 = hl.attach(st1, { margin = 50 })
  -- reopen on the same cached buffer: render_all runs on a hookless fresh
  -- state, so lease1's marks are orphaned by an edit it never observed.
  local st2 = canvas.open(big_sections(), {})
  -- The owner disposes the previous review; nothing in the highlighter elects
  -- a winner on its behalf, and teardown after a foreign full render must
  -- still resolve exactly the IDs lease1 reserved.
  assert(hl.detach(lease1))
  local lease2 = hl.attach(st2, { margin = 50 })
  local ns = vim.api.nvim_create_namespace("canvasdiff.canvas.ts")
  local total = #vim.api.nvim_buf_get_extmarks(st2.buf, ns, 0, -1, {})
  local tracked = 0
  for _, ids in pairs(lease2.ids_by_path) do
    tracked = tracked + #ids
  end
  H.eq(total, tracked, "every mark in the namespace is tracked by the live state")
  assert(total > 0, "sanity: attach applied marks")
  assert(hl.detach(lease2))
end

T["hl_engine stale state apply is a no-op after reattach"] = function()
  -- The old review's generation fence is what makes it stale. No module-global
  -- selector is involved: lease1 keeps its own exact identity, and its owner
  -- refusing the fence is the only thing that stops it reconciling.
  local st1 = canvas.open(big_sections(), {})
  local superseded = false
  local lease1 = hl.attach(st1, { margin = 5 }, {
    alive = function() return not superseded end,
  })
  local st2 = canvas.open(big_sections(), {})
  superseded = true
  local lease2 = hl.attach(st2, { margin = 5 })

  -- Move the viewport far from the sections both states applied at attach
  -- time (f1), so a stale apply would evict f1 (deleting ids that alias the
  -- live state's marks) and apply f3 (marks tracked only by the dead state).
  vim.api.nvim_win_call(st2.win, function()
    vim.cmd("normal! G")
  end)

  local ns = vim.api.nvim_create_namespace("canvasdiff.canvas.ts")
  local before = vim.api.nvim_buf_get_extmarks(st2.buf, ns, 0, -1, {})

  H.eq(hl.apply_now(lease1), false, "simulated stale debounce callback is inert")

  local after = vim.api.nvim_buf_get_extmarks(st2.buf, ns, 0, -1, {})
  H.eq(after, before, "stale-state apply changed the namespace")

  assert(hl.detach(lease1))
  local tracked = 0
  for _, ids in pairs(lease2.ids_by_path) do
    tracked = tracked + #ids
  end
  H.eq(#vim.api.nvim_buf_get_extmarks(st2.buf, ns, 0, -1, {}), tracked,
    "once the stale review is disposed the live state tracks every remaining mark")
  assert(hl.detach(lease2))
end

T["hl_engine BufWinEnter reapplies marks after a hidden splice"] = function()
  local old = big_lua(30, 21)
  local sec = model.build_section("hidden.lua", old, changed_every(old, 5), "M")
  local st = canvas.open({ sec }, {})
  reset_view(st)
  local lease = hl.attach(st, { margin = 200 })
  assert(lease.ids_by_path["hidden.lua"] and #lease.ids_by_path["hidden.lua"] > 0,
    "sanity: attach applied marks")

  -- hide the canvas: show a scratch buffer in its window
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(st.win, scratch)

  -- splice while hidden: the on_section_replaced hook still deletes the old
  -- marks, but the trailing apply_now no-ops (window no longer shows the
  -- canvas), so nothing re-applies them.
  local sec2 = model.build_section("hidden.lua", old, changed_every(old, 7), "M")
  canvas.replace_section(st, 1, sec2)
  H.eq(lease.ids_by_path["hidden.lua"], nil, "hook cleared marks on the hidden splice")

  -- re-show the canvas buffer in the window: nvim_win_set_buf fires
  -- BufWinEnter, which must re-apply without an explicit apply_now call.
  vim.api.nvim_win_set_buf(st.win, st.buf)

  vim.wait(100, function()
    return lease.ids_by_path["hidden.lua"] ~= nil
  end)
  assert(lease.ids_by_path["hidden.lua"] and #lease.ids_by_path["hidden.lua"] > 0,
    "BufWinEnter re-applied marks with nobody calling apply_now manually")
  assert(hl.detach(lease))
end

local function tracked_count(lease)
  local n = 0
  for _, ids in pairs(lease.ids_by_path) do
    n = n + #ids
  end
  return n
end

local function ts_marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, TS_NS, 0, -1, {})
end

local function with_fake_highlighter_runtime(callback)
  local real_create_group = vim.api.nvim_create_augroup
  local real_delete_group_id = vim.api.nvim_del_augroup_by_id
  local real_delete_group_name = vim.api.nvim_del_augroup_by_name
  local real_create_autocmd = vim.api.nvim_create_autocmd
  local real_delete_autocmd = vim.api.nvim_del_autocmd
  local real_new_timer = vim.uv.new_timer
  local real_schedule = vim.schedule
  local real_schedule_wrap = vim.schedule_wrap
  local runtime = {
    groups = {},
    names = {},
    free_groups = {},
    next_group = 0,
    autocmds = {},
    next_autocmd = 0,
    timers = {},
    scheduled = {},
  }

  local function erase_autocmds(group)
    for id, autocmd in pairs(runtime.autocmds) do
      if autocmd.group == group then
        runtime.autocmds[id] = nil
      end
    end
  end

  vim.api.nvim_create_augroup = function(name, opts)
    local existing = runtime.names[name]
    if existing then
      if opts and opts.clear then erase_autocmds(existing) end
      return existing
    end
    local id = table.remove(runtime.free_groups)
    if not id then
      runtime.next_group = runtime.next_group + 1
      id = runtime.next_group
    end
    runtime.groups[id] = name
    runtime.names[name] = id
    return id
  end
  vim.api.nvim_del_augroup_by_id = function(id)
    local name = assert(runtime.groups[id], "missing fake augroup id")
    erase_autocmds(id)
    runtime.groups[id] = nil
    runtime.names[name] = nil
    runtime.free_groups[#runtime.free_groups + 1] = id
  end
  vim.api.nvim_del_augroup_by_name = function(name)
    local id = assert(runtime.names[name], "missing fake augroup name")
    return vim.api.nvim_del_augroup_by_id(id)
  end
  vim.api.nvim_create_autocmd = function(events, spec)
    local group = type(spec.group) == "string" and runtime.names[spec.group] or spec.group
    assert(group and runtime.groups[group], "missing fake autocmd group")
    runtime.next_autocmd = runtime.next_autocmd + 1
    local id = runtime.next_autocmd
    runtime.autocmds[id] = {
      id = id,
      group = group,
      events = type(events) == "table" and vim.deepcopy(events) or { events },
      callback = spec.callback,
    }
    return id
  end
  vim.api.nvim_del_autocmd = function(id)
    assert(runtime.autocmds[id], "missing fake autocmd")
    runtime.autocmds[id] = nil
  end
  vim.uv.new_timer = function()
    local timer = {
      starts = 0,
      stops = 0,
      closes = 0,
      closing = false,
    }
    function timer:start(_, _, fn)
      self.starts = self.starts + 1
      self.callback = fn
      return true
    end
    function timer:stop()
      self.stops = self.stops + 1
      local on_stop = self.on_stop
      self.on_stop = nil
      if on_stop then on_stop() end
      return true
    end
    function timer:is_closing()
      return self.closing
    end
    function timer:close()
      assert(not self.closing, "fake timer closed twice")
      self.closing = true
      self.closes = self.closes + 1
    end
    runtime.timers[#runtime.timers + 1] = timer
    return timer
  end
  vim.schedule = function(fn)
    runtime.scheduled[#runtime.scheduled + 1] = fn
  end
  vim.schedule_wrap = function(fn)
    return function(...)
      local args = { n = select("#", ...), ... }
      vim.schedule(function()
        fn(unpack(args, 1, args.n))
      end)
    end
  end

  function runtime:event(lease, event)
    for _, autocmd in pairs(runtime.autocmds) do
      if autocmd.group == lease.aug and vim.tbl_contains(autocmd.events, event) then
        return autocmd.callback
      end
    end
  end

  local ok, err = xpcall(function()
    callback(runtime)
  end, debug.traceback)
  vim.api.nvim_create_augroup = real_create_group
  vim.api.nvim_del_augroup_by_id = real_delete_group_id
  vim.api.nvim_del_augroup_by_name = real_delete_group_name
  vim.api.nvim_create_autocmd = real_create_autocmd
  vim.api.nvim_del_autocmd = real_delete_autocmd
  vim.uv.new_timer = real_new_timer
  vim.schedule = real_schedule
  vim.schedule_wrap = real_schedule_wrap
  if not ok then error(err, 0) end
end

-- --- lease independence ------------------------------------------------------
--
-- No module-global selector decides which highlighter is live. Two independent
-- reviews hold two independent leases; each one authenticates by exact private
-- identity, owns unique resources, and tears down without touching its peer.

T["hl_lease independent canvases hold concurrent highlighter leases"] = function()
  local a = independent_canvas(big_sections())
  local b = independent_canvas(big_sections())
  local lease_a, lease_b
  local ok, err = xpcall(function()
    lease_a = hl.attach(a, { margin = 5 }, { windows = function() return { a.win } end })
    lease_b = hl.attach(b, { margin = 5 }, { windows = function() return { b.win } end })

    assert(lease_a.ids_by_path["f1.lua"], "A applied inside its own buffer")
    assert(lease_b.ids_by_path["f1.lua"],
      "attaching B did not require superseding A")
    assert(lease_a.aug ~= lease_b.aug, "each lease owns a distinct augroup")
    assert(lease_a.group_name ~= lease_b.group_name, "group names never collide")
    assert(not rawequal(lease_a.timer, lease_b.timer), "each lease owns its timer")
    assert(hl.apply_now(lease_a), "A still reconciles after B attached")
    assert(hl.apply_now(lease_b), "B still reconciles alongside A")

    H.eq(#ts_marks(a.buf), tracked_count(lease_a), "A's buffer holds exactly A's marks")
    H.eq(#ts_marks(b.buf), tracked_count(lease_b), "B's buffer holds exactly B's marks")
    assert(tracked_count(lease_a) > 0 and tracked_count(lease_b) > 0, "sanity: both applied")

    local b_before = ts_marks(b.buf)
    local b_tracked = tracked_count(lease_b)
    assert(hl.detach(lease_a))
    H.eq(ts_marks(a.buf), {}, "A teardown clears exactly A's buffer")
    H.eq(ts_marks(b.buf), b_before, "A teardown never touches a peer's marks")
    H.eq(tracked_count(lease_b), b_tracked, "A teardown never touches peer bookkeeping")
    H.eq(#vim.api.nvim_get_autocmds({ group = lease_b.aug }), 6,
      "B retains exactly its own viewport event sources")
    assert(not lease_b.timer:is_closing(), "A teardown never closes a peer's timer")
    assert(hl.apply_now(lease_b), "B survives its peer's teardown")

    assert(hl.detach(lease_b))
    H.eq(ts_marks(b.buf), {}, "B teardown clears its own buffer")
  end, debug.traceback)

  if lease_a then pcall(hl.detach, lease_a) end
  if lease_b then pcall(hl.detach, lease_b) end
  close_canvas(a)
  close_canvas(b)
  if not ok then error(err, 0) end
end

T["hl_lease a forged shell cannot authenticate as a lease"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local lease = hl.attach(st, { margin = 5 })
  local before = ts_marks(st.buf)
  assert(#before > 0, "sanity: the real lease applied marks")
  local cached = hl._cache_size(lease)
  assert(cached > 0, "sanity: the real lease holds a parse cache")

  local copy = {}
  for k, v in pairs(lease) do
    copy[k] = v
  end
  local forgeries = {
    copy,
    setmetatable({}, { __index = lease }),
    { disposed = false, id = lease.id, group_name = lease.group_name, state = st },
    "not a table",
    nil,
  }
  for i = 1, 5 do
    local forged = forgeries[i]
    H.eq(hl.apply_now(forged), false, "a forged handle cannot drive reconciliation")
    H.eq(hl.detach(forged), false, "a forged handle cannot tear down a real lease")
    H.eq(hl.invalidate(forged, "f1.lua"), false, "a forged handle cannot evict the cache")
    H.eq(hl._cache_size(forged), 0, "a forged handle reports no cache")
  end

  H.eq(ts_marks(st.buf), before, "no forgery disturbed the real lease's marks")
  H.eq(hl._cache_size(lease), cached, "no forgery disturbed the real lease's cache")
  assert(hl.apply_now(lease), "the real lease still reconciles")
  assert(hl.detach(lease))
end

T["hl_lease out-of-order detach keeps the consumer's own hook reachable"] = function()
  local st = canvas.open(big_sections(), {})
  local render_calls, replace_calls = 0, 0
  local prior_render = function() render_calls = render_calls + 1 end
  local prior_replace = function() replace_calls = replace_calls + 1 end
  st.hooks = { on_render_all = prior_render, on_section_replaced = prior_replace }
  local windows = function() return {} end

  local first = hl.attach(st, { margin = 0 }, { windows = windows })
  local second = hl.attach(st, { margin = 0 }, { windows = windows })

  -- The inner lease leaves first, so its wrapper is spliced out of the middle
  -- of the chain rather than restored from the top of it.
  assert(hl.detach(first), "the inner lease detaches independently")
  st.hooks.on_render_all()
  st.hooks.on_section_replaced("f1.lua")
  H.eq({ render_calls, replace_calls }, { 1, 1 },
    "the surviving wrapper still reaches the consumer's own hooks")

  assert(hl.detach(second))
  assert(rawequal(st.hooks.on_render_all, prior_render),
    "the last lease restores the consumer's own render hook by identity")
  assert(rawequal(st.hooks.on_section_replaced, prior_replace),
    "the last lease restores the consumer's own replace hook by identity")
  st.hooks.on_render_all()
  st.hooks.on_section_replaced("f1.lua")
  H.eq({ render_calls, replace_calls }, { 2, 2 }, "no wrapper remains in the way")
end

T["hl_lease claim publishes the exact lease before any resource exists"] = function()
  local st = canvas.open({}, {})
  local published, timers_at_claim
  local lease = hl.attach(st, { margin = 0 }, {
    windows = function() return {} end,
    claim = function(candidate)
      published = candidate
      timers_at_claim = candidate.timer
      return true
    end,
  })
  assert(rawequal(published, lease), "claim received the exact returned lease")
  H.eq(timers_at_claim, nil, "claim ran before the first resource was allocated")
  assert(hl.detach(lease))
end

T["hl_lease a refused claim allocates nothing and returns nil"] = function()
  local st = canvas.open({}, {})
  local timers = 0
  local real_new_timer = vim.uv.new_timer
  vim.uv.new_timer = function()
    timers = timers + 1
    return real_new_timer()
  end
  local lease = hl.attach(st, { margin = 0 }, {
    windows = function() return {} end,
    claim = function() return false end,
  })
  vim.uv.new_timer = real_new_timer
  H.eq(lease, nil, "a refused claim yields no lease")
  H.eq(timers, 0, "a refused claim allocates no timer")
end

T["hl_lease release runs exactly once on exact teardown"] = function()
  local st = canvas.open({}, {})
  local released = 0
  local lease = hl.attach(st, { margin = 0 }, {
    windows = function() return {} end,
    claim = function() return true end,
    release = function() released = released + 1 end,
  })
  assert(hl.detach(lease))
  H.eq(released, 1, "exact teardown released the owner slot once")
  H.eq(hl.detach(lease), false, "a second detach is inert")
  H.eq(released, 1, "an inert detach does not release again")
end

T["hl_lease a fenced-off lease performs no reconciliation"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local alive = true
  local lease = hl.attach(st, { margin = 5 }, {
    alive = function() return alive end,
  })
  local before = ts_marks(st.buf)
  assert(#before > 0, "sanity: attach applied marks")

  alive = false
  vim.api.nvim_win_call(st.win, function()
    vim.cmd("normal! G")
  end)
  H.eq(hl.apply_now(lease), false, "a fenced-off lease refuses to reconcile")
  H.eq(ts_marks(st.buf), before, "a fenced-off lease changed nothing in the namespace")
  H.eq(hl.invalidate(lease, "f1.lua"), true,
    "the generation fence does not revoke exact private identity")

  alive = true
  assert(hl.apply_now(lease), "lifting the fence restores reconciliation")
  assert(hl.detach(lease))
  H.eq(ts_marks(st.buf), {}, "teardown still removes exactly its own marks")
end

T["hl_lease stale event timer and scheduled callbacks cannot cross teardown"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  with_fake_highlighter_runtime(function(runtime)
    local windows = function() return { st.win } end
    local lease_a = hl.attach(st, { margin = 0, debounce_ms = 1 }, { windows = windows })
    local callback_a = assert(runtime:event(lease_a, "WinScrolled"))
    vim.api.nvim_win_call(st.win, function()
      vim.cmd("normal! G")
    end)
    callback_a({ match = tostring(st.win) })
    local timer_a = lease_a.timer
    H.eq(timer_a.starts, 1, "A scroll arms A's timer")
    local raw_a = assert(timer_a.callback)
    raw_a()
    local scheduled_a = assert(runtime.scheduled[#runtime.scheduled])

    assert(hl.detach(lease_a), "the owner disposes A")
    local lease_b = hl.attach(st, { margin = 0, debounce_ms = 1 }, { windows = windows })
    local before = ts_marks(st.buf)
    local stops_after_detach = timer_a.stops
    callback_a({ match = tostring(st.win) })
    raw_a()
    scheduled_a()
    H.eq(ts_marks(st.buf), before, "all three retained A callback stages are inert")
    H.eq(timer_a.starts, 1, "stale A event did not rearm its timer")
    H.eq(timer_a.stops, stops_after_detach, "stale A callbacks did not touch its handle")
    H.eq(timer_a.closes, 1, "A timer closed exactly once")
    H.eq(hl.detach(lease_a), false, "a disposed lease cannot be torn down twice")
    assert(runtime.groups[lease_b.aug], "B's unique group remains live")

    local callback_b = assert(runtime:event(lease_b, "WinScrolled"))
    callback_b({ match = tostring(st.win) })
    H.eq(lease_b.timer.starts, 1, "B's event source and timer remain functional")
    local timer_b = lease_b.timer
    assert(hl.detach(lease_b))
    H.eq(timer_b.closes, 1, "B timer closes exactly once")

    local lease_c = hl.attach(st, { margin = 0 }, { windows = windows })
    local timer_c = lease_c.timer
    local lease_d
    timer_c.on_stop = function()
      lease_d = hl.attach(st, { margin = 0 }, { windows = windows })
    end
    assert(hl.detach(lease_c))
    assert(lease_d, "C timer stop installed replacement D")
    assert(runtime.groups[lease_d.aug],
      "outer C teardown cannot delete D even when fake group IDs are recycled")
    assert(not lease_d.timer.closing, "outer C teardown cannot close D's timer")
    H.eq(timer_c.closes, 1, "C timer closes exactly once after reentrant stop")
    assert(hl.detach(lease_d))
  end)
end

T["hl_lease uses the union of split viewports without changing state win"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local first = st.win
  vim.api.nvim_set_current_win(first)
  vim.cmd("vsplit")
  local second = vim.api.nvim_get_current_win()
  local s3 = (canvas.section_rows(st, 3))
  vim.api.nvim_win_call(first, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  vim.api.nvim_win_call(second, function()
    vim.fn.winrestview({ topline = s3 + 1, lnum = s3 + 1 })
  end)
  st.win = first

  local lease
  local ok, err = xpcall(function()
    lease = hl.attach(st, { margin = 0 }, {
      windows = function()
        return { first, second }
      end,
    })
    assert(lease.ids_by_path["f1.lua"], "top split applies its visible section")
    H.eq(lease.ids_by_path["f2.lua"], nil,
      "the gap between disjoint viewports is not treated as visible")
    assert(lease.ids_by_path["f3.lua"], "bottom split applies its visible section")
    H.eq(st.win, first, "highlighter never elects or mutates the primary window")
  end, debug.traceback)

  if lease then hl.detach(lease) end
  if vim.api.nvim_win_is_valid(second) then
    vim.api.nvim_win_close(second, true)
  end
  if vim.api.nvim_win_is_valid(first) then
    vim.api.nvim_set_current_win(first)
  end
  if not ok then error(err, 0) end
end

T["hl_lease empty window coverage preserves existing marks"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local windows = { st.win }
  local lease = hl.attach(st, { margin = 0 }, {
    windows = function()
      return windows
    end,
  })
  local before = ts_marks(st.buf)
  assert(lease.ids_by_path["f1.lua"] and #before > 0, "sanity: top section applied")

  windows = {}
  vim.api.nvim_win_call(st.win, function()
    vim.cmd("normal! G")
  end)
  H.eq(hl.apply_now(lease), false, "an unobserved viewport performs no reconciliation")
  H.eq(ts_marks(st.buf), before, "temporarily hidden Canvas preserves exact marks")
  assert(lease.ids_by_path["f1.lua"], "bookkeeping is preserved with the marks")
  assert(hl.detach(lease))
  H.eq(ts_marks(st.buf), {}, "detach still removes exact marks while hidden")
end

T["hl_lease composes and exactly restores canvas hooks"] = function()
  local st = canvas.open(big_sections(), {})
  local render_calls, replace_calls = 0, 0
  local prior_render = function() render_calls = render_calls + 1 end
  local prior_replace = function() replace_calls = replace_calls + 1 end
  st.hooks = {
    on_render_all = prior_render,
    on_section_replaced = prior_replace,
  }
  local lease = hl.attach(st, { margin = 0 }, {
    windows = function() return {} end,
  })
  local stale_render = st.hooks.on_render_all
  local stale_replace = st.hooks.on_section_replaced

  stale_render()
  stale_replace("f1.lua")
  H.eq({ render_calls, replace_calls }, { 1, 1 }, "predecessor hooks remain composed")
  assert(hl.detach(lease))
  assert(rawequal(st.hooks.on_render_all, prior_render), "render hook restored by identity")
  assert(rawequal(st.hooks.on_section_replaced, prior_replace),
    "replace hook restored by identity")
  H.eq(lease.state, nil, "detached stale closure cannot retain canvas state")
  H.eq(lease.callbacks, {}, "detached stale closure cannot retain owner callbacks")
  H.eq(lease.cache, {}, "detached stale closure cannot retain sources or syntax trees")
  H.eq(lease.hooks, nil, "detached lease releases its hook graph")

  stale_render()
  stale_replace("f1.lua")
  H.eq({ render_calls, replace_calls }, { 1, 1 }, "held stale wrappers are inert")

  local lease2 = hl.attach(st, { margin = 0 }, {
    windows = function() return {} end,
  })
  local override = function() end
  st.hooks.on_render_all = override
  assert(hl.detach(lease2))
  assert(rawequal(st.hooks.on_render_all, override),
    "detach does not overwrite a hook installed after attach")
  assert(rawequal(st.hooks.on_section_replaced, prior_replace))
end

T["hl_lease direct window callback faults stay observable"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local broken = false
  local lease = hl.attach(st, { margin = 0 }, {
    windows = function()
      if broken then error("window callback boom") end
      return { st.win }
    end,
  })
  broken = true
  local ok, err = pcall(hl.apply_now, lease)
  assert(not ok and tostring(err):find("window callback boom", 1, true),
    "direct apply must expose a broken owner callback")
  broken = false
  assert(hl.detach(lease))
end

T["hl_lease detach removes exact resources and never clears foreign marks"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local foreign_id = 900001
  vim.api.nvim_buf_set_extmark(st.buf, TS_NS, 0, 0, {
    id = foreign_id,
    end_col = 1,
    hl_group = "Comment",
  })
  local lease = hl.attach(st, { margin = 0 })
  local timer = lease.timer
  local commands = vim.api.nvim_get_autocmds({ group = lease.aug })
  local events = {}
  for _, command in ipairs(commands) do
    events[command.event] = true
  end
  for _, event in ipairs({
    "WinScrolled", "BufWinEnter", "BufWinLeave", "WinLeave", "WinClosed", "WinResized",
  }) do
    assert(events[event], "missing viewport reconciliation event " .. event)
  end
  H.eq(#ts_marks(st.buf), tracked_count(lease) + 1,
    "foreign namespace mark is not claimed by the lease")

  assert(hl.detach(lease))
  assert(timer:is_closing(), "detach stops and closes its uv timer")
  H.eq(vim.api.nvim_buf_get_extmark_by_id(st.buf, TS_NS, foreign_id, {}), { 0, 0 },
    "exact teardown preserves a foreign ID in the shared namespace")
  H.eq(hl.detach(lease), false, "stale exact detach is inert")
  vim.api.nvim_buf_del_extmark(st.buf, TS_NS, foreign_id)
end

T["hl_lease detach falls back from group id to its unique name"] = function()
  local st = canvas.open({}, {})
  local lease = hl.attach(st, { margin = 0 }, {
    windows = function() return {} end,
  })
  local group_name = lease.group_name
  local real_delete = vim.api.nvim_del_augroup_by_id
  vim.api.nvim_del_augroup_by_id = function()
    error("injected group-id deletion failure")
  end
  local ok, result = pcall(hl.detach, lease)
  vim.api.nvim_del_augroup_by_id = real_delete

  assert(ok and result, "detach remains terminal after the exact-name fallback")
  local exists = pcall(vim.api.nvim_get_autocmds, { group = group_name })
  assert(not exists, "unique highlighter group was removed by name")
end

T["hl_lease failed eviction stays owned for detach retry"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local lease = hl.attach(st, { margin = 0 })
  local ids = assert(lease.ids_by_path["f1.lua"])
  local target = ids[1]
  assert(#vim.api.nvim_buf_get_extmark_by_id(st.buf, TS_NS, target, {}) > 0)
  vim.api.nvim_win_call(st.win, function()
    vim.cmd("normal! G")
  end)

  local real_delete = vim.api.nvim_buf_del_extmark
  local failed = false
  vim.api.nvim_buf_del_extmark = function(buf, ns, id)
    if id == target and not failed then
      failed = true
      error("injected one-shot extmark deletion failure")
    end
    return real_delete(buf, ns, id)
  end
  local applied = hl.apply_now(lease)
  vim.api.nvim_buf_del_extmark = real_delete

  H.eq(applied, false, "failed eviction is surfaced to the synchronous caller")
  assert(failed, "fault hit the exact target ID")
  assert(next(lease.deleting) ~= nil, "whole ID list remains exact-owned")
  assert(#vim.api.nvim_buf_get_extmark_by_id(st.buf, TS_NS, target, {}) > 0,
    "failed ID is still present before teardown retry")
  assert(hl.detach(lease))
  H.eq(ts_marks(st.buf), {}, "detach retries the retained list and leaves no orphan")
end

T["hl_lease retry accepts an extmark already deleted before a thrown return"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local lease = hl.attach(st, { margin = 0 })
  local target = assert(lease.ids_by_path["f1.lua"])[1]
  vim.api.nvim_win_call(st.win, function()
    vim.cmd("normal! G")
  end)

  local real_delete = vim.api.nvim_buf_del_extmark
  local failed = false
  vim.api.nvim_buf_del_extmark = function(buf, ns, id)
    local deleted = real_delete(buf, ns, id)
    if id == target and not failed then
      failed = true
      error("injected post-delete return failure")
    end
    return deleted
  end
  H.eq(hl.apply_now(lease), false, "thrown return keeps the path exact-owned")
  vim.api.nvim_buf_del_extmark = real_delete
  assert(next(lease.deleting) ~= nil and lease.ids_by_path["f1.lua"],
    "failed return retained both transaction and path association")

  assert(hl.apply_now(lease), "retry treats already-absent IDs as cleaned")
  H.eq(lease.ids_by_path["f1.lua"], nil, "evicted path no longer looks applied")
  H.eq(next(lease.deleting), nil, "retry releases the deletion transaction")
  assert(hl.detach(lease))
  H.eq(ts_marks(st.buf), {})
end

T["hl_lease full render deletion failure retains every unprocessed path"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local lease = hl.attach(st, { margin = 1000 })
  local original = {}
  for _, ids in pairs(lease.ids_by_path) do
    for _, id in ipairs(ids) do original[id] = true end
  end
  local original_n = vim.tbl_count(original)
  assert(original_n > 0 and vim.tbl_count(lease.ids_by_path) == 3,
    "sanity: multiple paths are marked")

  local real_delete = vim.api.nvim_buf_del_extmark
  local failed = false
  vim.api.nvim_buf_del_extmark = function(buf, ns, id)
    if ns == TS_NS and not failed then
      failed = true
      error("injected first-list deletion failure")
    end
    return real_delete(buf, ns, id)
  end
  canvas.render_all(st, big_sections())
  vim.api.nvim_buf_del_extmark = real_delete
  assert(failed, "render hook hit the injected fault")

  local owned = {}
  local function collect(ids)
    for _, id in ipairs(ids) do owned[id] = true end
  end
  for _, ids in pairs(lease.ids_by_path) do collect(ids) end
  for ids in pairs(lease.deleting) do collect(ids) end
  for ids in pairs(lease.pending) do collect(ids) end
  H.eq(vim.tbl_count(owned), original_n,
    "failed list and every unprocessed path remain in exact ownership")
  for id in pairs(original) do
    assert(owned[id], "render fault lost ownership of extmark " .. id)
  end

  assert(hl.detach(lease))
  H.eq(ts_marks(st.buf), {}, "detach removes the failed and unprocessed path marks")
end

T["hl_lease rolls back a set extmark call that writes then throws"] = function()
  local st = canvas.open(big_sections(), {})
  reset_view(st)
  local visible = false
  local lease = hl.attach(st, { margin = 1000 }, {
    windows = function()
      return visible and { st.win } or {}
    end,
  })
  visible = true

  local real_set = vim.api.nvim_buf_set_extmark
  local calls = 0
  vim.api.nvim_buf_set_extmark = function(buf, ns, row, col, opts)
    local id = real_set(buf, ns, row, col, opts)
    if ns == TS_NS then
      calls = calls + 1
      if calls == 2 then
        error("set extmark boom")
      end
    end
    return id
  end
  local ok, err = pcall(hl.apply_now, lease)
  vim.api.nvim_buf_set_extmark = real_set

  assert(not ok and tostring(err):find("set extmark boom", 1, true),
    "placement error remains observable")
  H.eq(ts_marks(st.buf), {}, "every mark from the failed section was rolled back")
  H.eq(next(lease.ids_by_path), nil, "failed transaction was never published")
  assert(hl.apply_now(lease), "the same lease can retry after rollback")
  assert(tracked_count(lease) > 0)
  assert(hl.detach(lease))
end

T["hl_lease late predecessor write cannot orphan a reserved ID"] = function()
  local st = canvas.open({
    model.build_section("late.lua", OLD, NEW, "M"),
  }, {})
  reset_view(st)
  local visible = false
  local function windows()
    return visible and { st.win } or {}
  end
  local predecessor = hl.attach(st, { margin = 1000 }, { windows = windows })
  visible = true

  local real_set = vim.api.nvim_buf_set_extmark
  local replacement
  local replacing = false
  vim.api.nvim_buf_set_extmark = function(...)
    if not replacing then
      replacing = true
      -- The owner disposes A and starts B from inside A's own placement call.
      assert(hl.detach(predecessor))
      replacement = hl.attach(st, { margin = 1000 }, { windows = windows })
      replacing = false
    end
    -- Deliberately land A's reserved ID only after B has completed its own
    -- initial apply, i.e. after A had already been torn down.
    return real_set(...)
  end
  local ok, err = pcall(hl.apply_now, predecessor)
  vim.api.nvim_buf_set_extmark = real_set

  assert(ok, err)
  assert(replacement, "set wrapper installed the replacement")
  H.eq(#ts_marks(st.buf), tracked_count(replacement),
    "namespace contains only IDs tracked by replacement B")
  H.eq(hl.detach(predecessor), false, "a disposed A cannot be torn down again")
  assert(hl.detach(replacement))
  H.eq(ts_marks(st.buf), {}, "B teardown leaves no late A orphan")
end

T["hl_lease same lease render epoch cancels an old placement transaction"] = function()
  local original = model.build_section("epoch.lua", OLD, NEW, "M")
  local replacement_section = model.build_section(
    "epoch.lua", "local old = 1\n", "local fresh = 2\n", "M")
  local st = canvas.open({ original }, {})
  reset_view(st)
  local visible = false
  local lease = hl.attach(st, { margin = 1000 }, {
    windows = function()
      return visible and { st.win } or {}
    end,
  })
  visible = true

  local real_set = vim.api.nvim_buf_set_extmark
  local reshaped = false
  vim.api.nvim_buf_set_extmark = function(...)
    if not reshaped then
      reshaped = true
      canvas.render_all(st, { replacement_section })
    end
    return real_set(...)
  end
  local ok, err = pcall(hl.apply_now, lease)
  vim.api.nvim_buf_set_extmark = real_set

  assert(ok, err)
  H.eq(ts_marks(st.buf), {}, "old-epoch transaction deletes its late mark")
  H.eq(next(lease.ids_by_path), nil, "old model was never published")
  H.eq(hl._cache_size(lease), 0, "render epoch also releases the old parse cache")
  assert(hl.apply_now(lease), "new epoch remains usable")
  assert(lease.ids_by_path["epoch.lua"], "replacement section highlights on retry")
  assert(hl.detach(lease))
end

-- --- reentrant disposal during partial resource creation ---------------------
--
-- With no module-global selector left, "superseded" means exactly one thing:
-- the owner disposed THIS lease while its own attach was still allocating.
-- `claim` publishes the exact identity before the first resource exists, which
-- is what lets these tests reach in and dispose it mid-flight.

--- Attach a lease whose `claim` hands the exact candidate to `on_claim`, so a
--- fault injector can dispose it from inside a later allocation call.
local function attaching_lease(st, on_claim)
  local captured
  local ok, err = pcall(hl.attach, st, { margin = 0 }, {
    windows = function() return {} end,
    claim = function(candidate)
      captured = candidate
      if on_claim then on_claim(candidate) end
      return true
    end,
  })
  return ok, err, captured
end

T["hl_lease closes a timer returned after reentrant disposal"] = function()
  local st = canvas.open({}, {})
  local real_new_timer = vim.uv.new_timer
  local first = true
  local orphan, victim, peer
  vim.uv.new_timer = function()
    if first then
      first = false
      orphan = real_new_timer()
      -- The owner disposes the half-built lease and opens an independent
      -- review before this allocation call ever returns its handle.
      assert(hl.detach(victim))
      peer = hl.attach(st, { margin = 0 }, { windows = function() return {} end })
      return orphan
    end
    return real_new_timer()
  end
  local ok, err = attaching_lease(st, function(candidate)
    victim = candidate
  end)
  vim.uv.new_timer = real_new_timer

  assert(not ok and tostring(err):find("disposed", 1, true),
    "the disposed attach must fail: " .. tostring(err))
  assert(peer, "the independent peer attached")
  assert(orphan:is_closing(), "late unpublished timer is closed directly")
  assert(not peer.timer:is_closing(), "the peer's timer is untouched")
  assert(hl.detach(peer))
end

T["hl_lease unique group created after reentrant disposal is deleted by name"] = function()
  local st = canvas.open({}, {})
  local real_create = vim.api.nvim_create_augroup
  local first = true
  local victim_name, victim, peer
  vim.api.nvim_create_augroup = function(name, opts)
    if first and name:match("^canvasdiff%.highlight%.") then
      first = false
      victim_name = name
      assert(hl.detach(victim))
      peer = hl.attach(st, { margin = 0 }, { windows = function() return {} end })
    end
    return real_create(name, opts)
  end
  local ok, err = attaching_lease(st, function(candidate)
    victim = candidate
  end)
  vim.api.nvim_create_augroup = real_create

  assert(not ok and tostring(err):find("disposed", 1, true),
    "the disposed attach must fail: " .. tostring(err))
  assert(peer, "the independent peer attached")
  H.eq(#vim.api.nvim_get_autocmds({ group = peer.aug }), 6,
    "a late group creation by a disposed lease cannot clear a peer's event sources")
  local stale_ok = pcall(vim.api.nvim_get_autocmds, { group = victim_name })
  assert(not stale_ok, "the disposed lease's group was deleted by its unique name")
  assert(hl.detach(peer))
end

T["hl_lease stale autocmd creation cannot join a recycled peer group"] = function()
  local st = canvas.open({}, {})
  local real_create = vim.api.nvim_create_autocmd
  local first = true
  local victim, peer
  vim.api.nvim_create_autocmd = function(events, spec)
    if first and type(spec.group) == "string" and spec.group:match("^canvasdiff%.highlight%.") then
      first = false
      assert(hl.detach(victim))
      peer = hl.attach(st, { margin = 0 }, { windows = function() return {} end })
    end
    return real_create(events, spec)
  end
  local ok = attaching_lease(st, function(candidate)
    victim = candidate
  end)
  vim.api.nvim_create_autocmd = real_create

  assert(not ok, "a create against a deleted unique group must fail")
  assert(peer, "the independent peer attached")
  H.eq(#vim.api.nvim_get_autocmds({ group = peer.aug }), 6,
    "the peer retains exactly its own viewport event sources")
  assert(hl.detach(peer))
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
    if d and (d.hl_group == "CanvasDiffAdd" or d.hl_group == "CanvasDiffDel") then
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
T["hl_rows the row tints go through overridable CanvasDiff aliases"] = function()
  for _, g in ipairs({ "CanvasDiffAdd", "CanvasDiffDel" }) do
    local direct = vim.api.nvim_get_hl(0, { name = g, link = false })
    assert(next(direct) ~= nil, g .. " must be defined, or the diff rows render unstyled")
  end
  -- `default = true` throughout, so a colourscheme that defines these wins.
  -- The shipped default is the computed elevation (a bg, no link); an
  -- override may be anything with a background.
  local linked = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = true })
  assert(linked.link == "DiffAdd" or linked.bg,
    "CanvasDiffAdd should carry a quiet tint or an override, got: "
    .. vim.inspect(linked))
end

-- --- the diff-row group values -----------------------------------------------
--
-- The field is DERIVED from the live scheme, and it is one statement per
-- channel: a single hueless elevation says "changed", a dimmed foreground
-- says "removed", and the green/red lives only on the margin (prefix and
-- gutter). These tests pin the relationships between the groups, never the
-- measured colour values -- those depend on the runner's scheme.

local config = require("canvasdiff.config")
local render = require("canvasdiff.canvas.format")

-- Rec.709 luma, the same measure the factors were chosen by.
local function luma(rgb)
  if not rgb then return nil end
  local r = math.floor(rgb / 65536) % 256
  local g = math.floor(rgb / 256) % 256
  local b = rgb % 256
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

-- Every group ensure_diff_hl authors. The module's authorship record is a
-- singleton, so a group an earlier test left defined would satisfy
-- set_diff_default and mask a broken derive; each derivation test clears
-- them all first.
local DIFF_GROUPS = {
  "CanvasDiffAdd", "CanvasDiffDel", "CanvasDiffGhost",
  "CanvasDiffPrefixAdd", "CanvasDiffPrefixDel",
  "CanvasDiffGutterAdd", "CanvasDiffGutterDel",
  "CanvasDiffFileBar",
}

local function reset_diff_groups()
  for _, g in ipairs(DIFF_GROUPS) do
    vim.api.nvim_set_hl(0, g, {})
  end
end

T["hl_rows blend interpolates channelwise and tolerates a missing endpoint"] = function()
  H.eq(render.blend(0x000000, 0xffffff, 0), "#000000")
  H.eq(render.blend(0x000000, 0xffffff, 1), "#ffffff")
  H.eq(render.blend(0x004080, 0x808080, 0.5), "#406080")
  -- A missing endpoint yields the other unchanged: a scheme without a Normal
  -- background (transparent terminals) keeps the raw tint rather than crashing
  -- or inventing black.
  H.eq(render.blend(nil, 0x123456, 0.6), "#123456")
  H.eq(render.blend(0x123456, nil, 0.6), "#123456")
  H.eq(render.blend(nil, nil, 0.6), nil)
end

T["hl_rows the field is one neutral elevation shared by add and del"] = function()
  reset_diff_groups()
  render.ensure_diff_hl()
  local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false })
  local del = vim.api.nvim_get_hl(0, { name = "CanvasDiffDel", link = false })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  H.eq(add.bg, del.bg, "one elevation, not two hues")
  assert(add.bg ~= normal.bg, "the elevation must differ from Normal")
  local diff_add = vim.api.nvim_get_hl(0, { name = "DiffAdd", link = false })
  assert(add.bg ~= diff_add.bg, "the elevation is not the scheme's diff wash")
  assert(add.fg == nil, "add rows keep full-contrast syntax")
  assert(del.fg ~= nil, "a deleted file's real rows read dimmed")
end

T["hl_rows ghosts have no background and a dimmed, struck foreground"] = function()
  reset_diff_groups()
  render.ensure_diff_hl()
  local ghost = vim.api.nvim_get_hl(0, { name = "CanvasDiffGhost", link = false })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  H.eq(ghost.bg, nil)
  assert(ghost.fg and ghost.fg ~= normal.fg, "dimmed, not Normal's own fg")
  assert(luma(ghost.fg) < luma(normal.fg) and luma(ghost.fg) > luma(normal.bg),
    "dimmed means moved toward the background, not past it and not brighter")
  H.eq(ghost.strikethrough, nil,
    "not struck: the dim carries 'removed' on its own now, and the `-` prefix"
      .. " is the shape channel that outlives colour")

  -- The dim's ceiling is @comment -- a deletion must never read dimmer than
  -- one -- and with the strike gone this clearance is the whole distinction
  -- between a deleted block and a comment block. The
  -- factor is chosen to clear it with room, so the two channels split the
  -- work; drift back toward the ceiling and this fails before the docs that
  -- quote the clearance go quietly false.
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  if comment.fg then
    local bg = luma(normal.bg)
    local clearance = math.abs(luma(ghost.fg) - bg) - math.abs(luma(comment.fg) - bg)
    assert(clearance >= 15,
      ("a ghost must clear @comment by a real margin, not sit on it (got %.1f)")
        :format(clearance))
  end
end

T["hl_rows margin hue lives on the prefix and gutter groups, identically"] = function()
  reset_diff_groups()
  render.ensure_diff_hl()
  for _, pair in ipairs({
    { "CanvasDiffPrefixAdd", "CanvasDiffGutterAdd" },
    { "CanvasDiffPrefixDel", "CanvasDiffGutterDel" },
  }) do
    local prefix = vim.api.nvim_get_hl(0, { name = pair[1], link = false })
    local gutter = vim.api.nvim_get_hl(0, { name = pair[2], link = false })
    assert(prefix.fg, pair[1] .. " must carry a foreground")
    H.eq(prefix.fg, gutter.fg, "prefix and bar are the same statement")
    H.eq(prefix.bg, nil)
  end
  local ga = vim.api.nvim_get_hl(0, { name = "CanvasDiffGutterAdd", link = true })
  H.eq(ga.link, nil, "no longer a link to Added")
end

T["hl_bar the header bar is derived, not Folded's luck"] = function()
  reset_diff_groups()
  render.ensure_diff_hl()
  local bar = vim.api.nvim_get_hl(0, { name = "CanvasDiffFileBar", link = true })
  H.eq(bar.link, nil, "no longer linked to Folded")
  assert(bar.bg, "the bar is a background statement")
end

T["hl_bar the bar clears the row elevation, which clears Normal"] = function()
  reset_diff_groups()
  render.ensure_diff_hl()
  local normal = luma(vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg or 0)
  local field = luma(vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false }).bg)
  local bar = luma(vim.api.nvim_get_hl(0, { name = "CanvasDiffFileBar", link = false }).bg)
  assert(math.abs(field - normal) > 0, "sanity: the field is elevated")
  assert(math.abs(bar - normal) > math.abs(field - normal),
    "the bar must clear the field, not just Normal")
end

T["hl_rows a user's pre-defined group survives the derivation"] = function()
  reset_diff_groups()
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", { bg = 0x123456 })
  render.ensure_diff_hl()
  local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false })
  H.eq(add.bg, 0x123456, "an explicit override always wins")
  reset_diff_groups()
end

T["hl_rows a user definition of CanvasDiffAdd survives every ensure"] = function()
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", { bg = 0x123456 })
  local ok, err = pcall(function()
    config.setup({})
    canvas.open({ model.build_section("override.lua", OLD, NEW, "M") }, {})
    H.eq(vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false }).bg, 0x123456,
      "a derived default must never clobber an explicit user definition")
  end)
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", {})
  config.setup({})
  assert(ok, err)
end

return T
