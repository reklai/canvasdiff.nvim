local M = {}

local AUTHORITATIVE_SIZES = { 1, 1000, 10000, 100000, 1000000 }

local IDENTITY_PATHS = {
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

function M.finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function value_at(subject, path)
  local value = subject
  for segment in path:gmatch("[^.]+") do
    if type(value) ~= "table" then
      return nil
    end
    value = value[segment]
  end
  return value
end

function M.summary(values)
  assert(type(values) == "table" and #values > 0,
    "metrics.summary requires at least one sample")

  local sorted = {}
  for index, value in ipairs(values) do
    assert(M.finite(value), "metrics.summary requires finite samples")
    sorted[index] = value
  end
  table.sort(sorted)

  local function quantile(percentile)
    local rank = math.max(1, math.ceil(percentile * #sorted))
    return sorted[rank]
  end

  return {
    count = #sorted,
    p50 = quantile(0.5),
    p95 = quantile(0.95),
    max = sorted[#sorted],
  }
end

function M.compatible(current, baseline)
  local reasons = {}
  for _, path in ipairs(IDENTITY_PATHS) do
    local current_value = value_at(current, path)
    local baseline_value = value_at(baseline, path)
    if path == "authoritative_sizes" then
      if not vim.deep_equal(current_value, AUTHORITATIVE_SIZES)
          or not vim.deep_equal(baseline_value, AUTHORITATIVE_SIZES) then
        reasons[#reasons + 1] = path
      end
    elseif not vim.deep_equal(current_value, baseline_value) then
      reasons[#reasons + 1] = path
    end
  end
  if #reasons > 0 then
    return nil, reasons
  end
  return true, reasons
end

local function aggregate_by_size(aggregate)
  local by_size = {}
  for _, row in ipairs(aggregate.aggregates or {}) do
    by_size[row.size] = row
  end
  return by_size
end

function M.compare(current, baseline)
  local compatible, reasons = M.compatible(current, baseline)
  if not compatible then
    return nil, reasons
  end

  local comparison = {}
  local current_by_size = aggregate_by_size(current)
  local baseline_by_size = aggregate_by_size(baseline)
  for _, size in ipairs(AUTHORITATIVE_SIZES) do
    local current_row = current_by_size[size]
    local baseline_row = baseline_by_size[size]
    if current_row and baseline_row then
      local operations = vim.tbl_keys(current_row.operations or {})
      table.sort(operations)
      for _, operation in ipairs(operations) do
        local current_summary = current_row.operations[operation]
        local baseline_summary = (baseline_row.operations or {})[operation]
        if current_summary and baseline_summary then
          local current_value = current_summary.p95
          local baseline_value = baseline_summary.p95
          comparison[#comparison + 1] = {
            size = current_row.size,
            operation = operation,
            current = current_value,
            baseline = baseline_value,
            ratio = current_value / baseline_value,
            percent = (current_value / baseline_value - 1) * 100,
          }
        end
      end
    end
  end
  return comparison
end

return M
