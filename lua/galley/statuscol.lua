local canvas = require("galley.canvas")
local fold = require("galley.fold")

local M = {}

local STATUSCOL_EXPR = "%!v:lua.require'galley.statuscol'.text()"
local current = nil
local next_id = 0

-- Window-local options can outlive buffers and are inherited by plain splits.
-- The expression string is identical across generations, so ownership needs an
-- exact record rather than a string comparison.
local owners = {}

local function exact(lease)
  return lease ~= nil and current == lease and not lease.disposed
end

local function active(lease)
  if not exact(lease) then
    return false
  end
  local alive = lease.callbacks.alive
  if alive and not alive() then
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
  end

  set_option(win, STATUSCOL_EXPR)
  if owners[win] ~= record or not exact(lease) then
    reconcile_expression_write(win, record)
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
  if not active(lease) or lease.leaving[win] ~= record
      or owners[win] ~= record then
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
  if not record or owners[win] ~= record or not showing(lease.state, win) then
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
function M.render(lease, win, lnum)
  if not active(lease) or not showing(lease.state, win) then
    return ""
  end

  local state = lease.state
  local index, offset = canvas.locate(state, lnum - 1)
  if not index then
    return "     "
  end
  local section = state.sections[index]
  if not section or fold.hidden(state, section.path) then
    return "     "
  end
  local entry = section.entries[offset]
  if not entry or entry.kind == "file_hdr" or entry.kind == "hunk_hdr" then
    return "     "
  end
  if entry.new_lnum then
    return ("%4d "):format(entry.new_lnum)
  end
  return "     "
end

--- Fail-closed statuscolumn expression entrypoint.
function M.text()
  local ok, result = pcall(
    M.render, current, vim.g.statusline_winid, vim.v.lnum)
  return ok and result or ""
end

--- Exact, idempotent teardown. Invalidate and delete the producer before any
--- option I/O, which may reentrantly install a replacement.
function M.detach(expected)
  local lease = current
  if not lease or (expected and expected ~= lease) then
    return false
  end

  lease.disposed = true
  current = nil
  local aug = lease.aug
  lease.aug = nil
  if aug then
    pcall(vim.api.nvim_del_augroup_by_id, aug)
  end

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
  if first_error then
    error(first_error, 0)
  end
  return true
end

--- Install one Surface-owned status-column lease.
function M.attach(state, callbacks)
  if current then
    local predecessor = current
    M.detach(predecessor)
    if current then
      error("status-column attach was superseded during predecessor teardown", 0)
    end
  end

  next_id = next_id + 1
  local lease = {
    id = next_id,
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
  current = lease

  local ok, err = pcall(function()
    lease.aug = vim.api.nvim_create_augroup(
      "galley.statuscol", { clear = true })
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
          if not exact(lease) then
            transfer_replacement()
          elseif not pending then
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
          if not exact(lease) then
            transfer_replacement()
          end
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
      error("status-column attach was superseded during window discovery", 0)
    end
    for _, win in ipairs(wins) do
      claim(lease, win)
      if not exact(lease) then
        error("status-column attach was superseded during initial claim", 0)
      end
    end
    lease.focused_win = vim.api.nvim_get_current_win()
    lease.last_canvas = capture_source(lease, "last")
    if not exact(lease) then
      error("status-column attach was superseded during source capture", 0)
    end
  end)
  if not ok then
    pcall(M.detach, lease)
    error(err, 0)
  end
  return lease
end

return M
