-- Coordinator for the million-row paged-engine acceptance lane.
--
-- Usage:
--   nvim --headless --clean -n -i NONE -l benchmark/paged/run.lua [output.json] [repetitions]
--
-- This process measures nothing. It creates one isolated environment per
-- measurement, launches a worker in a fresh Neovim, validates the untrusted
-- JSON that comes back, applies the journey's gates, and publishes one
-- aggregate atomically. Judging lives here and only here, so a worker cannot
-- pass itself.

local uv = vim.uv

local BENCHMARK = "canvasdiff.paged_million_row"
local PROFILE = "paged-engine-v1"
local WORKER_SCHEMA = 1
local CORPORA = { "repetitive", "unique", "long-line", "mixed" }
local WORKER_TIMEOUT_MS = 300000
local MIB = 1024 * 1024

-- The journey's acceptance table. Every entry is a hard gate: a measurement
-- outside it fails the lane rather than being reported as a regression.
local GATES = {
  logical_rows = { exact = 1000000 },
  first_viewport_ms = { max = 1000 },
  sequential_scroll_p95_ms = { max = 16 },
  sequential_scroll_max_ms = { max = 50 },
  random_jump_p95_ms = { max = 16 },
  random_jump_max_ms = { max = 50 },
  heartbeat_max_gap_ms = { max = 50 },
  row_extmarks = { exact = 0 },
}

-- Same reasoning as RSS: the heap budget is stated for a settled store of the
-- shapes the journey names, and applied to those.
local HEAP_GATES = {
  repetitive = 128 * MIB,
  unique = 128 * MIB,
}

-- The journey states an RSS budget for two corpora only, and deliberately so:
-- repetitive text should compact far harder than text where every row differs,
-- and those two bracket the range. `long-line` and `mixed` are measured and
-- reported without a gate, because inventing a threshold for them would be
-- asserting a number nobody chose.
--
-- That matters most for `long-line`, whose resident plateau is roughly its raw
-- corpus size even after every page is compacted: one store's worth of
-- ingestion memory stays resident for the life of the process. It was measured
-- flat across twenty consecutive build/compact/discard cycles at 50,000 and
-- 200,000 rows, so it is a bounded one-time plateau rather than a leak, and
-- gating on it would be gating on the allocator rather than on the engine.
-- What actually proves the invariant is gated below and separately: the
-- resident page cap, and zero persistent per-row extmarks.
local RSS_GATES = {
  repetitive = 96 * MIB,
  unique = 256 * MIB,
}

-- Plateau tolerances. These are shaped to catch a trend, not to pin a number:
-- a cache that degrades as it fills shows up as a multiple, and repeated
-- open/close that never gives memory back shows up as steady growth. Both are
-- deliberately loose enough that ordinary run-to-run noise cannot trip them.
local JUMP_PLATEAU_FACTOR = 2
local JUMP_PLATEAU_SLACK_MS = 4
local OPEN_CLOSE_PLATEAU_MAX_BYTES = 32 * MIB

local function absolute(path)
  local resolved = vim.fn.fnamemodify(path, ":p")
  if resolved ~= "/" then
    resolved = (resolved:gsub("/+$", ""))
  end
  return resolved
end

local script = absolute(debug.getinfo(1, "S").source:sub(2))
local lane_root = vim.fs.dirname(script)
local repo_root = vim.fs.dirname(vim.fs.dirname(lane_root))
local worker_path = vim.fs.joinpath(lane_root, "worker.lua")

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
  return finite(value) and value == math.floor(value)
end

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
    error("could not encode aggregate JSON: " .. tostring(encoded), 0)
  end
  file:write(encoded, "\n")
  assert(file:close())
  local renamed, rename_err = uv.fs_rename(temporary, path)
  if not renamed then
    vim.fn.delete(temporary)
    error(("could not publish %s: %s"):format(path, rename_err or "rename failed"), 0)
  end
end

local function read_json(path)
  local file = io.open(path, "rb")
  if not file then
    return nil, "worker published no JSON at " .. path
  end
  local content = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil, "worker JSON is malformed"
  end
  return decoded
end

--- Resolve a destination that does not exist yet, and refuse one that lands
--- back inside the checkout through any symlink or `/proc` alias.
local function outside_repo(path)
  local cursor = absolute(path)
  local missing = {}
  while not uv.fs_lstat(cursor) do
    local parent = vim.fs.dirname(cursor)
    assert(parent and parent ~= cursor,
      "could not resolve an existing ancestor for: " .. path)
    table.insert(missing, 1, vim.fs.basename(cursor))
    cursor = parent
  end
  local resolved = assert(uv.fs_realpath(cursor),
    "could not resolve " .. cursor)
  local canonical_repo = assert(uv.fs_realpath(repo_root))
  assert(resolved ~= canonical_repo
    and resolved:sub(1, #canonical_repo + 1) ~= canonical_repo .. "/",
    "benchmark output must resolve outside the checkout: " .. path)
  for _, component in ipairs(missing) do
    resolved = vim.fs.joinpath(resolved, component)
  end
  return resolved
end

local function git(arguments)
  local completed = vim.system(
    vim.list_extend({ "git", "-C", repo_root }, arguments),
    { text = true }):wait()
  if completed.code ~= 0 then
    return nil
  end
  return (completed.stdout or ""):gsub("%s+$", "")
end

-- --- arguments ---------------------------------------------------------------

local raw_output = _G.arg and _G.arg[1]
local raw_repetitions = _G.arg and _G.arg[2]
assert(not (_G.arg and _G.arg[3]),
  "unexpected extra argument: " .. tostring(_G.arg and _G.arg[3]))

local repetitions = 3
if raw_repetitions ~= nil and raw_repetitions ~= "" then
  repetitions = tonumber(raw_repetitions)
  assert(integer(repetitions) and repetitions >= 1 and repetitions <= 10,
    "repetitions must be an integer between 1 and 10")
end

local temporary_root = assert(uv.fs_realpath(uv.os_tmpdir() or "/tmp"))
local canonical_repo = assert(uv.fs_realpath(repo_root))
if temporary_root == canonical_repo
    or temporary_root:sub(1, #canonical_repo + 1) == canonical_repo .. "/" then
  temporary_root = assert(uv.fs_realpath("/tmp"))
end

local output_path
if raw_output ~= nil and raw_output ~= "" then
  output_path = outside_repo(raw_output)
else
  output_path = vim.fs.joinpath(
    temporary_root, ("canvasdiff-paged-%d.json"):format(uv.hrtime()))
end

local isolated_root = vim.fs.joinpath(
  temporary_root, ("canvasdiff-paged-lane-%d-%d"):format(vim.fn.getpid(), uv.hrtime()))
mkdir(isolated_root)

-- --- run ---------------------------------------------------------------------

local aggregate = {
  schema_version = 1,
  benchmark = BENCHMARK,
  profile = PROFILE,
  status = "fail",
  repetitions = repetitions,
  corpora = CORPORA,
  gates = {
    thresholds = GATES,
    rss_delta_bytes = RSS_GATES,
    heap_delta_bytes = HEAP_GATES,
    jump_plateau_factor = JUMP_PLATEAU_FACTOR,
    jump_plateau_slack_ms = JUMP_PLATEAU_SLACK_MS,
    open_close_plateau_max_bytes = OPEN_CLOSE_PLATEAU_MAX_BYTES,
  },
  environment = {
    revision = git({ "rev-parse", "HEAD" }),
    dirty = git({ "status", "--porcelain" }) ~= "",
    nvim_version = tostring(vim.version()),
    lua = _VERSION,
    jit = jit and jit.version or nil,
    uname = (function()
      local info = uv.os_uname()
      return info and {
        sysname = info.sysname,
        machine = info.machine,
        release = info.release,
      } or nil
    end)(),
    cpus = (function()
      local ok, info = pcall(uv.cpu_info)
      return ok and info and #info or nil
    end)(),
    total_memory_bytes = uv.get_total_memory(),
  },
  runs = {},
  failures = {},
}

local function fail(message)
  aggregate.failures[#aggregate.failures + 1] = message
end

local function launch(corpus, index, result_path, log_path)
  local completed = vim.system({
    vim.v.progpath, "--headless", "--clean", "-n", "-i", "NONE",
    "-l", worker_path, result_path, corpus, tostring(index),
  }, {
    cwd = repo_root,
    text = true,
    timeout = WORKER_TIMEOUT_MS,
    env = {
      PATH = vim.env.PATH,
      HOME = isolated_root,
      LANG = "C",
      LC_ALL = "C",
      TERM = "dumb",
      NVIM_LOG_FILE = log_path,
      XDG_CONFIG_HOME = vim.fs.joinpath(isolated_root, "config"),
      XDG_DATA_HOME = vim.fs.joinpath(isolated_root, "data"),
      XDG_STATE_HOME = vim.fs.joinpath(isolated_root, "state"),
      XDG_CACHE_HOME = vim.fs.joinpath(isolated_root, "cache"),
      XDG_RUNTIME_DIR = vim.fs.joinpath(isolated_root, "runtime"),
    },
  }):wait()
  return completed
end

--- Everything a worker claims is untrusted until it is shaped correctly.
local function validate(payload, corpus, index)
  local problems = {}
  local function require_field(name, predicate, description)
    local value = payload[name]
    if not predicate(value) then
      problems[#problems + 1] = ("%s must be %s, got %s")
        :format(name, description, vim.inspect(value))
      return nil
    end
    return value
  end

  require_field("schema_version", function(v) return v == WORKER_SCHEMA end,
    "schema " .. WORKER_SCHEMA)
  require_field("benchmark", function(v) return v == BENCHMARK end, BENCHMARK)
  require_field("profile", function(v) return v == PROFILE end, PROFILE)
  require_field("corpus", function(v) return v == corpus end, corpus)
  require_field("run_index", function(v) return v == index end, "run " .. index)
  require_field("status", function(v) return v == "ok" end, "ok")
  require_field("logical_rows", integer, "an integer row count")
  require_field("first_viewport_ms", finite, "a finite duration")
  require_field("row_extmarks", integer, "an integer extmark count")
  for _, name in ipairs({ "sequential_scroll", "random_jump" }) do
    local phase = payload[name]
    if type(phase) ~= "table" or not finite(phase.p95_ms)
        or not finite(phase.max_ms) or not integer(phase.count) then
      problems[#problems + 1] = name .. " is not a complete timing summary"
    end
  end
  local delta = payload.delta
  if type(delta) ~= "table" or not finite(delta.rss_bytes)
      or not finite(delta.heap_bytes) then
    problems[#problems + 1] = "delta is not a complete memory summary"
  end
  local heartbeat = payload.heartbeat
  if type(heartbeat) ~= "table" or not finite(heartbeat.max_gap_ms)
      or not integer(heartbeat.ticks) or heartbeat.ticks < 1 then
    problems[#problems + 1] = "heartbeat never ticked, so it measured nothing"
  end
  return problems
end

local function judge(payload, corpus)
  local measured = {
    logical_rows = payload.logical_rows,
    first_viewport_ms = payload.first_viewport_ms,
    sequential_scroll_p95_ms = payload.sequential_scroll.p95_ms,
    sequential_scroll_max_ms = payload.sequential_scroll.max_ms,
    random_jump_p95_ms = payload.random_jump.p95_ms,
    random_jump_max_ms = payload.random_jump.max_ms,
    heartbeat_max_gap_ms = payload.heartbeat.max_gap_ms,
    row_extmarks = payload.row_extmarks,
    heap_delta_bytes = payload.delta.heap_bytes,
    rss_delta_bytes = payload.delta.rss_bytes,
  }
  local verdicts = {}
  for name, gate in pairs(GATES) do
    local value = measured[name]
    if gate.exact ~= nil and value ~= gate.exact then
      verdicts[#verdicts + 1] = ("%s: %s is not exactly %s")
        :format(name, tostring(value), tostring(gate.exact))
    elseif gate.max ~= nil and value > gate.max then
      verdicts[#verdicts + 1] = ("%s: %s exceeds %s")
        :format(name, tostring(value), tostring(gate.max))
    end
  end
  local rss_gate = RSS_GATES[corpus]
  if rss_gate and payload.delta.rss_bytes > rss_gate then
    verdicts[#verdicts + 1] = ("rss_delta_bytes: %d exceeds %d for %s")
      :format(payload.delta.rss_bytes, rss_gate, corpus)
  end
  local heap_gate = HEAP_GATES[corpus]
  if heap_gate and payload.delta.heap_bytes > heap_gate then
    verdicts[#verdicts + 1] = ("heap_delta_bytes: %d exceeds %d for %s")
      :format(payload.delta.heap_bytes, heap_gate, corpus)
  end

  -- Memory measured while the compactor is still working describes a store
  -- that has not settled, so the budgets above would be judging the wrong
  -- thing.
  if payload.compaction_settled ~= true then
    verdicts[#verdicts + 1] =
      "compaction did not settle within the worker budget"
  end

  -- The resident cache is the whole premise: a million rows must never be a
  -- million resident pages.
  local resident = payload.resident
  if type(resident) == "table" and integer(resident.pages)
      and integer(resident.max_pages) and resident.pages > resident.max_pages then
    verdicts[#verdicts + 1] = ("resident pages %d exceed the cap of %d")
      :format(resident.pages, resident.max_pages)
  end
  if type(resident) == "table" and finite(resident.bytes)
      and finite(resident.max_bytes) and resident.bytes > resident.max_bytes then
    verdicts[#verdicts + 1] = ("resident bytes %d exceed the cap of %d")
      :format(resident.bytes, resident.max_bytes)
  end

  -- A skeleton row per logical row is what keeps native scrolling exact; if
  -- these ever diverge, every row address in the display stack is wrong.
  local rows = payload.rows
  if type(rows) ~= "table" or rows.skeleton ~= rows.logical then
    verdicts[#verdicts + 1] = "skeleton rows do not match logical rows"
  end

  -- Plateaus, both of them. Degradation over a session is the failure these
  -- catch, and neither is visible in a whole-run aggregate.
  local plateau = payload.jump_plateau
  if type(plateau) ~= "table" or not finite(plateau.first_quarter_p95_ms)
      or not finite(plateau.last_quarter_p95_ms) then
    verdicts[#verdicts + 1] = "random jump reported no plateau"
  elseif plateau.last_quarter_p95_ms
      > plateau.first_quarter_p95_ms * JUMP_PLATEAU_FACTOR + JUMP_PLATEAU_SLACK_MS then
    verdicts[#verdicts + 1] = ("random jump degrades: last-quarter p95 %.2f ms against first-quarter %.2f ms")
      :format(plateau.last_quarter_p95_ms, plateau.first_quarter_p95_ms)
  end

  local cycles = payload.open_close
  if type(cycles) ~= "table" or not finite(cycles.plateau_delta_bytes)
      or not integer(cycles.cycles) or cycles.cycles < 3 then
    verdicts[#verdicts + 1] = "repeated open/close reported no plateau"
  elseif cycles.plateau_delta_bytes > OPEN_CLOSE_PLATEAU_MAX_BYTES then
    verdicts[#verdicts + 1] = ("repeated open/close grows %d bytes across %d cycles")
      :format(cycles.plateau_delta_bytes, cycles.cycles)
  end
  return measured, verdicts
end

for _, corpus in ipairs(CORPORA) do
  for index = 1, repetitions do
    local slug = ("%s-%d"):format(corpus:gsub("%W", "_"), index)
    local result_path = vim.fs.joinpath(isolated_root, slug .. ".json")
    local log_path = vim.fs.joinpath(isolated_root, slug .. ".log")
    local completed = launch(corpus, index, result_path, log_path)

    local record = {
      corpus = corpus,
      run_index = index,
      exit_code = completed.code,
      signal = completed.signal,
    }
    local payload, read_err = read_json(result_path)
    if completed.code ~= 0 or not payload then
      record.status = "fail"
      record.error = read_err or (payload and payload.error)
        or ("worker exited %s"):format(tostring(completed.code))
      record.stderr = completed.stderr
      fail(("%s run %d: %s"):format(corpus, index, record.error))
    else
      local problems = validate(payload, corpus, index)
      if #problems > 0 then
        record.status = "fail"
        record.error = table.concat(problems, "; ")
        fail(("%s run %d: %s"):format(corpus, index, record.error))
      else
        local measured, verdicts = judge(payload, corpus)
        record.status = #verdicts == 0 and "ok" or "fail"
        record.measured = measured
        record.rss_delta_bytes = payload.delta.rss_bytes
        record.compression = payload.compression
        record.compaction = payload.compaction and {
          phase = payload.compaction.phase,
          compacted = payload.compaction.compacted,
          attempts = payload.compaction.attempts,
          error_count = payload.compaction.error_count,
          last_error = payload.compaction.last_error,
        } or nil
        record.resident = payload.resident
        record.rows = payload.rows
        record.jump_plateau = payload.jump_plateau
        record.open_close = payload.open_close
        record.page_count = payload.page_count
        record.corpus_digest = payload.corpus_digest
        record.projection = payload.projection
        if #verdicts > 0 then
          record.gate_failures = verdicts
          for _, verdict in ipairs(verdicts) do
            fail(("%s run %d: %s"):format(corpus, index, verdict))
          end
        end
      end
    end
    aggregate.runs[#aggregate.runs + 1] = record
    print(("%-10s run %d  %s"):format(corpus, index, record.status or "fail"))
  end
end

-- Two workers of the same corpus must have measured the same text.
local digests = {}
for _, record in ipairs(aggregate.runs) do
  if record.corpus_digest then
    local seen = digests[record.corpus]
    if seen and seen ~= record.corpus_digest then
      fail(("%s produced two different corpora across runs"):format(record.corpus))
    end
    digests[record.corpus] = record.corpus_digest
  end
end
aggregate.corpus_digests = digests

aggregate.status = #aggregate.failures == 0 and "ok" or "fail"
atomic_json(output_path, aggregate)
print(("\n%s -> %s"):format(aggregate.status, output_path))
if aggregate.status ~= "ok" then
  print(("%d failure(s); the isolated worker directory is retained at %s")
    :format(#aggregate.failures, isolated_root))
  for _, message in ipairs(aggregate.failures) do
    print("  - " .. message)
  end
  os.exit(1)
end
vim.fn.delete(isolated_root, "rf")
os.exit(0)
