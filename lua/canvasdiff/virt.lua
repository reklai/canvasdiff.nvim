local canvas = require("canvasdiff.canvas")
local fold = require("canvasdiff.fold")

local M = {}

-- Tier-1 auto-virtualization: huge changesets keep near-viewport sections
-- expanded and reduce distant ones to placeholders. Ownership of a collapse is
-- intentionally canvas state, not lease state:
-- `state.collapsed[path] == "auto"` means this controller may expand it again;
-- `"user"` must survive virtualization and is the only kind session persists.
-- The LRU's `tick`/`tick_of`, by contrast, describe one producer lifetime and
-- therefore live on its opaque lease.
local current = nil
local next_id = 0

local function exact(lease)
  return lease ~= nil and current == lease and not lease.disposed
end

--- Add the owner's generation fence to the module's exact-lease check.
--- Recheck after `alive`: it is user code and may replace this lease
--- reentrantly before returning true.
local function active(lease)
  if not exact(lease) then
    return false
  end
  local alive = lease.callbacks.alive
  if not alive then
    return true
  end
  local ok, result = pcall(alive)
  return ok and result and exact(lease) or false
end

local function close_timer(timer)
  if not timer then
    return
  end
  pcall(function()
    timer:stop()
  end)
  local ok, closing = pcall(function()
    return timer:is_closing()
  end)
  if not ok or not closing then
    pcall(function()
      timer:close()
    end)
  end
end

--- Exact, idempotent teardown. The optional no-argument form exists for test
--- resets and attach replacement; owners should pass their stored lease.
function M.detach(expected)
  local lease = current
  if not lease or (expected and expected ~= lease) then
    return false
  end

  -- Invalidate first. Delete this exact group before handle methods: stop/close
  -- are external calls and may reentrantly attach a replacement whose group
  -- must not then be deleted by the old teardown.
  lease.disposed = true
  current = nil
  local aug = lease.aug
  local timer = lease.timer
  lease.aug = nil
  lease.timer = nil

  if aug then
    pcall(vim.api.nvim_del_augroup_by_id, aug)
  end
  close_timer(timer)

  -- Auto-collapse intent deliberately stays on state for session filtering.
  lease.state = nil
  lease.opts = nil
  lease.callbacks = {}
  lease.tick = 0
  lease.tick_of = {}
  return true
end

local function canvas_showing(state)
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

local function index_of_path(state, path)
  for i, section in ipairs(state.sections) do
    if section.path == path then
      return i
    end
  end
end

--- The changeset's fully-expanded row count. Buffer line count cannot be used:
--- the rendering shrinks as this policy collapses sections, so measuring it
--- would drop a just-over-threshold canvas back under the threshold on the next
--- pass, expand everything, and oscillate forever.
local function natural_line_count(state)
  local count = 0
  for _, section in ipairs(state.sections) do
    count = count + #section.entries
  end
  return count
end

local function publish(lease, state, changed)
  if not changed or not active(lease) then
    return changed
  end
  local on_change = lease.callbacks.on_change
  if on_change then
    -- Raw by design: owner callback failures are observable. Do not touch the
    -- lease after this call; the callback may dispose or replace it.
    on_change(state)
  end
  return changed
end

--- Apply the auto-virtualization policy once. Only the exact current lease may
--- mutate. Returns true exactly when canvas collapse state changed.
function M.apply(lease, opts)
  if not active(lease) then
    return false
  end
  if opts ~= nil then
    lease.opts = opts
  end

  local state = lease.state
  opts = lease.opts or {}
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return false
  end
  -- Resolve state.win now, never at attach time: Surface may rebind the primary
  -- window when a sibling split or tab survives.
  if not canvas_showing(state) then
    return false
  end

  local max_files = opts.max_files or math.huge
  local max_lines = opts.max_lines or math.huge
  local margin = opts.margin or 0
  local max_expanded = opts.max_expanded or math.huge
  local enabled = opts.enabled ~= false
  local policy_active = enabled
    and (#state.sections > max_files or natural_line_count(state) > max_lines)
  local changed = false

  if not policy_active then
    -- Collect before expanding: set_collapsed mutates this table.
    local mine = {}
    for path, intent in pairs(state.collapsed) do
      if intent == "auto" then
        mine[#mine + 1] = path
      end
    end
    for _, path in ipairs(mine) do
      if not exact(lease) then
        return changed
      end
      local index = index_of_path(state, path)
      if index then
        canvas.set_collapsed(state, index, false)
        changed = true
      else
        -- No section owns this path any more. Remove the dead bookkeeping
        -- claim, but do not publish a shape change because no row moved.
        state.collapsed[path] = nil
      end
      -- set_collapsed invokes state hooks synchronously; one can replace us.
      if not exact(lease) then
        return changed
      end
    end
    return publish(lease, state, changed)
  end

  lease.tick = lease.tick + 1
  local tick = lease.tick
  local tick_of = lease.tick_of

  local info = vim.api.nvim_win_call(state.win, function()
    return {
      top0 = vim.fn.line("w0") - 1,
      bot0 = vim.fn.line("w$") - 1,
    }
  end)
  local win_lo, win_hi = info.top0 - margin, info.bot0 + margin

  -- Classify on the original pre-splice rows so this pass's mutations cannot
  -- perturb its own viewport decision.
  local in_window = {}
  local distance = {}
  for i, section in ipairs(state.sections) do
    local start_row, end_row = canvas.section_rows(state, i)
    local visible = start_row <= win_hi and end_row > win_lo
    in_window[i] = visible
    if visible then
      tick_of[section.path] = tick
    elseif end_row <= win_lo then
      distance[i] = win_lo - end_row
    else
      distance[i] = start_row - win_hi
    end
  end

  -- Expand only this module's own in-window collapses. A user's collapse reads
  -- "user" and is never touched.
  for i, section in ipairs(state.sections) do
    if not exact(lease) then
      return changed
    end
    if in_window[i] and state.collapsed[section.path] == "auto" then
      canvas.set_collapsed(state, i, false)
      changed = true
      if not exact(lease) then
        return changed
      end
    end
  end

  local function count_expanded()
    local count = 0
    for _, section in ipairs(state.sections) do
      -- fold.hidden is the rendered predicate: a directory-folded section is
      -- already one row and must neither count as expanded nor become an
      -- auto-collapse candidate that the user would inherit on unfold.
      if not fold.hidden(state, section.path) then
        count = count + 1
      end
    end
    return count
  end

  local count = count_expanded()
  while count > max_expanded do
    if not exact(lease) then
      return changed
    end
    local best_i, best_tick, best_distance
    for i, section in ipairs(state.sections) do
      if not in_window[i] and not fold.hidden(state, section.path) then
        -- Oldest visibility tick wins (nil means never seen); ties evict the
        -- farthest section so near neighbors remain expanded longer.
        local seen = tick_of[section.path] or 0
        local far = distance[i] or 0
        if not best_tick or seen < best_tick
            or (seen == best_tick and far > best_distance) then
          best_i, best_tick, best_distance = i, seen, far
        end
      end
    end
    if not best_i then
      break
    end
    canvas.set_collapsed(state, best_i, true, "auto")
    changed = true
    count = count - 1
    if not exact(lease) then
      return changed
    end
  end

  return publish(lease, state, changed)
end

local function mark_dirty(lease)
  if not active(lease) then
    return
  end

  local timer = lease.timer
  if timer then
    pcall(function()
      timer:stop()
    end)
    if not active(lease) then
      return
    end
  else
    timer = vim.uv.new_timer()
    if not timer then
      return
    end
    lease.timer = timer
  end

  local scheduled = vim.schedule_wrap(function()
    if not active(lease) then
      return
    end
    M.apply(lease)
  end)
  pcall(function()
    timer:start(50, 0, function()
      if not active(lease) then
        return
      end
      scheduled()
    end)
  end)
end

--- Install the scroll producer and run one immediate policy pass.
function M.attach(state, opts, callbacks)
  if current then
    local predecessor = current
    M.detach(predecessor)
    if current then
      error("virtualizer attach was superseded during predecessor teardown", 0)
    end
  end

  next_id = next_id + 1
  local lease = {
    id = next_id,
    state = state,
    opts = opts or {},
    callbacks = callbacks or {},
    timer = nil,
    aug = nil,
    tick = 0,
    tick_of = {},
    disposed = false,
  }
  current = lease

  local ok, err = pcall(function()
    lease.aug = vim.api.nvim_create_augroup("canvasdiff.virt", { clear = true })
    vim.api.nvim_create_autocmd("WinScrolled", {
      group = lease.aug,
      callback = function(ev)
        if not active(lease) then
          return
        end
        local state_now = lease.state
        local win = tonumber(ev.match)
        if win ~= state_now.win or not vim.api.nvim_win_is_valid(win)
            or vim.api.nvim_win_get_buf(win) ~= state_now.buf then
          return
        end
        mark_dirty(lease)
      end,
    })
    M.apply(lease)
    if not exact(lease) then
      error("virtualizer attach was superseded during initial apply", 0)
    end
  end)
  if not ok then
    -- Exact cleanup cannot tear down a replacement installed reentrantly by a
    -- failing owner callback.
    M.detach(lease)
    error(err, 0)
  end
  return lease
end

return M
