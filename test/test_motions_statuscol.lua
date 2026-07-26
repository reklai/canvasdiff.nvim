local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")
local motions = require("canvasdiff.motions")
local statuscol = require("canvasdiff.statuscol")
local Surface = require("canvasdiff.Surface")
local virt = require("canvasdiff.virt")
local config = require("canvasdiff.config")

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

T["motions_ ]f [f move between section starts and clamp"] = function()
  local st = canvas.open(three_sections(), {})
  local b_start = (canvas.section_rows(st, 2))
  vim.api.nvim_win_set_cursor(st.win, { b_start + 3, 1 }) -- mid section 2

  motions.goto_file(st, 1, 1)
  local c_start = (canvas.section_rows(st, 3))
  H.eq(vim.api.nvim_win_get_cursor(st.win), { c_start + 1, 0 }, "moved to section 3 start")

  for _ = 1, 3 do
    motions.goto_file(st, 1, 1)
  end
  H.eq(vim.api.nvim_win_get_cursor(st.win), { c_start + 1, 0 }, "clamped at last section")

  for _ = 1, 5 do
    motions.goto_file(st, -1, 1)
  end
  local a_start = (canvas.section_rows(st, 1))
  H.eq(vim.api.nvim_win_get_cursor(st.win), { a_start + 1, 0 }, "clamped at first section")
end

-- --- navigation steps over what you folded -----------------------------

local function cursor_section(st)
  return (canvas.locate(st, vim.api.nvim_win_get_cursor(st.win)[1] - 1))
end

local function put_cursor_in(st, i, offset)
  local s = (canvas.section_rows(st, i))
  vim.api.nvim_win_set_cursor(st.win, { s + 1 + (offset or 0), 0 })
end

local function set_folds(st, dirs)
  st.folded = dirs
  canvas.resync_visibility(st)
end

-- Folded is folded: a folded file is one row, and navigation LANDS on it. That is
-- the whole point -- you arrive at the placeholder, press Tab to unfold, and carry
-- on. Navigation used to step over folded files, which quietly made folding mean
-- "I am done with this" rather than just "collapsed".
T["motions_ ]f [f land ON a folded-away section"] = function()
  virt.detach()
  local st = canvas.open(three_sections(), {})
  set_folds(st, { ["b/"] = true })

  put_cursor_in(st, 1, 3)
  motions.goto_file(st, 1, 1)
  H.eq(cursor_section(st), 2, "]f stops at the folded middle section, it does not skip it")
  local s2 = (canvas.section_rows(st, 2))
  H.eq(vim.api.nvim_win_get_cursor(st.win)[1], s2 + 1,
    "and lands exactly on its placeholder row, where Tab will unfold it")

  motions.goto_file(st, 1, 1)
  H.eq(cursor_section(st), 3, "carrying on from there works normally")
  motions.goto_file(st, -1, 1)
  H.eq(cursor_section(st), 2, "[f stops there too")
  set_folds(st, {})
end

-- Guard: passes before and after. It exists to fail if someone swaps the
-- navigation predicate for the rendering one. The virtualizer collapsing a
-- far-away section is bookkeeping, not the user putting it away, so navigation
-- must still be able to land there.
T["motions_ ]f stops at an auto-collapsed section"] = function()
  virt.detach()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_win_call(st.win, function() vim.fn.winrestview({ topline = 1, lnum = 1 }) end)
  local lease = virt.attach(st, { enabled = false })
  virt.apply(lease, { enabled = true, max_files = 1, max_lines = 1000000, margin = 0, max_expanded = 1 })
  local auto = H.auto_set(st)
  assert(auto["b/two.txt"], "sanity: virt auto-collapsed section 2")

  put_cursor_in(st, 1, 0)
  motions.goto_file(st, 1, 1)
  H.eq(cursor_section(st), 2, "]f lands on the auto-collapsed section, not past it")
  virt.detach(lease)
end

T["motions_ ]f [f still move with every section folded"] = function()
  virt.detach()
  local st = canvas.open(three_sections(), {})
  set_folds(st, { ["a/"] = true, ["b/"] = true, ["c/"] = true })

  put_cursor_in(st, 2, 0)
  motions.goto_file(st, 1, 1)
  H.eq(cursor_section(st), 3, "every section is a stop, so there is always somewhere to go")
  motions.goto_file(st, -1, 1)
  H.eq(cursor_section(st), 2, "and back")
  set_folds(st, {})
end

T["motions_ ]f counts every section, folded or not"] = function()
  virt.detach()
  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
    big_section("d/four.txt", "d"),
  }, {})
  set_folds(st, { ["b/"] = true })

  put_cursor_in(st, 1, 0)
  motions.goto_file(st, 1, 2)
  H.eq(cursor_section(st), 3, "2]f counts the folded b/ as one of the two")
  set_folds(st, {})
end

-- goto_file and cycle are public functions with an explicit count parameter, and
-- there is no zero-count motion in Vim -- so 0 clamps to 1 rather than meaning
-- "stay put", and it must mean the same in both of them. It briefly did not: the
-- old stepping helpers clamped while the plain-index path used the count raw.
T["motions_ count = 0 clamps to 1 in both goto_file and cycle"] = function()
  virt.detach()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_win_call(st.win, function() vim.fn.winrestview({ topline = 1, lnum = 1 }) end)

  put_cursor_in(st, 1, 3)
  motions.goto_file(st, 1, 0)
  H.eq(cursor_section(st), 2, "count 0 moves one section, like count1")

  local s1 = (canvas.section_rows(st, 1))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = s1 + 1, lnum = s1 + 1 })
  end)
  motions.cycle(st, st.win, 1, 0)
  local top0 = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") - 1 end)
  H.eq((canvas.locate(st, top0)), 2, "and cycle agrees")
end

-- A folded file gets exactly ONE ]h stop: its placeholder row. So ]h walks INTO it
-- rather than over it -- arrive, press Tab, carry on. The old behaviour skipped
-- folded sections entirely, which meant a folded file was unreachable by ]h.
--
-- What it must never do is land on a row computed from a folded section's ENTRIES.
-- That part is arithmetic, not policy: the section still carries every entry while
-- rendering as one row, so `start0 + idx - 1` would point into the FOLLOWING file.
T["motions_ ]h treats a folded section as exactly one stop"] = function()
  local st = canvas.open(three_sections(), {})
  canvas.set_collapsed(st, 2, true)

  local b_start, b_end = canvas.section_rows(st, 2)
  H.eq(b_end - b_start, 1, "sanity: section 2 is a one-row placeholder")
  local c_start = (canvas.section_rows(st, 3))

  local a_start = (canvas.section_rows(st, 1))
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 })

  -- Walk forward, collecting every row ]h stops on until we reach section 3.
  local visited, prev = {}, a_start
  for _ = 1, 30 do
    motions.goto_hunk(st, 1, 1)
    local row = vim.api.nvim_win_get_cursor(st.win)[1] - 1
    if row == prev then break end
    assert(row > prev, "hunk motion must move forward")
    visited[#visited + 1] = row
    prev = row
    if row >= c_start then break end
  end

  -- Exactly one of those stops is inside section 2, and it is its placeholder row.
  local in_b = {}
  for _, row in ipairs(visited) do
    if row >= b_start and row < b_end then in_b[#in_b + 1] = row end
  end
  H.eq(in_b, { b_start },
    "the folded section contributes one stop, its placeholder -- not zero, not many")
  assert(visited[#visited] >= c_start, "and ]h carries on into section 3 afterwards")
end

T["motions_ ]h inside the last hunk's body does not reverse direction"] = function()
  local st = canvas.open(three_sections(), {})
  local last_row, seg_end = last_hunk_row_and_section_end(st)
  local body_row0 = math.min(last_row + 2, seg_end - 1)
  vim.api.nvim_win_set_cursor(st.win, { body_row0 + 1, 0 })

  local before = vim.api.nvim_win_get_cursor(st.win)
  motions.goto_hunk(st, 1, 1)
  H.eq(vim.api.nvim_win_get_cursor(st.win), before,
    "]h past the last hunk header must not move the cursor backward")
end

T["motions_ [h before the first hunk header does not reverse direction"] = function()
  local st = canvas.open(three_sections(), {})
  local a_start = (canvas.section_rows(st, 1))
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 }) -- file_hdr row, before any hunk header

  local before = vim.api.nvim_win_get_cursor(st.win)
  motions.goto_hunk(st, -1, 1)
  H.eq(vim.api.nvim_win_get_cursor(st.win), before,
    "[h before the first hunk header must not move the cursor forward")
end

T["motions_ count is honored"] = function()
  local st = canvas.open(three_sections(), {})
  local a_start = (canvas.section_rows(st, 1))
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 })

  motions.goto_file(st, 1, 2) -- explicit count param, skip section 2 -> land on 3
  local c_start = (canvas.section_rows(st, 3))
  H.eq(vim.api.nvim_win_get_cursor(st.win), { c_start + 1, 0 })
end

T["motions_ [h steps back to the previous hunk header"] = function()
  local st = canvas.open(three_sections(), {})
  local a_start = (canvas.section_rows(st, 1))
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 }) -- file_hdr row

  motions.goto_hunk(st, 1, 1)
  local first_header = vim.api.nvim_win_get_cursor(st.win)
  motions.goto_hunk(st, 1, 1)
  local second_header = vim.api.nvim_win_get_cursor(st.win)
  assert(second_header[1] > first_header[1], "sanity: forward step actually advanced")

  motions.goto_hunk(st, -1, 1)
  H.eq(vim.api.nvim_win_get_cursor(st.win), first_header, "[h steps back to the previous header")
end

T["motions_ 2]h skips one hunk header ahead"] = function()
  local st = canvas.open(three_sections(), {})
  local a_start = (canvas.section_rows(st, 1))
  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 }) -- file_hdr row

  motions.goto_hunk(st, 1, 1)
  local one_step = vim.api.nvim_win_get_cursor(st.win)

  vim.api.nvim_win_set_cursor(st.win, { a_start + 1, 0 }) -- reset
  motions.goto_hunk(st, 1, 2)
  local two_step = vim.api.nvim_win_get_cursor(st.win)

  assert(two_step[1] > one_step[1], "2]h must land further than a single ]h step")
end

local STATUSCOL_EXPR = "%!v:lua.require'canvasdiff.statuscol'.text()"

local function with_fake_statuscolumn(callback)
  statuscol.detach()
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
  local cleanup_ok, cleanup_err = pcall(statuscol.detach)
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
      local leave_a = fake_autocmd(runtime, "BufWinLeave", 1)
      local closed_a = fake_autocmd(runtime, "WinClosed", 1)
      local win_leave_a = fake_autocmd(runtime, "WinLeave", 1)
      local split_pre_a = fake_autocmd(runtime, "WinNewPre", 1)
      local tab_leave_a = fake_autocmd(runtime, "TabLeave", 1)
      local win_enter_a = fake_autocmd(runtime, "WinEnter", 1)
      local win_new_a = fake_autocmd(runtime, "WinNew", 1)
      vim.api.nvim_set_current_win(primary)
      leave_a()
      H.eq(#runtime.scheduled, 1, "A captured one deferred leave")

      local lease_b = statuscol.attach(st, {
        alive = function() return true end,
        windows = function() return views end,
      })
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
      H.eq(statuscol.detach(lease_a), false, "stale detach(A) cannot stop B")
      assert(runtime.groups[group_b], "B's reused group survives stale detach(A)")

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
      runtime.scheduled[1]()
      H.eq(runtime.options[primary], STATUSCOL_EXPR,
        "A's stale deferred leave cannot restore over B")

      -- This split inherited the expression without BufWinEnter and is omitted
      -- from Surface views by the time its leave runs. Adopt it before defer.
      vim.api.nvim_set_current_win(inherited)
      local leave_b = fake_autocmd(runtime, "BufWinLeave", 2)
      leave_b()
      vim.api.nvim_win_set_buf(inherited, foreign)
      H.eq(#runtime.scheduled, 2)
      runtime.scheduled[2]()
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
  statuscol.detach()
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
  statuscol.detach()
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
  statuscol.detach()
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
  statuscol.detach()
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

      vim.api.nvim_set_current_win(raw)
      fake_autocmd(runtime, "WinEnter", 1)()
      H.eq(lease.last_canvas, nil, "excluded raw source has no provenance")

      child = vim.api.nvim_open_win(st.buf, true, { split = "below" })
      runtime.options[child] = "RAW"
      fake_autocmd(runtime, "WinNew", 1)()
      H.eq(#runtime.scheduled, 1, "source-less WinNew queued reconciliation")
      local queued = runtime.scheduled[1]

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

T["statuscol_ cross-state replacement repairs a late claim write"] = function()
  statuscol.detach()
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
      if name == "statuscolumn" and spec and spec.win == target then
        if step == 0 and value == STATUSCOL_EXPR then
          step = 1
          lease_b = statuscol.attach({
            buf = replacement_buf,
            win = replacement_win,
          }, {
            windows = function() return { replacement_win } end,
          })
          step = 2
        elseif step == 2 and value == "OLD" then
          step = 3
          lease_c = statuscol.attach(st, {
            windows = function() return { source, target } end,
          })
        end
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
    H.eq(lease_a.disposed, true)
    H.eq(lease_b.disposed, true)
    H.eq(lease_a.state, nil)
    H.eq(lease_b.state, nil)
    H.eq(next(lease_a.touched), nil)
    H.eq(next(lease_b.touched), nil)
    H.eq(lease_c.priors[target], "OLD",
      "C's target record receives the transferred exact prior")
    H.eq(lease_c.initial_prior, "SOURCE",
      "rebasing the target does not corrupt C's independent fallback")
    H.eq(lease_c.last_canvas.prior, "OLD",
      "C's focused provenance follows its rebased target record")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = target, scope = "local" }), STATUSCOL_EXPR,
      "C retains ownership after A's orphan repair")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = replacement_win, scope = "local" }), "NEW",
      "C's attach cleanly retired the different-Canvas B")

    H.eq(statuscol.detach(lease_b), false)
    H.eq(statuscol.detach(lease_c), true)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = target, scope = "local" }), "OLD",
      "C inherited A's exact prior instead of an expression fallback")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = source, scope = "local" }), "SOURCE")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = replacement_win, scope = "local" }), "NEW")
  end, debug.traceback)

  vim.api.nvim_set_option_value = real_set
  pcall(statuscol.detach)
  for _, win in ipairs({ target, replacement_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  pcall(vim.api.nvim_buf_delete, replacement_buf, { force = true })
  assert(verify_ok, verify_err)
end

T["statuscol_ creation transaction follows reentrant replacements"] = function()
  statuscol.detach()
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
    H.eq(lease_a.disposed, true)
    H.eq(lease_b.disposed, true)
    H.eq(lease_a.state, nil)
    H.eq(lease_b.state, nil)
    H.eq(next(lease_a.leaving), nil)
    H.eq(next(lease_b.leaving), nil)

    H.eq(vim.wait(300, function()
      return lease_c.touched[child] == nil
        and lease_c.touched[second_child] == nil
    end), true, "winning C observes both synchronous foreign final buffers")
    H.eq(statuscol.detach(lease_c), true)
    vim.api.nvim_win_set_buf(child, st.buf)
    vim.api.nvim_win_set_buf(second_child, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "source prior",
      "A-to-B-to-C transfer cannot strand a transient expression")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = second_child, scope = "local" }), "source prior",
      "the replacement keeps the real source for an immediate second child")
  end, debug.traceback)

  vim.api.nvim_set_option_value = real_set
  pcall(statuscol.detach)
  for _, win in ipairs({ second_child, child }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(verify_ok, verify_err)
end

T["statuscol_ leave transaction follows reentrant replacement"] = function()
  statuscol.detach()
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
    H.eq(lease_a.disposed, true)
    H.eq(next(lease_a.leaving), nil)
    H.eq(vim.wait(300, function()
      return lease_b.touched[departed] == nil
        and lease_b.touched[child] == nil
    end), true, "winning B observes the leave and immediate foreign child")

    H.eq(statuscol.detach(lease_b), true)
    vim.api.nvim_win_set_buf(departed, st.buf)
    vim.api.nvim_win_set_buf(child, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = departed, scope = "local" }), "departed prior",
      "reentrant BufLeave transfer restores the hidden Canvas slot")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = source, scope = "local" }), "source prior")
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "source prior",
      "replacement keeps the real source across a nonfocused leave")
  end, debug.traceback)

  vim.api.nvim_set_option_value = real_set
  pcall(statuscol.detach)
  if child and vim.api.nvim_win_is_valid(child) then
    pcall(vim.api.nvim_win_close, child, true)
  end
  if source ~= departed and vim.api.nvim_win_is_valid(source) then
    pcall(vim.api.nvim_win_close, source, true)
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(verify_ok, verify_err)
end

T["statuscol_ creation preflight transfers to its reentrant winner"] = function()
  statuscol.detach()
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
    H.eq(lease_a.disposed, true)
    H.eq(lease_a.state, nil)
    H.eq(next(lease_a.leaving), nil)
    H.eq(vim.wait(300, function()
      return lease_b.touched[child] == nil
    end), true, "winning preflight lease observes the foreign final buffer")

    H.eq(statuscol.detach(lease_b), true)
    vim.api.nvim_win_set_buf(child, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = child, scope = "local" }), "source prior",
      "alive replacement cannot strand the transient Canvas expression")
  end, debug.traceback)

  pcall(statuscol.detach)
  if child and vim.api.nvim_win_is_valid(child) then
    pcall(vim.api.nvim_win_close, child, true)
  end
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(ok, err)
end

T["statuscol_ leave preflight transfers to its reentrant winner"] = function()
  statuscol.detach()
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
    H.eq(lease_a.disposed, true)
    H.eq(lease_a.state, nil)
    H.eq(next(lease_a.leaving), nil)
    H.eq(vim.wait(300, function()
      return lease_b.touched[win] == nil
    end), true, "winning preflight lease observes the completed buffer leave")

    H.eq(statuscol.detach(lease_b), true)
    vim.api.nvim_win_set_buf(win, st.buf)
    H.eq(vim.api.nvim_get_option_value(
      "statuscolumn", { win = win, scope = "local" }), "canvas prior",
      "alive replacement cannot strand the departed Canvas slot")
  end, debug.traceback)

  pcall(statuscol.detach)
  pcall(vim.api.nvim_buf_delete, foreign, { force = true })
  assert(ok, err)
end

T["statuscol_ suspended child is exact provenance for nested creation"] = function()
  statuscol.detach()
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
  statuscol.detach()
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
  statuscol.detach()
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
  statuscol.detach()
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
  statuscol.detach()
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

    local lease_a2 = statuscol.attach(st, callbacks)
    local lease_b2
    runtime.on_set = function(_, value)
      if value == "prior" then
        lease_b2 = statuscol.attach(st, callbacks)
      end
    end
    local ok, err = pcall(statuscol.attach, st, callbacks)
    H.eq(ok, false, "outer attach aborts when teardown installs a winner")
    assert(tostring(err):find("superseded", 1, true), tostring(err))
    assert(lease_b2, "the teardown winner was installed")
    H.eq(statuscol.detach(lease_a2), false)
    H.eq(runtime.options[win], STATUSCOL_EXPR,
      "aborted outer attach did not orphan or overwrite B")
    H.eq(statuscol.detach(lease_b2), true)
    H.eq(runtime.options[win], "prior")
  end)
end

T["statuscol_ callback errors are observable except from text"] = function()
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
  H.eq(statuscol.detach(), false, "failed attach leaves no current lease")
end

T["statuscol_ text maps rows to new-file numbers"] = function()
  local st = canvas.open(three_sections(), {})
  vim.api.nvim_set_current_win(st.win)
  local lease = statuscol.attach(st, {
    windows = function() return { st.win } end,
  })

  -- Production sets g:statusline_winid to the window being drawn before
  -- evaluating the `%!` statuscolumn expression; simulate that eval context.
  vim.g.statusline_winid = st.win

  -- file_hdr row (section start) -> 5 spaces.
  local a_start = (canvas.section_rows(st, 1))
  H.eq(statuscol.render(lease, st.win, a_start + 1), "     ")

  -- Find a ctx/add row and check it maps to its new_lnum.
  local _, offset = canvas.locate(st, a_start + 2) -- hunk_hdr is offset 2; entries after that
  local entry
  local row0 = a_start + 2
  while true do
    local i, off = canvas.locate(st, row0)
    entry = st.sections[i].entries[off]
    if entry.kind ~= "hunk_hdr" and entry.kind ~= "file_hdr" then
      break
    end
    row0 = row0 + 1
  end
  H.eq(entry.new_lnum ~= nil, true, "found a row with a new_lnum")
  H.eq(statuscol.render(lease, st.win, row0 + 1), ("%4d "):format(entry.new_lnum))

  vim.g.statusline_winid = nil
  statuscol.detach(lease)
end

T["statuscol_ renders for the drawn window even while focus is elsewhere"] = function()
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
    if entry.kind ~= "hunk_hdr" and entry.kind ~= "file_hdr" then
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

  H.eq(text, ("%4d "):format(entry.new_lnum),
    "statuscolumn for the canvas window's own row renders even while focus is in another window")

  vim.api.nvim_win_close(other_win, true)
  statuscol.detach(lease)
end

T["statuscol_ never leaks into a foreign buffer"] = function()
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
    "%!v:lua.require'canvasdiff.statuscol'.text()",
    "statuscolumn restored once the canvas is showing again")

  statuscol.detach(lease)
  pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
end

return T
