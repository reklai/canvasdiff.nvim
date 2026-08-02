-- The sticky file-header row: a one-row float pinned under the winbar that
-- mirrors the in-buffer header of the section under the topline, followed by a
-- breadcrumb naming the hunk you are inside it. SH.content is the pure half:
-- given a state and a 0-based topline, what (if anything) should the row show.
-- The float half below (open/update/close) renders that answer.
--
-- The lease machinery here is DELIBERATELY the scrollbar's, ported rather
-- than shared: sidebar, status column and scrollbar each own their lease
-- pattern by repo convention, because the update logic in the middle
-- diverges completely and a shared abstraction would couple four owners
-- through their least interesting part.
local canvas = require("canvasdiff.canvas")
local render = canvas.format
local fold = require("canvasdiff.diff").fold

local SH = {}

--- The breadcrumb after the file identity: which hunk the topline is inside,
--- and how far through the file that is -- "→ @@ 88  render(state) · 3/5".
--- Returns the text and its spans (byte columns absolute on the finished row,
--- which is why it is given `head`), or nil when no hunk header sits at or
--- above the row `offset` names: a binary notice, a pure rename, any row a
--- section publishes outside its hunks.
---
--- This is the answer a closed sidebar would otherwise cost you. It is also the
--- only part of the row that MAY change while the file stays the same -- the
--- file part is a verbatim mirror of the header row underneath, which is what
--- lets the float hide itself when that row reaches the top.
---
--- A body row already knows its hunk (`entry.hunk_idx`, the same `gi` the
--- sidebar's rows carry), so nothing walks upward looking for the header.
---
--- `room` is the window's column count when the caller has one. Only the LABEL
--- gives way to it: the file identity and the ordinal are the two answers the
--- row exists to give, and half of either is worse than none -- which is also
--- why a window too narrow for the crumb even without a label gets no crumb at
--- all, rather than one whose ordinal the window clips off the right edge.
local function crumb(section, offset, head, room)
  local entry = (section.entries or {})[offset]
  local gi = entry and entry.hunk_idx or nil
  local hunks = section.hunks or {}
  local hunk = gi and hunks[gi] or nil
  if not hunk then
    return nil
  end
  local marker, label = render.hunk_name(hunk)
  label = render.escape_path(label)
  -- Counted off the same list the ordinal indexes, so "3/5" can never name a
  -- hunk from outside its own denominator.
  local ordinal = ("%s%d/%d"):format(render.glyphs.crumb_sep, gi, #hunks)
  local lead = render.glyphs.crumb .. marker
  -- Bytes are an upper bound on cells, so the arithmetic only has to be exact
  -- for a row that really is too long.
  if room and #head + #lead + #label + #ordinal > room then
    label = render.fit(label,
      room - vim.fn.strdisplaywidth(head .. lead .. ordinal))
    if vim.fn.strdisplaywidth(head .. lead .. label .. ordinal) > room then
      -- Even with the label gone the crumb does not fit, so it would be drawn
      -- with its right edge -- the ordinal -- off the window. File-only is the
      -- honest answer for a window with no room for the rest.
      return nil
    end
  end
  local text = lead .. label .. ordinal
  local spans = {
    -- The crumb reads as what it names: the group the canvas's own `@@` rows
    -- wear. It layers OVER the file header's own foreground, which the float
    -- draws across the whole row.
    { #head, #head + #text, "CanvasDiffHunkHeader" },
  }
  if hunk.pure_del and #label > 0 then
    -- Struck iff the label is old-side text: the same fact, on the same
    -- channel, as the sidebar's hunk row and the canvas's ghost deletions.
    -- Measured off the label that SURVIVED the cut above, never the one that
    -- arrived -- a span from before it would run past end-of-line.
    spans[2] = { #head + #lead, #head + #lead + #label, "CanvasDiffHunkDel" }
  end
  return text, spans
end

--- nil = show nothing: empty canvas, nothing resolvable, a folded
--- placeholder (that single row IS the header), or the real header row
--- sitting exactly at the top -- pinning a copy over the original would
--- double it.
---
--- `room` is optional: without it nothing truncates, which is what keeps this
--- answerable with no window to measure.
function SH.content(st, top0, room)
  if type(st) ~= "table" or type(st.sections) ~= "table"
      or #st.sections == 0 then
    return nil
  end
  local index, offset = canvas.locate(st, top0)
  local section = index and st.sections[index] or nil
  if not section then
    return nil
  end
  -- Both clauses are load-bearing, and neither shadows the other. A folded
  -- section renders as ONE row, so every topline inside it lands on offset 1 --
  -- but locate has no upper clamp, and a row past the last section's placeholder
  -- comes back with a larger offset. Without fold.hidden that row would pin the
  -- EXPANDED header of a file the buffer is drawing as a placeholder.
  if fold.hidden(st, section.path) or offset == 1 then
    return nil
  end
  local line = render.section_line(section, 1)
  if not line then
    return nil
  end
  -- Measured on the FILE line, before the crumb joins it: marker_spans walks in
  -- from the END of what it is given, so the whole row would put the stage
  -- marks on the crumb's last bytes.
  --
  -- Never a stale span either: the pinned section is on screen, and fold.stale
  -- is false by construction for anything you can see (the same reason
  -- the expanded in-buffer header carries none).
  local spans = render.marker_spans(line, section.staged, section.unstaged, false)
  local text, crumb_spans = crumb(section, offset, line, room)
  if text then
    line = line .. text
    for _, span in ipairs(crumb_spans) do
      spans[#spans + 1] = span
    end
  end
  return { line = line, spans = spans }
end

local NS = vim.api.nvim_create_namespace("canvasdiff.sticky")
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

function SH.is_open(lease)
  return owned_window(lease)
end

local canvas_showing = canvas.win_showing_canvas

--- How many canvas rows actually hold buffer text: `getwininfo().height`
--- excludes the winbar row where `nvim_win_get_height` counts it (measured).
--- Used only as the "is there anywhere to pin" gate -- the float's ROW needs
--- no winbar arithmetic at all; see float_config.
local function text_geometry(win)
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return { height = 0 }
  end
  return { height = info.height }
end

local function float_config(state)
  return {
    relative = "win",
    win = state.win,
    -- Row 0 IS the first text row: a `relative = "win"` float's grid starts
    -- BELOW the winbar (measured on 0.12 -- nvim_win_get_position of a row-0
    -- float is the host's screen row plus its winbar rows). An earlier note,
    -- inherited from the minimap, claimed row 0 landed ON the winbar and
    -- added `getwininfo().winbar` here; that pinned this row one text row too
    -- low the moment a winbar existed, which in the real app is always.
    row = 0,
    col = 0,
    width = math.max(vim.api.nvim_win_get_width(state.win), 1),
    height = 1,
    focusable = false,
    style = "minimal",
    -- Below the minimap's 40: where the two floats share the top-right
    -- cell, the minimap wins. Clicks fall through to the covered canvas
    -- row either way (non-focusable floats are mouse-transparent).
    zindex = 30,
  }
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

--- Redraw (and re-show/reposition if needed) the pinned row for the live
--- canvas. Content nil, canvas hidden or window squashed => hide/no-op; the
--- lease survives hiding so BufWinEnter (or the next scroll) can re-show it.
---
--- The float OVERLAYS the top text row -- it never pushes content down, so
--- opening and hiding it cannot reflow the canvas or move the view.
function SH.update(lease, state)
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

  -- A squashed window (winminheight=0) reports height 0; there is no text
  -- row left to pin over. Hide and let WinResized/BufWinEnter re-show later.
  if text_geometry(state.win).height < 1 then
    hide(lease)
    return false
  end

  local top0 = vim.api.nvim_win_call(state.win, function()
    return vim.fn.line("w0") - 1
  end)
  if not active(lease) then
    return false
  end
  -- The same width the float is about to be given, so the crumb's label is cut
  -- to the room the row will actually have.
  local content = SH.content(state, top0,
    math.max(vim.api.nvim_win_get_width(state.win), 1))
  if not active(lease) then
    return false
  end
  if content == nil then
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
    vim.api.nvim_buf_set_name(buf, ("canvasdiff://sticky/%d"):format(lease.id))
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

  vim.api.nvim_buf_set_lines(lease.buf, 0, -1, false, { content.line })
  if not active(lease) then
    return false
  end
  vim.api.nvim_buf_clear_namespace(lease.buf, NS, 0, -1)
  if not active(lease) then
    return false
  end

  -- The same three layers the in-buffer header carries (canvas/Canvas.lua's
  -- section rendering), so the pinned copy is indistinguishable from the row
  -- it mirrors: the full-width bar tint below, the Title-linked foreground
  -- over the text, the stage marks on top. All groups are authored by the
  -- canvas that must already be showing for this row to exist.
  vim.api.nvim_buf_set_extmark(lease.buf, NS, 0, 0, {
    line_hl_group = "CanvasDiffFileBar",
    priority = 99,
  })
  if not active(lease) then
    return false
  end
  vim.api.nvim_buf_set_extmark(lease.buf, NS, 0, 0, {
    end_col = #content.line,
    hl_group = "CanvasDiffFileHeader",
    priority = 100,
  })
  for i, span in ipairs(content.spans) do
    if not active(lease) then
      return false
    end
    -- The first is 101, which is the in-buffer header's non-stale priority
    -- exactly (SH.content passes stale = false by construction, so there is
    -- never a CanvasDiffStaleEmphasis span to layer here). The rest step up
    -- from it, because spans arrive outermost-first: the crumb's strike has to
    -- land over the crumb's own group, the way the sidebar layers the same two.
    vim.api.nvim_buf_set_extmark(lease.buf, NS, 0, span[1], {
      end_col = span[2],
      hl_group = span[3],
      priority = 101 + i - 1,
    })
  end
  return active(lease)
end

--- Terminal, exact, idempotent teardown for one sticky-header lease.
--- Invalidate before the first external operation: closing a window or
--- deleting a group may synchronously run callbacks, and those callbacks
--- must see a dead lease.
function SH.close(lease)
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
  local release = lease.callbacks and lease.callbacks.release
  local claimed = lease.claimed

  lease.group_id = nil
  lease.autocmd_ids = {}
  lease.win = nil
  lease.buf = nil
  lease.state = nil
  lease.opts = nil
  lease.callbacks = {}
  lease.phase = "disposed"

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
      SH.update(lease)
    end
  end)
end

local function create_autocmd(lease, events, spec)
  spec.group = lease.group_id
  local id = vim.api.nvim_create_autocmd(events, spec)
  if not active(lease) then
    pcall(vim.api.nvim_del_autocmd, id)
    error("sticky header open was superseded while creating autocmds", 0)
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
        SH.update(lease)
      end
    end,
  })
  create_autocmd(lease, "BufWinEnter", {
    buffer = state.buf,
    callback = function()
      if active(lease) then
        SH.update(lease)
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
          SH.close(lease)
        end
      end)
    end,
  })
end

--- Open one independent Surface-owned sticky-header lease. `claim`, `alive`,
--- and `release` callbacks let the owner publish and fence the exact identity
--- before any resource is created.
function SH.open(state, opts, callbacks)
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
    group_name = "canvasdiff.sticky." .. next_lease_id,
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
      pcall(SH.close, lease)
      error(claimed, 0)
    end
    if not claimed then
      lease.claimed = false
      SH.close(lease)
      return nil
    end
  else
    lease.claimed = true
  end

  local ok, err = pcall(function()
    if not active(lease) then
      error("sticky header owner is no longer alive", 0)
    end
    -- Every other group this row wears is authored by the canvas that must
    -- already be showing for the row to exist. The struck crumb label is the
    -- exception: its group belongs to the hunk vocabulary the sidebar shares,
    -- and the sidebar may never have opened at all.
    render.ensure_hunk_hl()
    lease.group_id = vim.api.nvim_create_augroup(lease.group_name, { clear = true })
    if not active(lease) then
      pcall(vim.api.nvim_del_augroup_by_id, lease.group_id)
      error("sticky header open was superseded while creating its group", 0)
    end
    install_autocmds(lease)
    SH.update(lease)
    if not active(lease) then
      error("sticky header open was superseded during initial draw", 0)
    end
    lease.phase = "active"
  end)
  if not ok then
    pcall(SH.close, lease)
    error(err, 0)
  end
  return lease
end

return SH
