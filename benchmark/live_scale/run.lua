-- CLI entry point for the isolated live Git scale campaign.
--
-- Usage:
--   nvim --headless --clean -n -i NONE -l benchmark/live_scale/run.lua \
--     OUTPUT REPS [SIZES] [BASELINE]

local function absolute(path)
  local resolved = vim.fn.fnamemodify(path, ":p")
  if resolved ~= "/" then
    resolved = resolved:gsub("/+$", "")
  end
  return resolved
end

local script = absolute(debug.getinfo(1, "S").source:sub(2))
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
vim.opt.runtimepath:prepend(repo_root)

local coordinator = require("benchmark.live_scale.coordinator")
local argv = _G.arg or {}
for key, value in pairs(argv) do
  if type(key) == "number" and key >= 5 and value ~= nil then
    error(("unexpected coordinator argument #%d: %s"):format(
      key, tostring(value)), 0)
  end
end

local output = argv[1]
assert(type(output) == "string" and output ~= "",
  "coordinator requires OUTPUT")
assert(type(argv[2]) == "string" and argv[2]:match("^%d+$"),
  "coordinator requires integer REPS between 1 and 20")
local repetitions = tonumber(argv[2])

local sizes
if argv[3] ~= nil and argv[3] ~= "" then
  sizes = {}
  for _, value in ipairs(vim.split(argv[3], ",", { plain = true })) do
    assert(value:match("^%d+$") and value ~= "0",
      "SIZES must be comma-separated positive integers")
    sizes[#sizes + 1] = tonumber(value)
  end
  assert(#sizes > 0, "SIZES must not be empty")
end

local baseline = argv[4]
if baseline == "" then
  baseline = nil
end

local aggregate = coordinator.execute({
  output = output,
  repetitions = repetitions,
  sizes = sizes,
  baseline = baseline,
})
print(coordinator.format_table(aggregate))
print("CanvasDiff live-scale artifact: " .. output)
if aggregate.status ~= "pass" then
  io.stderr:write(("CanvasDiff live-scale failed with %d failure(s)\n")
    :format(#aggregate.failures))
end
os.exit(aggregate.status == "pass" and 0 or 1)
