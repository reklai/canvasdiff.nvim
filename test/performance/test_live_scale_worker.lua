local H = require("helpers")
local actions = require("benchmark.live_scale.actions")
local metrics = require("benchmark.live_scale.metrics")

local T = {}

local PHASES = {
  fixture_build = true,
  adapter_install = true,
  app_load = true,
  replay = true,
  cleanup = true,
}

local RESOURCE_GROUPS = {
  "canvasdiff.watch",
  "canvasdiff.virt",
  "canvasdiff.highlight",
  "canvasdiff.status_column",
  "canvasdiff.sidebar",
  "canvasdiff.scrollbar",
  "canvasdiff.session",
  "canvasdiff.close",
  "canvasdiff.winbar",
}

local function remove_test_root(root)
  local prefix = vim.fs.joinpath(vim.uv.os_tmpdir(), "canvasdiff_test_")
  assert(root:sub(1, #prefix) == prefix,
    "refusing to remove a path outside the test-owned prefix: " .. root)
  assert(vim.fn.delete(root, "rf") == 0, "could not remove test root: " .. root)
end

local function read_json(path)
  local file = assert(io.open(path, "rb"))
  local content = assert(file:read("*a"))
  assert(file:close())
  return vim.json.decode(content)
end

local function validate_worker(payload, expected)
  local errors = {}
  local function check(condition, message)
    if not condition then
      errors[#errors + 1] = message
    end
  end

  check(type(payload) == "table", "payload must be an object")
  if type(payload) ~= "table" then
    return nil, errors
  end
  check(payload.schema == "canvasdiff.live_scale.worker/v1",
    "unexpected worker schema")
  check(payload.status == "ok", "worker status must be ok")
  check(payload.error == vim.NIL or payload.error == nil,
    "successful worker must not publish an error")
  check(payload.run_index == expected.run_index, "run index mismatch")
  check(payload.rows == expected.rows, "row count mismatch")
  check(payload.seed == expected.seed, "seed mismatch")

  local manifest = payload.manifest
  check(type(manifest) == "table", "manifest observation is required")
  if type(manifest) == "table" then
    check(manifest.schema == "canvasdiff.live_scale.fixture/v1",
      "fixture schema mismatch")
    check(manifest.rows == expected.rows, "fixture rows mismatch")
    check(manifest.seed == expected.seed, "fixture seed mismatch")
    check(manifest.primary_path == "primary.txt", "primary path mismatch")
    check(type(manifest.digest) == "string"
        and manifest.digest:match("^[0-9a-f]+$") and #manifest.digest == 64,
      "fixture digest must be sha256")
  end

  local found_phases = {}
  check(type(payload.phases) == "table", "phase samples are required")
  for _, phase in ipairs(payload.phases or {}) do
    check(type(phase) == "table", "phase sample must be an object")
    if type(phase) == "table" then
      check(PHASES[phase.name], "unexpected phase " .. tostring(phase.name))
      check(metrics.finite(phase.elapsed_ns) and phase.elapsed_ns >= 0,
        "phase duration must be finite")
      check(phase.status == "ok", "phase must finish successfully")
      found_phases[phase.name] = true
    end
  end
  for name in pairs(PHASES) do
    check(found_phases[name], "missing phase " .. name)
  end

  local found_actions = {}
  check(type(payload.trace) == "table" and #payload.trace > 0,
    "action trace is required")
  for index, action in ipairs(payload.trace or {}) do
    check(action.index == index, "action indices must be contiguous")
    check(type(action.name) == "string", "action name is required")
    check(type(action.arguments) == "table", "action arguments are required")
    check(metrics.finite(action.elapsed_ns) and action.elapsed_ns >= 0,
      "action duration must be finite")
    check(action.status == "ok", "action must finish successfully")
    check(type(action.observations) == "table",
      "action observations are required")
    found_actions[action.name] = true
  end
  for _, name in ipairs(actions.required_names()) do
    check(found_actions[name], "missing required action " .. name)
  end

  local correctness = payload.correctness
  check(type(correctness) == "table", "correctness observations are required")
  if type(correctness) == "table" then
    check(type(correctness.content) == "table",
      "content identity observation is required")
    check(correctness.content and correctness.content.disk_exact == true,
      "disk content identity was not preserved")
    check(correctness.content and correctness.content.model_exact == true,
      "model content identity was not preserved")
    check(correctness.content and correctness.content.ui_exact == true,
      "UI content identity was not preserved")

    check(type(correctness.lenses) == "table"
        and correctness.lenses.preserved == true,
      "lens identities were not preserved")
    check(type(correctness.index) == "table"
        and correctness.index.stage_exact == true
        and correctness.index.unstage_exact == true,
      "index identities were not preserved")
    check(type(correctness.refs) == "table"
        and correctness.refs.branch_exact == true
        and correctness.refs.range_exact == true,
      "comparison ref identities were not preserved")
    check(type(correctness.git_failure) == "table"
        and correctness.git_failure.caught == true
        and type(correctness.git_failure.error) == "string",
      "injected Git failure was not contained")
  end

  check(type(payload.adapters) == "table"
      and type(payload.adapters.git) == "table"
      and #payload.adapters.git > 0,
    "Git timing adapter observations are required")
  check(type(payload.adapters) == "table"
      and type(payload.adapters.source) == "table"
      and #payload.adapters.source > 0,
    "source timing adapter observations are required")
  for _, sample in ipairs((payload.adapters or {}).git or {}) do
    check(type(sample.category) == "string" and sample.category ~= "",
      "Git argv category is required")
    check(metrics.finite(sample.elapsed_ns) and sample.elapsed_ns >= 0,
      "Git adapter duration must be finite")
  end
  for _, sample in ipairs((payload.adapters or {}).source or {}) do
    check(type(sample.name) == "string" and sample.name ~= "",
      "source adapter name is required")
    check(metrics.finite(sample.elapsed_ns) and sample.elapsed_ns >= 0,
      "source adapter duration must be finite")
  end

  check(type(payload.heartbeat) == "table"
      and metrics.finite(payload.heartbeat.max_gap_ns)
      and payload.heartbeat.max_gap_ns >= 0
      and type(payload.heartbeat.ticks) == "number",
    "heartbeat observation is required")
  check(type(payload.memory) == "table"
      and type(payload.memory.samples) == "table"
      and #payload.memory.samples >= 4,
    "memory samples are required")
  check(type(payload.capabilities) == "table"
      and type(payload.capabilities.rss_source) == "string"
      and type(payload.capabilities.hwm_source) == "string",
    "memory capabilities are required")
  check(type(payload.paging) == "table"
      and type(payload.paging.mode) == "string"
      and type(payload.paging.cache) == "table",
    "paging/cache observations are required")
  check(type(payload.extmarks) == "table"
      and type(payload.extmarks.during) == "number"
      and type(payload.extmarks.after) == "number",
    "extmark observations are required")

  local cleanup = payload.cleanup
  check(type(cleanup) == "table", "cleanup observations are required")
  if type(cleanup) == "table" then
    check(cleanup.fixture_removed == true, "fixture root survived cleanup")
    check(cleanup.canvas_windows == 0, "CanvasDiff windows survived cleanup")
    check(cleanup.open_timers == 0, "timers survived cleanup")
    check(cleanup.wrappers_restored == true, "timing wrappers were not restored")
    check(type(cleanup.owned_groups) == "table"
        and #cleanup.owned_groups == 0,
      "CanvasDiff autocmd groups survived cleanup")
    check(type(cleanup.checked_group_prefixes) == "table"
        and vim.deep_equal(cleanup.checked_group_prefixes, RESOURCE_GROUPS),
      "cleanup did not check the complete ownership group set")
  end

  if #errors > 0 then
    return nil, errors
  end
  return true, errors
end

T["live_scale_worker_replays one real row and publishes complete evidence"] = function()
  local fixture_root = H.tmpdir()
  local output_root = H.tmpdir()
  local isolated_root = H.tmpdir()
  local output = vim.fs.joinpath(output_root, "worker.json")
  local worker = vim.fs.joinpath(
    H.project_root, "benchmark", "live_scale", "worker.lua")
  local command = {
    assert(vim.fn.exepath("nvim") ~= "" and vim.fn.exepath("nvim")),
    "--headless", "--clean", "-n", "-i", "NONE",
    "-l", worker, output, fixture_root, "1", "1729", "1",
  }

  local ok, failure = xpcall(function()
    local process = vim.system(command, {
      cwd = H.project_root,
      clear_env = true,
      env = {
        HOME = isolated_root,
        LANG = "C",
        LC_ALL = "C",
        NVIM_LOG_FILE = vim.fs.joinpath(isolated_root, "nvim.log"),
        PATH = vim.env.PATH,
        XDG_CACHE_HOME = vim.fs.joinpath(isolated_root, "cache"),
        XDG_CONFIG_HOME = vim.fs.joinpath(isolated_root, "config"),
        XDG_DATA_HOME = vim.fs.joinpath(isolated_root, "data"),
        XDG_RUNTIME_DIR = vim.fs.joinpath(isolated_root, "runtime"),
        XDG_STATE_HOME = vim.fs.joinpath(isolated_root, "state"),
      },
      text = true,
      timeout = 120000,
    }):wait()
    assert(process.code == 0 and (process.signal or 0) == 0, (
      "worker failed: code=%s signal=%s\nstdout:\n%s\nstderr:\n%s"
    ):format(
      tostring(process.code),
      tostring(process.signal),
      process.stdout or "",
      process.stderr or ""
    ))

    local payload = read_json(output)
    local valid, errors = validate_worker(payload, {
      rows = 1,
      seed = 1729,
      run_index = 1,
    })
    assert(valid, table.concat(errors, "\n"))
    H.eq(vim.uv.fs_stat(fixture_root), nil,
      "worker cleanup must remove its exact fixture root")

    local missing = vim.deepcopy(payload)
    missing.correctness.index = nil
    local malformed, malformed_errors = validate_worker(missing, {
      rows = 1,
      seed = 1729,
      run_index = 1,
    })
    H.eq(malformed, nil)
    assert(vim.tbl_contains(malformed_errors,
      "index identities were not preserved"),
      vim.inspect(malformed_errors))
  end, debug.traceback)

  if vim.uv.fs_stat(fixture_root) then
    remove_test_root(fixture_root)
  end
  remove_test_root(output_root)
  remove_test_root(isolated_root)
  assert(ok, failure)
end

return T
