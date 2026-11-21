--- Pure role and display semantics for branch records.
local M = {}

local function copy(item)
  local out = {}
  for key, value in pairs(item) do
    out[key] = value
  end
  return out
end

--- The remote name represented by a symbolic remote-default ref.
--- @param item table
--- @return string|nil
function M.remote_name(item)
  if type(item) ~= "table" or type(item.ref) ~= "string" then
    return nil
  end
  return item.ref:match("^refs/remotes/([^/]+)/HEAD$")
end

--- Human-facing branch text; execution continues to use `item.ref`.
--- @param item table
--- @return string
function M.format(item)
  local name = type(item) == "table" and item.name or ""
  if item.current then
    return name .. " [checked out]"
  end
  if item.remote_default then
    local remote = M.remote_name(item)
    if remote then
      return ("%s [default for %s]"):format(name, remote)
    end
  end
  if item.kind == "remote" then
    return name .. " [remote-tracking ref]"
  end
  return name
end

local function filtered_copy(items, include)
  local out = {}
  for _, item in ipairs(type(items) == "table" and items or {}) do
    if include(item) then
      out[#out + 1] = copy(item)
    end
  end
  return out
end

--- Local branches in source order, copied away from the repository records.
--- @param items table[]
--- @return table[]
function M.local_branches(items)
  return filtered_copy(items, function(item)
    return type(item) == "table" and item.kind == "local"
  end)
end

return M
