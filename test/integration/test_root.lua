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
    "cycle_lens",
    "jump_back",
    "open",
    "refresh",
    "set_base",
    "set_branch",
    "set_lens",
    "setup",
    "toggle",
    "toggle_base",
  })
  for _, name in ipairs(names) do
    H.eq(type(first[name]), "function", name .. " is callable")
  end
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

  local state = {}
  local surface = require("canvasdiff.Surface").new(state)
  first.surface = surface
  H.eq(first.surface, surface, "the active Surface is stored on its owning App")
  H.eq(second.surface, nil, "one App's Surface cannot leak into another App")
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
  local parent = vim.fs.dirname(root)

  in_cwd(parent, function(fm)
    vim.cmd.edit(vim.fs.joinpath(root, "f.txt"))
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
