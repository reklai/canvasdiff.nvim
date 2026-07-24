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

--- Directory of `buf`'s own file, or nil when it doesn't have one.
--- Restricted to ordinary file buffers, so scratch buffers, terminals and
--- URI-backed buffers (oil://, fugitive://, our own galley://) never
--- contribute a bogus path.
local function buf_dir(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  if vim.api.nvim_get_option_value("buftype", { buf = buf }) ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local dir = vim.fn.fnamemodify(name, ":p:h")
  return vim.fn.isdirectory(dir) == 1 and dir or nil
end

--- Open the canvas in the current window for the git repo we're working in.
--- Not a repo ⇒ notify and return (never throws).
---
--- The repo is resolved from the cwd first, falling back to the current
--- buffer's own file. cwd wins because in Neovim the cwd IS the project, and
--- keeping it first means this changes nothing for anyone already working
--- that way. The fallback exists because `nvim path/to/repo/file.lua` from a
--- parent directory -- or hopping projects with a file picker -- otherwise
--- refuses to open at all, with a message that looks like the plugin is
--- broken rather than looking in the wrong place.
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

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)

  local cwd = vim.fn.getcwd()
  local root = git.root(cwd)
  if not root then
    local dir = buf_dir(prev_buf)
    root = dir and git.root(dir) or nil
  end
  if not root then
    util.warn("not inside a git repository (looked in " .. cwd .. ")")
    return
  end

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

--- Windows in the CURRENT tabpage showing the canvas buffer.
---
--- Tabpage-scoped on purpose: tabs are separate workspaces, so closing here
--- must not reach into a canvas someone left open in another one.
local function canvas_wins(st)
  local out = {}
  if not (st and st.buf and vim.api.nvim_buf_is_valid(st.buf)) then
    return out
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == st.buf then
      out[#out + 1] = w
    end
  end
  return out
end

--- Is `buf` something we could sensibly leave a window sitting on?
local function restorable(buf, st)
  return buf
    and buf ~= st.buf
    and vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_buf_is_loaded(buf)
end

--- Put `win` back on something useful now that the canvas is leaving it.
---
--- Preference order, most to least specific: the buffer this window had when
--- the canvas took it over; the last file an excursion landed in (if you were
--- reviewing, that's the file you most recently touched); the window's
--- alternate file; and only then a blank buffer. The chain exists because
--- landing on [No Name] reads as something having gone wrong, when in fact
--- nothing did -- the buffer we came from was simply deleted meanwhile.
local function restore_window(win, st)
  local candidates = {
    (win == st.win) and st.prev_buf or nil,
    jump.last_buf(),
    vim.api.nvim_win_call(win, function() return vim.fn.bufnr("#") end),
  }
  for _, buf in ipairs(candidates) do
    if restorable(buf, st) then
      vim.api.nvim_win_set_buf(win, buf)
      return
    end
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd("enew")
  end)
end

--- Take the canvas off screen and put every window it occupied back on
--- something useful. The canvas buffer itself is left alone -- canvas.lua
--- keeps it cached/hidden, which is what makes reopening cheap.
---
--- Acts on every window in this tabpage showing the canvas, not just the
--- current one. Restricting it to the current window meant `:Galley close`
--- from a neighbouring split was a silent no-op that read as the plugin being
--- broken. `state` is still a single module-level singleton, so only the one
--- window it remembers a `prev_buf` for gets that buffer back; the others go
--- through the same fallback chain rather than being handed another window's
--- history.
---
--- No canvas on screen ⇒ no-op. Closing what isn't open is not an error.
---
--- A stale 'statuscolumn' left on a restored window is harmless: statuscol's
--- text function returns "" as soon as the window isn't showing the canvas.
function M.close()
  if not state then
    return
  end

  local wins = canvas_wins(state)
  if #wins == 0 then
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

  for _, win in ipairs(wins) do
    restore_window(win, state)
  end
end

--- Toggle: if the canvas is on screen anywhere in this tabpage, take it off;
--- otherwise open it here.
---
--- Keyed on "is it showing at all", not "is it showing in THIS window".
--- Toggling from a neighbouring split used to fall through to open() and put
--- a second view of the same canvas on screen, so the key that is supposed to
--- dismiss it added another one instead.
---
--- Being focused inside our own sidebar counts as "the canvas is open": close
--- it, or just close the sidebar if the canvas it was attached to is already
--- gone. Never errors.
function M.toggle()
  local showing = state and #canvas_wins(state) > 0

  if sidebar.is_sidebar_win(vim.api.nvim_get_current_win()) then
    if showing then
      M.close()
    else
      sidebar.close()
    end
    return
  end

  if showing then
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
