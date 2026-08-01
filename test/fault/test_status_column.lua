-- Status-column ownership under concurrency, reentrancy and injected faults.

local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")
local statuscol = require("canvasdiff.ui").status_column
local Surface = require("canvasdiff.Surface")

local T = {}

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

-- ~55 rows per section (6 separated hunks): same idiom as test_sidebar.lua's
-- big_section, tall enough that scroll-targeting assertions can't clamp to
-- the wrong section against the ~22-row headless window.
local function big_section(path, tag)
  local old = bigtext(60, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 10, 60, 10 do
    lines[i] = lines[i] .. " changed"
  end
  local new = table.concat(lines, "\n")
  return model.build_section(path, old, new, "M")
end

local function three_sections()
  return {
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
  }
end

-- 0-based row of the LAST hunk header across all sections, and the
-- 0-based exclusive end row of the section it belongs to.
local function last_hunk_row_and_section_end(st)
  local last_row, seg_end
  for i, section in ipairs(st.sections) do
    local s0, e0 = canvas.section_rows(st, i)
    for idx, entry in ipairs(section.entries) do
      if entry.kind == "hunk_hdr" then
        last_row = s0 + idx - 1
        seg_end = e0
      end
    end
  end
  return last_row, seg_end
end
local STATUSCOL_EXPR = "%!v:lua.require'canvasdiff.ui.status_column'.text()"

-- Leases are independent, so there is no "detach whatever is current" sweep to
-- fall back on: every lease belongs to whoever opened it. These tests share one
-- process-wide canvas buffer, so one leaked lease keeps an armed BufWinEnter
-- that claims the next test's windows first. Recording every lease this file
-- creates -- including the ones its own fault injectors attach reentrantly --
-- is what replaces the old global sweep.
local tracked_leases = {}
do
  local real_attach = statuscol.attach
  statuscol.attach = function(...)
    local lease = real_attach(...)
    if lease then
      tracked_leases[#tracked_leases + 1] = lease
    end
    return lease
  end
end

--- Dispose every lease opened so far, newest first.
local function detach_tracked()
  for i = #tracked_leases, 1, -1 do
    pcall(statuscol.detach, tracked_leases[i])
    tracked_leases[i] = nil
  end
end

--- Exact cleanup for one test's named leases. `detach_tracked` is the backstop;
--- naming them here keeps each test's own ownership legible.
local function detach_all(...)
  for i = 1, select("#", ...) do
    local lease = select(i, ...)
    if lease then
      pcall(statuscol.detach, lease)
    end
  end
end

local function with_fake_statuscolumn(callback)
  detach_tracked()
  local first_tracked = #tracked_leases + 1
  local real_create_group = vim.api.nvim_create_augroup
  local real_delete_group = vim.api.nvim_del_augroup_by_id
  local real_create_autocmd = vim.api.nvim_create_autocmd
  local real_get_option = vim.api.nvim_get_option_value
  local real_set_option = vim.api.nvim_set_option_value
  local real_schedule = vim.schedule
  local runtime = {
    groups = {},
    group_order = {},
    free_groups = {},
    next_group = 0,
    autocmds = {},
    options = {},
    scheduled = {},
    sets = {},
  }

  vim.api.nvim_create_augroup = function(name, _)
    local id = table.remove(runtime.free_groups)
    if not id then
      runtime.next_group = runtime.next_group + 1
      id = runtime.next_group
    end
    runtime.groups[id] = name
    runtime.group_order[#runtime.group_order + 1] = id
    return id
  end
  vim.api.nvim_del_augroup_by_id = function(id)
    assert(runtime.groups[id], "fake augroup already deleted")
    runtime.groups[id] = nil
    runtime.free_groups[#runtime.free_groups + 1] = id
  end
  vim.api.nvim_create_autocmd = function(event, spec)
    runtime.autocmds[#runtime.autocmds + 1] = {
      event = event,
      group = spec.group,
      callback = spec.callback,
    }
    return #runtime.autocmds
  end
  vim.api.nvim_get_option_value = function(name, spec)
    if name == "statuscolumn" and spec and spec.win then
      local hook = runtime.on_get
      if hook then
        hook(spec.win)
      end
      return runtime.options[spec.win] or ""
    end
    return real_get_option(name, spec)
  end
  vim.api.nvim_set_option_value = function(name, value, spec)
    if name == "statuscolumn" and spec and spec.win then
      local hook = runtime.on_set
      runtime.on_set = nil
      if hook then
        hook(spec.win, value)
      end
      runtime.options[spec.win] = value
      runtime.sets[#runtime.sets + 1] = { win = spec.win, value = value }
      return
    end
    return real_set_option(name, value, spec)
  end
  vim.schedule = function(fn)
    runtime.scheduled[#runtime.scheduled + 1] = fn
  end

  local ok, err = xpcall(function()
    callback(runtime)
  end, debug.traceback)
  runtime.on_get, runtime.on_set = nil, nil
  local cleanup_ok, cleanup_err = true, nil
  for i = #tracked_leases, first_tracked, -1 do
    local closed, err = pcall(statuscol.detach, tracked_leases[i])
    tracked_leases[i] = nil
    if not closed and cleanup_ok then
      cleanup_ok, cleanup_err = false, err
    end
  end
  vim.api.nvim_create_augroup = real_create_group
  vim.api.nvim_del_augroup_by_id = real_delete_group
  vim.api.nvim_create_autocmd = real_create_autocmd
  vim.api.nvim_get_option_value = real_get_option
  vim.api.nvim_set_option_value = real_set_option
  vim.schedule = real_schedule
  if ok and not cleanup_ok then
    ok, err = false, cleanup_err
  end
  assert(ok, err)
end

local function fake_autocmd(runtime, event, occurrence)
  local seen = 0
  for _, spec in ipairs(runtime.autocmds) do
    if spec.event == event then
      seen = seen + 1
      if seen == (occurrence or 1) then
        return spec.callback
      end
    end
  end
  error(("missing fake %s autocmd #%d"):format(event, occurrence or 1))
end

T["statuscol_ stale deferred leave cannot reach replacement"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local primary = st.win
  local foreign = vim.api.nvim_create_buf(false, true)
  local inherited = vim.api.nvim_open_win(st.buf, false, {
    relative = "editor", row = 0, col = 0, width = 20, height = 5,
  })

  local ok, err = pcall(function()
    with_fake_statuscolumn(function(runtime)
      runtime.options[primary] = "primary prior"
      runtime.options[inherited] = STATUSCOL_EXPR
      local views = { primary }
      local lease_a = statuscol.attach(st, {
        alive = function() return true end,
        windows = function() return views end,
      })
      -- Attach queues one reconcile of its own initial claim snapshot.
      local after_attach_a = #runtime.scheduled
      H.eq(after_attach_a, 1, "attach queued exactly its snapshot reconcile")
      local leave_a = fake_autocmd(runtime, "BufWinLeave", 1)
      local closed_a = fake_autocmd(runtime, "WinClosed", 1)
      local win_leave_a = fake_autocmd(runtime, "WinLeave", 1)
      local split_pre_a = fake_autocmd(runtime, "WinNewPre", 1)
      local tab_leave_a = fake_autocmd(runtime, "TabLeave", 1)
      local win_enter_a = fake_autocmd(runtime, "WinEnter", 1)
      local win_new_a = fake_autocmd(runtime, "WinNew", 1)
      vim.api.nvim_set_current_win(primary)
      leave_a()
      H.eq(#runtime.scheduled, after_attach_a + 1, "A captured one deferred leave")
      local a_leave = after_attach_a + 1

      H.eq(statuscol.detach(lease_a), true, "the owner disposes A")
      local lease_b = statuscol.attach(st, {
        alive = function() return true end,
        windows = function() return views end,
      })
      local after_attach_b = #runtime.scheduled
      local group_b = runtime.group_order[2]
      H.eq(runtime.options[primary], STATUSCOL_EXPR)
      H.eq(lease_a.disposed, true)
      H.eq(lease_a.state, nil, "disposed A releases its Surface")
      H.eq(next(lease_a.callbacks), nil, "disposed A releases callbacks")
      H.eq(next(lease_a.touched), nil, "disposed A releases per-window priors")
      H.eq(next(lease_a.tab_priors), nil, "disposed A releases tab priors")
      H.eq(next(lease_a.priors), nil, "disposed A releases known priors")
      H.eq(next(lease_a.leaving), nil, "disposed A releases leave tokens")
      H.eq(lease_a.last_canvas, nil, "disposed A releases source provenance")
      H.eq(lease_a.focused_win, nil, "disposed A releases focus provenance")
      H.eq(lease_a.aug, nil)
      H.eq(statuscol.detach(lease_a), false, "a disposed A cannot be torn down twice")
      assert(runtime.groups[group_b], "B's reused group survives a stale detach(A)")

      split_pre_a()
      tab_leave_a()
      win_enter_a()
      win_new_a()
      closed_a({ match = tostring(primary) })
      win_leave_a()
      H.eq(lease_a.pending_split, nil)
      H.eq(lease_a.pending_tab, nil)
      H.eq(lease_a.last_canvas, nil)
      H.eq(lease_a.focused_win, nil,
        "held stale global callbacks cannot repopulate disposed A")
      H.eq(next(lease_a.priors), nil)
      H.eq(next(lease_a.leaving), nil)
      H.eq(runtime.options[primary], STATUSCOL_EXPR,
        "held stale global callbacks cannot alter B's option")
      assert(runtime.groups[group_b],
        "held stale global callbacks cannot delete B's reused group")

      vim.api.nvim_win_set_buf(primary, foreign)
      runtime.scheduled[a_leave]()
      H.eq(runtime.options[primary], STATUSCOL_EXPR,
        "A's stale deferred leave cannot restore over B")

      -- This split inherited the expression without BufWinEnter and is omitted
      -- from Surface views by the time its leave runs. Adopt it before defer.
      vim.api.nvim_set_current_win(inherited)
      local leave_b = fake_autocmd(runtime, "BufWinLeave", 2)
      leave_b()
      vim.api.nvim_win_set_buf(inherited, foreign)
      H.eq(#runtime.scheduled, after_attach_b + 1)
      runtime.scheduled[after_attach_b + 1]()
      H.eq(runtime.options[inherited], "primary prior",
        "an untracked inherited split restores its same-tab prior")

      vim.api.nvim_win_set_buf(primary, st.buf)
      H.eq(statuscol.detach(lease_b), true)
      H.eq(runtime.options[primary], "primary prior")
      H.eq(statuscol.detach(lease_b), false)
    end)
  end)

  if vim.api.nvim_win_is_valid(inherited) then
    pcall(vim.api.nvim_win_close, inherited, true)
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(ok, err)
end

T["statuscol_ restores every Surface view and preserves user overrides"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local original_tab = vim.api.nvim_get_current_tabpage()
  local primary = st.win
  vim.cmd("tabnew")
  local remote_tab = vim.api.nvim_get_current_tabpage()
  local remote = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(remote, st.buf)
  vim.api.nvim_set_current_tabpage(original_tab)
  local inherited = vim.api.nvim_open_win(st.buf, false, {
    relative = "editor", row = 1, col = 1, width = 20, height = 5,
  })

  local ok, err = pcall(function()
    with_fake_statuscolumn(function(runtime)
      runtime.options[primary] = "tab one prior"
      runtime.options[remote] = "tab two prior"
      local views = { primary, remote }
      local original_state_win = st.win
      local lease = statuscol.attach(st, {
        windows = function() return views end,
      })
      H.eq(st.win, original_state_win, "statuscol never rebinds Surface state.win")
      H.eq(runtime.options[primary], STATUSCOL_EXPR)
      H.eq(runtime.options[remote], STATUSCOL_EXPR)
      H.eq(runtime.options[inherited], nil,
        "an unrelated view omitted by Surface is not globally claimed")

      -- A later plain split inherits the expression but emits no BufWinEnter.
      runtime.options[inherited] = STATUSCOL_EXPR
      views[#views + 1] = inherited
      runtime.options[remote] = "user remote override"

      H.eq(statuscol.detach(lease), true)
      H.eq(runtime.options[primary], "tab one prior")
      H.eq(runtime.options[remote], "user remote override",
        "detach preserves a later user-local override")
      H.eq(runtime.options[inherited], "tab one prior",
        "same-tab inherited split restores from its touched host")
      H.eq(st.win, original_state_win)
    end)
  end)

  if vim.api.nvim_win_is_valid(inherited) then
    pcall(vim.api.nvim_win_close, inherited, true)
  end
  if vim.api.nvim_tabpage_is_valid(remote_tab) then
    pcall(function()
      vim.api.nvim_set_current_tabpage(remote_tab)
      vim.cmd("tabclose!")
    end)
  end
  if vim.api.nvim_tabpage_is_valid(original_tab) then
    vim.api.nvim_set_current_tabpage(original_tab)
  end
  assert(ok, err)
end

T["statuscol_ plain split restores its exact parent prior"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local first = st.win
  vim.api.nvim_set_current_win(first)
  vim.cmd("split")
  local second = vim.api.nvim_get_current_win()
  local child
  local lease

  local ok, err = pcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "first prior", { win = first, scope = "local" })
    vim.api.nvim_set_option_value(
      "statuscolumn", "second prior", { win = second, scope = "local" })
    lease = statuscol.attach(st, {
      windows = function() return { first, second } end,
    })
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = first, scope = "local" }), STATUSCOL_EXPR)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = second, scope = "local" }), STATUSCOL_EXPR)

    -- WinNewPre runs in the exact source and WinNew runs in the child.
    -- Pinning that provenance matters when same-tab hosts had distinct
    -- original local values.
    vim.api.nvim_set_current_win(second)
    child = vim.api.nvim_open_win(st.buf, true, { split = "below" })
    H.eq(vim.wait(300, function()
      return vim.api.nvim_get_option_value(
        "statuscolumn", { win = child, scope = "local" }) == STATUSCOL_EXPR
    end), true, "plain split commits its Canvas creation transaction")

    H.eq(statuscol.detach(lease), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = first, scope = "local" }), "first prior")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = second, scope = "local" }), "second prior")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "second prior",
      "plain split restores the prior copied from its exact parent")
    H.eq(lease.pending_split, nil)
    H.eq(lease.last_canvas, nil)
    H.eq(next(lease.touched), nil)
    H.eq(next(lease.tab_priors), nil)
  end)

  pcall(statuscol.detach, lease)
  for _, win in ipairs({ child, second }) do
    if win and win ~= first and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  assert(ok, err)
end

T["statuscol_ floating window restores its exact source prior"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local first = st.win
  vim.api.nvim_set_current_win(first)
  vim.cmd("split")
  local second = vim.api.nvim_get_current_win()
  local foreign = vim.api.nvim_create_buf(false, true)
  local closed_child
  local child
  local lease

  local ok, err = pcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "first prior", { win = first, scope = "local" })
    vim.api.nvim_set_option_value(
      "statuscolumn", "second prior", { win = second, scope = "local" })
    lease = statuscol.attach(st, {
      windows = function() return { first, second } end,
    })

    -- Hide the nonfocused host first, then the focused final canvas view.
    -- BufLeave must release the first even though its sibling suppresses
    -- BufWinLeave; the latter then clears the focused source record.
    vim.api.nvim_win_set_buf(first, foreign)
    H.eq(vim.api.nvim_get_current_win(), second)
    H.eq(vim.wait(300, function()
      return lease.touched[first] == nil
    end), true, "duplicate canvas host leave released its owner record")
    vim.api.nvim_win_set_buf(second, foreign)
    H.eq(vim.wait(300, function()
      return lease.touched[second] == nil and lease.last_canvas == nil
    end), true, "focused canvas leave released its owner provenance")
    vim.api.nvim_win_set_buf(second, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = second, scope = "local" }), STATUSCOL_EXPR,
      "BufWinEnter reclaimed the re-entered canvas host")

    -- A nonfocused nvim_win_set_buf() can make BufWinEnter temporarily report
    -- its target as current. It must not replace the real focused source.
    vim.api.nvim_win_set_buf(first, st.buf)
    H.eq(vim.api.nvim_get_current_win(), second,
      "nonfocused buffer changes preserve the real focused window")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = first, scope = "local" }), STATUSCOL_EXPR)

    closed_child = vim.api.nvim_open_win(st.buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 5,
    })
    assert(lease.touched[closed_child], "WinNew claimed disposable float")
    vim.api.nvim_win_close(closed_child, true)
    H.eq(lease.touched[closed_child], nil,
      "WinClosed releases a dead duplicate owner immediately")
    H.eq(lease.priors[closed_child], nil,
      "WinClosed releases the dead window's remembered prior")

    -- nvim_open_win(..., false, float-config) emits WinNew without
    -- WinNewPre or BufWinEnter. BufWinEnter refreshed its exact source.
    child = vim.api.nvim_open_win(st.buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 5,
    })
    H.eq(vim.api.nvim_get_current_win(), second,
      "non-entering float leaves its exact source current")
    H.eq(vim.wait(300, function()
      return vim.api.nvim_get_option_value(
        "statuscolumn", { win = child, scope = "local" }) == STATUSCOL_EXPR
    end), true, "Canvas float commits its creation transaction")

    H.eq(statuscol.detach(lease), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = first, scope = "local" }), "first prior")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = second, scope = "local" }), "second prior")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "second prior",
      "float restores the prior copied from its exact source")
    H.eq(lease.last_canvas, nil)
    H.eq(lease.focused_win, nil)
    H.eq(next(lease.priors), nil)
  end)

  pcall(statuscol.detach, lease)
  for _, win in ipairs({ closed_child, child, second }) do
    if win and win ~= first and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(ok, err)
end

T["statuscol_ foreign float cannot retain its transient Canvas expression"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local source = st.win
  local foreign = vim.api.nvim_create_buf(false, true)
  local child
  local lease

  local ok, err = pcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "source prior", { win = source, scope = "local" })
    lease = statuscol.attach(st, {
      windows = function() return { source } end,
    })

    child = vim.api.nvim_open_win(foreign, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 5,
    })
    H.eq(vim.api.nvim_win_get_buf(child), foreign)
    H.eq(vim.wait(300, function()
      return lease.touched[child] == nil
    end), true, "foreign final buffer aborts its Canvas creation transaction")

    H.eq(statuscol.detach(lease), true)
    vim.api.nvim_win_set_buf(child, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "source prior",
      "foreign float cannot resurrect a transient plugin expression")
  end)

  pcall(statuscol.detach, lease)
  if child and vim.api.nvim_win_is_valid(child) then
    pcall(vim.api.nvim_win_close, child, true)
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(ok, err)
end

T["statuscol_ adopts a child of an excluded raw Canvas view"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local primary = st.win
  vim.api.nvim_set_current_win(primary)
  vim.cmd("split")
  local raw = vim.api.nvim_get_current_win()
  local surface = Surface.new(st, {}, { windows = { primary } })
  local foreign = vim.api.nvim_create_buf(false, true)
  local foreign_child
  local child
  local lease

  local ok, err = xpcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "PRIMARY", { win = primary, scope = "local" })
    vim.api.nvim_set_option_value(
      "statuscolumn", "RAW", { win = raw, scope = "local" })
    lease = statuscol.attach(st, {
      windows = function()
        return surface:canvas_windows()
      end,
    })
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = primary, scope = "local" }), STATUSCOL_EXPR)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = raw, scope = "local" }), "RAW",
      "the pre-existing raw view remains outside Surface ownership")

    vim.api.nvim_set_current_win(raw)
    foreign_child = vim.api.nvim_open_win(foreign, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 5,
    })
    local drained = false
    vim.schedule(function() drained = true end)
    H.eq(vim.wait(300, function() return drained end), true)
    H.eq(surface:owns_window(foreign_child), false,
      "deferred discovery never adopts a transient foreign-target window")

    child = vim.api.nvim_open_win(st.buf, true, { split = "below" })
    H.eq(vim.wait(300, function()
      return vim.api.nvim_get_option_value(
        "statuscolumn", { win = child, scope = "local" }) == STATUSCOL_EXPR
    end), true, "the settled child is reconciled after source-less WinNew")
    H.eq(surface:owns_window(child), true,
      "Surface adopts the post-open child but not its raw parent")
    assert(lease.touched[child], "the status-column lease owns the child")

    H.eq(statuscol.detach(lease), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = primary, scope = "local" }), "PRIMARY")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = raw, scope = "local" }), "RAW")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "RAW",
      "the child restores the exact prior inherited from its raw parent")
    vim.api.nvim_win_set_buf(foreign_child, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = foreign_child, scope = "local" }), "RAW",
      "the rejected foreign child retains its untouched hidden Canvas slot")
  end, debug.traceback)

  pcall(statuscol.detach, lease)
  for _, win in ipairs({ foreign_child, child, raw }) do
    if win and win ~= primary and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(ok, err)
end

T["statuscol_ deferred raw-child reconcile releases its disposed graph"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local primary = st.win
  vim.api.nvim_set_current_win(primary)
  vim.cmd("split")
  local raw = vim.api.nvim_get_current_win()
  local child

  local ok, err = pcall(function()
    with_fake_statuscolumn(function(runtime)
      runtime.options[primary] = "PRIMARY"
      runtime.options[raw] = "RAW"
      local lease = statuscol.attach(st, {
        windows = function() return { primary } end,
      })
      -- Attach queues one reconcile of its own initial claim snapshot.
      local after_attach = #runtime.scheduled

      vim.api.nvim_set_current_win(raw)
      fake_autocmd(runtime, "WinEnter", 1)()
      H.eq(lease.last_canvas, nil, "excluded raw source has no provenance")

      child = vim.api.nvim_open_win(st.buf, true, { split = "below" })
      runtime.options[child] = "RAW"
      fake_autocmd(runtime, "WinNew", 1)()
      H.eq(#runtime.scheduled, after_attach + 1,
        "source-less WinNew queued reconciliation")
      local queued = runtime.scheduled[after_attach + 1]

      H.eq(statuscol.detach(lease), true)
      H.eq(lease.state, nil)
      H.eq(next(lease.callbacks), nil)
      local captures_state = false
      local index = 1
      while true do
        local name, value = debug.getupvalue(queued, index)
        if not name then
          break
        end
        captures_state = captures_state or rawequal(value, st)
        index = index + 1
      end
      H.eq(captures_state, false,
        "queued stale work retains only the scrubbed lease, not Canvas state")
      queued()
      H.eq(next(lease.touched), nil)
    end)
  end)

  for _, win in ipairs({ child, raw }) do
    if win and win ~= primary and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  assert(ok, err)
end

-- Per-window ownership transfer, not lease replacement: attaching C does not
-- dispose A, but C's claim of `target` still takes that one window -- and with
-- it A's exact prior -- while A's in-flight write is repaired behind it.
T["statuscol_ cross-state claim transfers one window and repairs a late write"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local source = st.win
  local foreign = vim.api.nvim_create_buf(false, true)
  local replacement_buf = vim.api.nvim_create_buf(false, true)
  local target = vim.api.nvim_open_win(st.buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 20,
    height = 5,
  })
  local replacement_win = vim.api.nvim_open_win(replacement_buf, false, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 20,
    height = 5,
  })
  local lease_a
  local lease_b
  local lease_c
  local real_set = vim.api.nvim_set_option_value
  local step = 0

  local ok, err = xpcall(function()
    real_set("statuscolumn", "SOURCE", { win = source, scope = "local" })
    real_set("statuscolumn", "OLD", { win = target, scope = "local" })
    vim.api.nvim_win_set_buf(target, foreign)
    real_set("statuscolumn", "NEW", {
      win = replacement_win,
      scope = "local",
    })
    lease_a = statuscol.attach(st, {
      windows = function() return { source } end,
    })

    vim.api.nvim_set_option_value = function(name, value, spec)
      if name == "statuscolumn" and spec and spec.win == target
          and step == 0 and value == STATUSCOL_EXPR then
        step = 1
        -- An unrelated Canvas attaches first, to show the two never interact.
        lease_b = statuscol.attach({
          buf = replacement_buf,
          win = replacement_win,
        }, {
          windows = function() return { replacement_win } end,
        })
        step = 2
        -- Then a same-Canvas peer claims both of A's windows out from under
        -- A's in-flight write, which has not landed yet.
        lease_c = statuscol.attach(st, {
          windows = function() return { source, target } end,
        })
        step = 3
      end
      return real_set(name, value, spec)
    end

    vim.api.nvim_win_set_buf(target, st.buf)
  end, debug.traceback)
  vim.api.nvim_set_option_value = real_set

  local verify_ok, verify_err = xpcall(function()
    assert(ok, err)
    assert(lease_b and lease_c, "A's late claim installed B then C")
    H.eq(step, 3)
    H.eq(lease_a.disposed, false, "an independent peer never disposes A")
    H.eq(lease_b.disposed, false, "a third lease never disposes B either")
    H.eq(lease_a.touched[target], nil,
      "A released exactly the one window C claimed from it")
    H.eq(lease_c.priors[target], "OLD",
      "C's target record receives the transferred exact prior")
    H.eq(lease_c.initial_prior, "SOURCE",
      "rebasing the target does not corrupt C's independent fallback")
    if lease_c.last_canvas then
      assert(rawequal(lease_c.last_canvas.owner.lease, lease_c),
        "C's provenance references only records C itself owns")
    end
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = target, scope = "local" }), STATUSCOL_EXPR,
      "C retains ownership after A's orphan repair")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = replacement_win, scope = "local" }), STATUSCOL_EXPR,
      "B keeps its own different-Canvas window")

    H.eq(statuscol.detach(lease_b), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = replacement_win, scope = "local" }), "NEW",
      "B restores exactly its own window")
    H.eq(statuscol.detach(lease_c), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = target, scope = "local" }), "OLD",
      "C inherited A's exact prior instead of an expression fallback")
    H.eq(statuscol.detach(lease_a), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = source, scope = "local" }), "SOURCE")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = replacement_win, scope = "local" }), "NEW")
  end, debug.traceback)

  vim.api.nvim_set_option_value = real_set
  detach_all(lease_a, lease_b, lease_c)
  for _, win in ipairs({ target, replacement_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  pcall(vim.api.nvim_buf_delete, replacement_buf, { force = true })
  assert(verify_ok, verify_err)
end

T["statuscol_ creation transaction follows reentrant peers"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local source = st.win
  local foreign = vim.api.nvim_create_buf(false, true)
  local child
  local second_child
  local lease_a
  local lease_b
  local lease_c
  local real_set = vim.api.nvim_set_option_value
  local hook_count = 0

  local function windows()
    return { source, vim.api.nvim_get_current_win() }
  end

  local ok, err = xpcall(function()
    real_set("statuscolumn", "source prior", {
      win = source,
      scope = "local",
    })
    lease_a = statuscol.attach(st, { windows = windows })
    vim.api.nvim_set_option_value = function(name, value, spec)
      if name == "statuscolumn" and value == "source prior"
          and spec and spec.win ~= source then
        hook_count = hook_count + 1
        real_set(name, value, spec)
        if hook_count == 1 then
          lease_b = statuscol.attach(st, { windows = windows })
        elseif hook_count == 2 then
          lease_c = statuscol.attach(st, { windows = windows })
        end
        return
      end
      return real_set(name, value, spec)
    end

    child = vim.api.nvim_open_win(foreign, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 5,
    })
    second_child = vim.api.nvim_open_win(foreign, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 5,
    })
  end, debug.traceback)
  vim.api.nvim_set_option_value = real_set

  local verify_ok, verify_err = xpcall(function()
    assert(ok, err)
    assert(lease_b and lease_c, "pre-restore installed B then C")
    H.eq(lease_a.disposed, false, "a reentrant peer never disposes A")
    H.eq(lease_b.disposed, false, "nor B")

    -- Whichever lease ends up owning the children, none of the three may leave
    -- a transient plugin expression behind in a foreign window.
    H.eq(vim.wait(300, function()
      for _, lease in ipairs({ lease_a, lease_b, lease_c }) do
        if lease.touched[child] ~= nil or lease.touched[second_child] ~= nil then
          return false
        end
      end
      return true
    end), true, "every lease observes both synchronous foreign final buffers")
    detach_all(lease_a, lease_b, lease_c)
    vim.api.nvim_win_set_buf(child, st.buf)
    vim.api.nvim_win_set_buf(second_child, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "source prior",
      "an A-to-B-to-C creation chain cannot strand a transient expression")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = second_child, scope = "local" }), "source prior",
      "a reentrant peer keeps the real source for an immediate second child")
  end, debug.traceback)

  vim.api.nvim_set_option_value = real_set
  detach_all(lease_a, lease_b, lease_c)
  for _, win in ipairs({ second_child, child }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(verify_ok, verify_err)
end

T["statuscol_ leave transaction follows a reentrant peer"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local departed = st.win
  vim.api.nvim_set_current_win(departed)
  vim.cmd("split")
  local source = vim.api.nvim_get_current_win()
  local foreign = vim.api.nvim_create_buf(false, true)
  local child
  local lease_a
  local lease_b
  local real_set = vim.api.nvim_set_option_value
  local installed = false

  local ok, err = xpcall(function()
    real_set("statuscolumn", "departed prior", {
      win = departed,
      scope = "local",
    })
    real_set("statuscolumn", "source prior", {
      win = source,
      scope = "local",
    })
    local callbacks = {
      windows = function() return { departed, source } end,
    }
    lease_a = statuscol.attach(st, callbacks)
    vim.api.nvim_set_option_value = function(name, value, spec)
      if not installed and name == "statuscolumn" and value == "departed prior"
          and spec and spec.win == departed then
        installed = true
        real_set(name, value, spec)
        lease_b = statuscol.attach(st, callbacks)
        return
      end
      return real_set(name, value, spec)
    end

    vim.api.nvim_win_set_buf(departed, foreign)
    H.eq(vim.api.nvim_get_current_win(), source,
      "a nonfocused leave preserves the real Canvas source")
    child = vim.api.nvim_open_win(foreign, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 5,
    })
  end, debug.traceback)
  vim.api.nvim_set_option_value = real_set

  local verify_ok, verify_err = xpcall(function()
    assert(ok, err)
    assert(lease_b, "BufLeave pre-restore installed B")
    H.eq(lease_a.disposed, false, "a reentrant peer never disposes A")
    H.eq(vim.wait(300, function()
      for _, lease in ipairs({ lease_a, lease_b }) do
        if lease.touched[departed] ~= nil or lease.touched[child] ~= nil then
          return false
        end
      end
      return true
    end), true, "both leases observe the leave and the immediate foreign child")

    detach_all(lease_a, lease_b)
    vim.api.nvim_win_set_buf(departed, st.buf)
    vim.api.nvim_win_set_buf(child, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = departed, scope = "local" }), "departed prior",
      "a reentrant BufLeave peer cannot strand the hidden Canvas slot")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = source, scope = "local" }), "source prior")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "source prior",
      "a reentrant peer keeps the real source across a nonfocused leave")
  end, debug.traceback)

  vim.api.nvim_set_option_value = real_set
  detach_all(lease_a, lease_b)
  if child and vim.api.nvim_win_is_valid(child) then
    pcall(vim.api.nvim_win_close, child, true)
  end
  if source ~= departed and vim.api.nvim_win_is_valid(source) then
    pcall(vim.api.nvim_win_close, source, true)
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(verify_ok, verify_err)
end

T["statuscol_ creation preflight survives a reentrant peer"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local source = st.win
  local foreign = vim.api.nvim_create_buf(false, true)
  local child
  local lease_a
  local lease_b
  local armed = false

  local function windows()
    return { source, vim.api.nvim_get_current_win() }
  end

  local ok, err = xpcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "source prior", { win = source, scope = "local" })
    lease_a = statuscol.attach(st, {
      alive = function()
        if armed and not lease_b
            and vim.api.nvim_get_current_win() ~= source then
          lease_b = statuscol.attach(st, { windows = windows })
        end
        return true
      end,
      windows = windows,
    })
    armed = true

    child = vim.api.nvim_open_win(foreign, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 5,
    })
    assert(lease_b, "WinNew alive preflight installed B")
    H.eq(lease_a.disposed, false, "a preflight peer never disposes A")
    H.eq(vim.wait(300, function()
      return lease_a.touched[child] == nil and lease_b.touched[child] == nil
    end), true, "both preflight leases observe the foreign final buffer")

    detach_all(lease_a, lease_b)
    -- Neovim remembers a window-local option per displayed buffer, so this
    -- also proves nothing was left remembered for the transient pairing.
    vim.api.nvim_win_set_buf(child, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "source prior",
      "an alive-callback peer cannot strand the transient Canvas expression")
  end, debug.traceback)

  detach_all(lease_a, lease_b)
  if child and vim.api.nvim_win_is_valid(child) then
    pcall(vim.api.nvim_win_close, child, true)
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(ok, err)
end

T["statuscol_ leave preflight survives a reentrant peer"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local win = st.win
  local foreign = vim.api.nvim_create_buf(false, true)
  local lease_a
  local lease_b
  local armed = false
  local callbacks

  local ok, err = xpcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "canvas prior", { win = win, scope = "local" })
    callbacks = {
      alive = function()
        if armed and not lease_b then
          lease_b = statuscol.attach(st, {
            windows = function() return { win } end,
          })
        end
        return true
      end,
      windows = function() return { win } end,
    }
    lease_a = statuscol.attach(st, callbacks)
    armed = true

    vim.api.nvim_win_set_buf(win, foreign)
    assert(lease_b, "BufLeave alive preflight installed B")
    H.eq(lease_a.disposed, false, "a preflight peer never disposes A")
    H.eq(vim.wait(300, function()
      return lease_a.touched[win] == nil and lease_b.touched[win] == nil
    end), true, "both preflight leases observe the completed buffer leave")

    detach_all(lease_a, lease_b)
    vim.api.nvim_win_set_buf(win, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = win, scope = "local" }), "canvas prior",
      "an alive-callback peer cannot strand the departed Canvas slot")
  end, debug.traceback)

  detach_all(lease_a, lease_b)
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(ok, err)
end

T["statuscol_ suspended child is exact provenance for nested creation"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local source = st.win
  local first
  local second
  local lease

  local ok, err = pcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "source prior", { win = source, scope = "local" })
    lease = statuscol.attach(st, {
      windows = function() return { source } end,
    })

    first = vim.api.nvim_open_win(st.buf, true, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 5,
    })
    assert(lease.leaving[first],
      "first child remains suspended until its deferred commit")
    second = vim.api.nvim_open_win(st.buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 5,
    })
    assert(lease.leaving[second],
      "nested child inherited exact suspended provenance")

    H.eq(vim.wait(300, function()
      return vim.api.nvim_get_option_value(
          "statuscolumn", { win = first, scope = "local" }) == STATUSCOL_EXPR
        and vim.api.nvim_get_option_value(
          "statuscolumn", { win = second, scope = "local" }) == STATUSCOL_EXPR
    end), true, "both nested Canvas transactions commit")

    H.eq(statuscol.detach(lease), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = first, scope = "local" }), "source prior")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = second, scope = "local" }), "source prior")
  end)

  pcall(statuscol.detach, lease)
  for _, win in ipairs({ second, first }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  assert(ok, err)
end

T["statuscol_ duplicate host leave restores its hidden slot before detach"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local first = st.win
  vim.api.nvim_set_current_win(first)
  vim.cmd("split")
  local second = vim.api.nvim_get_current_win()
  local foreign = vim.api.nvim_create_buf(false, true)
  local lease

  local ok, err = pcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "first prior", { win = first, scope = "local" })
    vim.api.nvim_set_option_value(
      "statuscolumn", "second prior", { win = second, scope = "local" })
    lease = statuscol.attach(st, {
      windows = function() return { first, second } end,
    })

    -- BufWinLeave is suppressed because the sibling still shows the canvas.
    -- BufLeave must restore the old buffer's window-local slot before swap.
    vim.api.nvim_win_set_buf(first, foreign)
    H.eq(vim.wait(300, function()
      return lease.touched[first] == nil
    end), true, "duplicate host departure released its active owner")

    H.eq(statuscol.detach(lease), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = second, scope = "local" }), "second prior")

    vim.api.nvim_win_set_buf(first, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = first, scope = "local" }), "first prior",
      "showing Canvas after detach cannot resurrect the plugin expression")
    H.eq(next(lease.leaving), nil)
    H.eq(next(lease.priors), nil)
  end)

  pcall(statuscol.detach, lease)
  if second ~= first and vim.api.nvim_win_is_valid(second) then
    pcall(vim.api.nvim_win_close, second, true)
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(ok, err)
end

T["statuscol_ rapid buffer bounce cancels its stale leave"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local win = st.win
  local foreign = vim.api.nvim_create_buf(false, true)
  local lease

  local ok, err = pcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "canvas prior", { win = win, scope = "local" })
    lease = statuscol.attach(st, {
      windows = function() return { win } end,
    })

    vim.api.nvim_win_set_buf(win, foreign)
    vim.api.nvim_win_set_buf(win, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = win, scope = "local" }), STATUSCOL_EXPR)
    H.eq(lease.leaving[win], nil,
      "BufWinEnter claim cancels the matching deferred leave")

    vim.wait(50)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = win, scope = "local" }), STATUSCOL_EXPR,
      "stale deferred leave cannot release a reclaimed owner")
    assert(lease.touched[win], "reclaimed owner remains tracked")

    H.eq(statuscol.detach(lease), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = win, scope = "local" }), "canvas prior")
  end)

  pcall(statuscol.detach, lease)
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(ok, err)
end

T["statuscol_ focus roundtrip preserves source for immediate float"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local source = st.win
  local foreign_buf = vim.api.nvim_create_buf(false, true)
  local foreign_win = vim.api.nvim_open_win(foreign_buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 20,
    height = 5,
  })
  local child
  local lease

  local ok, err = pcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "source prior", { win = source, scope = "local" })
    lease = statuscol.attach(st, {
      windows = function() return { source } end,
    })

    -- Keep this entire sequence synchronous: WinLeave must distinguish the
    -- focus-only BufLeave before the scheduled fallback can run.
    vim.api.nvim_set_current_win(foreign_win)
    vim.api.nvim_set_current_win(source)
    child = vim.api.nvim_open_win(st.buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 5,
    })
    H.eq(lease.leaving[source], nil,
      "focus-only WinLeave cancels the departure token")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = source, scope = "local" }), STATUSCOL_EXPR)
    H.eq(vim.wait(300, function()
      return vim.api.nvim_get_option_value(
        "statuscolumn", { win = child, scope = "local" }) == STATUSCOL_EXPR
    end), true, "immediate float commits from the exact source")

    H.eq(statuscol.detach(lease), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = source, scope = "local" }), "source prior")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "source prior")
  end)

  pcall(statuscol.detach, lease)
  for _, win in ipairs({ child, foreign_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  pcall(vim.api.nvim_buf_delete, foreign_buf, { force = true })
  assert(ok, err)
end

T["statuscol_ tab split restores its exact parent prior"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local original_tab = vim.api.nvim_get_current_tabpage()
  local first = st.win
  vim.api.nvim_set_current_win(first)
  vim.cmd("split")
  local second = vim.api.nvim_get_current_win()
  local child
  local child_tab
  local lease

  local ok, err = pcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "first prior", { win = first, scope = "local" })
    vim.api.nvim_set_option_value(
      "statuscolumn", "second prior", { win = second, scope = "local" })
    lease = statuscol.attach(st, {
      windows = function() return { first, second } end,
    })

    -- :tab split has no WinNewPre or BufWinEnter. TabLeave must pin the
    -- exact source before WinNew creates the child in its new tab.
    vim.api.nvim_set_current_win(second)
    vim.cmd("tab split")
    child = vim.api.nvim_get_current_win()
    child_tab = vim.api.nvim_get_current_tabpage()
    assert(child_tab ~= original_tab, "tab split created a distinct tab")
    H.eq(vim.wait(300, function()
      return vim.api.nvim_get_option_value(
        "statuscolumn", { win = child, scope = "local" }) == STATUSCOL_EXPR
    end), true, "tab split commits its Canvas creation transaction")

    H.eq(statuscol.detach(lease), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = first, scope = "local" }), "first prior")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = second, scope = "local" }), "second prior")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "second prior",
      "tab split restores the prior copied from its exact source")
    H.eq(lease.pending_split, nil)
    H.eq(lease.pending_tab, nil)
    H.eq(next(lease.touched), nil)
    H.eq(next(lease.tab_priors), nil)
  end)

  pcall(statuscol.detach, lease)
  if child_tab and vim.api.nvim_tabpage_is_valid(child_tab) then
    pcall(function()
      vim.api.nvim_set_current_tabpage(child_tab)
      vim.cmd("tabclose!")
    end)
  end
  if vim.api.nvim_tabpage_is_valid(original_tab) then
    vim.api.nvim_set_current_tabpage(original_tab)
  end
  if second ~= first and vim.api.nvim_win_is_valid(second) then
    pcall(vim.api.nvim_win_close, second, true)
  end
  assert(ok, err)
end

T["statuscol_ fresh tab provenance supersedes a stale split candidate"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local original_tab = vim.api.nvim_get_current_tabpage()
  local first = st.win
  vim.api.nvim_set_current_win(first)
  vim.cmd("split")
  local second = vim.api.nvim_get_current_win()
  local child
  local child_tab

  local ok, err = pcall(function()
    with_fake_statuscolumn(function(runtime)
      runtime.options[first] = "first prior"
      runtime.options[second] = "second prior"
      local lease = statuscol.attach(st, {
        windows = function() return { first, second } end,
      })

      vim.api.nvim_set_current_win(first)
      fake_autocmd(runtime, "WinNewPre", 1)()
      assert(lease.pending_split, "injected stale split candidate")

      vim.api.nvim_set_current_win(second)
      fake_autocmd(runtime, "TabLeave", 1)()
      H.eq(lease.pending_split, nil,
        "fresh TabLeave supersedes stale WinNewPre provenance")
      assert(lease.pending_tab, "fresh tab source captured")

      vim.cmd("tab split")
      child = vim.api.nvim_get_current_win()
      child_tab = vim.api.nvim_get_current_tabpage()
      runtime.options[child] = STATUSCOL_EXPR
      fake_autocmd(runtime, "WinNew", 1)()

      H.eq(statuscol.detach(lease), true)
      H.eq(runtime.options[first], "first prior")
      H.eq(runtime.options[second], "second prior")
      H.eq(runtime.options[child], "second prior",
        "WinNew consumed the fresh tab source, not stale split source")
    end)
  end)

  if child_tab and vim.api.nvim_tabpage_is_valid(child_tab) then
    pcall(function()
      vim.api.nvim_set_current_tabpage(child_tab)
      vim.cmd("tabclose!")
    end)
  end
  if vim.api.nvim_tabpage_is_valid(original_tab) then
    vim.api.nvim_set_current_tabpage(original_tab)
  end
  if second ~= first and vim.api.nvim_win_is_valid(second) then
    pcall(vim.api.nvim_win_close, second, true)
  end
  assert(ok, err)
end

T["statuscol_ reentrant restore cannot clobber its winner"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local win = st.win

  with_fake_statuscolumn(function(runtime)
    runtime.options[win] = "prior"
    local callbacks = {
      windows = function() return { win } end,
    }
    local lease_a = statuscol.attach(st, callbacks)
    local lease_b
    runtime.on_set = function(_, value)
      if value == "prior" then
        lease_b = statuscol.attach(st, callbacks)
      end
    end

    H.eq(statuscol.detach(lease_a), true)
    assert(lease_b, "A's restore reentrantly installed B")
    local group_b = runtime.group_order[2]
    assert(runtime.groups[group_b],
      "A deleted its group before B reused the ID")
    H.eq(runtime.options[win], STATUSCOL_EXPR,
      "A repairs B's expression when its old write lands last")
    H.eq(statuscol.detach(lease_b), true)
    H.eq(runtime.options[win], "prior")

    -- Attach no longer tears a predecessor down, so the surviving abort case
    -- is an attach the owner disposes mid-flight. Its partial resources go,
    -- and the peer installed reentrantly inside its own claim keeps the window.
    local lease_a2 = statuscol.attach(st, callbacks)
    local victim, lease_b2
    runtime.on_set = function(_, value)
      if value == STATUSCOL_EXPR and victim then
        H.eq(statuscol.detach(victim), true, "the owner disposes the half-built lease")
        lease_b2 = statuscol.attach(st, callbacks)
      end
    end
    local ok, err = pcall(statuscol.attach, st, {
      alive = callbacks.alive,
      windows = callbacks.windows,
      claim = function(lease)
        victim = lease
        return true
      end,
    })
    H.eq(ok, false, "an attach disposed inside its own first claim aborts")
    assert(tostring(err):find("disposed", 1, true), tostring(err))
    assert(lease_b2, "the reentrant peer was installed")
    H.eq(statuscol.detach(victim), false, "the aborted attach is already terminal")
    H.eq(runtime.options[win], STATUSCOL_EXPR,
      "the aborted attach did not orphan or overwrite its peer")
    H.eq(statuscol.detach(lease_b2), true)
    H.eq(statuscol.detach(lease_a2), true)
    H.eq(runtime.options[win], "prior")
  end)
end

T["statuscol_ callback errors are observable except from text"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local callbacks = {
    alive = function() return true end,
    windows = function() return { st.win } end,
  }
  local lease = statuscol.attach(st, callbacks)
  callbacks.alive = function()
    error("statuscol alive fault")
  end

  local ok, err = pcall(statuscol.render, lease, st.win, 1)
  H.eq(ok, false)
  assert(tostring(err):find("statuscol alive fault", 1, true), tostring(err))
  vim.g.statusline_winid = st.win
  H.eq(statuscol.text(), "", "expression entrypoint fails closed")
  vim.g.statusline_winid = nil
  H.eq(statuscol.detach(lease), true)

  ok, err = pcall(statuscol.attach, st, {
    windows = function()
      error("statuscol windows fault")
    end,
  })
  H.eq(ok, false)
  assert(tostring(err):find("statuscol windows fault", 1, true), tostring(err))
  H.eq(statuscol.detach(nil), false, "there is no unqualified teardown to fall back on")
end

--- A second complete review on its own buffer and its own window.
---
--- `canvas.open` creates one buffer per review now, and shows it in the
--- CURRENT window -- so two concurrent reviews need two windows, exactly as a
--- user would give them.
local function independent_state()
  return (H.in_new_window(function()
    return canvas.open(three_sections(), {})
  end))
end

T["statuscol_ two simultaneous leases render their own canvases"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local first = st.win
  vim.api.nvim_set_current_win(first)
  local other = independent_state()
  local second = other.win
  local lease_a, lease_b

  local ok, err = xpcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "first prior", { win = first, scope = "local" })
    vim.api.nvim_set_option_value(
      "statuscolumn", "second prior", { win = second, scope = "local" })

    lease_a = statuscol.attach(st, { windows = function() return { first } end })
    lease_b = statuscol.attach(other, { windows = function() return { second } end })
    assert(lease_a.group_name ~= lease_b.group_name, "group names never collide")
    H.eq(lease_a.disposed, false, "attaching B never disposes A")

    -- One global expression string, two owners. The drawn window is the only
    -- thing that can decide which lease renders this row, so `text` must reach
    -- the right one for each.
    for _, case in ipairs({ { first, lease_a }, { second, lease_b } }) do
      local win = case[1]
      H.eq(vim.api.nvim_get_option_value(
        "statuscolumn", { win = win, scope = "local" }), STATUSCOL_EXPR)
      vim.g.statusline_winid = win
      vim.v.lnum = 1
      H.eq(statuscol.text(), statuscol.render(case[2], win, 1),
        "the expression resolves through the exact per-window owner")
    end
    vim.g.statusline_winid = nil

    -- An unowned window renders nothing rather than guessing an owner.
    vim.g.statusline_winid = -1
    H.eq(statuscol.text(), "", "an unowned window has no status column")
    vim.g.statusline_winid = nil

    H.eq(statuscol.detach(lease_a), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = first, scope = "local" }), "first prior")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = second, scope = "local" }), STATUSCOL_EXPR,
      "A teardown never restores over a peer's window")
    H.eq(statuscol.detach(lease_b), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = second, scope = "local" }), "second prior")
  end, debug.traceback)

  vim.g.statusline_winid = nil
  detach_all(lease_a, lease_b)
  if second ~= first and vim.api.nvim_win_is_valid(second) then
    pcall(vim.api.nvim_win_close, second, true)
  end
  if vim.api.nvim_buf_is_valid(other.buf) then
    pcall(vim.api.nvim_buf_delete, other.buf, { force = true })
  end
  assert(ok, err)
end

T["statuscol_ a forged shell cannot authenticate as a lease"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  local win = st.win
  local lease

  local ok, err = xpcall(function()
    vim.api.nvim_set_option_value(
      "statuscolumn", "real prior", { win = win, scope = "local" })
    lease = statuscol.attach(st, { windows = function() return { win } end })

    local copy = {}
    for k, v in pairs(lease) do
      copy[k] = v
    end
    local forgeries = {
      copy,
      setmetatable({}, { __index = lease }),
      { disposed = false, id = lease.id, group_name = lease.group_name,
        state = st, callbacks = {}, touched = {}, priors = {}, leaving = {} },
      "not a table",
      nil,
    }
    for i = 1, 5 do
      local forged = forgeries[i]
      H.eq(statuscol.detach(forged), false,
        "a forged handle cannot tear down a real lease")
      H.eq(statuscol.render(forged, win, 1), "",
        "a forged handle renders nothing")
    end

    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = win, scope = "local" }), STATUSCOL_EXPR,
      "the real lease still owns its window")
    assert(statuscol.render(lease, win, 1) ~= "" or #st.sections == 0,
      "the real lease still renders")
    H.eq(statuscol.detach(lease), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = win, scope = "local" }), "real prior")
  end, debug.traceback)

  detach_all(lease)
  assert(ok, err)
end

T["statuscol_ text maps rows to new-file numbers"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_set_current_win(st.win)
  local lease = statuscol.attach(st, {
    windows = function() return { st.win } end,
  })

  -- Production sets g:statusline_winid to the window being drawn before
  -- evaluating the `%!` statuscolumn expression; simulate that eval context.
  vim.g.statusline_winid = st.win

  -- file_hdr row (section start) -> the padded bar cell, then 5 blank number cells.
  local a_start = (canvas.section_rows(st, 1))
  H.eq(statuscol.render(lease, st.win, a_start + 1), "      ")

  -- Find a ctx row (no bar, so the cell is padding) and check it maps to its
  -- new_lnum.
  local entry
  local row0 = a_start + 2
  while true do
    local i, off = canvas.locate(st, row0)
    entry = st.sections[i].entries[off]
    if entry.kind == "ctx" then
      break
    end
    row0 = row0 + 1
  end
  H.eq(entry.new_lnum ~= nil, true, "found a row with a new_lnum")
  H.eq(statuscol.render(lease, st.win, row0 + 1), (" %4d "):format(entry.new_lnum))

  vim.g.statusline_winid = nil
  statuscol.detach(lease)
end

T["statuscol_ maps rows to new-file numbers on a paged canvas"] = function()
  detach_tracked()
  -- The render path resolves rows through canvas.locate and indexes
  -- `entries[offset]` directly. The paged store must answer the same 1-based
  -- offset the eager canvas does: a 0-based answer makes every row render its
  -- NEIGHBOUR's cell -- blank below a hunk header, the wrong number elsewhere.
  local Paged = require("canvasdiff.canvas.paged")
  local paged, err = Paged.render(three_sections())
  assert(paged, err)
  local original = vim.api.nvim_get_current_buf()
  local ok, failure = xpcall(function()
    vim.api.nvim_set_current_buf(paged.buffer)
    local win = vim.api.nvim_get_current_win()
    local lease = statuscol.attach(paged.state, {
      windows = function() return { win } end,
    })
    vim.g.statusline_winid = win

    local start0 = (canvas.section_rows(paged.state, 1))
    H.eq(statuscol.render(lease, win, start0 + 1), "      ",
      "the file header row keeps blank number cells")

    -- A numbered ctx row directly below a hunk header: the row where a
    -- 0-based offset answers the header's blank cell instead of the number.
    local entries = paged.sections[1].entries
    local target_off
    for off = 2, #entries do
      if entries[off - 1].kind == "hunk_hdr" and entries[off].kind == "ctx"
          and entries[off].new_lnum then
        target_off = off
        break
      end
    end
    assert(target_off, "sanity: a numbered ctx row directly below a hunk header")
    -- 1-based offset `off` sits at buffer row0 = start0 + off - 1, lnum = start0 + off.
    H.eq(statuscol.render(lease, win, start0 + target_off),
      (" %4d "):format(entries[target_off].new_lnum),
      "a paged row answers its OWN new-file number, not its neighbour's")

    vim.g.statusline_winid = nil
    statuscol.detach(lease)
  end, debug.traceback)
  if vim.api.nvim_buf_is_valid(original) then
    pcall(vim.api.nvim_set_current_buf, original)
  end
  Paged.dispose(paged)
  detach_tracked()
  assert(ok, failure)
end

T["statuscol_ the bar column renders on add, del and ghost rows by default"] = function()
  detach_tracked()
  require("canvasdiff.config").setup({})
  local ok, err = xpcall(function()
    local st = canvas.open({
      model.build_section("a.txt", "one\ntwo\n", "one\ntwo\nthree\n", "M"),
      -- A wholly deleted file keeps its deletions as REAL rows (no result view
      -- to ghost them into), so this is where a del row can carry the bar.
      model.build_section("gone.txt", "x\ny\n", "", "D"),
    }, {})
    vim.api.nvim_set_current_win(st.win)
    local lease = statuscol.attach(st, {
      windows = function() return { st.win } end,
    })
    vim.g.statusline_winid = st.win

    local function row_of(kind)
      for i, section in ipairs(st.sections) do
        local s0 = (canvas.section_rows(st, i))
        for off, entry in ipairs(section.entries) do
          if entry.kind == kind then
            return s0 + off - 1, entry
          end
        end
      end
    end

    local add_row, add_entry = row_of("add")
    assert(add_row, "sanity: an add row exists")
    H.eq(statuscol.render(lease, st.win, add_row + 1),
      ("%%#CanvasDiffGutterAdd#▎%%*%4d "):format(add_entry.new_lnum),
      "an added row carries the add bar before its number")

    local del_row = row_of("del")
    assert(del_row, "sanity: the deleted file keeps a del row in the buffer")
    H.eq(statuscol.render(lease, st.win, del_row + 1),
      "%#CanvasDiffGutterDel#▎%*     ",
      "a deleted row carries the del bar and no new-file number")

    local ctx_row, ctx_entry = row_of("ctx")
    assert(ctx_row, "sanity: a ctx row exists")
    H.eq(statuscol.render(lease, st.win, ctx_row + 1),
      (" %4d "):format(ctx_entry.new_lnum),
      "unmarked rows pad the gutter cell so the numbers stay aligned")

    -- Ghost deletions are virtual lines; the only virtual rows the canvas ever
    -- draws. Their statuscolumn row carries the deletion bar rather than
    -- repeating the anchor row's number.
    H.eq(statuscol.render(lease, st.win, add_row + 1, 1),
      "%#CanvasDiffGutterDel#▎%*     ",
      "a ghost's virtual row reads as a deletion, not as its anchor")

    vim.g.statusline_winid = nil
    statuscol.detach(lease)
  end, debug.traceback)
  detach_tracked()
  assert(ok, err)
end

T["statuscol_ renders for the drawn window even while focus is elsewhere"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_set_current_win(st.win)
  local lease = statuscol.attach(st, {
    windows = function() return { st.win } end,
  })

  local a_start = (canvas.section_rows(st, 1))
  local row0 = a_start + 2
  local entry
  while true do
    local i, off = canvas.locate(st, row0)
    entry = st.sections[i].entries[off]
    if entry.kind == "ctx" then
      break
    end
    row0 = row0 + 1
  end
  assert(entry.new_lnum ~= nil, "sanity: found a row with a new_lnum")

  -- Focus moves to another window entirely; the canvas window (st.win) is
  -- still SHOWING st.buf, just not the current one.
  local other_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
    relative = "editor", row = 0, col = 0, width = 20, height = 5,
  })
  assert(vim.api.nvim_get_current_win() ~= st.win)
  assert(vim.api.nvim_get_current_buf() ~= st.buf)
  H.eq(vim.wait(300, function()
    return vim.api.nvim_get_option_value(
      "statuscolumn", { win = st.win, scope = "local" }) == STATUSCOL_EXPR
  end), true, "focus-only BufLeave reapplies the canvas expression")

  -- Simulate the eval context production runs under: Neovim sets
  -- g:statusline_winid to the window being DRAWN before invoking the `%!`
  -- statuscolumn expression.
  vim.g.statusline_winid = st.win
  local text = statuscol.render(lease, st.win, row0 + 1)
  vim.g.statusline_winid = nil

  H.eq(text, (" %4d "):format(entry.new_lnum),
    "statuscolumn for the canvas window's own row renders even while focus is in another window")

  vim.api.nvim_win_close(other_win, true)
  statuscol.detach(lease)
end

T["statuscol_ never leaks into a foreign buffer"] = function()
  detach_tracked()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_set_current_win(st.win)
  local lease = statuscol.attach(st, {
    windows = function() return { st.win } end,
  })

  local other_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(st.win, other_buf)

  vim.g.statusline_winid = st.win
  H.eq(statuscol.render(lease, st.win, 1), "",
    "render returns empty once the drawn window shows a foreign buffer")
  vim.g.statusline_winid = nil

  vim.wait(300, function()
    return vim.api.nvim_get_option_value("statuscolumn", { win = st.win }) == ""
  end)
  H.eq(vim.api.nvim_get_option_value("statuscolumn", { win = st.win }), "",
    "statuscolumn cleared once the canvas left the window")

  vim.api.nvim_win_set_buf(st.win, st.buf)
  vim.wait(300, function()
    return vim.api.nvim_get_option_value("statuscolumn", { win = st.win }) ~= ""
  end)
  H.eq(vim.api.nvim_get_option_value("statuscolumn", { win = st.win }),
    "%!v:lua.require'canvasdiff.ui.status_column'.text()",
    "statuscolumn restored once the canvas is showing again")

  statuscol.detach(lease)
  pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
end

return T
