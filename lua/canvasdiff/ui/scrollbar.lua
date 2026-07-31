local canvas = require("canvasdiff.canvas")
local render = canvas.format
local fold = require("canvasdiff.diff").fold

local S = {}

--- The minimap's two glyphs: a file boundary and a stretch of changed lines.
---
--- ‒ (U+2012 FIGURE DASH) and ❘ (U+2758 LIGHT VERTICAL BAR) rather than the
--- box-drawing ─ and │ they replace, and the reason is WIDTH, not looks.
---
--- This float is ONE column wide. Every box-drawing and block-element glyph is East
--- Asian Ambiguous, so under `ambiwidth=double` -- which CJK users set, and which is a
--- legitimate setting rather than a misconfiguration -- ─ and │ become two cells and
--- cannot fit the window they are drawn in. Measured: 13 of 21 rows held a two-cell
--- glyph in a width-1 float. These two are the most solid-looking glyphs that stay one
--- cell in BOTH modes, so the minimap is correct either way with no detection needed.
---
--- Named rather than inlined so the tests assert against these instead of their own
--- copies of the literals -- they did, and both drifted the moment these changed.
---
--- Keep any replacement width-stable: check `vim.fn.strwidth` under both `ambiwidth`
--- values before swapping one in. ─ ━ │ ┃ ▏ ▎ ▕ ┆ – — ‾ all fail that test.

--- One kind per canvas line, sections in render order. hunk_hdr counts as
--- "ctx" (structural, uncolored); file_hdr becomes "hdr" (boundary rows). A
--- folded section (`hidden[section.path]` truthy) renders as its single
--- placeholder row -- exactly one "hdr" entry. Callers build the set with
--- fold.hidden_set, which keeps this function pure over plain tables;
--- `hidden` is optional so pre-Tier-2 callers keep working unchanged.
function S.line_kinds(sections, hidden)
  hidden = hidden or {}
  local kinds = {}
  for _, section in ipairs(sections) do
    if hidden[section.path] then
      kinds[#kinds + 1] = "hdr"
    else
      for _, e in ipairs(section.entries) do
        if e.kind == "file_hdr" then
          kinds[#kinds + 1] = "hdr"
        elseif e.ghosts or e.ghosts_after then
          -- Deletions are not rows any more -- they ride on the row that follows them
          -- as virtual lines. Without this branch the minimap would lose every trace
          -- of deletion density, because there is no "del" row left to count. "mod"
          -- means this row carries both: a replaced line reads as add AND del, which
          -- is what it actually is.
          kinds[#kinds + 1] = "mod"
        elseif e.kind == "add" or e.kind == "del" then
          kinds[#kinds + 1] = e.kind
        else
          kinds[#kinds + 1] = "ctx"
        end
      end
    end
  end
  return kinds
end

--- Bucket per-line kinds into `height` display cells. Row r (1-based)
--- covers 0-based canvas lines [floor((r-1)*n/H), floor(r*n/H)).
--- cell = { char, hl (nil = blank), thumb } per the phase contract.
function S.column(kinds, height, top0, bot0)
  local cells = {}
  if height <= 0 then
    return cells
  end
  local n = #kinds

  for r = 1, height do
    local lo = math.floor((r - 1) * n / height)
    local hi = math.floor(r * n / height) -- exclusive

    local has_hdr, has_add, has_del = false, false, false
    for i = lo + 1, hi do
      local k = kinds[i]
      if k == "hdr" then
        has_hdr = true
      elseif k == "add" then
        has_add = true
      elseif k == "del" then
        has_del = true
      elseif k == "mod" then
        -- One row carrying both facts: an added line with deleted lines ghosted above
        -- it. Counting it as add-only would make every modification look like pure
        -- growth on the minimap.
        has_add, has_del = true, true
      end
    end

    local char, hl = " ", nil
    if has_hdr then
      char, hl = render.glyphs.scroll_file, "CanvasDiffScrollFile"
    elseif has_add and has_del then
      char, hl = render.glyphs.scroll_bar, "CanvasDiffScrollChanged"
    elseif has_add then
      char, hl = render.glyphs.scroll_bar, "CanvasDiffScrollAdd"
    elseif has_del then
      char, hl = render.glyphs.scroll_bar, "CanvasDiffScrollDel"
    end

    -- Thumb: this row's non-empty bucket intersects the viewport line
    -- range. Empty buckets (lo == hi, when n < height) are blank and never
    -- claim the thumb.
    local thumb = hi > lo and lo <= bot0 and hi > top0

    cells[r] = { char = char, hl = hl, thumb = thumb }
  end

  return cells
end

--- The pure inverse of the thumb: which topline does bar row `bar_row` name?
---
--- The float is exactly the canvas window's text height, so `bar_height`
--- doubles as the viewport height and the answer ranges over the real scroll
--- range [1, total - height + 1] -- the same positions the thumb itself can
--- occupy. Row 1 means "top of the canvas", the last row means "the last full
--- screen", and everything between is linear interpolation, rounded to the
--- nearest topline.
---
--- Clamped on every side, because drag events keep firing after the pointer
--- leaves the bar (spike Q3) and arrive carrying out-of-range rows.
function S.locate(bar_row, bar_height, total_lines)
  if type(bar_height) ~= "number" or bar_height <= 1 then
    return 1
  end
  local total = math.max(type(total_lines) == "number" and total_lines or 1, 1)
  local max_top = math.max(total - bar_height + 1, 1)
  local row = math.min(math.max(type(bar_row) == "number" and bar_row or 1, 1), bar_height)
  local top = 1 + math.floor((row - 1) * (max_top - 1) / (bar_height - 1) + 0.5)
  return math.min(math.max(top, 1), max_top)
end

local NS = vim.api.nvim_create_namespace("canvasdiff.scrollbar")
local next_lease_id = 0

-- Lookup-only authentication. Weak keys cannot keep a lease alive and, unlike
-- trusting a handful of public table fields, cannot be copied onto a forged
-- shell. All live resources remain reachable only from their owning lease.
local LEASE_AUTH = setmetatable({}, { __mode = "k" })

local function exact(lease)
  return type(lease) == "table"
    and LEASE_AUTH[lease] == true
    and not lease.disposed
    and (lease.phase == "attaching" or lease.phase == "active")
end

--- Add the Surface generation fence to exact lease authentication. The
--- callback is allowed to tear the lease down reentrantly, so exactness is
--- checked again after it returns.
local function active(lease)
  if not exact(lease) then
    return false
  end
  local alive = lease.callbacks and lease.callbacks.alive
  if not alive then
    return true
  end
  local ok, result = pcall(alive, lease)
  return ok and result and exact(lease) or false
end

local function ensure_hl_groups()
  vim.api.nvim_set_hl(0, "CanvasDiffScrollFile", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffScrollAdd", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffScrollDel", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffScrollChanged", { link = "DiffChange", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffScrollThumb", { link = "PmenuThumb", default = true })
end

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function owned_window(lease)
  if not (active(lease) and valid_win(lease.win) and valid_buf(lease.buf)) then
    return false
  end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, lease.win)
  return ok and buf == lease.buf and active(lease)
end

function S.is_open(lease)
  return owned_window(lease)
end

local canvas_showing = canvas.win_showing_canvas

--- The canvas window's TEXT geometry: how many rows actually hold buffer lines, and
--- how far down the first of them starts.
---
--- Verified empirically: `nvim_win_get_height` INCLUDES the winbar row, while
--- `getwininfo().height` excludes it -- and a float opened `relative = "win", row = 0`
--- lands at the window's origin, i.e. on top of the winbar. So a full-height
--- right-edge float sized from nvim_win_get_height is one row too tall AND one row
--- too high the moment a winbar exists, which it now does (App sets one to show the
--- current lens). Both numbers have to come from getwininfo.
local function text_geometry(win)
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return { height = 0, row = 0 }
  end
  return { height = info.height, row = info.winbar or 0 }
end

local function float_config(state)
  local geo = text_geometry(state.win)
  return {
    relative = "win",
    win = state.win,
    row = geo.row,
    col = vim.api.nvim_win_get_width(state.win) - 1,
    width = 1,
    height = geo.height,
    focusable = false,
    style = "minimal",
    zindex = 40,
  }
end

-- ---------------------------------------------------------------------------
-- Mouse: thumb dragging and track jumps.
--
-- Routing is the spike's answer (spikes/2026-08-01-minimap-click-routing): the
-- non-focusable float is mouse-transparent, so press/drag/release over it
-- dispatch on the CANVAS buffer -- that is where the mappings live, and
-- mappings on the float's own buffer would be dead code. They are EXPR
-- mappings so that "not ours" behaves exactly as if no mapping existed:
-- returning the key (noremap) hands the event to the default -- cursor
-- placement keeps working, and a double click still arrives as its own
-- <2-LeftMouse> key, so the jump mapping is untouched. With 'mouse' empty no
-- event ever reaches these handlers and the feature is simply inert.
-- ---------------------------------------------------------------------------

--- The 1-based bar row under the pointer, or nil when the pointer is off the
--- bar (which is the fall-through signal).
---
--- Per spike Q2 the float NEVER appears in getmousepos(): `winid` is the
--- canvas window beneath, so the hit-test is column math on the canvas --
--- `wincol == width` means the bar column (the float covers the canvas's last
--- column), and `winrow` counts the winbar, which is subtracted off. Never
--- `pos.line`: deletion ghosts are virtual lines, so buffer lines and screen
--- rows diverge under the pointer.
local function bar_row_under_pointer(lease)
  if not owned_window(lease) then
    return nil
  end
  local state = lease.state
  if type(state) ~= "table" or not valid_win(state.win) then
    return nil
  end
  local pos = vim.fn.getmousepos()
  if pos.winid ~= state.win
      or pos.wincol ~= vim.api.nvim_win_get_width(state.win) then
    return nil
  end
  local geo = text_geometry(state.win)
  local row = pos.winrow - geo.row
  if row < 1 or row > geo.height then
    return nil
  end
  return row, geo.height
end

--- Scroll the canvas so `bar_row` names its topline, one main-loop tick from
--- now. Deferred because expr-mapping evaluation holds the textlock, where a
--- view change silently does not stick (measured: winrestview succeeds and
--- the topline stays put). The topline is recomputed at apply time -- a
--- splice may have changed the line count since the event.
---
--- The cursor rides along, clamped into the new screenful: a topline the
--- cursor is not inside is normalized away on the next redraw (measured), so
--- scrubbing without moving the cursor would visibly snap back.
local function scrub(lease, bar_row, bar_height)
  vim.schedule(function()
    if not active(lease) then
      return
    end
    local state = lease.state
    if type(state) ~= "table"
        or not (valid_win(state.win) and valid_buf(state.buf))
        or not canvas_showing(state) then
      return
    end
    local total = vim.api.nvim_buf_line_count(state.buf)
    local top = S.locate(bar_row, bar_height, total)
    vim.api.nvim_win_call(state.win, function()
      local last = math.min(top + text_geometry(state.win).height - 1, total)
      local lnum = math.min(math.max(vim.fn.line("."), top), last)
      vim.fn.winrestview({ topline = top, lnum = lnum })
    end)
    if active(lease) then
      -- WinScrolled follows on the next redraw in a live session, but keep
      -- the thumb honest even where it never fires (headless).
      S.update(lease)
    end
  end)
end

--- <LeftMouse>: press on the thumb arms a drag; press on the track jumps
--- once to that row's proportional position (and owns the rest of the
--- gesture, so a follow-up drag scrubs from where the thumb just landed
--- instead of falling into a half-default visual drag). Anything off the bar
--- falls through untouched.
local function on_press(lease)
  local row, height = bar_row_under_pointer(lease)
  if not row then
    lease.drag = nil
    return "<LeftMouse>"
  end
  -- A plain armed flag: drags recompute the live height themselves (the
  -- window may resize mid-gesture), so nothing from press time is carried.
  lease.drag = true
  local thumb = lease.thumb
  if not (thumb and row >= thumb.lo and row <= thumb.hi) then
    scrub(lease, row, height)
  end
  return "<Ignore>"
end

--- <LeftDrag>: while armed, scrub live. The pointer may have wandered off
--- the bar -- drags keep firing (spike Q3) and may resolve to a different
--- window entirely, so the row comes from SCREEN coordinates against the
--- float's own position and is clamped to the bar's ends.
local function on_drag(lease)
  if not lease.drag then
    return "<LeftDrag>"
  end
  if not owned_window(lease) then
    lease.drag = nil
    return "<LeftDrag>"
  end
  local fpos = vim.fn.win_screenpos(lease.win)
  local height = vim.api.nvim_win_get_height(lease.win)
  local row = math.min(
    math.max(vim.fn.getmousepos().screenrow - fpos[1] + 1, 1), height)
  scrub(lease, row, height)
  return "<Ignore>"
end

--- <LeftRelease>: disarm a gesture this lease owns; otherwise untouched.
local function on_release(lease)
  if not lease.drag then
    return "<LeftRelease>"
  end
  lease.drag = nil
  return "<Ignore>"
end

local function norm_lhs(lhs)
  return vim.fn.keytrans(vim.keycode(lhs))
end

--- Buffer-local expr mappings on the canvas buffer, coexisting with the
--- keymaps system: a lhs anything else already claimed there (a user binding
--- an action to <LeftMouse>, say) is left alone, and close removes only what
--- this lease itself installed.
local function install_mouse(lease)
  local state = lease.state
  local buf = type(state) == "table" and state.buf or nil
  if not valid_buf(buf) then
    return
  end
  local handlers = {
    ["<LeftMouse>"] = function() return on_press(lease) end,
    ["<LeftDrag>"] = function() return on_drag(lease) end,
    ["<LeftRelease>"] = function() return on_release(lease) end,
  }
  local taken = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    taken[norm_lhs(m.lhs)] = true
  end
  lease.mouse_lhs = {}
  for lhs, handler in pairs(handlers) do
    if not taken[norm_lhs(lhs)] then
      vim.keymap.set("n", lhs, handler, {
        buffer = buf,
        expr = true,
        desc = "CanvasDiff: minimap scrollbar drag / track jump",
      })
      lease.mouse_lhs[#lease.mouse_lhs + 1] = lhs
    end
  end
end

local function remove_mouse(lease, buf)
  if valid_buf(buf) then
    for _, lhs in ipairs(lease.mouse_lhs or {}) do
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
  end
  lease.mouse_lhs = nil
end

local function hide(lease)
  if not exact(lease) then
    return false
  end
  local win = lease.win
  local buf = lease.buf
  -- Unlink before the external close. WinClosed callbacks and test doubles may
  -- reenter teardown, and neither path may observe this window as still owned.
  lease.win = nil
  if valid_win(win) then
    local ok, showing = pcall(vim.api.nvim_win_get_buf, win)
    if ok and showing == buf then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  return exact(lease)
end

--- Redraw (and re-show/reposition if needed) the bar for the live canvas.
--- Never opened yet or canvas hidden => hide/no-op; the lease survives
--- hiding so BufWinEnter can re-show it.
function S.update(lease, state)
  if not active(lease) then
    return false
  end
  if state ~= nil then
    lease.state = state
  end
  state = lease.state
  if type(state) ~= "table" then
    return false
  end
  if not canvas_showing(state) then
    hide(lease)
    return false
  end

  -- A squashed window (winminheight=0) reports height 0; a zero-height
  -- float is invalid. Hide and let WinResized/BufWinEnter re-show later.
  if text_geometry(state.win).height < 1 then
    hide(lease)
    return false
  end

  if not valid_buf(lease.buf) then
    local buf = vim.api.nvim_create_buf(false, true)
    if not active(lease) then
      if valid_buf(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      return false
    end
    lease.buf = buf
    vim.api.nvim_buf_set_name(buf, ("canvasdiff://scrollbar/%d"):format(lease.id))
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
    if not active(lease) then
      return false
    end
  end
  if not owned_window(lease) then
    local win = vim.api.nvim_open_win(lease.buf, false, float_config(state))
    if not active(lease) then
      if valid_win(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
      return false
    end
    lease.win = win
  else
    vim.api.nvim_win_set_config(lease.win, float_config(state))
    if not active(lease) then
      return false
    end
  end

  local info = vim.api.nvim_win_call(state.win, function()
    return { top0 = vim.fn.line("w0") - 1, bot0 = vim.fn.line("w$") - 1 }
  end)
  if not active(lease) then
    return false
  end
  local height = text_geometry(state.win).height
  local hidden = fold.hidden_set(state.sections, state.collapsed, state.folded)
  local cells = S.column(S.line_kinds(state.sections, hidden), height, info.top0, info.bot0)

  -- The rendered thumb's bar-row extent, kept for the press hit-test: a press
  -- inside it arms a drag, outside it jumps. This is the same geometry the
  -- extmarks below draw, recorded rather than recomputed.
  local thumb_lo, thumb_hi
  for r, cell in ipairs(cells) do
    if cell.thumb then
      thumb_lo = thumb_lo or r
      thumb_hi = r
    end
  end
  lease.thumb = thumb_lo and { lo = thumb_lo, hi = thumb_hi } or nil

  local lines = {}
  for r = 1, #cells do
    lines[r] = cells[r].char
  end
  vim.api.nvim_buf_set_lines(lease.buf, 0, -1, false, lines)
  if not active(lease) then
    return false
  end
  vim.api.nvim_buf_clear_namespace(lease.buf, NS, 0, -1)
  if not active(lease) then
    return false
  end
  for r, cell in ipairs(cells) do
    if not active(lease) then
      return false
    end
    if cell.hl then
      vim.api.nvim_buf_set_extmark(lease.buf, NS, r - 1, 0, {
        line_hl_group = cell.hl,
        priority = 100,
      })
    end
    if cell.thumb then
      vim.api.nvim_buf_set_extmark(lease.buf, NS, r - 1, 0, {
        line_hl_group = "CanvasDiffScrollThumb",
        priority = 200,
      })
    end
  end
  return active(lease)
end

--- Terminal, exact, idempotent teardown for one scrollbar lease. Invalidate
--- before the first external operation: closing a window or deleting a group
--- may synchronously run callbacks, and those callbacks must see a dead lease.
function S.close(lease)
  if not exact(lease) then
    return false
  end
  LEASE_AUTH[lease] = nil
  lease.phase = "closing"
  lease.disposed = true
  lease.schedule_ticket = lease.schedule_ticket + 1

  local group_id = lease.group_id
  local autocmd_ids = lease.autocmd_ids
  local win = lease.win
  local buf = lease.buf
  local canvas_buf = type(lease.state) == "table" and lease.state.buf or nil
  local release = lease.callbacks and lease.callbacks.release
  local claimed = lease.claimed

  lease.group_id = nil
  lease.autocmd_ids = {}
  lease.win = nil
  lease.buf = nil
  lease.state = nil
  lease.opts = nil
  lease.callbacks = {}
  -- An in-flight gesture dies with its lease: no queued scrub can pass the
  -- active() gate again, and the mappings leave with the canvas buffer's maps.
  lease.drag = nil
  lease.thumb = nil
  lease.phase = "disposed"

  remove_mouse(lease, canvas_buf)

  local group_deleted = group_id and pcall(vim.api.nvim_del_augroup_by_id, group_id)
  if not group_deleted then
    for _, id in ipairs(autocmd_ids or {}) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
  end
  if valid_win(win) then
    local ok, showing = pcall(vim.api.nvim_win_get_buf, win)
    if ok and showing == buf then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if valid_buf(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  if release and claimed then
    local ok, err = pcall(release, lease)
    if not ok then
      error(err, 0)
    end
  end
  return true
end

local function defer_update(lease)
  if not active(lease) then
    return
  end
  lease.schedule_ticket = lease.schedule_ticket + 1
  local ticket = lease.schedule_ticket
  vim.schedule(function()
    if active(lease) and ticket == lease.schedule_ticket then
      S.update(lease)
    end
  end)
end

local function create_autocmd(lease, events, spec)
  spec.group = lease.group_id
  local id = vim.api.nvim_create_autocmd(events, spec)
  if not active(lease) then
    pcall(vim.api.nvim_del_autocmd, id)
    error("scrollbar open was superseded while creating autocmds", 0)
  end
  lease.autocmd_ids[#lease.autocmd_ids + 1] = id
end

local function install_autocmds(lease)
  local state = lease.state
  create_autocmd(lease, { "WinScrolled", "WinResized" }, {
    callback = function(ev)
      if not active(lease) then
        return
      end
      local w = tonumber(ev.match)
      if ev.event == "WinResized" or w == lease.state.win then
        S.update(lease)
      end
    end,
  })
  create_autocmd(lease, "BufWinEnter", {
    buffer = state.buf,
    callback = function()
      if active(lease) then
        S.update(lease)
      end
    end,
  })
  create_autocmd(lease, "BufWinLeave", {
    buffer = state.buf,
    callback = function()
      -- The canvas buffer just left a window (jump excursion's :edit, or
      -- any buffer switch); if it no longer shows in state.win, hide the
      -- float instead of letting it sit over the real file. At this point
      -- in the event the window still transiently reports the OLD buffer
      -- (the canvas), so canvas_showing would wrongly read "still
      -- showing" if checked synchronously; defer to let the switch land.
      defer_update(lease)
    end,
  })
  create_autocmd(lease, "WinClosed", {
    callback = function(ev)
      local closed = tonumber(ev.match)
      if not (active(lease) and lease.state.win == closed) then
        return
      end
      lease.schedule_ticket = lease.schedule_ticket + 1
      local ticket = lease.schedule_ticket
      vim.schedule(function()
        if active(lease)
            and ticket == lease.schedule_ticket
            and lease.state.win == closed then
          S.close(lease)
        end
      end)
    end,
  })
end

--- Open one independent Surface-owned scrollbar lease. `claim`, `alive`, and
--- `release` callbacks let the owner publish and fence the exact identity
--- before any resource is created.
function S.open(state, opts, callbacks)
  opts = opts or {}
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  next_lease_id = next_lease_id + 1
  local lease = {
    id = next_lease_id,
    phase = "attaching",
    disposed = false,
    claimed = false,
    state = state,
    opts = opts,
    callbacks = callbacks or {},
    group_name = "canvasdiff.scrollbar." .. next_lease_id,
    group_id = nil,
    autocmd_ids = {},
    schedule_ticket = 0,
    buf = nil,
    win = nil,
  }
  LEASE_AUTH[lease] = true

  local claim = lease.callbacks.claim
  if claim then
    -- A throwing claim may already have published the lease. Mark it claimed
    -- before entering owner code so exact close can safely ask release to
    -- unlink only this identity.
    lease.claimed = true
    local ok, claimed = pcall(claim, lease)
    if not ok then
      pcall(S.close, lease)
      error(claimed, 0)
    end
    if not claimed then
      lease.claimed = false
      S.close(lease)
      return nil
    end
  else
    lease.claimed = true
  end

  local ok, err = pcall(function()
    if not active(lease) then
      error("scrollbar owner is no longer alive", 0)
    end
    ensure_hl_groups()
    if not active(lease) then
      error("scrollbar open was superseded while defining highlights", 0)
    end
    lease.group_id = vim.api.nvim_create_augroup(lease.group_name, { clear = true })
    if not active(lease) then
      pcall(vim.api.nvim_del_augroup_by_id, lease.group_id)
      error("scrollbar open was superseded while creating its group", 0)
    end
    install_autocmds(lease)
    install_mouse(lease)
    if not active(lease) then
      error("scrollbar open was superseded while installing mouse handlers", 0)
    end
    S.update(lease)
    if not active(lease) then
      error("scrollbar open was superseded during initial draw", 0)
    end
    lease.phase = "active"
  end)
  if not ok then
    pcall(S.close, lease)
    error(err, 0)
  end
  return lease
end

return S
