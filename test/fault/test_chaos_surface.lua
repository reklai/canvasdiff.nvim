-- The Surface-level chaos campaign, run as part of the ordinary suite.
--
-- Where `test_chaos.lua` hammers the engine, this hammers everything above it
-- against a real Git fixture: opening, closing, refreshing, pivoting lenses,
-- splitting and closing windows, writing to the worktree, and injecting Git
-- and session-write failures -- asserting after every action that no augroup
-- outlives the Surface that owned it and that no two live Surfaces claim one
-- canvas buffer.

local H = require("helpers")
local Chaos = require("fault.chaos_surface")

local SEEDS = { 31337, 20260728, 8675309 }
local ACTIONS = 60

local T = {}

local function report(result)
  if result.status == "ok" then
    return nil
  end
  local lines = {
    ("surface chaos seed %d failed at action %d (%s)")
      :format(result.seed, result.failed_at, result.failed_action),
    "replay: make test SUITE=fault FILTER='^chaos_surface'",
    "recent actions:",
  }
  local history = result.history or {}
  for index = math.max(1, #history - 30), #history do
    lines[#lines + 1] = ("  %4d  %s"):format(index, history[index])
  end
  lines[#lines + 1] = result.error
  return table.concat(lines, "\n")
end

for _, seed in ipairs(SEEDS) do
  T[("chaos_surface_ ownership survives seed %d"):format(seed)] = function()
    local original = vim.fn.getcwd()
    local result = Chaos.run({ seed = seed, actions = ACTIONS })
    pcall(vim.api.nvim_set_current_dir, original)
    local failure = report(result)
    assert(not failure, failure)

    H.eq(result.actions, ACTIONS, "every action ran")
    local distinct = 0
    for _ in pairs(result.counts) do
      distinct = distinct + 1
    end
    assert(distinct >= 6, (
      "seed %d exercised only %d distinct actions"
    ):format(seed, distinct))
  end
end

T["chaos_surface_ injected Git and session failures are contained"] = function()
  -- A campaign where nothing hostile ran proves nothing, so the injections
  -- are asserted to have happened rather than assumed.
  local original = vim.fn.getcwd()
  local result = Chaos.run({ seed = 4242, actions = 80 })
  pcall(vim.api.nvim_set_current_dir, original)
  local failure = report(result)
  assert(not failure, failure)

  local total = 0
  for _, count in pairs(result.refusals) do
    total = total + count
  end
  assert(total > 0,
    "no injected failure ran, so nothing hostile was actually tested")
end

T["chaos_surface_ a seed replays to the same campaign"] = function()
  local original = vim.fn.getcwd()
  local first = Chaos.run({ seed = 909, actions = 40 })
  local second = Chaos.run({ seed = 909, actions = 40 })
  pcall(vim.api.nvim_set_current_dir, original)
  H.eq(first.status, "ok", first.error)
  H.eq(second.status, "ok", second.error)
  H.eq(second.counts, first.counts, "the same seed ran different actions")
end

return T
