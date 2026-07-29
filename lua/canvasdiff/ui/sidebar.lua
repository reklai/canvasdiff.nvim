local canvas = require("canvasdiff.canvas")
local render = canvas.format
local config = require("canvasdiff.config")
local keys = require("canvasdiff.input").keys
local diff = require("canvasdiff.diff")
local fold = diff.fold
local model = diff
local lens = diff.lens
local notifications = require("canvasdiff.ui.notifications")
local cheatsheet = require("canvasdiff.ui.cheatsheet")

local S = {}

--- Flatten alphabetical sections into display-ordered dir/file entries.
--- `folded` is a set of dir paths ("lua/mod/" -- cumulative, trailing
--- slash); a folded dir is shown itself but none of its descendants are.
--- Sections are sorted by path, so each dir is emitted exactly once,
--- immediately before its first descendant.
---
--- `aside` is an optional set of file paths the user folded themselves, used only
--- to flag their rows. `stale` is an optional set of paths that have changed since
--- they were folded; a DIR row carries it when anything beneath it has, which is
--- the only way the signal is visible for a folded directory -- a folded dir emits
--- no rows for its children at all. All plain tables, so this stays pure.
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
      if not slash then
        break
      end
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
            kind = "dir",
            path = prefix,
            name = parts[d] .. "/",
            depth = d - 1,
            folded = folded[prefix] or false,
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
        kind = "file",
        path = section.path,
        name = fname,
        depth = #parts,
        section_i = i,
        adds = section.adds,
        dels = section.dels,
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
function S.render_lines(entries)
  local lines = {}
  for i, e in ipairs(entries) do
    local indent = ("  "):rep(e.depth)
    local mark = e.stale and render.glyphs.stale or ""
    if e.kind == "dir" then
      lines[i] = indent
        .. (e.folded and (render.glyphs.folded .. " ") or (render.glyphs.open .. " "))
        .. render.escape_path(e.name)
        .. mark
    else
      local stage = render.stage_mark(e.staged, e.unstaged)
      if stage ~= "" then
        stage = " " .. stage
      end
      lines[i] = indent
        .. (e.aside and (render.glyphs.folded .. " ") or "  ")
        .. render.escape_path(e.name)
        .. ("  +%d " .. render.glyphs.minus .. "%d"):format(e.adds, e.dels)
        .. stage
        .. mark
    end
  end
  return lines
end

local NS = vim.api.nvim_create_namespace("canvasdiff.sidebar")
local next_lease_id = 0
local next_view_id = 0
local next_mark_id = 0

local WINDOW_OPTIONS = {
  { name = "winfixwidth", value = true },
  { name = "winfixbuf", value = true },
  { name = "wrap", value = false },
  { name = "cursorline", value = true },
  { name = "number", value = false },
  { name = "relativenumber", value = false },
  { name = "signcolumn", value = "no" },
  { name = "foldenable", value = false },
}

local function ensure_hl_groups()
  vim.api.nvim_set_hl(0, "CanvasDiffSidebarDir", {
    link = "Directory",
    default = true,
  })
  vim.api.nvim_set_hl(0, "CanvasDiffSidebarActive", {
    link = "Visual",
    default = true,
  })
  render.ensure_marker_hl()
end

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function normalize_tab(tab)
  if tab == nil or tab == 0 then
    return vim.api.nvim_get_current_tabpage()
  end
  return tab
end

-- Lookup-only authentication. Weak keys cannot keep a lease alive and, unlike
-- trusting a handful of public table fields, cannot be copied onto a forged
-- shell. It selects nothing: simultaneous Surfaces hold simultaneous sidebar
-- leases, and every live view stays reachable only from its owning lease.
local LEASE_AUTH = setmetatable({}, { __mode = "k" })

local function exact(lease)
  return type(lease) == "table"
    and LEASE_AUTH[lease] == true
    and not lease.disposed
    and (lease.phase == "attaching" or lease.phase == "active")
end

--- Owner liveness is protected and fail-closed. The identity check after the
--- callback is load-bearing: the callback itself may reentrantly replace or
--- dispose this lease.
local function active(lease)
  if not exact(lease) then
    return false
  end
  local alive = lease.callbacks and lease.callbacks.alive
  if alive then
    local ok, result = pcall(alive, lease)
    if not (ok and result) then
      return false
    end
  end
  return exact(lease)
end

--- A view is authenticated through its own lease's private per-tab map, so a
--- forged view table is unreachable even when it copies every public field of
--- a real one. Deliberately independent of `exact`: terminal teardown flips
--- the lease to "closing" before it disposes the views it still owns.
local function view_exact(lease, view)
  return type(lease) == "table"
    and type(view) == "table"
    and not view.disposed
    and view.lease == lease
    and lease.views_by_tab
    and lease.views_by_tab[view.tab] == view
end

local function view_active(lease, view)
  return active(lease) and view_exact(lease, view)
end

local function owned_pair(view)
  if not (view and valid_win(view.win) and valid_buf(view.buf)) then
    return false
  end
  local ok, showing = pcall(vim.api.nvim_win_get_buf, view.win)
  return ok and showing == view.buf
end

local function default_snapshot(lease)
  local state = lease.state
  local hosts, canvases = {}, {}
  local win = state and state.win
  if valid_win(win) then
    hosts[1] = win
    if state.buf and valid_buf(state.buf) and vim.api.nvim_win_get_buf(win) == state.buf then
      canvases[1] = win
    end
  end
  return { hosts = hosts, canvas = canvases }
end

local function sanitize_windows(lease, input, canvas_only)
  local out, seen = {}, {}
  local state = lease.state
  for _, win in ipairs(input or {}) do
    if type(win) == "number" and not seen[win] and valid_win(win) then
      local include = true
      if canvas_only then
        include = state
          and state.buf
          and valid_buf(state.buf)
          and vim.api.nvim_win_get_buf(win) == state.buf
      end
      if include then
        seen[win] = true
        out[#out + 1] = win
      end
    end
  end
  table.sort(out)
  return out
end

local function snapshot(lease)
  if not active(lease) then
    return nil
  end
  local callback = lease.callbacks and lease.callbacks.snapshot
  local observed = callback and callback(lease) or default_snapshot(lease)
  if not active(lease) then
    return nil
  end
  observed = type(observed) == "table" and observed or {}
  local result = {
    hosts = sanitize_windows(lease, observed.hosts, false),
    canvas = sanitize_windows(lease, observed.canvas, true),
  }
  local host_set = {}
  for _, win in ipairs(result.hosts) do
    host_set[win] = true
  end
  for _, win in ipairs(result.canvas) do
    if not host_set[win] then
      result.hosts[#result.hosts + 1] = win
      host_set[win] = true
    end
  end
  table.sort(result.hosts)
  return active(lease) and result or nil
end

local function windows_in_tab(windows, tab)
  local out = {}
  for _, win in ipairs(windows or {}) do
    if valid_win(win) and vim.api.nvim_win_get_tabpage(win) == tab then
      out[#out + 1] = win
    end
  end
  table.sort(out)
  return out
end

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

local function choose_window(list, remembered, preferred)
  if preferred and contains(list, preferred) then
    return preferred
  end
  if remembered and contains(list, remembered) then
    return remembered
  end
  return list[1]
end

local function update_targets(view, observed, preferred_canvas)
  local hosts = windows_in_tab(observed.hosts, view.tab)
  local canvases = windows_in_tab(observed.canvas, view.tab)
  view.host_win = choose_window(hosts, view.host_win, preferred_canvas)
  view.canvas_win = choose_window(canvases, view.canvas_win, preferred_canvas)
  return hosts, canvases
end

local function reserve_mark_id(buf)
  while true do
    next_mark_id = next_mark_id + 1
    local ok, position = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, NS, next_mark_id, {})
    if not ok or #position == 0 then
      return next_mark_id
    end
  end
end

local function mark_exists_in(buf, id)
  if not valid_buf(buf) then
    return false
  end
  local ok, position = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, NS, id, {})
  return ok and #position > 0
end

local function delete_mark(view, id)
  if not id then
    return
  end
  local buf = view.buf
  if view.deleting then
    view.deleting[id] = true
  end
  if valid_buf(buf) then
    pcall(vim.api.nvim_buf_del_extmark, buf, NS, id)
  end
  if view.deleting then
    view.deleting[id] = nil
  end
  if not mark_exists_in(buf, id) then
    if view.mark_ids then
      view.mark_ids[id] = nil
    end
    if view.pending then
      view.pending[id] = nil
    end
  end
end

local function place_mark(lease, view, row, col, opts)
  if not (view_active(lease, view) and valid_buf(view.buf)) then
    return nil
  end
  local buf = view.buf
  local id = reserve_mark_id(view.buf)
  opts = vim.tbl_extend("force", opts or {}, { id = id })
  view.pending[id] = true
  local ok, result = pcall(vim.api.nvim_buf_set_extmark, buf, NS, row, col, opts)
  if view.pending then
    view.pending[id] = nil
  end
  if not ok then
    if valid_buf(buf) then
      pcall(vim.api.nvim_buf_del_extmark, buf, NS, id)
    end
    if mark_exists_in(buf, id) and view.mark_ids then
      view.mark_ids[id] = true
    end
    error(result, 0)
  end
  if not view_active(lease, view) then
    if valid_buf(buf) then
      pcall(vim.api.nvim_buf_del_extmark, buf, NS, id)
    end
    return nil
  end
  view.mark_ids[id] = true
  return id
end

local function index_of_path(state, path)
  for i, section in ipairs(state.sections or {}) do
    if section.path == path then
      return i
    end
  end
end

local function set_modifiable(buf, value)
  vim.api.nvim_set_option_value("modifiable", value, { buf = buf })
end

local function write_lines(view, lines)
  local ok_mod, mod_err = pcall(set_modifiable, view.buf, true)
  if not ok_mod then
    error(mod_err, 0)
  end
  local ok_write, write_err = pcall(vim.api.nvim_buf_set_lines, view.buf, 0, -1, false, lines)
  local ok_restore, restore_err = pcall(set_modifiable, view.buf, false)
  if not ok_write then
    error(write_err, 0)
  end
  if not ok_restore then
    error(restore_err, 0)
  end
end

local EXTENDED_MARK_OPTIONS = {
  "end_row",
  "end_col",
  "hl_group",
  "hl_eol",
  "hl_mode",
  "virt_text",
  "virt_text_pos",
  "virt_text_win_col",
  "virt_text_hide",
  "virt_text_repeat_linebreak",
  "virt_lines",
  "virt_lines_above",
  "virt_lines_leftcol",
  "virt_lines_overflow",
  "right_gravity",
  "end_right_gravity",
  "priority",
  "strict",
  "sign_text",
  "sign_hl_group",
  "cursorline_hl_group",
  "number_hl_group",
  "line_hl_group",
  "conceal",
  "spell",
  "ui_watched",
  "undo_restore",
  "invalidate",
  "url",
}

--- Replacing all buffer lines moves even marks this lease does not own. Keep
--- foreign marks byte-for-byte at their prior coordinates and with the
--- options Neovim reports, while continuing to delete only our exact IDs.
local function snapshot_marks(view, foreign_only)
  local buf = view.buf
  local mark_ids = view.mark_ids
  local pending = view.pending
  local deleting = view.deleting
  local out = {}
  local marks = vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {
    details = true,
  })
  if view.disposed or view.buf ~= buf then
    return nil
  end
  for _, mark in ipairs(marks) do
    local id = mark[1]
    local owned = mark_ids[id] or pending[id] or deleting[id]
    if not foreign_only or not owned then
      out[#out + 1] = mark
    end
  end
  return out
end

local function restore_marks(view, marks)
  local buf = view.buf
  if not valid_buf(buf) then
    return false, "sidebar buffer disappeared while restoring extmarks"
  end
  local first_error
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    local opts = { id = mark[1] }
    for _, name in ipairs(EXTENDED_MARK_OPTIONS) do
      if details[name] ~= nil then
        opts[name] = details[name]
      end
    end
    local ok, err = pcall(
      vim.api.nvim_buf_set_extmark, buf, NS, mark[2], mark[3], opts)
    if view.disposed or view.buf ~= buf then
      return nil
    end
    if not ok and not first_error then
      first_error = err
    end
  end
  return first_error == nil, first_error
end

local sync_view

local function set_active(lease, view, section_i, path)
  if not view_active(lease, view) then
    return false
  end
  local best
  for row, entry in ipairs(view.entries or {}) do
    if
      (entry.kind == "file" and entry.section_i == section_i)
      or (entry.kind == "dir" and path:sub(1, #entry.path) == entry.path)
    then
      best = row - 1
    end
  end
  if best == nil then
    return false
  end

  local previous = view.active_mark
  local id = place_mark(lease, view, best, 0, {
    line_hl_group = "CanvasDiffSidebarActive",
    priority = 100,
  })
  if not id then
    return false
  end
  view.active_mark = id
  if previous and previous ~= id then
    delete_mark(view, previous)
  end
  if owned_pair(view) and vim.api.nvim_get_current_win() ~= view.win then
    pcall(vim.api.nvim_win_set_cursor, view.win, { best + 1, 0 })
  end
  return view_active(lease, view)
end

local function refresh_view(lease, view, observed)
  if not (view_active(lease, view) and owned_pair(view)) then
    return false
  end
  local state = lease.state
  local aside = fold.user_folded_set(state.sections, state)
  local stale = fold.stale_set(state.sections, state, model.fingerprint, lens.of(state).id)
  local entries = S.build_entries(state.sections, state.folded, aside, stale)
  local lines = S.render_lines(entries)
  if #lines == 0 then
    lines = { "" }
  end

  local old_lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
  local marks_before = snapshot_marks(view, false)
  if not marks_before or not view_active(lease, view) then
    return false
  end
  local foreign = snapshot_marks(view, true)
  if not foreign or not view_active(lease, view) then
    return false
  end
  local old_ids = {}
  for id in pairs(view.mark_ids) do
    old_ids[id] = true
  end
  local new_ids = {}

  local ok_write, write_err = pcall(write_lines, view, lines)
  if not ok_write then
    if valid_buf(view.buf) then
      pcall(write_lines, view, old_lines)
      restore_marks(view, marks_before)
    end
    error(write_err, 0)
  end
  if not view_active(lease, view) then
    return false
  end
  local foreign_ok, foreign_err = restore_marks(view, foreign)
  if foreign_ok == nil or not view_active(lease, view) then
    return false
  end
  if not foreign_ok then
    if valid_buf(view.buf) then
      pcall(write_lines, view, old_lines)
      restore_marks(view, marks_before)
    end
    error(foreign_err, 0)
  end
  if not view_active(lease, view) then
    return false
  end

  local ok, err = pcall(function()
    for row, entry in ipairs(entries) do
      if entry.kind == "dir" then
        local id = place_mark(lease, view, row - 1, 0, {
          line_hl_group = "CanvasDiffSidebarDir",
          priority = 90,
        })
        if id then
          new_ids[id] = true
        end
      end
      local line = lines[row] or ""
      local is_file = entry.kind ~= "dir"
      local spans = render.marker_spans(
        line,
        is_file and entry.staged or nil,
        is_file and entry.unstaged or nil,
        entry.stale
      )
      for _, span in ipairs(spans) do
        local id = place_mark(lease, view, row - 1, span[1], {
          end_row = row - 1,
          end_col = span[2],
          hl_group = span[3],
          priority = 101,
        })
        if id then
          new_ids[id] = true
        end
      end
    end
  end)
  if not ok then
    for id in pairs(new_ids) do
      delete_mark(view, id)
    end
    if valid_buf(view.buf) then
      pcall(write_lines, view, old_lines)
      restore_marks(view, marks_before)
    end
    error(err, 0)
  end
  if not view_active(lease, view) then
    return false
  end

  for id in pairs(old_ids) do
    delete_mark(view, id)
  end
  view.entries = entries
  view.active_mark = nil
  view.render_epoch = view.render_epoch + 1
  return sync_view(lease, view, observed)
end

sync_view = function(lease, view, observed, preferred_canvas)
  if not (view_active(lease, view) and owned_pair(view)) then
    return false
  end
  observed = observed or snapshot(lease)
  if not observed or not view_active(lease, view) then
    return false
  end
  update_targets(view, observed, preferred_canvas)
  local win = view.canvas_win
  local state = lease.state
  if
    not (
      win
      and valid_win(win)
      and valid_buf(state.buf)
      and vim.api.nvim_win_get_buf(win) == state.buf
    )
  then
    return false
  end

  local ok, top0 = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.line("w0") - 1
  end)
  if not ok then
    error(top0, 0)
  end
  if not view_active(lease, view) then
    return false
  end
  if type(top0) ~= "number" then
    return false
  end
  local section_i = canvas.locate(state, top0)
  local section = section_i and state.sections[section_i]
  if not section or not set_active(lease, view, section_i, section.path) then
    return false
  end

  local callback = lease.callbacks and lease.callbacks.on_locate
  if callback then
    callback(lease, state, win, section.path)
  end
  return view_active(lease, view)
end

local function restore_surviving_window(view, win, buf)
  if not (valid_win(win) and valid_buf(buf) and vim.api.nvim_win_get_buf(win) == buf) then
    return
  end

  -- The buffer must be replaceable before the old sidebar buffer can be
  -- deleted. This is safe only while the exact owned pair still exists.
  local winfixbuf_owned = false
  local ok_fixed, fixed = pcall(
    vim.api.nvim_get_option_value, "winfixbuf", { win = win })
  if ok_fixed then
    winfixbuf_owned = fixed == view.applied_options.winfixbuf
  end
  pcall(vim.api.nvim_set_option_value, "winfixbuf", false, {
    win = win,
    scope = "local",
  })
  local ok_scratch, scratch = pcall(vim.api.nvim_create_buf, true, true)
  if ok_scratch then
    local ok_set = pcall(vim.api.nvim_win_set_buf, win, scratch)
    if not ok_set and valid_buf(scratch) then
      pcall(vim.api.nvim_buf_delete, scratch, { force = true })
    end
  end

  for _, option in ipairs(WINDOW_OPTIONS) do
    local prior = view.prior_options[option.name]
    local applied = view.applied_options[option.name]
    local restore = option.name == "winfixbuf" and winfixbuf_owned
    local ok, actual
    if option.name ~= "winfixbuf" then
      ok, actual = pcall(vim.api.nvim_get_option_value, option.name, { win = win })
      restore = ok and actual == applied
    end
    if restore then
      pcall(vim.api.nvim_set_option_value, option.name, prior, {
        win = win,
        scope = "local",
      })
    end
  end
end

local function close_view(lease, view, dismiss)
  if not view_exact(lease, view) then
    return false
  end
  local tab, win, buf = view.tab, view.win, view.buf
  lease.views_by_tab[tab] = nil
  if win then
    lease.views_by_win[win] = nil
  end
  if dismiss then
    lease.dismissed_tabs[tab] = true
  end
  view.disposed = true
  view.phase = "closing"

  for _, autocmd_id in ipairs(view.autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, autocmd_id)
  end
  for _, lhs in ipairs(view.keymaps) do
    if valid_buf(buf) then
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
  end
  local ids = {}
  for id in pairs(view.mark_ids) do
    ids[id] = true
  end
  for id in pairs(view.pending) do
    ids[id] = true
  end
  for id in pairs(view.deleting) do
    ids[id] = true
  end
  for id in pairs(ids) do
    delete_mark(view, id)
  end

  local pair = owned_pair(view)
  if pair then
    pcall(vim.api.nvim_win_close, win, true)
    if owned_pair(view) then
      restore_surviving_window(view, win, buf)
    end
  end
  if valid_buf(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  view.lease = nil
  view.entries = nil
  view.keymaps = nil
  view.autocmd_ids = nil
  view.mark_ids = nil
  view.pending = nil
  view.deleting = nil
  view.prior_options = nil
  view.applied_options = nil
  view.win = nil
  view.buf = nil
  view.host_win = nil
  view.canvas_win = nil
  view.phase = "disposed"
  return true
end

local function defer_reconcile(lease)
  if not active(lease) then
    return
  end
  lease.reconcile_ticket = lease.reconcile_ticket + 1
  local ticket = lease.reconcile_ticket
  vim.schedule(function()
    if active(lease) and ticket == lease.reconcile_ticket then
      S.reconcile(lease)
    end
  end)
end

local function create_autocmd(lease, events, spec, sink)
  spec.group = lease.group_name
  local id = vim.api.nvim_create_autocmd(events, spec)
  if not exact(lease) then
    pcall(vim.api.nvim_del_autocmd, id)
    error("sidebar open was superseded while creating autocmds", 0)
  end
  sink[#sink + 1] = id
  return id
end

local function install_lease_autocmds(lease)
  create_autocmd(lease, { "BufWinEnter", "BufWinLeave" }, {
    buffer = lease.state.buf,
    callback = function()
      defer_reconcile(lease)
    end,
  }, lease.autocmd_ids)
  create_autocmd(lease, { "WinClosed", "WinResized", "TabClosed" }, {
    callback = function()
      defer_reconcile(lease)
    end,
  }, lease.autocmd_ids)
  create_autocmd(lease, "WinScrolled", {
    callback = function(event)
      if active(lease) then
        S.sync(lease, tonumber(event.match))
      end
    end,
  }, lease.autocmd_ids)
  create_autocmd(lease, "WinEnter", {
    callback = function()
      if active(lease) then
        S.sync(lease, vim.api.nvim_get_current_win())
      end
    end,
  }, lease.autocmd_ids)
end

local function create_view(lease, tab, host_win, observed)
  next_view_id = next_view_id + 1
  local view = {
    id = next_view_id,
    lease = lease,
    tab = tab,
    phase = "creating",
    disposed = false,
    host_win = host_win,
    canvas_win = nil,
    buf = nil,
    win = nil,
    entries = {},
    keymaps = {},
    autocmd_ids = {},
    mark_ids = {},
    pending = {},
    deleting = {},
    active_mark = nil,
    prior_options = {},
    applied_options = {},
    render_epoch = 0,
  }
  lease.views_by_tab[tab] = view

  local ok, err = pcall(function()
    local buf = vim.api.nvim_create_buf(false, true)
    if not view_active(lease, view) then
      if valid_buf(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      error("sidebar open was superseded while creating a buffer", 0)
    end
    view.buf = buf
    vim.api.nvim_buf_set_name(buf, ("canvasdiff://sidebar/%d/%d"):format(lease.id, view.id))
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
    set_modifiable(buf, false)

    local win = vim.api.nvim_open_win(buf, false, {
      split = "left",
      width = lease.width,
      win = host_win,
    })
    if not view_active(lease, view) then
      if valid_win(win) and vim.api.nvim_win_get_buf(win) == buf then
        pcall(vim.api.nvim_win_close, win, true)
      end
      if valid_buf(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      error("sidebar open was superseded while creating a window", 0)
    end
    view.win = win
    lease.views_by_win[win] = view

    for _, option in ipairs(WINDOW_OPTIONS) do
      view.prior_options[option.name] = vim.api.nvim_get_option_value(option.name, { win = win })
      view.applied_options[option.name] = option.value
      vim.api.nvim_set_option_value(option.name, option.value, {
        win = win,
        scope = "local",
      })
    end

    local actions = {
      select = function()
        if view_active(lease, view) then
          S.select(lease, view.win)
        end
      end,
      close = function()
        if view_active(lease, view) then
          close_view(lease, view, true)
        end
      end,
      help = function()
        if view_active(lease, view) then
          cheatsheet.toggle()
        end
      end,
      stage_cycle = function()
        if not view_active(lease, view) then
          return
        end
        local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, view.win)
        local entry = ok_cursor and view.entries[cursor[1]] or nil
        if not entry then
          return
        end
        if entry.kind == "dir" then
          notifications.warn("directory rows cannot be staged or unstaged")
          return
        end
        local callback = lease.callbacks and lease.callbacks.on_stage_cycle
        if callback then
          callback(lease, lease.state, entry.path)
        end
      end,
    }
    for _, mapping in ipairs(keys.resolved("sidebar", config.options.keymaps)) do
      local callback = actions[mapping.action]
      if callback then
        vim.keymap.set("n", mapping.lhs, callback, {
          buffer = buf,
          silent = true,
          noremap = true,
          desc = mapping.desc,
        })
        view.keymaps[#view.keymaps + 1] = mapping.lhs
      end
    end

    create_autocmd(lease, "BufWipeout", {
      buffer = buf,
      callback = function()
        defer_reconcile(lease)
      end,
    }, view.autocmd_ids)

    view.phase = "active"
    update_targets(view, observed)
    refresh_view(lease, view, observed)
  end)
  if not ok then
    if view_exact(lease, view) then
      close_view(lease, view, false)
    end
    error(err, 0)
  end
  return view
end

function S.reconcile(lease)
  if not active(lease) then
    return false
  end
  local observed = snapshot(lease)
  if not observed or not active(lease) then
    return false
  end

  local hosts_by_tab = {}
  for _, win in ipairs(observed.hosts) do
    local tab = vim.api.nvim_win_get_tabpage(win)
    hosts_by_tab[tab] = hosts_by_tab[tab] or {}
    hosts_by_tab[tab][#hosts_by_tab[tab] + 1] = win
  end

  local existing = {}
  for _, view in pairs(lease.views_by_tab) do
    existing[#existing + 1] = view
  end
  for _, view in ipairs(existing) do
    local tab_ok = vim.api.nvim_tabpage_is_valid(view.tab)
    local hosts = hosts_by_tab[view.tab]
    if not tab_ok or not hosts or #hosts == 0 then
      close_view(lease, view, false)
    elseif not owned_pair(view) then
      close_view(lease, view, true)
    else
      update_targets(view, observed)
    end
  end

  local tabs = {}
  for tab in pairs(hosts_by_tab) do
    tabs[#tabs + 1] = tab
  end
  table.sort(tabs)
  for _, tab in ipairs(tabs) do
    if not active(lease) then
      return false
    end
    local view = lease.views_by_tab[tab]
    if view then
      update_targets(view, observed)
    elseif not lease.dismissed_tabs[tab] then
      local canvases = windows_in_tab(observed.canvas, tab)
      local hosts = hosts_by_tab[tab]
      local host = canvases[1] or hosts[1]
      create_view(lease, tab, host, observed)
    end
  end
  return active(lease)
end

function S.refresh(lease)
  if not active(lease) then
    return false
  end
  S.reconcile(lease)
  if not active(lease) then
    return false
  end
  local observed = snapshot(lease)
  if not observed then
    return false
  end
  local refreshed = false
  local views = {}
  for _, view in pairs(lease.views_by_tab) do
    views[#views + 1] = view
  end
  table.sort(views, function(a, b)
    return a.tab < b.tab
  end)
  for _, view in ipairs(views) do
    if refresh_view(lease, view, observed) then
      refreshed = true
    end
  end
  return refreshed
end

function S.sync(lease, canvas_win)
  if not active(lease) then
    return false
  end
  local observed = snapshot(lease)
  if not observed then
    return false
  end
  if canvas_win and valid_win(canvas_win) then
    local tab = vim.api.nvim_win_get_tabpage(canvas_win)
    local view = lease.views_by_tab[tab]
    return view and sync_view(lease, view, observed, canvas_win) or false
  end

  local synced = false
  local views = {}
  for _, view in pairs(lease.views_by_tab) do
    views[#views + 1] = view
  end
  table.sort(views, function(a, b)
    return a.tab < b.tab
  end)
  for _, view in ipairs(views) do
    if sync_view(lease, view, observed) then
      synced = true
    end
  end
  return synced
end

function S.mark_path(lease, path, source_win)
  if not (active(lease) and path) then
    return false
  end
  local state = lease.state
  local section_i = index_of_path(state, path)
  if not section_i then
    return false
  end
  local source_tab = source_win
      and valid_win(source_win)
      and vim.api.nvim_win_get_tabpage(source_win)
    or nil
  local marked = false
  for tab, view in pairs(lease.views_by_tab) do
    if (source_tab == nil or source_tab == tab) and set_active(lease, view, section_i, path) then
      marked = true
    end
  end
  return marked
end

local function view_for_selection(lease, side_win)
  if side_win then
    local direct = lease.views_by_win[side_win]
    if direct and owned_pair(direct) then
      return direct
    end
  end
  local current = vim.api.nvim_get_current_win()
  if valid_win(current) then
    local tab = vim.api.nvim_win_get_tabpage(current)
    local local_view = lease.views_by_tab[tab]
    if local_view and owned_pair(local_view) then
      return local_view
    end
  end
  for _, view in pairs(lease.views_by_tab) do
    if owned_pair(view) then
      return view
    end
  end
end

function S.select(lease, side_win)
  if not active(lease) then
    return false
  end
  local view = view_for_selection(lease, side_win)
  if not view then
    return false
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, view.win)
  if not ok or not view_active(lease, view) then
    return false
  end
  local entry = view.entries[cursor[1]]
  if not entry then
    return false
  end
  local state = lease.state
  local observed = snapshot(lease)
  if not observed then
    return false
  end
  update_targets(view, observed)

  if entry.kind == "dir" then
    if not (state.buf and valid_buf(state.buf)) then
      return false
    end
    local previous = state.folded[entry.path]
    if previous then
      state.folded[entry.path] = nil
    else
      state.folded[entry.path] = true
    end
    local ok_resync, resync_err = pcall(
      canvas.resync_visibility,
      state,
      fold.indices_under(state.sections, entry.path),
      view.canvas_win
    )
    if not ok_resync then
      state.folded[entry.path] = previous
      pcall(
        canvas.resync_visibility,
        state,
        fold.indices_under(state.sections, entry.path),
        view.canvas_win
      )
      error(resync_err, 0)
    end
    if not view_active(lease, view) then
      return false
    end
    local callback = lease.callbacks and lease.callbacks.on_shape_change
    if callback then
      callback(lease, state, view.canvas_win)
    else
      S.refresh(lease)
    end
    return view_active(lease, view)
  end

  local path = entry.path
  if not view.canvas_win then
    local callback = lease.callbacks and lease.callbacks.on_return
    if not callback or not view.host_win then
      return false
    end
    local returned = callback(lease, state, view.host_win)
    if not (returned and view_active(lease, view)) then
      return false
    end
    observed = snapshot(lease)
    if not observed or not view_active(lease, view) then
      return false
    end
    update_targets(view, observed, view.host_win)
  end

  local section_i = index_of_path(state, path)
  if not section_i then
    notifications.notify(path .. " has no changes any more")
    return false
  end
  local win = view.canvas_win
  if not (win and valid_win(win) and vim.api.nvim_win_get_buf(win) == state.buf) then
    return false
  end
  local start0 = canvas.section_rows(state, section_i)
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = start0 + 1, lnum = start0 + 1 })
  end)
  return view_active(lease, view) and sync_view(lease, view, observed, win)
end

function S.is_open(lease, tab)
  if not active(lease) then
    return false
  end
  if tab ~= nil then
    local view = lease.views_by_tab[normalize_tab(tab)]
    return view ~= nil and owned_pair(view)
  end
  for _, view in pairs(lease.views_by_tab) do
    if owned_pair(view) then
      return true
    end
  end
  return false
end

function S.is_sidebar_win(lease, win)
  if not (active(lease) and valid_win(win)) then
    return false
  end
  local view = lease.views_by_win[win]
  return view ~= nil and view_exact(lease, view) and view.win == win and owned_pair(view)
end

--- Open one Surface-owned Sidebar lease. A lease owns one view per host tab;
--- no module-global "current" identity exists, so independent owners cannot
--- erase or redirect one another.
function S.open(state, opts, callbacks)
  next_lease_id = next_lease_id + 1
  opts = opts or {}
  local lease = {
    id = next_lease_id,
    phase = "attaching",
    disposed = false,
    state = state,
    opts = opts,
    callbacks = callbacks or {},
    width = opts.width or 32,
    group_name = "canvasdiff.sidebar." .. next_lease_id,
    autocmd_ids = {},
    views_by_tab = {},
    views_by_win = {},
    dismissed_tabs = {},
    reconcile_ticket = 0,
    claimed = false,
  }
  -- Publish exact identity before the first external call, so a reentrant
  -- callback can dispose only this partial lease.
  LEASE_AUTH[lease] = true

  local claim = lease.callbacks.claim
  if claim then
    -- Treat a throwing claim as potentially committed: a callback can publish
    -- this lease and then fault. Exact close will ask release() to undo only
    -- that identity, while a clean `false` remains an unclaimed rejection.
    lease.claimed = true
    local ok_claim, claimed = pcall(claim, lease)
    if not ok_claim then
      pcall(S.close, lease)
      error(claimed, 0)
    end
    if not claimed then
      lease.claimed = false
      LEASE_AUTH[lease] = nil
      lease.phase = "disposed"
      lease.disposed = true
      lease.state = nil
      lease.callbacks = {}
      return nil
    end
  else
    lease.claimed = true
  end

  local ok, err = pcall(function()
    if not active(lease) then
      error("sidebar owner is no longer alive", 0)
    end
    ensure_hl_groups()
    if not active(lease) then
      error("sidebar open was superseded while defining highlights", 0)
    end
    vim.api.nvim_create_augroup(lease.group_name, { clear = true })
    if not active(lease) then
      pcall(vim.api.nvim_del_augroup_by_name, lease.group_name)
      error("sidebar open was superseded while creating its group", 0)
    end
    install_lease_autocmds(lease)
    S.reconcile(lease)
    if not active(lease) then
      error("sidebar open was superseded during initial reconciliation", 0)
    end
    lease.phase = "active"
  end)
  if not ok then
    pcall(S.close, lease)
    error(err, 0)
  end
  return lease
end

--- Terminal, exact, idempotent teardown for one Sidebar lease.
function S.close(lease)
  if not exact(lease) then
    return false
  end
  LEASE_AUTH[lease] = nil
  lease.phase = "closing"
  lease.disposed = true
  lease.reconcile_ticket = lease.reconcile_ticket + 1

  local views = {}
  for _, view in pairs(lease.views_by_tab) do
    views[#views + 1] = view
  end
  local first_error
  for _, view in ipairs(views) do
    local ok, err = pcall(close_view, lease, view, false)
    if not ok and not first_error then
      first_error = err
    end
  end

  local group_deleted = pcall(vim.api.nvim_del_augroup_by_name, lease.group_name)
  if not group_deleted then
    for _, id in ipairs(lease.autocmd_ids) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
  end

  local release = lease.callbacks and lease.callbacks.release
  lease.state = nil
  lease.opts = nil
  lease.callbacks = {}
  lease.autocmd_ids = {}
  lease.views_by_tab = {}
  lease.views_by_win = {}
  lease.dismissed_tabs = {}
  lease.phase = "disposed"
  if release and lease.claimed then
    local ok, err = pcall(release, lease)
    if not ok and not first_error then
      first_error = err
    end
  end
  if first_error then
    error(first_error, 0)
  end
  return true
end

return S
