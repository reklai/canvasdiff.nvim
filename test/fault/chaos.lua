-- The deterministic chaos harness for the paged engine.
--
-- Phase 7's requirement is not "run some random operations". It is: drive
-- thousands of actions from a recorded seed, injecting hostility at named
-- seams, and after EVERY action assert that the invariants still hold -- with
-- enough history retained that a failure replays exactly.
--
-- Three things make that work:
--
-- 1. An oracle. Every action that changes the text changes a plain Lua array
--    alongside the store, so "is the store still correct" is a comparison
--    rather than an opinion. Without it a fuzzer can only catch crashes.
-- 2. A seeded generator of our own. `math.random` is process-global and shared
--    with anything else that runs, so a campaign that used it could not be
--    replayed from its seed alone.
-- 3. Injected failure that is expected to be REFUSED, not survived. A codec
--    that corrupts a block must produce a clean refusal and leave the previous
--    state intact; a harness that accepted "it did not crash" would pass a
--    store that silently published garbage.
--
-- The harness is a library. `test/fault/test_chaos.lua` runs a short campaign
-- as part of the ordinary suite; `benchmark/chaos/run.lua` runs the full
-- 10,000-action campaign out of band.

local canvas = require("canvasdiff.canvas")

local Chaos = {}

-- Small enough that a full oracle comparison after every action is affordable,
-- large enough to span many pages and exercise page boundaries constantly.
local INITIAL_ROWS = 900
local MAX_ROWS = 4000
local RESIDENT_MAX_PAGES = 4
local RESIDENT_MAX_BYTES = 96 * 1024

--- A generator that belongs to the campaign, not to the process.
---
--- Plain 32-bit LCG: the exact algorithm matters far less than the fact that
--- it is ours, so a seed replays the same actions on any machine and cannot be
--- perturbed by unrelated code calling `math.random`.
local function generator(seed)
  local state = seed % 2147483648
  local self = {}
  function self.next(bound)
    state = (state * 1103515245 + 12345) % 2147483648
    if bound == nil then
      return state
    end
    -- Take the HIGH bits. An LCG's low bits have a period as short as the
    -- modulus of the bound -- taking `state % 14` directly made a 250-action
    -- campaign visit only three of fourteen actions, which looks like coverage
    -- and is not.
    return math.floor(state / 2048) % bound
  end
  function self.range(low, high)
    if high < low then
      return low
    end
    return low + self.next(high - low + 1)
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

-- Text shapes that have historically broken row addressing: empty rows, NUL
-- bytes, invalid UTF-8, CR, wide characters, and a row long enough to exceed a
-- page's byte budget on its own.
local SHAPES = {
  function(rng) return ("plain %d"):format(rng.next(1000000)) end,
  function() return "" end,
  function(rng) return ("tab\tsep\t%d"):format(rng.next(1000)) end,
  function(rng) return ("cr\rembedded %d"):format(rng.next(1000)) end,
  function(rng) return ("nul\0byte %d"):format(rng.next(1000)) end,
  function(rng) return ("\xff\xfe invalid utf8 %d"):format(rng.next(1000)) end,
  function(rng) return ("héllo wörld %d ünïcødé"):format(rng.next(1000)) end,
  function(rng) return ("日本語のテキスト %d"):format(rng.next(1000)) end,
  function(rng) return ("wide "):rep(rng.range(1, 40)) end,
  function(rng) return ("x"):rep(rng.range(1, 3) * 40 * 1024) end,
}

local function row_text(rng)
  return SHAPES[rng.next(#SHAPES) + 1](rng)
end
Chaos.row_text = row_text

--- A codec that damages what it is asked to preserve.
---
--- `mode` decides which contract it violates: a corrupted block, a lying
--- checksum, an encode that refuses, or a decode that returns the wrong number
--- of bytes. Each must be REFUSED by the store rather than absorbed.
local function hostile_codec(base, mode)
  return {
    codec = base.codec,
    crc32 = mode == "bad_crc"
        and function(_) return 1 end
      or base.crc32,
    encode = mode == "encode_refuses"
        and function() return nil, "injected encode failure" end
      or base.encode,
    decode = (mode == "corrupt_block" or mode == "short_decode")
        and function(block, size)
          local decoded, err = base.decode(block, size)
          if not decoded then
            return nil, err
          end
          if mode == "short_decode" then
            return decoded:sub(1, math.max(0, #decoded - 1))
          end
          return ("\0"):rep(#decoded)
        end
      or base.decode,
  }
end

--- Build one world: a store, its projection, its scheduler, and the oracle.
local function build(rng, opts)
  opts = opts or {}
  local rows = {}
  for index = 1, INITIAL_ROWS do
    rows[index] = row_text(rng)
  end

  local compression = canvas.compression()
  local list, list_err = canvas.paginate(rows, compression and {
    resident = {
      max_pages = RESIDENT_MAX_PAGES,
      max_bytes = RESIDENT_MAX_BYTES,
      restore = compression,
    },
  } or nil)
  assert(list, list_err)

  local projection, projection_err = canvas.project(list)
  assert(projection, projection_err)

  local scheduler, scheduler_err = canvas.schedule(list, { idle_ms = 1 })
  assert(scheduler, scheduler_err)

  return {
    rng = rng,
    list = list,
    projection = projection,
    scheduler = scheduler,
    compression = compression,
    oracle = rows,
    history = {},
    counts = {},
    refusals = {},
    window = opts.window,
  }
end

local function record(world, name, detail)
  world.counts[name] = (world.counts[name] or 0) + 1
  local history = world.history
  history[#history + 1] = detail and (name .. " " .. detail) or name
  -- Bounded history: the tail is what a failure replays from, and an unbounded
  -- log would itself become the memory problem the campaign is looking for.
  if #history > 256 then
    table.remove(history, 1)
  end
end

local function note_refusal(world, seam)
  world.refusals[seam] = (world.refusals[seam] or 0) + 1
end

-- --- actions -----------------------------------------------------------------
--
-- Every action returns nothing and leaves the world consistent with its oracle.
-- An action that injects a failure is responsible for asserting that the
-- failure was refused rather than absorbed.

local ACTIONS = {}

ACTIONS.read_range = function(world)
  local rng, total = world.rng, #world.oracle
  if total == 0 then
    return
  end
  local start0 = rng.next(total)
  local count = rng.next(total - start0 + 1)
  local got, err = world.list:rows(start0, count)
  assert(got, err)
  for index = 1, count do
    assert(got[index] == world.oracle[start0 + index],
      ("row %d disagrees with the oracle"):format(start0 + index - 1))
  end
  record(world, "read_range", ("%d+%d"):format(start0, count))
end

ACTIONS.read_row = function(world)
  local total = #world.oracle
  if total == 0 then
    return
  end
  local row0 = world.rng.next(total)
  local got = world.list:row(row0)
  assert(got == world.oracle[row0 + 1],
    ("row %d disagrees with the oracle"):format(row0))
  record(world, "read_row", tostring(row0))
end

ACTIONS.splice = function(world)
  local rng = world.rng
  local total = #world.oracle
  local start0 = rng.next(total + 1)

  -- Seek back toward the initial size. An unbiased splice that can delete far
  -- more than it inserts drains the store within a few hundred actions, and a
  -- campaign spent on a fourteen-row store is not testing a paged store at
  -- all. The bias only shifts the ratio; both directions stay reachable at
  -- every size, so page boundaries and empty ranges are still visited.
  local room = math.max(0, total - start0)
  local delete_ceiling = math.min(room, 40)
  local insert_ceiling = 40
  if total < INITIAL_ROWS then
    delete_ceiling = math.min(delete_ceiling, 8)
  elseif total > INITIAL_ROWS * 2 then
    insert_ceiling = 8
  end

  local delete_count = rng.next(delete_ceiling + 1)
  local insert_count = rng.next(insert_ceiling + 1)
  if total - delete_count + insert_count > MAX_ROWS then
    insert_count = 0
  end
  local inserted = {}
  for index = 1, insert_count do
    inserted[index] = row_text(rng)
  end

  local ok, err = world.list:splice(start0, delete_count, inserted)
  if not ok then
    -- A refused splice must have changed nothing; the oracle stays as it was
    -- and the next invariant sweep proves the store agrees.
    note_refusal(world, "splice")
    record(world, "splice_refused", tostring(err))
    return
  end
  for _ = 1, delete_count do
    table.remove(world.oracle, start0 + 1)
  end
  for index = insert_count, 1, -1 do
    table.insert(world.oracle, start0 + 1, inserted[index])
  end
  record(world, "splice",
    ("%d-%d+%d"):format(start0, delete_count, insert_count))
end

ACTIONS.compact_step = function(world)
  -- The scheduler is idle-driven; letting the loop turn is what advances it.
  vim.wait(2)
  local stats = world.scheduler:stats()
  assert(stats, "scheduler lost its state")
  record(world, "compact_step", stats.phase)
end

ACTIONS.touch = function(world)
  local ok, err = world.scheduler:touch()
  assert(ok, err)
  record(world, "touch")
end

ACTIONS.redraw = function(world)
  local ok, err = world.projection:redraw()
  -- A redraw with no window showing the projection is legitimately a no-op
  -- refusal, not a fault.
  if not ok then
    note_refusal(world, "redraw")
    record(world, "redraw_refused", tostring(err))
    return
  end
  record(world, "redraw")
end

ACTIONS.viewport = function(world)
  local window = world.window
  if not window or not vim.api.nvim_win_is_valid(window) then
    return
  end
  local total = #world.oracle
  if total == 0 then
    return
  end
  local line1 = world.rng.range(1, total)
  pcall(vim.api.nvim_win_set_cursor, window, { line1, 0 })
  record(world, "viewport", tostring(line1))
end

ACTIONS.resize = function(world)
  local window = world.window
  if not window or not vim.api.nvim_win_is_valid(window) then
    return
  end
  local height = world.rng.range(1, 40)
  pcall(vim.api.nvim_win_set_height, window, height)
  record(world, "resize", tostring(height))
end

ACTIONS.corrupt_codec = function(world)
  if not world.compression then
    return
  end
  local mode = world.rng.pick({
    "corrupt_block", "bad_crc", "encode_refuses", "short_decode",
  })

  -- A store built on a hostile codec must refuse, at some point in the
  -- round trip, to hand back text it cannot prove. Which call refuses is the
  -- implementation's business; that SOMETHING refuses is the invariant.
  local rows = {}
  for index = 1, 40 do
    rows[index] = row_text(world.rng)
  end
  local hostile = hostile_codec(world.compression, mode)
  local list = canvas.paginate(rows, {
    resident = {
      max_pages = 1,
      max_bytes = RESIDENT_MAX_BYTES,
      restore = hostile,
    },
  })
  if not list then
    note_refusal(world, "corrupt_codec")
    record(world, "corrupt_codec_refused_build", mode)
    return
  end

  local compacted, compact_err = list:compact_page(0, list:generation())
  local read, read_err = list:rows(0, #rows)

  if mode == "encode_refuses" then
    -- Refusing to encode must leave the page raw and perfectly readable.
    assert(read, read_err)
    for index = 1, #rows do
      assert(read[index] == rows[index],
        "a refused compaction changed the text it declined to compact")
    end
    note_refusal(world, "corrupt_codec")
    record(world, "corrupt_codec", mode)
    return
  end

  if compacted and read then
    for index = 1, #rows do
      assert(read[index] == rows[index], (
        "hostile codec mode %s published corrupted text as if it were valid"
      ):format(mode))
    end
  end
  if not compacted or not read then
    note_refusal(world, "corrupt_codec")
  end
  record(world, "corrupt_codec",
    ("%s %s"):format(mode, tostring(compact_err or read_err or "clean")))
end

ACTIONS.reentrant_read = function(world)
  -- Reading the store from inside a read is the reentry seam: the store must
  -- either serve it or refuse it, never corrupt its own cursor.
  local total = #world.oracle
  if total == 0 then
    return
  end
  local row0 = world.rng.next(total)
  local ok, err = pcall(function()
    local outer = world.list:row(row0)
    local inner = world.list:row((row0 + 1) % total)
    assert(outer == world.oracle[row0 + 1], "outer read disagreed")
    assert(inner == world.oracle[((row0 + 1) % total) + 1],
      "inner read disagreed")
  end)
  assert(ok, err)
  record(world, "reentrant_read", tostring(row0))
end

ACTIONS.scheduler_cycle = function(world)
  -- Dispose and rebuild the scheduler underneath a live store. A disposed
  -- scheduler must own nothing afterwards, and the replacement must not
  -- inherit the old one's cursor.
  assert(world.scheduler:dispose())
  local stats = world.scheduler:stats()
  assert(stats and stats.disposed, "a disposed scheduler still reports live")
  local replacement, err = canvas.schedule(world.list, { idle_ms = 1 })
  assert(replacement, err)
  world.scheduler = replacement
  record(world, "scheduler_cycle")
end

ACTIONS.projection_cycle = function(world)
  -- Same question for the projection: dispose it and build another over the
  -- same store, which is what closing and reopening a review does.
  assert(world.projection:dispose(true))
  local replacement, err = canvas.project(world.list)
  assert(replacement, err)
  world.projection = replacement
  if world.window and vim.api.nvim_win_is_valid(world.window) then
    local buffer = replacement:buffer()
    if buffer then
      pcall(vim.api.nvim_win_set_buf, world.window, buffer)
    end
  end
  record(world, "projection_cycle")
end

local ACTION_NAMES = {}
for name in pairs(ACTIONS) do
  ACTION_NAMES[#ACTION_NAMES + 1] = name
end
table.sort(ACTION_NAMES)
Chaos.action_names = ACTION_NAMES

-- --- invariants --------------------------------------------------------------

--- Everything that must be true after every single action.
---
--- These are deliberately cheap enough to run 10,000 times. The expensive
--- whole-text comparison is sampled by `read_range` instead, which over a long
--- campaign covers the text far more thoroughly than one full sweep would.
local function check(world)
  local list = world.list

  local valid, valid_err = require("canvasdiff.canvas.PageList").validate(list)
  assert(valid, "page list invariant lost: " .. tostring(valid_err))

  assert(list:row_count() == #world.oracle, (
    "store has %d rows, oracle has %d"
  ):format(list:row_count(), #world.oracle))

  local resident = list:resident_stats()
  if resident then
    assert(resident.pages <= resident.max_pages, (
      "resident pages %d exceed the cap of %d"
    ):format(resident.pages, resident.max_pages))
    -- A single row larger than the whole byte budget must still be readable,
    -- so the byte cap is allowed to be exceeded by exactly one oversized page
    -- and by nothing else.
    assert(resident.pages <= 1 or resident.bytes <= resident.max_bytes, (
      "resident bytes %d exceed the cap of %d across %d pages"
    ):format(resident.bytes, resident.max_bytes, resident.pages))
  end

  -- A store whose shape changed leaves the projection deliberately out of
  -- sync until its owner refreshes it -- that pending state is the contract,
  -- not a fault. So the invariant is the stronger one: refreshing must always
  -- succeed, and a refreshed projection must always validate. Checking it
  -- after every action means the refresh path is exercised as heavily as the
  -- store itself.
  local refreshed, refresh_err = world.projection:refresh()
  assert(refreshed, "projection refused to refresh: " .. tostring(refresh_err))

  local projection_valid, projection_err = world.projection:validate()
  assert(projection_valid,
    "projection invariant lost: " .. tostring(projection_err))

  local stats = world.projection:stats()
  assert(stats, "projection lost its stats")
  assert(stats.logical_rows == #world.oracle, (
    "projection sees %d rows, oracle has %d"
  ):format(stats.logical_rows, #world.oracle))

  -- The invariant the whole design rests on: no persistent per-row extmark.
  local buffer = stats.buffer
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    for _, namespace in pairs(vim.api.nvim_get_namespaces()) do
      local ok, marks = pcall(
        vim.api.nvim_buf_get_extmarks, buffer, namespace, 0, -1, {})
      assert(not ok or #marks == 0,
        "the skeleton buffer grew a persistent extmark")
    end
  end
end
Chaos.check = check

--- Run one campaign and return its report.
---
--- `on_failure` receives the recorded history so a caller can print an exact
--- replay recipe rather than a stack trace with no context.
function Chaos.run(opts)
  opts = opts or {}
  local seed = assert(opts.seed, "a campaign requires a seed")
  local actions = opts.actions or 500
  local rng = generator(seed)
  local world = build(rng, { window = opts.window })

  local ok, failure
  for step = 1, actions do
    local name = rng.pick(ACTION_NAMES)
    ok, failure = xpcall(function()
      ACTIONS[name](world)
      check(world)
    end, debug.traceback)
    if not ok then
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

  world.scheduler:dispose()
  world.projection:dispose(true)
  return {
    seed = seed,
    status = "ok",
    actions = actions,
    rows = #world.oracle,
    counts = world.counts,
    refusals = world.refusals,
  }
end

return Chaos
