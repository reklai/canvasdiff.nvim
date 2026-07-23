local canvas = require("finding_myself.canvas")
local git = require("finding_myself.git")
local model = require("finding_myself.model")
local jump = require("finding_myself.jump")
local config = require("finding_myself.config")
local hl = require("finding_myself.hl")
local collect = require("finding_myself.collect")
local watch = require("finding_myself.watch")
local sidebar = require("finding_myself.sidebar")
local scrollbar = require("finding_myself.scrollbar")
local virt = require("finding_myself.virt")

local M = {}

local EMPTY_MSG = "-- no changes --"

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

--- Expand section i if it's currently collapsed. Used by the jump keymap
--- to intercept a jump into a collapsed section.
local function expand_section(st, i)
  canvas.set_collapsed(st, i, false)
  sync_after_collapse(st)
end

--- Toggle collapse of the section under the cursor.
local function toggle_collapse_under_cursor(st)
  local cursor = vim.api.nvim_win_get_cursor(st.win)
  local i = canvas.locate(st, cursor[1] - 1)
  if not i then
    return
  end
  canvas.set_collapsed(st, i, not st.collapsed[st.sections[i].path])
  sync_after_collapse(st)
end

local function set_canvas_keymaps(st)
  local cfg = config.options
  local map_opts = { buffer = st.buf, silent = true, noremap = true }
  vim.keymap.set("n", cfg.keymaps.jump, function()
    local cursor = vim.api.nvim_win_get_cursor(st.win)
    local i = canvas.locate(st, cursor[1] - 1)
    if i and st.collapsed[st.sections[i].path] then
      expand_section(st, i)
      return
    end
    jump.enter(st, { back_key = cfg.keymaps.back })
  end, map_opts)
  vim.keymap.set("n", "<2-LeftMouse>", function()
    jump.enter(st, { back_key = cfg.keymaps.back })
  end, map_opts)
  vim.keymap.set("n", cfg.keymaps.collapse, function()
    toggle_collapse_under_cursor(st)
  end, map_opts)
  vim.keymap.set("n", "za", function()
    toggle_collapse_under_cursor(st)
  end, map_opts)
  vim.keymap.set("n", cfg.keymaps.close, function()
    M.close()
  end, map_opts)
  vim.keymap.set("n", cfg.keymaps.refresh, function()
    M.refresh()
  end, map_opts)
  vim.keymap.set("n", cfg.keymaps.cycle_next, function()
    sidebar.cycle(st, 1)
  end, map_opts)
  vim.keymap.set("n", cfg.keymaps.cycle_prev, function()
    sidebar.cycle(st, -1)
  end, map_opts)
end

--- Open the canvas in the current window for the current cwd's git repo.
--- Not a repo ⇒ notify and return (never throws).
function M.open()
  -- Invoked from inside our own sidebar (winfixbuf): the canvas can't be
  -- opened INTO that window. Redirect to the live canvas window if there is
  -- one; otherwise treat the sidebar as an appendage of an open canvas.
  if sidebar.is_sidebar_win(vim.api.nvim_get_current_win()) then
    if state and state.win and vim.api.nvim_win_is_valid(state.win)
        and vim.api.nvim_win_get_buf(state.win) == state.buf then
      vim.api.nvim_set_current_win(state.win)
    else
      return
    end
  end

  local root = git.root(vim.fn.getcwd())
  if not root then
    vim.notify("finding_myself: not inside a git repository", vim.log.levels.WARN)
    return
  end

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)

  local sections = model.build(collect.files(root), config.options.context)

  local st = canvas.open(sections, {})
  st.root = root
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

  if config.options.virt.enabled then
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

  watch.stop()
  hl.detach(state)
  sidebar.close()
  scrollbar.close()
  virt.detach()

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
    if state and state.win and vim.api.nvim_win_is_valid(state.win)
        and vim.api.nvim_win_get_buf(state.win) == state.buf then
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
  local sections = model.build(collect.files(state.root), config.options.context)
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

return M
