local canvas = require("finding_myself.canvas")

local M = {}

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

--- Snapshot of the module's own auto-collapsed paths (shallow copy -- the
--- caller must not be able to mutate module state through it).
function M.auto_set()
  local copy = {}
  for path, v in pairs(auto) do
    copy[path] = v
  end
  return copy
end

--- Apply the AUTO virtualization policy once, synchronously, against the
--- live viewport. No-op unless the canvas is actually showing in state.win.
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
    and (#state.sections > max_files or vim.api.nvim_buf_line_count(state.buf) > max_lines)

  if not active then
    for path in pairs(auto) do
      local idx = index_of_path(state, path)
      if idx then
        canvas.set_collapsed(state, idx, false)
      end
    end
    auto = {}
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
    end
  end

  -- Collapse pass: while too many sections are expanded, evict the
  -- least-recently-visible one that's fully outside the window.
  local function count_expanded()
    local n = 0
    for _, sec in ipairs(state.sections) do
      if not state.collapsed[sec.path] then
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
      if not in_window[i] and not state.collapsed[sec.path] then
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
  end
end

--- Install a debounced (50ms) WinScrolled trigger for `state` and run one
--- immediate apply. Singleton discipline: re-attaching stops any previous
--- timer/augroup first.
function M.attach(state, opts)
  if timer then
    timer:stop()
  end
  live = state
  live_opts = opts

  vim.api.nvim_create_augroup("finding_myself.virt", { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = "finding_myself.virt",
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

--- Tear everything down: timer, augroup, and the module's own auto-set/tick
--- bookkeeping. Nil-safe; safe to call when never attached.
function M.detach()
  if timer then
    timer:stop()
  end
  pcall(vim.api.nvim_del_augroup_by_name, "finding_myself.virt")
  auto = {}
  tick_of = {}
  tick = 0
  live = nil
  live_opts = nil
end

return M
