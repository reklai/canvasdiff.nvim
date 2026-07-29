local H = require("helpers")
local canvas = require("canvasdiff.canvas")

local T = {}

--- Run `fn` in a throwaway tab with `cwd` as the working directory, capturing
--- notifications. Restores cwd, closes the tab, and drops the cached root
--- facade so the next test gets a fresh default App.
local function in_cwd(cwd, fn)
  local old_cwd = vim.fn.getcwd()
  local real = vim.notify
  local msgs = {}
  vim.notify = function(msg, level) msgs[#msgs + 1] = { msg = msg, level = level } end

  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(cwd)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")

  local ok, err = pcall(fn, fm, msgs)

  pcall(fm.close)
  vim.notify = real
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  assert(ok, err)
end

local function shown_files()
  local out = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local p = l:match("^▎ (%S+)")
    if p then out[#out + 1] = p end
  end
  return out
end

-- The root module is the entire supported Lua surface. Pin it before the
-- App/Surface extraction so moving ownership cannot accidentally expose an
-- implementation method or drop one of the command-facing compatibility
-- methods. Ordinary repeated require() calls must also resolve to the one
-- cached facade; manually evicting package.loaded is not a lifecycle API.
T["root_ facade is cached and exports exactly the supported API"] = function()
  local first = require("canvasdiff")
  local second = require("canvasdiff")
  assert(rawequal(first, second), "ordinary require() calls share one facade")
  H.eq(getmetatable(first), nil, "the public facade is a plain table")

  local names = vim.tbl_keys(first)
  table.sort(names)
  H.eq(names, {
    "close",
    "command",
    "command_complete",
    "compare",
    "cycle_lens",
    "jump_back",
    "open",
    "refresh",
    "set_base",
    "set_branch",
    "set_lens",
    "set_range",
    "setup",
    "toggle",
    "toggle_base",
  })
  for _, name in ipairs(names) do
    H.eq(type(first[name]), "function", name .. " is callable")
  end
end

local function git(root, args)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  return vim.trim(res.stdout or "")
end

local function picker_fixture()
  local root = H.git_fixture({ committed = { ["a.txt"] = "base\n" } })
  git(root, { "branch", "master" })
  git(root, { "branch", "zeta" })
  git(root, { "update-ref", "refs/remotes/origin/topic", "HEAD" })
  git(root, { "symbolic-ref", "refs/remotes/origin/HEAD",
    "refs/remotes/origin/topic" })
  git(root, { "update-ref", "refs/remotes/upstream/topic", "HEAD" })
  git(root, { "symbolic-ref", "refs/remotes/upstream/HEAD",
    "refs/remotes/upstream/topic" })
  git(root, { "switch", "zeta" })
  return root
end

local function names(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = item.name
  end
  return out
end

local function item_named(items, name)
  for _, item in ipairs(items) do
    if item.name == name then
      return item
    end
  end
  error("missing picker item " .. name .. " in " .. vim.inspect(names(items)))
end

T["root_ compare picker orders metadata choices and cancels silently"] = function()
  local root = picker_fixture()
  in_cwd(root, function(fm, msgs)
    H.eq(fm.command_complete("origin/"), { "origin/HEAD", "origin/topic" },
      "completion inspects the command window's repository")
    H.eq(fm.command_complete("main...up"), {
      "main...upstream/HEAD", "main...upstream/topic",
    }, "range completion preserves the typed left side and operator")
    local before = vim.api.nvim_get_current_buf()
    local real_select = vim.ui.select
    local calls = {}
    vim.ui.select = function(items, opts, callback)
      calls[#calls + 1] = { items = items, opts = opts }
      if #calls == 1 then
        callback(items[1], 1)
      else
        callback(nil, nil)
      end
    end
    local ok, err = xpcall(function()
      fm.compare()
    end, debug.traceback)
    vim.ui.select = real_select
    assert(ok, err)

    H.eq(#calls, 2, "choosing a base opens exactly one comparison prompt")
    H.eq(names(calls[1].items), {
      "origin/HEAD", "upstream/HEAD", "main", "master",
      "origin/topic", "upstream/topic", "zeta",
    }, "base choices prefer remote defaults and conventional local bases")
    H.eq(names(calls[2].items), {
      "zeta", "main", "master", "origin/topic", "upstream/topic",
    }, "comparison choices put the current branch first and exclude remote HEAD")
    H.eq(calls[1].items[1].ref, "refs/remotes/origin/HEAD",
      "picker execution identity is the unambiguous full ref")
    assert(calls[1].opts.format_item(calls[1].items[1]):find(
      "remote default", 1, true), "the symbolic default is labeled")
    assert(calls[2].opts.format_item(calls[2].items[1]):find(
      "current", 1, true), "the current branch is labeled")
    H.eq(vim.api.nvim_get_current_buf(), before,
      "cancelling the second prompt changes no window")
    H.eq(#msgs, 0, "cancellation is silent")

    calls = {}
    vim.ui.select = function(items, opts, callback)
      calls[#calls + 1] = { items = items, opts = opts }
      callback(nil, nil)
    end
    fm.compare()
    H.eq(#calls, 1, "cancelling the base prompt cannot open the second prompt")
    H.eq(vim.api.nvim_get_current_buf(), before)
    H.eq(#msgs, 0, "first-prompt cancellation is silent too")
    vim.ui.select = real_select
  end)
  vim.fn.delete(root, "rf")
end

T["root_ base priority uses full refs when a tag collides with main"] = function()
  local root = picker_fixture()
  git(root, { "tag", "main" })
  in_cwd(root, function(fm)
    local real_select = vim.ui.select
    local calls = {}
    vim.ui.select = function(items, opts, callback)
      calls[#calls + 1] = { items = items, opts = opts, callback = callback }
    end
    local ok, err = xpcall(function() fm.compare() end, debug.traceback)
    vim.ui.select = real_select
    assert(ok, err)
    H.eq(names(calls[1].items), {
      "origin/HEAD", "upstream/HEAD", "heads/main", "master",
      "origin/topic", "upstream/topic", "zeta",
    }, "local main stays ahead of master even when its safe display name changes")
    H.eq(calls[1].items[3].ref, "refs/heads/main")
  end)
  vim.fn.delete(root, "rf")
end

T["root_ detached compare picker synthesizes HEAD as the current choice"] = function()
  local root = picker_fixture()
  git(root, { "switch", "--detach" })
  in_cwd(root, function(fm)
    local real_select = vim.ui.select
    local calls = {}
    vim.ui.select = function(items, opts, callback)
      calls[#calls + 1] = { items = items, opts = opts }
      if #calls == 1 then
        callback(item_named(items, "main"))
      else
        callback(nil, nil)
      end
    end
    local ok, err = xpcall(function() fm.compare() end, debug.traceback)
    vim.ui.select = real_select
    assert(ok, err)
    H.eq(calls[2].items[1], {
      ref = "HEAD", name = "HEAD", kind = "detached", current = true,
    }, "detached HEAD remains selectable even though it has no local branch ref")
  end)
  vim.fn.delete(root, "rf")
end

local function two_surface_app(root)
  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local st_a = assert(app:open())
  local win_a = vim.api.nvim_get_current_win()
  vim.cmd("tabnew")
  local win_b = vim.api.nvim_get_current_win()
  local st_b = assert(app:open())
  return app, st_a, win_a, st_b, win_b, old_cwd
end

local function cleanup_two_surface_app(app, win_a, win_b, old_cwd)
  for _, win in ipairs({ win_b, win_a }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      pcall(function() app:close() end)
    end
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
  end
  vim.api.nvim_set_current_dir(old_cwd)
end

T["root_ delayed picker callbacks retain their exact originating Surface"] = function()
  local root = picker_fixture()
  local app, st_a, win_a, st_b, win_b, old_cwd = two_surface_app(root)
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    vim.api.nvim_set_current_win(win_a)
    app:compare()
    H.eq(#calls, 1)

    vim.api.nvim_set_current_win(win_b)
    calls[1].callback(item_named(calls[1].items, "main"))
    H.eq(#calls, 2)
    calls[2].callback(item_named(calls[2].items, "zeta"))

    H.eq(require("canvasdiff.diff").lens.of(st_a),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."),
      "the delayed choice must pivot the Surface that opened the picker")
    H.eq(require("canvasdiff.diff").lens.of(st_b).id, "all",
      "the currently focused Surface must remain untouched")
  end, debug.traceback)

  vim.ui.select = real_select
  cleanup_two_surface_app(app, win_a, win_b, old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ an unowned picker window cannot redirect into another Surface"] = function()
  local root = picker_fixture()
  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local existing = assert(app:open())
  local existing_win = vim.api.nvim_get_current_win()
  vim.cmd("tabnew")
  local origin_win = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_get_current_buf()
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    calls[2].callback(item_named(calls[2].items, "zeta"))

    H.eq(require("canvasdiff.diff").lens.of(existing).id, "all",
      "the unrelated live review cannot answer for an unowned origin window")
    assert(vim.api.nvim_win_get_buf(origin_win) ~= origin_buf,
      "a successful picker opens its committed review in the origin window")
    local opened = assert(app.opened[#app.opened])
    H.eq(opened.state.root, root)
    H.eq(require("canvasdiff.diff").lens.of(opened.state),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."))
  end, debug.traceback)

  vim.ui.select = real_select
  for _, win in ipairs({ origin_win, existing_win }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      pcall(function() app:close() end)
    end
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ delayed unowned picker keeps its captured repository across cwd drift"] =
function()
  local root = picker_fixture()
  local other = H.git_fixture({
    committed = { ["other.txt"] = "other\n" },
    worktree = { ["other.txt"] = "dirty\n" },
  })
  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local win = vim.api.nvim_get_current_win()
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    vim.api.nvim_set_current_dir(other)
    calls[2].callback(item_named(calls[2].items, "zeta"))
    local opened = assert(app.opened[#app.opened])
    H.eq(opened.state.root, root,
      "async completion uses the repository captured when the picker opened")
    H.eq(require("canvasdiff.diff").lens.of(opened.state),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."))
  end, debug.traceback)

  vim.ui.select = real_select
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  vim.fn.delete(other, "rf")
  assert(ok, err)
end

T["root_ picker from a jump excursion reopens the exact Surface window"] =
function()
  local root = picker_fixture()
  local file = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  file:write("dirty worktree\n")
  file:close()
  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local st = assert(app:open())
  local surface = assert(app.opened[#app.opened])
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local entered = require("canvasdiff.input").jump.enter(
    surface.excursion, st, { win = win })
  assert(entered.ok, vim.inspect(entered))
  assert(not surface:is_showing(), "the single canvas window is in its file excursion")

  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end
  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    calls[2].callback(item_named(calls[2].items, "zeta"))

    assert(require("canvasdiff.canvas").is_canvas_buf(
      vim.api.nvim_win_get_buf(win)),
      "a successful picker must visibly return the excursion window to a canvas")
    local replacement = assert(app.opened[#app.opened])
    H.eq(replacement.state.root, root)
    H.eq(require("canvasdiff.diff").lens.of(replacement.state),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."))
  end, debug.traceback)

  vim.ui.select = real_select
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ a newer compare request invalidates every older callback"] = function()
  local root = picker_fixture()
  local app, st_a, win_a, st_b, win_b, old_cwd = two_surface_app(root)
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    vim.api.nvim_set_current_win(win_a)
    app:compare()
    vim.api.nvim_set_current_win(win_b)
    app:compare()
    H.eq(#calls, 2, "both first prompts were issued")

    calls[1].callback(item_named(calls[1].items, "main"))
    H.eq(#calls, 2, "the stale first callback cannot open another prompt")

    calls[2].callback(item_named(calls[2].items, "main"))
    H.eq(#calls, 3)
    calls[3].callback(item_named(calls[3].items, "zeta"))
    H.eq(require("canvasdiff.diff").lens.of(st_a).id, "all")
    H.eq(require("canvasdiff.diff").lens.of(st_b),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."))
  end, debug.traceback)

  vim.ui.select = real_select
  cleanup_two_surface_app(app, win_a, win_b, old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ compare invalidates its predecessor before repository inspection"] = function()
  local root = picker_fixture()
  local app, st_a, win_a, st_b, win_b, old_cwd = two_surface_app(root)
  local source = require("canvasdiff.source")
  local real_branches = source.branches
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    vim.api.nvim_set_current_win(win_a)
    app:compare()
    H.eq(#calls, 1)

    source.branches = function(repo)
      calls[1].callback(item_named(calls[1].items, "main"))
      return real_branches(repo)
    end
    vim.api.nvim_set_current_win(win_b)
    app:compare()
    H.eq(#calls, 2,
      "the old callback reentered during inspection but could not open a prompt")
    H.eq(require("canvasdiff.diff").lens.of(st_a).id, "all")
    H.eq(require("canvasdiff.diff").lens.of(st_b).id, "all")
  end, debug.traceback)

  source.branches = real_branches
  vim.ui.select = real_select
  cleanup_two_surface_app(app, win_a, win_b, old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ owned picker rechecks newest request after range collection"] = function()
  local root = picker_fixture()
  local app, st_a, win_a, st_b, win_b, old_cwd = two_surface_app(root)
  local source = require("canvasdiff.source")
  local real_sections = source.sections
  local real_select = vim.ui.select
  local real_notify = vim.notify
  local messages = {}
  local calls = {}
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    vim.api.nvim_set_current_win(win_a)
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    local reentered = false
    source.sections = function(...)
      if not reentered then
        reentered = true
        vim.api.nvim_set_current_win(win_b)
        app:compare()
      end
      return nil, "stale owned collection"
    end
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(#calls, 3, "collection reentry started the newer picker")
    H.eq(require("canvasdiff.diff").lens.of(st_a).id, "all",
      "the stale owned transaction cannot publish after collection")
    H.eq(require("canvasdiff.diff").lens.of(st_b).id, "all")
    H.eq(messages, {}, "a stale collection error is discarded silently")
  end, debug.traceback)

  source.sections = real_sections
  vim.ui.select = real_select
  vim.notify = real_notify
  cleanup_two_surface_app(app, win_a, win_b, old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ unowned picker rechecks newest request after open collection"] = function()
  local root = picker_fixture()
  local App = require("canvasdiff.App")
  local app = App.new()
  local source = require("canvasdiff.source")
  local real_sections = source.sections
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local win = vim.api.nvim_get_current_win()
  local before = vim.api.nvim_win_get_buf(win)
  local real_select = vim.ui.select
  local real_notify = vim.notify
  local messages = {}
  local calls = {}
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    local reentered = false
    source.sections = function(...)
      if not reentered then
        reentered = true
        app:compare()
      end
      return nil, "stale unowned collection"
    end
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(#calls, 3, "open collection reentry started the newer picker")
    H.eq(#app.opened, 0,
      "the stale unowned transaction cannot create a Surface after collection")
    H.eq(vim.api.nvim_win_get_buf(win), before,
      "the stale open changes no window")
    H.eq(messages, {}, "a stale open error is discarded silently")
  end, debug.traceback)

  source.sections = real_sections
  vim.ui.select = real_select
  vim.notify = real_notify
  if #app.opened > 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ reentrant select invalidates the picker it interrupted"] = function()
  local root = picker_fixture()
  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local st = assert(app:open())
  local win = vim.api.nvim_get_current_win()
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
    if #calls == 1 then
      callback(item_named(items, "main"))
    elseif #calls == 2 then
      -- A UI implementation is allowed to run arbitrary code before returning.
      -- Starting another picker here must invalidate both callbacks above.
      app:compare()
    end
  end

  local ok, err = xpcall(function()
    app:compare()
    H.eq(#calls, 3, "the reentrant request issued its own first prompt")
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(require("canvasdiff.diff").lens.of(st).id, "all",
      "the interrupted request cannot publish after re-entry")

    calls[3].callback(item_named(calls[3].items, "main"))
    H.eq(#calls, 4)
    calls[4].callback(item_named(calls[4].items, "zeta"))
    H.eq(require("canvasdiff.diff").lens.of(st),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."),
      "the newest request remains live")
  end, debug.traceback)

  vim.ui.select = real_select
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ loader has no init shim and App instances own separate Surfaces"] = function()
  local cached = require("canvasdiff")
  package.loaded["canvasdiff"] = nil
  local reloaded = require("canvasdiff")
  assert(not rawequal(cached, reloaded),
    "manual root eviction reloads a fresh facade and default App")

  package.loaded["canvasdiff.init"] = nil
  local loaded = pcall(require, "canvasdiff.init")
  assert(not loaded, "canvasdiff.init must not remain as a second root loader")

  local App = require("canvasdiff.App")
  local first = App.new()
  local second = App.new()
  assert(not rawequal(first, second), "each App.new() returns a distinct owner")

  -- A review is filed under its own canvas buffer, so a synthetic state gets
  -- a synthetic key. What matters is that the index is per App instance.
  local state = { buf = -1 }
  local surface = require("canvasdiff.Surface").new(state)
  first.surfaces[state.buf] = surface
  first.opened[#first.opened + 1] = surface
  H.eq(first.surfaces[state.buf], surface,
    "a review is indexed by its own canvas buffer on its owning App")
  H.eq(next(second.surfaces), nil, "one App's review cannot leak into another App")
  H.eq(state.surface, surface, "the canvas state names its exact Surface owner")
  H.eq(type(surface.id), "number")
  H.eq(type(surface.generation), "number")
  H.eq(surface.phase, "active")
  H.eq(surface.saved, false)
  H.eq(surface.disposed, false)
  H.eq(type(surface.callbacks), "table")
  assert(surface:is_alive(), "a new Surface is alive")
  assert(not surface:is_showing(), "a Surface without a canvas buffer is hidden")
  assert(surface:guard(surface.generation), "the current generation passes its guard")

  local ui = require("canvasdiff.ui")
  local real_warn = ui.warn
  local warnings = {}
  ui.warn = function(msg)
    warnings[#warnings + 1] = msg
  end

  local ok, err = xpcall(function()
    local refreshed, refresh_err = first:refresh()
    H.eq(refreshed, nil)
    H.eq(refresh_err, "no valid diff canvas",
      "a method reads the Surface stored on its receiver")

    local untouched, untouched_err = second:refresh()
    H.eq(untouched, nil)
    H.eq(untouched_err, nil, "the other receiver still has no state")
    H.eq(warnings, { "no valid diff canvas" },
      "only the App carrying state attempted a refresh")
  end, debug.traceback)

  ui.warn = real_warn
  assert(ok, err)
end

T["root_ setup presents config diagnostics as errors"] = function()
  local fm = require("canvasdiff")
  local real_notify = vim.notify
  local messages = {}
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end

  local ok, err = xpcall(function()
    fm.setup({ glyphs = 42 })
  end, debug.traceback)
  local reset_ok, reset_err = pcall(fm.setup, {})

  vim.notify = real_notify
  assert(ok, err)
  assert(reset_ok, reset_err)
  H.eq(#messages, 1, "one invalid option produces one user-facing diagnostic")
  H.eq(messages[1].level, vim.log.levels.ERROR)
  assert(messages[1].message:find("CanvasDiff: ", 1, true) == 1,
    "the UI owns the plugin prefix: " .. messages[1].message)
  assert(messages[1].message:find("glyphs must be", 1, true),
    "the validation message reaches the user: " .. messages[1].message)
end

T["root_ Surface never issues unqualified controller teardown"] = function()
  local runtime = require("canvasdiff.runtime")
  local watch = runtime.watch
  local hl = require("canvasdiff.ui").highlight
  local sidebar = require("canvasdiff.ui").sidebar
  local scrollbar = require("canvasdiff.ui").scrollbar
  local virt = runtime.virtualizer
  local statuscol = require("canvasdiff.ui").status_column
  local real_stop = watch.stop
  local real_hl_detach = hl.detach
  local real_sidebar_close = sidebar.close
  local real_scrollbar_close = scrollbar.close
  local real_detach = virt.detach
  local real_statuscol_detach = statuscol.detach
  local stops, hl_detaches, sidebar_closes, scrollbar_closes, detaches, statuscol_detaches =
    0, 0, 0, 0, 0, 0
  watch.stop = function(...)
    stops = stops + 1
    return real_stop(...)
  end
  hl.detach = function(...)
    hl_detaches = hl_detaches + 1
    return real_hl_detach(...)
  end
  sidebar.close = function(...)
    sidebar_closes = sidebar_closes + 1
    return real_sidebar_close(...)
  end
  scrollbar.close = function(...)
    scrollbar_closes = scrollbar_closes + 1
    return real_scrollbar_close(...)
  end
  virt.detach = function(...)
    detaches = detaches + 1
    return real_detach(...)
  end
  statuscol.detach = function(...)
    statuscol_detaches = statuscol_detaches + 1
    return real_statuscol_detach(...)
  end

  local ok, err = xpcall(function()
    local state = {}
    local surface = require("canvasdiff.Surface").new(state)
    surface.saved = true
    H.eq(surface.controllers.watch, nil, "this Surface acquired no watch lease")
    H.eq(surface.controllers.hl, nil, "this Surface acquired no highlighter lease")
    H.eq(surface.controllers.sidebar, nil, "this Surface acquired no sidebar lease")
    H.eq(surface.controllers.scrollbar, nil, "this Surface acquired no scrollbar lease")
    H.eq(surface.controllers.virt, nil, "this Surface acquired no virtualizer lease")
    H.eq(surface.controllers.statuscol, nil,
      "this Surface acquired no status-column lease")
    H.eq(surface:dispose("test"), true)
    H.eq(stops, 0,
      "a lease-less owner must not attempt an unqualified watch teardown")
    H.eq(hl_detaches, 0,
      "a lease-less owner must not detach the current highlighter")
    H.eq(sidebar_closes, 0,
      "a lease-less owner must not close the current sidebar")
    H.eq(scrollbar_closes, 0,
      "a lease-less owner must not close any scrollbar")
    H.eq(detaches, 0,
      "a lease-less owner must not attempt an unqualified virtualizer teardown")
    H.eq(statuscol_detaches, 0,
      "a lease-less owner must not detach the current status-column controller")
  end, debug.traceback)

  watch.stop = real_stop
  hl.detach = real_hl_detach
  sidebar.close = real_sidebar_close
  scrollbar.close = real_scrollbar_close
  virt.detach = real_detach
  statuscol.detach = real_statuscol_detach
  assert(ok, err)
end

-- Regression: the root came only from getcwd(), so `nvim path/to/repo/file`
-- from a parent directory refused to open with "not inside a git
-- repository" -- while staring at a file that plainly was in one. It read as
-- the plugin being broken rather than looking in the wrong place.
T["root_ resolves from the current buffer when cwd is not a repo"] = function()
  local root = H.git_fixture({
    committed = { ["f.txt"] = "one\ntwo\n" },
    worktree = { ["f.txt"] = "one\nCHANGED\n" },
  })
  git(root, { "branch", "topic" })
  local parent = vim.fs.dirname(root)

  in_cwd(parent, function(fm)
    vim.cmd.edit(vim.fs.joinpath(root, "f.txt"))
    H.eq(fm.command_complete("topi"), { "topic" },
      "completion uses the same buffer-repository fallback as open")
    fm.open()
    assert(canvas.is_canvas_buf(vim.api.nvim_get_current_buf()),
      "the canvas must open from the buffer's own repo")
    H.eq(shown_files(), { "f.txt" })
  end)
end

-- cwd stays authoritative: in Neovim the cwd is the project, and putting the
-- buffer first would silently switch repos when you opened a file elsewhere.
T["root_ cwd wins over the buffer when both are repos"] = function()
  local a = H.git_fixture({
    committed = { ["in_a.txt"] = "a\n" },
    worktree = { ["in_a.txt"] = "A\n" },
  })
  local b = H.git_fixture({
    committed = { ["in_b.txt"] = "b\n" },
    worktree = { ["in_b.txt"] = "B\n" },
  })

  in_cwd(a, function(fm)
    vim.cmd.edit(vim.fs.joinpath(b, "in_b.txt"))
    fm.open()
    H.eq(shown_files(), { "in_a.txt" }, "the cwd's repo, not the buffer's")
  end)
end

T["root_ neither a repo still warns and opens nothing"] = function()
  local dir = H.tmpdir()
  in_cwd(dir, function(fm, msgs)
    fm.open()
    assert(not canvas.is_canvas_buf(vim.api.nvim_get_current_buf()),
      "nothing should open outside a repo")
    H.eq(#msgs, 1, "exactly one warning")
    H.eq(msgs[1].level, vim.log.levels.WARN)
    assert(msgs[1].msg:match("not inside a git repository"), "got: " .. msgs[1].msg)
    assert(msgs[1].msg:find(dir, 1, true),
      "should name where it looked so the user can see why, got: " .. msgs[1].msg)
  end)
end

-- A scratch/terminal/URI buffer has no meaningful path; it must not be
-- mistaken for one and must not throw.
T["root_ a nameless buffer contributes no path"] = function()
  local dir = H.tmpdir()
  in_cwd(dir, function(fm, msgs)
    vim.cmd("enew") -- no name, no file
    fm.open()
    H.eq(#msgs, 1, "still just the one warning, no error")
    assert(msgs[1].msg:match("not inside a git repository"), "got: " .. msgs[1].msg)
  end)
end

return T
