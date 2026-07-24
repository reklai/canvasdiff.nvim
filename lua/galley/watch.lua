local canvas = require("galley.canvas")
local model = require("galley.model")
local collect = require("galley.collect")
local config = require("galley.config")
local hl = require("galley.hl")
local sidebar = require("galley.sidebar")
local scrollbar = require("galley.scrollbar")
local virt = require("galley.virt")

local W = {}

--- Assignable callback: fired by reconcile when the canvas becomes empty
--- (all changes gone), so the owner can render its empty-state message.
W.on_empty = nil

local uv = vim.uv

-- Trigger state: one live watched canvas at a time (mirrors init's
-- singleton). All handles are torn down by stop().
local live = nil
local debounce_ms = 200
local timer = nil
local aug = nil
local fs_handles = {}

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
      W.reconcile(state)
      refresh_fs_watches(state)
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
end

--- Synchronous full reconcile of the live canvas against the working tree:
--- collect desired sections, then splice the difference section-by-section.
--- Sections whose old_text AND new_text are unchanged are never touched, so
--- their anchors, highlight marks, and rows stay exactly as they are -- the
--- niri invariant then rests entirely on the canvas splice primitives.
function W.reconcile(state)
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local desired = model.build(collect.files(state.root, state.base), config.options.context)

  -- 0 <-> N transitions: the empty canvas holds a placeholder line, not
  -- sections; splicing against it is meaningless. Full re-render instead.
  if #state.sections == 0 or #desired == 0 then
    if #state.sections ~= 0 or #desired ~= 0 then
      canvas.render_all(state, desired)
      if #desired == 0 and W.on_empty then
        W.on_empty()
      end
      hl.apply_now(state)
      sidebar.refresh(state)
      scrollbar.update(state)
      virt.apply(state, config.options.virt)
    end
    return
  end

  -- Both lists are sorted by path: sorted merge-walk.
  local i, j = 1, 1
  while i <= #state.sections or j <= #desired do
    local cur = state.sections[i]
    local des = desired[j]
    if cur and des and cur.path == des.path then
      if cur.old_text ~= des.old_text or cur.new_text ~= des.new_text then
        canvas.replace_section(state, i, des)
      end
      i, j = i + 1, j + 1
    elseif cur and (not des or cur.path < des.path) then
      if #state.sections == 1 then
        -- Deleting the last remaining section would leave the
        -- placeholder-line empty canvas, which splices can't target;
        -- finish with a full render of whatever is desired instead.
        canvas.render_all(state, desired)
        hl.apply_now(state)
        sidebar.refresh(state)
        scrollbar.update(state)
        virt.apply(state, config.options.virt)
        return
      end
      canvas.replace_section(state, i, nil) -- delete shrinks the list; keep i
    else
      canvas.insert_section(state, i, des)
      i, j = i + 1, j + 1
    end
  end

  hl.apply_now(state)
  sidebar.refresh(state)
  scrollbar.update(state)
  virt.apply(state, config.options.virt)
end

return W
