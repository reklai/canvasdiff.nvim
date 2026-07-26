local H = require("helpers")
local canvas = require("galley.canvas")
local viewport = require("galley.viewport")

local T = {}

local PROJECT_ROOT = vim.fs.dirname(vim.fs.dirname(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

local RESOURCE_GROUPS = {
  "galley.watch",
  "galley.virt",
  "galley.hl",
  "galley.statuscol",
  "galley.sidebar",
  "galley.scrollbar",
  "galley.session",
  "galley.close",
  "galley.winbar",
}

-- These groups belong to the shared review surface rather than to one
-- window-bound accessory. The current sidebar/scrollbar owners may follow the
-- duplicate window that closes; rebinding those accessories is deliberately a
-- later Surface contract, while the review itself must remain alive.
local SURFACE_GROUPS = {
  "galley.watch",
  "galley.virt",
  "galley.hl",
  "galley.statuscol",
  "galley.session",
  "galley.close",
  "galley.winbar",
}

local function highlighter_groups()
  local out, seen = {}, {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    local name = autocmd.group_name
    if name
        and (name == "galley.hl" or name:match("^galley%.hl%."))
        and not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local function group_alive(name)
  if name == "galley.hl" then
    return #highlighter_groups() > 0
  end
  return pcall(vim.api.nvim_get_autocmds, { group = name })
end

local function assert_groups(alive, where, groups)
  for _, name in ipairs(groups or RESOURCE_GROUPS) do
    H.eq(group_alive(name), alive,
      ("%s should be %s %s"):format(name, alive and "armed" or "gone", where))
  end
end

--- Earlier unit files exercise the auxiliary singleton modules directly,
--- without going through the application teardown that owns them in normal
--- use. Normalize those test-only leftovers before characterizing the root
--- lifecycle, so this file observes only the review it opens itself.
local function reset_auxiliary_owners()
  require("galley.watch").stop()
  require("galley.sidebar").close()
  require("galley.scrollbar").close()
  require("galley.virt").detach()
  require("galley.statuscol").detach()
  for _, name in ipairs(highlighter_groups()) do
    pcall(vim.api.nvim_del_augroup_by_name, name)
  end
end

--- Temporarily count calls through table methods, restoring every method even
--- when the body fails. App resolves these methods through their module
--- tables at teardown time, so this observes the existing ownership seam
--- without adding production-only introspection.
local function with_spies(specs, body)
  local counts, calls, installed = {}, {}, {}
  for _, spec in ipairs(specs) do
    local original = spec.target[spec.method]
    counts[spec.name] = 0
    calls[spec.name] = {}
    local wrapper = function(...)
      counts[spec.name] = counts[spec.name] + 1
      calls[spec.name][#calls[spec.name] + 1] = {
        n = select("#", ...),
        ...,
      }
      return original(...)
    end
    spec.target[spec.method] = wrapper
    installed[#installed + 1] = {
      target = spec.target,
      method = spec.method,
      original = original,
      wrapper = wrapper,
    }
  end

  local ok, err = xpcall(function()
    body(counts, calls)
  end, debug.traceback)

  for i = #installed, 1, -1 do
    local item = installed[i]
    -- A test body must not replace an owned method behind the spy. Guarding
    -- this makes a future collision fail loudly without leaving the wrapper
    -- installed for every later case in the shared headless process.
    if item.target[item.method] ~= item.wrapper then
      ok = false
      err = err or ("spied method was replaced: " .. item.method)
    end
    item.target[item.method] = item.original
  end

  assert(ok, err)
end

--- Open one real review in an isolated tab/repository and guarantee cleanup.
--- The package eviction is safe here only because the preceding owner has
--- already torn every resource group down; package.loaded itself is not a
--- lifecycle mechanism.
local function with_canvas(body)
  assert(not group_alive("galley.watch"),
    "the preceding test must close its review before lifecycle isolation")
  reset_auxiliary_owners()
  assert_groups(false, "before the isolated review opens")
  package.loaded["galley"] = nil

  local root = H.git_fixture({
    committed = { ["a.txt"] = "one\ntwo\nthree\n" },
    worktree = { ["a.txt"] = "ONE\ntwo\nthree\n" },
  })
  local old_cwd = vim.fn.getcwd()
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_set_current_dir(root)

  local fm = require("galley")
  fm.setup({})
  local previous_buf = vim.api.nvim_get_current_buf()
  local st = fm.open()
  local owner = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()

  local ok, err = xpcall(function()
    assert(canvas.is_canvas_buf(buf), "sanity: the review canvas opened")
    assert_groups(true, "after open")
    body({
      fm = fm,
      root = root,
      tab = tab,
      owner = owner,
      buf = buf,
      previous_buf = previous_buf,
      state = st,
      surface = st.surface,
    })
  end, debug.traceback)

  -- On an assertion failure, reclaim any still-live owner before restoring the
  -- shared test process. Surface disposal is idempotent, so this is also safe
  -- after a successful terminal path.
  if group_alive("galley.watch") then
    pcall(fm.close)
  end

  vim.api.nvim_set_current_dir(
    vim.fn.isdirectory(old_cwd) == 1 and old_cwd or PROJECT_ROOT)
  if vim.api.nvim_tabpage_is_valid(tab) then
    pcall(vim.api.nvim_set_current_tabpage, tab)
    pcall(vim.cmd, "tabclose!")
  end

  local session = require("galley.session")
  os.remove(session.path_for(root))
  vim.api.nvim_set_current_dir(PROJECT_ROOT)
  H.eq(vim.fn.delete(root, "rf"), 0, "fixture directory was removed")
  package.loaded["galley"] = nil

  assert(ok, err)
end

T["lifecycle_ a duplicate canvas split shares the review and only the final close tears down"] = function()
  with_canvas(function(ctx)
    local session = require("galley.session")
    with_spies({
      { name = "session.save", target = session, method = "save" },
    }, function(counts)
      -- Mutating the review through its original view is immediately visible
      -- in a later duplicate because fold/model state belongs to the shared
      -- review buffer, not to either window.
      vim.api.nvim_set_current_win(ctx.owner)
      vim.api.nvim_win_set_cursor(ctx.owner, { 1, 0 })
      vim.api.nvim_feedkeys(vim.keycode("c"), "x", false)
      local folded = vim.api.nvim_buf_get_lines(ctx.buf, 0, 1, false)[1] or ""
      assert(folded:match("^▸ a%.txt"),
        "the shared review was folded through the original window: " .. folded)

      -- Match the ordinary user gesture covered by the existing lifecycle:
      -- split the current canvas window, then close the newly-created view.
      -- This deliberately does not characterize closing the original first;
      -- the scalar state.win bug on that path is failure-first work for the
      -- Surface ownership change.
      vim.cmd("split")
      local duplicate = vim.api.nvim_get_current_win()
      assert(duplicate ~= ctx.owner, "sanity: a second window was created")
      H.eq(vim.api.nvim_win_get_buf(duplicate), ctx.buf,
        "both windows display one shared canvas")
      H.eq(vim.api.nvim_buf_get_lines(
        vim.api.nvim_win_get_buf(duplicate), 0, 1, false)[1], folded,
        "the duplicate sees the same folded model")

      vim.api.nvim_win_close(duplicate, false)
      vim.wait(120, function() return false end)

      H.eq(counts["session.save"], 0,
        "closing a non-final view does not persist or dispose the review")
      assert(vim.api.nvim_win_is_valid(ctx.owner),
        "the original canvas window remains")
      H.eq(vim.api.nvim_win_get_buf(ctx.owner), ctx.buf,
        "the original still displays the shared canvas")
      assert_groups(true, "while one canvas window survives", SURFACE_GROUPS)

      -- The original is now the final canvas view. Its WinClosed path is
      -- deferred, so wait for the watch group to disappear before observing
      -- the completed teardown.
      vim.api.nvim_win_close(ctx.owner, false)
      local stopped = vim.wait(500, function()
        return not group_alive("galley.watch")
      end, 10)
      assert(stopped, "the final canvas close completed its deferred teardown")

      H.eq(counts["session.save"], 1,
        "the final close persists the shared review exactly once")
      assert_groups(false, "after the final canvas window closed")
    end)
  end)
end

T["lifecycle_ closing the original split first rebinds and persists the survivor"] = function()
  with_canvas(function(ctx)
    local session = require("galley.session")
    with_spies({
      { name = "session.save", target = session, method = "save" },
    }, function(counts)
      local surface = ctx.surface
      local initial_generation = surface.generation

      vim.api.nvim_set_current_win(ctx.owner)
      vim.cmd("split")
      local survivor = vim.api.nvim_get_current_win()
      assert(survivor ~= ctx.owner, "sanity: the duplicate is a distinct window")
      H.eq(ctx.state.win, ctx.owner,
        "plain :split does not silently repair the scalar owner before the fault")

      -- Close the remembered/original window, not the duplicate. The deferred
      -- ownership scan must discover and rebind the surviving view.
      vim.api.nvim_win_close(ctx.owner, false)
      local rebound = vim.wait(500, function()
        return ctx.state.win == survivor
      end, 10)
      assert(rebound, "the surviving split became the primary canvas view")
      assert(surface:is_alive(), "one surviving view keeps the Surface active")
      H.eq(counts["session.save"], 0, "a non-final close does not persist")
      H.eq(vim.api.nvim_win_get_buf(survivor), ctx.buf)
      assert_groups(true, "after the original view closed", SURFACE_GROUPS)

      -- Derive the semantic payload independently, before WinClosed. The
      -- terminal callback must capture this exact position synchronously while
      -- the window is valid, then carry it through deferred disposal.
      local row = math.min(3, vim.api.nvim_buf_line_count(ctx.buf))
      vim.api.nvim_win_call(survivor, function()
        vim.fn.winrestview({ topline = 1, lnum = row })
      end)
      local top0 = vim.api.nvim_win_call(survivor, function()
        return vim.fn.line("w0") - 1
      end)
      local vi, voffset = canvas.locate(ctx.state, top0)
      local expected_view = viewport.capture_from_entries(
        ctx.state.sections[vi].entries, voffset)
      expected_view.path = ctx.state.sections[vi].path

      local cursor0 = vim.api.nvim_win_get_cursor(survivor)[1] - 1
      local ci, coffset = canvas.locate(ctx.state, cursor0)
      local centry = ctx.state.sections[ci].entries[coffset]
      local expected_cursor = {
        path = ctx.state.sections[ci].path,
        new_lnum = centry and centry.new_lnum or nil,
        content = centry and centry.content or nil,
      }

      vim.api.nvim_win_close(survivor, false)
      local disposed = vim.wait(500, function()
        return surface.disposed
      end, 10)
      assert(disposed, "the global final host disposes the Surface")
      H.eq(surface.phase, "disposed")
      H.eq(surface.generation, initial_generation + 1)
      H.eq(counts["session.save"], 1, "the final view persists exactly once")

      local saved = assert(session.load(ctx.root), "the final close wrote a session")
      H.eq(saved.view, expected_view, "the closing window's semantic view survived")
      H.eq(saved.cursor, expected_cursor, "the closing window's semantic cursor survived")
      assert_groups(false, "after the rebound survivor closed")
    end)
  end)
end

T["lifecycle_ one Surface spans tabs until its global final host closes"] = function()
  with_canvas(function(ctx)
    local session = require("galley.session")
    with_spies({
      { name = "session.save", target = session, method = "save" },
    }, function(counts)
      local surface = ctx.surface

      vim.cmd("tabnew")
      local remote_tab = vim.api.nvim_get_current_tabpage()
      local remote = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(remote, ctx.buf)
      assert(surface:adopt_window(remote), "the remote BufWinEnter view is owned")

      vim.api.nvim_set_current_tabpage(ctx.tab)
      vim.api.nvim_win_close(ctx.owner, false)
      local rebound = vim.wait(500, function()
        return surface:is_alive() and ctx.state.win == remote
      end, 10)
      assert(rebound, "the Surface rebound across tabs after its local view closed")
      H.eq(counts["session.save"], 0, "a remote host prevents terminal persistence")
      H.eq(vim.api.nvim_win_get_buf(remote), ctx.buf,
        "closing one tab cannot clobber the other tab's canvas")
      assert_groups(true, "while a cross-tab host survives", SURFACE_GROUPS)

      vim.api.nvim_set_current_tabpage(remote_tab)
      vim.api.nvim_win_close(remote, false)
      local disposed = vim.wait(500, function()
        return surface.disposed
      end, 10)
      assert(disposed, "closing the global final host disposes the review")
      H.eq(counts["session.save"], 1)
      assert_groups(false, "after the cross-tab final host closed")
    end)
  end)
end

T["lifecycle_ tab-local close and toggle preserve each window landing"] = function()
  with_canvas(function(ctx)
    local surface = ctx.surface
    local original_landing = ctx.previous_buf

    -- Add a second tab whose own prior buffer is distinct from the original
    -- host's landing.
    vim.cmd("tabnew")
    local remote_tab = vim.api.nvim_get_current_tabpage()
    local remote = vim.api.nvim_get_current_win()
    local remote_landing = vim.api.nvim_get_current_buf()
    local remote_statuscol = "%=%l "
    vim.api.nvim_set_option_value(
      "statuscolumn", remote_statuscol, { win = remote, scope = "local" })
    vim.api.nvim_win_set_buf(remote, ctx.buf)
    surface:adopt_window(remote, remote_landing)
    H.eq(vim.api.nvim_get_option_value("statuscolumn", { win = remote }),
      "%!v:lua.require'galley.statuscol'.text()",
      "a newly-adopted remote host receives the review status column")

    -- Explicit close is tab-local. It restores the original host to its own
    -- landing and leaves the remote review untouched.
    vim.api.nvim_set_current_tabpage(ctx.tab)
    ctx.fm.close()
    H.eq(vim.api.nvim_win_get_buf(ctx.owner), original_landing,
      "the original tab returns to the buffer it replaced")
    H.eq(vim.api.nvim_win_get_buf(remote), ctx.buf,
      "the remote tab keeps the shared canvas")
    assert(surface:is_alive())

    -- From a third tab, toggle must show this existing Surface rather than
    -- silently trying to close a different tab or replacing the review.
    vim.cmd("tabnew")
    local third = vim.api.nvim_get_current_win()
    local third_landing = vim.api.nvim_get_current_buf()
    local third_statuscol = "%=%r "
    vim.api.nvim_set_option_value(
      "statuscolumn", third_statuscol, { win = third, scope = "local" })
    ctx.fm.toggle()
    H.eq(vim.api.nvim_win_get_buf(third), ctx.buf,
      "toggle shows the existing remote review in this tab")
    H.eq(vim.api.nvim_get_option_value("statuscolumn", { win = third }),
      "%!v:lua.require'galley.statuscol'.text()")
    H.eq(ctx.state.surface, surface, "toggle did not create a replacement Surface")
    H.eq(#surface:canvas_windows(), 2)

    ctx.fm.toggle()
    H.eq(vim.api.nvim_win_get_buf(third), third_landing,
      "the second toggle restores this tab's independent landing")
    assert(vim.wait(500, function()
      return vim.api.nvim_get_option_value("statuscolumn", { win = third })
        == third_statuscol
    end, 10), "the deferred leave restored the third window's prior option")
    H.eq(vim.api.nvim_get_option_value("statuscolumn", { win = third }),
      third_statuscol, "leaving the review restores this window's prior option")
    assert(surface:is_alive(), "the remote tab still owns the review")
    H.eq(vim.api.nvim_win_get_buf(remote), ctx.buf)

    vim.api.nvim_set_current_tabpage(remote_tab)
    ctx.fm.close()
    H.eq(vim.api.nvim_win_get_buf(remote), remote_landing,
      "the remote tab restores its own prior buffer, not the original tab's")
    assert(vim.wait(500, function()
      return vim.api.nvim_get_option_value("statuscolumn", { win = remote })
        == remote_statuscol
    end, 10), "final teardown restored the remote window's prior option")
    H.eq(vim.api.nvim_get_option_value("statuscolumn", { win = remote }),
      remote_statuscol, "final explicit close restores the remote option")
    assert(surface.disposed, "the remote host was the global final owner")
    vim.cmd("tabonly!")
  end)
end

T["lifecycle_ replacement hands every cross-tab host to the new Surface"] = function()
  with_canvas(function(ctx)
    local old = ctx.surface

    vim.cmd("tabnew")
    local remote_tab = vim.api.nvim_get_current_tabpage()
    local remote = vim.api.nvim_get_current_win()
    local remote_landing = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(remote, ctx.buf)
    old:adopt_window(remote, remote_landing)

    vim.api.nvim_set_current_tabpage(ctx.tab)
    vim.api.nvim_set_current_win(ctx.owner)
    local next_state = assert(ctx.fm.open())
    local replacement = assert(next_state.surface)

    assert(old.disposed, "the preceding generation was retired")
    assert(replacement:is_alive())
    H.eq(#replacement:canvas_windows(), 2,
      "both visible hosts transferred to the replacement generation")
    H.eq(vim.api.nvim_win_get_buf(remote), next_state.buf,
      "the remote view sees the rerendered shared canvas")

    vim.api.nvim_win_close(ctx.owner, false)
    local rebound = vim.wait(500, function()
      return replacement:is_alive() and next_state.win == remote
    end, 10)
    assert(rebound, "closing the local host rebinds the replacement remotely")
    H.eq(vim.api.nvim_win_get_buf(remote), next_state.buf)

    vim.api.nvim_set_current_tabpage(remote_tab)
    ctx.fm.close()
    H.eq(vim.api.nvim_win_get_buf(remote), remote_landing)
    assert(replacement.disposed)
    vim.cmd("tabonly!")
  end)
end

T["lifecycle_ racing terminal paths dispose and persist exactly once"] = function()
  with_canvas(function(ctx)
    local surface = ctx.surface
    local generation = surface.generation
    local hl_lease = assert(surface.controllers.hl)
    local virt_lease = assert(surface.controllers.virt)
    local statuscol_lease = assert(surface.controllers.statuscol)
    local disposed_callbacks = 0
    local release = surface.callbacks.on_dispose
    surface.callbacks.on_dispose = function(...)
      disposed_callbacks = disposed_callbacks + 1
      return release(...)
    end

    local specs = {
      { name = "session.save", target = require("galley.session"), method = "save" },
      { name = "watch.stop", target = require("galley.watch"), method = "stop" },
      { name = "hl.detach", target = require("galley.hl"), method = "detach" },
      { name = "sidebar.close", target = require("galley.sidebar"), method = "close" },
      { name = "scrollbar.close", target = require("galley.scrollbar"), method = "close" },
      { name = "virt.detach", target = require("galley.virt"), method = "detach" },
      { name = "statuscol.detach", target = require("galley.statuscol"), method = "detach" },
    }

    with_spies(specs, function(counts, calls)
      -- Keep a normal spare so the canvas WinClosed path can queue without
      -- ending the tab or the headless process.
      vim.api.nvim_set_current_win(ctx.owner)
      vim.cmd("vnew")
      local spare = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(ctx.owner)
      vim.api.nvim_win_close(ctx.owner, false)
      vim.api.nvim_set_current_win(spare)

      -- VimLeave, explicit close, repeat close, and the already-queued
      -- WinClosed callback all converge on the same once gate.
      vim.api.nvim_exec_autocmds("VimLeavePre", { group = "galley.session" })
      ctx.fm.close()
      ctx.fm.close()
      H.eq(surface:dispose("again"), false, "terminal disposal is idempotent")

      local drained = false
      vim.schedule(function() drained = true end)
      assert(vim.wait(500, function() return drained end, 10),
        "the held WinClosed queue drained")

      for _, spec in ipairs(specs) do
        H.eq(counts[spec.name], 1, spec.name .. " runs exactly once across the race")
      end
      H.eq(calls["virt.detach"][1].n, 1,
        "Surface teardown qualifies virtualizer cleanup with one exact lease")
      assert(rawequal(calls["virt.detach"][1][1], virt_lease),
        "Surface teardown passes the exact virtualizer lease it acquired")
      H.eq(calls["hl.detach"][1].n, 1,
        "Surface teardown qualifies highlighter cleanup with one exact lease")
      assert(rawequal(calls["hl.detach"][1][1], hl_lease),
        "Surface teardown passes the exact highlighter lease it acquired")
      H.eq(calls["statuscol.detach"][1].n, 1,
        "Surface teardown qualifies status-column cleanup with one exact lease")
      assert(rawequal(calls["statuscol.detach"][1][1], statuscol_lease),
        "Surface teardown passes the exact status-column lease it acquired")
      H.eq(disposed_callbacks, 1, "the App release callback runs exactly once")
      H.eq(surface.phase, "disposed")
      H.eq(surface.disposed, true)
      H.eq(surface.saved, true)
      H.eq(surface.generation, generation + 1)
      H.eq(ctx.state.surface, nil, "disposed state releases its owner back-reference")
      assert_groups(false, "after racing terminal paths")
    end)
  end)
end

T["lifecycle_ a queued old callback cannot dispose its replacement"] = function()
  with_canvas(function(ctx)
    local old = ctx.surface
    local old_generation = old.generation
    local old_hl = assert(old.controllers.hl)
    local old_shape_change = assert(ctx.state.hooks.on_shape_change)
    local old_virt = assert(old.controllers.virt)
    local old_statuscol = assert(old.controllers.statuscol)
    local session = require("galley.session")
    local watch = require("galley.watch")
    local hl = require("galley.hl")
    local virt = require("galley.virt")
    local statuscol = require("galley.statuscol")

    with_spies({
      { name = "session.save", target = session, method = "save" },
      { name = "watch.stop", target = watch, method = "stop" },
      { name = "hl.apply_now", target = hl, method = "apply_now" },
      { name = "hl.detach", target = hl, method = "detach" },
      { name = "virt.detach", target = virt, method = "detach" },
      { name = "statuscol.detach", target = statuscol, method = "detach" },
    }, function(counts, calls)
      vim.api.nvim_set_current_win(ctx.owner)
      vim.cmd("vnew")
      local spare = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(ctx.owner)
      vim.api.nvim_win_close(ctx.owner, false) -- queues old's guarded recheck
      vim.api.nvim_set_current_win(spare)

      local next_state = assert(ctx.fm.open())
      local replacement = assert(next_state.surface)
      assert(old.disposed, "opening the replacement retires the old Surface")
      assert(replacement:is_alive())
      assert(replacement.generation > old_generation,
        "activation generations are monotonically increasing")
      local replacement_hl = assert(replacement.controllers.hl)
      assert(replacement_hl ~= old_hl,
        "a replacement Surface acquires a distinct highlighter lease")
      local replacement_virt = assert(replacement.controllers.virt)
      assert(replacement_virt ~= old_virt,
        "a replacement Surface acquires a distinct virtualizer lease")
      local replacement_statuscol = assert(replacement.controllers.statuscol)
      assert(replacement_statuscol ~= old_statuscol,
        "a replacement Surface acquires a distinct status-column lease")
      H.eq(calls["virt.detach"][1].n, 1)
      assert(rawequal(calls["virt.detach"][1][1], old_virt),
        "replacement retires only the preceding Surface's virtualizer")
      H.eq(calls["hl.detach"][1].n, 1)
      assert(rawequal(calls["hl.detach"][1][1], old_hl),
        "replacement retires only the preceding Surface's highlighter")
      H.eq(calls["statuscol.detach"][1].n, 1)
      assert(rawequal(calls["statuscol.detach"][1][1], old_statuscol),
        "replacement retires only the preceding Surface's status-column controller")
      local saves_after_open = counts["session.save"]
      local stops_after_open = counts["watch.stop"]
      local hl_detaches_after_open = counts["hl.detach"]
      local detaches_after_open = counts["virt.detach"]
      local statuscol_detaches_after_open = counts["statuscol.detach"]

      local drained = false
      vim.schedule(function() drained = true end)
      assert(vim.wait(500, function() return drained end, 10),
        "the old queued callback ran before the marker")

      assert(replacement:is_alive(), "old queued work cannot dispose the replacement")
      H.eq(replacement.saved, false)
      H.eq(saves_after_open, 1, "only the replaced Surface was persisted")
      H.eq(counts["session.save"], saves_after_open,
        "the old queued callback did not persist the replacement")
      H.eq(counts["watch.stop"], stops_after_open,
        "the old queued callback did not stop the replacement watch")
      H.eq(counts["hl.detach"], hl_detaches_after_open,
        "the old queued callback did not detach the replacement highlighter")
      H.eq(counts["virt.detach"], detaches_after_open,
        "the old queued callback did not detach the replacement virtualizer")
      H.eq(counts["statuscol.detach"], statuscol_detaches_after_open,
        "the old queued callback did not detach the replacement status column")
      H.eq(#replacement:canvas_windows(), 1)
      assert_groups(true, "on the replacement", SURFACE_GROUPS)

      local applies_before_stale = counts["hl.apply_now"]
      old_shape_change()
      H.eq(counts["hl.apply_now"], applies_before_stale,
        "a stale generation's retained shape hook cannot apply to the replacement")

      local applies_before_current = counts["hl.apply_now"]
      next_state.hooks.on_shape_change()
      H.eq(counts["hl.apply_now"], applies_before_current + 1,
        "the replacement shape hook applies its highlighter exactly once")
      local last_apply = calls["hl.apply_now"][#calls["hl.apply_now"]]
      H.eq(last_apply.n, 1,
        "shape composition qualifies highlighter application with one exact lease")
      assert(rawequal(last_apply[1], replacement_hl),
        "shape composition passes the replacement Surface's highlighter lease")

      ctx.fm.close()
      H.eq(counts["hl.detach"], hl_detaches_after_open + 1)
      H.eq(calls["hl.detach"][2].n, 1)
      assert(rawequal(calls["hl.detach"][2][1], replacement_hl),
        "final close detaches the replacement's own highlighter lease")
      H.eq(counts["virt.detach"], detaches_after_open + 1)
      H.eq(calls["virt.detach"][2].n, 1)
      assert(rawequal(calls["virt.detach"][2][1], replacement_virt),
        "final close detaches the replacement's own lease")
      H.eq(counts["statuscol.detach"], statuscol_detaches_after_open + 1)
      H.eq(calls["statuscol.detach"][2].n, 1)
      assert(rawequal(calls["statuscol.detach"][2][1], replacement_statuscol),
        "final close detaches the replacement's own status-column lease")
    end)
  end)
end

T["lifecycle_ one explicit close performs one complete teardown pass"] = function()
  with_canvas(function(ctx)
    local specs = {
      { name = "session.save", target = require("galley.session"), method = "save" },
      { name = "watch.stop", target = require("galley.watch"), method = "stop" },
      { name = "hl.detach", target = require("galley.hl"), method = "detach" },
      { name = "sidebar.close", target = require("galley.sidebar"), method = "close" },
      { name = "scrollbar.close", target = require("galley.scrollbar"), method = "close" },
      { name = "virt.detach", target = require("galley.virt"), method = "detach" },
      { name = "statuscol.detach", target = require("galley.statuscol"), method = "detach" },
    }

    with_spies(specs, function(counts)
      ctx.fm.close()
      vim.wait(50, function() return false end)

      for _, spec in ipairs(specs) do
        H.eq(counts[spec.name], 1,
          spec.name .. " runs once in one explicit teardown pass")
      end
      assert_groups(false, "after explicit close")
      assert(vim.api.nvim_win_is_valid(ctx.owner),
        "explicit close restores rather than destroys the canvas window")
      H.eq(vim.api.nvim_win_get_buf(ctx.owner), ctx.previous_buf,
        "the window was restored to the buffer the canvas replaced")
    end)
  end)
end

return T
