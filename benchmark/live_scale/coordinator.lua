-- Coordinator library for the live Git scale campaign.
--
-- Worker JSON is an untrusted process boundary. This module decodes and
-- validates it before applying coordinator-owned gates or summaries.

local uv = vim.uv
local actions = require("benchmark.live_scale.actions")
local metrics = require("benchmark.live_scale.metrics")

local M = {}

local SCHEMA = "canvasdiff.live_scale/v1"
local WORKER_SCHEMA = "canvasdiff.live_scale.worker/v1"
local FIXTURE_SCHEMA = "canvasdiff.live_scale.fixture/v1"
local PROFILE = "live-git-v1"
local SEED = 1729
local AUTHORITATIVE_SIZES = { 1, 1000, 10000, 100000, 1000000 }
local WORKER_TIMEOUT_MS = 15 * 60 * 1000
local LOG_TAIL_BYTES = 4000
local PAGING_RESIDENT_MAX_PAGES = 8
local PAGING_RESIDENT_MAX_BYTES = 532512
-- A 100ms gap is our responsiveness target. The live Git replay deliberately
-- includes synchronous million-row operations, so its correctness gate is a
-- bounded-completion ceiling rather than a false claim that every operation
-- can admit a callback inside the target.
local HEARTBEAT_TARGET_GAP_NS = 100 * 1000 * 1000
local HEARTBEAT_MAX_GAP_NS = 2 * 1000 * 1000 * 1000
local WATCH_CONVERGENCE_BASE_MS = 1500
local WATCH_CONVERGENCE_PER_100K_MS = 250
local WATCH_CONVERGENCE_MAX_MS = 5000
local PHASES = {
  fixture_build = true,
  adapter_install = true,
  app_load = true,
  replay = true,
  cleanup = true,
}
local SOURCE_NAMES = {
  root = true,
  sections = true,
  changed_files = true,
  stage = true,
  unstage = true,
}
local MEMORY_NAMES = {
  "worker_start",
  "after_fixture",
  "after_app_load",
  "after_replay",
  "after_cleanup",
}
local MEMORY_NAME_SET = {}
for _, name in ipairs(MEMORY_NAMES) do
  MEMORY_NAME_SET[name] = true
end
local RESOURCE_GROUPS = {
  "canvasdiff.watch",
  "canvasdiff.virt",
  "canvasdiff.syntax",
  "canvasdiff.status_column",
  "canvasdiff.sidebar",
  "canvasdiff.scrollbar",
  "canvasdiff.session",
  "canvasdiff.close",
  "canvasdiff.winbar",
}

local function absolute(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local resolved = vim.fn.fnamemodify(path, ":p")
  if resolved ~= "/" then
    resolved = resolved:gsub("/+$", "")
  end
  return resolved
end

local script = assert(absolute(debug.getinfo(1, "S").source:sub(2)))
local lane_root = vim.fs.dirname(script)
local repo_root = vim.fs.dirname(vim.fs.dirname(lane_root))
local canonical_repo_root = assert(uv.fs_realpath(repo_root))
local worker_path = vim.fs.joinpath(lane_root, "worker.lua")

local function integer(value)
  return metrics.finite(value) and value == math.floor(value)
end

local function watch_convergence_timeout_ms(rows)
  return math.min(WATCH_CONVERGENCE_MAX_MS,
    WATCH_CONVERGENCE_BASE_MS
      + math.floor(rows / 100000) * WATCH_CONVERGENCE_PER_100K_MS)
end

local function sha256(value)
  return type(value) == "string"
    and #value == 64
    and value:match("^[0-9a-f]+$") ~= nil
end

local function within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function canonical_future(path)
  local cursor = assert(absolute(path))
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
  return assert(absolute(resolved))
end

local function canonical_destination(path)
  path = assert(absolute(path))
  assert(path ~= "/", "live-scale artifact must name a file")
  return assert(absolute(vim.fs.joinpath(
    canonical_future(vim.fs.dirname(path)),
    vim.fs.basename(path)
  )))
end

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

local function read_all(path)
  local file, open_error = io.open(path, "rb")
  if not file then
    return nil, tostring(open_error)
  end
  local content = file:read("*a")
  local closed, close_error = file:close()
  if content == nil then
    return nil, "could not read " .. path
  end
  if not closed then
    return nil, tostring(close_error)
  end
  return content
end

local function command(cwd, argv)
  local completed = vim.system(argv, {
    cwd = cwd,
    text = true,
    timeout = 30000,
  }):wait()
  local signal = completed.signal
  assert(completed.code == 0 and (signal == nil or signal == 0),
    ("%s failed: exit=%s signal=%s %s"):format(
      table.concat(argv, " "),
      tostring(completed.code),
      tostring(signal),
      completed.stderr or ""
    ))
  return (completed.stdout or ""):gsub("%s+$", "")
end

local function source_tree_snapshot(git)
  local completed = vim.system({
    git,
    "ls-files",
    "-z",
    "--cached",
    "--others",
    "--exclude-standard",
  }, {
    cwd = repo_root,
    text = false,
    timeout = 30000,
  }):wait()
  local signal = completed.signal
  assert(completed.code == 0 and (signal == nil or signal == 0),
    "could not enumerate live-scale source tree")

  local paths = {}
  for relative in (completed.stdout or ""):gmatch("([^%z]+)") do
    paths[#paths + 1] = relative
  end
  table.sort(paths)

  local records = {}
  for _, relative in ipairs(paths) do
    local path = vim.fs.joinpath(repo_root, relative)
    local stat = uv.fs_lstat(path)
    if not stat then
      records[#records + 1] = "missing\0" .. relative
    elseif stat.type == "file" then
      local content = assert(read_all(path),
        "could not read source-tree file: " .. relative)
      records[#records + 1] =
        ("file\0%s\0%s"):format(relative, vim.fn.sha256(content))
    elseif stat.type == "link" then
      local target = assert(uv.fs_readlink(path),
        "could not read source-tree link: " .. relative)
      records[#records + 1] =
        ("link\0%s\0%s"):format(relative, vim.fn.sha256(target))
    else
      records[#records + 1] = stat.type .. "\0" .. relative
    end
  end
  return {
    digest = vim.fn.sha256(table.concat(records, "\n")),
    entries = #records,
  }
end

local function environment()
  local git = vim.fn.exepath("git")
  assert(git ~= "", "Git executable is unavailable")
  local uname = uv.os_uname()
  local cpu
  local cpuinfo = read_all("/proc/cpuinfo")
  if cpuinfo then
    cpu = cpuinfo:match("\nmodel name%s*:%s*([^\n]+)")
      or cpuinfo:match("^model name%s*:%s*([^\n]+)")
  end
  local version = vim.version()
  local lua_version = _G.jit and jit.version or _VERSION
  local lua_os = _G.jit and jit.os or uname.sysname
  local lua_arch = _G.jit and jit.arch or uname.machine
  local source_tree = source_tree_snapshot(git)
  local fingerprint = vim.fn.sha256(table.concat({
    uname.sysname or "",
    uname.release or "",
    uname.machine or "",
    cpu or "",
    ("%d.%d.%d"):format(version.major, version.minor, version.patch),
    lua_version or "",
    command(repo_root, { git, "--version" }),
  }, "\0"))
  return {
    git_revision = command(repo_root, { git, "rev-parse", "HEAD" }),
    git_dirty = command(repo_root, {
      git, "status", "--porcelain", "--untracked-files=normal",
    }) ~= "",
    nvim = ("%d.%d.%d"):format(version.major, version.minor, version.patch),
    lua = lua_version,
    lua_os = lua_os,
    lua_arch = lua_arch,
    os = uname.sysname,
    os_release = uname.release,
    machine = uname.machine,
    cpu = cpu,
    git = command(repo_root, { git, "--version" }),
    host_fingerprint = fingerprint,
    source_tree_digest = source_tree.digest,
    source_tree_entries = source_tree.entries,
  }
end

local function tail(text)
  text = type(text) == "string" and text or ""
  if #text <= LOG_TAIL_BYTES then
    return text
  end
  return text:sub(#text - LOG_TAIL_BYTES + 1)
end

local function check_all_numbers(value, errors, seen, path)
  if type(value) == "number" then
    if not metrics.finite(value) then
      errors[#errors + 1] = "non-finite numeric claim at " .. path
    end
    return
  end
  if type(value) ~= "table" or seen[value] then
    return
  end
  seen[value] = true
  for key, child in pairs(value) do
    check_all_numbers(child, errors, seen,
      path .. "." .. tostring(key))
  end
end

local function validate_action_observation(action, check)
  local observation = action.observations
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
    check(observation.destination_exact == true,
      action.name .. " destination evidence is required")
    check(type(observation.projection) == "table"
        and observation.projection.sampled == true
        and observation.projection.exact == true
        and type(observation.projection.expected) == "string"
        and observation.projection.actual == observation.projection.expected,
      action.name .. " projected UI evidence is required")
  elseif action.name == "manual_refresh" or action.name == "watch_refresh" then
    local convergence = observation.convergence
    check(type(convergence) == "table"
        and convergence.mutated == true
        and convergence.disk_exact == true
        and convergence.model_exact == true
        and convergence.ui_exact == true
        and type(convergence.expected_bytes) == "string"
        and type(convergence.expected_digest) == "string",
      action.name .. " convergence evidence is required")
  elseif action.name == "stage" or action.name == "unstage" then
    check(observation.bytes_exact == true
        and observation.primary_absent == true
        and observation.paths_exact == true
        and type(observation.before_paths) == "table"
        and type(observation.after_paths) == "table"
        and type(observation.before_name_status) == "table"
        and type(observation.after_name_status) == "table",
      action.name .. " scoped index evidence is required")
    if action.name == "stage" then
      check(type(observation.tree_before) == "string"
          and observation.tree_before:match("^[0-9a-f]+$") ~= nil,
        "stage tree snapshot is required")
    else
      check(observation.cycle_path_exact == true
          and observation.tree_exact == true
          and type(observation.tree_before) == "string"
          and observation.tree_after == observation.tree_before,
        "unstage must restore the staged sidecar and exact index tree")
    end
    for _, records in ipairs({
      observation.before_name_status or {},
      observation.after_name_status or {},
    }) do
      for _, record in ipairs(records) do
        check(type(record) == "table"
            and type(record.status) == "string" and record.status ~= ""
            and type(record.path) == "string" and record.path ~= "",
          action.name .. " name-status records must be exact")
      end
    end
  elseif action.name == "close_reopen" then
    local equivalence = observation.equivalence
    check(type(equivalence) == "table"
        and equivalence.disk_exact == true
        and equivalence.model_exact == true
        and equivalence.ui_exact == true
        and equivalence.paging_exact == true,
      "close_reopen bounded equivalence evidence is required")
  elseif exact[action.name] then
    check(observation[exact[action.name]] == true,
      action.name .. " exact observation is required")
  end
end

function M.validate_worker(payload, expected)
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
  check_all_numbers(payload, errors, {}, "payload")
  check(type(expected) == "table", "expected identity must be an object")
  expected = type(expected) == "table" and expected or {}

  check(payload.schema == WORKER_SCHEMA, "unexpected worker schema")
  check(payload.status == "ok", "worker status must be ok")
  check(payload.error == nil or payload.error == vim.NIL,
    "successful worker must not publish an error")
  check(payload.rows == expected.rows, "row count mismatch")
  check(payload.seed == expected.seed, "seed mismatch")
  check(payload.run_index == expected.run_index, "run index mismatch")

  local manifest = payload.manifest
  check(type(manifest) == "table", "manifest observation is required")
  if type(manifest) == "table" then
    check(manifest.schema == FIXTURE_SCHEMA, "fixture schema mismatch")
    check(manifest.rows == expected.rows, "fixture rows mismatch")
    check(manifest.seed == expected.seed, "fixture seed mismatch")
    check(manifest.primary_path == "primary.txt", "primary path mismatch")
    check(manifest.first_line
        == ("scale 1 seed %d"):format(expected.seed),
      "fixture first line mismatch")
    check(manifest.last_line
        == ("scale %d seed %d"):format(expected.rows, expected.seed),
      "fixture last line mismatch")
    check(sha256(manifest.digest), "fixture digest must be sha256")
  end

  local found_phases = {}
  check(type(payload.phases) == "table", "phase samples are required")
  for _, phase in ipairs(
      type(payload.phases) == "table" and payload.phases or {}) do
    check(type(phase) == "table", "phase sample must be an object")
    if type(phase) == "table" then
      local name = phase.name
      check(type(name) == "string" and PHASES[name] == true,
        "unexpected phase " .. tostring(phase.name))
      check(type(name) ~= "string" or not found_phases[name],
        "duplicate phase " .. tostring(phase.name))
      if type(name) == "string" then
        found_phases[name] = true
      end
      check(metrics.finite(phase.elapsed_ns) and phase.elapsed_ns >= 0,
        "phase duration must be finite")
      check(phase.status == "ok", "phase must finish successfully")
    end
  end
  for name in pairs(PHASES) do
    check(found_phases[name], "missing phase " .. name)
  end

  local planned_ok, plan = pcall(actions.plan, expected.rows, expected.seed)
  check(planned_ok, "expected action plan is invalid")
  plan = planned_ok and plan or {}
  check(type(payload.trace) == "table" and #payload.trace == #plan,
    "trace must exactly match planned length")
  for index, planned in ipairs(plan) do
    local action = type(payload.trace) == "table"
        and payload.trace[index] or nil
    check(type(action) == "table", "missing planned action " .. index)
    if type(action) == "table" then
      check(action.index == index, "action indices must be contiguous")
      check(action.name == planned.name, "action name/order mismatch")
      check(vim.deep_equal(action.arguments, planned.arguments),
        "action arguments mismatch")
      check(metrics.finite(action.operation_ns) and action.operation_ns >= 0,
        "action operation duration must be finite")
      if action.name == "open" then
        check(metrics.finite(action.first_view_ns)
            and action.first_view_ns >= 0
            and metrics.finite(action.operation_ns)
            and action.first_view_ns < action.operation_ns
            and integer(action.operation_count)
            and action.operation_count >= 2,
          "open first-view duration must be finite")
      else
        check(action.first_view_ns == nil or action.first_view_ns == vim.NIL,
          "only open may publish first-view duration")
      end
      check(action.elapsed_ns == action.operation_ns,
        "elapsed duration must contain operation time only")
      check(metrics.finite(action.oracle_ns) and action.oracle_ns >= 0,
        "action oracle duration must be finite")
      check(metrics.finite(action.wall_ns)
          and metrics.finite(action.operation_ns)
          and action.wall_ns >= action.operation_ns,
        "action wall duration must be finite")
      check(integer(action.operation_count) and action.operation_count >= 1,
        "action operation count must be positive")
      check(action.status == "ok", "action must finish successfully")
      check(type(action.observations) == "table",
        "action observations are required")
      if type(action.observations) == "table" then
        validate_action_observation(action, check)
      end
    end
  end

  local correctness = payload.correctness
  check(type(correctness) == "table",
    "correctness observations are required")
  if type(correctness) == "table" then
    local content = correctness.content
    check(type(content) == "table"
        and content.disk_exact == true
        and content.model_exact == true
        and content.ui_exact == true,
      "content identities were not preserved")
    local lenses = correctness.lenses
    check(type(lenses) == "table"
        and lenses.preserved == true
        and type(lenses.observations) == "table",
      "lens identities were not preserved")
    local projection = correctness.projection
    check(type(projection) == "table"
        and projection.preserved == true
        and integer(projection.samples)
        and projection.samples > 0,
      "projected UI identities were not preserved")
    local index = correctness.index
    check(type(index) == "table"
        and index.stage_exact == true
        and index.unstage_exact == true
        and index.primary_absent == true
        and index.paths_exact == true
        and index.cycle_path_exact == true
        and index.tree_exact == true
        and type(index.tree_before) == "string"
        and index.tree_after == index.tree_before,
      "index identities were not preserved")
    local refs = correctness.refs
    check(type(refs) == "table"
        and refs.branch_exact == true
        and refs.range_exact == true,
      "comparison ref identities were not preserved")
    local git_failure = correctness.git_failure
    check(type(git_failure) == "table"
        and git_failure.caught == true
        and type(git_failure.error) == "string",
      "injected Git failure was not contained")
  end

  local adapters = payload.adapters
  check(type(adapters) == "table", "timing adapters are required")
  local git_samples = type(adapters) == "table" and adapters.git or nil
  check(type(git_samples) == "table" and #git_samples > 0,
    "Git timing adapter observations are required")
  for _, sample in ipairs(type(git_samples) == "table" and git_samples or {}) do
    check(type(sample) == "table", "Git adapter sample must be an object")
    if type(sample) == "table" then
      check(type(sample.argv) == "table" and #sample.argv > 0,
        "Git argv is required")
      for _, argument in ipairs(
          type(sample.argv) == "table" and sample.argv or {}) do
        check(type(argument) == "string",
          "Git argv must contain strings")
      end
      check(type(sample.category) == "string" and sample.category ~= "",
        "Git argv category is required")
      check(sample.status == "ok", "Git adapter status must be ok")
      check(metrics.finite(sample.elapsed_ns) and sample.elapsed_ns >= 0,
        "Git adapter duration must be finite")
    end
  end

  local source_samples = type(adapters) == "table" and adapters.source or nil
  local source_seen = {}
  check(type(source_samples) == "table" and #source_samples > 0,
    "source timing adapter observations are required")
  for _, sample in ipairs(
      type(source_samples) == "table" and source_samples or {}) do
    check(type(sample) == "table", "source adapter sample must be an object")
    if type(sample) == "table" then
      local name = sample.name
      check(type(name) == "string" and SOURCE_NAMES[name] == true,
        "unexpected source adapter name")
      if type(name) == "string" then
        source_seen[name] = true
      end
      check(sample.status == "ok", "source adapter status must be ok")
      check(metrics.finite(sample.elapsed_ns) and sample.elapsed_ns >= 0,
        "source adapter duration must be finite")
    end
  end
  for name in pairs(SOURCE_NAMES) do
    check(source_seen[name], "missing source adapter " .. name)
  end

  local heartbeat = payload.heartbeat
  check(type(heartbeat) == "table"
      and heartbeat.interval_ms == 10
      and heartbeat.scope == "plugin_operations"
      and heartbeat.started_after_fixture == true
      and integer(heartbeat.ticks) and heartbeat.ticks >= 1
      and metrics.finite(heartbeat.max_gap_ns)
      and heartbeat.max_gap_ns > 0
      and integer(heartbeat.operation_windows)
      and heartbeat.operation_windows >= 1,
    "heartbeat must contain finite plugin-operation observations")
  local maximum = type(heartbeat) == "table" and heartbeat.max_gap or nil
  local attributed_action = type(maximum) == "table"
      and type(payload.trace) == "table"
      and maximum.action_index and payload.trace[maximum.action_index] or nil
  check(type(maximum) == "table"
      and integer(maximum.action_index) and maximum.action_index >= 1
      and type(maximum.action_name) == "string"
      and type(attributed_action) == "table"
      and attributed_action.name == maximum.action_name
      and metrics.finite(maximum.callback_admission_ns)
      and maximum.callback_admission_ns == heartbeat.max_gap_ns
      and metrics.finite(maximum.callback_body_ns)
      and maximum.callback_body_ns >= 0,
    "heartbeat maximum-gap attribution is required")

  local watch = payload.watch
  check(type(watch) == "table"
      and integer(watch.convergence_timeout_ms)
      and watch.convergence_timeout_ms == watch_convergence_timeout_ms(expected.rows),
    "watch convergence deadline must match the bounded scale policy")

  local capabilities = payload.capabilities
  check(type(capabilities) == "table"
      and type(capabilities.rss_source) == "string"
      and capabilities.rss_source ~= ""
      and type(capabilities.hwm_source) == "string"
      and capabilities.hwm_source ~= ""
      and type(capabilities.paged_canvas) == "boolean"
      and type(capabilities.procfs) == "boolean",
    "memory and paging capabilities are required")

  local memory = payload.memory
  check(type(memory) == "table"
      and type(memory.samples) == "table"
      and #memory.samples == #MEMORY_NAMES,
    "memory samples are required")
  local memory_names = {}
  for _, sample in ipairs(type(memory) == "table"
      and type(memory.samples) == "table" and memory.samples or {}) do
    check(type(sample) == "table", "memory sample must be an object")
    if type(sample) == "table" then
      local name = sample.name
      check(type(name) == "string" and MEMORY_NAME_SET[name] == true,
        "unexpected memory sample " .. tostring(name))
      if type(name) == "string" and MEMORY_NAME_SET[name] then
        check(not memory_names[name], "duplicate memory sample " .. name)
        memory_names[name] = true
      end
      check(metrics.finite(sample.heap_bytes) and sample.heap_bytes >= 0,
        "heap sample must be finite")
      if type(capabilities) == "table"
          and capabilities.rss_source ~= "unavailable" then
        check(metrics.finite(sample.rss_bytes) and sample.rss_bytes > 0,
          "RSS sample must be finite when available")
      end
      if type(capabilities) == "table"
          and capabilities.hwm_source ~= "unavailable" then
        check(metrics.finite(sample.hwm_bytes) and sample.hwm_bytes > 0,
          "HWM sample must be finite when available")
      end
    end
  end
  for _, name in ipairs(MEMORY_NAMES) do
    check(memory_names[name], "missing memory sample " .. name)
  end

  local paging = payload.paging
  check(type(paging) == "table"
      and (paging.mode == "eager" or paging.mode == "paged")
      and integer(paging.logical_rows) and paging.logical_rows > 0
      and type(paging.cache) == "table"
      and type(paging.cache.available) == "boolean",
    "finite paging/cache observations are required")
  if type(paging) == "table" and paging.mode == "eager" then
    check(integer(paging.buffer_rows) and paging.buffer_rows > 0,
      "eager buffer rows must be finite")
  elseif type(paging) == "table" and paging.mode == "paged" then
    local cache = paging.cache
    check(type(cache) == "table"
        and cache.available == true
        and integer(cache.row_count) and cache.row_count > 0
        and integer(cache.page_count) and cache.page_count > 0,
      "paged cache values must be finite")
    check(type(paging.projection) == "table"
        and integer(paging.projection.logical_rows)
        and integer(paging.projection.skeleton_rows),
      "paged projection values must be finite")
    check(type(paging.scheduler) == "table",
      "paged scheduler values are required")
    local resident = type(cache) == "table" and cache.resident or nil
    check(type(resident) == "table"
        and integer(resident.pages) and resident.pages >= 0
        and integer(resident.bytes) and resident.bytes >= 0
        and integer(resident.max_pages) and resident.max_pages >= 0
        and integer(resident.max_bytes) and resident.max_bytes >= 0,
      "paged resident cache observations are required")
    check(integer(resident and resident.samples)
        and resident.samples >= 2
        and integer(resident.navigation_samples)
        and resident.navigation_samples >= 1
        and resident.scope == "live_after_first_view_and_actions"
        and resident.first_sample == "open_first_view"
        and type(resident.last_sample) == "string",
      "paged resident evidence must cover live navigation")
  end

  local extmarks = payload.extmarks
  check(type(extmarks) == "table"
      and integer(extmarks.during) and extmarks.during >= 0
      and integer(extmarks.after) and extmarks.after >= 0,
    "extmark observations must be finite integers")

  local cleanup = payload.cleanup
  check(type(cleanup) == "table", "cleanup observations are required")
  if type(cleanup) == "table" then
    check(cleanup.fixture_cleanup_attempted == true,
      "same-instance fixture cleanup was not attempted")
    check(cleanup.fixture_removed == true, "fixture root survived cleanup")
    check(cleanup.canvas_windows == 0,
      "CanvasDiff windows survived cleanup")
    check(cleanup.open_timers == 0, "timers survived cleanup")
    check(cleanup.wrappers_restored == true,
      "timing wrappers were not restored")
    check(type(cleanup.owned_groups) == "table"
        and #cleanup.owned_groups == 0,
      "CanvasDiff autocmd groups survived cleanup")
    check(type(cleanup.checked_group_prefixes) == "table"
        and vim.deep_equal(cleanup.checked_group_prefixes, RESOURCE_GROUPS),
      "cleanup did not check the complete ownership group set")
  end

  return #errors == 0 and true or nil, errors
end

local function gate_worker(payload, expected)
  local errors = {}
  local function check(condition, message)
    if not condition then
      errors[#errors + 1] = message
    end
  end

  check(payload.rows == expected.rows
      and payload.manifest.rows == expected.rows,
    "worker did not preserve exact requested content rows")
  check(payload.error == nil or payload.error == vim.NIL,
    "worker published an unhandled error")
  check(payload.heartbeat.max_gap_ns <= HEARTBEAT_MAX_GAP_NS,
    "heartbeat max gap exceeds 2s")
  check(payload.extmarks.after == 0,
    "extmarks must be zero after cleanup")
  if payload.paging.mode == "paged" then
    check(payload.extmarks.during == 0,
      "persistent row extmarks must be zero")
    local resident = payload.paging.cache.resident
    check(resident.max_pages == PAGING_RESIDENT_MAX_PAGES,
      "paging resident page cap differs from campaign config")
    check(resident.max_bytes == PAGING_RESIDENT_MAX_BYTES,
      "paging resident byte cap differs from campaign config")
    check(resident.pages <= resident.max_pages,
      "paging resident pages exceed configured cap")
    check(resident.bytes <= resident.max_bytes,
      "paging resident bytes exceed configured cap")
  end
  return #errors == 0 and true or nil, errors
end

local function safe_temporary_root()
  local seen = {}
  for _, candidate in ipairs({ uv.os_tmpdir(), "/tmp" }) do
    if type(candidate) == "string" and candidate ~= ""
        and not seen[candidate] then
      seen[candidate] = true
      local ok, resolved = pcall(canonical_future, candidate)
      local stat = ok and uv.fs_stat(resolved) or nil
      if stat and stat.type == "directory"
          and not within(resolved, canonical_repo_root) then
        return resolved
      end
    end
  end
  error("could not resolve a temporary directory outside the repository", 0)
end

local function new_run_root()
  local root = assert(absolute(vim.fs.joinpath(
    safe_temporary_root(),
    ("canvasdiff-live-scale-%d-%d"):format(vim.fn.getpid(), uv.hrtime())
  )))
  assert(not uv.fs_lstat(root), "coordinator root unexpectedly exists")
  assert(not within(canonical_future(root), canonical_repo_root),
    "coordinator root resolves inside the repository")
  mkdir_private(root)
  return root
end

local function default_launcher(run_root)
  local nvim = vim.fn.exepath("nvim")
  local git = vim.fn.exepath("git")
  assert(nvim ~= "", "Neovim executable is unavailable")
  assert(git ~= "", "Git executable is unavailable")
  local explicit_path = table.concat({
    vim.fs.dirname(nvim),
    vim.fs.dirname(git),
    "/usr/bin",
    "/bin",
  }, ":")

  return function(spec)
    local owner = vim.fs.joinpath(
      run_root, ("sample-%03d"):format(spec.sample_index))
    local output = vim.fs.joinpath(owner, "result.json")
    local fixture_root = vim.fs.joinpath(owner, "fixture")
    local home = vim.fs.joinpath(owner, "home")
    local xdg_config = vim.fs.joinpath(owner, "xdg-config")
    local xdg_data = vim.fs.joinpath(owner, "xdg-data")
    local xdg_state = vim.fs.joinpath(owner, "xdg-state")
    local xdg_cache = vim.fs.joinpath(owner, "xdg-cache")
    local xdg_runtime = vim.fs.joinpath(owner, "xdg-runtime")
    local temporary = vim.fs.joinpath(owner, "tmp")
    local log_path = vim.fs.joinpath(owner, "nvim.log")

    mkdir_private(owner)
    mkdir(fixture_root)
    mkdir_private(home)
    mkdir(xdg_config)
    mkdir(xdg_data)
    mkdir(xdg_state)
    mkdir(xdg_cache)
    mkdir_private(xdg_runtime)
    mkdir_private(temporary)
    assert(vim.fn.empty(vim.fn.readdir(fixture_root)) == 1,
      "fixture root must be empty before worker launch")
    assert(not uv.fs_lstat(output), "worker output must not exist before launch")
    assert(vim.fs.dirname(output) == vim.fs.dirname(fixture_root),
      "worker output and fixture must share coordinator owner")

    local started = uv.hrtime()
    local completed = vim.system({
      nvim,
      "--headless",
      "--clean",
      "-n",
      "-i",
      "NONE",
      "-l",
      worker_path,
      output,
      fixture_root,
      tostring(spec.rows),
      tostring(spec.seed),
      tostring(spec.run_index),
    }, {
      cwd = repo_root,
      clear_env = true,
      text = true,
      timeout = spec.timeout_ms,
      env = {
        PATH = explicit_path,
        HOME = home,
        TMPDIR = temporary,
        XDG_CONFIG_HOME = xdg_config,
        XDG_DATA_HOME = xdg_data,
        XDG_STATE_HOME = xdg_state,
        XDG_CACHE_HOME = xdg_cache,
        XDG_RUNTIME_DIR = xdg_runtime,
        NVIM_APPNAME = "canvasdiff-live-scale",
        NVIM_LOG_FILE = log_path,
        GIT_CONFIG_GLOBAL = "/dev/null",
        GIT_CONFIG_SYSTEM = "/dev/null",
        GIT_CONFIG_NOSYSTEM = "1",
        GIT_TERMINAL_PROMPT = "0",
        LC_ALL = "C",
        LANG = "C",
        TZ = "UTC",
        TERM = "dumb",
      },
    }):wait()
    local payload = read_all(output)
    return {
      code = completed.code,
      signal = completed.signal,
      timed_out = completed.code == 124,
      stdout = completed.stdout,
      stderr = completed.stderr,
      wall_ns = uv.hrtime() - started,
      payload = payload,
      isolation = {
        owner = owner,
        output = output,
        fixture_root = fixture_root,
        home = home,
        xdg_config = xdg_config,
        xdg_data = xdg_data,
        xdg_state = xdg_state,
        xdg_cache = xdg_cache,
        xdg_runtime = xdg_runtime,
        temporary = temporary,
        clear_env = true,
      },
    }
  end
end

local function validate_sizes(sizes)
  assert(type(sizes) == "table" and #sizes > 0,
    "sizes must be a non-empty array")
  local previous
  for index, size in ipairs(sizes) do
    assert(integer(size) and size >= 1,
      ("sizes[%d] must be a positive integer"):format(index))
    assert(not previous or size > previous,
      "sizes must be strictly increasing and unique")
    previous = size
  end
end

local function is_authoritative(sizes)
  return vim.deep_equal(sizes, AUTHORITATIVE_SIZES)
end

local function validate_output(path, authoritative)
  if not path then
    return nil
  end
  local stat = uv.fs_lstat(path)
  assert(not stat or stat.type ~= "directory",
    "live-scale artifact is an existing directory")
  local destination = canonical_destination(path)
  if within(destination, canonical_repo_root) then
    local checked_in = vim.fs.joinpath(
      canonical_repo_root, "docs", "verification", "live-scale.json")
    assert(authoritative and destination == checked_in,
      "non-authoritative or unexpected checked-in output path is forbidden")
  end
  return destination
end

local function atomic_json(path, value)
  mkdir(vim.fs.dirname(path))
  local temporary = ("%s.tmp.%d.%d"):format(
    path, vim.fn.getpid(), uv.hrtime())
  local encoded_ok, encoded = pcall(vim.json.encode, value)
  if not encoded_ok then
    error("could not encode live-scale aggregate: " .. tostring(encoded), 0)
  end
  local descriptor, open_error = uv.fs_open(temporary, "wx", 384)
  assert(descriptor, ("could not create %s: %s"):format(
    temporary, tostring(open_error)))
  local written, write_error = uv.fs_write(descriptor, encoded .. "\n", -1)
  local closed, close_error = uv.fs_close(descriptor)
  if not written or not closed then
    vim.fn.delete(temporary)
    error(("could not write live-scale aggregate: %s%s"):format(
      tostring(write_error or ""), tostring(close_error or "")), 0)
  end
  local renamed, rename_error = uv.fs_rename(temporary, path)
  if not renamed then
    vim.fn.delete(temporary)
    error(("could not publish %s: %s"):format(
      path, rename_error or "rename failed"), 0)
  end
end

local function decode_payload(value)
  if type(value) == "table" then
    return value
  end
  if type(value) ~= "string" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, value)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function failure(kind, spec, messages, launched, worker_payload)
  local recorded = {
    kind = kind,
    size = spec.rows,
    repetition = spec.repetition,
    run_index = spec.run_index,
    messages = messages,
    stdout_tail = tail(launched and launched.stdout),
    stderr_tail = tail(launched and launched.stderr),
  }
  if worker_payload ~= nil then
    -- This crosses the process boundary only after strict validation, keeping
    -- gate failures reproducible without trusting malformed worker output.
    recorded.worker_payload = worker_payload
  end
  return recorded
end

local function derive_worker(payload)
  local source_ns = 0
  for _, sample in ipairs(payload.adapters.source) do
    local next_value = source_ns + sample.elapsed_ns
    if not metrics.finite(next_value) then
      return nil, { "source timing sum must be finite" }
    end
    source_ns = next_value
  end

  local peak_rss, peak_heap = 0, 0
  local retained_heap
  for _, sample in ipairs(payload.memory.samples) do
    peak_heap = math.max(peak_heap, sample.heap_bytes)
    if metrics.finite(sample.rss_bytes) then
      peak_rss = math.max(peak_rss, sample.rss_bytes)
    end
    if metrics.finite(sample.hwm_bytes) then
      peak_rss = math.max(peak_rss, sample.hwm_bytes)
    end
    if sample.name == "after_cleanup" then
      retained_heap = sample.heap_bytes
    end
  end
  if not metrics.finite(retained_heap) then
    return nil, { "retained heap derivation must be finite" }
  end
  local lines_per_second =
    math.floor(payload.rows * 1000000000 / source_ns)
  if not metrics.finite(lines_per_second) or lines_per_second <= 0
      or not metrics.finite(peak_heap) or peak_heap <= 0 then
    return nil, { "throughput and peak heap derivation must be finite" }
  end
  local first_view_ns
  for _, action in ipairs(payload.trace) do
    if action.name == "open" then
      first_view_ns = action.first_view_ns
      break
    end
  end
  if not metrics.finite(first_view_ns) then
    return nil, { "first-view derivation must be finite" }
  end
  return {
    source_ns = source_ns,
    peak_rss_bytes = peak_rss,
    peak_heap_bytes = peak_heap,
    retained_heap_bytes = retained_heap,
    lines_per_second = lines_per_second,
    first_view_ns = first_view_ns,
  }
end

local function append_value(destination, name, value)
  assert(type(name) == "string" and name ~= "",
    "aggregate metric name must be a non-empty string")
  assert(metrics.finite(value), "aggregate metric value must be finite")
  destination[name] = destination[name] or {}
  destination[name][#destination[name] + 1] = value
end

local function summarize_map(values)
  local result = {}
  for name, samples in pairs(values) do
    result[name] = metrics.summary(samples)
  end
  return result
end

local function aggregate_size(size, samples, repetitions)
  local phases, action_values = {}, {}
  local source_values, first_view_values, heartbeat_values = {}, {}, {}
  local peak_rss_values, peak_heap_values, retained_heap_values = {}, {}, {}
  local throughput_values = {}
  for _, sample in ipairs(samples) do
    if sample.size == size and sample.status == "pass" then
      local payload = sample.worker
      for _, phase in ipairs(payload.phases) do
        append_value(phases, phase.name, phase.elapsed_ns)
      end
      for _, action in ipairs(payload.trace) do
        append_value(action_values, action.name, action.operation_ns)
      end
      source_values[#source_values + 1] = sample.derived.source_ns
      first_view_values[#first_view_values + 1] =
        sample.derived.first_view_ns
      heartbeat_values[#heartbeat_values + 1] =
        payload.heartbeat.max_gap_ns
      peak_rss_values[#peak_rss_values + 1] =
        sample.derived.peak_rss_bytes
      peak_heap_values[#peak_heap_values + 1] =
        sample.derived.peak_heap_bytes
      retained_heap_values[#retained_heap_values + 1] =
        sample.derived.retained_heap_bytes
      throughput_values[#throughput_values + 1] =
        sample.derived.lines_per_second
    end
  end
  if #source_values ~= repetitions then
    return nil
  end
  local action_summaries = summarize_map(action_values)
  return {
    size = size,
    sample_count = #source_values,
    phases = summarize_map(phases),
    actions = action_summaries,
    operations = vim.deepcopy(action_summaries),
    source = metrics.summary(source_values),
    lines_per_second = metrics.summary(throughput_values),
    first_view = metrics.summary(first_view_values),
    heartbeat = {
      max_gap_ns = metrics.summary(heartbeat_values),
    },
    memory = {
      peak_rss_bytes = metrics.summary(peak_rss_values),
      peak_heap_bytes = metrics.summary(peak_heap_values),
      retained_heap_bytes = metrics.summary(retained_heap_values),
    },
    verdict = "pass",
  }
end

local function fixture_identity(samples, sizes, repetitions)
  local by_size = {}
  local counts = {}
  for _, sample in ipairs(samples) do
    if sample.status == "pass" then
      counts[sample.size] = (counts[sample.size] or 0) + 1
      if not by_size[sample.size] then
        by_size[sample.size] = sample.worker.manifest.digest
      end
    end
  end
  local records = {}
  for _, size in ipairs(sizes) do
    local digest = counts[size] == repetitions and by_size[size] or "missing"
    records[#records + 1] =
      tostring(size) .. "\0" .. tostring(digest)
  end
  return {
    schema = FIXTURE_SCHEMA,
    digest = vim.fn.sha256(table.concat(records, "\n")),
  }
end

local function read_baseline(value)
  if type(value) == "table" then
    return value
  end
  assert(type(value) == "string" and value ~= "",
    "baseline must be an aggregate object or JSON path")
  local content, read_error = read_all(value)
  assert(content, "could not read baseline: " .. tostring(read_error))
  local ok, decoded = pcall(vim.json.decode, content)
  assert(ok and type(decoded) == "table",
    "baseline must contain a JSON object")
  return decoded
end

function M.execute(options)
  options = options or {}
  assert(type(options) == "table", "coordinator options must be an object")
  local sizes_overridden = options.sizes ~= nil
  local sizes = vim.deepcopy(options.sizes or AUTHORITATIVE_SIZES)
  validate_sizes(sizes)
  local authoritative = not sizes_overridden and is_authoritative(sizes)
  local repetitions = options.repetitions == nil and 1 or options.repetitions
  assert(integer(repetitions) and repetitions >= 1 and repetitions <= 20,
    "repetitions must be an integer between 1 and 20")
  local seed = options.seed == nil and SEED or options.seed
  assert(integer(seed), "seed must be an integer")
  local output = validate_output(options.output, authoritative)
  local baseline = options.baseline ~= nil
      and read_baseline(options.baseline) or nil
  local observed_environment = options.environment or environment()
  assert(type(observed_environment) == "table"
      and sha256(observed_environment.host_fingerprint)
      and sha256(observed_environment.source_tree_digest)
      and integer(observed_environment.source_tree_entries)
      and observed_environment.source_tree_entries > 0,
    "coordinator environment identity is invalid")

  local run_root
  local launch = options.launch
  if launch == nil then
    run_root = new_run_root()
    launch = default_launcher(run_root)
  end
  assert(type(launch) == "function", "launch must be a function")

  local aggregate = {
    schema = SCHEMA,
    profile = PROFILE,
    status = "pass",
    verdict = "pass",
    authoritative = authoritative,
    authoritative_sizes = vim.deepcopy(AUTHORITATIVE_SIZES),
    sizes = vim.deepcopy(sizes),
    repetitions = repetitions,
    seed = seed,
    environment = vim.deepcopy(observed_environment),
    host_fingerprint = observed_environment.host_fingerprint,
    provenance = {
      source_revision = observed_environment.git_revision,
      tree_digest = observed_environment.source_tree_digest,
    },
    thresholds = {
      worker_timeout_ms = WORKER_TIMEOUT_MS,
      cleanup = { required = true },
      requested_content_rows = { exact = true },
      correctness = { all = true },
      heartbeat_ticks = { min = 1 },
      heartbeat_max_gap_ns = {
        target = HEARTBEAT_TARGET_GAP_NS,
        max = HEARTBEAT_MAX_GAP_NS,
      },
      watch_convergence_timeout_ms = {
        base = WATCH_CONVERGENCE_BASE_MS,
        per_100k_rows = WATCH_CONVERGENCE_PER_100K_MS,
        max = WATCH_CONVERGENCE_MAX_MS,
      },
      row_extmarks = { exact = 0, scope = "paged_persistent" },
      paging_resident_pages = { max = PAGING_RESIDENT_MAX_PAGES },
      paging_resident_bytes = { max = PAGING_RESIDENT_MAX_BYTES },
      worker_error = { allowed = false },
      latency = { observational = true },
      memory = { observational = true },
    },
    config_digest = vim.fn.sha256(table.concat({
      PROFILE,
      "seed=" .. seed,
      "virt.enabled=false",
      "heartbeat.interval_ms=10",
      "first_view=forced_redraw",
      "resident.max_pages=" .. PAGING_RESIDENT_MAX_PAGES,
      "resident.max_bytes=" .. PAGING_RESIDENT_MAX_BYTES,
    }, "\n")),
    samples = {},
    aggregates = {},
    failures = {},
  }

  local capability_reference
  local fixture_reference_by_size = {}
  local sample_index = 0
  for _, size in ipairs(sizes) do
    for repetition = 1, repetitions do
      sample_index = sample_index + 1
      local spec = {
        rows = size,
        repetition = repetition,
        run_index = repetition,
        sample_index = sample_index,
        seed = seed,
        timeout_ms = WORKER_TIMEOUT_MS,
      }
      local launched_ok, launched = pcall(launch, vim.deepcopy(spec))
      if not launched_ok or type(launched) ~= "table" then
        local launch_error = launched
        launched = type(launched) == "table" and launched or {}
        local message = launched_ok
            and "launcher must return a result object"
          or "worker launch failed: " .. tostring(launch_error)
        aggregate.failures[#aggregate.failures + 1] =
          failure("launch", spec, { message }, launched)
        aggregate.samples[#aggregate.samples + 1] = {
          size = size,
          repetition = repetition,
          run_index = repetition,
          status = "fail",
          failure_kind = "launch",
        }
      elseif launched.timed_out == true then
        local recorded = failure("timeout", spec, {
          ("worker exceeded the %dms timeout"):format(WORKER_TIMEOUT_MS),
        }, launched)
        aggregate.failures[#aggregate.failures + 1] = recorded
        aggregate.samples[#aggregate.samples + 1] = {
          size = size,
          repetition = repetition,
          run_index = repetition,
          status = "fail",
          failure_kind = "timeout",
          isolation = launched.isolation,
        }
      else
        local payload = decode_payload(launched.payload)
        if not payload then
          aggregate.failures[#aggregate.failures + 1] =
            failure("malformed_payload", spec, {
              "worker payload is not valid JSON",
            }, launched)
          aggregate.samples[#aggregate.samples + 1] = {
            size = size,
            repetition = repetition,
            run_index = repetition,
            status = "fail",
            failure_kind = "malformed_payload",
            isolation = launched.isolation,
          }
        else
          local validation_called, valid, validation_errors =
            pcall(M.validate_worker, payload, spec)
          if not validation_called then
            aggregate.failures[#aggregate.failures + 1] =
              failure("validation_exception", spec, {
                "worker validation raised: " .. tostring(valid),
              }, launched)
            aggregate.samples[#aggregate.samples + 1] = {
              size = size,
              repetition = repetition,
              run_index = repetition,
              status = "fail",
              failure_kind = "validation_exception",
              isolation = launched.isolation,
            }
          elseif not valid then
            aggregate.failures[#aggregate.failures + 1] =
              failure("validation", spec, validation_errors, launched)
            aggregate.samples[#aggregate.samples + 1] = {
              size = size,
              repetition = repetition,
              run_index = repetition,
              status = "fail",
              failure_kind = "validation",
              isolation = launched.isolation,
            }
          elseif launched.code ~= 0
              or (launched.signal ~= nil and launched.signal ~= 0) then
            aggregate.failures[#aggregate.failures + 1] =
              failure("process", spec, {
                ("worker process failed: exit=%s signal=%s"):format(
                  tostring(launched.code), tostring(launched.signal)),
              }, launched)
            aggregate.samples[#aggregate.samples + 1] = {
              size = size,
              repetition = repetition,
              run_index = repetition,
              status = "fail",
              failure_kind = "process",
              isolation = launched.isolation,
            }
          else
            local derived_called, derived, derived_errors =
              pcall(derive_worker, payload)
            if not derived_called then
              aggregate.failures[#aggregate.failures + 1] =
                failure("derived_metrics", spec, {
                  "worker metric derivation raised: " .. tostring(derived),
                }, launched)
              aggregate.samples[#aggregate.samples + 1] = {
                size = size,
                repetition = repetition,
                run_index = repetition,
                status = "fail",
                failure_kind = "derived_metrics",
                isolation = launched.isolation,
              }
            elseif not derived then
              aggregate.failures[#aggregate.failures + 1] =
                failure("derived_metrics", spec, derived_errors, launched)
              aggregate.samples[#aggregate.samples + 1] = {
                size = size,
                repetition = repetition,
                run_index = repetition,
                status = "fail",
                failure_kind = "derived_metrics",
                isolation = launched.isolation,
              }
            else
              local gate_called, gated, gate_errors =
                pcall(gate_worker, payload, spec)
              if not gate_called then
                aggregate.failures[#aggregate.failures + 1] =
                  failure("gate_exception", spec, {
                    "worker gate raised: " .. tostring(gated),
                  }, launched)
                aggregate.samples[#aggregate.samples + 1] = {
                  size = size,
                  repetition = repetition,
                  run_index = repetition,
                  status = "fail",
                  failure_kind = "gate_exception",
                  isolation = launched.isolation,
                }
              elseif not gated then
                aggregate.failures[#aggregate.failures + 1] =
                failure("gate", spec, gate_errors, launched, payload)
                aggregate.samples[#aggregate.samples + 1] = {
                  size = size,
                  repetition = repetition,
                  run_index = repetition,
                  status = "fail",
                  failure_kind = "gate",
                  isolation = launched.isolation,
                }
              elseif capability_reference
                  and not vim.deep_equal(
                    capability_reference, payload.capabilities) then
                aggregate.failures[#aggregate.failures + 1] =
                  failure("identity", spec, {
                    "worker capability identity differs from the first sample",
                  }, launched)
                aggregate.samples[#aggregate.samples + 1] = {
                  size = size,
                  repetition = repetition,
                  run_index = repetition,
                  status = "fail",
                  failure_kind = "identity",
                  isolation = launched.isolation,
                }
              else
                local fixture_identity = {
                  schema = payload.manifest.schema,
                  digest = payload.manifest.digest,
                  rows = payload.manifest.rows,
                  seed = payload.manifest.seed,
                  first_line = payload.manifest.first_line,
                  last_line = payload.manifest.last_line,
                }
                local fixture_reference = fixture_reference_by_size[size]
                if fixture_reference
                    and not vim.deep_equal(
                      fixture_reference, fixture_identity) then
                  aggregate.failures[#aggregate.failures + 1] =
                    failure("fixture_identity", spec, {
                      "fixture identity differs across repetitions",
                    }, launched)
                  aggregate.samples[#aggregate.samples + 1] = {
                    size = size,
                    repetition = repetition,
                    run_index = repetition,
                    status = "fail",
                    failure_kind = "fixture_identity",
                    isolation = launched.isolation,
                  }
                else
                  capability_reference = capability_reference
                    or vim.deepcopy(payload.capabilities)
                  fixture_reference_by_size[size] =
                    fixture_reference or fixture_identity
                  aggregate.samples[#aggregate.samples + 1] = {
                    size = size,
                    repetition = repetition,
                    run_index = repetition,
                    status = "pass",
                    process = {
                      wall_ns = launched.wall_ns,
                      exit_code = launched.code,
                      signal = launched.signal,
                      stdout_tail = tail(launched.stdout),
                      stderr_tail = tail(launched.stderr),
                    },
                    isolation = launched.isolation,
                    worker = payload,
                    derived = derived,
                  }
                end
              end
            end
          end
        end
      end
    end
  end

  aggregate.capabilities = capability_reference or {}
  aggregate.fixture = fixture_identity(aggregate.samples, sizes, repetitions)
  for _, size in ipairs(sizes) do
    local aggregated, row = pcall(
      aggregate_size, size, aggregate.samples, repetitions)
    if not aggregated then
      aggregate.failures[#aggregate.failures + 1] = {
        kind = "aggregation",
        size = size,
        messages = {
          "size aggregation raised: " .. tostring(row),
        },
      }
    elseif row then
      aggregate.aggregates[#aggregate.aggregates + 1] = row
    end
  end

  if baseline then
    if not authoritative then
      aggregate.comparison = {
        status = "incompatible",
        reasons = { "authoritative_sizes" },
      }
    else
      local checked, compatible, reasons =
        pcall(metrics.compatible, aggregate, baseline)
      if not checked then
        aggregate.comparison = {
          status = "invalid",
          reasons = {
            "baseline compatibility check raised: " .. tostring(compatible),
          },
        }
      elseif compatible then
        local compared, rows, compare_reasons =
          pcall(metrics.compare, aggregate, baseline)
        local finite_rows = compared and type(rows) == "table"
        if finite_rows then
          for _, row in ipairs(rows) do
            if type(row) ~= "table"
                or not metrics.finite(row.current)
                or not metrics.finite(row.baseline)
                or row.baseline <= 0
                or not metrics.finite(row.ratio)
                or not metrics.finite(row.percent) then
              finite_rows = false
              break
            end
          end
        end
        if not compared then
          aggregate.comparison = {
            status = "invalid",
            reasons = {
              "baseline comparison raised: " .. tostring(rows),
            },
          }
        elseif not rows then
          aggregate.comparison = {
            status = "incompatible",
            reasons = compare_reasons,
          }
        elseif not finite_rows then
          aggregate.comparison = {
            status = "invalid",
            reasons = {
              "baseline comparison produced invalid numeric data",
            },
          }
        else
          aggregate.comparison = {
            status = "compatible",
            rows = rows,
          }
        end
      else
        aggregate.comparison = {
          status = "incompatible",
          reasons = reasons,
        }
      end
    end
    if aggregate.comparison.status ~= "compatible" then
      local prefix = aggregate.comparison.status == "invalid"
          and "invalid baseline: " or "incompatible baseline: "
      aggregate.failures[#aggregate.failures + 1] = {
        kind = "baseline",
        messages = {
          prefix .. table.concat(aggregate.comparison.reasons, ", "),
        },
      }
    end
  end

  if #aggregate.failures > 0 then
    aggregate.status = "fail"
    aggregate.verdict = "fail"
  end

  if run_root then
    aggregate.cleanup = {
      coordinator_root = run_root,
      removed = vim.fn.delete(run_root, "rf") == 0,
    }
    if not aggregate.cleanup.removed then
      aggregate.failures[#aggregate.failures + 1] = {
        kind = "coordinator_cleanup",
        messages = { "coordinator root survived cleanup" },
      }
      aggregate.status = "fail"
      aggregate.verdict = "fail"
    end
  end
  if output then
    aggregate.output_realpath = output
    atomic_json(output, aggregate)
  end
  return aggregate
end

local function display_ms(value)
  if not metrics.finite(value) then
    return "-"
  end
  return ("%.2f"):format(value / 1000000)
end

local function display_mib(value)
  if not metrics.finite(value) then
    return "-"
  end
  return ("%.1f"):format(value / (1024 * 1024))
end

function M.format_table(aggregate)
  local lines = {
    ("%-10s %10s %10s %10s %10s %10s %10s %-7s"):format(
      "rows", "source", "open", "1st-view", "action",
      "hb-max", "rss/heap", "verdict"),
  }
  local by_size = {}
  for _, row in ipairs(aggregate.aggregates or {}) do
    by_size[row.size] = row
  end
  for _, size in ipairs(aggregate.sizes or {}) do
    local row = by_size[size]
    if row then
      local open = row.actions.open
      local action_max = 0
      for name, summary in pairs(row.actions) do
        if name ~= "open" then
          action_max = math.max(action_max, summary.p95)
        end
      end
      lines[#lines + 1] = (
        "%-10d %10s %10s %10s %10s %10s %10s %-7s"
      ):format(
        size,
        display_ms(row.source.p95),
        display_ms(open and open.p95),
        display_ms(row.first_view.p95),
        display_ms(action_max),
        display_ms(row.heartbeat.max_gap_ns.max),
        display_mib(row.memory.peak_rss_bytes.p95)
          .. "/" .. display_mib(row.memory.retained_heap_bytes.p95),
        row.verdict
      )
    else
      lines[#lines + 1] = (
        "%-10d %10s %10s %10s %10s %10s %10s %-7s"
      ):format(size, "-", "-", "-", "-", "-", "-", "fail")
    end
  end
  return table.concat(lines, "\n")
end

return M
