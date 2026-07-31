-- Two reviews open at once, through the production path only.
--
-- Every earlier concurrency test had to hand-build its second review, because
-- `canvas.open` resolved one process-wide buffer and App held one `surface`
-- scalar. This file uses nothing but `require("canvasdiff")`, which is the
-- point: if two reviews are not reachable the way a user reaches them, they
-- are not really supported.

local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local session = require("canvasdiff.session")

local T = {}

local function groups_with_prefix(prefix)
  local out, seen = {}, {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    local name = autocmd.group_name
    if name and not seen[name]
        and (name == prefix or name:sub(1, #prefix + 1) == prefix .. ".") then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local RESOURCE_PREFIXES = {
  "canvasdiff.watch",
  "canvasdiff.virt",
  "canvasdiff.highlight",
  "canvasdiff.status_column",
  "canvasdiff.sidebar",
  "canvasdiff.scrollbar",
  "canvasdiff.session",
  "canvasdiff.close",
  "canvasdiff.winbar",
}

local function total_groups()
  local n = 0
  for _, prefix in ipairs(RESOURCE_PREFIXES) do
    n = n + #groups_with_prefix(prefix)
  end
  return n
end

--- Which of `bufs` still exist. Deliberately scoped to this test's own
--- buffers: unit files elsewhere in the suite open canvases directly and never
--- close them, so a process-wide count would measure them instead.
local function surviving(bufs)
  local out = {}
  for _, buf in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      out[#out + 1] = buf
    end
  end
  return out
end

local function fixture(tag)
  return H.git_fixture({
    committed = { [tag .. ".txt"] = "one\ntwo\nthree\n" },
    worktree = { [tag .. ".txt"] = tag:upper() .. "\ntwo\nthree\n" },
  })
end

--- Open two reviews of two different repositories, each in its own window.
---
--- `lcd` rather than a global chdir, because App resolves the repository from
--- the window's own working directory -- which is exactly how a user ends up
--- with two projects side by side.
local function with_two_reviews(body)
  local previous_cwd = vim.fn.getcwd()
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local root_a, root_b = fixture("alpha"), fixture("beta")

  local fm = require("canvasdiff")
  fm.setup({})

  local win_a = vim.api.nvim_get_current_win()
  vim.cmd("lcd " .. vim.fn.fnameescape(root_a))
  local state_a = assert(fm.open())

  -- `:new`, not `:split`: a split of A's canvas window is another view of A,
  -- and opening there correctly REPLACES A rather than starting a peer. A
  -- second review begins in a window that belongs to no review, which is how a
  -- user reaches one.
  vim.cmd("new")
  local win_b = vim.api.nvim_get_current_win()
  vim.cmd("lcd " .. vim.fn.fnameescape(root_b))
  local state_b = assert(fm.open())

  local ok, err = xpcall(function()
    body({
      fm = fm,
      a = { root = root_a, state = state_a, win = win_a, surface = state_a.surface },
      b = { root = root_b, state = state_b, win = win_b, surface = state_b.surface },
    })
  end, debug.traceback)

  fm.setup({ keymaps = { global = { compare = false, checkout = false } } })
  for _, surface in ipairs({ state_b.surface, state_a.surface }) do
    if surface then
      pcall(surface.dispose, surface, "test cleanup")
    end
  end
  if vim.api.nvim_tabpage_is_valid(tab) then
    pcall(vim.api.nvim_set_current_tabpage, tab)
    pcall(vim.cmd, "tabclose!")
  end
  for _, root in ipairs({ root_a, root_b }) do
    os.remove(session.path_for(root))
    vim.fn.delete(root, "rf")
  end
  vim.api.nvim_set_current_dir(
    vim.fn.isdirectory(previous_cwd) == 1 and previous_cwd or H.project_root)
  assert(ok, err)
end

T["concurrent_ two reviews own distinct buffers, Surfaces and controllers"] = function()
  with_two_reviews(function(ctx)
    assert(ctx.a.surface and ctx.b.surface, "both reviews produced a Surface")
    assert(not rawequal(ctx.a.surface, ctx.b.surface),
      "opening the second review did not replace the first")
    assert(ctx.a.surface:is_alive() and ctx.b.surface:is_alive())

    assert(ctx.a.state.buf ~= ctx.b.state.buf, "each review owns its own buffer")
    assert(canvas.is_canvas_buf(ctx.a.state.buf))
    assert(canvas.is_canvas_buf(ctx.b.state.buf))
    assert(vim.api.nvim_buf_get_name(ctx.a.state.buf)
      ~= vim.api.nvim_buf_get_name(ctx.b.state.buf),
      "and a name that distinguishes it in :ls")

    H.eq(ctx.a.state.root, ctx.a.root, "each review resolved its own repository")
    H.eq(ctx.b.state.root, ctx.b.root)

    for kind, lease_a in pairs(ctx.a.surface.controllers) do
      local lease_b = ctx.b.surface.controllers[kind]
      assert(lease_b, "both reviews acquired a " .. kind .. " lease")
      assert(not rawequal(lease_a, lease_b),
        kind .. " leases must be independent objects")
    end

    -- Including the groups the Surface installs itself, which were fixed names
    -- until reviews could coexist.
    for _, kind in ipairs({ "session", "close", "winbar" }) do
      assert(ctx.a.surface.groups[kind] ~= ctx.b.surface.groups[kind],
        kind .. " group names must not collide")
    end
    for _, prefix in ipairs({ "canvasdiff.close", "canvasdiff.winbar" }) do
      H.eq(#groups_with_prefix(prefix), 2,
        "both reviews arm their own " .. prefix .. " group")
    end
  end)
end

T["concurrent_ mutating one review leaves the other untouched"] = function()
  with_two_reviews(function(ctx)
    local before_b = vim.api.nvim_buf_get_lines(ctx.b.state.buf, 0, -1, false)
    local view_b = vim.api.nvim_win_call(ctx.b.win, vim.fn.winsaveview)

    vim.api.nvim_set_current_win(ctx.a.win)
    canvas.set_collapsed(ctx.a.state, 1, true)

    H.eq(ctx.a.state.collapsed["alpha.txt"] ~= nil, true, "A collapsed its file")
    H.eq(next(ctx.b.state.collapsed), nil, "B's collapse state is its own")
    H.eq(vim.api.nvim_buf_get_lines(ctx.b.state.buf, 0, -1, false), before_b,
      "A's splice never rewrote B's buffer")
    H.eq(vim.api.nvim_win_call(ctx.b.win, vim.fn.winsaveview), view_b,
      "nor moved B's viewport")

    -- A lens pivot rebuilds A's model wholesale; B must not notice.
    local lens = require("canvasdiff.diff").lens
    local b_lens = ctx.b.state.lens
    ctx.fm.set_lens(lens.get("all"))
    H.eq(ctx.b.state.lens, b_lens, "B keeps the lens it was opened with")
    H.eq(vim.api.nvim_buf_get_lines(ctx.b.state.buf, 0, -1, false), before_b,
      "and the text that goes with it")
  end)
end

T["concurrent_ stage and both watchers stay scoped to the focused review"] = function()
  with_two_reviews(function(ctx)
    local source = require("canvasdiff.source")
    local before_b = vim.deepcopy(ctx.b.state.sections)
    local b_lens = vim.deepcopy(ctx.b.state.lens)
    local b_watch = ctx.b.surface.controllers.watch
    local a_watch = ctx.a.surface.controllers.watch
    assert(a_watch and b_watch and not rawequal(a_watch, b_watch),
      "the production path has two independent watcher leases")

    vim.api.nvim_set_current_win(ctx.a.win)
    assert(ctx.fm.stage())
    local a_file = assert(source.changed_files(ctx.a.root)[1])
    local b_file = assert(source.changed_files(ctx.b.root)[1])
    assert(a_file.staged and not a_file.unstaged, vim.inspect(a_file))
    assert(b_file.unstaged and not b_file.staged, vim.inspect(b_file))
    H.eq(ctx.b.state.sections, before_b,
      "A's stage reconcile and watcher fanout never touch B's model")
    H.eq(ctx.b.state.lens, b_lens)
    assert(ctx.a.surface.controllers.watch == a_watch)
    assert(ctx.b.surface.controllers.watch == b_watch)
  end)
end

--- Close both reviews in the given order and prove the survivor is intact
--- between the two closes, and that nothing at all is left after the second.
local function assert_close_order(ctx, first, second)
  local closing, survivor = ctx[first], ctx[second]
  local owned_buffers = { ctx.a.state.buf, ctx.b.state.buf }
  local survivor_buf = survivor.state.buf
  local survivor_lines = vim.api.nvim_buf_get_lines(survivor_buf, 0, -1, false)
  local survivor_groups = {}
  for _, prefix in ipairs(RESOURCE_PREFIXES) do
    survivor_groups[prefix] = #groups_with_prefix(prefix)
  end

  vim.api.nvim_set_current_win(closing.win)
  ctx.fm.close()

  assert(not closing.surface:is_alive(), first .. " was disposed")
  assert(survivor.surface:is_alive(), second .. " survives its peer's close")
  H.eq(vim.api.nvim_buf_get_lines(survivor_buf, 0, -1, false), survivor_lines,
    "the survivor's buffer is untouched")
  for kind, lease in pairs(survivor.surface.controllers) do
    assert(lease, "the survivor kept its " .. kind .. " lease")
  end
  for _, prefix in ipairs(RESOURCE_PREFIXES) do
    local remaining = #groups_with_prefix(prefix)
    assert(remaining < survivor_groups[prefix] or survivor_groups[prefix] == 0,
      ("closing %s should have removed one %s group, %d remain of %d")
        :format(first, prefix, remaining, survivor_groups[prefix]))
    assert(remaining >= 1 or survivor_groups[prefix] < 2,
      ("closing %s removed the survivor's %s group too"):format(first, prefix))
  end
  assert(survivor.state.win and vim.api.nvim_win_is_valid(survivor.state.win)
    and vim.api.nvim_win_get_buf(survivor.state.win) == survivor_buf,
    "the survivor is still on screen in its own window")

  vim.api.nvim_set_current_win(survivor.state.win)
  ctx.fm.close()
  assert(not survivor.surface:is_alive(), second .. " was disposed in turn")

  -- Buffer reclamation is deferred past window restoration, so drain the loop.
  local drained = false
  vim.schedule(function() drained = true end)
  assert(vim.wait(500, function() return drained end, 10), "the loop drained")

  H.eq(total_groups(), 0, "closing both reviews leaves no armed group")
  H.eq(surviving(owned_buffers), {}, "and reclaims both canvas buffers")
end

T["concurrent_ closing the first review first leaves the second intact"] = function()
  with_two_reviews(function(ctx)
    assert_close_order(ctx, "a", "b")
  end)
end

T["concurrent_ closing the second review first leaves the first intact"] = function()
  with_two_reviews(function(ctx)
    assert_close_order(ctx, "b", "a")
  end)
end

T["concurrent_ each review persists its own session"] = function()
  with_two_reviews(function(ctx)
    vim.api.nvim_set_current_win(ctx.a.win)
    canvas.set_collapsed(ctx.a.state, 1, true)
    ctx.a.surface:save()
    ctx.b.surface:save()

    local saved_a = session.load(ctx.a.root)
    local saved_b = session.load(ctx.b.root)
    assert(saved_a, "A wrote a session for its own repository")
    assert(saved_b, "so did B, under its own path")
    assert(session.path_for(ctx.a.root) ~= session.path_for(ctx.b.root),
      "two repositories never share a session file")
    H.eq(saved_a.collapsed, { "alpha.txt" }, "A saved exactly its own collapse")
    H.eq(saved_b.collapsed or {}, {}, "B saved none, because it has none")
  end)
end

T["concurrent_ a command acts on the review whose window you are in"] = function()
  with_two_reviews(function(ctx)
    local lens = require("canvasdiff.diff").lens
    local a_lens, b_lens = ctx.a.state.lens, ctx.b.state.lens

    vim.api.nvim_set_current_win(ctx.b.win)
    ctx.fm.set_lens(lens.get("all"))
    H.eq(ctx.a.state.lens, a_lens, "the review you are NOT in is not the target")
    assert(ctx.b.state.lens ~= b_lens or b_lens.id == "all",
      "the review you are in is")

    -- And from a window belonging to neither, the most recent review answers,
    -- rather than the command silently doing nothing.
    vim.cmd("split")
    vim.cmd("enew")
    local outside = vim.api.nvim_get_current_win()
    H.eq(ctx.fm.jump_back(), false,
      "an unrelated window still reaches a review, which declines cleanly")
    if vim.api.nvim_win_is_valid(outside)
        and #vim.api.nvim_tabpage_list_wins(0) > 1 then
      vim.api.nvim_win_close(outside, true)
    end
  end)
end

T["concurrent_ delayed checkout stays bound to its originating repository"] =
function()
  with_two_reviews(function(ctx)
    for _, review in ipairs({ ctx.a, ctx.b }) do
      local made = vim.system(
        { "git", "branch", "topic" }, { cwd = review.root, text = true }):wait()
      assert(made.code == 0, made.stderr)
    end

    local real_select = vim.ui.select
    local call
    vim.ui.select = function(items, opts, callback)
      call = { items = items, opts = opts, callback = callback }
    end
    vim.api.nvim_set_current_win(ctx.a.win)
    local invoked, invoke_err = pcall(ctx.fm.checkout)
    if not invoked then
      vim.ui.select = real_select
      error(invoke_err)
    end
    assert(call, "checkout opened its picker")

    vim.api.nvim_set_current_win(ctx.b.win)
    local topic
    for _, item in ipairs(call.items) do
      if item.name == "topic" then topic = item end
    end
    assert(topic, "repository A's exact topic ref is selectable")
    call.callback(topic)
    vim.ui.select = real_select

    local function branch(root)
      local result = vim.system(
        { "git", "branch", "--show-current" }, { cwd = root, text = true }):wait()
      assert(result.code == 0, result.stderr)
      return vim.trim(result.stdout)
    end
    H.eq(branch(ctx.a.root), "topic",
      "the delayed choice mutates only its captured repository")
    H.eq(branch(ctx.b.root), "main",
      "current focus cannot redirect the choice into another review")
    assert(ctx.b.surface:is_alive(), "the peer review remains live")
  end)
end

return T
