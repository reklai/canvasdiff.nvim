local groups = require("canvasdiff.appearance.groups")

local M = {}
local authored = {}
local overrides = {}
local override_authored = {}
local VALIDATE_NS = vim.api.nvim_create_namespace("canvasdiff.appearance.validate")
local native_deep_equal = vim.deep_equal

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

local function validate(raw)
  local accepted, diagnostics = {}, {}
  if raw == nil then return accepted, diagnostics end
  if type(raw) ~= "table" then
    return accepted, { "highlights must be a table, got " .. type(raw) }
  end
  for name, spec in pairs(raw) do
    if not groups.known(name) then
      diagnostics[#diagnostics + 1] =
        "unknown highlight group: " .. tostring(name)
    elseif spec ~= false and type(spec) ~= "table" then
      diagnostics[#diagnostics + 1] =
        ("highlights.%s must be a table or false, got %s")
          :format(name, type(spec))
    elseif spec ~= false and (spec.default ~= nil or spec.force ~= nil) then
      diagnostics[#diagnostics + 1] =
        ("highlights.%s cannot set default or force"):format(name)
    elseif spec ~= false then
      local copied, copy = pcall(vim.deepcopy, spec)
      if not copied then
        diagnostics[#diagnostics + 1] =
          ("highlights.%s is invalid: %s"):format(name, tostring(copy))
      else
        local valid, err = pcall(vim.api.nvim_set_hl, VALIDATE_NS, name, copy)
        if valid then
          accepted[name] = copy
        else
          diagnostics[#diagnostics + 1] =
            ("highlights.%s is invalid: %s"):format(name, tostring(err))
        end
      end
    end
  end
  table.sort(diagnostics)
  return accepted, diagnostics
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
        or not native_deep_equal(current_shape, authored[name]) then
      return -- colorscheme or direct user definition owns it
    end
    if native_deep_equal(current_shape, shape(spec)) then
      return
    end
    spec.force = true
  end
  vim.api.nvim_set_hl(0, name, spec)
  authored[name] = shape(readback(name))
end

function M.ensure()
  local definitions = groups.definitions()
  local names = groups.names()
  for _, name in ipairs(names) do
    set_default(name, assert(definitions[name], "missing definition: " .. name))
  end
  for _, name in ipairs(names) do
    local spec = overrides[name]
    if spec then
      local marked = vim.tbl_extend("force", vim.deepcopy(spec), {
        default = true,
        force = true,
      })
      vim.api.nvim_set_hl(0, name, marked)
      override_authored[name] = readback(name)
    end
  end
end

function M.audit(raw)
  local _, diagnostics = validate(raw)
  return diagnostics
end

function M.setup(raw)
  local accepted, diagnostics = validate(raw)

  for _, name in ipairs(groups.names()) do
    local prior = override_authored[name]
    if prior ~= nil and accepted[name] == nil then
      if native_deep_equal(readback(name), prior) then
        vim.api.nvim_set_hl(0, name, {})
      end
      override_authored[name] = nil
    end
  end
  overrides = accepted

  local group = vim.api.nvim_create_augroup("canvasdiff.appearance", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "Reapply CanvasDiff defaults and explicit overrides",
    callback = function() M.ensure() end,
  })

  M.ensure()
  return diagnostics
end

return M
