-- The deterministic chaos harness ABOVE the engine.
--
-- `chaos.lua` drives stores, projections and schedulers; it never builds a
-- Surface, so it cannot assert the journey's "exact Surface ownership, and
-- disposed Surfaces own no callbacks", and it never touches Git, refs or the
-- session directory. This harness covers exactly that gap.
--
-- It works against a real Git fixture and the real `:CanvasDiff` entry points,
-- because the invariants at this level are about the editor's own state --
-- which windows exist, which augroups exist, which buffers survive -- and a
-- fake would prove nothing about any of them.
--
-- Injected hostility is expected to be REFUSED or SURVIVED, never absorbed
-- silently: a failing Git call must leave a review that still closes cleanly,
-- and an unwritable session directory must not take the review with it.

local H = require("helpers")

local Chaos = {}

--- The same generator as the engine harness: ours, so a seed replays, and
--- high bits, because an LCG's low bits have a period as short as the bound.
local function generator(seed)
  local state = seed % 2147483648
  local self = {}
  function self.next(bound)
    state = (state * 1103515245 + 12345) % 2147483648
    if bound == nil then
      return state
    end
    return math.floor(state / 2048) % bound
  end
  function self.pick(list)
    return list[self.next(#list) + 1]
  end
  function self.chance(percent)
    return self.next(100) < percent
  end
  return self
end
Chaos.generator = generator

local function body(tag, revision)
  local out = {}
  for index = 1, 40 do
    out[index] = ("%s line %d"):format(tag, index)
    if revision and index % 7 == 0 then
      out[index] = out[index] .. " r" .. revision
    end
  end
  return table.concat(out, "\n") .. "\n"
end

-- --- invariants --------------------------------------------------------------

local function canvasdiff_augroups()
  local groups = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    local name = autocmd.group_name or ""
    if name:sub(1, #"canvasdiff") == "canvasdiff" then
      groups[name] = (groups[name] or 0) + 1
    end
  end
  return groups
end

local function canvas_buffers()
  local canvas = require("canvasdiff.canvas")
  local found = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and canvas.is_canvas_buf(buf) then
      found[#found + 1] = buf
    end
  end
  return found
end

--- Everything that must hold after every action.
---
--- The strongest of these is the augroup check. A Surface owns numbered
--- augroups, and a disposed one must own none: a leftover augroup is a
--- callback that will fire against a review that no longer exists, which is
--- the exact failure the lease contract is written to prevent.
local function check(world)

  -- Every augroup that exists must belong to a LIVE surface. The number in
  -- the name is what makes this checkable at all: a leaked group from a
  -- disposed review is distinguishable from the live one's.
  local live = {}
  for _, surface in pairs(world.surfaces) do
    if surface:is_alive() then
      for _, name in pairs(surface.groups) do
        live[name] = true
      end
    end
  end
  -- Only the kinds a Surface itself owns. The status column, sidebar and
  -- scrollbar also carry numbered groups, but those belong to their own
  -- leases with their own lifetimes -- checking them against Surface.groups
  -- would flag a live controller as a leak.
  for name in pairs(canvasdiff_augroups()) do
    local kind = name:match("^canvasdiff%.(%a+)%.%d+$")
    if kind == "session" or kind == "close" or kind == "winbar" then
      assert(live[name], (
        "augroup %s outlived the Surface that owned it"
      ):format(name))
    end
  end

  -- No two live surfaces may claim one canvas buffer.
  local claimed = {}
  for _, surface in pairs(world.surfaces) do
    local buf = surface:is_alive() and surface.state and surface.state.buf
    if buf then
      assert(not claimed[buf], (
        "two live Surfaces claim canvas buffer %d"
      ):format(buf))
      claimed[buf] = surface
    end
  end

  -- A disposed Surface must hold no state that could still act.
  for _, surface in pairs(world.surfaces) do
    if not surface:is_alive() then
      assert(surface.state == nil or surface.state.hooks == nil,
        "a disposed Surface still holds render hooks")
    end
  end

  -- Canvas buffers must not accumulate. Measured against the count this
  -- campaign started with, because a headless test process is shared and
  -- earlier tests legitimately leave buffers behind; what this catches is
  -- THIS campaign growing the set without bound. The slack is one buffer for
  -- the review being replaced, whose reclamation is deferred by a schedule.
  local now = #canvas_buffers()
  assert(now <= world.baseline_buffers + world.peak_reviews + 1, (
    "canvas buffers are accumulating: %d now, %d at the start, peak %d reviews"
  ):format(now, world.baseline_buffers, world.peak_reviews))
end
Chaos.check = check

-- --- actions -----------------------------------------------------------------

local ACTIONS = {}

--- Learn about a Surface the only way a caller legitimately can.
---
--- A live canvas state carries `state.surface`, and disposal clears it, so
--- capturing it at open time gives the harness real Surface objects to check
--- without reaching into App's private index.
local function remember(world, state)
  local surface = type(state) == "table" and state.surface or nil
  if surface then
    world.surfaces[surface] = surface
  end
  local count = 0
  for _, tracked in pairs(world.surfaces) do
    if tracked:is_alive() then
      count = count + 1
    end
  end
  if count > world.peak_reviews then
    world.peak_reviews = count
  end
end

local function record(world, name, detail)
  world.counts[name] = (world.counts[name] or 0) + 1
  local history = world.history
  history[#history + 1] = detail and (name .. " " .. detail) or name
  if #history > 256 then
    table.remove(history, 1)
  end
end

ACTIONS.open = function(world)
  local state = world.plugin.open()
  remember(world, state)
  record(world, state and "open" or "open_refused")
end

ACTIONS.close = function(world)
  world.plugin.close()
  record(world, "close")
end

ACTIONS.toggle = function(world)
  remember(world, world.plugin.toggle())
  record(world, "toggle")
end

ACTIONS.refresh = function(world)
  world.plugin.refresh()
  record(world, "refresh")
end

ACTIONS.set_lens = function(world)
  local id = world.rng.pick({ "all", "unstaged", "staged" })
  world.plugin.set_lens(id)
  record(world, "set_lens", id)
end

ACTIONS.cycle_lens = function(world)
  world.plugin.cycle_lens(world.rng.chance(50) and 1 or -1)
  record(world, "cycle_lens")
end

ACTIONS.write_file = function(world)
  -- The worktree changing under a live review is the ordinary case the
  -- watcher exists for, and the one most likely to desynchronize a canvas.
  world.revision = world.revision + 1
  local name = world.rng.pick({ "a.txt", "b.txt", "c.txt" })
  local path = vim.fs.joinpath(world.dir, name)
  local file = io.open(path, "wb")
  if file then
    file:write(body(name:sub(1, 1), world.revision))
    file:close()
  end
  record(world, "write_file", name)
end

ACTIONS.split_window = function(world)
  if #vim.api.nvim_tabpage_list_wins(0) >= 4 then
    return
  end
  pcall(vim.cmd, world.rng.chance(50) and "split" or "vsplit")
  record(world, "split_window")
end

ACTIONS.close_window = function(world)
  local wins = vim.api.nvim_tabpage_list_wins(0)
  if #wins <= 1 then
    return
  end
  pcall(vim.api.nvim_win_close, world.rng.pick(wins), true)
  record(world, "close_window")
end

ACTIONS.git_fails = function(world)
  -- Kill Git for one operation. A review must refuse or survive; it must not
  -- half-apply a collection it could not finish.
  local system = require("canvasdiff.os")
  local real = system.run
  system.run = function()
    return { code = 128, stdout = "", stderr = "injected git failure" }
  end
  local ok = pcall(function()
    if world.rng.chance(50) then
      world.plugin.refresh()
    else
      -- Track whatever a failing open produced: a review that got far enough
      -- to own augroups before Git refused is exactly the case worth checking.
      remember(world, world.plugin.open())
    end
  end)
  system.run = real
  world.refusals.git = (world.refusals.git or 0) + 1
  record(world, "git_fails", ok and "contained" or "threw")
  assert(ok, "an injected Git failure escaped as a throw")
end

ACTIONS.session_unwritable = function(world)
  -- An unwritable session directory must not take the review with it.
  local session = require("canvasdiff.session")
  local real = session.save
  session.save = function()
    error("injected session write failure")
  end
  local ok = pcall(function() world.plugin.close() end)
  session.save = real
  world.refusals.session = (world.refusals.session or 0) + 1
  record(world, "session_unwritable", ok and "contained" or "threw")
  assert(ok, "an injected session failure escaped as a throw")
end

ACTIONS.jump_back = function(world)
  -- Returning from an excursion that may not exist: an ordinary refusal.
  local ok = pcall(function() world.plugin.jump_back() end)
  assert(ok, "jump_back threw instead of refusing")
  record(world, "jump_back")
end

local ACTION_NAMES = {}
for name in pairs(ACTIONS) do
  ACTION_NAMES[#ACTION_NAMES + 1] = name
end
table.sort(ACTION_NAMES)
Chaos.action_names = ACTION_NAMES

--- Run one campaign against a real repository.
function Chaos.run(opts)
  opts = opts or {}
  local seed = assert(opts.seed, "a campaign requires a seed")
  local actions = opts.actions or 200
  local rng = generator(seed)

  local dir = H.git_fixture({
    committed = {
      ["a.txt"] = body("a"), ["b.txt"] = body("b"), ["c.txt"] = body("c"),
    },
    worktree = {
      ["a.txt"] = body("a", 1), ["b.txt"] = body("b", 1),
    },
  })
  vim.api.nvim_set_current_dir(dir)
  package.loaded["canvasdiff"] = nil
  local plugin = require("canvasdiff")

  -- The campaign splits and closes windows, so it runs in a tab of its own and
  -- takes it away afterwards. Without that it leaves the layout changed, and
  -- a later test measuring a viewport gets a different window height and fails
  -- for reasons that have nothing to do with it.
  local origin_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  local campaign_tab = vim.api.nvim_get_current_tabpage()
  local function restore()
    pcall(function() plugin.close() end)
    if vim.api.nvim_tabpage_is_valid(campaign_tab)
        and vim.api.nvim_get_current_tabpage() == campaign_tab
        and vim.api.nvim_tabpage_is_valid(origin_tab) then
      pcall(vim.cmd, "tabclose!")
    end
    if vim.api.nvim_tabpage_is_valid(origin_tab) then
      pcall(vim.api.nvim_set_current_tabpage, origin_tab)
    end
  end

  local world = {
    rng = rng,
    dir = dir,
    plugin = plugin,
    surfaces = {},
    counts = {},
    refusals = {},
    history = {},
    revision = 1,
    peak_reviews = 0,
    baseline_buffers = #canvas_buffers(),
  }
  for step = 1, actions do
    local name = rng.pick(ACTION_NAMES)
    local ok, failure = xpcall(function()
      ACTIONS[name](world)
      -- Let the loop turn. Canvas-buffer reclamation and window adoption are
      -- both deferred by vim.schedule, so a campaign that never yields would
      -- measure a world where neither has happened yet -- and report an
      -- accumulation that is really just a queue.
      vim.wait(1)
      check(world)
    end, debug.traceback)
    if not ok then
      restore()
      return {
        seed = seed,
        status = "fail",
        failed_at = step,
        failed_action = name,
        error = tostring(failure),
        history = world.history,
        counts = world.counts,
        refusals = world.refusals,
      }
    end
  end

  restore()
  return {
    seed = seed,
    status = "ok",
    actions = actions,
    counts = world.counts,
    refusals = world.refusals,
    peak_reviews = world.peak_reviews,
  }
end

return Chaos
