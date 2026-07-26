local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")
local sidebar = require("canvasdiff.ui").sidebar

local T = {}

local SIDE_NS = vim.api.nvim_create_namespace("canvasdiff.sidebar")

local function section(path, tag)
  local old = {}
  local new = {}
  for i = 1, 60 do
    old[i] = ("%s old %d"):format(tag, i)
    new[i] = old[i]
  end
  for i = 10, 60, 10 do
    new[i] = new[i] .. " changed"
  end
  return model.build_section(
    path, table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", "M")
end

local function state(paths)
  local sections = {}
  for i, path in ipairs(paths or { "a/one.txt", "b/two.txt" }) do
    sections[i] = section(path, tostring(i))
  end
  local st = canvas.open(sections, {})
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  return st
end

local function views(lease, tab)
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab or 0)) do
    if sidebar.is_sidebar_win(lease, win) then
      out[#out + 1] = win
    end
  end
  table.sort(out)
  return out
end

local function one_view(lease, tab)
  local found = views(lease, tab)
  H.eq(#found, 1, "one sidebar view in this host tab")
  return found[1]
end

local function sidebar_buf(lease, tab)
  return vim.api.nvim_win_get_buf(one_view(lease, tab))
end

local function owner_callbacks(owner)
  return {
    claim = function(lease)
      owner.lease = lease
      return true
    end,
    alive = function(lease)
      return owner.alive ~= false and owner.lease == lease
    end,
    snapshot = function()
      return {
        hosts = vim.list_slice(owner.hosts),
        canvas = vim.list_slice(owner.canvas),
      }
    end,
    on_shape_change = function(lease)
      owner.shape_changes = owner.shape_changes + 1
      sidebar.refresh(lease)
    end,
    on_locate = function(_, _, win, path)
      owner.locates[#owner.locates + 1] = { win = win, path = path }
    end,
    on_return = function(_, _, win)
      owner.returned = win
    end,
    release = function(lease)
      if owner.lease ~= lease then return false end
      owner.lease = nil
      owner.releases = owner.releases + 1
      return true
    end,
  }
end

local function owner_for(st)
  return {
    alive = true,
    hosts = { st.win },
    canvas = { st.win },
    shape_changes = 0,
    locates = {},
    releases = 0,
  }
end

local function with_tab(body)
  local baseline = {}
  for _, existing in ipairs(vim.api.nvim_list_tabpages()) do
    baseline[existing] = true
  end
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local leases = {}
  local function remember(lease)
    leases[#leases + 1] = lease
    return lease
  end

  local ok, err = xpcall(function()
    body(remember, tab)
  end, debug.traceback)

  for i = #leases, 1, -1 do
    pcall(sidebar.close, leases[i])
  end
  for _, candidate in ipairs(vim.api.nvim_list_tabpages()) do
    if not baseline[candidate] and vim.api.nvim_tabpage_is_valid(candidate) then
      pcall(vim.api.nvim_set_current_tabpage, candidate)
      pcall(vim.cmd, "tabclose!")
    end
  end
  assert(ok, err)
end

local function sidebar_autocmds()
  local out = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    local group = autocmd.group_name or ""
    if group == "canvasdiff.sidebar" or group:match("^canvasdiff%.sidebar%.") then
      out[#out + 1] = autocmd
    end
  end
  return out
end

local function mark_snapshot(buf)
  local out = vim.api.nvim_buf_get_extmarks(buf, SIDE_NS, 0, -1, {
    details = true,
    hl_name = true,
  })
  for _, mark in ipairs(out) do
    local details = mark[4] or {}
    details.ns_id = nil
    details.invalid = nil
  end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end

local function set_complex_foreign_mark(buf, id)
  vim.api.nvim_buf_set_extmark(buf, SIDE_NS, 2, 0, {
    id = id,
    end_row = 3,
    end_col = 1,
    hl_group = "Comment",
    hl_eol = true,
    hl_mode = "combine",
    virt_text = { { " foreign ", "Comment" } },
    virt_text_pos = "eol",
    virt_text_hide = true,
    right_gravity = false,
    end_right_gravity = true,
    priority = 777,
    sign_text = "F",
    sign_hl_group = "WarningMsg",
    cursorline_hl_group = "CursorLine",
    number_hl_group = "LineNr",
    line_hl_group = "CursorLine",
    spell = true,
    undo_restore = false,
    invalidate = true,
    url = "https://example.invalid/sidebar-foreign-mark",
  })
end

T["sidebar_lease a forged shell cannot authenticate as a lease"] = function()
  with_tab(function(remember)
    local st = state({ "a/one.txt", "b/two.txt" })
    local lease = remember(assert(sidebar.open(st, { width = 24 })))
    local win = one_view(lease)
    local buf = vim.api.nvim_win_get_buf(win)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- Every public field a lease carries, copied verbatim. Authentication has
    -- to rest on something a caller cannot reproduce.
    local copy = {}
    for k, v in pairs(lease) do
      copy[k] = v
    end
    local forgeries = {
      copy,
      setmetatable({}, { __index = lease }),
      { phase = "active", disposed = false, views_by_tab = lease.views_by_tab,
        views_by_win = lease.views_by_win, state = st, callbacks = {} },
      "not a table",
      nil,
    }
    for i = 1, 5 do
      local forged = forgeries[i]
      H.eq(sidebar.close(forged), false, "a forged handle cannot close a real lease")
      H.eq(sidebar.is_open(forged), false, "a forged handle owns no view")
      H.eq(sidebar.is_sidebar_win(forged, win), false,
        "a forged handle cannot claim a real view")
      H.eq(sidebar.refresh(forged), false, "a forged handle cannot redraw")
      H.eq(sidebar.reconcile(forged), false, "a forged handle cannot reconcile")
      H.eq(sidebar.sync(forged, st.win), false, "a forged handle cannot move the cursor")
      H.eq(sidebar.mark_path(forged, "a/one.txt", st.win), false,
        "a forged handle cannot select a path")
    end

    assert(sidebar.is_open(lease), "the real lease is still open")
    H.eq(one_view(lease), win, "the real view is untouched")
    H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines,
      "no forgery rewrote the real sidebar")
    H.eq(sidebar.close(lease), true)
  end)
end

T["sidebar_lease two simultaneous leases keep independent views and teardown"] = function()
  with_tab(function(remember)
    local st_a = state({ "a/one.txt", "a/two.txt" })
    local owner_a = owner_for(st_a)
    local lease_a = remember(assert(
      sidebar.open(st_a, { width = 24 }, owner_callbacks(owner_a))))
    local win_a = one_view(lease_a)
    local buf_a = vim.api.nvim_win_get_buf(win_a)

    -- A second review opens while the first is still live, in a window of its
    -- own -- reviews own one buffer each, so opening B over A's window would
    -- simply take that window. Nothing in the sidebar arbitrates between them.
    local st_b = H.in_new_window(function()
      return state({ "x/new.txt", "y/other.txt" })
    end)
    local owner_b = owner_for(st_b)
    local lease_b = remember(assert(
      sidebar.open(st_b, { width = 26 }, owner_callbacks(owner_b))))
    local win_b
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if sidebar.is_sidebar_win(lease_b, win) then
        win_b = win
      end
    end
    assert(win_b, "B opened its own view")
    assert(win_a ~= win_b, "the two leases own distinct windows")
    local buf_b = vim.api.nvim_win_get_buf(win_b)
    assert(buf_a ~= buf_b, "the two leases own distinct buffers")
    assert(lease_a.group_name ~= lease_b.group_name, "group names never collide")

    H.eq(sidebar.is_sidebar_win(lease_a, win_b), false, "A does not claim B's view")
    H.eq(sidebar.is_sidebar_win(lease_b, win_a), false, "B does not claim A's view")
    assert(sidebar.is_open(lease_a), "opening B did not supersede A")
    assert(sidebar.is_open(lease_b))
    assert(sidebar.refresh(lease_a), "A still redraws alongside B")
    assert(sidebar.refresh(lease_b))

    local lines_b = vim.api.nvim_buf_get_lines(buf_b, 0, -1, false)
    H.eq(sidebar.close(lease_a), true)
    H.eq(owner_a.releases, 1, "A released exactly its own owner slot")
    H.eq(owner_b.releases, 0, "A teardown never released B")
    assert(not vim.api.nvim_win_is_valid(win_a), "A's window is gone")
    assert(sidebar.is_open(lease_b), "B survives its peer's teardown")
    H.eq(vim.api.nvim_buf_get_lines(buf_b, 0, -1, false), lines_b,
      "A teardown never rewrote B's buffer")
    assert(sidebar.refresh(lease_b), "B remains functional")

    H.eq(sidebar.close(lease_b), true)
    H.eq(owner_b.releases, 1)
  end)
end

T["sidebar_lease throwing claim releases a partially published identity"] = function()
  with_tab(function()
    local st = state()
    local owner = { lease = nil, releases = 0 }
    local captured
    local ok, err = pcall(sidebar.open, st, { width = 24 }, {
      claim = function(lease)
        captured = lease
        owner.lease = lease
        error("injected sidebar claim fault")
      end,
      release = function(lease)
        H.eq(owner.lease, lease, "release receives only the identity claim published")
        owner.lease = nil
        owner.releases = owner.releases + 1
      end,
    })

    assert(not ok and tostring(err):find("injected sidebar claim fault", 1, true), err)
    assert(captured, "the fault happened after an exact lease existed")
    H.eq(captured.phase, "disposed")
    H.eq(captured.disposed, true)
    H.eq(captured.state, nil, "failed attach releases the Canvas graph")
    H.eq(owner.lease, nil, "release undoes a claim that threw after publishing")
    H.eq(owner.releases, 1, "partial ownership is released exactly once")
    H.eq(sidebar.close(captured), false, "failed attach is terminal and idempotent")
    H.eq(#views(captured), 0)
  end)
end

T["sidebar_lease line write then throw rolls back lines and every prior mark"] = function()
  with_tab(function(remember)
    local st = state()
    local lease = remember(assert(sidebar.open(st, { width = 24 })))
    local buf = sidebar_buf(lease)
    local foreign_id = 900002
    set_complex_foreign_mark(buf, foreign_id)
    local lines_before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local marks_before = mark_snapshot(buf)
    st.sections = {
      section("a/one.txt", "one"),
      section("b/two.txt", "two"),
      section("c/three.txt", "three"),
    }

    local real_set_lines = vim.api.nvim_buf_set_lines
    local injected = false
    vim.api.nvim_buf_set_lines = function(target, ...)
      local result = real_set_lines(target, ...)
      if target == buf and not injected then
        injected = true
        error("injected sidebar post-write fault")
      end
      return result
    end
    local ok, err = pcall(sidebar.refresh, lease)
    vim.api.nvim_buf_set_lines = real_set_lines

    assert(not ok and tostring(err):find("injected sidebar post%-write fault"), err)
    H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines_before,
      "a call that mutates then throws is rolled back to the prior render")
    H.eq(mark_snapshot(buf), marks_before,
      "rollback restores every owned and foreign coordinate, range, gravity, and decoration")
    H.eq(vim.api.nvim_get_option_value("modifiable", { buf = buf }), false)

    assert(sidebar.refresh(lease), "the same lease retries after rollback")
    assert(#vim.api.nvim_buf_get_lines(buf, 0, -1, false) > #lines_before,
      "the retry commits the new tree")
  end)
end

T["sidebar_lease extmark write then throw rolls back the whole refresh"] = function()
  with_tab(function(remember)
    local st = state()
    local lease = remember(assert(sidebar.open(st, { width = 24 })))
    local buf = sidebar_buf(lease)
    local foreign_id = 900003
    set_complex_foreign_mark(buf, foreign_id)
    local lines_before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local marks_before = mark_snapshot(buf)
    st.sections = {
      section("a/one.txt", "one"),
      section("b/two.txt", "two"),
      section("c/three.txt", "three"),
    }

    local real_set_extmark = vim.api.nvim_buf_set_extmark
    local injected = false
    vim.api.nvim_buf_set_extmark = function(target, namespace, ...)
      local id = real_set_extmark(target, namespace, ...)
      if target == buf and namespace == SIDE_NS and not injected then
        injected = true
        error("injected sidebar post-extmark fault")
      end
      return id
    end
    local ok, err = pcall(sidebar.refresh, lease)
    vim.api.nvim_buf_set_extmark = real_set_extmark

    assert(not ok and tostring(err):find("injected sidebar post%-extmark fault"), err)
    H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines_before)
    H.eq(mark_snapshot(buf), marks_before,
      "placement rollback restores full state, not only the set of prior IDs")
    assert(sidebar.refresh(lease), "placement rollback leaves the lease retryable")
  end)
end

T["sidebar_lease reentrant close during placement leaves no partial graph"] = function()
  with_tab(function(remember)
    local st = state()
    local owner = owner_for(st)
    local lease = remember(assert(sidebar.open(
      st, { width = 24 }, owner_callbacks(owner))))
    local buf = sidebar_buf(lease)

    local real_set_extmark = vim.api.nvim_buf_set_extmark
    local injected = false
    vim.api.nvim_buf_set_extmark = function(target, namespace, ...)
      local id = real_set_extmark(target, namespace, ...)
      if target == buf and namespace == SIDE_NS and not injected then
        injected = true
        H.eq(sidebar.close(lease), true, "the placement callback closes its exact lease")
      end
      return id
    end
    local ok, result = pcall(sidebar.sync, lease, st.win)
    vim.api.nvim_buf_set_extmark = real_set_extmark

    assert(ok, result)
    H.eq(result, false, "the superseded placement reports no committed work")
    H.eq(lease.phase, "disposed")
    H.eq(lease.state, nil)
    H.eq(owner.lease, nil)
    H.eq(owner.releases, 1)
    H.eq(vim.api.nvim_buf_is_valid(buf), false, "teardown reaps the partial mark buffer")
    H.eq(sidebar.close(lease), false)
  end)
end

T["sidebar_lease reentrant close during foreign-mark restore cancels cleanly"] = function()
  with_tab(function(remember)
    local st = state()
    local owner = owner_for(st)
    local lease = remember(assert(sidebar.open(
      st, { width = 24 }, owner_callbacks(owner))))
    local buf = sidebar_buf(lease)
    local foreign_a, foreign_b = 900004, 900005
    vim.api.nvim_buf_set_extmark(buf, SIDE_NS, 0, 0, { id = foreign_a })
    vim.api.nvim_buf_set_extmark(buf, SIDE_NS, 1, 0, { id = foreign_b })

    local real_set_extmark = vim.api.nvim_buf_set_extmark
    local injected = false
    vim.api.nvim_buf_set_extmark = function(target, namespace, row, col, opts)
      local id = real_set_extmark(target, namespace, row, col, opts)
      if target == buf and namespace == SIDE_NS and opts.id == foreign_a and not injected then
        injected = true
        H.eq(sidebar.close(lease), true,
          "foreign-mark restoration can reentrantly retire its exact lease")
      end
      return id
    end
    local ok, result = pcall(sidebar.refresh, lease)
    vim.api.nvim_buf_set_extmark = real_set_extmark

    assert(ok, result)
    H.eq(result, false, "restoration stops before touching a disposed view again")
    H.eq(lease.phase, "disposed")
    H.eq(lease.state, nil)
    H.eq(owner.lease, nil)
    H.eq(owner.releases, 1)
    H.eq(vim.api.nvim_buf_is_valid(buf), false)
  end)
end

T["sidebar_lease reentrant close during mark snapshot cancels cleanly"] = function()
  with_tab(function(remember)
    local st = state()
    local owner = owner_for(st)
    local lease = remember(assert(sidebar.open(
      st, { width = 24 }, owner_callbacks(owner))))
    local buf = sidebar_buf(lease)

    local real_get_extmarks = vim.api.nvim_buf_get_extmarks
    local injected = false
    vim.api.nvim_buf_get_extmarks = function(target, namespace, ...)
      local marks = real_get_extmarks(target, namespace, ...)
      if target == buf and namespace == SIDE_NS and not injected then
        injected = true
        H.eq(sidebar.close(lease), true,
          "the mark snapshot can reentrantly retire its exact lease")
      end
      return marks
    end
    local ok, result = pcall(sidebar.refresh, lease)
    vim.api.nvim_buf_get_extmarks = real_get_extmarks

    assert(ok, result)
    H.eq(result, false, "snapshot results are discarded after their view is disposed")
    H.eq(lease.phase, "disposed")
    H.eq(lease.state, nil)
    H.eq(owner.lease, nil)
    H.eq(owner.releases, 1)
    H.eq(vim.api.nvim_buf_is_valid(buf), false)
  end)
end

T["sidebar_lease retained A sources and stale close cannot reach B"] = function()
  with_tab(function(remember)
    local st_a = state({ "a/one.txt", "a/two.txt" })
    local weak = setmetatable({ state = st_a }, { __mode = "v" })
    local lease_a = remember(assert(sidebar.open(st_a, { width = 24 })))
    local buf_a = sidebar_buf(lease_a)

    local held_select, held_close
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf_a, "n")) do
      if H.norm_lhs(map.lhs) == H.norm_lhs("<CR>") then
        held_select = map.callback
      elseif H.norm_lhs(map.lhs) == H.norm_lhs("q") then
        held_close = map.callback
      end
    end
    assert(held_select, "A exposes its select callback")
    assert(held_close, "A exposes its exact close callback")

    local held_autocmds = sidebar_autocmds()
    assert(#held_autocmds > 0, "A installed event sources")

    -- Cross the deferred host-close boundary while A is current, but retain
    -- the queued callback until after B has replaced it.
    local scheduled = {}
    local real_schedule = vim.schedule
    vim.schedule = function(callback)
      scheduled[#scheduled + 1] = callback
    end
    local callback_error
    for _, autocmd in ipairs(held_autocmds) do
      local pattern = autocmd.pattern
      local host_event = pattern == nil or pattern == "*"
        or pattern == tostring(st_a.win)
      if #scheduled == 0 and autocmd.event == "WinClosed" and host_event
          and type(autocmd.callback) == "function" then
        local ok, err = pcall(autocmd.callback, { match = tostring(st_a.win) })
        if not ok then callback_error = callback_error or err end
      end
    end
    vim.schedule = real_schedule
    assert(not callback_error, callback_error)
    assert(#scheduled > 0, "A queued a deferred host reconciliation")

    H.eq(sidebar.close(lease_a), true, "A closes only its exact resources")
    local st_b = state({ "x/new.txt", "y/other.txt" })
    local lease_b = remember(assert(sidebar.open(st_b, { width = 25 })))
    local win_b = one_view(lease_b)
    local buf_b = vim.api.nvim_win_get_buf(win_b)
    local lines_b = vim.api.nvim_buf_get_lines(buf_b, 0, -1, false)
    local top_b = vim.api.nvim_win_call(st_b.win, function() return vim.fn.line("w0") end)

    H.eq(sidebar.close(lease_a), false, "repeat exact close(A) cannot close B")
    H.eq(sidebar.is_sidebar_win(lease_a, win_b), false,
      "a stale lease cannot claim B's view")
    held_select()
    held_close()
    for _, autocmd in ipairs(held_autocmds) do
      if type(autocmd.callback) == "function" then
        autocmd.callback({ match = tostring(st_b.win) })
      end
    end
    for _, callback in ipairs(scheduled) do callback() end

    assert(sidebar.is_open(lease_b), "B survives every retained A source")
    H.eq(one_view(lease_b), win_b)
    H.eq(vim.api.nvim_win_get_buf(win_b), buf_b)
    H.eq(vim.api.nvim_buf_get_lines(buf_b, 0, -1, false), lines_b)
    H.eq(vim.api.nvim_win_call(st_b.win, function() return vim.fn.line("w0") end), top_b,
      "A's retained selection cannot scroll B")

    -- The held callbacks still exist, so collecting A proves they capture only
    -- the released lease shell rather than its Canvas graph.
    st_a = nil
    collectgarbage("collect")
    collectgarbage("collect")
    H.eq(weak.state, nil, "replacement releases A's state graph")

    H.eq(sidebar.close(lease_b), true)
    H.eq(sidebar.close(lease_b), false, "exact close is idempotent")
  end)
end

T["sidebar_lease refresh restores modifiable and preserves foreign namespace marks"] = function()
  with_tab(function(remember)
    local st = state()
    local lease = remember(assert(sidebar.open(st, { width = 24 })))
    local buf = sidebar_buf(lease)
    local foreign_id = 900001
    vim.api.nvim_buf_set_extmark(buf, SIDE_NS, 0, 0, {
      id = foreign_id,
      end_col = 1,
      hl_group = "Comment",
    })

    local real_set_lines = vim.api.nvim_buf_set_lines
    local injected = false
    vim.api.nvim_buf_set_lines = function(target, ...)
      if target == buf and not injected then
        injected = true
        error("injected sidebar line-write fault")
      end
      return real_set_lines(target, ...)
    end
    local ok, err = pcall(sidebar.refresh, lease)
    vim.api.nvim_buf_set_lines = real_set_lines

    assert(not ok and tostring(err):find("injected sidebar line%-write fault"),
      "refresh exposes the write fault")
    H.eq(vim.api.nvim_get_option_value("modifiable", { buf = buf }), false,
      "refresh restores the owned buffer's option on every exit")
    H.eq(vim.api.nvim_buf_get_extmark_by_id(buf, SIDE_NS, foreign_id, {}), { 0, 0 },
      "a failed refresh never claims the foreign mark")

    assert(sidebar.refresh(lease) ~= false, "the exact lease remains retryable")
    H.eq(vim.api.nvim_buf_get_extmark_by_id(buf, SIDE_NS, foreign_id, {}), { 0, 0 },
      "normal refresh deletes only marks owned by this lease")
    sidebar.close(lease)
  end)
end

T["sidebar_lease same-tab host rebind keeps one working view"] = function()
  with_tab(function(remember)
    local st = state({ "a/one.txt", "b/two.txt", "c/three.txt" })
    local original = st.win
    local owner = owner_for(st)
    local lease = remember(assert(sidebar.open(
      st, { width = 24 }, owner_callbacks(owner))))

    vim.api.nvim_set_current_win(original)
    vim.cmd("split")
    local survivor = vim.api.nvim_get_current_win()
    owner.hosts = { original, survivor }
    owner.canvas = { original, survivor }
    vim.api.nvim_win_close(original, false)
    owner.hosts = { survivor }
    owner.canvas = { survivor }
    sidebar.reconcile(lease)

    assert(vim.wait(500, function()
      return sidebar.is_open(lease) and #views(lease) == 1
    end, 10), "the view reconciled against the surviving split")
    local side_win = one_view(lease)
    vim.api.nvim_win_set_cursor(side_win, { 6, 0 })
    sidebar.select(lease)
    local top = vim.api.nvim_win_call(survivor, function() return vim.fn.line("w0") - 1 end)
    H.eq((canvas.locate(st, top)), 3, "the rebound view selects in the surviving host")
    H.eq(owner.releases, 0)
    sidebar.close(lease)
    H.eq(owner.releases, 1, "the owner is released exactly once")
  end)
end

T["sidebar_lease one view per host tab and tab-local host removal"] = function()
  with_tab(function(remember, local_tab)
    local st = state()
    local local_host = st.win
    local local_landing = vim.api.nvim_create_buf(false, true)
    local owner = owner_for(st)
    local lease = remember(assert(sidebar.open(
      st, { width = 24 }, owner_callbacks(owner))))
    local local_view = one_view(lease, local_tab)

    vim.cmd("tabnew")
    local remote_tab = vim.api.nvim_get_current_tabpage()
    local remote = vim.api.nvim_get_current_win()
    owner.hosts = { local_host, remote }
    owner.canvas = { local_host, remote }
    vim.api.nvim_win_set_buf(remote, st.buf)
    sidebar.reconcile(lease)

    assert(vim.wait(500, function()
      return #views(lease, local_tab) == 1 and #views(lease, remote_tab) == 1
    end, 10), "each host tab acquired exactly one sidebar view")
    assert(one_view(lease, local_tab) == local_view,
      "adding a remote host does not churn the local view")
    local remote_view = one_view(lease, remote_tab)

    owner.hosts = { remote }
    owner.canvas = { remote }
    vim.api.nvim_win_set_buf(local_host, local_landing)
    sidebar.reconcile(lease)

    assert(vim.wait(500, function()
      return #views(lease, local_tab) == 0 and #views(lease, remote_tab) == 1
    end, 10), "removing one tab's final host removes only that tab's view")
    H.eq(vim.api.nvim_win_get_buf(local_host), local_landing,
      "tab-local reconciliation preserves the foreign landing")
    H.eq(one_view(lease, remote_tab), remote_view,
      "tab-local removal does not churn the remote view")
    assert(sidebar.is_open(lease, remote_tab))

    sidebar.close(lease)
    if vim.api.nvim_tabpage_is_valid(remote_tab) then
      pcall(vim.cmd, "tabclose!")
    end
    if vim.api.nvim_buf_is_valid(local_landing) then
      pcall(vim.api.nvim_buf_delete, local_landing, { force = true })
    end
  end)
end

T["sidebar_lease manual view close is safe and explicit close remains exact"] = function()
  with_tab(function(remember, tab)
    local st = state()
    local lease = remember(assert(sidebar.open(st, { width = 24 })))
    local win = one_view(lease)
    vim.api.nvim_win_close(win, true)

    assert(vim.wait(500, function() return not sidebar.is_open(lease, tab) end, 10),
      "manual :close releases the tab's sidebar view")
    H.eq(sidebar.is_sidebar_win(lease, win), false)
    sidebar.refresh(lease)
    sidebar.sync(lease)
    sidebar.close(lease)
  end)
end

T["sidebar_lease foreign buffer and window survive exact teardown"] = function()
  with_tab(function(remember)
    local st = state()
    local lease = remember(assert(sidebar.open(st, { width = 24 })))
    local win = one_view(lease)
    local foreign = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(
      foreign, "canvasdiff-test://foreign-sidebar-window/" .. tostring(vim.uv.hrtime()))
    vim.api.nvim_buf_set_lines(foreign, 0, -1, false, { "foreign content" })

    vim.api.nvim_set_option_value("winfixbuf", false, { win = win })
    vim.api.nvim_win_set_buf(win, foreign)
    vim.api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
    sidebar.close(lease)
    vim.wait(50, function() return false end)

    assert(vim.api.nvim_win_is_valid(win), "teardown never closes a foreign window")
    H.eq(vim.api.nvim_win_get_buf(win), foreign)
    H.eq(vim.api.nvim_buf_get_lines(foreign, 0, -1, false), { "foreign content" })
    H.eq(vim.api.nvim_get_option_value("wrap", { win = win }), true,
      "teardown preserves a user override on the foreign window")

    vim.api.nvim_win_close(win, true)
    if vim.api.nvim_buf_is_valid(foreign) then
      vim.api.nvim_buf_delete(foreign, { force = true })
    end
  end)
end

return T
