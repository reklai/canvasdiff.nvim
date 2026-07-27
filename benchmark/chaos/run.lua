-- Coordinator for the Phase 7 deliberate-breakage campaign.
--
-- Usage:
--   nvim --headless --clean -n -i NONE -l benchmark/chaos/run.lua [output.json] [actions] [seeds...]
--
-- The journey requires 10,000 deterministic actions for at least three seeds,
-- with every invariant asserted after every action and enough action history
-- retained for exact replay. The short campaign in `test/fault/test_chaos.lua`
-- runs the same seams on every `make test`; this is the full one.
--
-- As in the performance lane, judging lives here and only here.

local uv = vim.uv

local BENCHMARK = "canvasdiff.chaos_campaign"
local PROFILE = "paged-engine-chaos-v1"
local WORKER_SCHEMA = 1
local DEFAULT_ACTIONS = 10000
-- The Surface campaign runs real Git per action, so it is measured in
-- hundreds rather than thousands. Ten thousand of these would take hours and
-- test the same seams ten thousand times.
local DEFAULT_SURFACE_ACTIONS = 200
local DEFAULT_SEEDS = { 20260727, 990001, 4242 }
local MINIMUM_SEEDS = 3
local MINIMUM_DISTINCT_ACTIONS = 10
-- One action can splice, compact, rebuild a projection and sweep every
-- invariant, so a full campaign is minutes rather than seconds per seed.
local WORKER_TIMEOUT_MS = 1800000

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

--- Refuse a destination that lands back inside the checkout through any
--- symlink or `/proc` alias, resolving components that do not exist yet.
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
  local resolved = assert(uv.fs_realpath(cursor), "could not resolve " .. cursor)
  local canonical_repo = assert(uv.fs_realpath(repo_root))
  assert(resolved ~= canonical_repo
    and resolved:sub(1, #canonical_repo + 1) ~= canonical_repo .. "/",
    "campaign output must resolve outside the checkout: " .. path)
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
local raw_actions = _G.arg and _G.arg[2]

local actions = DEFAULT_ACTIONS
if raw_actions ~= nil and raw_actions ~= "" then
  actions = tonumber(raw_actions)
  assert(integer(actions) and actions >= 1 and actions <= 1000000,
    "actions must be an integer between 1 and 1000000")
end

local seeds = {}
for index = 3, 32 do
  local raw = _G.arg and _G.arg[index]
  if raw == nil or raw == "" then
    break
  end
  local seed = tonumber(raw)
  assert(integer(seed), "each seed must be an integer: " .. tostring(raw))
  seeds[#seeds + 1] = seed
end
if #seeds == 0 then
  seeds = DEFAULT_SEEDS
end
assert(#seeds >= MINIMUM_SEEDS,
  ("the campaign requires at least %d seeds"):format(MINIMUM_SEEDS))

local seen_seeds = {}
for _, seed in ipairs(seeds) do
  assert(not seen_seeds[seed],
    ("seed %d was given twice; repeating a seed is not extra coverage")
      :format(seed))
  seen_seeds[seed] = true
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
    temporary_root, ("canvasdiff-chaos-%d.json"):format(uv.hrtime()))
end

local isolated_root = vim.fs.joinpath(
  temporary_root,
  ("canvasdiff-chaos-lane-%d-%d"):format(vim.fn.getpid(), uv.hrtime()))
mkdir(isolated_root)

-- --- run ---------------------------------------------------------------------

local aggregate = {
  schema_version = 1,
  benchmark = BENCHMARK,
  profile = PROFILE,
  status = "fail",
  actions_per_seed = actions,
  seeds = seeds,
  requirements = {
    minimum_seeds = MINIMUM_SEEDS,
    minimum_actions_per_seed = DEFAULT_ACTIONS,
    minimum_distinct_actions = MINIMUM_DISTINCT_ACTIONS,
  },
  environment = {
    revision = git({ "rev-parse", "HEAD" }),
    dirty = git({ "status", "--porcelain" }) ~= "",
    nvim_version = tostring(vim.version()),
    lua = _VERSION,
    jit = jit and jit.version or nil,
  },
  runs = {},
  failures = {},
}

local function fail(message)
  aggregate.failures[#aggregate.failures + 1] = message
end

local function launch(seed, result_path, log_path, harness, count)
  return vim.system({
    vim.v.progpath, "--headless", "--clean", "-n", "-i", "NONE",
    "-l", worker_path, result_path, tostring(seed), tostring(count), harness,
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
end

--- Everything a worker claims is untrusted until it is shaped correctly.
local function validate(payload, seed, expected_actions)
  local problems = {}
  local function require_field(name, predicate, description)
    if not predicate(payload[name]) then
      problems[#problems + 1] = ("%s must be %s, got %s")
        :format(name, description, vim.inspect(payload[name]))
    end
  end
  require_field("schema_version", function(v) return v == WORKER_SCHEMA end,
    "schema " .. WORKER_SCHEMA)
  require_field("benchmark", function(v) return v == BENCHMARK end, BENCHMARK)
  require_field("profile", function(v) return v == PROFILE end, PROFILE)
  require_field("seed", function(v) return v == seed end, "seed " .. seed)
  require_field("status", function(v) return v == "ok" end, "ok")
  require_field("completed_actions",
    function(v) return v == expected_actions end,
    ("exactly %d actions"):format(expected_actions))
  require_field("distinct_actions", integer, "an integer distinct-action count")
  if type(payload.counts) ~= "table" then
    problems[#problems + 1] = "counts is not an action histogram"
  end
  return problems
end

local function judge(payload, harness)
  local verdicts = {}
  if payload.completed_actions ~= harness.count then
    verdicts[#verdicts + 1] = ("completed %s of %d actions")
      :format(tostring(payload.completed_actions), harness.count)
  end
  local minimum_distinct = harness.name == "surface" and 6
    or MINIMUM_DISTINCT_ACTIONS
  if (payload.distinct_actions or 0) < minimum_distinct then
    verdicts[#verdicts + 1] = ("only %d distinct actions ran; the campaign did not reach its seams")
      :format(payload.distinct_actions or 0)
  end

  -- A campaign where nothing was ever refused injected no hostility. The
  -- codec seam is the one that must always produce refusals, so its absence
  -- means the injection stopped working rather than that the engine got
  -- better.
  local refusals = payload.refusals or {}
  local total_refusals = 0
  for _, count in pairs(refusals) do
    total_refusals = total_refusals + count
  end
  if total_refusals == 0 then
    verdicts[#verdicts + 1] =
      "no injected failure was ever refused, so nothing hostile actually ran"
  end

  -- The store must not have drained to nothing: a campaign that ends on an
  -- empty store spent its second half proving very little. Only the engine
  -- campaign has a store of its own.
  if harness.name == "engine" and (payload.final_rows or 0) < 100 then
    verdicts[#verdicts + 1] = ("the store drained to %d rows")
      :format(payload.final_rows or 0)
  end
  return verdicts
end

local HARNESSES = {
  { name = "engine", count = actions },
  { name = "surface", count = DEFAULT_SURFACE_ACTIONS },
}

for _, harness in ipairs(HARNESSES) do
for _, seed in ipairs(seeds) do
  local slug = ("%s-seed-%d"):format(harness.name, seed)
  local result_path = vim.fs.joinpath(isolated_root, slug .. ".json")
  local log_path = vim.fs.joinpath(isolated_root, slug .. ".log")
  local completed = launch(seed, result_path, log_path, harness.name, harness.count)

  local record = {
    harness = harness.name,
    seed = seed,
    exit_code = completed.code,
    signal = completed.signal,
  }
  local payload, read_err = read_json(result_path)
  if not payload then
    record.status = "fail"
    record.error = read_err
    record.stderr = completed.stderr
    fail(("seed %d: %s"):format(seed, record.error))
  else
    record.campaign_status = payload.campaign_status
    record.completed_actions = payload.completed_actions
    record.distinct_actions = payload.distinct_actions
    record.final_rows = payload.final_rows
    record.counts = payload.counts
    record.refusals = payload.refusals
    record.wall_ns = payload.wall_ns
    -- Replay evidence, retained on failure and only on failure: the history is
    -- long, and a passing campaign has nothing to reproduce.
    if payload.status ~= "ok" then
      record.failed_at = payload.failed_at
      record.failed_action = payload.failed_action
      record.error = payload.campaign_error or payload.error
      record.history = payload.history
    end

    local problems = validate(payload, seed, harness.count)
    if #problems > 0 then
      record.status = "fail"
      record.error = record.error or table.concat(problems, "; ")
      fail(("seed %d: %s"):format(seed, table.concat(problems, "; ")))
    else
      local verdicts = judge(payload, harness)
      record.status = #verdicts == 0 and "ok" or "fail"
      if #verdicts > 0 then
        record.gate_failures = verdicts
        for _, verdict in ipairs(verdicts) do
          fail(("seed %d: %s"):format(seed, verdict))
        end
      end
    end
  end
  aggregate.runs[#aggregate.runs + 1] = record
  print(("%-8s seed %-10d %-6s %s actions, %s distinct"):format(
    harness.name, seed, record.status or "fail",
    tostring(record.completed_actions), tostring(record.distinct_actions)))
end
end

-- Different seeds must not have produced the same campaign, or the seed is
-- decorative and "three seeds" is really one.
local histograms = {}
for _, record in ipairs(aggregate.runs) do
  if record.counts then
    local encoded = (record.harness or "engine") .. vim.json.encode(record.counts)
    if histograms[encoded] then
      fail(("seeds %d and %d ran identical campaigns")
        :format(histograms[encoded], record.seed))
    end
    histograms[encoded] = record.seed
  end
end

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
