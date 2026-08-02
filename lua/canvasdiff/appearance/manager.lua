-- Process-wide highlight authorship and reload owner. Setup validates explicit
-- overrides and installs one ColorScheme callback; ensure applies derived
-- defaults first and explicit overrides second. Default-authorship snapshots
-- permit re-derivation, while override underlays restore definitions an
-- explicit override temporarily displaced.
local groups = require("canvasdiff.appearance.groups")

local M = {}
local authored = {}
local overrides = {}
local override_authored = {}
local underlays = {}
local underlay_known = {}
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
  return vim.api.nvim_get_hl(0, { name = name, link = true, create = false })
end

local function safe_text(value)
  local ok, rendered = pcall(tostring, value)
  return ok and rendered or ("<unprintable %s>"):format(type(value))
end

local function validate(raw)
  local accepted, diagnostics = {}, {}
  if raw == nil then return accepted, diagnostics end
  if type(raw) ~= "table" then
    return accepted, { "highlights must be a table, got " .. type(raw) }
  end
  for name, spec in next, raw do
    local checked, known = pcall(groups.known, name)
    if not checked or not known then
      diagnostics[#diagnostics + 1] =
        "unknown highlight group: " .. safe_text(name)
    elseif spec ~= false and type(spec) ~= "table" then
      diagnostics[#diagnostics + 1] =
        ("highlights.%s must be a table or false, got %s")
          :format(name, type(spec))
    elseif spec ~= false and getmetatable(spec) ~= nil then
      diagnostics[#diagnostics + 1] =
        ("highlights.%s must be a plain table without a metatable"):format(name)
    elseif spec ~= false then
      local forbidden = rawget(spec, "default") ~= nil
        or rawget(spec, "force") ~= nil
      if forbidden then
        diagnostics[#diagnostics + 1] =
          ("highlights.%s cannot set default or force"):format(name)
      else
        local copied, copy = pcall(vim.deepcopy, spec)
        if not copied then
          diagnostics[#diagnostics + 1] =
            ("highlights.%s is invalid: %s"):format(name, safe_text(copy))
        else
          local valid, err = pcall(vim.api.nvim_set_hl, VALIDATE_NS, name, copy)
          if valid then
            accepted[name] = copy
          else
            diagnostics[#diagnostics + 1] =
              ("highlights.%s is invalid: %s"):format(name, safe_text(err))
          end
        end
      end
    end
  end
  table.sort(diagnostics)
  return accepted, diagnostics
end

-- Define one group as a default, replacing only our own prior authorship.
local function set_default(name, value, recover_cleared)
  local existed = vim.fn.hlexists(name) == 1
  local current = readback(name)
  local current_shape = shape(current)
  local spec = vim.tbl_extend("force", vim.deepcopy(value), { default = true })
  if next(current_shape) == nil then
    if not recover_cleared and (authored[name] ~= nil or existed) then
      return -- an ordinary render boundary preserves a foreign empty definition
    end
    if authored[name] ~= nil or existed then spec.force = true end
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

local function apply_defaults(recover_cleared)
  local definitions = groups.definitions()
  for _, name in ipairs(groups.names()) do
    set_default(name, assert(definitions[name], "missing definition: " .. name),
      recover_cleared)
  end
end

local function refresh_underlays()
  for _, name in ipairs(groups.names()) do
    if overrides[name] ~= nil then
      local current = readback(name)
      local prior = override_authored[name]
      if prior == nil or not native_deep_equal(current, prior) then
        underlays[name] = vim.deepcopy(current)
        underlay_known[name] = true
      end
    end
  end
end

local function apply_overrides()
  for _, name in ipairs(groups.names()) do
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

local function ensure(recover_cleared)
  apply_defaults(recover_cleared)
  refresh_underlays()
  apply_overrides()
end

function M.ensure()
  ensure(false)
end

function M.audit(raw)
  local _, diagnostics = validate(raw)
  return diagnostics
end

function M.setup(raw)
  local accepted, diagnostics = validate(raw)

  -- Establish the default layer before remembering what a first override
  -- displaces. This also preserves a colorscheme or direct definition.
  apply_defaults(false)
  for _, name in ipairs(groups.names()) do
    local prior = override_authored[name]
    local current = readback(name)
    if accepted[name] ~= nil then
      if prior == nil or not native_deep_equal(current, prior) then
        underlays[name] = vim.deepcopy(current)
        underlay_known[name] = true
      end
    elseif prior ~= nil then
      if native_deep_equal(current, prior) and underlay_known[name] then
        local exact = vim.deepcopy(underlays[name])
        exact.force = true
        vim.api.nvim_set_hl(0, name, exact)
      end
      override_authored[name] = nil
      underlays[name] = nil
      underlay_known[name] = nil
    end
  end
  overrides = accepted

  local group = vim.api.nvim_create_augroup("canvasdiff.appearance", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "Reapply CanvasDiff defaults and explicit overrides",
    callback = function()
      -- Once a group ID exists, Neovim exposes a colorscheme's explicit empty
      -- exactly like scheme-wide clearing. The event is therefore the recovery
      -- boundary; ordinary ensure() continues to preserve external empties.
      ensure(true)
    end,
  })

  M.ensure()
  return diagnostics
end

return M
