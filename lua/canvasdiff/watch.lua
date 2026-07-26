local canvas = require("canvasdiff.canvas")
local collect = require("canvasdiff.collect")
local config = require("canvasdiff.config")
local lens = require("canvasdiff.diff").lens
local system = require("canvasdiff.os")

local W = {}

local current = nil
local next_id = 0

--- Owner callbacks are part of the synchronous reconcile contract. Do not
--- protect them here: a broken refresh must be observable to a direct caller
--- and to Neovim's scheduled-callback error reporting, never converted into a
--- false successful refresh.
local function call(callback, ...)
  if callback then
    return callback(...)
  end
end

--- An asynchronous producer may run only for the exact lease that installed
--- it. `alive` lets the owner add its own lifetime/generation fence without
--- teaching this low-level module about App or Surface.
local function is_active(lease)
  if current ~= lease or lease.disposed then
    return false
  end
  local alive = lease.callbacks.alive
  if not alive then
    return true
  end
  local ok, result = pcall(alive)
  return ok and result and true or false
end

local function close_handle(handle)
  if not handle then
    return
  end
  pcall(function()
    handle:stop()
  end)
  local ok, closing = pcall(function()
    return handle:is_closing()
  end)
  if not ok or not closing then
    pcall(function()
      handle:close()
    end)
  end
end

local function close_fs_handles(lease)
  local handles = lease.fs_handles
  lease.fs_handles = {}
  for _, handle in ipairs(handles) do
    close_handle(handle)
  end
end

--- Tear down the current watch. When `expected` is supplied, it is an identity
--- guard: a delayed owner of lease A cannot stop replacement lease B.
function W.stop(expected)
  local lease = current
  if not lease or (expected and expected ~= lease) then
    return false
  end

  -- Invalidate every queued callback before the first teardown side effect.
  lease.disposed = true
  current = nil

  local timer = lease.timer
  local aug = lease.aug
  lease.timer = nil
  lease.aug = nil
  lease.last_error = nil

  -- Delete the old event source before invoking handle methods: a fault-
  -- injection handle may reentrantly start replacement B, reusing this shared
  -- group ID. Deleting A's ID afterward would then tear down B's autocmds.
  if aug then
    pcall(vim.api.nvim_del_augroup_by_id, aug)
  end
  close_handle(timer)
  close_fs_handles(lease)

  -- A queued closure retains the lease until it drains. Drop its potentially
  -- large state and owner callback graph now; the identity/disposed check above
  -- is all that stale closure is allowed to observe.
  lease.state = nil
  lease.callbacks = {}
  return true
end

--- Synchronously collect truth and reconcile one canvas. This operation has no
--- UI dependencies: its owner receives the result and decides which consumers
--- to refresh.
function W.reconcile(state, callbacks)
  callbacks = callbacks or {}

  local function fail(err)
    call(callbacks.on_error, err)
    return nil, err
  end

  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return fail("no valid canvas state to reconcile")
  end

  local desired, err = collect.sections(
    state.root, lens.of(state), config.options.context)
  if not desired then
    -- Transactional failure: no canvas reconciliation and no success callback
    -- gets to observe a fabricated or half-refreshed state.
    return fail(err)
  end

  local full = canvas.reconcile_sections(state, desired)
  local result = {
    full = full and true or false,
    empty = #desired == 0,
    desired = desired,
  }

  if result.full and result.empty then
    call(callbacks.on_empty)
  end
  call(callbacks.on_change, state, result)
  return true, result
end

local refresh_fs_watches

local function lease_callbacks(lease)
  return {
    on_empty = function()
      if not is_active(lease) then
        return
      end
      call(lease.callbacks.on_empty)
    end,
    on_error = function(err)
      if not is_active(lease) then
        return
      end
      if err == lease.last_error then
        return
      end
      lease.last_error = err
      call(lease.callbacks.on_error, err)
    end,
    on_change = function(state, result)
      if not is_active(lease) then
        return
      end
      lease.last_error = nil
      call(lease.callbacks.on_change, state, result)
    end,
  }
end

local function mark_dirty(lease)
  if not is_active(lease) then
    return
  end

  local timer = lease.timer
  if timer then
    pcall(function()
      timer:stop()
    end)
  else
    lease.timer = system.new_timer()
    if not lease.timer then
      return
    end
    timer = lease.timer
  end

  -- There are two asynchronous boundaries here. The libuv callback and the
  -- scheduled main-loop callback each carry and validate the exact lease, so
  -- replacement between those boundaries cannot redirect A's event into B.
  local scheduled = vim.schedule_wrap(function()
    if not is_active(lease) then
      return
    end
    local ok = W.reconcile(lease.state, lease_callbacks(lease))
    if ok and is_active(lease) then
      -- Rebuild coverage only after a successful truth pass. On an invalid or
      -- deleted ref, the prior watcher set remains intact for recovery.
      refresh_fs_watches(lease)
    end
  end)

  pcall(function()
    timer:start(lease.debounce_ms, 0, function()
      if not is_active(lease) then
        return
      end
      scheduled()
    end)
  end)
end

local function watch_dir(lease, path, filter)
  if not is_active(lease) then
    return
  end

  local handle = system.new_fs_event()
  if not handle then
    return
  end

  local ok, started = pcall(function()
    return handle:start(path, {}, function(_, filename, _)
      if not is_active(lease) then
        return
      end
      if filter and filename and not filter(filename) then
        return
      end
      mark_dirty(lease)
    end)
  end)
  if not ok or not started then
    close_handle(handle)
    return
  end
  lease.fs_handles[#lease.fs_handles + 1] = handle
end

--- Rebuild fs_event coverage for this exact lease: repo root, .git (excluding
--- lock churn), and parent directories of currently changed files.
refresh_fs_watches = function(lease)
  if not is_active(lease) then
    return
  end

  close_fs_handles(lease)
  if not is_active(lease) then
    return
  end

  local state = lease.state
  watch_dir(lease, state.root)
  watch_dir(lease, vim.fs.joinpath(state.root, ".git"), function(name)
    return not name:match("%.lock$")
  end)

  local seen = {}
  for _, section in ipairs(state.sections) do
    local dir = vim.fs.dirname(vim.fs.joinpath(state.root, section.path))
    if dir ~= state.root and not seen[dir] then
      seen[dir] = true
      watch_dir(lease, dir)
    end
  end
end

--- Start watching `state`, replacing any previous singleton lease.
function W.start(state, opts, callbacks)
  W.stop()
  next_id = next_id + 1

  local lease = {
    id = next_id,
    state = state,
    callbacks = callbacks or {},
    debounce_ms = (opts and opts.debounce_ms) or 200,
    timer = nil,
    fs_handles = {},
    aug = nil,
    last_error = nil,
    disposed = false,
  }
  current = lease

  local ok, err = pcall(function()
    lease.aug = vim.api.nvim_create_augroup("canvasdiff.watch", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = lease.aug,
      callback = function(ev)
        if not is_active(lease) then
          return
        end
        local name = vim.api.nvim_buf_get_name(ev.buf)
        if name ~= "" and vim.startswith(name, lease.state.root .. "/") then
          mark_dirty(lease)
        end
      end,
    })
    vim.api.nvim_create_autocmd("FocusGained", {
      group = lease.aug,
      callback = function()
        if not is_active(lease) then
          return
        end
        mark_dirty(lease)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = lease.aug,
      buffer = state.buf,
      callback = function()
        if not is_active(lease) then
          return
        end
        W.stop(lease)
      end,
    })
    refresh_fs_watches(lease)
  end)
  if not ok then
    W.stop(lease)
    error(err, 0)
  end
  return lease
end

return W
