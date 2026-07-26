local canvas = require("galley.canvas")
local collect = require("galley.collect")
local config = require("galley.config")
local hl = require("galley.hl")
local sidebar = require("galley.sidebar")
local scrollbar = require("galley.scrollbar")
local virt = require("galley.virt")
local lens = require("galley.lens")

local W = {}

--- Assignable callback: fired by reconcile when the canvas becomes empty
--- (all changes gone), so the owner can render its empty-state message.
W.on_empty = nil

--- Assignable callback for a scheduled reconcile failure. The synchronous
--- W.reconcile API returns the error to its caller; the timer has no caller, so
--- this seam lets init report it without coupling watch to notification policy.
--- Identical consecutive failures are reported only once.
W.on_error = nil

local uv = vim.uv

-- Trigger state: one live watched canvas at a time (mirrors init's
-- singleton). All handles are torn down by stop().
local live = nil
local debounce_ms = 200
local timer = nil
local aug = nil
local fs_handles = {}
local last_error = nil

local function close_fs_handles()
  for _, h in ipairs(fs_handles) do
    pcall(function()
      h:stop()
      h:close()
    end)
  end
  fs_handles = {}
end

-- Forward-declared local (not global): mark_dirty's scheduled callback calls
-- this, but it's only defined below. Declaring the upvalue here lets both
-- functions close over the same local.
local refresh_fs_watches

local function mark_dirty()
  if not live then
    return
  end
  if not timer then
    timer = uv.new_timer()
  end
  timer:stop()
  timer:start(debounce_ms, 0, vim.schedule_wrap(function()
    local state = live
    if state then
      local ok, err = W.reconcile(state)
      if ok then
        last_error = nil
        -- refresh_fs_watches starts by closing the existing handles. Only do
        -- that after a successful truth pass; on an invalid/deleted ref, the
        -- prior canvas and its watcher coverage stay intact for recovery.
        if live == state then
          refresh_fs_watches(state)
        end
      elseif err ~= last_error then
        last_error = err
        if W.on_error then
          pcall(W.on_error, err)
        end
      end
    end
  end))
end

local function watch_dir(path, filter)
  local h = uv.new_fs_event()
  if not h then
    return
  end
  local ok = h:start(path, {}, function(_, filename, _)
    if filter and filename and not filter(filename) then
      return
    end
    mark_dirty()
  end)
  if not ok then
    pcall(function() h:close() end)
    return
  end
  fs_handles[#fs_handles + 1] = h
end

--- (Re)build the fs_event watcher set: repo root (non-recursive -- Linux
--- inotify has no recursive watch), .git (index/HEAD flips; *.lock churn
--- filtered), and the parent dirs of currently-changed files. Subdir
--- changes with no watcher are covered by BufWritePost/FocusGained.
refresh_fs_watches = function(state)
  close_fs_handles()
  if not live then
    return
  end
  watch_dir(state.root)
  watch_dir(vim.fs.joinpath(state.root, ".git"), function(name)
    return not name:match("%.lock$")
  end)
  local seen = {}
  for _, sec in ipairs(state.sections) do
    local dir = vim.fs.dirname(vim.fs.joinpath(state.root, sec.path))
    if dir ~= state.root and not seen[dir] then
      seen[dir] = true
      watch_dir(dir)
    end
  end
end

--- Start live-watching for `state` (stopping any previous watch first).
function W.start(state, opts)
  W.stop()
  live = state
  last_error = nil
  debounce_ms = (opts and opts.debounce_ms) or 200

  aug = vim.api.nvim_create_augroup("galley.watch", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = aug,
    callback = function(ev)
      if not live then
        return
      end
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if name ~= "" and vim.startswith(name, live.root .. "/") then
        mark_dirty()
      end
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = aug,
    callback = mark_dirty,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = aug,
    buffer = state.buf,
    callback = function()
      W.stop()
    end,
  })

  refresh_fs_watches(state)
end

--- Tear everything down. Safe when never started.
function W.stop()
  if timer then
    timer:stop()
  end
  close_fs_handles()
  if aug then
    pcall(vim.api.nvim_del_augroup_by_id, aug)
    aug = nil
  end
  live = nil
  last_error = nil
end

--- Synchronous full reconcile of the live canvas against the working tree:
--- collect desired sections, then splice the difference section-by-section.
--- Sections whose old_text AND new_text are unchanged are never touched, so
--- their anchors, highlight marks, and rows stay exactly as they are -- the
--- niri invariant then rests entirely on the canvas splice primitives.
function W.reconcile(state)
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return nil, "no valid canvas state to reconcile"
  end
  local desired, err = collect.sections(
    state.root, lens.of(state), config.options.context)
  if not desired then
    -- Transactional failure: no canvas reconciliation and no follow-up UI
    -- consumer gets to observe a half-refreshed or fabricated empty state.
    return nil, err
  end

  -- The merge-walk itself lives in canvas, because a user-initiated LENS pivot
  -- needs exactly the same "splice only what actually differs" behaviour and has
  -- no business routing through the file-watch module to get it.
  local full = canvas.reconcile_sections(state, desired)
  if full and #desired == 0 and W.on_empty then
    W.on_empty()
  end

  hl.apply_now(state)
  sidebar.refresh(state)
  scrollbar.update(state)
  virt.apply(state, config.options.virt)
  return true
end

return W
