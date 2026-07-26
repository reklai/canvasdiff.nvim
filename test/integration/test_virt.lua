local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")
local runtime_domain = require("canvasdiff.runtime")
local virt = runtime_domain.virtualizer
local system = require("canvasdiff.os")
local hl = require("canvasdiff.ui").highlight

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

-- Every virtualizer lease owns fresh LRU ticks, while auto/user collapse intent
-- deliberately lives on the canvas state. Each test starts a fresh lease so its
-- visibility history is isolated; canvas.open provides fresh collapse intent.
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

local function open_six(callbacks)
  local state = canvas.open(six_sections(), {})
  local lease = virt.attach(state, { enabled = false }, callbacks)
  return state, lease
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

--- Deterministic libuv/autocmd harness. Deleted group IDs are deliberately
--- reused, making teardown order observable: deleting C's group after a
--- reentrant D attach would delete D's newly-created group too.
local function with_fake_runtime(callback)
  local real_create_group = vim.api.nvim_create_augroup
  local real_delete_group = vim.api.nvim_del_augroup_by_id
  local real_create_autocmd = vim.api.nvim_create_autocmd
  local real_new_timer = system.new_timer
  local real_schedule_wrap = vim.schedule_wrap
  local real_attach = virt.attach
  local real_detach = virt.detach
  local runtime = {
    groups = {},
    group_order = {},
    autocmds = {},
    timers = {},
    scheduled = {},
    free_groups = {},
    leases = {},
    next_group = 0,
  }

  vim.api.nvim_create_augroup = function(name, _)
    local id = table.remove(runtime.free_groups)
    if not id then
      runtime.next_group = runtime.next_group + 1
      id = runtime.next_group
    end
    runtime.groups[id] = { name = name }
    runtime.group_order[#runtime.group_order + 1] = id
    return id
  end
  vim.api.nvim_del_augroup_by_id = function(id)
    assert(runtime.groups[id], "attempted to delete an absent fake augroup")
    runtime.groups[id] = nil
    runtime.free_groups[#runtime.free_groups + 1] = id
  end
  vim.api.nvim_create_autocmd = function(_, spec)
    local item = { group = spec.group, callback = spec.callback }
    runtime.autocmds[#runtime.autocmds + 1] = item
    return #runtime.autocmds
  end
  system.new_timer = function()
    local timer = { started = 0, stopped = 0, closed = 0 }
    function timer:start(_, _, fn)
      self.started = self.started + 1
      self.callback = fn
      return true
    end
    function timer:stop()
      self.stopped = self.stopped + 1
      local reenter = self.on_stop
      self.on_stop = nil
      if reenter then
        reenter()
      end
      return true
    end
    function timer:close()
      self.closed = self.closed + 1
      return true
    end
    function timer:is_closing()
      return self.closed > 0
    end
    runtime.timers[#runtime.timers + 1] = timer
    return timer
  end
  vim.schedule_wrap = function(fn)
    return function()
      runtime.scheduled[#runtime.scheduled + 1] = fn
    end
  end
  virt.attach = function(...)
    local lease = real_attach(...)
    runtime.leases[#runtime.leases + 1] = lease
    return lease
  end

  local ok, err = xpcall(function()
    callback(runtime)
  end, debug.traceback)

  for _, timer in ipairs(runtime.timers) do
    timer.on_stop = nil
  end
  for i = #runtime.leases, 1, -1 do
    local cleanup_ok, cleanup_err = pcall(real_detach, runtime.leases[i])
    if ok and not cleanup_ok then
      ok, err = false, cleanup_err
    end
  end
  virt.attach = real_attach
  vim.api.nvim_create_augroup = real_create_group
  vim.api.nvim_del_augroup_by_id = real_delete_group
  vim.api.nvim_create_autocmd = real_create_autocmd
  system.new_timer = real_new_timer
  vim.schedule_wrap = real_schedule_wrap
  assert(ok, err)
end

T["virt_ debounce allocation uses the os facade and retries an unavailable handle"] =
  function()
    local state = canvas.open(six_sections(), {})
    reset_view(state)

    with_fake_runtime(function(fake)
      local adapter_factory = system.new_timer
      local adapter_calls = 0
      system.new_timer = function()
        adapter_calls = adapter_calls + 1
        if adapter_calls == 1 then
          return nil
        end
        return adapter_factory()
      end

      local lease = virt.attach(state, { enabled = false })
      local on_scroll = fake.autocmds[1].callback

      on_scroll({ match = tostring(state.win) })
      H.eq(adapter_calls, 1, "the first debounce allocation reaches canvasdiff.os")
      H.eq(lease.timer, nil,
        "an unavailable adapter handle is not published into the lease")
      H.eq(#fake.timers, 0, "no raw libuv timer bypassed the adapter")

      on_scroll({ match = tostring(state.win) })
      H.eq(adapter_calls, 2, "a transient unavailable handle is retried")
      H.eq(#fake.timers, 1)
      assert(rawequal(lease.timer, fake.timers[1]),
        "the exact adapter result becomes the lease-owned timer")
      H.eq(fake.timers[1].started, 1)

      H.eq(virt.detach(lease), true)
      H.eq(fake.timers[1].stopped, 1)
      H.eq(fake.timers[1].closed, 1)
    end)
  end

T["virt_ concurrent owners and stale async work remain isolated"] = function()
  local state_a = canvas.open(six_sections(), {})
  reset_view(state_a)

  with_fake_runtime(function(runtime)
    local a_changes = 0
    local lease_a = virt.attach(state_a, { enabled = false }, {
      alive = function() return true end,
      on_change = function() a_changes = a_changes + 1 end,
    })
    local autocmd_a = runtime.autocmds[1].callback

    -- Cross the raw timer boundary while A is live, but hold the scheduled
    -- main-loop callback across creation and teardown of peer B.
    autocmd_a({ match = tostring(state_a.win) })
    H.eq(#runtime.timers, 1)
    local timer_a = runtime.timers[1]
    timer_a.callback()
    H.eq(#runtime.scheduled, 1)

    local state_b = canvas.open(six_sections(), {})
    reset_view(state_b)
    local b_changes = 0
    local opts_b = {
      enabled = true,
      max_files = 3,
      max_lines = 1000000,
      margin = 10,
      max_expanded = 2,
    }
    local lease_b = virt.attach(state_b, opts_b, {
      alive = function() return true end,
      on_change = function(state)
        H.eq(state, state_b)
        b_changes = b_changes + 1
      end,
    })
    H.eq(b_changes, 1, "B's immediate mutating pass publishes once")
    b_changes = 0
    local b_before = vim.deepcopy(state_b.collapsed)
    local autocmd_b = runtime.autocmds[2].callback
    local group_a = runtime.group_order[1]
    local group_b = runtime.group_order[2]

    assert(lease_a.group_name ~= lease_b.group_name,
      "concurrent virtualizers own distinct augroup names")
    assert(lease_a.aug ~= lease_b.aug,
      "concurrent virtualizers own distinct augroup ids")
    assert(runtime.groups[lease_a.aug], "starting B keeps A's group installed")
    assert(runtime.groups[group_b], "B's own group is installed")
    H.eq(lease_a.disposed, false, "starting B does not implicitly dispose A")
    H.eq(timer_a.stopped, 0, "starting B does not stop A's timer")
    H.eq(timer_a.closed, 0, "starting B does not close A's timer")

    local forged = {
      disposed = false,
      aug = lease_b.aug,
      timer = timer_a,
      callbacks = {},
      tick_of = {},
    }
    H.eq(virt.detach(forged), false,
      "a field-shaped table is not an authenticated virtualizer lease")
    H.eq(forged.disposed, false, "rejected forgery is not mutated")
    assert(runtime.groups[group_b],
      "forged teardown cannot delete a live lease's augroup")
    H.eq(timer_a.stopped, 0,
      "forged teardown cannot stop another lease's timer")
    H.eq(timer_a.closed, 0,
      "forged teardown cannot close another lease's timer")

    H.eq(virt.detach(lease_a), true, "A's owner detaches only A")
    H.eq(virt.detach(lease_a), false, "stale exact detach(A) is idempotent")
    H.eq(virt.detach(nil), false, "there is no unqualified global detach")
    H.eq(runtime.groups[group_a], nil,
      "A's exact group is deleted independently")
    assert(runtime.groups[group_b], "B's group survives detach(A)")
    H.eq(timer_a.stopped, 1)
    H.eq(timer_a.closed, 1)
    H.eq(lease_a.disposed, true)
    H.eq(lease_a.state, nil, "disposed lease releases its canvas graph")
    H.eq(lease_a.opts, nil, "disposed lease releases its options")
    H.eq(next(lease_a.callbacks), nil, "disposed lease releases owner callbacks")
    H.eq(lease_a.timer, nil)
    H.eq(lease_a.aug, nil)
    autocmd_a({ match = tostring(state_a.win) })
    H.eq(#runtime.timers, 1, "held A autocmd cannot arm a timer for B")
    timer_a.callback()
    H.eq(#runtime.scheduled, 1, "held A raw timer cannot queue into B")
    runtime.scheduled[1]()
    H.eq(state_b.collapsed, b_before, "A's queued callback cannot mutate B")
    H.eq(b_changes, 0, "A's queued callback cannot notify B")
    H.eq(a_changes, 0, "disposed A receives no late notification")

    -- The peer remains fully operational through its own exact callback.
    vim.api.nvim_win_call(state_b.win, function()
      vim.cmd("normal! G")
    end)
    autocmd_b({ match = tostring(state_b.win) })
    H.eq(#runtime.timers, 2)
    local timer_b = runtime.timers[2]
    timer_b.callback()
    H.eq(#runtime.scheduled, 2)
    runtime.scheduled[2]()
    H.eq(b_changes, 1, "B's own scheduled pass mutates and publishes")

    H.eq(virt.detach(lease_b), true)
    H.eq(virt.detach(lease_b), false, "detach(B) is idempotent")
    for _, timer in ipairs(runtime.timers) do
      H.eq(timer.stopped, 1, "every timer is stopped exactly once")
      H.eq(timer.closed, 1, "every timer is closed exactly once")
    end
  end)
end

T["virt_ teardown deletes C group before reentrant D attach"] = function()
  local state_c, win_c = H.in_new_window(function()
    return canvas.open(six_sections(), {})
  end)
  local state_d, win_d = H.in_new_window(function()
    return canvas.open(six_sections(), {})
  end)

  with_fake_runtime(function(runtime)
    local lease_c = virt.attach(state_c, { enabled = false })
    runtime.autocmds[1].callback({ match = tostring(state_c.win) })
    local timer_c = runtime.timers[1]
    local lease_d
    timer_c.on_stop = function()
      lease_d = virt.attach(state_d, { enabled = false })
    end

    H.eq(virt.detach(lease_c), true)
    assert(lease_d, "timer stop reentrantly installed independent D")
    local group_d = runtime.group_order[2]
    assert(runtime.groups[group_d],
      "D's reused group survives the remainder of C teardown")
    H.eq(timer_c.stopped, 1)
    H.eq(timer_c.closed, 1)
    H.eq(virt.apply(lease_c, { enabled = true, max_files = 0 }), false,
      "disposed C can never apply")
    H.eq(virt.detach(lease_d), true, "D remains an independent live exact lease")
  end)
  H.close_windows(win_c, win_d)
end

T["virt_ attaching a peer never invokes predecessor teardown"] = function()
  local state_a, win_a = H.in_new_window(function()
    return canvas.open(six_sections(), {})
  end)
  local state_b, win_b = H.in_new_window(function()
    return canvas.open(six_sections(), {})
  end)
  local state_c, win_c = H.in_new_window(function()
    return canvas.open(six_sections(), {})
  end)

  with_fake_runtime(function(runtime)
    local lease_a = virt.attach(state_a, { enabled = false })
    runtime.autocmds[1].callback({ match = tostring(state_a.win) })
    local timer_a = runtime.timers[1]
    local lease_b
    timer_a.on_stop = function()
      lease_b = virt.attach(state_b, { enabled = false })
    end

    local lease_c = virt.attach(state_c, { enabled = false })
    H.eq(lease_b, nil, "attaching C never stops A or enters its timer teardown")
    H.eq(lease_a.disposed, false)
    H.eq(timer_a.stopped, 0)
    assert(runtime.groups[lease_a.aug], "A's group remains installed")
    assert(runtime.groups[lease_c.aug], "C's independent group is installed")

    H.eq(virt.detach(lease_a), true)
    assert(lease_b, "only A's explicit detach entered its timer teardown")
    assert(runtime.groups[lease_c.aug], "C survives A's reentrant teardown")
    assert(runtime.groups[lease_b.aug], "reentrant B is independently installed")
    H.eq(virt.detach(lease_c), true)
    H.eq(virt.detach(lease_b), true)
  end)
  H.close_windows(win_a, win_b, win_c)
end

T["virt_ alive reentrancy can create a peer without revoking either lease"] = function()
  local state_a = canvas.open(six_sections(), {})
  local state_b = canvas.open(six_sections(), {})
  local create_peer = false
  local lease_b
  local lease_a = virt.attach(state_a, { enabled = false }, {
    alive = function()
      if create_peer then
        create_peer = false
        lease_b = virt.attach(state_b, { enabled = false })
      end
      return true
    end,
  })

  create_peer = true
  H.eq(virt.apply(lease_a, {
    enabled = false,
    margin = 0,
  }), false, "A remains authorized after its callback creates peer B")
  assert(lease_b, "alive installed independent B")
  H.eq(lease_a.disposed, false)
  H.eq(lease_b.disposed, false)
  assert(lease_a.group_name ~= lease_b.group_name)
  H.eq(virt.detach(lease_a), true)
  H.eq(virt.apply(lease_b, { enabled = false }), false,
    "B remains usable after exact detach(A)")
  H.eq(virt.detach(lease_b), true)
end

T["virt_ owner invalidation after viewport read prevents stale mutation"] = function()
  local owner_alive = true
  local st, lease = open_six({
    alive = function() return owner_alive end,
  })
  reset_view(st)
  local real_win_call = vim.api.nvim_win_call
  vim.api.nvim_win_call = function(...)
    local result = real_win_call(...)
    owner_alive = false
    return result
  end

  local ok, changed = pcall(virt.apply, lease, {
    enabled = true,
    max_files = 3,
    max_lines = 1000000,
    margin = 10,
    max_expanded = 2,
  })
  vim.api.nvim_win_call = real_win_call

  assert(ok, changed)
  H.eq(changed, false)
  H.eq(next(H.auto_set(st)), nil,
    "an owner invalidated at the viewport boundary performs no mutation")
  H.eq(lease.disposed, false,
    "owner invalidation and exact resource teardown remain separate")
  H.eq(virt.detach(lease), true)
end

T["virt_ owner invalidation during a splice stops the remaining pass"] = function()
  local owner_alive = true
  local notifications = 0
  local st, lease = open_six({
    alive = function() return owner_alive end,
    on_change = function() notifications = notifications + 1 end,
  })
  reset_view(st)
  st.hooks = {
    on_section_replaced = function()
      owner_alive = false
    end,
  }

  H.eq(virt.apply(lease, {
    enabled = true,
    max_files = 3,
    max_lines = 1000000,
    margin = 10,
    max_expanded = 2,
  }), true, "the first splice happened before owner invalidation")
  H.eq(vim.tbl_count(H.auto_set(st)), 1,
    "the invalidated owner performs no later collapse")
  H.eq(notifications, 0,
    "an invalidated owner does not publish the partial pass")
  H.eq(virt.detach(lease), true)
end

T["virt_ owner callback faults are observable and attach is transactional"] = function()
  local state, lease = open_six({
    on_change = function()
      error("direct virt callback fault")
    end,
  })
  reset_view(state)
  local opts = {
    enabled = true,
    max_files = 3,
    max_lines = 1000000,
    margin = 10,
    max_expanded = 2,
  }

  local ok, err = pcall(virt.apply, lease, opts)
  H.eq(ok, false)
  assert(tostring(err):find("direct virt callback fault", 1, true), tostring(err))
  assert(next(H.auto_set(state)), "the mutating pass happened before its raw callback fault")
  H.eq(virt.detach(lease), true, "a direct callback fault leaves explicit teardown possible")

  local state2 = canvas.open(six_sections(), {})
  reset_view(state2)
  ok, err = pcall(virt.attach, state2, opts, {
    on_change = function()
      error("immediate virt callback fault")
    end,
  })
  H.eq(ok, false)
  assert(tostring(err):find("immediate virt callback fault", 1, true), tostring(err))
  H.eq(virt.detach(nil), false,
    "failed immediate attach leaves no unqualified teardown capability")
end

T["virt_ immediate callback may attach an independent peer"] = function()
  local state_a, win_a = H.in_new_window(function()
    return canvas.open(six_sections(), {})
  end)
  reset_view(state_a)
  local state_b, win_b = H.in_new_window(function()
    return canvas.open(six_sections(), {})
  end)
  local lease_b
  local opts = {
    enabled = true,
    max_files = 3,
    max_lines = 1000000,
    margin = 10,
    max_expanded = 2,
  }

  local ok, lease_a = pcall(virt.attach, state_a, opts, {
    on_change = function()
      lease_b = virt.attach(state_b, { enabled = false })
    end,
  })
  H.eq(ok, true, lease_a)
  assert(lease_a, "the outer attach returns its own lease")
  assert(lease_b, "the callback's peer was installed")
  H.eq(lease_a.disposed, false)
  H.eq(lease_b.disposed, false)
  assert(lease_a.group_name ~= lease_b.group_name)
  H.eq(virt.apply(lease_b, { enabled = false }), false,
    "the peer remains independently usable")
  H.eq(virt.detach(lease_a), true)
  H.eq(virt.detach(lease_b), true)
  H.close_windows(win_a, win_b)
end

T["virt_ queued work resolves the latest rebound canvas window"] = function()
  local state = canvas.open(six_sections(), {})
  reset_view(state)
  local original = state.win
  local alternate = vim.api.nvim_open_win(state.buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 30,
    height = 8,
    style = "minimal",
  })
  vim.api.nvim_win_call(alternate, function()
    vim.cmd("normal! G")
  end)

  local ok, err = pcall(function()
    with_fake_runtime(function(runtime)
      -- Active threshold, but no initial collapse. Mutating this same options
      -- table later lets the queued pass become discriminating.
      local opts = {
        enabled = true,
        max_files = 3,
        max_lines = 1000000,
        margin = 0,
        max_expanded = 6,
      }
      local lease = virt.attach(state, opts)
      local autocmd = runtime.autocmds[1].callback

      -- The event follows a window adopted after attach.
      state.win = alternate
      autocmd({ match = tostring(alternate) })
      H.eq(#runtime.timers, 1,
        "event eligibility reads the current state.win, not the attach-time win")
      runtime.timers[1].callback()
      H.eq(#runtime.scheduled, 1)

      -- Rebind again after the raw timer queued its main-loop work. The actual
      -- policy pass must classify at this latest top-of-canvas window.
      state.win = original
      reset_view(state)
      opts.max_expanded = 2
      runtime.scheduled[1]()
      H.eq(state.collapsed[state.sections[2].path], nil,
        "a near-top section stays expanded")
      assert(state.collapsed[state.sections[6].path],
        "the far bottom collapses; queued work did not retain the old bottom window")
      H.eq(virt.detach(lease), true)
    end)
  end)

  state.win = original
  if vim.api.nvim_win_is_valid(alternate) then
    pcall(vim.api.nvim_win_close, alternate, true)
  end
  assert(ok, err)
end

T["virt_ folded-away sections do not count as expanded"] = function()
  local st, lease = open_six()
  reset_view(st)
  -- Fold two of the six away. They already occupy one row each, so virt must
  -- see four expanded sections, not six -- and must never pick one of them as
  -- an eviction candidate (that would record it as "auto" while splicing
  -- nothing, freeing zero rows and leaving the user a collapse to inherit on
  -- unfold).
  st.folded = { ["e/"] = true, ["f/"] = true }
  canvas.resync_visibility(st)

  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }
  virt.apply(lease, opts)

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
  virt.detach(lease)
end

T["virt_ unfolding leaves an auto-collapsed section as a placeholder"] = function()
  local st, lease = open_six()
  reset_view(st)
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }
  virt.apply(lease, opts)

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
  virt.detach(lease)
end

T["virt_ inactive under thresholds leaves everything expanded"] = function()
  local st, lease = open_six()
  reset_view(st)
  virt.apply(lease, { enabled = true, max_files = 100, max_lines = 1000000, margin = 10, max_expanded = 2 })
  H.eq(count_collapsed(st), 0, "under thresholds: nothing collapsed")
  for i = 1, 6 do
    local s, e = canvas.section_rows(st, i)
    assert(e - s > 1, "section " .. i .. " is not a 1-row placeholder")
  end
  H.eq(virt.detach(lease), true)
end

T["virt_ active collapses far sections beyond max_expanded and keeps near ones"] = function()
  local st, lease = open_six()
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

  virt.apply(lease, opts)

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
  H.eq(virt.detach(lease), true)
end

T["virt_ scroll then apply expands newly-near and collapses newly-far"] = function()
  local st, lease = open_six()
  reset_view(st)
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }

  virt.apply(lease, opts)
  -- first two sections (nearest the top-of-viewport window) survive the
  -- first apply expanded; the rest collapse to their placeholder row.
  H.eq(st.collapsed[st.sections[1].path], nil, "sanity: section 1 expanded after first apply")
  H.eq(st.collapsed[st.sections[2].path], nil, "sanity: section 2 expanded after first apply")
  assert(st.collapsed[st.sections[6].path], "sanity: section 6 collapsed after first apply")

  vim.api.nvim_win_call(st.win, function() vim.cmd("normal! G") end)
  local before = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)

  virt.apply(lease, opts)

  local after = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)
  H.eq(after, before, "zero motion: visible top line unchanged across the apply")

  H.eq(st.collapsed[st.sections[6].path], nil, "last section expanded once near")
  assert(st.collapsed[st.sections[1].path], "first section collapsed once far")
  H.eq(virt.detach(lease), true)
end

T["virt_ never auto-expands a user-collapsed section"] = function()
  local st, lease = open_six()
  reset_view(st)
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 1000, max_expanded = 6 }

  -- User-collapses a section that sits inside the viewport, via the plain
  -- canvas primitive (not virt) -- this must never be auto-expanded back.
  canvas.set_collapsed(st, 1, true)

  virt.apply(lease, opts)

  assert(st.collapsed[st.sections[1].path], "user-collapsed section stays collapsed")
  H.eq(H.auto_set(st)[st.sections[1].path], nil, "auto-set never claims a user-collapsed path")
  H.eq(virt.detach(lease), true)
end

T["virt_ deactivation auto-expands only the auto set"] = function()
  local st, lease = open_six()
  reset_view(st)
  local active_opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }

  virt.apply(lease, active_opts)
  assert(next(H.auto_set(st)) ~= nil, "sanity: something got auto-collapsed")
  assert(st.collapsed[st.sections[1].path] == nil, "sanity: section 1 still expanded (in-window)")

  -- User-collapses the still-expanded section 1 directly.
  canvas.set_collapsed(st, 1, true)

  local auto_before = H.auto_set(st)
  local inactive_opts = { enabled = true, max_files = 100, max_lines = 1000000, margin = 10, max_expanded = 2 }
  virt.apply(lease, inactive_opts)

  for path in pairs(auto_before) do
    H.eq(st.collapsed[path], nil, "auto-collapsed section " .. path .. " expanded back")
  end
  assert(st.collapsed[st.sections[1].path], "user-collapsed section 1 stays collapsed")
  H.eq(next(H.auto_set(st)), nil, "auto-set cleared")
  H.eq(virt.detach(lease), true)
end

-- The max_lines threshold must describe the CHANGESET, not the current
-- rendering. Six big_sections are 312 rows fully expanded; once virt
-- collapses four of them the buffer is only 108 rows. Measuring the buffer
-- would put a max_lines of 200 on the wrong side of the threshold on the
-- second pass, deactivating virt, expanding everything back, and leaving the
-- canvas oscillating between virtualized and fully rendered on every scroll.
T["virt_ stays active while its own collapses shrink the buffer"] = function()
  local st, lease = open_six()
  reset_view(st)
  local opts = { enabled = true, max_files = 1000, max_lines = 200, margin = 10, max_expanded = 2 }

  virt.apply(lease, opts)

  local collapsed_after_first = count_collapsed(st)
  assert(collapsed_after_first > 0, "sanity: the first apply auto-collapsed something")
  local rendered = vim.api.nvim_buf_line_count(st.buf)
  assert(rendered < 200,
    "sanity: collapsing dropped the buffer below max_lines (got " .. rendered .. ")")

  virt.apply(lease, opts)

  H.eq(count_collapsed(st), collapsed_after_first,
    "a second apply keeps the same sections collapsed")
  assert(next(H.auto_set(st)) ~= nil, "auto-set survives the second apply")
  H.eq(virt.detach(lease), true)
end

T["virt_ on_change fires once per mutating apply"] = function()
  local n, seen = 0, nil
  local st, lease = open_six({
    on_change = function(state)
      n = n + 1
      seen = state
    end,
  })
  reset_view(st)
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }

  H.eq(virt.apply(lease, opts), true)
  H.eq(n, 1, "one notification for the apply that collapsed sections")
  H.eq(seen, st, "the callback receives the state that was applied")

  H.eq(virt.apply(lease, opts), false)
  H.eq(n, 1, "an apply that changes nothing stays silent")
  H.eq(virt.detach(lease), true)
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
  local st
  local lease
  local hl_lease
  st, lease = open_six({
    on_change = function()
      hl.apply_now(hl_lease)
    end,
  })
  reset_view(st)
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 0, max_expanded = 1 }

  hl_lease = hl.attach(st, { margin = 0, debounce_ms = 30 })

  virt.apply(lease, opts)
  local path = st.sections[6].path
  assert(st.collapsed[path], "sanity: section 6 auto-collapsed while far from the viewport")
  H.eq(hl_lease.ids_by_path[path], nil, "sanity: a collapsed section carries no marks")

  local s6 = (canvas.section_rows(st, 6))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = s6 + 1, lnum = s6 + 1 })
  end)
  virt.apply(lease, opts)

  H.eq(st.collapsed[path], nil, "section 6 expanded back once it was near")
  assert(hl_lease.ids_by_path[path] ~= nil, "the expanded section got its highlights back")

  hl.detach(hl_lease)
  H.eq(virt.detach(lease), true)
end

-- The LRU belongs to a lease, not a path or canvas state. Reattaching even the
-- SAME state must start a fresh visibility history; otherwise bottom-of-canvas
-- ticks from the predecessor outrank what the new lease has actually seen and
-- invert the eviction policy.
T["virt_ a fresh lease on the same canvas forgets predecessor history"] = function()
  local opts = { enabled = true, max_files = 3, max_lines = 1000000, margin = 10, max_expanded = 2 }

  local st, lease1 = open_six()
  -- Park the predecessor at the bottom so its last sections look recent.
  vim.api.nvim_win_call(st.win, function()
    vim.cmd("normal! G")
  end)
  virt.apply(lease1, opts)
  assert(H.auto_set(st)["a/one.txt"], "sanity: the predecessor collapsed its far top")

  -- Expand its auto set, explicitly retire it, then attach a fresh lease
  -- without changing the state identity.
  virt.apply(lease1, { enabled = false })
  H.eq(virt.detach(lease1), true)
  reset_view(st)
  local lease2 = virt.attach(st, opts)

  H.eq(st.collapsed[st.sections[2].path], nil,
    "the section just below the viewport stays expanded")
  assert(st.collapsed[st.sections[6].path],
    "the farthest section is collapsed, not protected by predecessor ticks")

  H.eq(virt.detach(lease2), true)
end

return T
