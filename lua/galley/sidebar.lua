local canvas = require("galley.canvas")
local config = require("galley.config")
local keys = require("galley.keys")
local fold = require("galley.fold")
local virt = require("galley.virt")

local S = {}

--- Assignable "the canvas changed shape" callback, mirroring virt.on_change.
--- init wires it to its own sync_after_collapse; this module cannot require
--- init (init requires it), and a fold that only redrew the tree would leave
--- the treesitter tier holding marks on rows that no longer exist and the
--- minimap depicting a canvas that isn't there. Falls back to a plain redraw
--- so the sidebar still works standalone.
S.on_change = nil

--- Flatten alphabetical sections into display-ordered dir/file entries.
--- `folded` is a set of dir paths ("lua/mod/" -- cumulative, trailing
--- slash); a folded dir is shown itself but none of its descendants are.
--- Sections are sorted by path, so each dir is emitted exactly once,
--- immediately before its first descendant.
function S.build_entries(sections, folded)
  folded = folded or {}
  local entries = {}
  local prev_dirs = {}

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
      }
    end
    prev_dirs = parts
  end

  return entries
end

--- Render entries to display lines (pure).
function S.render_lines(entries)
  local lines = {}
  for i, e in ipairs(entries) do
    local indent = ("  "):rep(e.depth)
    if e.kind == "dir" then
      lines[i] = indent .. (e.folded and "▸ " or "▾ ") .. e.name
    else
      lines[i] = indent .. e.name .. ("  +%d −%d"):format(e.adds, e.dels)
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

local function notify_change(state)
  if S.on_change then
    S.on_change(state)
  else
    S.refresh(state)
  end
end

--- Rebuild entries from the live sections + fold state and redraw.
function S.refresh(state)
  if not S.is_open() then
    return
  end
  side.entries = S.build_entries(state.sections, state.folded)
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
--- sets its files aside on the canvas too; a file scrolls the canvas to its
--- section, expanding it first if it was set aside. Never changes any window's
--- buffer or the focused window.
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

  -- "Take me to this file" has to mean you can read it when you get there, so
  -- a section that was set aside expands first -- the same interception canvas
  -- <CR> makes via init's jump_or_expand. A visible file row is never hidden
  -- by a fold (a folded dir emits no rows for its children), so its own
  -- collapse flag is the whole question. unauto + set_collapsed mirrors
  -- init.user_set_collapsed: an explicit selection is user intent, so virt
  -- must not expand or discard it later.
  local expanded = false
  if state.collapsed and state.collapsed[e.path] then
    virt.unauto(e.path)
    canvas.set_collapsed(state, e.section_i, false)
    expanded = true
  end

  local start0 = (canvas.section_rows(state, e.section_i))
  vim.api.nvim_win_call(state.win, function()
    vim.fn.winrestview({ topline = start0 + 1, lnum = start0 + 1 })
  end)
  if expanded then
    notify_change(state) -- the canvas changed shape, not just its viewport
  else
    S.sync(state)
  end
end

--- Cycle the canvas view to the next/previous section (wrapping), keeping
--- the sidebar selection in step. Usable with or without the sidebar open;
--- focus never moves.
function S.cycle(state, delta)
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
  local target = ((i - 1 + delta) % n) + 1
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
