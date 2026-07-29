local canvas = require("canvasdiff.canvas")
local config = require("canvasdiff.config")
local lens = require("canvasdiff.diff").lens
local system = require("canvasdiff.os")
local source = require("canvasdiff.source")

local W = {}

-- Filesystem/autocmd production belongs to the runtime domain. This internal
-- owner is exposed only through the curated canvasdiff.runtime facade.
local next_id = 0
-- Authentication is lookup-only: weak keys cannot retain or select a lease,
-- and ownership/lifetime still belongs exclusively to the Surface holding it.
local lease_auth = setmetatable({}, { __mode = "k" })

local function exact(lease)
  return type(lease) == "table"
    and lease_auth[lease] == true
    and not lease.disposed
end

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

--- Tear down one exact watch lease. There is deliberately no unqualified
--- process-global stop: each Surface owns and releases only its own producer.
function W.stop(lease)
  if not exact(lease) then
    return false
  end

  -- Invalidate every queued callback before the first teardown side effect.
  lease_auth[lease] = nil
  lease.disposed = true

  local timer = lease.timer
  local aug = lease.aug
  lease.timer = nil
  lease.aug = nil
  lease.last_error = nil

  -- Delete the event source before invoking handle methods. A fault-injection
  -- handle may reentrantly start another lease, which must remain independent.
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
local function reconcile(state, callbacks, lease)
  callbacks = callbacks or {}
  local publication

  local function current()
    if lease and not is_active(lease) then
      return false
    end
    local callback = callbacks.current
    return not callback or callback(publication) == true
  end

  local function fail(err)
    call(callbacks.on_error, err)
    return nil, err
  end

  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return fail("no valid canvas state to reconcile")
  end

  if callbacks.begin then
    publication = call(callbacks.begin, state)
    if publication == nil or not current() then
      return false
    end
  end
  local collected_lens = lens.of(state)
  local desired, err = source.sections(
    state.root, collected_lens, config.options.context)
  -- Collection is an I/O boundary. The owner may die or explicitly stop this
  -- exact lease, or publish a newer model intent, while source.sections is
  -- running; never commit that stale snapshot into its former canvas.
  if not current() then
    return false
  end
  if not desired then
    -- Transactional failure: no canvas reconciliation and no success callback
    -- gets to observe a fabricated or half-refreshed state.
    return fail(err)
  end

  local full
  if callbacks.publish then
    local published, publish_err, published_full =
      call(callbacks.publish, state, desired, publication)
    if not current() then
      return false
    end
    if not published then
      return fail(publish_err or "watch publication failed")
    end
    full = published_full
  else
    full = canvas.reconcile_sections(state, desired)
    if not current() then
      return false
    end
  end
  local result = {
    full = full and true or false,
    empty = #desired == 0,
    desired = desired,
  }

  if result.full and result.empty then
    call(callbacks.on_empty)
    if not current() then
      return false
    end
  end
  call(callbacks.on_change, state, result)
  if not current() then
    return false
  end
  return true, result
end

function W.reconcile(state, callbacks)
  return reconcile(state, callbacks)
end

local refresh_fs_watches

local function lease_callbacks(lease)
  return {
    begin = lease.callbacks.begin and function(state)
      if not is_active(lease) then
        return nil
      end
      return call(lease.callbacks.begin, state)
    end or nil,
    current = function(publication)
      if not is_active(lease) then
        return false
      end
      local callback = lease.callbacks.current
      return not callback or callback(publication) == true
    end,
    publish = lease.callbacks.publish and function(state, desired, publication)
      if not is_active(lease) then
        return false
      end
      return call(lease.callbacks.publish, state, desired, publication)
    end or nil,
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
    if not is_active(lease) then
      return
    end
  else
    timer = system.new_timer()
    if not timer then
      return
    end
    if not is_active(lease) then
      close_handle(timer)
      return
    end
    lease.timer = timer
  end

  -- There are two asynchronous boundaries here. The libuv callback and the
  -- scheduled main-loop callback each carry and validate the exact lease, so
  -- owner invalidation between them cannot redirect A's event into peer B.
  local scheduled = vim.schedule_wrap(function()
    if not is_active(lease) then
      return
    end
    local ok = reconcile(lease.state, lease_callbacks(lease), lease)
    if ok and is_active(lease) then
      -- Rebuild coverage only after a successful truth pass. On an invalid or
      -- deleted ref, the prior watcher set remains intact for recovery.
      refresh_fs_watches(lease)
    end
  end)
  if not is_active(lease) then
    return
  end

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
  if not is_active(lease) then
    close_handle(handle)
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
  if not ok or not started or not is_active(lease) then
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

--- Start one independent watch lease. The caller owns its exact teardown.
function W.start(state, opts, callbacks)
  next_id = next_id + 1

  local lease = {
    id = next_id,
    group_name = ("canvasdiff.watch.%d"):format(next_id),
    state = state,
    callbacks = callbacks or {},
    debounce_ms = (opts and opts.debounce_ms) or 200,
    timer = nil,
    fs_handles = {},
    aug = nil,
    last_error = nil,
    disposed = false,
  }
  lease_auth[lease] = true

  local ok, err = pcall(function()
    local aug = vim.api.nvim_create_augroup(lease.group_name, { clear = true })
    if not is_active(lease) then
      pcall(vim.api.nvim_del_augroup_by_id, aug)
      error("watch owner became inactive during augroup creation", 0)
    end
    lease.aug = aug
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
    if not is_active(lease) then
      error("watch owner became inactive during start", 0)
    end
  end)
  if not ok then
    W.stop(lease)
    error(err, 0)
  end
  return lease
end

return W
