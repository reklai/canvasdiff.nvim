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

local SOURCE_NAMES = {
  root = true,
  sections = true,
  changed_files = true,
  stage = true,
  unstage = true,
}

local function finite_integer(value)
  return metrics.finite(value) and value == math.floor(value)
end

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

local function write_file(path, content)
  local file = assert(io.open(path, "wb"))
  assert(file:write(content))
  assert(file:close())
end

local function worker_command(output, fixture_root, rows, seed, run_index)
  return {
    assert(vim.fn.exepath("nvim") ~= "" and vim.fn.exepath("nvim")),
    "--headless", "--clean", "-n", "-i", "NONE",
    "-l", vim.fs.joinpath(
      H.project_root, "benchmark", "live_scale", "worker.lua"),
    output, fixture_root, tostring(rows), tostring(seed), tostring(run_index),
  }
end

local function launch_worker(spec)
  local coordinator_root = H.tmpdir()
  local fixture_root = vim.fs.joinpath(coordinator_root, "fixture")
  local output = vim.fs.joinpath(coordinator_root, "worker.json")
  local isolated_root = H.tmpdir()
  assert(vim.fn.mkdir(fixture_root, "p") == 1)
  if spec and spec.output then
    output = spec.output(coordinator_root, fixture_root)
  end
  local env = {
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
  }
  for name, value in pairs((spec and spec.env) or {}) do
    env[name] = value
  end
  local process = vim.system(worker_command(
    output, fixture_root, (spec and spec.rows) or 1,
    (spec and spec.seed) or 1729, (spec and spec.run_index) or 1
  ), {
    cwd = H.project_root,
    clear_env = true,
    env = env,
    text = true,
    timeout = (spec and spec.timeout) or 120000,
  }):wait()
  return {
    coordinator_root = coordinator_root,
    fixture_root = fixture_root,
    isolated_root = isolated_root,
    output = output,
    process = process,
  }
end

local function cleanup_launch(run)
  if vim.uv.fs_stat(run.coordinator_root) then
    remove_test_root(run.coordinator_root)
  end
  if vim.uv.fs_stat(run.isolated_root) then
    remove_test_root(run.isolated_root)
  end
end

local function validate_action_observation(action, check)
  local o = action.observations
  local exact = {
    open = "content_exact",
    search = "destination_exact",
    yank = "exact",
    fold = "reduced",
    unfold = "restored",
    cycle_all = "lens_exact",
    cycle_staged = "lens_exact",
    cycle_unstaged = "lens_exact",
    file_next = "destination_exact",
    file_prev = "destination_exact",
    hunk_next = "destination_exact",
    hunk_prev = "destination_exact",
    jump = "destination_exact",
    back = "destination_exact",
    branch_compare = "ref_exact",
    range_compare = "ref_exact",
    git_failure = "caught",
    close_orders = "order_exact",
    final_close = "closed_exact",
  }
  if action.name == "sequential_scroll" or action.name == "random_jump" then
    check(o.destination_exact == true,
      action.name .. " destination evidence is required")
    check(type(o.projection) == "table" and o.projection.sampled == true
        and o.projection.exact == true
        and type(o.projection.expected) == "string"
        and o.projection.actual == o.projection.expected,
      action.name .. " projected UI evidence is required")
  elseif action.name == "manual_refresh" or action.name == "watch_refresh" then
    check(type(o.convergence) == "table"
        and o.convergence.mutated == true
        and o.convergence.disk_exact == true
        and o.convergence.model_exact == true
        and o.convergence.ui_exact == true
        and type(o.convergence.expected_bytes) == "string"
        and type(o.convergence.expected_digest) == "string",
      action.name .. " convergence evidence is required")
  elseif action.name == "stage" or action.name == "unstage" then
    check(o.bytes_exact == true and o.primary_absent == true
        and o.paths_exact == true
        and type(o.before_paths) == "table"
        and type(o.after_paths) == "table"
        and type(o.before_name_status) == "table"
        and type(o.after_name_status) == "table",
      action.name .. " scoped index evidence is required")
    for _, records in ipairs({
      o.before_name_status or {}, o.after_name_status or {},
    }) do
      for _, record in ipairs(records) do
        check(type(record) == "table"
            and type(record.status) == "string" and record.status ~= ""
            and type(record.path) == "string" and record.path ~= "",
          action.name .. " name-status records must be exact")
      end
    end
  elseif action.name == "close_reopen" then
    check(type(o.equivalence) == "table"
        and o.equivalence.disk_exact == true
        and o.equivalence.model_exact == true
        and o.equivalence.ui_exact == true
        and o.equivalence.paging_exact == true,
      "close_reopen bounded equivalence evidence is required")
  elseif exact[action.name] then
    check(o[exact[action.name]] == true,
      action.name .. " exact observation is required")
  end
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

  local plan = actions.plan(expected.rows, expected.seed)
  check(type(payload.trace) == "table" and #payload.trace == #plan,
    "trace must exactly match planned length")
  for index, planned in ipairs(plan) do
    local action = (payload.trace or {})[index]
    check(type(action) == "table", "missing planned action " .. index)
    if type(action) == "table" then
      check(action.index == index, "action indices must be contiguous")
      check(action.name == planned.name, "action name/order mismatch")
      check(vim.deep_equal(action.arguments, planned.arguments),
        "action arguments mismatch")
      check(metrics.finite(action.operation_ns) and action.operation_ns >= 0,
        "operation duration must be finite")
      if action.name == "open" then
        check(metrics.finite(action.first_view_ns)
            and action.first_view_ns >= 0
            and metrics.finite(action.operation_ns)
            and action.first_view_ns < action.operation_ns
            and action.operation_count >= 2,
          "open first-view duration must be finite")
      else
        check(action.first_view_ns == nil or action.first_view_ns == vim.NIL,
          "only open may publish first-view duration")
      end
      check(action.elapsed_ns == action.operation_ns,
        "elapsed duration must contain operation time only")
      check(metrics.finite(action.oracle_ns) and action.oracle_ns >= 0,
        "oracle duration must be finite")
      check(metrics.finite(action.wall_ns)
          and action.wall_ns >= action.operation_ns,
        "wall duration must be finite")
      check(finite_integer(action.operation_count)
          and action.operation_count >= 1,
        "operation count must be a positive integer")
      check(action.status == "ok", "action must finish successfully")
      check(type(action.observations) == "table",
        "action observations are required")
      if type(action.observations) == "table" then
        validate_action_observation(action, check)
      end
    end
  end

  local correctness = payload.correctness
  check(type(correctness) == "table", "correctness observations are required")
  if type(correctness) == "table" then
    check(type(correctness.content) == "table"
        and correctness.content.disk_exact == true
        and correctness.content.model_exact == true
        and correctness.content.ui_exact == true,
      "content identities were not preserved")
    check(type(correctness.projection) == "table"
        and correctness.projection.preserved == true
        and finite_integer(correctness.projection.samples)
        and correctness.projection.samples > 0,
      "projected UI identities were not preserved")
    check(type(correctness.lenses) == "table"
        and correctness.lenses.preserved == true,
      "lens identities were not preserved")
    check(type(correctness.index) == "table"
        and correctness.index.stage_exact == true
        and correctness.index.unstage_exact == true
        and correctness.index.primary_absent == true
        and correctness.index.paths_exact == true,
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

  local source_seen = {}
  check(type(payload.adapters) == "table"
      and type(payload.adapters.git) == "table"
      and #payload.adapters.git > 0,
    "Git timing adapter observations are required")
  check(type(payload.adapters) == "table"
      and type(payload.adapters.source) == "table"
      and #payload.adapters.source > 0,
    "source timing adapter observations are required")
  for _, sample in ipairs((payload.adapters or {}).git or {}) do
    check(type(sample.argv) == "table" and #sample.argv > 0,
      "Git argv is required")
    for _, argument in ipairs(sample.argv or {}) do
      check(type(argument) == "string", "Git argv must contain strings")
    end
    check(type(sample.category) == "string" and sample.category ~= "",
      "Git argv category is required")
    check(sample.status == "ok", "Git adapter status must be ok")
    check(metrics.finite(sample.elapsed_ns) and sample.elapsed_ns >= 0,
      "Git adapter duration must be finite")
  end
  for _, sample in ipairs((payload.adapters or {}).source or {}) do
    check(SOURCE_NAMES[sample.name] == true, "unexpected source adapter name")
    source_seen[sample.name] = true
    check(sample.status == "ok", "source adapter status must be ok")
    check(metrics.finite(sample.elapsed_ns) and sample.elapsed_ns >= 0,
      "source adapter duration must be finite")
  end
  for name in pairs(SOURCE_NAMES) do
    check(source_seen[name], "missing source adapter " .. name)
  end

  local heartbeat = payload.heartbeat
  check(type(heartbeat) == "table"
      and heartbeat.scope == "plugin_operations"
      and heartbeat.started_after_fixture == true
      and finite_integer(heartbeat.ticks) and heartbeat.ticks >= 1
      and metrics.finite(heartbeat.max_gap_ns)
      and heartbeat.max_gap_ns > 0,
    "heartbeat must tick during plugin operations")

  check(type(payload.capabilities) == "table"
      and type(payload.capabilities.rss_source) == "string"
      and type(payload.capabilities.hwm_source) == "string",
    "memory capabilities are required")
  check(type(payload.memory) == "table"
      and type(payload.memory.samples) == "table"
      and #payload.memory.samples >= 4,
    "memory samples are required")
  for _, sample in ipairs((payload.memory or {}).samples or {}) do
    check(metrics.finite(sample.heap_bytes) and sample.heap_bytes >= 0,
      "heap sample must be finite")
    if payload.capabilities.rss_source ~= "unavailable" then
      check(metrics.finite(sample.rss_bytes) and sample.rss_bytes > 0,
        "RSS sample must be finite when available")
    end
    if payload.capabilities.hwm_source ~= "unavailable" then
      check(metrics.finite(sample.hwm_bytes) and sample.hwm_bytes > 0,
        "HWM sample must be finite when available")
    end
  end

  local paging = payload.paging
  check(type(paging) == "table"
      and (paging.mode == "eager" or paging.mode == "paged")
      and finite_integer(paging.logical_rows) and paging.logical_rows > 0
      and type(paging.cache) == "table"
      and type(paging.cache.available) == "boolean",
    "finite paging/cache observations are required")
  if type(paging) == "table" and paging.mode == "eager" then
    check(finite_integer(paging.buffer_rows) and paging.buffer_rows > 0,
      "eager buffer rows must be finite")
  elseif type(paging) == "table" and paging.mode == "paged" then
    check(paging.cache.available == true
        and finite_integer(paging.cache.row_count)
        and finite_integer(paging.cache.page_count)
        and type(paging.projection) == "table"
        and finite_integer(paging.projection.logical_rows),
      "paged cache/projection values must be finite")
    local resident = type(paging.cache) == "table"
        and paging.cache.resident or nil
    check(type(resident) == "table"
        and finite_integer(resident.pages) and resident.pages >= 0
        and finite_integer(resident.bytes) and resident.bytes >= 0
        and finite_integer(resident.max_pages) and resident.max_pages >= 0
        and finite_integer(resident.max_bytes) and resident.max_bytes >= 0
        and finite_integer(resident.samples) and resident.samples >= 2
        and finite_integer(resident.navigation_samples)
        and resident.navigation_samples >= 1
        and resident.scope == "live_after_first_view_and_actions"
        and resident.first_sample == "open_first_view"
        and type(resident.last_sample) == "string"
        and resident.pages <= resident.max_pages
        and resident.bytes <= resident.max_bytes,
      "paged resident evidence must be finite and bounded")
    for _, values in ipairs({
      paging.cache or {}, paging.projection or {}, paging.scheduler or {},
    }) do
      for key, value in pairs(values) do
        if type(value) == "number" then
          check(metrics.finite(value) and value >= 0,
            "paged numeric value must be finite: " .. tostring(key))
        end
      end
    end
  end

  check(type(payload.extmarks) == "table"
      and finite_integer(payload.extmarks.during)
      and payload.extmarks.during >= 0
      and finite_integer(payload.extmarks.after)
      and payload.extmarks.after >= 0,
    "extmark observations must be finite integers")

  local cleanup = payload.cleanup
  check(type(cleanup) == "table", "cleanup observations are required")
  if type(cleanup) == "table" then
    check(cleanup.fixture_cleanup_attempted == true,
      "same-instance fixture cleanup was not attempted")
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

  return #errors == 0 and true or nil, errors
end

T["live_scale_worker_replays one real row and rejects corrupted evidence"] = function()
  local run = launch_worker()
  local ok, failure = xpcall(function()
    assert(run.process.code == 0 and (run.process.signal or 0) == 0, (
      "worker failed: code=%s signal=%s\nstdout:\n%s\nstderr:\n%s"
    ):format(run.process.code, run.process.signal,
      run.process.stdout or "", run.process.stderr or ""))
    local payload = read_json(run.output)
    local expected = { rows = 1, seed = 1729, run_index = 1 }
    local valid, errors = validate_worker(payload, expected)
    assert(valid, table.concat(errors, "\n"))
    H.eq(vim.uv.fs_stat(run.fixture_root), nil,
      "worker cleanup must remove its exact fixture root")

    local cases = {
      {
        name = "trace deletion",
        mutate = function(value) table.remove(value.trace) end,
        message = "trace must exactly match planned length",
      },
      {
        name = "trace order",
        mutate = function(value) value.trace[1].name = "wrong" end,
        message = "action name/order mismatch",
      },
      {
        name = "trace arguments",
        mutate = function(value) value.trace[1].arguments.rows = 2 end,
        message = "action arguments mismatch",
      },
      {
        name = "action evidence",
        mutate = function(value)
          value.trace[2].observations.projection.exact = false
        end,
        message = "sequential_scroll projected UI evidence is required",
      },
      {
        name = "source status",
        mutate = function(value) value.adapters.source[1].status = "error" end,
        message = "source adapter status must be ok",
      },
      {
        name = "Git argv",
        mutate = function(value) value.adapters.git[1].argv = {} end,
        message = "Git argv is required",
      },
      {
        name = "memory",
        mutate = function(value) value.memory.samples[1].heap_bytes = 0 / 0 end,
        message = "heap sample must be finite",
      },
      {
        name = "paging",
        mutate = function(value) value.paging.logical_rows = -1 end,
        message = "finite paging/cache observations are required",
      },
      {
        name = "heartbeat ticks",
        mutate = function(value) value.heartbeat.ticks = 0 end,
        message = "heartbeat must tick during plugin operations",
      },
      {
        name = "heartbeat gap",
        mutate = function(value) value.heartbeat.max_gap_ns = 0 end,
        message = "heartbeat must tick during plugin operations",
      },
      {
        name = "extmarks",
        mutate = function(value) value.extmarks.during = 0.5 end,
        message = "extmark observations must be finite integers",
      },
      {
        name = "correctness",
        mutate = function(value) value.correctness.index.paths_exact = false end,
        message = "index identities were not preserved",
      },
    }
    for _, case in ipairs(cases) do
      local corrupted = vim.deepcopy(payload)
      case.mutate(corrupted)
      local accepted, mutation_errors = validate_worker(corrupted, expected)
      H.eq(accepted, nil, case.name .. " must be rejected")
      assert(vim.tbl_contains(mutation_errors, case.message),
        case.name .. ": " .. vim.inspect(mutation_errors))
    end
  end, debug.traceback)
  cleanup_launch(run)
  assert(ok, failure)
end

T["live_scale_worker_publishes bounded paged resident evidence at 100k"] = function()
  local run = launch_worker({ rows = 100000, timeout = 900000 })
  local ok, failure = xpcall(function()
    assert(run.process.code == 0 and (run.process.signal or 0) == 0, (
      "worker failed: code=%s signal=%s\nstdout:\n%s\nstderr:\n%s"
    ):format(run.process.code, run.process.signal,
      run.process.stdout or "", run.process.stderr or ""))
    local payload = read_json(run.output)
    local valid, errors = validate_worker(payload, {
      rows = 100000, seed = 1729, run_index = 1,
    })
    assert(valid, table.concat(errors, "\n"))
    H.eq(payload.paging.mode, "paged")
    local resident = payload.paging.cache.resident
    assert(resident.samples >= 2)
    assert(resident.navigation_samples >= 1)
    H.eq(resident.first_sample, "open_first_view")
    assert(resident.pages <= resident.max_pages)
    assert(resident.bytes <= resident.max_bytes)
  end, debug.traceback)
  cleanup_launch(run)
  assert(ok, failure)
end

T["live_scale_worker_cleans a fixture after injected post-build failure"] = function()
  local run = launch_worker({
    env = { CANVASDIFF_LIVE_SCALE_FAIL_FIXTURE_AFTER_BUILD = "1" },
  })
  local ok, failure = xpcall(function()
    assert(run.process.code ~= 0, "injected fixture failure must fail the worker")
    local payload = read_json(run.output)
    H.eq(payload.status, "fail")
    H.eq(payload.cleanup.fixture_cleanup_attempted, true)
    H.eq(payload.cleanup.fixture_removed, true)
    H.eq(vim.uv.fs_stat(run.fixture_root), nil)
  end, debug.traceback)
  cleanup_launch(run)
  assert(ok, failure)
end

T["live_scale_worker_tracks a timer allocated by a deferred callback"] = function()
  local run = launch_worker({
    env = { CANVASDIFF_LIVE_SCALE_DEFER_TIMER = "1" },
  })
  local ok, failure = xpcall(function()
    assert(run.process.code ~= 0, "deferred timer leak must fail the worker")
    local payload = read_json(run.output)
    H.eq(payload.status, "fail")
    assert(payload.cleanup.open_timers >= 1,
      "deferred timer allocation escaped tracking")
    H.eq(payload.cleanup.wrappers_restored, true)
    H.eq(payload.cleanup.fixture_removed, true)
  end, debug.traceback)
  cleanup_launch(run)
  assert(ok, failure)
end

T["live_scale_worker_rejects unsafe output paths without mutation"] = function()
  local sentinel = "do not overwrite\n"
  local existing = launch_worker({
    output = function(root)
      local path = vim.fs.joinpath(root, "sentinel.json")
      write_file(path, sentinel)
      return path
    end,
  })
  local equal = launch_worker({
    output = function(_, fixture_root) return fixture_root end,
  })
  local ok, failure = xpcall(function()
    assert(existing.process.code ~= 0, "existing output must be rejected")
    local file = assert(io.open(existing.output, "rb"))
    H.eq(file:read("*a"), sentinel)
    assert(file:close())
    assert(vim.uv.fs_stat(existing.fixture_root),
      "preflight rejection must not claim the fixture")
    H.eq(vim.fn.empty(vim.fn.readdir(existing.fixture_root)), 1)

    assert(equal.process.code ~= 0, "OUTPUT == FIXTURE_ROOT must be rejected")
    assert(vim.uv.fs_stat(equal.fixture_root),
      "equal output rejection must not claim the fixture")
    H.eq(vim.fn.empty(vim.fn.readdir(equal.fixture_root)), 1)
  end, debug.traceback)
  cleanup_launch(existing)
  cleanup_launch(equal)
  assert(ok, failure)
end

return T
