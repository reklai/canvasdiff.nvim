-- The Surface-level chaos campaign, run as part of the ordinary suite.
--
-- Where `test_chaos.lua` hammers the engine, this hammers everything above it
-- against a real Git fixture: opening, closing, refreshing, pivoting lenses
-- (including branch and range pivots onto refs that were deleted meanwhile),
-- creating, deleting and committing to branches under a live review, staging,
-- close-and-reopen through the saved session, splitting and closing windows,
-- writing to the worktree, and injecting Git and session-write failures --
-- asserting after every action that no augroup outlives the Surface that
-- owned it, that no two live Surfaces claim one canvas buffer, and that a
-- remembered return lens is always somewhere <Tab> can actually go.

local H = require("helpers")
local Chaos = require("fault.chaos_surface")

local SEEDS = { 31337, 20260728, 8675309 }
local ACTIONS = 120
local REQUIRED_CONFIGURATION_ACTIONS = {
  "configure_appearance", "configure_invalid", "reset_config",
  "change_colorscheme", "toggle_glyph_set",
}

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

local function restore_test_colorscheme(name)
  if name then
    vim.cmd.colorscheme(name)
  else
    vim.cmd.colorscheme("default")
    vim.g.colors_name = nil
  end
  require("canvasdiff.appearance").setup({})
end

for _, seed in ipairs(SEEDS) do
  T[("chaos_surface_ ownership survives seed %d"):format(seed)] = function()
    local result = Chaos.run({ seed = seed, actions = ACTIONS })
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
    for _, action in ipairs(REQUIRED_CONFIGURATION_ACTIONS) do
      assert((result.counts[action] or 0) > 0,
        action .. " never ran: " .. vim.inspect(result.counts))
    end
  end
end

T["chaos_surface_ injected Git and session failures are contained"] = function()
  -- A campaign where nothing hostile ran proves nothing, so the injections
  -- are asserted to have happened rather than assumed.
  local result = Chaos.run({ seed = 4242, actions = 80 })
  local failure = report(result)
  assert(not failure, failure)

  local total = 0
  for _, count in pairs(result.refusals) do
    total = total + count
  end
  assert(total > 0,
    "no injected failure ran, so nothing hostile was actually tested")
end

-- The same principle, bound to the one action whose hostile branch carries an
-- invariant of its own -- the byte-exact index check after a killed hunk stage.
--
-- It needs its own assertion because that action can legitimately do NOTHING:
-- with no review showing, or none this harness captured at open time, it has no
-- hunk row to press and records itself as a noop. `refusals.stage_hunk` is
-- incremented only past both of those guards, on the branch that injects and
-- then compares the index -- so it is the one counter that cannot be satisfied
-- by a visit that pressed nothing. Without this, a change that quietly stopped
-- showing_review from ever matching would revert the whole action to
-- decoration and every campaign would still pass.
T["chaos_surface_ the hunk stage really runs under an injected Git failure"] = function()
  local result = Chaos.run({ seed = SEEDS[1], actions = ACTIONS })
  local failure = report(result)
  assert(not failure, failure)

  assert((result.refusals.stage_hunk or 0) > 0, (
    "stage_hunk never reached a real press with Git killed, so the byte-exact "
    .. "index invariant was never checked. counts=%s refusals=%s"
  ):format(vim.inspect(result.counts), vim.inspect(result.refusals)))
  assert((result.counts.stage_hunk or 0) > 0,
    "and the action must have pressed at least once, not only recorded noops")
end

T["chaos_surface_ a seed replays to the same campaign"] = function()
  local first = Chaos.run({ seed = 909, actions = 40 })
  local second = Chaos.run({ seed = 909, actions = 40 })
  H.eq(first.status, "ok", vim.inspect(first))
  H.eq(second.status, "ok", vim.inspect(second))
  H.eq(second.counts, first.counts, "the same seed ran different actions")
  assert(type(first.history) == "table",
    "a successful campaign must retain replay history")
  H.eq(#first.history, 40, "every replayed action must retain its history")
  H.eq(second.history, first.history,
    "the same seed selected different actions or arguments")
end

T["chaos_surface_ restores the caller's named colorscheme"] = function()
  local original = vim.g.colors_name
  vim.cmd.colorscheme("industry")
  local ok, err = xpcall(function()
    local result = Chaos.run({ seed = 31337, actions = ACTIONS })
    H.eq(result.status, "ok", result.error)
    H.eq(vim.g.colors_name, "industry",
      "the campaign leaked its default colorscheme into the caller")
  end, debug.traceback)

  restore_test_colorscheme(original)
  assert(ok, err)
end

T["chaos_surface_ restores a clean unnamed colorscheme and its highlights"] = function()
  local original = vim.g.colors_name
  vim.cmd.colorscheme("default")
  vim.api.nvim_set_hl(0, "Normal", { fg = "#abcdef", bg = "#010203" })
  vim.api.nvim_set_hl(0, "CanvasDiffFileBar", { bg = "#654321" })
  vim.api.nvim_set_hl(0, "CanvasDiffWinbar", {})
  vim.api.nvim_set_hl(0, "CanvasDiffCrumb", {})
  vim.g.colors_name = nil
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = true })
  local bar = vim.api.nvim_get_hl(0,
    { name = "CanvasDiffFileBar", link = true })
  local empty = vim.api.nvim_get_hl(0,
    { name = "CanvasDiffWinbar", link = true })
  local crumb = vim.api.nvim_get_hl(0,
    { name = "CanvasDiffCrumb", link = true })

  local ok, err = xpcall(function()
    local result = Chaos.run({ seed = 31337, actions = ACTIONS })
    H.eq(result.status, "ok", result.error)
    H.eq(vim.g.colors_name, nil, "the campaign invented a colorscheme name")
    H.eq(vim.api.nvim_get_hl(0, { name = "Normal", link = true }), normal,
      "the campaign did not restore the caller's unnamed palette")
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = true }), bar,
      "the campaign did not restore caller-owned CanvasDiff appearance")
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffWinbar", link = true }), empty,
      "the campaign did not restore a caller-owned empty group")
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffCrumb", link = true }), crumb,
      "the campaign did not preserve the intentionally empty crumb group")
  end, debug.traceback)

  restore_test_colorscheme(original)
  assert(ok, err)
end

T["chaos_surface_ cleanup restores colorscheme after a campaign failure"] = function()
  local original = vim.g.colors_name
  vim.cmd.colorscheme("industry")
  local injected = false
  local result = Chaos.run({
    seed = 31337,
    actions = ACTIONS,
    after_action = function(_, name)
      if not injected and name == "change_colorscheme" then
        injected = true
        error("injected post-colorscheme failure")
      end
    end,
  })
  local restored = vim.g.colors_name

  restore_test_colorscheme(original)

  assert(injected, "the deterministic seed never reached change_colorscheme: "
    .. vim.inspect(result))
  H.eq(result.status, "fail", "the injected failure must stop the campaign")
  H.eq(restored, "industry", "failure cleanup leaked the campaign colorscheme")
end

T["chaos_surface_ run restores cwd after a successful campaign"] = function()
  local original = vim.fn.getcwd()
  local result = Chaos.run({ seed = 31337, actions = 1 })
  H.eq(result.status, "ok", result.error)
  H.eq(vim.fn.getcwd(), original, "successful campaign leaked its fixture cwd")
end

T["chaos_surface_ run restores cwd after a campaign failure"] = function()
  local original = vim.fn.getcwd()
  local result = Chaos.run({
    seed = 31337,
    actions = 1,
    after_action = function() error("injected cwd cleanup failure") end,
  })
  H.eq(result.status, "fail", "the injected failure must stop the campaign")
  H.eq(vim.fn.getcwd(), original, "failed campaign leaked its fixture cwd")
end

T["chaos_surface_ released FileBar oracle rejects a stale override"] = function()
  local stale_bg
  local injected = false
  local result = Chaos.run({
    seed = 31337,
    actions = ACTIONS,
    after_action = function(world, name)
      if name == "configure_appearance" then
        stale_bg = world.expected_file_bar.bg
      elseif stale_bg and not injected and (name == "configure_invalid"
          or name == "reset_config" or name == "toggle_glyph_set") then
        vim.api.nvim_set_hl(0, "CanvasDiffFileBar", { bg = stale_bg })
        injected = true
      end
    end,
  })
  assert(injected, "the deterministic seed never reached override replacement")
  H.eq(result.status, "fail", "the stale override must violate the oracle")
  assert(result.error:find("released CanvasDiffFileBar", 1, true), result.error)
end

T["chaos_surface_ glyph oracle rejects replacement-model drift"] = function()
  local injected = false
  local result = Chaos.run({
    seed = 31337,
    actions = ACTIONS,
    after_action = function(_, name)
      if not injected and name == "configure_appearance" then
        require("canvasdiff.config").glyphs.file = "|"
        injected = true
      end
    end,
  })
  assert(injected, "the deterministic seed never reached configure_appearance")
  H.eq(result.status, "fail", "the wrong live glyph set must violate the oracle")
  assert(result.error:find("configured glyph set drifted", 1, true), result.error)
end

T["chaos_surface_ invalid setup oracle rejects review teardown"] = function()
  local injected = false
  local result = Chaos.run({
    seed = 31337,
    actions = ACTIONS,
    after_action = function(world, name)
      if not injected and name == "configure_invalid" then
        world.plugin.close()
        injected = true
      end
    end,
  })
  assert(injected, "the deterministic seed never reached configure_invalid")
  H.eq(result.status, "fail", "invalid setup teardown must violate the oracle")
  assert(result.error:find("invalid setup dismantled", 1, true), result.error)
end

return T
