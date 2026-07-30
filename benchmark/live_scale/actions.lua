-- A bounded, data-only journey for exercising a live-scale fixture.
-- The worker interprets these records; this module deliberately has no
-- Neovim state or executable callbacks.
local M = {}

local REQUIRED_NAMES = {
  "open", "sequential_scroll", "random_jump", "search", "yank",
  "fold", "unfold", "cycle_all", "cycle_staged", "cycle_unstaged",
  "manual_refresh", "watch_refresh", "file_next", "file_prev",
  "hunk_next", "hunk_prev", "jump", "back", "stage", "unstage",
  "branch_compare", "range_compare", "git_failure", "close_reopen",
  "close_orders", "final_close",
}

local MAX_VIEWPORTS = 200
local RANDOM_JUMPS = 200
local REBUILD_CYCLES = 3
local LCG_MODULUS = 2147483647
local LCG_MULTIPLIER = 48271

local function is_finite(value)
  return value == value and value ~= math.huge and value ~= -math.huge
end

local function assert_positive_integer(value, name)
  assert(type(value) == "number" and is_finite(value)
      and value == math.floor(value) and value >= 1,
    name .. " must be a positive integer")
end

local function lcg(seed)
  local state = seed % (LCG_MODULUS - 1)
  if state < 0 then
    state = state + LCG_MODULUS - 1
  end
  state = state + 1
  return function()
    state = (state * LCG_MULTIPLIER) % LCG_MODULUS
    return state
  end
end

local function add(plan, name, class, arguments)
  plan[#plan + 1] = { name = name, class = class, arguments = arguments }
end

local function evenly_spaced_row(index, samples, rows)
  if samples == 1 then
    return 1
  end
  return math.floor((index - 1) * (rows - 1) / (samples - 1)) + 1
end

function M.required_names()
  local result = {}
  for index, name in ipairs(REQUIRED_NAMES) do
    result[index] = name
  end
  return result
end

function M.plan(rows, seed)
  assert_positive_integer(rows, "rows")
  assert(type(seed) == "number" and is_finite(seed) and seed == math.floor(seed),
    "seed must be an integer")

  local plan = {}
  local next_random = lcg(seed)
  local viewport_count = math.min(rows, MAX_VIEWPORTS)
  local function random_row()
    return (next_random() % rows) + 1
  end

  add(plan, "open", "lifecycle", { rows = rows })
  for index = 1, viewport_count do
    add(plan, "sequential_scroll", "navigation", {
      row = evenly_spaced_row(index, viewport_count, rows),
    })
  end
  for _ = 1, RANDOM_JUMPS do
    add(plan, "random_jump", "navigation", { row = random_row() })
  end

  local yank_start = random_row()
  add(plan, "search", "query", { query = "scale" })
  add(plan, "yank", "selection", {
    start_row = yank_start,
    end_row = math.min(rows, yank_start + 1999),
  })
  add(plan, "fold", "view", { start_row = 1, end_row = math.min(rows, 2000) })
  add(plan, "unfold", "view", {})

  for _ = 1, REBUILD_CYCLES do
    add(plan, "cycle_all", "rebuild", {})
    add(plan, "cycle_staged", "rebuild", {})
    add(plan, "cycle_unstaged", "rebuild", {})
  end

  add(plan, "manual_refresh", "refresh", {})
  add(plan, "watch_refresh", "refresh", {})
  add(plan, "file_next", "navigation", {})
  add(plan, "file_prev", "navigation", {})
  add(plan, "hunk_next", "navigation", {})
  add(plan, "hunk_prev", "navigation", {})
  add(plan, "jump", "navigation", { row = random_row() })
  add(plan, "back", "navigation", {})
  add(plan, "stage", "mutation", { path = "unstaged.txt" })
  add(plan, "unstage", "mutation", { path = "staged.txt" })
  add(plan, "branch_compare", "comparison", { base = "scale-base", target = "scale-branch" })
  add(plan, "range_compare", "comparison", { range = "scale-base..scale-range" })
  add(plan, "git_failure", "failure", { ref = "refs/heads/does-not-exist" })
  add(plan, "close_reopen", "lifecycle", {})
  add(plan, "close_orders", "lifecycle", { order = { "working", "staged", "unstaged" } })
  add(plan, "final_close", "lifecycle", {})

  return plan
end

return M
