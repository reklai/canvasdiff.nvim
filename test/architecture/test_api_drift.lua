local graph = require("architecture.graph")
local T = {}

-- Neovim marks a C API function deprecated in api_info() releases before it
-- removes it, and nothing at runtime says so: the call keeps working, quietly,
-- until the release that deletes it. CI runs this suite on the stated floor,
-- stable and nightly, so on the nightly lane this turns the first deprecating
-- commit upstream into a failure here, while there is still a release of
-- slack to move. The runtime half of the same tripwire (vim.deprecate) lives
-- in test/run.lua.

local function production_files()
  local files = {}
  for _, dir in ipairs({ "lua", "plugin" }) do
    local base = vim.fs.joinpath(graph.root, dir)
    for name, kind in vim.fs.dir(base, { depth = 10 }) do
      if kind == "file" and name:match("%.lua$") then
        files[#files + 1] = vim.fs.joinpath(base, name)
      end
    end
  end
  table.sort(files)
  return files
end

--- Every `nvim_*` identifier production code names, with the first file that
--- names it. Comments count too: a comment naming an API is a claim about it.
local function used_api()
  local used = {}
  for _, path in ipairs(production_files()) do
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    for name in text:gmatch("nvim_[%l%d_]+") do
      used[name] = used[name] or path:sub(#graph.root + 2)
    end
  end
  return used
end

-- Private `nvim__*` functions are outside api_info() and outside any
-- deprecation cycle. Each one used must name the fallback that keeps the
-- plugin correct when it changes, so a new dependency on one is a decision
-- rather than an accident.
local PRIVATE_WITH_FALLBACK = {
  nvim__redraw = "Projection falls back to :redraw! (test/fault/test_private_api.lua)",
}

T["architecture_ every nvim_* API production code names exists and is not deprecated"] = function()
  local info = {}
  for _, fn in ipairs(vim.fn.api_info().functions) do
    info[fn.name] = fn
  end
  local used = used_api()
  assert(next(used) ~= nil, "the scan found no API use at all -- the walk is broken")
  local problems = {}
  for name, where in pairs(used) do
    local fn = info[name]
    if vim.startswith(name, "nvim__") then
      if not PRIVATE_WITH_FALLBACK[name] then
        problems[#problems + 1] = ("%s (%s): private API with no recorded fallback")
          :format(name, where)
      elseif vim.api[name] == nil then
        -- The fallback is carrying users; this is the maintainer's notice.
        problems[#problems + 1] = ("%s (%s): gone from this Neovim; %s")
          :format(name, where, PRIVATE_WITH_FALLBACK[name])
      end
    elseif not fn then
      problems[#problems + 1] = ("%s (%s): not in this Neovim's API"):format(name, where)
    elseif fn.deprecated_since then
      problems[#problems + 1] = ("%s (%s): deprecated since API level %d")
        :format(name, where, fn.deprecated_since)
    end
  end
  table.sort(problems)
  assert(#problems == 0, ("Neovim %s:\n  %s")
    :format(tostring(vim.version()), table.concat(problems, "\n  ")))
end

return T
