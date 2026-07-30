local H = require("helpers")
local actions = require("benchmark.live_scale.actions")
local coordinator = require("benchmark.live_scale.coordinator")

local T = {}

local SHA = string.rep("a", 64)

local function memory_sample(name, heap, rss, hwm)
  return {
    name = name,
    heap_bytes = heap,
    rss_bytes = rss,
    hwm_bytes = hwm,
  }
end

local function action_observation(name)
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
  if name == "sequential_scroll" or name == "random_jump" then
    return {
      destination_exact = true,
      projection = {
        sampled = true,
        exact = true,
        expected = "expected row",
        actual = "expected row",
      },
    }
  elseif name == "manual_refresh" or name == "watch_refresh" then
    return {
      convergence = {
        mutated = true,
        disk_exact = true,
        model_exact = true,
        ui_exact = true,
        expected_bytes = "bytes",
        expected_digest = SHA,
      },
    }
  elseif name == "stage" or name == "unstage" then
    return {
      bytes_exact = true,
      primary_absent = true,
      paths_exact = true,
      before_paths = {},
      after_paths = {},
      before_name_status = {},
      after_name_status = {},
    }
  elseif name == "close_reopen" then
    return {
      equivalence = {
        disk_exact = true,
        model_exact = true,
        ui_exact = true,
        paging_exact = true,
      },
    }
  end
  return { [exact[name]] = true }
end

local function valid_payload(rows, run_index)
  local trace = {}
  for index, planned in ipairs(actions.plan(rows, 1729)) do
    local operation_ns = planned.name == "open"
        and rows + 2000 or rows + index
    trace[index] = {
      index = index,
      name = planned.name,
      arguments = vim.deepcopy(planned.arguments),
      operation_ns = operation_ns,
      elapsed_ns = operation_ns,
      oracle_ns = index,
      wall_ns = operation_ns + index,
      operation_count = planned.name == "open" and 2 or 1,
      status = "ok",
      observations = action_observation(planned.name),
    }
    if planned.name == "open" then
      trace[index].first_view_ns = rows + 777
    end
  end

  return {
    schema = "canvasdiff.live_scale.worker/v1",
    status = "ok",
    rows = rows,
    seed = 1729,
    run_index = run_index,
    manifest = {
      schema = "canvasdiff.live_scale.fixture/v1",
      rows = rows,
      seed = 1729,
      primary_path = "primary.txt",
      first_line = "scale 1 seed 1729",
      last_line = ("scale %d seed 1729"):format(rows),
      digest = SHA,
    },
    phases = {
      { name = "fixture_build", elapsed_ns = rows + 1, status = "ok" },
      { name = "adapter_install", elapsed_ns = rows + 2, status = "ok" },
      { name = "app_load", elapsed_ns = rows + 3, status = "ok" },
      { name = "replay", elapsed_ns = rows + 4, status = "ok" },
      { name = "cleanup", elapsed_ns = rows + 5, status = "ok" },
    },
    trace = trace,
    adapters = {
      git = {
        {
          argv = { "git", "-C", "/fixture", "status" },
          category = "status",
          status = "ok",
          elapsed_ns = rows + 6,
        },
      },
      source = {
        { name = "root", status = "ok", elapsed_ns = rows + 7 },
        { name = "sections", status = "ok", elapsed_ns = rows + 8 },
        { name = "changed_files", status = "ok", elapsed_ns = rows + 9 },
        { name = "stage", status = "ok", elapsed_ns = rows + 10 },
        { name = "unstage", status = "ok", elapsed_ns = rows + 11 },
      },
    },
    correctness = {
      content = { disk_exact = true, model_exact = true, ui_exact = true },
      lenses = { preserved = true, observations = { "all" } },
      projection = { preserved = true, samples = 2 },
      index = {
        stage_exact = true,
        unstage_exact = true,
        primary_absent = true,
        paths_exact = true,
      },
      refs = { branch_exact = true, range_exact = true },
      git_failure = { caught = true, error = "injected" },
    },
    heartbeat = {
      interval_ms = 10,
      scope = "plugin_operations",
      started_after_fixture = true,
      ticks = 2,
      max_gap_ns = 50000000,
      operation_windows = #trace,
    },
    capabilities = {
      rss_source = "libuv.resident_set_memory",
      hwm_source = "procfs.VmHWM",
      paged_canvas = true,
      procfs = true,
    },
    memory = {
      samples = {
        memory_sample("worker_start", 100, 1000, 1000),
        memory_sample("after_fixture", 200, 2000, 2000),
        memory_sample("after_app_load", 300, 3000, 3000),
        memory_sample("after_replay", 400, 4000, 4000),
        memory_sample("after_cleanup", 250, 2500, 4000),
      },
    },
    paging = {
      mode = "paged",
      logical_rows = rows + 12,
      cache = {
        available = true,
        row_count = rows + 12,
        page_count = 2,
        resident = {
          pages = 2,
          bytes = 200,
          max_pages = 8,
          max_bytes = 532512,
          samples = 3,
          navigation_samples = 2,
          scope = "live_after_first_view_and_actions",
          first_sample = "open_first_view",
          last_sample = "after_random_jump",
        },
      },
      projection = {
        logical_rows = rows + 12,
        skeleton_rows = rows + 12,
      },
      scheduler = { deferred_pages = 0 },
    },
    extmarks = { during = 0, after = 0 },
    cleanup = {
      fixture_cleanup_attempted = true,
      fixture_removed = true,
      canvas_windows = 0,
      open_timers = 0,
      wrappers_restored = true,
      owned_groups = {},
      checked_group_prefixes = {
        "canvasdiff.watch",
        "canvasdiff.virt",
        "canvasdiff.highlight",
        "canvasdiff.status_column",
        "canvasdiff.sidebar",
        "canvasdiff.scrollbar",
        "canvasdiff.session",
        "canvasdiff.close",
        "canvasdiff.winbar",
      },
    },
  }
end

local function fake_environment()
  return {
    git_revision = "0123456789abcdef",
    git_dirty = false,
    nvim = "0.12.0",
    lua = "LuaJIT 2.1",
    lua_os = "Linux",
    lua_arch = "x64",
    os = "Linux",
    os_release = "test",
    machine = "x86_64",
    cpu = "test cpu",
    git = "git version 2.50",
    host_fingerprint = SHA,
    source_tree_digest = SHA,
    source_tree_entries = 10,
  }
end

T["live_scale_coordinator_aggregates development sizes and publishes atomically"] = function()
  local root = H.tmpdir()
  local output = vim.fs.joinpath(root, "aggregate.json")
  local aggregate = coordinator.execute({
    output = output,
    repetitions = 1,
    sizes = { 1, 1000 },
    environment = fake_environment(),
    launch = function(spec)
      return {
        code = 0,
        signal = 0,
        stdout = "",
        stderr = "",
        payload = vim.json.encode(valid_payload(spec.rows, spec.run_index)),
        isolation = {
          owner = "/tmp/coordinator/sample",
          output = "/tmp/coordinator/sample/result.json",
          fixture_root = "/tmp/coordinator/sample/fixture",
        },
      }
    end,
  })

  H.eq(aggregate.schema, "canvasdiff.live_scale/v1")
  H.eq(aggregate.profile, "live-git-v1")
  H.eq(aggregate.sizes, { 1, 1000 })
  H.eq(aggregate.authoritative, false)
  H.eq(aggregate.status, "pass")
  H.eq(aggregate.failures, {})
  H.eq(vim.tbl_map(function(sample) return sample.size end, aggregate.samples),
    { 1, 1000 })
  H.eq(vim.tbl_map(function(row) return row.size end, aggregate.aggregates),
    { 1, 1000 })
  H.eq(aggregate.aggregates[1].phases.fixture_build,
    { count = 1, p50 = 2, p95 = 2, max = 2 })
  H.eq(aggregate.aggregates[2].actions.open,
    { count = 1, p50 = 3000, p95 = 3000, max = 3000 })
  H.eq(aggregate.aggregates[2].first_view,
    { count = 1, p50 = 1777, p95 = 1777, max = 1777 })
  H.eq(aggregate.aggregates[1].heartbeat.max_gap_ns.max, 50000000)
  H.eq(aggregate.aggregates[1].memory.peak_rss_bytes.p95, 4000)
  H.eq(aggregate.aggregates[1].memory.retained_heap_bytes.p95, 250)
  H.eq(aggregate.environment.host_fingerprint, SHA)
  H.eq(aggregate.capabilities, {
    rss_source = "libuv.resident_set_memory",
    hwm_source = "procfs.VmHWM",
    paged_canvas = true,
    procfs = true,
  })
  H.eq(aggregate.thresholds.worker_timeout_ms, 900000)
  H.eq(aggregate.thresholds.heartbeat_max_gap_ns.max, 100000000)
  H.eq(aggregate.thresholds.row_extmarks.exact, 0)
  H.eq(aggregate.thresholds.paging_resident_pages.max, 8)
  H.eq(aggregate.thresholds.paging_resident_bytes.max, 532512)

  local file = assert(io.open(output, "rb"))
  local published = vim.json.decode(assert(file:read("*a")))
  assert(file:close())
  H.eq(published, aggregate)
  H.eq(vim.fn.glob(output .. ".tmp.*"), "")
  assert(vim.fn.delete(root, "rf") == 0)
end

T["live_scale_coordinator_records malformed timeout and gate failures then continues"] = function()
  local calls = 0
  local aggregate = coordinator.execute({
    repetitions = 1,
    sizes = { 1, 1000, 10000, 100000 },
    environment = fake_environment(),
    launch = function(spec)
      calls = calls + 1
      if spec.rows == 1 then
        return { code = 0, signal = 0, payload = "{not-json" }
      elseif spec.rows == 1000 then
        return {
          code = nil,
          signal = 15,
          timed_out = true,
          stderr = string.rep("x", 5000),
        }
      end
      local payload = valid_payload(spec.rows, spec.run_index)
      if spec.rows == 10000 then
        payload.heartbeat.max_gap_ns = 100000001
      end
      return { code = 0, signal = 0, payload = payload }
    end,
  })

  H.eq(calls, 4)
  H.eq(#aggregate.samples, 4)
  H.eq(vim.tbl_map(function(sample) return sample.size end, aggregate.samples),
    { 1, 1000, 10000, 100000 })
  H.eq(aggregate.status, "fail")
  H.eq(vim.tbl_map(function(failure) return failure.kind end, aggregate.failures),
    { "malformed_payload", "timeout", "gate" })
  H.eq(aggregate.failures[1].messages,
    { "worker payload is not valid JSON" })
  H.eq(aggregate.failures[2].messages,
    { "worker exceeded the 900000ms timeout" })
  H.eq(#aggregate.failures[2].stderr_tail, 4000)
  H.eq(aggregate.failures[3].messages,
    { "heartbeat max gap exceeds 100ms" })
  H.eq(aggregate.samples[4].status, "pass",
    "a later valid sample must survive preceding failures")
  H.eq(#aggregate.aggregates, 1)
  H.eq(aggregate.aggregates[1].size, 100000)
end

T["live_scale_coordinator_allows eager rendering extmarks but requires cleanup"] = function()
  local aggregate = coordinator.execute({
    repetitions = 1,
    sizes = { 1 },
    environment = fake_environment(),
    launch = function(spec)
      local payload = valid_payload(spec.rows, spec.run_index)
      payload.paging = {
        mode = "eager",
        logical_rows = 13,
        buffer_rows = 13,
        cache = { available = false, page_count = 0 },
      }
      payload.extmarks.during = 4
      return { code = 0, signal = 0, payload = payload }
    end,
  })

  H.eq(aggregate.status, "pass")
  H.eq(aggregate.failures, {})
end

T["live_scale_coordinator_rejects untrusted numbers and incompatible baseline"] = function()
  local payload = valid_payload(1, 1)
  payload.trace[1].operation_ns = 0 / 0
  local valid, errors = coordinator.validate_worker(payload, {
    rows = 1, seed = 1729, run_index = 1,
  })
  H.eq(valid, nil)
  assert(vim.tbl_contains(errors, "action operation duration must be finite"))

  payload = valid_payload(1, 1)
  payload.trace[2].observations.destination_exact = false
  valid, errors = coordinator.validate_worker(payload, {
    rows = 1, seed = 1729, run_index = 1,
  })
  H.eq(valid, nil)
  assert(vim.tbl_contains(
    errors, "sequential_scroll destination evidence is required"))

  local baseline = coordinator.execute({
    repetitions = 1,
    environment = fake_environment(),
    launch = function(spec)
      return { code = 0, signal = 0,
        payload = valid_payload(spec.rows, spec.run_index) }
    end,
  })

  local compatible = coordinator.execute({
    repetitions = 1,
    environment = fake_environment(),
    baseline = baseline,
    launch = function(spec)
      return { code = 0, signal = 0,
        payload = valid_payload(spec.rows, spec.run_index) }
    end,
  })
  H.eq(compatible.status, "pass")
  H.eq(compatible.comparison.status, "compatible")
  assert(#compatible.comparison.rows > 0)
  H.eq(compatible.comparison.rows[1].ratio, 1)

  baseline.host_fingerprint = string.rep("b", 64)

  local current = coordinator.execute({
    repetitions = 1,
    environment = fake_environment(),
    baseline = baseline,
    launch = function(spec)
      return { code = 0, signal = 0,
        payload = valid_payload(spec.rows, spec.run_index) }
    end,
  })

  H.eq(current.status, "fail")
  H.eq(current.comparison.status, "incompatible")
  H.eq(current.comparison.reasons, { "host_fingerprint" })
  H.eq(current.failures[#current.failures].kind, "baseline")
  H.eq(current.failures[#current.failures].messages,
    { "incompatible baseline: host_fingerprint" })
end

T["live_scale_coordinator_treats every explicit size override as development"] = function()
  local canonical = { 1, 1000, 10000, 100000, 1000000 }
  local function launch(spec)
    return {
      code = 0,
      signal = 0,
      payload = valid_payload(spec.rows, spec.run_index),
    }
  end
  local explicit = coordinator.execute({
    repetitions = 1,
    sizes = canonical,
    environment = fake_environment(),
    launch = launch,
  })
  local defaulted = coordinator.execute({
    repetitions = 1,
    environment = fake_environment(),
    launch = launch,
  })

  H.eq(explicit.authoritative, false)
  H.eq(defaulted.authoritative, true)
end

T["live_scale_coordinator_validation is total and overflow continues"] = function()
  for _, mutate in ipairs({
    function(payload) payload.phases[1].name = vim.NIL end,
    function(payload) payload.adapters.source[1].name = vim.NIL end,
    function(payload) payload.memory.samples[1].name = vim.NIL end,
  }) do
    local payload = valid_payload(1, 1)
    mutate(payload)
    local called, valid, errors = pcall(coordinator.validate_worker, payload, {
      rows = 1, seed = 1729, run_index = 1,
    })
    assert(called, "validation must be total over decoded JSON")
    H.eq(valid, nil)
    assert(type(errors) == "table" and #errors > 0)
  end

  local malformed = coordinator.execute({
    repetitions = 1,
    sizes = { 1, 1000 },
    environment = fake_environment(),
    launch = function(spec)
      local payload = valid_payload(spec.rows, spec.run_index)
      if spec.rows == 1 then
        payload.phases[1].name = vim.NIL
        payload = vim.json.encode(payload)
      end
      return { code = 0, signal = 0, payload = payload }
    end,
  })
  H.eq(malformed.failures[1].kind, "validation")
  H.eq(malformed.samples[2].status, "pass")
  H.eq(malformed.aggregates[1].size, 1000)

  local aggregate = coordinator.execute({
    repetitions = 1,
    sizes = { 1, 1000 },
    environment = fake_environment(),
    launch = function(spec)
      local payload = valid_payload(spec.rows, spec.run_index)
      if spec.rows == 1 then
        for _, sample in ipairs(payload.adapters.source) do
          sample.elapsed_ns = 1e308
        end
      end
      return { code = 0, signal = 0, payload = payload }
    end,
  })

  H.eq(aggregate.status, "fail")
  H.eq(aggregate.failures[1].kind, "derived_metrics")
  H.eq(aggregate.failures[1].messages,
    { "source timing sum must be finite" })
  H.eq(aggregate.samples[2].status, "pass")
  H.eq(#aggregate.aggregates, 1)
  H.eq(aggregate.aggregates[1].size, 1000)
end

T["live_scale_coordinator_requires unique memory checkpoints and fixture identity"] = function()
  local payload = valid_payload(1, 1)
  payload.memory.samples[2].name = "worker_start"
  local valid, errors = coordinator.validate_worker(payload, {
    rows = 1, seed = 1729, run_index = 1,
  })
  H.eq(valid, nil)
  assert(vim.tbl_contains(errors, "duplicate memory sample worker_start"))
  assert(vim.tbl_contains(errors, "missing memory sample after_fixture"))

  payload = valid_payload(1, 1)
  payload.manifest.first_line = "forged"
  valid, errors = coordinator.validate_worker(payload, {
    rows = 1, seed = 1729, run_index = 1,
  })
  H.eq(valid, nil)
  assert(vim.tbl_contains(errors, "fixture first line mismatch"))

  local aggregate = coordinator.execute({
    repetitions = 2,
    sizes = { 1 },
    environment = fake_environment(),
    launch = function(spec)
      local worker = valid_payload(spec.rows, spec.run_index)
      if spec.repetition == 2 then
        worker.manifest.digest = string.rep("b", 64)
      end
      return { code = 0, signal = 0, payload = worker }
    end,
  })
  H.eq(aggregate.status, "fail")
  H.eq(aggregate.failures[1].kind, "fixture_identity")
  H.eq(#aggregate.aggregates, 0)
end

T["live_scale_coordinator_gate failure does not establish capabilities"] = function()
  local aggregate = coordinator.execute({
    repetitions = 1,
    sizes = { 1, 1000 },
    environment = fake_environment(),
    launch = function(spec)
      local payload = valid_payload(spec.rows, spec.run_index)
      if spec.rows == 1 then
        payload.heartbeat.max_gap_ns = 100000001
        payload.capabilities.rss_source = "different"
      end
      return { code = 0, signal = 0, payload = payload }
    end,
  })

  H.eq(vim.tbl_map(function(item) return item.kind end, aggregate.failures),
    { "gate" })
  H.eq(aggregate.samples[2].status, "pass")
  H.eq(aggregate.capabilities.rss_source, "libuv.resident_set_memory")
end

T["live_scale_coordinator_refuses checked in development output"] = function()
  local output = vim.fs.joinpath(
    H.project_root, "docs", "verification", "live-scale.json")
  local ok, err = pcall(coordinator.execute, {
    output = output,
    repetitions = 1,
    sizes = { 1, 1000 },
    environment = fake_environment(),
    launch = function()
      error("checked-in development output must fail before launch")
    end,
  })

  assert(not ok)
  assert(tostring(err):find(
    "non-authoritative or unexpected checked-in output path is forbidden",
    1, true))
end

return T
