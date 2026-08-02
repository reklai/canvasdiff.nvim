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
-- an unwritable session directory must not take the review with it, and a
-- branch deleted out from under a saved or remembered lens must be refused
-- (a pivot onto it) or degraded to the default lens (a reopen through it) --
-- never allowed to dismantle the review that was already on screen.

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

--- Run one Git command against the fixture repository, the way the OUTSIDE
--- world would -- vim.system, not canvasdiff.os, whose failures other actions
--- inject. Fixture-side Git is harness infrastructure, so a failure here is a
--- broken campaign, not a finding: assert it.
local function git(dir, cmd)
  local result = vim.system(cmd, { cwd = dir, text = true }):wait()
  assert(result.code == 0, ("%s failed: %s")
    :format(table.concat(cmd, " "), result.stderr or ""))
  return result.stdout or ""
end

--- The bounded branch pool the campaign creates and deletes from. Pivot
--- candidates DELIBERATELY include names that were never created or have been
--- deleted meanwhile: pivoting onto a missing ref is the hostile case, and it
--- must refuse without dismantling the review it would have replaced.
local POOL = { "chaos-0", "chaos-1", "chaos-2", "chaos-3" }

local function ref_candidates(world)
  local out = { world.default_branch, "HEAD" }
  vim.list_extend(out, POOL)
  return out
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

  -- The remembered pre-comparison exit must itself be somewhere <Tab> can go:
  -- a valid lens and never a range. A range recorded here would make "leave
  -- the comparison" mean "enter another one", forever.
  local lens = require("canvasdiff.diff.lens")
  for _, surface in pairs(world.surfaces) do
    local st = surface:is_alive() and surface.state or nil
    local back = st and st.return_lens
    if back ~= nil then
      assert(lens.valid(back), "return_lens does not satisfy lens.valid: "
        .. vim.inspect(back, { newline = " ", indent = "" }))
      assert(not lens.is_range(back),
        "return_lens is a range, so leaving a comparison could never finish")
    end
  end

  -- A refused pivot must leave the review it would have replaced on screen:
  -- a live Surface whose primary window still exists must be showing its own
  -- canvas buffer there, not whatever a half-applied pivot left behind.
  for _, surface in pairs(world.surfaces) do
    local st = surface:is_alive() and surface.state or nil
    local win = st and st.win
    if win and st.buf and vim.api.nvim_win_is_valid(win) then
      assert(vim.api.nvim_win_get_buf(win) == st.buf,
        "a live Surface's window no longer shows its canvas buffer")
    end
  end

  -- A reopen-through-the-session either produced a review that is actually on
  -- screen, or refused cleanly -- in which case nothing of the closed review
  -- may survive it: no live Surface, and none of the augroup kinds a Surface
  -- owns. Consumed here so the stricter form binds exactly one action.
  local reopen = world.pending_reopen
  world.pending_reopen = nil
  if reopen then
    if reopen.opened then
      local showing = false
      for _, surface in pairs(world.surfaces) do
        local st = surface:is_alive() and surface.state or nil
        local buf = st and st.buf
        if buf then
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == buf then
              showing = true
            end
          end
        end
      end
      assert(showing, "session_reopen produced a review that is not showing")
    else
      for _, surface in pairs(world.surfaces) do
        assert(not surface:is_alive(),
          "session_reopen refused but left a live Surface behind")
      end
      for name in pairs(canvasdiff_augroups()) do
        local kind = name:match("^canvasdiff%.(%a+)%.%d+$")
        assert(not (kind == "session" or kind == "close" or kind == "winbar"),
          ("session_reopen refused but augroup %s leaked"):format(name))
      end
    end
  end
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

--- First window in this tab showing a canvas buffer -- layout order, so a
--- replayed seed lands on the same one.
local function canvas_window()
  local canvas = require("canvasdiff.canvas")
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if canvas.is_canvas_buf(vim.api.nvim_win_get_buf(win)) then
      return win
    end
  end
end

--- Change what the review compares: pivot in place when one is showing, open
--- with an explicit lens when none is. The split exists because set_lens and
--- friends open INTERNALLY when nothing is showing and return only `true` --
--- a Surface the harness never saw, which the ownership checks would then
--- misread as a leak. An explicit lens that no longer resolves refuses the
--- open (typo feedback), and that refusal is an expected outcome here.
local function pivot_or_open(world, l)
  if canvas_window() then
    world.plugin.set_lens(l)
  else
    remember(world, world.plugin.open({ lens = l }))
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
  -- The real lens table, not its id: App:set_lens refuses a bare string, so
  -- passing "all" tested nothing but the refusal message.
  local id = world.rng.pick({ "all", "unstaged", "staged" })
  pivot_or_open(world, require("canvasdiff.diff.lens").get(id))
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

-- Window actions draw and record BEFORE their live-state guard. Window count
-- is editor state that scheduled teardown can change between two otherwise
-- identical runs, and a draw (or a record) that happens in one run but not
-- the other desynchronizes every action picked after it, breaking seed
-- replay for reasons that have nothing to do with the seed.

ACTIONS.split_window = function(world)
  local vertical = world.rng.chance(50)
  if #vim.api.nvim_tabpage_list_wins(0) >= 4 then
    return record(world, "split_window", "noop")
  end
  pcall(vim.cmd, vertical and "split" or "vsplit")
  record(world, "split_window")
end

ACTIONS.close_window = function(world)
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local victim = wins[world.rng.next(#wins) + 1]
  if #wins <= 1 then
    return record(world, "close_window", "noop")
  end
  pcall(vim.api.nvim_win_close, victim, true)
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

ACTIONS.git_branch = function(world)
  -- The pool is bounded so a campaign recreates names it deleted earlier and
  -- deletes names a lens still remembers: that collision is the point.
  local name = "chaos-" .. world.rng.next(4)
  git(world.dir, { "git", "branch", "-f", name })
  world.branches[name] = true
  record(world, "git_branch", name)
end

ACTIONS.git_branch_delete = function(world)
  local names = vim.tbl_keys(world.branches)
  if #names == 0 then
    return record(world, "git_branch_delete", "noop")
  end
  -- tbl_keys order is not deterministic; a replayed seed must pick the same
  -- victim, so the pick happens over a sorted copy.
  table.sort(names)
  local name = world.rng.pick(names)
  git(world.dir, { "git", "branch", "-D", name })
  world.branches[name] = nil
  record(world, "git_branch_delete", name)
end

ACTIONS.git_commit = function(world)
  -- Ranges need history that actually moves: advance a pooled file and commit
  -- everything, index changes included. `--allow-empty` keeps the action
  -- total when a stage already committed the worktree's whole story.
  world.revision = world.revision + 1
  local name = world.rng.pick({ "a.txt", "b.txt", "c.txt" })
  local file = io.open(vim.fs.joinpath(world.dir, name), "wb")
  if file then
    file:write(body(name:sub(1, 1), world.revision))
    file:close()
  end
  git(world.dir, { "git", "add", "-A" })
  git(world.dir, { "git", "commit", "-m", "chaos r" .. world.revision, "--allow-empty" })
  record(world, "git_commit", name)
end

ACTIONS.set_range = function(world)
  -- Both endpoints come from the candidate list, so a range regularly names a
  -- branch that no longer exists. That pivot is EXPECTED to refuse; the
  -- invariants after the action assert the review it would have replaced is
  -- still on screen.
  local refs = ref_candidates(world)
  local left = world.rng.pick(refs)
  local right = world.rng.pick(refs)
  local operator = world.rng.chance(50) and ".." or "..."
  local ok = pcall(function()
    pivot_or_open(world,
      require("canvasdiff.diff.lens").range(left, right, operator))
  end)
  record(world, "set_range", left .. operator .. right)
  assert(ok, "set_range threw instead of refusing")
end

ACTIONS.set_branch = function(world)
  -- Same posture as set_range: a deleted candidate must refuse, not throw and
  -- not tear down the current review.
  local ref = world.rng.pick(ref_candidates(world))
  local ok = pcall(function()
    pivot_or_open(world, require("canvasdiff.diff.lens").branch(ref))
  end)
  record(world, "set_branch", ref)
  assert(ok, "set_branch threw instead of refusing")
end

-- Drive staging the way a user does: from inside a canvas window with the
-- cursor on some row. Without one -- or on a READ-ONLY comparison, or with
-- nothing for the verb to do -- the entry point must refuse, not throw.
-- The cursor row is drawn whether or not a canvas is showing, for the same
-- replay-determinism reason as the window actions above.
local function stage_verb(verb)
  return function(world)
    local win = canvas_window()
    local rows = win
      and vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) or 1
    local row = world.rng.next(rows) + 1
    if win then
      vim.api.nvim_set_current_win(win)
      pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
    end
    local ok = pcall(function() world.plugin[verb]() end)
    record(world, verb)
    assert(ok, verb .. " threw instead of refusing")
  end
end

ACTIONS.stage = stage_verb("stage")
ACTIONS.unstage = stage_verb("unstage")

--- The whole index, as Git itself reports it: mode, object id and stage number
--- for every path. Read through vim.system rather than canvasdiff.os, so the
--- seam an action injects failure at can never also fake the measurement it is
--- being measured by.
local function index_snapshot(dir)
  return git(dir, { "git", "ls-files", "--stage", "-z" })
end

--- The canvas rows that ARE hunk rows, asked of the resolver the verb itself
--- routes through -- so "a hunk row" means here exactly what it means at press
--- time, rather than a guess made from the text.
local function hunk_rows(state)
  local rows = {}
  local ok, total = pcall(vim.api.nvim_buf_line_count, state.buf)
  if not ok then
    return rows
  end
  for row0 = 0, total - 1 do
    local resolved = require("canvasdiff.canvas").context.resolve(state, row0)
    if resolved and resolved.scope == "hunk" then
      rows[#rows + 1] = row0
    end
  end
  return rows
end

--- The live review showing in this tab, and the window showing it.
---
--- Learned from the Surfaces the harness captured at open time, the same way
--- everything else here learns about them: a Surface that opened INTERNALLY
--- was never handed to remember(), and this declines to act on one rather than
--- reaching into App's private index for it.
local function showing_review(world)
  local win = canvas_window()
  if not win then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  for _, surface in pairs(world.surfaces) do
    local st = surface:is_alive() and surface.state or nil
    if st and st.buf == buf then
      return st, win
    end
  end
end

--- The canvas's own `s`, pressed on a row that really is a hunk row.
---
--- The file verbs above land on a random buffer row, which is a hunk row only
--- by luck; this asks which rows are hunks and presses on one of those, so the
--- hunk path is visited on purpose rather than occasionally. It goes through
--- the buffer-local mapping instead of a module call because the hunk verb has
--- no public entry point -- `canvasdiff.stage()` is the FILE verb -- and the
--- mapping is what a user actually presses.
---
--- Half the presses run with Git killed under them. That half is the one worth
--- asserting: an index write is hash-object followed by update-index, two
--- commands with a window between them, so a failure that half-applied would
--- leave a staged blob nobody asked for. The invariant is the mixed-rename
--- test's, extended to the hunk verb and widened to the WHOLE index -- a
--- failed press may not move any path, not merely the one it was pressed on.
---
--- Both draws happen before the live-state guard, for the replay-determinism
--- reason the window actions above spell out.
ACTIONS.stage_hunk = function(world)
  local state, win = showing_review(world)
  local rows = state and hunk_rows(state) or {}
  local row0 = rows[world.rng.next(math.max(#rows, 1)) + 1]
  local hostile = world.rng.chance(50)
  if not (win and row0) then
    return record(world, "stage_hunk", "noop")
  end
  vim.api.nvim_set_current_win(win)
  pcall(vim.api.nvim_win_set_cursor, win, { row0 + 1, 0 })

  local press
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
    if mapping.lhs == "s" then
      press = mapping.callback
    end
  end
  if not press then
    return record(world, "stage_hunk", "unmapped")
  end

  local before = index_snapshot(world.dir)
  local ok
  if hostile then
    local system = require("canvasdiff.os")
    local real = system.run
    system.run = function()
      return { code = 128, stdout = "", stderr = "injected git failure" }
    end
    ok = pcall(press)
    system.run = real
    world.refusals.stage_hunk = (world.refusals.stage_hunk or 0) + 1
    H.eq(index_snapshot(world.dir), before,
      "an injected Git failure moved the index while staging a hunk")
  else
    ok = pcall(press)
  end
  record(world, "stage_hunk", hostile and "hostile" or "clean")
  assert(ok, "stage_hunk threw instead of refusing")
end

ACTIONS.sidebar_toggle = function(world)
  -- With no review showing this must warn-and-refuse; with one showing it
  -- retires or claims the Surface's one sidebar lease. Either way, never a
  -- throw. The ownership checks after the action cover only Surface-owned
  -- augroups -- check() deliberately leaves the sidebar lease's own groups
  -- alone -- so what this action pins is the refuse-don't-throw contract.
  local ok = pcall(function() world.plugin.sidebar() end)
  record(world, "sidebar_toggle")
  assert(ok, "sidebar_toggle threw instead of refusing")
end

ACTIONS.session_reopen = function(world)
  -- A restart in miniature. Closing SAVES the session -- deliberately not
  -- invalidated -- and reopening restores through it, so a saved lens whose
  -- branch was deleted meanwhile must degrade to the default lens rather than
  -- fail the open or leak the review. The check consumes pending_reopen.
  world.plugin.close()
  local state = world.plugin.open()
  remember(world, state)
  world.pending_reopen = { opened = state ~= nil }
  record(world, "session_reopen", state and "opened" or "refused")
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
  -- Two pool branches exist from the start, so deletions bite immediately
  -- instead of waiting for a git_branch to have happened first. The default
  -- branch is read rather than assumed: it is a pivot candidate, and the one
  -- that must always resolve.
  git(dir, { "git", "branch", POOL[1] })
  git(dir, { "git", "branch", POOL[2] })
  local default_branch = vim.trim(
    git(dir, { "git", "symbolic-ref", "--short", "HEAD" }))

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
    branches = { [POOL[1]] = true, [POOL[2]] = true },
    default_branch = default_branch ~= "" and default_branch or "main",
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
