local H = require("helpers")
local actions = require("benchmark.live_scale.actions")

local T = {}

local required = {
  "open", "sequential_scroll", "random_jump", "search", "yank",
  "fold", "unfold", "cycle_all", "cycle_staged", "cycle_unstaged",
  "manual_refresh", "watch_refresh", "file_next", "file_prev",
  "hunk_next", "hunk_prev", "jump", "back", "stage", "unstage",
  "branch_compare", "range_compare", "git_failure", "close_reopen",
  "close_orders", "final_close",
}

local function names_in(plan)
  local found = {}
  for _, action in ipairs(plan) do
    found[action.name] = (found[action.name] or 0) + 1
  end
  return found
end

local function random_rows(plan)
  local rows = {}
  for _, action in ipairs(plan) do
    if action.name == "random_jump" then
      rows[#rows + 1] = action.arguments.row
    end
  end
  return rows
end

T["live_scale_actions_plan is deterministic serializable and seed-sensitive"] = function()
  local first = actions.plan(10000, 1729)
  local second = actions.plan(10000, 1729)
  local changed = actions.plan(10000, 1730)

  H.eq(vim.json.encode(first), vim.json.encode(second))
  assert(vim.json.encode(first), "plan must contain only JSON-serializable data")
  assert(not vim.deep_equal(random_rows(first), random_rows(changed)),
    "a different seed must change randomized jump rows")
end

T["live_scale_actions_plan bounds navigation and yank ranges for every size"] = function()
  for _, row_count in ipairs({ 1, 1000, 10000, 100000, 1000000 }) do
    local plan = actions.plan(row_count, 1729)
    local counts = names_in(plan)
    assert(#plan <= 435, "plan length must remain bounded independently of row count")
    H.eq(counts.sequential_scroll, math.min(row_count, 200))
    H.eq(counts.random_jump, 200)
    H.eq(counts.cycle_all, 3)
    H.eq(counts.cycle_staged, 3)
    H.eq(counts.cycle_unstaged, 3)
    for _, name in ipairs(required) do
      if name ~= "sequential_scroll" and name ~= "random_jump"
        and name ~= "cycle_all" and name ~= "cycle_staged" and name ~= "cycle_unstaged" then
        H.eq(counts[name], 1, name .. " must occur once per plan")
      end
    end

    for _, action in ipairs(plan) do
      H.eq(type(action.name), "string")
      H.eq(type(action.class), "string")
      H.eq(type(action.arguments), "table")
      if action.name == "random_jump" or action.name == "jump" then
        assert(action.arguments.row >= 1 and action.arguments.row <= row_count,
          "jump rows must stay inside the fixture")
      elseif action.name == "yank" then
        assert(action.arguments.end_row >= action.arguments.start_row)
        assert(action.arguments.end_row - action.arguments.start_row + 1 <= 2000,
          "yank spans must be capped at 2,000 rows")
      end
    end
  end
end

T["live_scale_actions_plan includes the complete lifecycle semantic set"] = function()
  H.eq(actions.required_names(), required)

  for _, row_count in ipairs({ 1, 1000, 10000, 100000, 1000000 }) do
    local counts = names_in(actions.plan(row_count, 1729))
    for _, name in ipairs(required) do
      assert(counts[name], "missing required lifecycle action: " .. name)
    end
  end
end

T["live_scale_actions_plan stages and unstages the same bounded sidecar"] = function()
  local stage_path, unstage_path
  for _, action in ipairs(actions.plan(1000000, 1729)) do
    if action.name == "stage" then
      stage_path = action.arguments.path
    elseif action.name == "unstage" then
      unstage_path = action.arguments.path
    end
  end
  H.eq(stage_path, "unstaged.txt")
  H.eq(unstage_path, stage_path,
    "the mutation pair must restore the exact file it staged")
end

T["live_scale_actions_plan rejects non-finite rows and seeds"] = function()
  local non_finite = { math.huge, -math.huge, 0 / 0 }

  for _, value in ipairs(non_finite) do
    local rows_ok = pcall(actions.plan, value, 1729)
    assert(not rows_ok, "rows must reject non-finite integers")

    local seed_ok = pcall(actions.plan, 1000, value)
    assert(not seed_ok, "seed must reject non-finite integers")
  end
end

return T
