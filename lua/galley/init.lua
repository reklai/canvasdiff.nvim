local canvas = require("galley.canvas")
local git = require("galley.git")
local model = require("galley.model")
local jump = require("galley.jump")
local config = require("galley.config")
local hl = require("galley.hl")
local collect = require("galley.collect")
local watch = require("galley.watch")
local sidebar = require("galley.sidebar")
local scrollbar = require("galley.scrollbar")
local virt = require("galley.virt")
local motions = require("galley.motions")
local statuscol = require("galley.statuscol")
local session = require("galley.session")
local util = require("galley.util")
local keys = require("galley.keys")

local M = {}

local EMPTY_MSG = "-- no changes --"

--- Is `st`'s canvas actually live and on screen right now? `state` outlives
--- M.close (the canvas buffer is cached and reopened), so a bare nil check
--- is not enough to tell an open canvas from a closed one.
---
--- Keys on state.win, which the scrollbar/hl/statuscolumn refresh on
--- BufWinEnter -- with all three disabled it can go stale, and multi-window
--- canvas display is a documented MVP limitation anyway. Note M.close
--- deliberately does NOT use this: it tests the CURRENT window instead, for
--- the reasons in its own docstring.
local function canvas_showing(st)
  return st.win and vim.api.nvim_win_is_valid(st.win)
    and vim.api.nvim_win_get_buf(st.win) == st.buf
end

-- The single live canvas excursion state, cached across close()/open() so
-- the canvas buffer content survives being hidden (canvas.lua itself keeps
-- the scratch buffer alive; this just remembers our bookkeeping around it:
-- the git root and the window's previous buffer).
local state = nil

--- Public setup: merge user options into the config module. Entirely
--- optional -- every code path below works fine against config.defaults
--- when setup() is never called.
function M.setup(opts)
  return config.setup(opts)
end

local function show_empty_message(st)
  vim.api.nvim_set_option_value("modifiable", true, { buf = st.buf })
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { EMPTY_MSG })
  vim.api.nvim_set_option_value("modifiable", false, { buf = st.buf })
end

--- Refresh the other live UI pieces after a direct canvas.set_collapsed
--- splice (mirrors what jump.back/M.refresh already do after their own
--- canvas splices): reapply lazy highlighting and sync sidebar/scrollbar.
local function sync_after_collapse(st)
  hl.apply_now(st)
  sidebar.refresh(st)
  scrollbar.update(st)
end

--- Set section i's collapse state on behalf of the USER (the <Tab>/za/<CR>
--- keymaps). Drops virt's ownership claim on the path first: an explicit
--- action is user intent, so the auto-virtualizer must never expand it back
--- on a later in-window pass, and session.save must never discard it as
--- module intent. virt.apply only runs on scroll/refresh, so without this a
--- stale claim can outlive the toggle indefinitely.
local function user_set_collapsed(st, i, collapsed)
  virt.unauto(st.sections[i].path)
  canvas.set_collapsed(st, i, collapsed)
  sync_after_collapse(st)
end

--- Jump into the section/entry under the cursor, expanding it instead when
--- it's a collapsed placeholder. Shared by the jump keymap and the
--- double-click mapping so both intercept a jump into a placeholder the
--- same way.
local function jump_or_expand(st, cfg)
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  local i = canvas.locate(st, cursor[1] - 1)
  if i and st.collapsed[st.sections[i].path] then
    user_set_collapsed(st, i, false)
    return
  end
  jump.enter(st, { back_keys = keys.list(cfg.keymaps.file.back) })
end

--- Toggle collapse of the section under the cursor.
local function toggle_collapse_under_cursor(st)
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  local i = canvas.locate(st, cursor[1] - 1)
  if not i then
    return
  end
  user_set_collapsed(st, i, not st.collapsed[st.sections[i].path])
end

--- What each canvas action does. Keyed by `keys.specs` action names; an action
--- with no handler here simply installs no map, which is what lets a spec land
--- before the feature behind it does.
local function canvas_actions(st, cfg)
  return {
    jump       = function() jump_or_expand(st, cfg) end,
    collapse   = function() toggle_collapse_under_cursor(st) end,
    close      = function() M.close() end,
    refresh    = function() M.refresh() end,
    base       = function() M.toggle_base() end,
    cycle_next = function() sidebar.cycle(st, 1) end,
    cycle_prev = function() sidebar.cycle(st, -1) end,
    next_file  = function() motions.goto_file(st, 1) end,
    prev_file  = function() motions.goto_file(st, -1) end,
    next_hunk  = function() motions.goto_hunk(st, 1) end,
    prev_hunk  = function() motions.goto_hunk(st, -1) end,
  }
end

local function set_canvas_keymaps(st)
  local cfg = config.options
  local acts = canvas_actions(st, cfg)
  for _, m in ipairs(keys.resolved("canvas", cfg.keymaps)) do
    local fn = acts[m.action]
    if fn then
      vim.keymap.set("n", m.lhs, fn,
        { buffer = st.buf, silent = true, noremap = true, desc = m.desc })
    end
  end
end

--- Open the canvas in the current window for the current cwd's git repo.
--- Not a repo ⇒ notify and return (never throws).
---
--- `opts.base` ("HEAD" | "index") overrides both the saved session's base and
--- the configured default, so a command naming a state can open straight into
--- it rather than opening and then re-rendering.
function M.open(opts)
  opts = opts or {}
  -- Invoked from inside our own sidebar (winfixbuf): the canvas can't be
  -- opened INTO that window. Redirect to the live canvas window if there is
  -- one; otherwise treat the sidebar as an appendage of an open canvas.
  if sidebar.is_sidebar_win(vim.api.nvim_get_current_win()) then
    if state and canvas_showing(state) then
      vim.api.nvim_set_current_win(state.win)
    else
      return
    end
  end

  local root = git.root(vim.fn.getcwd())
  if not root then
    util.warn("not inside a git repository")
    return
  end

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)

  -- Load any saved session BEFORE collect, so a restored base is honored
  -- from the very first collect.files call -- not just after the fact.
  local sess = config.options.session.enabled and session.load(root) or nil
  local base = opts.base or (sess and sess.base) or config.options.base

  local sections = model.build(collect.files(root, base), config.options.context)

  local st = canvas.open(sections, {})
  st.root = root
  st.base = base
  st.prev_buf = prev_buf
  state = st

  if #sections == 0 then
    show_empty_message(st)
  end

  set_canvas_keymaps(st)

  if config.options.highlight.enabled then
    hl.attach(st, config.options.highlight)
  end

  if config.options.watch.enabled then
    watch.on_empty = function()
      show_empty_message(st)
    end
    watch.start(st, config.options.watch)
  end

  if config.options.sidebar.enabled then
    sidebar.open(st, config.options.sidebar)
  end

  if config.options.scrollbar.enabled then
    scrollbar.open(st, config.options.scrollbar)
  end

  if config.options.statuscolumn.enabled then
    statuscol.attach(st)
  end

  if config.options.session.enabled then
    local aug = vim.api.nvim_create_augroup("galley.session", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = aug,
      callback = function()
        session.save(st)
      end,
    })
  end

  -- Restore BEFORE the auto-virtualizer's first pass. A freshly-opened
  -- canvas sits at row 1, so a virt.apply here would auto-collapse whatever
  -- far section the saved view points at -- and restore's view step skips a
  -- collapsed target, silently reopening large changesets at section one.
  -- Restoring first also means the first apply classifies against the real
  -- viewport, so it leaves the section the user is looking at expanded.
  if sess then
    session.restore(st, sess)
    -- Restored collapses reshape the canvas after the sidebar and scrollbar
    -- were built from the fully-expanded one, and restoring the view doesn't
    -- necessarily scroll (it may already be at the top, or not be saved at
    -- all when the top section is the collapsed one) -- so nothing else
    -- brings them back in sync. Also fixes up the sidebar's active row,
    -- which set_folds drew before the view step moved the viewport.
    sync_after_collapse(st)
  end

  if config.options.virt.enabled then
    -- Must precede attach: attach applies immediately, and that first pass
    -- can already splice.
    virt.on_change = sync_after_collapse
    virt.attach(st, config.options.virt)
  end
end

--- Restore the window's previous buffer (or `enew` if it's gone). The
--- canvas buffer itself is left alone -- canvas.lua keeps it cached/hidden.
---
--- Only ever acts on the CURRENT window, and only when that window is
--- actually showing the canvas buffer right now -- never on `state.win`
--- blindly. This matters because `state` is a single module-level
--- singleton: the window it was captured in at `open()` time can since
--- have navigated to a different buffer (e.g. `:edit`'d away), or a later
--- `open()`/`toggle()` invoked from a *different* window can have
--- overwritten `state.win`/`state.prev_buf` entirely. In either case
--- blindly restoring `state.prev_buf` into `state.win` would clobber
--- whatever the user is actually looking at in some other window.
---
--- If the current window isn't showing the canvas at all, close() is a
--- no-op. If it is showing the canvas but isn't the window `state`
--- remembers a `prev_buf` for (the multi-window case above), it falls
--- back to `enew` there instead of guessing at some other window's
--- previous buffer. Any *other* window still showing the canvas buffer
--- besides the current one is left untouched -- multi-window canvas
--- display is a documented MVP limitation, not handled here.
function M.close()
  if not state then
    return
  end

  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= state.buf then
    return
  end

  if config.options.session.enabled then
    session.save(state)
  end
  pcall(vim.api.nvim_del_augroup_by_name, "galley.session")

  watch.stop()
  hl.detach(state)
  sidebar.close()
  scrollbar.close()
  virt.detach()
  statuscol.detach()

  local prev_buf = (win == state.win) and state.prev_buf or nil
  if prev_buf and prev_buf ~= state.buf and vim.api.nvim_buf_is_valid(prev_buf) then
    vim.api.nvim_win_set_buf(win, prev_buf)
  else
    vim.api.nvim_win_call(win, function()
      vim.cmd("enew")
    end)
  end
end

--- Toggle: close if the canvas is showing in the current window, else open.
--- Being focused inside our own sidebar counts as "the canvas is open": jump
--- to the live canvas window and close from there, or just close the
--- sidebar if the canvas it was attached to is already gone. Never errors.
function M.toggle()
  local current_win = vim.api.nvim_get_current_win()
  if sidebar.is_sidebar_win(current_win) then
    if state and canvas_showing(state) then
      vim.api.nvim_set_current_win(state.win)
      M.close()
    else
      sidebar.close()
    end
    return
  end

  if canvas.is_canvas_buf(vim.api.nvim_get_current_buf()) then
    M.close()
  else
    M.open()
  end
end

--- Full re-collect + re-render of the live canvas state, if any exists yet.
function M.refresh()
  if not state then
    return
  end
  local sections = model.build(collect.files(state.root, state.base), config.options.context)
  canvas.render_all(state, sections)
  state.sections = sections
  if #sections == 0 then
    show_empty_message(state)
  end
  hl.apply_now(state)
  sidebar.refresh(state)
  scrollbar.update(state)
  virt.apply(state, config.options.virt)
end

local function base_label(base)
  return base == "index" and "index (unstaged)" or "HEAD"
end

--- Set the diff base explicitly to "HEAD" or "index", opening the canvas if
--- it isn't showing.
---
--- Idempotent, which is the whole point: commands get put inside user
--- mappings, and `:Galley unstaged` must always land unstaged. A toggle in a
--- mapping is a coin flip. Opening rather than warning is likewise the only
--- sensible reading of a command that names a state.
function M.set_base(base)
  if not (state and canvas_showing(state)) then
    M.open({ base = base })
    return
  end
  if state.base == base then
    return
  end
  state.base = base
  M.refresh()
  util.notify("diff base = worktree vs " .. base_label(base))
end

--- Flip the diff base between "worktree vs HEAD" and "worktree vs index"
--- (unstaged-only review) and refresh the live canvas. Canvas not currently
--- showing (never opened, or closed again) ⇒ notify and return.
---
--- Deliberately still warns rather than opening: this is the keymap's entry
--- point, and a keypress on no canvas is a mistake, not a request to open one.
function M.toggle_base()
  if not (state and canvas_showing(state)) then
    util.warn("no live diff canvas")
    return
  end
  M.set_base(state.base == "index" and "HEAD" or "index")
end

return M
