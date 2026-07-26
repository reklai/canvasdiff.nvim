local canvas = require("galley.canvas")
local config = require("galley.config")
local keys = require("galley.keys")
local fold = require("galley.fold")
local render = require("galley.render")
local model = require("galley.model")
local lens = require("galley.lens")

local S = {}

--- Flatten alphabetical sections into display-ordered dir/file entries.
--- `folded` is a set of dir paths ("lua/mod/" -- cumulative, trailing
--- slash); a folded dir is shown itself but none of its descendants are.
--- Sections are sorted by path, so each dir is emitted exactly once,
--- immediately before its first descendant.
---
--- `aside` is an optional set of file paths the user folded themselves, used only
--- to flag their rows. `stale` is an optional set of paths that have changed since
--- they were folded; a folded directory carries the signal when anything beneath it
--- has changed, because its child rows are hidden. All inputs are plain tables.
function S.build_entries(sections, folded, aside, stale)
  folded = folded or {}
  aside = aside or {}
  stale = stale or {}
  local entries = {}
  local prev_dirs = {}
  local stale_dirs = {}
  for path in pairs(stale) do
    local from = 1
    while true do
      local slash = string.find(path, "/", from, true)
      if not slash then break end
      stale_dirs[string.sub(path, 1, slash)] = true
      from = slash + 1
    end
  end

  for i, section in ipairs(sections) do
    local parts = vim.split(section.path, "/", { plain = true })
    local fname = table.remove(parts)

    local shared = 0
    for d = 1, math.min(#prev_dirs, #parts) do
      if prev_dirs[d] == parts[d] then
        shared = d
      else
        break
      end
    end

    local hidden = false
    local prefix = ""
    for d = 1, #parts do
      prefix = prefix .. parts[d] .. "/"
      if not hidden then
        if d > shared then
          entries[#entries + 1] = {
            kind = "dir", path = prefix, name = parts[d] .. "/",
            depth = d - 1, folded = folded[prefix] or false,
            stale = (folded[prefix] and stale_dirs[prefix]) or false,
          }
        end
        if folded[prefix] then
          hidden = true
        end
      end
    end

    if not hidden then
      entries[#entries + 1] = {
        kind = "file", path = section.path, name = fname, depth = #parts,
        section_i = i, adds = section.adds, dels = section.dels,
        aside = aside[section.path] or false,
        stale = stale[section.path] or false,
        staged = section.staged,
        unstaged = section.unstaged,
      }
    end
    prev_dirs = parts
  end

  return entries
end

--- Render entries to display lines (pure).
---
--- File rows carry the same two-column gutter as dir rows, holding "▸ " when
--- the file is set aside -- the same glyph render.placeholder uses in the
--- canvas and a folded dir uses here, so one symbol means one thing
--- everywhere. Without it the tree and the navigation disagree: ]f skips a
--- file and nothing on screen explains why.
function S.render_lines(entries)
  local lines = {}
  for i, e in ipairs(entries) do
    local indent = ("  "):rep(e.depth)
    local stale = e.stale and render.glyphs.stale or ""
    if e.kind == "dir" then
      lines[i] = indent
        .. (e.folded and (render.glyphs.folded .. " ") or (render.glyphs.open .. " "))
        .. e.name .. stale
    else
      local stage = render.stage_mark(e.staged, e.unstaged)
      if stage ~= "" then stage = " " .. stage end
      lines[i] = indent .. (e.aside and (render.glyphs.folded .. " ") or "  ")
        .. e.name
        .. ("  +%d " .. render.glyphs.minus .. "%d"):format(e.adds, e.dels)
        .. stage .. stale
    end
  end
  return lines
end

local NS = vim.api.nvim_create_namespace("galley.sidebar")
local BUFNAME = "galley://sidebar"

-- Module-level singleton, mirroring init.lua's state pattern: at most one
-- sidebar, always attached to the one live canvas.
local side = nil

local function ensure_hl_groups()
  vim.api.nvim_set_hl(0, "GalleySidebarDir", { link = "Directory", default = true })
  vim.api.nvim_set_hl(0, "GalleySidebarActive", { link = "Visual", default = true })
  render.ensure_marker_hl()
end

function S.is_open()
  return side ~= nil and side.win ~= nil and vim.api.nvim_win_is_valid(side.win)
end

--- True when `win` is the live sidebar window.
function S.is_sidebar_win(win)
  return S.is_open() and win == side.win
end

local function set_modifiable(buf, val)
  vim.api.nvim_set_option_value("modifiable", val, { buf = buf })
end

--- "The canvas changed shape" -- a fold spliced sections down to placeholders,
--- or back. Lives on the STATE (`state.hooks`, the same table hl.attach uses)
--- rather than on this module, so it belongs to the canvas it describes and
--- cannot outlive it: a module-global assigned for one canvas would still be
--- pointing at that canvas's consumers after it closed.
---
--- The hook is what wakes the pieces this module cannot reach: without it the
--- treesitter tier keeps marks on rows that no longer exist and the minimap
--- depicts a canvas that isn't there. init.M.open wires it unconditionally.
---
--- The bare `S.refresh` fallback is for a sidebar driven against a hand-built
--- state (the tests do this): it keeps the tree honest, which is all this module
--- owns, and there are no other consumers to wake in that case.
local function notify_change(state)
  local hook = state.hooks and state.hooks.on_shape_change
  if hook then
    hook(state)
  else
    S.refresh(state)
  end
end

--- Rebuild entries from the live sections + fold state and redraw.
function S.refresh(state)
  if not S.is_open() then
    return
  end
  -- user_folded, not hidden: this runs on every shape change, so keying the
  -- markers off the rendering predicate would churn every row in the tree on
  -- every scroll of a large changeset -- and would claim the user folded
  -- what the virtualizer collapsed on its own.
  local aside = fold.user_folded_set(state.sections, state)
  local stale = fold.stale_set(state.sections, state, model.fingerprint, lens.of(state).id)
  side.entries = S.build_entries(state.sections, state.folded, aside, stale)
  local lines = S.render_lines(side.entries)
  if #lines == 0 then
    lines = { "" }
  end
  set_modifiable(side.buf, true)
  vim.api.nvim_buf_set_lines(side.buf, 0, -1, false, lines)
  set_modifiable(side.buf, false)
  vim.api.nvim_buf_clear_namespace(side.buf, NS, 0, -1)
  for row0, e in ipairs(side.entries) do
    if e.kind == "dir" then
      vim.api.nvim_buf_set_extmark(side.buf, NS, row0 - 1, 0, {
        line_hl_group = "GalleySidebarDir",
        priority = 90,
      })
    end
    local line = lines[row0] or ""
    local is_file = e.kind ~= "dir"
    local spans = render.marker_spans(
      line, is_file and e.staged or nil, is_file and e.unstaged or nil, e.stale)
    for _, span in ipairs(spans) do
      vim.api.nvim_buf_set_extmark(side.buf, NS, row0 - 1, span[1], {
        end_row = row0 - 1,
        end_col = span[2],
        hl_group = span[3],
        priority = 101,
      })
    end
  end
  side.active_mark = nil
  S.sync(state)
end

--- Track the canvas topline: activate the file entry for the section under
--- it, or the deepest visible ancestor dir when folds hide the file.
function S.sync(state)
  if not S.is_open() then
    return
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_win_get_buf(state.win) == state.buf) then
    return -- excursion in progress or canvas hidden
  end
  local top0 = vim.api.nvim_win_call(state.win, function()
    return vim.fn.line("w0") - 1
  end)
  local section_i = (canvas.locate(state, top0))
  if not section_i then
    return
  end
  local path = state.sections[section_i].path

  local best
  for row0m1, e in ipairs(side.entries) do
    if (e.kind == "file" and e.section_i == section_i)
      or (e.kind == "dir" and path:sub(1, #e.path) == e.path) then
      best = row0m1 - 1
    end
  end
  if not best then
    return
  end

  if side.active_mark then
    pcall(vim.api.nvim_buf_del_extmark, side.buf, NS, side.active_mark)
  end
  side.active_mark = vim.api.nvim_buf_set_extmark(side.buf, NS, best, 0, {
    line_hl_group = "GalleySidebarActive",
    priority = 100,
  })
  -- Don't yank the cursor out from under the user while they're actually
  -- navigating the sidebar themselves -- only steer it when focus is
  -- elsewhere (e.g. the canvas window scrolled).
  if vim.api.nvim_get_current_win() ~= side.win then
    pcall(vim.api.nvim_win_set_cursor, side.win, { best + 1, 0 })
  end
end

--- Act on the entry under the sidebar cursor: a dir toggles its fold, which
--- folds its files on the canvas too; a file scrolls the canvas to its section
--- without changing its fold. Never changes any window's buffer or the focused
--- window.
function S.select(state)
  if not S.is_open() then
    return
  end
  local row = vim.api.nvim_win_get_cursor(side.win)[1]
  local e = side.entries[row]
  if not e then
    return
  end

  if e.kind == "dir" then
    -- Buffer validity, deliberately NOT the file branch's window check: this
    -- branch splices the canvas BUFFER, which is the right thing to do even
    -- while a jump excursion has the window showing a real file (resplice
    -- classifies that as "none" and skips view correction). A wiped buffer is
    -- the case that must bail -- resolving anchors against it throws -- and it
    -- has to bail before recording a fold it cannot apply.
    if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
      return
    end
    state.folded[e.path] = not state.folded[e.path] or nil
    -- Ascending order (resync_visibility's contract): each correction after
    -- the first is a no-op, and folding the directory you happen to be
    -- reading lands you on that file's placeholder rather than somewhere
    -- arbitrary.
    canvas.resync_visibility(state, fold.indices_under(state.sections, e.path))
    notify_change(state)
    return
  end

  if not (state.win and vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_win_get_buf(state.win) == state.buf) then
    return -- canvas window closed out from under the sidebar
  end

  -- Scroll there and nothing more. Selecting a folded file does not unfold it:
  -- navigation and folding are separate verbs, so moving around never rewrites
  -- the review state the user deliberately set.
  local start0 = (canvas.section_rows(state, e.section_i))
  vim.api.nvim_win_call(state.win, function()
    vim.fn.winrestview({ topline = start0 + 1, lnum = start0 + 1 })
  end)
  S.sync(state)
end

--- Cycle the canvas view to the next/previous section (wrapping), including
--- folded placeholders as first-class stops and keeping the sidebar in step.
--- Usable with or without the sidebar open; focus never moves.
---
--- Despite living here, this is a CANVAS action (keys.specs registers it under
--- ctx = "canvas", in the same Navigate group as ]f) -- it moves the canvas
--- viewport and is bound on the canvas buffer. It only sits in this module
--- because the sidebar-selection sync does.
function S.cycle(state, delta, count)
  count = math.max(1, count or vim.v.count1)
  local n = #state.sections
  if n == 0 then
    return
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_win_get_buf(state.win) == state.buf) then
    return
  end
  local top0 = vim.api.nvim_win_call(state.win, function()
    return vim.fn.line("w0") - 1
  end)
  local i = (canvas.locate(state, top0)) or 1

  local target = ((i - 1 + delta * count) % n) + 1

  local start0 = (canvas.section_rows(state, target))
  vim.api.nvim_win_call(state.win, function()
    vim.fn.winrestview({ topline = start0 + 1, lnum = start0 + 1 })
  end)
  S.sync(state)
end

function S.close()
  if side then
    local win = side.win
    side = nil
    pcall(vim.api.nvim_del_augroup_by_name, "galley.sidebar")
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
      -- nvim_win_close silently fails (E444) when `win` is the tabpage's
      -- last window -- e.g. the canvas window already died out from under
      -- the sidebar, leaving it as the sole survivor. Rather than abandon a
      -- winfixbuf'd window with nothing to attach to, reclaim it as a plain
      -- scratch window so it stays usable.
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_option_value("winfixbuf", false, { win = win })
        vim.api.nvim_win_call(win, function() vim.cmd("enew") end)
      end
    end
  end
end

--- (Re)install the sidebar's autocmds against the CURRENT `side.win` and
--- `state.win` pair. An `augroup(..., { clear = true })` makes this
--- idempotent, so it's safe to call both on a fresh open and whenever an
--- already-open sidebar is rebound to a new canvas state (a different
--- `state.win` means the old WinClosed pattern would otherwise go stale and
--- never fire).
local function install_autocmds(state)
  local aug = vim.api.nvim_create_augroup("galley.sidebar", { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = aug,
    callback = function(ev)
      local st = side and side.state
      local w = tonumber(ev.match)
      if st and w == st.win and vim.api.nvim_win_get_buf(st.win) == st.buf then
        S.sync(st)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    pattern = tostring(side.win),
    callback = function()
      side = nil
      pcall(vim.api.nvim_del_augroup_by_name, "galley.sidebar")
    end,
  })
  -- The canvas window closing (e.g. `:q` there) must not strand a live
  -- sidebar pointed at a dead state.win -- that's exactly the setup for the
  -- "last window" winfixbuf trap in S.close(). Closing another window from
  -- inside a WinClosed callback can be fragile (empirically: recursing into
  -- window-close logic mid-autocmd), so defer the actual close a tick.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    pattern = tostring(state.win),
    callback = function()
      vim.schedule(S.close)
    end,
  })
end

--- Open (or refresh) the sidebar as a non-focused fixed vsplit left of the
--- canvas window. The canvas window itself must never get winfixbuf.
function S.open(state, opts)
  opts = opts or {}
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return -- nothing to attach to; nil-safe no-op
  end
  if S.is_open() then
    side.state = state
    install_autocmds(state)
    S.refresh(state)
    return
  end
  ensure_hl_groups()

  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, BUFNAME)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  set_modifiable(buf, false)

  local win = vim.api.nvim_open_win(buf, false, {
    split = "left",
    width = opts.width or 32,
    win = state.win,
  })
  local wopts = {
    winfixwidth = true, winfixbuf = true, wrap = false, cursorline = true,
    number = false, relativenumber = false, signcolumn = "no", foldenable = false,
  }
  for name, val in pairs(wopts) do
    vim.api.nvim_set_option_value(name, val, { win = win, scope = "local" })
  end

  -- No fold set here: folds live on `state` (canvas.open initializes it), so
  -- they survive close/reopen, are readable by rendering and navigation, and
  -- follow the state they belong to rather than this singleton.
  side = { buf = buf, win = win, entries = {}, active_mark = nil, state = state }

  local actions = {
    select = function()
      local st = side and side.state
      if st then
        S.select(st)
      end
    end,
    close = function() S.close() end,
  }
  for _, m in ipairs(keys.resolved("sidebar", config.options.keymaps)) do
    local fn = actions[m.action]
    if fn then
      vim.keymap.set("n", m.lhs, fn,
        { buffer = buf, silent = true, noremap = true, desc = m.desc })
    end
  end

  install_autocmds(state)

  S.refresh(state)
end

return S
