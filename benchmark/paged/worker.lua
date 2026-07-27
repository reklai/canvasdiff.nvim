-- One isolated million-row measurement of the paged canvas engine.
--
-- Launched by benchmark/paged/run.lua in a fresh `nvim --headless --clean`
-- process; the coordinator sets every XDG directory and NVIM_LOG_FILE before
-- this process starts. This file measures, publishes JSON, and judges nothing:
-- the coordinator owns the gates.
--
-- The measured path is deliberately the engine, not the diff canvas:
--
--   corpus iterator -> canvas.paginate_stream -> canvas.project -> viewport
--
-- No step materializes a million rows. If any did, that is what the RSS
-- deltas below are for.

local uv = vim.uv
local API = vim.api

local function absolute(path)
  return (vim.fn.fnamemodify(path, ":p"):gsub("/+$", ""))
end

local script = absolute(debug.getinfo(1, "S").source:sub(2))
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
local output_path = _G.arg and _G.arg[1] and absolute(_G.arg[1]) or nil
local corpus_name = _G.arg and _G.arg[2] or nil
local run_index = tonumber(_G.arg and _G.arg[3])

local LOGICAL_ROWS = 1000000
local SCROLL_STEPS = 200
local JUMP_STEPS = 200
local HEARTBEAT_MS = 10
local IDLE_MS = 20
-- How long to leave the canvas idle so the bounded compactor can work through
-- it. One candidate per scheduler step by design, so this is deliberately
-- generous: memory measured mid-compaction describes a store that is still
-- settling, not one a user has been sitting in front of.
local COMPACTION_BUDGET_MS = 120000
-- A deliberately small resident cache: the claim is that a million rows are
-- displayable while only a handful of pages are decoded at any moment.
local RESIDENT_MAX_PAGES = 16
local RESIDENT_MAX_BYTES = 4 * 1024 * 1024
-- Enough repeated opens to separate a plateau from a slope, and few enough
-- that a million-row ingestion per cycle stays inside the worker timeout.
local OPEN_CLOSE_CYCLES = 6

local result = {
  schema_version = 1,
  benchmark = "canvasdiff.paged_million_row",
  profile = "paged-engine-v1",
  corpus = corpus_name,
  run_index = run_index,
  status = "fail",
}

local function mkdir(path)
  assert(vim.fn.mkdir(path, "p") == 1 or vim.fn.isdirectory(path) == 1,
    "could not create directory: " .. path)
end

local function atomic_json(path, value)
  mkdir(vim.fs.dirname(path))
  local temporary = ("%s.tmp.%d"):format(path, vim.fn.getpid())
  local file = assert(io.open(temporary, "wb"))
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    file:close()
    vim.fn.delete(temporary)
    error("could not encode benchmark JSON: " .. tostring(encoded), 0)
  end
  file:write(encoded, "\n")
  assert(file:close())
  local renamed, rename_err = uv.fs_rename(temporary, path)
  if not renamed then
    vim.fn.delete(temporary)
    error(("could not publish %s: %s"):format(path, rename_err or "rename failed"), 0)
  end
end

local function publish()
  if output_path then
    atomic_json(output_path, result)
  end
end

-- --- environment probes ------------------------------------------------------

local function proc_status_kib(field)
  local file = io.open("/proc/self/status", "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  local value = content:match(field .. ":%s+(%d+) kB")
  return value and tonumber(value) or nil
end

local rss_source
local function rss_bytes()
  local ok, bytes = pcall(uv.resident_set_memory)
  if ok and type(bytes) == "number" and bytes > 0 then
    rss_source = rss_source or "uv.resident_set_memory"
    return bytes
  end
  local kib = proc_status_kib("VmRSS")
  if kib then
    rss_source = rss_source or "/proc/self/status VmRSS"
    return kib * 1024
  end
  return nil
end

local function hwm_bytes()
  local kib = proc_status_kib("VmHWM")
  return kib and kib * 1024 or nil
end

local function heap_bytes()
  return collectgarbage("count") * 1024
end

-- --- deterministic corpora ---------------------------------------------------
--
-- Every corpus is a pure function of its row index, so a worker never holds
-- more than one row and two workers of the same shape produce identical text.
-- The digest below is over a fixed sample of rows rather than the whole
-- corpus: hashing a million rows would itself dominate the measurement.

local function lcg(seed)
  local state = seed
  return function(bound)
    state = (state * 1103515245 + 12345) % 2147483648
    return state % bound
  end
end

local CORPORA = {
  -- Highly compressible: the compaction codec should shine, and RSS is held
  -- to the tightest budget.
  repetitive = function(index)
    return ("the same line over and over, row %d"):format(index % 32)
  end,
  -- Incompressible-ish: every row differs, which is the honest upper bound.
  unique = function(index)
    return ("%d %s %d"):format(index, ("abcdefghijklmnop"):sub(
      (index % 16) + 1), index * 2654435761 % 4294967296)
  end,
  -- Wide rows: exercises per-row byte cost rather than row count.
  ["long-line"] = function(index)
    return ("%08d "):format(index) .. ("x"):rep(240 + (index % 16))
  end,
  -- Interleaved, so no page is uniformly one shape.
  mixed = function(index)
    local bucket = index % 4
    if bucket == 0 then
      return "shared boilerplate line"
    elseif bucket == 1 then
      return ("unique %d payload %d"):format(index, index * 31 % 7919)
    elseif bucket == 2 then
      return ("wide%06d "):format(index) .. ("y"):rep(180)
    end
    return ""
  end,
}

local function corpus_iterator(name, rows)
  local produce = assert(CORPORA[name], "unknown corpus: " .. tostring(name))
  local index = -1
  return function()
    index = index + 1
    if index >= rows then
      return nil
    end
    return produce(index)
  end
end

local function corpus_digest(name, rows)
  local produce = assert(CORPORA[name])
  local sample = {}
  local step = math.floor(rows / 512)
  for i = 0, 511 do
    sample[#sample + 1] = produce(i * step)
  end
  sample[#sample + 1] = produce(rows - 1)
  return vim.fn.sha256(table.concat(sample, "\n"))
end

-- --- timing ------------------------------------------------------------------

local function now_ms()
  return uv.hrtime() / 1e6
end

local function percentile(sorted, fraction)
  if #sorted == 0 then
    return nil
  end
  local rank = math.ceil(fraction * #sorted)
  if rank < 1 then rank = 1 end
  if rank > #sorted then rank = #sorted end
  return sorted[rank]
end

local function summarize(samples)
  local sorted = vim.deepcopy(samples)
  table.sort(sorted)
  local total = 0
  for _, value in ipairs(sorted) do
    total = total + value
  end
  return {
    count = #sorted,
    min_ms = sorted[1],
    median_ms = percentile(sorted, 0.5),
    p95_ms = percentile(sorted, 0.95),
    max_ms = sorted[#sorted],
    mean_ms = #sorted > 0 and (total / #sorted) or nil,
  }
end

-- --- the measurement ---------------------------------------------------------

local function configure_window(window)
  for name, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    wrap = false,
    list = false,
    spell = false,
    cursorline = false,
    winbar = "",
  }) do
    pcall(API.nvim_set_option_value, name, value, { win = window })
  end
  pcall(API.nvim_set_option_value, "statuscolumn", "", { win = window })
end

--- Put logical line `line1` at the top of the window and force one redraw,
--- returning how long that took. This is the operation the gates are about:
--- a user pressing a key and waiting for the screen.
local function show_at(projection, window, line1)
  local started = now_ms()
  API.nvim_win_set_cursor(window, { line1, 0 })
  API.nvim_win_call(window, function()
    vim.cmd("normal! zt")
  end)
  local ok, err = projection:redraw()
  assert(ok, err)
  local elapsed = now_ms() - started
  -- Let the loop run between operations. A headless `-l` script otherwise
  -- never yields, and a heartbeat that cannot tick measures nothing.
  vim.wait(0)
  return elapsed
end

local function count_extmarks(buffer)
  local total = 0
  for _, namespace in pairs(API.nvim_get_namespaces()) do
    local ok, marks = pcall(
      API.nvim_buf_get_extmarks, buffer, namespace, 0, -1, {})
    if ok then
      total = total + #marks
    end
  end
  return total
end

local ok, failure = xpcall(function()
  assert(output_path, "worker requires an output path")
  assert(corpus_name and CORPORA[corpus_name],
    "worker requires a known corpus name")
  assert(run_index and run_index >= 1, "worker requires a run index")

  vim.opt.runtimepath:prepend(repo_root)
  local canvas = require("canvasdiff.canvas")

  vim.o.laststatus = 0
  vim.o.showtabline = 0
  vim.o.ruler = false
  vim.o.showcmd = false
  vim.o.lazyredraw = false

  result.corpus_digest = corpus_digest(corpus_name, LOGICAL_ROWS)

  -- A heartbeat, armed once the canvas is on screen: the longest gap between
  -- its ticks is how long the editor was unresponsive while being USED, which
  -- no wall-clock timing of our own operations would reveal.
  --
  -- Ingestion is deliberately outside it. Building the store is one
  -- synchronous burst by construction, and `first_viewport_ms` is the gate
  -- that measures it; folding it into the heartbeat would report one number
  -- for two different questions.
  local heartbeat = { ticks = 0, max_gap_ms = 0 }
  local timer, last_tick

  collectgarbage("collect")
  collectgarbage("collect")
  local baseline = {
    rss_bytes = rss_bytes(),
    heap_bytes = heap_bytes(),
  }
  assert(baseline.rss_bytes, "no resident-set-size source is available")

  -- First viewport: ingestion through to the first drawn screen.
  local first_started = now_ms()
  local compression, compression_capability = canvas.compression()
  result.compression = compression_capability
    or { available = true, codec = compression.codec }
  local list, list_err = canvas.paginate_stream(
    corpus_iterator(corpus_name, LOGICAL_ROWS),
    compression and {
      resident = {
        max_pages = RESIDENT_MAX_PAGES,
        max_bytes = RESIDENT_MAX_BYTES,
        restore = compression,
      },
    } or nil)
  assert(list, list_err)
  local projection, projection_err = canvas.project(list)
  assert(projection, projection_err)

  local scheduler, scheduler_err = canvas.schedule(list, { idle_ms = IDLE_MS })
  assert(scheduler, scheduler_err)

  local buffer = assert(projection:buffer())
  API.nvim_set_current_buf(buffer)
  local window = API.nvim_get_current_win()
  configure_window(window)
  API.nvim_win_set_cursor(window, { 1, 0 })
  local drawn, draw_err = projection:redraw()
  assert(drawn, draw_err)
  result.first_viewport_ms = now_ms() - first_started

  result.logical_rows = list:row_count()
  result.page_count = list:page_count()

  -- Residency while a viewport is actually pinned. Sampling after the last
  -- redraw would report zero and prove nothing: the interesting claim is that
  -- a million rows are bounded WHILE being displayed.
  result.resident_while_displayed = list:resident_stats()

  -- Let the bounded idle compactor work. Without this the pages stay raw and
  -- every timing below would measure a decode that never happens -- which is
  -- not what a canvas that has been sitting open costs to scroll.
  --
  -- "complete" is the scheduler's own terminal phase: a verification pass that
  -- swept every page and found nothing left to compact. Waiting for it, rather
  -- than for a fixed duration, is what makes the memory numbers below describe
  -- a settled store instead of one caught mid-pass.
  local compaction_deadline = now_ms() + COMPACTION_BUDGET_MS
  local settled = false
  while now_ms() < compaction_deadline do
    vim.wait(50)
    local scheduler_stats = scheduler:stats()
    if scheduler_stats and scheduler_stats.phase == "complete" then
      settled = true
      break
    end
  end
  result.compaction = scheduler:stats()
  result.compaction_settled = settled
  result.compaction_error = scheduler:last_error()
  result.resident_after_compaction = list:resident_stats()

  local height = API.nvim_win_get_height(window)
  assert(height >= 1, "the measurement window has no rows")

  last_tick = now_ms()
  timer = assert(uv.new_timer())
  timer:start(HEARTBEAT_MS, HEARTBEAT_MS, function()
    local at = now_ms()
    local gap = at - last_tick
    last_tick = at
    heartbeat.ticks = heartbeat.ticks + 1
    if gap > heartbeat.max_gap_ms then
      heartbeat.max_gap_ms = gap
    end
  end)

  -- Sequential scroll: consecutive screens, which is what reading looks like.
  local scroll_samples = {}
  local line1 = 1
  for _ = 1, SCROLL_STEPS do
    line1 = line1 + height
    if line1 > LOGICAL_ROWS then
      line1 = 1
    end
    scroll_samples[#scroll_samples + 1] = show_at(projection, window, line1)
  end
  result.sequential_scroll = summarize(scroll_samples)

  -- Random jump: the adversarial access pattern, since every page is cold.
  -- Activity resets the idle scheduler: a user scrolling must not be racing a
  -- background compactor for the same pages.
  local touched, touch_err = scheduler:touch()
  assert(touched, touch_err)

  local next_row = lcg(0x5eed + run_index)
  local jump_samples = {}
  for _ = 1, JUMP_STEPS do
    local target = next_row(LOGICAL_ROWS) + 1
    jump_samples[#jump_samples + 1] = show_at(projection, window, target)
  end
  result.random_jump = summarize(jump_samples)

  -- A plateau, not an average: random jumps must not get slower the longer the
  -- canvas is used. Comparing the first quarter of the walk against the last
  -- one is what distinguishes a bounded cache from one that degrades as it
  -- fills, which a single p95 over the whole run would hide.
  local quarter = math.floor(#jump_samples / 4)
  local function slice(from, to)
    local part = {}
    for index = from, to do
      part[#part + 1] = jump_samples[index]
    end
    return summarize(part)
  end
  local first_quarter = slice(1, quarter)
  local last_quarter = slice(#jump_samples - quarter + 1, #jump_samples)
  result.jump_plateau = {
    samples = quarter,
    first_quarter_p95_ms = first_quarter.p95_ms,
    last_quarter_p95_ms = last_quarter.p95_ms,
    first_quarter_median_ms = first_quarter.median_ms,
    last_quarter_median_ms = last_quarter.median_ms,
  }

  timer:stop()
  timer:close()
  result.heartbeat = heartbeat

  -- Measured while the workload is still resident, before any cleanup.
  result.peak = {
    rss_bytes = rss_bytes(),
    rss_hwm_bytes = hwm_bytes(),
    heap_bytes = heap_bytes(),
  }
  collectgarbage("collect")
  collectgarbage("collect")
  result.retained = {
    rss_bytes = rss_bytes(),
    heap_bytes = heap_bytes(),
  }
  result.baseline = baseline
  result.rss_source = rss_source
  result.delta = {
    rss_bytes = (result.retained.rss_bytes or 0) - baseline.rss_bytes,
    peak_rss_bytes = (result.peak.rss_bytes or 0) - baseline.rss_bytes,
    heap_bytes = result.retained.heap_bytes - baseline.heap_bytes,
  }

  -- Bounds and shape, after the metrics that allocation would perturb.
  local resident = list:resident_stats()
  result.resident = resident
  result.pins = list:pin_stats()
  local stats = projection:stats()
  result.projection = {
    logical_rows = stats.logical_rows,
    skeleton_rows = stats.skeleton_rows,
    active_leases = stats.active_leases,
    overscan_rows = stats.overscan_rows,
    needs_sync = stats.needs_sync,
    last_error = stats.last_error,
  }
  result.row_extmarks = count_extmarks(buffer)

  -- Skeleton versus materialized, reported separately and never conflated.
  -- The skeleton is what Neovim scrolls over: one blank line per logical row,
  -- which is why native scrolling still works. The materialized rows are the
  -- only ones whose text exists anywhere at this instant -- the decoration
  -- window, backed by the resident pages. The gap between the two columns is
  -- the whole claim of the paged canvas.
  result.rows = {
    logical = stats.logical_rows,
    skeleton = stats.skeleton_rows,
    viewport = height,
    overscan = stats.overscan_rows,
    decoration_window = height + 2 * (stats.overscan_rows or 0),
    resident_pages = resident and resident.pages or nil,
    resident_bytes = resident and resident.bytes or nil,
    resident_max_pages = resident and resident.max_pages or nil,
    resident_max_bytes = resident and resident.max_bytes or nil,
  }

  -- The whole premise: a million logical rows must not be a million resident
  -- pages, and must not be a single persistent per-row extmark.
  result.resident_pages = resident and resident.pages or nil
  result.resident_bytes = resident and resident.bytes or nil

  local valid, valid_err = projection:validate()
  assert(valid, valid_err)

  assert(scheduler:dispose())
  assert(projection:dispose(true))

  -- Repeated open/close, last of all so that nothing above measures its churn.
  --
  -- One open tells you what a canvas costs; repeating it tells you whether
  -- closing one gives the memory back. A lane that only ever opens once cannot
  -- distinguish a bounded store from a per-open accumulation, which is the
  -- failure a user would actually hit -- reviewing file after file in one
  -- session. The verdict is the slope across cycles, not any single sample.
  local cycle_rss = {}
  for cycle = 1, OPEN_CLOSE_CYCLES do
    local cycle_list, cycle_list_err = canvas.paginate_stream(
      corpus_iterator(corpus_name, LOGICAL_ROWS),
      compression and {
        resident = {
          max_pages = RESIDENT_MAX_PAGES,
          max_bytes = RESIDENT_MAX_BYTES,
          restore = compression,
        },
      } or nil)
    assert(cycle_list, cycle_list_err)
    local cycle_projection, cycle_projection_err = canvas.project(cycle_list)
    assert(cycle_projection, cycle_projection_err)
    local cycle_buffer = assert(cycle_projection:buffer())
    API.nvim_set_current_buf(cycle_buffer)
    configure_window(window)
    API.nvim_win_set_cursor(window, { 1, 0 })
    local cycle_drawn, cycle_draw_err = cycle_projection:redraw()
    assert(cycle_drawn, cycle_draw_err)
    assert(cycle_projection:dispose(true))
    collectgarbage("collect")
    collectgarbage("collect")
    cycle_rss[cycle] = rss_bytes()
  end
  result.open_close = {
    cycles = OPEN_CLOSE_CYCLES,
    rss_bytes = cycle_rss,
    -- The plateau: how much the last cycle costs over the first settled one.
    -- The first cycle still carries one-time allocation, so the slope is
    -- measured from the second.
    settled_from_cycle = 2,
    plateau_delta_bytes = (cycle_rss[OPEN_CLOSE_CYCLES] or 0)
      - (cycle_rss[2] or cycle_rss[1] or 0),
  }

  result.status = "ok"
end, debug.traceback)

if not ok then
  result.status = "fail"
  result.error = tostring(failure)
end

publish()
os.exit(ok and 0 or 1)
