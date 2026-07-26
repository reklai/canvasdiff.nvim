local H = require("helpers")
local canvas = require("galley.canvas")

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

local function group_alive(name)
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
  pcall(vim.api.nvim_del_augroup_by_name, "galley.hl")
end

--- Temporarily count calls through table methods, restoring every method even
--- when the body fails. App resolves these methods through their module
--- tables at teardown time, so this observes the existing ownership seam
--- without adding production-only introspection.
local function with_spies(specs, body)
  local counts, installed = {}, {}
  for _, spec in ipairs(specs) do
    local original = spec.target[spec.method]
    counts[spec.name] = 0
    local wrapper = function(...)
      counts[spec.name] = counts[spec.name] + 1
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
    body(counts)
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
  fm.open()
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
    })
  end, debug.traceback)

  -- Avoid a second close after a successful terminal path: the current
  -- singleton has no disposed bit yet, and repeated close is deliberately a
  -- later failure-first contract. On an assertion failure, however, reclaim
  -- any still-live owner before restoring the shared test process.
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
