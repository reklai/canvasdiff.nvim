local canvas = require("canvasdiff.canvas")
local config = require("canvasdiff.config")
local fold = require("canvasdiff.diff").fold

local M = {}

-- The bar drawn per changed row, foreground-coloured so it reads without
-- claiming a background. Defined by the canvas's group setup
-- (render.ensure_diff_hl), which runs before any statuscolumn can draw.
local GUTTER_HL = {
  add = "CanvasDiffGutterAdd",
  del = "CanvasDiffGutterDel",
}

local STATUSCOL_EXPR = "%!v:lua.require'canvasdiff.ui.status_column'.text()"
local next_id = 0

-- Window-local options can outlive buffers and are inherited by plain splits.
-- The expression string is identical across every lease, so ownership needs an
-- exact record rather than a string comparison.
--
-- This is the arbitration point, and it is deliberately per WINDOW: two
-- independent Surfaces may both be live, but exactly one of them owns any one
-- window's `statuscolumn` slot at a time. Nothing here decides which lease is
-- "the" status column.
local owners = {}

-- Lookup-only authentication. Weak keys cannot keep a lease alive and, unlike
-- trusting a handful of public table fields, cannot be copied onto a forged
-- shell.
local LEASE_AUTH = setmetatable({}, { __mode = "k" })

local function exact(lease)
  return type(lease) == "table"
    and LEASE_AUTH[lease] == true
    and not lease.disposed
end

local function active(lease)
  if not exact(lease) then
    return false
  end
  local alive = lease.callbacks and lease.callbacks.alive
  if alive and not alive(lease) then
    return false
  end
  return exact(lease)
end

local function valid_window(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function get_option(win)
  return vim.api.nvim_get_option_value(
    "statuscolumn", { win = win, scope = "local" })
end

local function set_option(win, value)
  vim.api.nvim_set_option_value(
    "statuscolumn", value, { win = win, scope = "local" })
end

local function showing(state, win)
  return state and state.buf and valid_window(win)
    and vim.api.nvim_win_get_buf(win) == state.buf
end

local function add_window(out, seen, win)
  if type(win) == "number" and not seen[win] then
    seen[win] = true
    out[#out + 1] = win
  end
end

--- Surface-owned views only. Surface performs the process scan while excluding
--- pre-existing raw/baseline canvas views that this lease must never claim.
--- Callback failures remain observable.
local function canvas_windows(lease)
  local out, seen = {}, {}
  local state = lease.state
  if state and showing(state, state.win) then
    add_window(out, seen, state.win)
  end

  local list = lease.callbacks.windows and lease.callbacks.windows() or {}
  for _, win in ipairs(list or {}) do
    if showing(state, win) then
      add_window(out, seen, win)
    end
  end
  return out
end

local function inherited_prior(lease, win)
  local window_prior = lease.priors[win]
  if window_prior ~= nil then
    return window_prior
  end
  if valid_window(win) then
    local tab = vim.api.nvim_win_get_tabpage(win)
    local prior = lease.tab_priors[tab]
    if prior ~= nil then
      return prior
    end
  end
  return lease.initial_prior or ""
end

local function remember_prior(lease, win, prior)
  if lease.initial_prior == nil then
    lease.initial_prior = prior
  end
  if valid_window(win) then
    local tab = vim.api.nvim_win_get_tabpage(win)
    if lease.tab_priors[tab] == nil then
      lease.tab_priors[tab] = prior
    end
  end
end

local function rebase_record_prior(win, record, prior)
  local lease = record and record.lease or nil
  if not lease or owners[win] ~= record or not exact(lease) then
    return false
  end
  local previous = record.prior
  record.prior = prior
  if lease.priors[win] == previous then
    lease.priors[win] = prior
  end
  for _, key in ipairs({ "last_canvas", "pending_split", "pending_tab" }) do
    local provenance = lease[key]
    if provenance and provenance.owner == record then
      provenance.prior = prior
    end
  end
  return owners[win] == record and exact(lease)
end

--- An expression write can reentrantly install a replacement whose detach
--- completes before the outer write lands. Follow an exact winning owner, or
--- restore the stale writer's prior when no lease owns this window anymore.
local function reconcile_expression_write(win, stale_record)
  if not stale_record or not valid_window(win) then
    return
  end

  local owner = owners[win]
  if owner then
    if not exact(owner.lease) then
      return
    end
    local value = get_option(win)
    if owners[win] ~= owner or not exact(owner.lease) then
      return reconcile_expression_write(win, owner)
    end
    if value == STATUSCOL_EXPR then
      return
    end
    set_option(win, STATUSCOL_EXPR)
    if owners[win] == owner and exact(owner.lease) then
      return
    end
    return reconcile_expression_write(win, owner)
  end

  local value = get_option(win)
  owner = owners[win]
  if owner then
    return reconcile_expression_write(win, owner)
  end
  if value ~= STATUSCOL_EXPR then
    return
  end

  set_option(win, stale_record.prior)
  owner = owners[win]
  if owner then
    rebase_record_prior(win, owner, stale_record.prior)
    reconcile_expression_write(win, owner)
  end
end

local function source_value_owned(lease, source, owner, value)
  return value == STATUSCOL_EXPR
    or (lease.leaving[source] == owner and value == owner.prior)
end

local function capture_window(lease, source, kind)
  if not active(lease) then
    return nil
  end
  if not showing(lease.state, source) then
    return nil
  end

  local owner = owners[source]
  if not owner or owner.lease ~= lease then
    return nil
  end
  local value = get_option(source)
  if not active(lease) or not source_value_owned(
        lease, source, owner, value)
      or owners[source] ~= owner then
    return nil
  end
  local tab = vim.api.nvim_win_get_tabpage(source)
  if not exact(lease) or owners[source] ~= owner then
    return nil
  end
  return {
    kind = kind,
    source = source,
    owner = owner,
    prior = owner.prior,
    tab = tab,
  }
end

--- Capture the exact owned source before Neovim creates a child window. Plain
--- splits provide WinNewPre; :tab split skips it but does provide TabLeave.
local function capture_source(lease, kind)
  if not active(lease) then
    return nil
  end
  local source = vim.api.nvim_get_current_win()
  if not exact(lease) then
    return nil
  end
  return capture_window(lease, source, kind)
end

--- A replacement attached inside WinNew/BufLeave temporarily observes the
--- event window as current. Re-pin it to the predecessor's trusted real source
--- so another synchronous non-entering window inherits the correct prior.
local function handoff_provenance(lease, source)
  if not lease or not source then
    return
  end
  if not exact(lease) then
    local replacement = owners[source]
    if replacement and replacement.lease ~= lease then
      return handoff_provenance(replacement.lease, source)
    end
    return
  end
  local captured = capture_window(lease, source, "last")
  if not exact(lease) then
    local replacement = owners[source]
    if replacement and replacement.lease ~= lease then
      return handoff_provenance(replacement.lease, source)
    end
    return
  end
  lease.focused_win = captured and source or nil
  lease.last_canvas = captured
end

local function release_record(lease, win, record)
  if owners[win] == record then
    owners[win] = nil
  end
  if lease.touched[win] == record then
    lease.touched[win] = nil
  end
  if lease.last_canvas and lease.last_canvas.owner == record then
    lease.last_canvas = nil
  end
  if lease.pending_split and lease.pending_split.owner == record then
    lease.pending_split = nil
  end
  if lease.pending_tab and lease.pending_tab.owner == record then
    lease.pending_tab = nil
  end
  if lease.leaving[win] == record then
    lease.leaving[win] = nil
  end
end

--- Claim one canvas window and install the expression, preserving its prior
--- local value. Existing-generation records transfer their original prior.
local function claim(lease, win, prior_hint, require_inherited)
  if not active(lease) or not showing(lease.state, win) then
    return false
  end

  local value = get_option(win)
  if not active(lease)
      or (require_inherited and value ~= STATUSCOL_EXPR) then
    return false
  end

  local record = owners[win]
  local displaced = record
  if not (record and record.lease == lease) then
    local prior
    if record then
      prior = record.prior
    elseif prior_hint ~= nil then
      prior = prior_hint
    elseif value == STATUSCOL_EXPR then
      prior = inherited_prior(lease, win)
    else
      prior = value
    end
    if not active(lease) then
      return false
    end
    record = { lease = lease, prior = prior }
    owners[win] = record
    lease.touched[win] = record
    lease.priors[win] = prior
    remember_prior(lease, win, prior)
    if displaced and displaced.lease ~= lease then
      -- One window moves from one live lease to another, carrying the exact
      -- prior with it. The peer keeps its other windows, but must not keep
      -- bookkeeping for a slot it no longer owns: a later teardown would
      -- otherwise try to restore over whoever owns it now.
      release_record(displaced.lease, win, displaced)
    end
  end

  set_option(win, STATUSCOL_EXPR)
  if owners[win] ~= record or not exact(lease) then
    reconcile_expression_write(win, record)
    if owners[win] ~= record then
      -- A peer claimed this window inside our own write. Drop the record we
      -- provisionally published: retaining it would make teardown try to
      -- restore a prior over the lease that owns the slot now.
      release_record(lease, win, record)
    end
    return false
  end
  if lease.leaving[win] == record then
    lease.leaving[win] = nil
  end
  return true
end

--- A plain split can inherit the expression without BufWinEnter. Adopt it
--- synchronously on leave so Surface releasing the window cannot strand it.
local function adopt_inherited(lease, win)
  if not active(lease) or owners[win] or not valid_window(win) then
    return
  end
  local value = get_option(win)
  if not active(lease) or owners[win] or value ~= STATUSCOL_EXPR then
    return
  end
  local record = {
    lease = lease,
    prior = inherited_prior(lease, win),
  }
  if not active(lease) or owners[win] then
    return
  end
  owners[win] = record
  lease.touched[win] = record
  lease.priors[win] = record.prior
end

local function repair_replacement(win, replacement)
  if not replacement or owners[win] ~= replacement or not valid_window(win) then
    return
  end
  local value = get_option(win)
  if owners[win] ~= replacement then
    return
  end
  if value ~= STATUSCOL_EXPR then
    set_option(win, STATUSCOL_EXPR)
    if owners[win] ~= replacement or not exact(replacement.lease) then
      reconcile_expression_write(win, replacement)
    end
  end
end

--- WinNew initially exposes the source Canvas buffer even when the requested
--- final buffer is foreign. Suspend the child on its exact inherited prior so
--- that a later foreign swap cannot strand the expression in a hidden slot.
local function suspend_created(win, record)
  if not record then
    return nil, nil
  end

  local winner = record.lease
  if owners[win] ~= record then
    local replacement = owners[win]
    if replacement and replacement ~= record then
      return suspend_created(win, replacement)
    end
    return nil, nil
  end

  if not active(winner) then
    local replacement = owners[win]
    if replacement and replacement ~= record then
      return suspend_created(win, replacement)
    end
    return nil, nil
  end

  local visible = showing(winner.state, win)
  if owners[win] ~= record or not exact(winner) then
    local replacement = owners[win]
    if replacement and replacement ~= record then
      return suspend_created(win, replacement)
    end
    return nil, nil
  end
  if not visible then
    return nil, nil
  end

  local value = get_option(win)
  if not active(winner) or owners[win] ~= record then
    local replacement = owners[win]
    if replacement and replacement ~= record then
      return suspend_created(win, replacement)
    end
    return nil, nil
  end
  if value ~= STATUSCOL_EXPR and value ~= record.prior then
    return nil, nil
  end

  winner.leaving[win] = record
  if value == STATUSCOL_EXPR then
    local ok, err = pcall(set_option, win, record.prior)
    if not ok then
      if winner.leaving[win] == record then
        winner.leaving[win] = nil
      end
      error(err, 0)
    end
  end

  local replacement = owners[win]
  if replacement == record and exact(winner) then
    return record, winner
  end
  if winner.leaving[win] == record then
    winner.leaving[win] = nil
  end
  if replacement and replacement ~= record then
    return suspend_created(win, replacement)
  end
  return nil, nil
end

local function suspend_with_provenance(win, record, source)
  local suspended, winner = suspend_created(win, record)
  if not suspended then
    return nil, nil
  end
  handoff_provenance(winner, source)
  if exact(winner) and owners[win] == suspended then
    return suspended, winner
  end
  local replacement = owners[win]
  if replacement and replacement ~= suspended then
    return suspend_with_provenance(win, replacement, source)
  end
  return nil, nil
end

local function prepare_created(lease, win, prior)
  if not active(lease) then
    local replacement = owners[win]
    if replacement and replacement.lease ~= lease then
      return suspend_created(win, replacement)
    end
    return nil, nil
  end
  local visible = showing(lease.state, win)
  if not exact(lease) then
    local replacement = owners[win]
    if replacement and replacement.lease ~= lease then
      return suspend_created(win, replacement)
    end
    return nil, nil
  end
  if not visible then
    return nil, nil
  end
  local value = get_option(win)
  if not active(lease) then
    local replacement = owners[win]
    if replacement and replacement.lease ~= lease then
      return suspend_created(win, replacement)
    end
    return nil, nil
  end
  if value ~= STATUSCOL_EXPR and value ~= prior then
    return nil, nil
  end

  local record = owners[win]
  if record and record.lease ~= lease then
    return suspend_created(win, record)
  elseif not record then
    record = { lease = lease, prior = prior }
    owners[win] = record
    lease.touched[win] = record
    lease.priors[win] = prior
    remember_prior(lease, win, prior)
  end
  if not record or record.lease ~= lease then
    return nil, nil
  end
  return suspend_created(win, record)
end

--- BufLeave runs while the canvas buffer's window-local option slot is still
--- active. Restore that slot synchronously, but retain exact ownership until
--- the deferred callback distinguishes a real buffer departure from a
--- focus-only BufLeave.
local function prepare_leave(lease, win)
  if not active(lease) then
    local replacement = owners[win]
    if replacement and replacement.lease ~= lease then
      return suspend_created(win, replacement)
    end
    return nil, nil
  end
  local pending = lease.leaving[win]
  if pending and owners[win] == pending then
    return nil, nil
  end

  adopt_inherited(lease, win)
  local record = owners[win]
  if not record then
    return nil, nil
  end
  if record.lease ~= lease then
    return suspend_created(win, record)
  end

  local valid = valid_window(win)
  if not exact(lease) or owners[win] ~= record then
    local replacement = owners[win]
    if replacement and replacement ~= record then
      return suspend_created(win, replacement)
    end
    return nil, nil
  end
  if not valid then
    release_record(lease, win, record)
    return nil, nil
  end

  local value = get_option(win)
  if not exact(lease) or owners[win] ~= record then
    local replacement = owners[win]
    if replacement and replacement ~= record then
      return suspend_created(win, replacement)
    end
    return nil, nil
  end
  if value ~= STATUSCOL_EXPR then
    release_record(lease, win, record)
    return nil, nil
  end
  return suspend_created(win, record)
end

local function finish_leave(lease, win, record)
  if not active(lease) or lease.leaving[win] ~= record then
    return
  end
  if owners[win] ~= record then
    -- A peer claimed this window while the deferred leave was queued. Drop the
    -- stale record instead of retaining a slot another lease now owns.
    release_record(lease, win, record)
    return
  end
  lease.leaving[win] = nil

  if not valid_window(win) or not showing(lease.state, win) then
    release_record(lease, win, record)
    return
  end
  local value = get_option(win)
  if not exact(lease) or owners[win] ~= record then
    return
  end
  if value == STATUSCOL_EXPR then
    return
  end
  if value ~= record.prior then
    release_record(lease, win, record)
    return
  end

  set_option(win, STATUSCOL_EXPR)
  if not exact(lease) or owners[win] ~= record then
    reconcile_expression_write(win, record)
    return
  end
  if win == lease.focused_win then
    lease.last_canvas = capture_source(lease, "last")
  end
end

--- WinLeave following BufLeave means only focus changed: the source window
--- still shows Canvas, so cancel its deferred departure immediately.
local function finish_focus_leave(lease)
  if not active(lease) then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local record = lease.leaving[win]
  if not record then
    return
  end
  if owners[win] ~= record then
    release_record(lease, win, record)
    return
  end
  if not showing(lease.state, win) then
    return
  end

  local value = get_option(win)
  if not exact(lease) or lease.leaving[win] ~= record
      or owners[win] ~= record then
    return
  end
  if value == STATUSCOL_EXPR then
    lease.leaving[win] = nil
    return
  end
  if value ~= record.prior then
    release_record(lease, win, record)
    return
  end

  set_option(win, STATUSCOL_EXPR)
  if not exact(lease) or owners[win] ~= record then
    reconcile_expression_write(win, record)
    return
  end
  if lease.leaving[win] == record then
    lease.leaving[win] = nil
  end
end

--- Restore only an option still owned by this exact record and still equal to
--- the plugin expression. A later user override is deliberately left alone.
local function restore(lease, win, allow_inherited)
  local record = owners[win]
  if record and record.lease ~= lease then
    return false
  end
  if not valid_window(win) then
    if record then
      release_record(lease, win, record)
    end
    return false
  end

  local value = get_option(win)
  if owners[win] ~= record then
    return false
  end

  if not record and allow_inherited and value == STATUSCOL_EXPR then
    record = {
      lease = lease,
      prior = inherited_prior(lease, win),
    }
    if owners[win] then
      return false
    end
    owners[win] = record
    lease.touched[win] = record
    lease.priors[win] = record.prior
  end
  if not record then
    return false
  end
  if value ~= STATUSCOL_EXPR then
    release_record(lease, win, record)
    return false
  end

  set_option(win, record.prior)
  local replacement = owners[win]
  if replacement == record then
    release_record(lease, win, record)
  else
    -- A replacement may have attached reentrantly inside set_option. Repair
    -- its identical expression if the old restore landed after its write.
    repair_replacement(win, replacement)
  end
  return true
end

--- Testable renderer for an exact lease, drawn window and 1-based buffer row.
--- Unlike text(), owner callback failures remain observable here.
---
--- `virtnum` is Neovim's v:virtnum for the drawn screen row: nonzero means a
--- virtual line, and the only virtual lines the canvas draws are ghost
--- deletions -- their bar cell carries the deletion bar rather than anything
--- of the anchor row's.
function M.render(lease, win, lnum, virtnum)
  if not active(lease) or not showing(lease.state, win) then
    return ""
  end

  -- Every row carries a one-cell bar column: the coloured glyph on add/del
  -- rows, padding elsewhere so the line numbers stay aligned.
  local glyph = config.glyphs.gutter
  local pad = (" "):rep(vim.fn.strdisplaywidth(glyph))

  local state = lease.state
  local index, offset = canvas.locate(state, lnum - 1)
  if not index then
    return pad .. "     "
  end
  local section = state.sections[index]
  if not section or fold.hidden(state, section.path) then
    return pad .. "     "
  end
  local entry = section.entries[offset]
  if not entry or entry.kind == "file_hdr" or entry.kind == "hunk_hdr" then
    return pad .. "     "
  end
  -- A ghost deletion's virtual row reads as a deletion, whatever kind its
  -- anchor row is -- and never repeats the anchor's line number below.
  local ghost = virtnum ~= nil and virtnum ~= 0
  local group = GUTTER_HL[ghost and "del" or entry.kind]
  if group then
    pad = "%#" .. group .. "#" .. glyph .. "%*"
  end
  if entry.new_lnum and not ghost then
    return pad .. ("%4d "):format(entry.new_lnum)
  end
  return pad .. "     "
end

--- Fail-closed statuscolumn expression entrypoint.
---
--- Neovim evaluates one global expression string for every window that carries
--- it, so the drawn window is the only thing that can say which lease owns this
--- row. Resolving through the per-window ownership record -- rather than
--- through a module-global "current" lease -- is what lets two concurrent
--- Surfaces each render their own canvas correctly.
function M.text()
  local win = vim.g.statusline_winid
  local record = type(win) == "number" and owners[win] or nil
  local lease = record and record.lease or nil
  if not lease then
    return ""
  end
  local ok, result = pcall(M.render, lease, win, vim.v.lnum, vim.v.virtnum)
  return ok and result or ""
end

--- Exact, idempotent teardown. Invalidate and delete the producer before any
--- option I/O, which may reentrantly install a replacement.
function M.detach(expected)
  local lease = expected
  if not exact(lease) then
    return false
  end

  LEASE_AUTH[lease] = nil
  lease.disposed = true
  local aug = lease.aug
  lease.aug = nil
  local group_deleted = false
  if aug then
    group_deleted = pcall(vim.api.nvim_del_augroup_by_id, aug)
  end
  if not group_deleted and lease.group_name then
    -- Per-lease names make this cleanup incapable of touching a peer's group
    -- even when Neovim has recycled the numeric ID.
    pcall(vim.api.nvim_del_augroup_by_name, lease.group_name)
  end

  local release = lease.callbacks and lease.callbacks.release
  local claimed = lease.claimed
  local wins, first_error = {}, nil
  local ok, result = pcall(canvas_windows, lease)
  if ok then
    wins = result
  else
    first_error = result
  end
  local seen = {}
  for _, win in ipairs(wins) do
    seen[win] = true
  end
  for win in pairs(lease.touched) do
    if not seen[win] then
      wins[#wins + 1] = win
      seen[win] = true
    end
  end

  -- Snapshot every inherited/untracked expression while every touched prior is
  -- still available. Sequential restoration would otherwise discard the
  -- same-tab source before a later inherited split can copy its prior.
  for _, win in ipairs(wins) do
    if not owners[win] and valid_window(win) then
      local adopted, err = pcall(function()
        if get_option(win) == STATUSCOL_EXPR and not owners[win] then
          local record = {
            lease = lease,
            prior = inherited_prior(lease, win),
          }
          owners[win] = record
          lease.touched[win] = record
          lease.priors[win] = record.prior
        end
      end)
      if not adopted and not first_error then
        first_error = err
      end
    end
  end

  for _, win in ipairs(wins) do
    local restored, err = pcall(restore, lease, win, false)
    if not restored and not first_error then
      first_error = err
    end
  end
  -- A failed option operation must not retain the disposed Surface graph.
  local residual = {}
  for win, record in pairs(lease.touched) do
    residual[#residual + 1] = { win = win, record = record }
  end
  for _, item in ipairs(residual) do
    release_record(lease, item.win, item.record)
  end

  lease.state = nil
  lease.callbacks = {}
  lease.touched = {}
  lease.pending_split = nil
  lease.pending_tab = nil
  lease.last_canvas = nil
  lease.focused_win = nil
  lease.leaving = {}
  lease.priors = {}
  lease.tab_priors = {}
  lease.initial_prior = nil

  -- Last, so the owner's slot is only cleared once every window this lease
  -- touched has actually been restored or released.
  if release and claimed then
    local released, err = pcall(release, lease)
    if not released and not first_error then
      first_error = err
    end
  end
  if first_error then
    error(first_error, 0)
  end
  return true
end

--- Install one Surface-owned status-column lease.
---
--- Attaching never disturbs a peer. Independent Surfaces hold independent
--- leases; per-window records decide who owns any individual `statuscolumn`
--- slot, and only a lease's own owner may dispose it.
function M.attach(state, callbacks)
  next_id = next_id + 1
  local lease = {
    id = next_id,
    group_name = "canvasdiff.status_column." .. next_id,
    claimed = false,
    state = state,
    callbacks = callbacks or {},
    aug = nil,
    disposed = false,
    touched = {},
    pending_split = nil,
    pending_tab = nil,
    last_canvas = nil,
    focused_win = nil,
    leaving = {},
    priors = {},
    tab_priors = {},
    initial_prior = nil,
  }
  -- Publish exact identity before the first external call, so a reentrant
  -- callback can dispose only this partial lease.
  LEASE_AUTH[lease] = true

  local claim_owner = lease.callbacks.claim
  if claim_owner then
    -- A throwing claim may already have published the lease. Mark it claimed
    -- before entering owner code so exact teardown can ask release to unlink
    -- only this identity.
    lease.claimed = true
    local ok_claim, claimed = pcall(claim_owner, lease)
    if not ok_claim then
      pcall(M.detach, lease)
      error(claimed, 0)
    end
    if not claimed then
      lease.claimed = false
      M.detach(lease)
      return nil
    end
  else
    lease.claimed = true
  end

  local ok, err = pcall(function()
    if not active(lease) then
      error("status-column owner is no longer alive", 0)
    end
    lease.aug = vim.api.nvim_create_augroup(lease.group_name, { clear = true })
    if not exact(lease) then
      pcall(vim.api.nvim_del_augroup_by_name, lease.group_name)
      error("status-column attach was disposed while creating its group", 0)
    end
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = lease.aug,
      buffer = state.buf,
      callback = function()
        if not active(lease) then
          return
        end
        local win = vim.api.nvim_get_current_win()
        if not active(lease) then
          return
        end
        if claim(lease, win) and win == lease.focused_win then
          lease.last_canvas = capture_source(lease, "last")
        end
      end,
    })
    local function queue_finish(win, record, owner_lease)
      if not record then
        return
      end
      vim.schedule(function()
        finish_leave(owner_lease, win, record)
      end)
    end
    local function reconcile_created(win)
      vim.schedule(function()
        -- Source-less WinNew events can originate in an intentionally excluded
        -- raw Canvas view. Wait until Neovim has installed the requested final
        -- buffer before asking Surface to adopt the child; scanning during
        -- WinNew would falsely adopt foreign-target transient Canvas windows.
        if not active(lease) or not showing(lease.state, win) then
          return
        end
        local wins = canvas_windows(lease)
        if not active(lease) then
          return
        end
        local owned = false
        for _, candidate in ipairs(wins) do
          if candidate == win then
            owned = true
            break
          end
        end
        if not owned or not claim(lease, win) then
          return
        end

        local focused = vim.api.nvim_get_current_win()
        if exact(lease) and focused == win then
          lease.focused_win = win
          lease.last_canvas = capture_source(lease, "last")
        end
      end)
    end
    local function leave_canvas_window()
      -- A held stale callback must never reach its replacement. Once this
      -- invocation starts exact, however, any winner installed reentrantly
      -- must inherit the in-flight leave transaction because its newly
      -- installed autocmd cannot observe the BufLeave already being emitted.
      if not exact(lease) then
        return
      end
      local provenance = lease.last_canvas
      local source = provenance and provenance.source or lease.focused_win
      local win = vim.api.nvim_get_current_win()
      if not exact(lease) then
        local replacement = owners[win]
        if replacement and replacement.lease ~= lease then
          local record, owner_lease = suspend_with_provenance(
            win, replacement, source)
          queue_finish(win, record, owner_lease)
        end
        return
      end
      local record, owner_lease = prepare_leave(lease, win)
      if record and owner_lease ~= lease then
        record, owner_lease = suspend_with_provenance(
          win, owners[win] or record, source)
      end
      queue_finish(win, record, owner_lease)
    end
    vim.api.nvim_create_autocmd("BufLeave", {
      group = lease.aug,
      buffer = state.buf,
      callback = leave_canvas_window,
    })
    vim.api.nvim_create_autocmd("BufWinLeave", {
      group = lease.aug,
      buffer = state.buf,
      callback = leave_canvas_window,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = lease.aug,
      callback = function(args)
        if not exact(lease) then
          return
        end
        local win = tonumber(args.match)
        local record = win and owners[win] or nil
        if record and record.lease == lease then
          release_record(lease, win, record)
          lease.priors[win] = nil
        end
      end,
    })
    vim.api.nvim_create_autocmd("WinLeave", {
      group = lease.aug,
      callback = function()
        finish_focus_leave(lease)
      end,
    })
    vim.api.nvim_create_autocmd("WinNewPre", {
      group = lease.aug,
      callback = function()
        lease.pending_split = nil
        lease.pending_tab = nil
        lease.pending_split = capture_source(lease, "split")
      end,
    })
    vim.api.nvim_create_autocmd("TabLeave", {
      group = lease.aug,
      callback = function()
        lease.pending_split = nil
        lease.pending_tab = nil
        lease.pending_tab = capture_source(lease, "tab")
      end,
    })
    vim.api.nvim_create_autocmd("WinEnter", {
      group = lease.aug,
      callback = function()
        if not exact(lease) then
          return
        end
        lease.pending_split = nil
        lease.pending_tab = nil
        lease.last_canvas = nil
        if not active(lease) then
          return
        end
        local win = vim.api.nvim_get_current_win()
        if not active(lease) then
          return
        end
        lease.focused_win = win
        lease.last_canvas = capture_source(lease, "last")
      end,
    })
    vim.api.nvim_create_autocmd("TabEnter", {
      group = lease.aug,
      callback = function()
        if exact(lease) then
          lease.pending_split = nil
          lease.pending_tab = nil
        end
      end,
    })
    vim.api.nvim_create_autocmd("WinNew", {
      group = lease.aug,
      callback = function()
        if not exact(lease) then
          return
        end
        local pending = lease.pending_split or lease.pending_tab
          or lease.last_canvas
        lease.pending_split = nil
        lease.pending_tab = nil
        local win = vim.api.nvim_get_current_win()

        -- Suspend a record belonging to a DIFFERENT lease.
        --
        -- Unconditional, because Neovim remembers a window-local option per
        -- displayed buffer: a peer that claimed this window while it was
        -- transiently showing the Canvas leaves the expression remembered for
        -- that (window, buffer) pair, and restoring it after the real buffer
        -- lands is already too late. Whichever lease observes the creation
        -- event must write the peer's prior back while the Canvas is still on
        -- screen -- even when this lease's own provenance does not match, and
        -- so has nothing of its own to create here.
        local function transfer_replacement()
          local replacement = owners[win]
          if replacement and replacement.lease ~= lease then
            local record, owner_lease = suspend_with_provenance(
              win, replacement, pending and pending.source)
            queue_finish(win, record, owner_lease)
          end
        end

        if not exact(lease) then
          transfer_replacement()
          return
        end
        if not active(lease) or not pending then
          transfer_replacement()
          if exact(lease) and not pending then
            reconcile_created(win)
          end
          return
        end

        local tab = showing(lease.state, win)
          and vim.api.nvim_win_get_tabpage(win) or nil
        if win == pending.source or not showing(lease.state, pending.source)
            or owners[pending.source] ~= pending.owner
            or not tab
            or (pending.kind == "split" and tab ~= pending.tab)
            or (pending.kind == "tab" and tab == pending.tab)
            or (pending.kind == "last" and tab ~= pending.tab) then
          transfer_replacement()
          return
        end
        local source_value = get_option(pending.source)
        if not active(lease) or not source_value_owned(
              lease, pending.source, pending.owner, source_value)
            or owners[pending.source] ~= pending.owner then
          if not exact(lease) then
            transfer_replacement()
          end
          return
        end
        local record, owner_lease = prepare_created(
          lease, win, pending.prior)
        if record and owner_lease ~= lease then
          record, owner_lease = suspend_with_provenance(
            win, owners[win] or record, pending.source)
        end
        queue_finish(win, record, owner_lease)
      end,
    })

    local wins = canvas_windows(lease)
    if not active(lease) then
      error("status-column attach was disposed during window discovery", 0)
    end
    for _, win in ipairs(wins) do
      claim(lease, win)
      if not exact(lease) then
        error("status-column attach was disposed during initial claim", 0)
      end
    end
    lease.focused_win = vim.api.nvim_get_current_win()
    lease.last_canvas = capture_source(lease, "last")
    if not exact(lease) then
      error("status-column attach was disposed during source capture", 0)
    end

    -- The claim above reads one synchronous snapshot. An attach that happens
    -- inside another window's creation event -- a peer's `alive` callback, for
    -- instance -- can observe a window still transiently showing the Canvas
    -- that will hold a foreign buffer by the time the event completes. Nothing
    -- else would tell this lease about that: BufWinLeave arrives for the
    -- CURRENT window, and a nonentered float is never current. Reconcile the
    -- initial claim once the event loop turns.
    local claimed = {}
    for _, win in ipairs(wins) do
      claimed[#claimed + 1] = win
    end
    vim.schedule(function()
      if not active(lease) then
        return
      end
      for _, win in ipairs(claimed) do
        local record = owners[win]
        if record and record.lease == lease and not showing(lease.state, win) then
          restore(lease, win, false)
        end
      end
    end)
  end)
  if not ok then
    pcall(M.detach, lease)
    error(err, 0)
  end
  return lease
end

return M
