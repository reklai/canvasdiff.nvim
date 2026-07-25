local canvas = require("galley.canvas")
local fold = require("galley.fold")

local M = {}

--- Assignable callback: fired once at the end of an apply that actually
--- changed collapse state, so the owner can resync the consumers that read
--- state.collapsed (highlighting, sidebar, scrollbar). None of them sees
--- these splices on its own -- they land on this module's private debounce,
--- after the other consumers' own scroll handlers have already run, and a
--- collapse fully below the viewport moves no rows and so fires no further
--- WinScrolled to bring them back.
M.on_change = nil

-- Tier-1 auto-virtualization: when a changeset is huge, far-from-viewport
-- sections auto-collapse and near ones auto-expand. `auto` is the set of
-- paths THIS module collapsed on its own (module intent, never persisted as
-- user intent -- session.lua reads auto_set() to exclude these). A path the
-- user collapsed directly (via canvas.set_collapsed, outside virt) is in
-- state.collapsed but NOT in `auto`, so the expand pass -- and deactivation
-- -- never touches it.
local auto = {}
local tick_of = {}
local tick = 0

-- Trigger state: one live watched canvas at a time (mirrors watch.lua's/
-- hl.lua's singleton discipline). All handles are torn down by detach().
local live = nil
local live_opts = nil
local timer = nil

local function canvas_showing(state)
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

local function index_of_path(state, path)
  for i, sec in ipairs(state.sections) do
    if sec.path == path then
      return i
    end
  end
end

--- The changeset's FULLY-EXPANDED row count: one row per entry in every
--- section (render.section_lines emits exactly that), whatever is collapsed
--- right now. Deliberately NOT nvim_buf_line_count -- the rendered buffer
--- shrinks as this module's own collapses land, so a changeset only just
--- over max_lines would fall back under it on the next apply, deactivate,
--- expand everything back, and leave the canvas oscillating between
--- virtualized and fully rendered on every scroll.
local function natural_line_count(state)
  local n = 0
  for _, sec in ipairs(state.sections) do
    n = n + #sec.entries
  end
  return n
end

--- Snapshot of the module's own auto-collapsed paths (shallow copy -- the
--- caller must not be able to mutate module state through it).
function M.auto_set()
  local copy = {}
  for path, v in pairs(auto) do
    copy[path] = v
  end
  return copy
end

--- Disclaim `path` as module intent: delete it from the auto-set and its
--- tick bookkeeping. Safe no-op when virt is inactive/unattached or `path`
--- was never auto-collapsed. Called whenever USER intent takes over a path
--- this module had claimed -- the explicit collapse keymaps (init's
--- user_set_collapsed) and session.restore -- so that collapse is never
--- later auto-expanded back or excluded from a future session.save.
function M.unauto(path)
  auto[path] = nil
  tick_of[path] = nil
end

local function notify_change(state, changed)
  if changed and M.on_change then
    M.on_change(state)
  end
end

--- Apply the AUTO virtualization policy once, synchronously, against the
--- live viewport. No-op unless the canvas is actually showing in state.win.
--- Fires M.on_change once at the end when the pass moved anything.
function M.apply(state, opts)
  opts = opts or {}
  if not state or not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  if not canvas_showing(state) then
    return
  end

  local max_files = opts.max_files or math.huge
  local max_lines = opts.max_lines or math.huge
  local margin = opts.margin or 0
  local max_expanded = opts.max_expanded or math.huge

  local active = opts.enabled ~= false
    and (#state.sections > max_files or natural_line_count(state) > max_lines)

  local changed = false

  if not active then
    for path in pairs(auto) do
      local idx = index_of_path(state, path)
      if idx then
        canvas.set_collapsed(state, idx, false)
        changed = true
      end
    end
    auto = {}
    notify_change(state, changed)
    return
  end

  tick = tick + 1

  local info = vim.api.nvim_win_call(state.win, function()
    return { top0 = vim.fn.line("w0") - 1, bot0 = vim.fn.line("w$") - 1 }
  end)
  local win_lo, win_hi = info.top0 - margin, info.bot0 + margin

  -- One pass over the ORIGINAL (pre-splice) rows: classify in/out of window,
  -- record each out-of-window section's distance from the nearest window
  -- edge, and bump last-seen ticks. Computed up front so later mutating
  -- passes (which shift rows) never perturb this apply's own window
  -- classification.
  local in_window = {}
  local distance = {}
  for i, sec in ipairs(state.sections) do
    local srow, erow = canvas.section_rows(state, i)
    local iw = srow <= win_hi and erow > win_lo
    in_window[i] = iw
    if iw then
      tick_of[sec.path] = tick
    elseif erow <= win_lo then
      distance[i] = win_lo - erow
    else
      distance[i] = srow - win_hi
    end
  end

  -- Expand pass: in-window sections the MODULE collapsed get expanded back.
  -- User-collapsed sections are never in `auto`, so they're never touched.
  for i, sec in ipairs(state.sections) do
    if in_window[i] and auto[sec.path] then
      canvas.set_collapsed(state, i, false)
      auto[sec.path] = nil
      changed = true
    end
  end

  -- Collapse pass: while too many sections are expanded, evict the
  -- least-recently-visible one that's fully outside the window. Both this
  -- count and the candidate filter below use the DERIVED predicate, so a
  -- section a folded directory already reduced to one row is invisible to this
  -- module. Counting one as expanded would make it an eviction candidate:
  -- set_collapsed would claim it in `auto` while splicing nothing, the loop
  -- would decrement having freed zero rows, and the user would inherit a
  -- collapse on unfold.
  local function count_expanded()
    local n = 0
    for _, sec in ipairs(state.sections) do
      if not fold.hidden(state, sec.path) then
        n = n + 1
      end
    end
    return n
  end

  local count = count_expanded()
  while count > max_expanded do
    -- Smallest tick_of wins (nil = 0, oldest); ties broken by largest
    -- distance from the window, so a section that's never intersected the
    -- window at all evicts farthest-first, keeping near neighbors expanded
    -- longer -- consistent with "far sections auto-collapse, near ones
    -- auto-expand".
    local best_i, best_tick, best_dist
    for i, sec in ipairs(state.sections) do
      if not in_window[i] and not fold.hidden(state, sec.path) then
        local t = tick_of[sec.path] or 0
        local d = distance[i] or 0
        if not best_tick or t < best_tick or (t == best_tick and d > best_dist) then
          best_tick, best_dist, best_i = t, d, i
        end
      end
    end
    if not best_i then
      break
    end
    canvas.set_collapsed(state, best_i, true)
    auto[state.sections[best_i].path] = true
    count = count - 1
    changed = true
  end

  notify_change(state, changed)
end

--- Install a debounced (50ms) WinScrolled trigger for `state` and run one
--- immediate apply. Singleton discipline: re-attaching stops any previous
--- timer/augroup first.
function M.attach(state, opts)
  if timer then
    timer:stop()
  end

  -- Binding to a DIFFERENT canvas: auto/tick_of are keyed by path, but
  -- canvas.open always hands back a fresh state.collapsed, so the previous
  -- canvas's bookkeeping describes nothing in this one. Carrying it over
  -- would claim paths nothing has collapsed and -- worse -- let stale
  -- visibility ticks outrank everything the new canvas has actually seen,
  -- so the LRU would keep the farthest section rendered and collapse the
  -- nearest. (M.open can re-open without an intervening close via its
  -- sidebar-redirect branch, so this is reachable.)
  if live ~= state then
    auto = {}
    tick_of = {}
    tick = 0
  end

  live = state
  live_opts = opts

  vim.api.nvim_create_augroup("galley.virt", { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = "galley.virt",
    callback = function(ev)
      local win = tonumber(ev.match)
      if not (live and win == live.win and vim.api.nvim_win_is_valid(win)
          and vim.api.nvim_win_get_buf(win) == live.buf) then
        return
      end
      if not timer then
        timer = vim.uv.new_timer()
      end
      timer:stop()
      timer:start(50, 0, vim.schedule_wrap(function()
        M.apply(live, live_opts)
      end))
    end,
  })

  M.apply(state, opts)
end

--- Tear everything down: timer, augroup, the resync callback, and the
--- module's own auto-set/tick bookkeeping. Nil-safe; safe to call when never
--- attached.
function M.detach()
  if timer then
    timer:stop()
  end
  pcall(vim.api.nvim_del_augroup_by_name, "galley.virt")
  auto = {}
  tick_of = {}
  tick = 0
  live = nil
  live_opts = nil
  M.on_change = nil
end

return M
