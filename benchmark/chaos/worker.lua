-- One isolated chaos campaign.
--
-- Launched by benchmark/chaos/run.lua in a fresh `nvim --headless --clean`.
-- This file runs the campaign, publishes JSON, and judges nothing: the
-- coordinator owns the gates, so a worker cannot pass itself.

local uv = vim.uv

local function absolute(path)
  return (vim.fn.fnamemodify(path, ":p"):gsub("/+$", ""))
end

local script = absolute(debug.getinfo(1, "S").source:sub(2))
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
local output_path = _G.arg and _G.arg[1] and absolute(_G.arg[1]) or nil
local seed = tonumber(_G.arg and _G.arg[2])
local actions = tonumber(_G.arg and _G.arg[3])
local harness = _G.arg and _G.arg[4] or "engine"

local result = {
  schema_version = 1,
  benchmark = "canvasdiff.chaos_campaign",
  profile = "paged-engine-chaos-v1",
  seed = seed,
  requested_actions = actions,
  harness = harness,
  status = "fail",
}

local function atomic_json(path, value)
  local directory = vim.fs.dirname(path)
  assert(vim.fn.mkdir(directory, "p") == 1 or vim.fn.isdirectory(directory) == 1,
    "could not create directory: " .. directory)
  local temporary = ("%s.tmp.%d"):format(path, vim.fn.getpid())
  local file = assert(io.open(temporary, "wb"))
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    file:close()
    vim.fn.delete(temporary)
    error("could not encode campaign JSON: " .. tostring(encoded), 0)
  end
  file:write(encoded, "\n")
  assert(file:close())
  local renamed, rename_err = uv.fs_rename(temporary, path)
  if not renamed then
    vim.fn.delete(temporary)
    error(("could not publish %s: %s"):format(path, rename_err or "rename failed"), 0)
  end
end

local ok, failure = xpcall(function()
  assert(output_path, "worker requires an output path")
  assert(seed and seed == math.floor(seed), "worker requires an integer seed")
  assert(actions and actions >= 1, "worker requires an action count")

  vim.opt.runtimepath:prepend(repo_root)
  package.path = repo_root .. "/test/?.lua;"
    .. repo_root .. "/test/?/init.lua;" .. package.path

  assert(harness == "engine" or harness == "surface",
    "harness must be engine or surface")
  -- The two campaigns test different layers and neither subsumes the other:
  -- the engine one drives stores and projections, the surface one drives the
  -- real entry points against a real Git fixture.
  local Chaos = require(harness == "surface"
    and "fault.chaos_surface" or "fault.chaos")

  local started = uv.hrtime()
  local campaign = Chaos.run({
    seed = seed,
    actions = actions,
    window = vim.api.nvim_get_current_win(),
  })
  result.wall_ns = uv.hrtime() - started

  result.campaign_status = campaign.status
  result.completed_actions = campaign.actions
  result.final_rows = campaign.rows
  result.counts = campaign.counts
  result.refusals = campaign.refusals
  result.failed_at = campaign.failed_at
  result.failed_action = campaign.failed_action
  result.campaign_error = campaign.error
  result.history = campaign.history

  local distinct = 0
  for _ in pairs(campaign.counts or {}) do
    distinct = distinct + 1
  end
  result.distinct_actions = distinct
  result.available_actions = #Chaos.action_names
  result.action_names = Chaos.action_names

  result.status = campaign.status == "ok" and "ok" or "fail"
end, debug.traceback)

if not ok then
  result.status = "fail"
  result.error = tostring(failure)
end

if output_path then
  atomic_json(output_path, result)
end
os.exit(result.status == "ok" and 0 or 1)
