-- The short chaos campaign that runs as part of the ordinary suite.
--
-- The full Phase 7 campaign is 10,000 actions across several seeds, which is
-- far too slow to sit in `make test`; that lives in `benchmark/chaos/run.lua`.
-- What belongs here is a campaign short enough to run every time and long
-- enough to catch a regression the moment it lands -- so the seams are the
-- same, only the action count differs.
--
-- Seeds are fixed rather than random. A suite whose coverage changes run to
-- run cannot tell you whether a fix worked.

local H = require("helpers")
local Chaos = require("fault.chaos")

local SEEDS = { 20260727, 990001, 4242 }
local ACTIONS = 250

local T = {}

--- Fail with the recipe to reproduce, not just the assertion.
local function report(result)
  if result.status == "ok" then
    return nil
  end
  local lines = {
    ("chaos seed %d failed at action %d (%s)")
      :format(result.seed, result.failed_at, result.failed_action),
    "replay: make test SUITE=fault FILTER='^chaos_'",
    ("or: benchmark/chaos/run.lua with seed %d"):format(result.seed),
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
  T[("chaos_ the paged engine holds every invariant under seed %d"):format(seed)] =
    function()
      local window = vim.api.nvim_get_current_win()
      local result = Chaos.run({
        seed = seed,
        actions = ACTIONS,
        window = window,
      })
      local failure = report(result)
      assert(not failure, failure)

      -- A campaign that never reached the interesting actions proves nothing,
      -- so assert the shape of what actually ran.
      H.eq(result.actions, ACTIONS, "every action ran")
      local distinct = 0
      for _ in pairs(result.counts) do
        distinct = distinct + 1
      end
      assert(distinct >= 8, (
        "seed %d exercised only %d distinct actions"
      ):format(seed, distinct))
    end
end

T["chaos_ a seed replays to exactly the same campaign"] = function()
  -- Determinism is the property that makes a failure actionable. If two runs
  -- of one seed diverge, no recorded history means anything.
  local window = vim.api.nvim_get_current_win()
  local first = Chaos.run({ seed = 777, actions = 120, window = window })
  local second = Chaos.run({ seed = 777, actions = 120, window = window })
  H.eq(first.status, "ok", first.error)
  H.eq(second.status, "ok", second.error)
  H.eq(second.counts, first.counts, "the same seed ran the same actions")
  H.eq(second.rows, first.rows, "the same seed ended at the same row count")
end

T["chaos_ two different seeds do not run the same campaign"] = function()
  local window = vim.api.nvim_get_current_win()
  local a = Chaos.run({ seed = 111, actions = 120, window = window })
  local b = Chaos.run({ seed = 222, actions = 120, window = window })
  H.eq(a.status, "ok", a.error)
  H.eq(b.status, "ok", b.error)
  assert(not vim.deep_equal(a.counts, b.counts),
    "two seeds produced identical action histograms, so the seed is ignored")
end

return T
