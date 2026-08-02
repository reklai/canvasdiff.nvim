local groups = require("canvasdiff.appearance.groups")

local M = {}
local authored = {}

-- `default` is a write instruction rather than part of the appearance, while
-- `force` is only how an authored default replaces its own stale value.
local function shape(definition)
  local out = {}
  for key, value in pairs(definition or {}) do
    if key ~= "default" and key ~= "force" then
      out[key] = value
    end
  end
  return out
end

local function readback(name)
  return vim.api.nvim_get_hl(0, { name = name, link = true })
end

-- Define one group as a default, replacing only our own prior authorship.
local function set_default(name, value)
  local current = readback(name)
  local current_shape = shape(current)
  local spec = vim.tbl_extend("force", vim.deepcopy(value), { default = true })
  if next(current_shape) == nil and authored[name] ~= nil then
    spec.force = true
  end
  if next(current_shape) ~= nil then
    if current.default ~= true
        or not vim.deep_equal(current_shape, authored[name]) then
      return -- colorscheme or direct user definition owns it
    end
    if vim.deep_equal(current_shape, shape(spec)) then
      return
    end
    spec.force = true
  end
  vim.api.nvim_set_hl(0, name, spec)
  authored[name] = shape(readback(name))
end

function M.ensure()
  local definitions = groups.definitions()
  for _, name in ipairs(groups.names()) do
    set_default(name, assert(definitions[name], "missing definition: " .. name))
  end
end

function M.audit(_) return {} end
function M.setup(_) M.ensure(); return {} end

return M
