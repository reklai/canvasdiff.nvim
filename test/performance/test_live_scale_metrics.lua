local H = require("helpers")
local metrics = require("benchmark.live_scale.metrics")

local T = {}

local function aggregate()
  return {
    schema = "canvasdiff.live_scale/v1",
    profile = "live-git-v1",
    authoritative_sizes = { 1, 1000, 10000, 100000, 1000000 },
    repetitions = 3,
    seed = 1729,
    fixture = {
      digest = "fixture-sha256",
      schema = "fixture/v1",
    },
    config_digest = "config-sha256",
    host_fingerprint = "nvim=0.10;luajit=2.1;git=2.46",
    capabilities = {
      rss_source = "uv.resident_set_memory",
      hwm_source = "procfs.VmHWM",
      procfs = true,
      paged_canvas = true,
    },
    provenance = {
      source_revision = "0123456789abcdef",
      tree_digest = "abcdef0123456789",
    },
    aggregates = vim.tbl_map(function(size)
      return {
        size = size,
        operations = {
          open = { p95 = 10 },
        },
      }
    end, { 1, 1000, 10000, 100000, 1000000 }),
  }
end

T["live_scale_metrics_summary uses nearest-rank quantiles without mutating samples"] = function()
  local samples = { 9, 1, 5, 3, 7 }

  H.eq(metrics.summary(samples), {
    count = 5, p50 = 5, p95 = 9, max = 9,
  })
  H.eq(samples, { 9, 1, 5, 3, 7 }, "summary must not sort the caller's table")
end

T["live_scale_metrics_summary rejects empty and non-finite samples"] = function()
  for _, samples in ipairs({
    {},
    { 0 / 0 },
    { math.huge },
    { -math.huge },
  }) do
    local ok = pcall(metrics.summary, samples)
    assert(not ok, "summary must reject invalid samples")
  end
  assert(metrics.finite(1.5))
  assert(not metrics.finite(0 / 0))
  assert(not metrics.finite(math.huge))
end

T["live_scale_metrics_compatible checks every binding identity path in order"] = function()
  local current = aggregate()
  local baseline = aggregate()
  local paths = {
    "schema",
    "profile",
    "authoritative_sizes",
    "repetitions",
    "seed",
    "fixture.digest",
    "fixture.schema",
    "config_digest",
    "host_fingerprint",
    "capabilities.rss_source",
    "capabilities.hwm_source",
    "capabilities.procfs",
    "capabilities.paged_canvas",
  }

  for _, path in ipairs(paths) do
    local changed = vim.deepcopy(baseline)
    local cursor = changed
    local segments = vim.split(path, ".", { plain = true })
    for index = 1, #segments - 1 do
      cursor = cursor[segments[index]]
    end
    local field = segments[#segments]
    if type(cursor[field]) == "table" then
      cursor[field] = { "different" }
    else
      cursor[field] = "different"
    end

    local compatible, reasons = metrics.compatible(current, changed)
    assert(not compatible, path .. " must bind compatibility")
    H.eq(reasons, { path })
  end

  baseline.schema = "different"
  baseline.seed = 1
  baseline.capabilities.hwm_source = "different"
  baseline.capabilities.procfs = false
  local compatible, reasons = metrics.compatible(current, baseline)
  assert(not compatible)
  H.eq(reasons, {
    "schema",
    "seed",
    "capabilities.hwm_source",
    "capabilities.procfs",
  })
end

T["live_scale_metrics_compatible records provenance without treating it as identity"] = function()
  local current = aggregate()
  local baseline = aggregate()
  baseline.provenance.source_revision = "new-revision"
  baseline.provenance.tree_digest = "new-tree"

  local compatible, reasons = metrics.compatible(current, baseline)
  assert(compatible)
  H.eq(reasons, {})
end

T["live_scale_metrics_compatible requires the canonical authoritative size order"] = function()
  local current = aggregate()
  local baseline = aggregate()
  local reordered = { 1000, 1, 10000, 100000, 1000000 }
  current.authoritative_sizes = reordered
  baseline.authoritative_sizes = vim.deepcopy(reordered)

  local compatible, reasons = metrics.compatible(current, baseline)
  assert(not compatible, "two matching malformed size lists must still be incompatible")
  H.eq(reasons, { "authoritative_sizes" })
end

T["live_scale_metrics_compare reports p95 ratios for compatible aggregates"] = function()
  local current = aggregate()
  local baseline = aggregate()
  baseline.aggregates[1].operations.open.p95 = 8

  local comparison = assert(metrics.compare(current, baseline))
  H.eq(#comparison, 5)
  H.eq(comparison[1], {
    size = 1,
    operation = "open",
    current = 10,
    baseline = 8,
    ratio = 1.25,
    percent = 25,
  })
end

T["live_scale_metrics_compare orders rows by authoritative size rather than aggregate input order"] = function()
  local current = aggregate()
  local baseline = aggregate()
  current.aggregates = {
    { size = 1000, operations = { open = { p95 = 20 } } },
    { size = 1, operations = { open = { p95 = 10 } } },
    { size = 10000, operations = { open = { p95 = 30 } } },
    { size = 100000, operations = { open = { p95 = 40 } } },
    { size = 1000000, operations = { open = { p95 = 50 } } },
  }
  baseline.aggregates = {
    { size = 1000, operations = { open = { p95 = 10 } } },
    { size = 1, operations = { open = { p95 = 8 } } },
    { size = 10000, operations = { open = { p95 = 15 } } },
    { size = 100000, operations = { open = { p95 = 20 } } },
    { size = 1000000, operations = { open = { p95 = 25 } } },
  }

  H.eq(metrics.compare(current, baseline), {
    { size = 1, operation = "open", current = 10, baseline = 8, ratio = 1.25, percent = 25 },
    { size = 1000, operation = "open", current = 20, baseline = 10, ratio = 2, percent = 100 },
    { size = 10000, operation = "open", current = 30, baseline = 15, ratio = 2, percent = 100 },
    { size = 100000, operation = "open", current = 40, baseline = 20, ratio = 2, percent = 100 },
    { size = 1000000, operation = "open", current = 50, baseline = 25, ratio = 2, percent = 100 },
  })
end

T["live_scale_metrics_compare rejects missing sizes and operations"] = function()
  local current = aggregate()
  local baseline = aggregate()
  current.aggregates = {}
  baseline.aggregates = {}
  for _, size in ipairs({ 1, 1000, 10000, 100000, 1000000 }) do
    current.aggregates[#current.aggregates + 1] = {
      size = size,
      operations = { open = { p95 = size + 10 } },
    }
    baseline.aggregates[#baseline.aggregates + 1] = {
      size = size,
      operations = { open = { p95 = size + 5 } },
    }
  end

  local missing_size = vim.deepcopy(baseline)
  table.remove(missing_size.aggregates)
  local rows, reasons = metrics.compare(current, missing_size)
  H.eq(rows, nil)
  H.eq(reasons, { "baseline.aggregates[1000000]" })

  local missing_operation = vim.deepcopy(baseline)
  missing_operation.aggregates[1].operations.open = nil
  rows, reasons = metrics.compare(current, missing_operation)
  H.eq(rows, nil)
  H.eq(reasons, { "baseline.aggregates[1].operations.open.p95" })
end

return T
