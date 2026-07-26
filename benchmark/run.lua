-- Coordinator for the isolated eager-canvas baseline.
--
-- Usage:
--   nvim --headless --clean -n -i NONE -l benchmark/run.lua [output.json] [repetitions]
--
-- Every measurement is a separate Neovim process. This process performs no
-- measurement itself; it creates isolated environments, launches workers,
-- validates their untrusted JSON, and publishes one aggregate atomically.

local uv = vim.uv
local EXPECTED_BENCHMARK = "canvasdiff.eager_small_open"
local EXPECTED_PROFILE = "eager-core-v1"
local WORKER_SCHEMA = 1

local function absolute(path)
  local resolved = vim.fn.fnamemodify(path, ":p")
  if resolved ~= "/" then
    resolved = resolved:gsub("/+$", "")
  end
  return resolved
end

local function finite_number(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function integer(value)
  return finite_number(value) and value == math.floor(value)
end

local function sha256(value)
  return type(value) == "string"
    and #value == 64
    and value:match("^[0-9a-f]+$") ~= nil
end

--- Resolve an existing path, or resolve the nearest existing ancestor and
--- append its still-missing components. This catches output aliases such as
--- `/tmp/repo-link/result.json` and `/proc/self/cwd/result.json` before any
--- directory or file is created.
local function canonical_future(path)
  local cursor = absolute(path)
  local missing = {}
  while not uv.fs_lstat(cursor) do
    local parent = vim.fs.dirname(cursor)
    assert(parent and parent ~= cursor,
      "could not resolve an existing ancestor for: " .. path)
    table.insert(missing, 1, vim.fs.basename(cursor))
    cursor = parent
  end

  local resolved, resolve_error = uv.fs_realpath(cursor)
  assert(resolved, ("could not resolve %s: %s"):format(
    cursor, resolve_error or "realpath failed"))
  for _, component in ipairs(missing) do
    resolved = vim.fs.joinpath(resolved, component)
  end
  return absolute(resolved)
end

--- Canonical identity of an atomic-rename destination. Resolve only the
--- destination parent: an existing final-component symlink is replaced by
--- rename(2), not followed.
local function canonical_destination(path)
  path = absolute(path)
  assert(path ~= "/", "benchmark artifact must name a file")
  return absolute(vim.fs.joinpath(
    canonical_future(vim.fs.dirname(path)),
    vim.fs.basename(path)
  ))
end

local function is_within(path, directory)
  return path == directory
    or path:sub(1, #directory + 1) == directory .. "/"
end

local args = _G.arg or {}
for key, value in pairs(args) do
  if type(key) == "number" and key >= 3 and value ~= nil then
    error(("unexpected coordinator argument #%d: %s"):format(
      key, tostring(value)), 0)
  end
end

local script = absolute(debug.getinfo(1, "S").source:sub(2))
local repo_root = vim.fs.dirname(vim.fs.dirname(script))
local canonical_repo_root = assert(uv.fs_realpath(repo_root))
local worker = vim.fs.joinpath(repo_root, "benchmark", "worker.lua")

local function safe_temporary_root()
  local candidates = { uv.os_tmpdir(), "/tmp" }
  local seen = {}
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "string" and candidate ~= ""
        and not seen[candidate] then
      seen[candidate] = true
      local resolved_ok, resolved = pcall(canonical_future, candidate)
      local stat = resolved_ok and uv.fs_stat(resolved) or nil
      if stat and stat.type == "directory"
          and not is_within(resolved, canonical_repo_root) then
        return resolved
      end
    end
  end
  error("could not resolve a temporary directory outside the repository", 0)
end

local temporary_root = safe_temporary_root()
local default_name = ("canvasdiff-eager-baseline-%s-%d.json"):format(
  os.date("!%Y%m%dT%H%M%SZ"),
  vim.fn.getpid()
)
local output_path = absolute(
  args[1] or vim.fs.joinpath(temporary_root, default_name)
)
local output_stat = uv.fs_lstat(output_path)
assert(not output_stat or output_stat.type ~= "directory",
  "benchmark artifact path is an existing directory: " .. output_path)
local canonical_output = canonical_destination(output_path)
assert(not is_within(canonical_output, canonical_repo_root),
  "benchmark artifact resolves inside the repository: " .. canonical_output)

local repetitions = 5
if args[2] ~= nil then
  repetitions = tonumber(args[2])
  assert(repetitions ~= nil,
    "repetitions must be an integer between 1 and 20; got: "
      .. tostring(args[2]))
end
assert(integer(repetitions) and repetitions >= 1 and repetitions <= 20,
  "repetitions must be an integer between 1 and 20")

local timeout_ms = 60000

local function mkdir(path)
  assert(vim.fn.mkdir(path, "p") == 1 or vim.fn.isdirectory(path) == 1,
    "could not create directory: " .. path)
end

local function mkdir_private(path)
  mkdir(path)
  local changed, change_error = uv.fs_chmod(path, 448) -- 0700
  assert(changed, ("could not chmod 0700 %s: %s"):format(
    path, change_error or "chmod failed"))
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
  local renamed, rename_error = uv.fs_rename(temporary, path)
  if not renamed then
    vim.fn.delete(temporary)
    error(("could not publish %s: %s"):format(
      path, rename_error or "rename failed"), 0)
  end
end

local function read_json(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return vim.json.decode(content)
end

local function tail(text, limit)
  text = text or ""
  if #text <= limit then
    return text
  end
  return text:sub(#text - limit + 1)
end

local function summary(values)
  local ordered = vim.deepcopy(values)
  table.sort(ordered)
  local count = #ordered
  local middle
  if count % 2 == 1 then
    middle = ordered[(count + 1) / 2]
  else
    middle = math.floor(
      (ordered[count / 2] + ordered[count / 2 + 1]) / 2
    )
  end
  return {
    minimum = ordered[1],
    median = middle,
    maximum = ordered[count],
  }
end

local function validation_error(errors, condition, message)
  if not condition then
    errors[#errors + 1] = message
  end
end

local required_metrics = {
  "open_wall_ns",
  "close_wall_ns",
  "rss_before_bytes",
  "rss_after_open_bytes",
  "rss_after_open_gc_bytes",
  "rss_after_close_bytes",
  "rss_open_delta_bytes",
  "rss_retained_delta_bytes",
  "rss_after_close_delta_bytes",
  "rss_hwm_before_bytes",
  "rss_hwm_after_open_bytes",
  "rss_hwm_delta_bytes",
  "lua_heap_before_bytes",
  "lua_heap_after_open_bytes",
  "lua_heap_retained_bytes",
  "lua_heap_after_close_bytes",
  "lua_heap_open_delta_bytes",
  "lua_heap_retained_delta_bytes",
  "lua_heap_after_close_delta_bytes",
}

local aggregate_metric_names = {
  "open_wall_ns",
  "close_wall_ns",
  "rss_open_delta_bytes",
  "rss_retained_delta_bytes",
  "rss_after_close_delta_bytes",
  "rss_hwm_delta_bytes",
  "lua_heap_open_delta_bytes",
  "lua_heap_retained_delta_bytes",
  "lua_heap_after_close_delta_bytes",
  "worker_process_wall_ns",
}

--- Validate worker-owned JSON before the coordinator mutates the decoded table.
local function validate_worker(worker_result, expected_index)
  local errors = {}
  validation_error(errors, worker_result.schema_version == WORKER_SCHEMA,
    "schema_version must be " .. WORKER_SCHEMA)
  validation_error(errors, worker_result.benchmark == EXPECTED_BENCHMARK,
    "unexpected benchmark identity")
  validation_error(errors, worker_result.run_index == expected_index,
    "run_index does not match the launched worker")
  validation_error(errors,
    worker_result.status == "pass" or worker_result.status == "fail",
    "status must be pass or fail")

  if worker_result.status ~= "pass" then
    validation_error(errors, type(worker_result.error) == "string",
      "failed worker must provide an error string")
    return errors
  end

  local profile = worker_result.profile
  validation_error(errors, type(profile) == "table",
    "passing worker requires profile metadata")
  if type(profile) == "table" then
    validation_error(errors, profile.name == EXPECTED_PROFILE,
      "unexpected worker profile")
    validation_error(errors, profile.command == ":CanvasDiff open",
      "worker did not measure the real open command")
  end

  local capabilities = worker_result.capabilities
  local memory = type(capabilities) == "table" and capabilities.memory or nil
  validation_error(errors, type(memory) == "table",
    "passing worker requires memory capabilities")
  if type(memory) == "table" then
    validation_error(errors,
      type(memory.rss_source) == "string" and memory.rss_source ~= "",
      "RSS capability source is missing")
    validation_error(errors,
      type(memory.hwm_source) == "string" and memory.hwm_source ~= "",
      "high-water RSS capability source is missing")
    validation_error(errors, type(memory.hwm_is_fallback) == "boolean",
      "high-water fallback flag must be boolean")
  end

  local environment = worker_result.environment
  validation_error(errors, type(environment) == "table",
    "passing worker requires environment metadata")
  if type(environment) == "table" then
    for _, name in ipairs({
      "git_revision", "nvim", "lua", "lua_os", "lua_arch", "os",
      "machine", "git", "host_fingerprint", "source_tree_digest",
    }) do
      validation_error(errors,
        type(environment[name]) == "string" and environment[name] ~= "",
        "environment." .. name .. " must be a non-empty string")
    end
    validation_error(errors, type(environment.git_dirty) == "boolean",
      "environment.git_dirty must be boolean")
    validation_error(errors, sha256(environment.host_fingerprint),
      "host fingerprint must be SHA-256")
    validation_error(errors, sha256(environment.source_tree_digest),
      "source-tree digest must be SHA-256")
    validation_error(errors,
      integer(environment.source_tree_entries)
        and environment.source_tree_entries > 0,
      "source-tree entry count must be a positive integer")
  end

  local corpus = worker_result.corpus
  validation_error(errors, type(corpus) == "table",
    "passing worker requires corpus metadata")
  if type(corpus) == "table" then
    validation_error(errors, sha256(corpus.digest),
      "corpus digest must be SHA-256")
    validation_error(errors,
      type(corpus.fixture_commit) == "string"
        and corpus.fixture_commit:match("^[0-9a-f]+$") ~= nil,
      "fixture commit must be a hexadecimal object ID")
    validation_error(errors,
      integer(corpus.expected_sections) and corpus.expected_sections > 0,
      "expected section count must be positive")
    validation_error(errors, type(corpus.expected_paths) == "table",
      "expected_paths must be an array")
    if type(corpus.expected_paths) == "table"
        and integer(corpus.expected_sections) then
      validation_error(errors,
        #corpus.expected_paths == corpus.expected_sections,
        "expected_paths length must match expected_sections")
      local prior
      for index, path in ipairs(corpus.expected_paths) do
        validation_error(errors, type(path) == "string" and path ~= "",
          ("expected_paths[%d] must be a non-empty string"):format(index))
        if type(path) == "string" and prior then
          validation_error(errors, prior < path,
            "expected_paths must be strictly sorted and unique")
        end
        prior = type(path) == "string" and path or prior
      end
    end
  end

  local correctness = worker_result.correctness
  validation_error(errors, type(correctness) == "table",
    "passing worker requires correctness evidence")
  if type(correctness) == "table" then
    validation_error(errors, correctness.command_registered == true,
      "command registration evidence is false")
    validation_error(errors, correctness.close_removed_all_views == true,
      "close invariant evidence is false")
    validation_error(errors, correctness.canvas_name == "canvasdiff://canvas",
      "unexpected canvas name")
    validation_error(errors, correctness.canvas_buffers == 1,
      "worker must observe exactly one canvas buffer")
    validation_error(errors,
      integer(correctness.rendered_rows) and correctness.rendered_rows > 0
        and correctness.rendered_rows < 10000,
      "rendered row count is outside the bounded small profile")
    validation_error(errors,
      integer(correctness.rendered_headers)
        and type(corpus) == "table"
        and correctness.rendered_headers == corpus.expected_sections,
      "rendered headers do not match the corpus")
    validation_error(errors,
      integer(correctness.expected_sections)
        and type(corpus) == "table"
        and correctness.expected_sections == corpus.expected_sections,
      "correctness section count does not match the corpus")
    validation_error(errors, sha256(correctness.first_row_sha256),
      "first-row render hash must be SHA-256")
    validation_error(errors, sha256(correctness.last_row_sha256),
      "last-row render hash must be SHA-256")
    validation_error(errors, sha256(correctness.rendered_sha256),
      "full eager-render hash must be SHA-256")
    validation_error(errors,
      integer(correctness.extmarks_total) and correctness.extmarks_total > 0,
      "extmark total must be a positive integer")
    local namespaces = correctness.extmarks_by_namespace
    validation_error(errors, type(namespaces) == "table",
      "extmark namespace counts must be a table")
    if type(namespaces) == "table" then
      for name, count in pairs(namespaces) do
        validation_error(errors,
          type(name) == "string" and integer(count) and count >= 0,
          "every extmark namespace count must be a nonnegative integer")
      end
      local anchors = namespaces["canvasdiff.canvas.anchors"]
      validation_error(errors,
        integer(anchors) and type(corpus) == "table"
          and anchors == corpus.expected_sections + 1,
        "section/EOF anchor count does not match the corpus")
    end
  end

  local metrics = worker_result.metrics
  validation_error(errors, type(metrics) == "table",
    "passing worker requires metrics")
  if type(metrics) == "table" then
    for name, value in pairs(metrics) do
      validation_error(errors, finite_number(value),
        "metric " .. tostring(name) .. " must be finite numeric data")
    end
    for _, name in ipairs(required_metrics) do
      validation_error(errors, finite_number(metrics[name]),
        "required metric is missing or non-finite: " .. name)
    end
    for _, name in ipairs({
      "open_wall_ns", "close_wall_ns", "rss_before_bytes",
      "rss_after_open_bytes", "rss_after_open_gc_bytes",
      "rss_after_close_bytes", "rss_hwm_before_bytes",
      "rss_hwm_after_open_bytes", "lua_heap_before_bytes",
      "lua_heap_after_open_bytes", "lua_heap_retained_bytes",
      "lua_heap_after_close_bytes",
    }) do
      validation_error(errors,
        finite_number(metrics[name]) and metrics[name] >= 0,
        "absolute metric must be nonnegative: " .. name)
    end
  end

  return errors
end

local function append_consistency_errors(errors, runs)
  if #runs < 2 then
    return
  end
  local reference = runs[1]
  for index = 2, #runs do
    local candidate = runs[index]
    for _, field in ipairs({
      "environment", "corpus", "profile", "capabilities", "correctness",
    }) do
      validation_error(errors,
        vim.deep_equal(reference[field], candidate[field]),
        ("run %d %s differs from run 1"):format(index, field))
    end
  end
end

local nvim = vim.fn.exepath("nvim")
local git = vim.fn.exepath("git")
assert(nvim ~= "", "could not resolve the nvim executable")
assert(git ~= "", "could not resolve the git executable")

local run_root = absolute(vim.fs.joinpath(
  temporary_root,
  ("canvasdiff-eager-workers-%d-%d"):format(
    vim.fn.getpid(),
    uv.hrtime()
  )
))
assert(not uv.fs_lstat(run_root),
  "isolated worker directory unexpectedly exists: " .. run_root)
assert(not is_within(canonical_future(run_root), canonical_repo_root),
  "isolated worker directory resolves inside the repository")
mkdir(run_root)

local aggregate = {
  schema_version = 1,
  benchmark = EXPECTED_BENCHMARK,
  profile = EXPECTED_PROFILE,
  status = "fail",
  repetitions = repetitions,
  worker_timeout_ms = timeout_ms,
  output_realpath = canonical_output,
  runs = {},
}

local explicit_path = table.concat({
  vim.fs.dirname(nvim),
  vim.fs.dirname(git),
  "/usr/bin",
  "/bin",
}, ":")
local validation_errors = {}

local coordinated, coordination_error = xpcall(function()
  for index = 1, repetitions do
    local worker_root = vim.fs.joinpath(
      run_root, ("worker-%02d"):format(index))
    local xdg_config = vim.fs.joinpath(worker_root, "xdg-config")
    local xdg_data = vim.fs.joinpath(worker_root, "xdg-data")
    local xdg_state = vim.fs.joinpath(worker_root, "xdg-state")
    local xdg_cache = vim.fs.joinpath(worker_root, "xdg-cache")
    local xdg_runtime = vim.fs.joinpath(worker_root, "xdg-runtime")
    local temporary = vim.fs.joinpath(worker_root, "tmp")
    local fixture = vim.fs.joinpath(worker_root, "fixture")
    local worker_output = vim.fs.joinpath(worker_root, "result.json")
    local log_path = vim.fs.joinpath(worker_root, "nvim.log")
    mkdir(xdg_config)
    mkdir(xdg_data)
    mkdir(xdg_state)
    mkdir(xdg_cache)
    mkdir_private(xdg_runtime)
    mkdir_private(temporary)

    local command = {
      nvim,
      "--headless",
      "--clean",
      "-n",
      "-i",
      "NONE",
      "-l",
      worker,
      worker_output,
      fixture,
      tostring(index),
    }

    local started = uv.hrtime()
    local completed = vim.system(command, {
      cwd = repo_root,
      text = true,
      clear_env = true,
      env = {
        PATH = explicit_path,
        TMPDIR = temporary,
        XDG_CONFIG_HOME = xdg_config,
        XDG_DATA_HOME = xdg_data,
        XDG_STATE_HOME = xdg_state,
        XDG_CACHE_HOME = xdg_cache,
        XDG_RUNTIME_DIR = xdg_runtime,
        NVIM_APPNAME = "canvasdiff-eager-benchmark",
        NVIM_LOG_FILE = log_path,
        CANVASDIFF_BENCH_GIT = git,
        GIT_CONFIG_GLOBAL = "/dev/null",
        GIT_CONFIG_SYSTEM = "/dev/null",
        GIT_CONFIG_NOSYSTEM = "1",
        GIT_TERMINAL_PROMPT = "0",
        LC_ALL = "C",
        LANG = "C",
        TZ = "UTC",
        TERM = "dumb",
      },
    }):wait(timeout_ms)
    local process_wall_ns = uv.hrtime() - started

    local worker_result
    local worker_errors = {}
    local decoded, decoded_value = pcall(read_json, worker_output)
    if decoded and type(decoded_value) == "table" then
      -- Full validation happens before the first coordinator-owned field write.
      worker_errors = validate_worker(decoded_value, index)
      worker_result = decoded_value
    else
      local detail = decoded
          and ("decoded JSON has type " .. type(decoded_value))
        or tostring(decoded_value)
      worker_result = {
        schema_version = WORKER_SCHEMA,
        benchmark = EXPECTED_BENCHMARK,
        run_index = index,
        status = "fail",
        error = "worker did not publish a valid JSON object: " .. detail,
      }
      worker_errors[#worker_errors + 1] = worker_result.error
    end

    local signal = completed.signal
    local process_ok = completed.code == 0
      and (signal == nil or signal == 0)
    if not process_ok then
      worker_errors[#worker_errors + 1] = (
        "worker process failed: exit=%s signal=%s"
      ):format(tostring(completed.code), tostring(signal))
    end
    if worker_result.status ~= "pass" then
      worker_errors[#worker_errors + 1] =
        "worker status is " .. tostring(worker_result.status)
    end

    -- The decoded value is known to be a table before any of these writes.
    worker_result.worker_process = {
      wall_ns = process_wall_ns,
      exit_code = completed.code,
      signal = signal,
      stdout_tail = tail(completed.stdout, 4000),
      stderr_tail = tail(completed.stderr, 4000),
    }
    worker_result.metrics = type(worker_result.metrics) == "table"
        and worker_result.metrics or {}
    worker_result.metrics.worker_process_wall_ns = process_wall_ns
    if #worker_errors > 0 then
      worker_result.coordinator_validation_errors = worker_errors
      for _, message in ipairs(worker_errors) do
        validation_errors[#validation_errors + 1] =
          ("run %d: %s"):format(index, message)
      end
    end
    aggregate.runs[#aggregate.runs + 1] = worker_result
  end

  if #validation_errors == 0 then
    append_consistency_errors(validation_errors, aggregate.runs)
  end
  if #validation_errors > 0 then
    error(table.concat(validation_errors, "\n"), 0)
  end

  aggregate.environment = aggregate.runs[1].environment
  aggregate.corpus = aggregate.runs[1].corpus
  aggregate.capabilities = aggregate.runs[1].capabilities
  aggregate.aggregate = {}
  for _, name in ipairs(aggregate_metric_names) do
    local values = {}
    for index, run in ipairs(aggregate.runs) do
      local value = run.metrics[name]
      if not finite_number(value) then
        error(("run %d metric %s is missing or non-finite"):format(
          index, name), 0)
      end
      values[#values + 1] = value
    end
    aggregate.aggregate[name] = summary(values)
  end
  aggregate.status = "pass"
end, debug.traceback)

if not coordinated then
  aggregate.status = "fail"
  aggregate.error = "coordinator validation failed: "
    .. tostring(coordination_error)
  aggregate.validation_errors = validation_errors
  aggregate.diagnostics_root = run_root
end

local published, publish_error = pcall(atomic_json, output_path, aggregate)
if not published then
  io.stderr:write("CanvasDiff eager baseline could not publish diagnostics: ",
    tostring(publish_error), "\n")
  io.stderr:write("Worker diagnostics retained at: ", run_root, "\n")
  os.exit(1)
end

if aggregate.status == "pass" then
  local removed = vim.fn.delete(run_root, "rf")
  if removed ~= 0 then
    aggregate.cleanup_warning = "could not remove isolated worker directory: "
      .. run_root
    atomic_json(output_path, aggregate)
  end
  print("CanvasDiff eager baseline artifact: " .. output_path)
  os.exit(0)
else
  io.stderr:write(aggregate.error, "\n")
  io.stderr:write("Worker diagnostics retained at: ", run_root, "\n")
  io.stderr:write("CanvasDiff eager baseline artifact: ", output_path, "\n")
  os.exit(1)
end
