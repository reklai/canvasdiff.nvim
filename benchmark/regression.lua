-- The small-canvas regression gate.
--
-- Usage:
--   nvim --headless --clean -n -i NONE -l benchmark/regression.lua \
--     <baseline.json> <current.json> [tolerance-percent]
--
-- The journey's requirement is that making the million-row canvas fast must
-- not make the ordinary small review slower: at most a 10% regression against
-- the frozen eager baseline. That is a comparison, not a measurement, so this
-- process measures nothing -- it reads two aggregates produced by
-- `benchmark/run.lua` and judges one against the other.
--
-- Both files are untrusted input. A malformed baseline must fail the gate
-- rather than silently pass it, because a gate that cannot read its own
-- reference is not a gate.

local BENCHMARK = "canvasdiff.eager_small_open"
local DEFAULT_TOLERANCE_PERCENT = 10

-- Wall time is the regression the requirement is about. The memory deltas are
-- compared too, because an open that got faster by retaining more is not an
-- improvement, and reporting only the timing would hide that trade.
local COMPARED = {
  { name = "open_wall_ns", label = "open wall time" },
  { name = "close_wall_ns", label = "close wall time" },
  { name = "rss_retained_delta_bytes", label = "retained RSS" },
  { name = "lua_heap_retained_delta_bytes", label = "retained Lua heap" },
}

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function read_aggregate(path, label)
  local file = io.open(path, "rb")
  assert(file, ("could not open the %s aggregate: %s"):format(label, path))
  local content = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, content)
  assert(ok and type(decoded) == "table",
    ("the %s aggregate is not valid JSON: %s"):format(label, path))
  assert(decoded.benchmark == BENCHMARK,
    ("the %s aggregate is not %s"):format(label, BENCHMARK))
  assert(decoded.status == "pass",
    ("the %s aggregate did not pass: %s"):format(label, tostring(decoded.status)))
  assert(type(decoded.aggregate) == "table",
    ("the %s aggregate has no metric summaries"):format(label))
  return decoded
end

local baseline_path = _G.arg and _G.arg[1]
local current_path = _G.arg and _G.arg[2]
local raw_tolerance = _G.arg and _G.arg[3]
assert(baseline_path and current_path,
  "usage: regression.lua <baseline.json> <current.json> [tolerance-percent]")
assert(not (_G.arg and _G.arg[4]),
  "unexpected extra argument: " .. tostring(_G.arg and _G.arg[4]))

local tolerance = DEFAULT_TOLERANCE_PERCENT
if raw_tolerance ~= nil and raw_tolerance ~= "" then
  tolerance = tonumber(raw_tolerance)
  assert(finite(tolerance) and tolerance >= 0 and tolerance <= 100,
    "tolerance must be a percentage between 0 and 100")
end

local baseline = read_aggregate(baseline_path, "baseline")
local current = read_aggregate(current_path, "current")

-- Comparing across different fixtures would compare nothing. The eager lane
-- already digests its corpus, so a mismatch is a hard error rather than a
-- regression verdict.
local baseline_corpus = baseline.corpus and baseline.corpus.digest
local current_corpus = current.corpus and current.corpus.digest
if baseline_corpus and current_corpus then
  assert(baseline_corpus == current_corpus,
    "baseline and current measured different fixtures; the comparison is meaningless")
end

local failures = {}
print(("small eager regression gate: at most %.1f%% against %s")
  :format(tolerance, baseline_path))
print(("%-22s %14s %14s %9s"):format("metric", "baseline", "current", "change"))

for _, metric in ipairs(COMPARED) do
  local before = baseline.aggregate[metric.name]
  local after = current.aggregate[metric.name]
  assert(type(before) == "table" and finite(before.median),
    ("the baseline has no median for %s"):format(metric.name))
  assert(type(after) == "table" and finite(after.median),
    ("the current run has no median for %s"):format(metric.name))

  -- A baseline of zero cannot be exceeded by a percentage, so the only honest
  -- verdict there is "did it become nonzero".
  local change_percent
  if before.median == 0 then
    change_percent = after.median == 0 and 0 or math.huge
  else
    change_percent = (after.median - before.median) / before.median * 100
  end
  local verdict = change_percent > tolerance and "FAIL" or "ok"
  if verdict == "FAIL" then
    failures[#failures + 1] = ("%s regressed %.1f%% (%s -> %s)"):format(
      metric.label, change_percent,
      tostring(before.median), tostring(after.median))
  end
  print(("%-22s %14s %14s %8.1f%% %s"):format(
    metric.name, tostring(before.median), tostring(after.median),
    change_percent, verdict))
end

if #failures > 0 then
  print("")
  for _, message in ipairs(failures) do
    print("  - " .. message)
  end
  os.exit(1)
end
print("\nno metric regressed beyond the tolerance")
os.exit(0)
