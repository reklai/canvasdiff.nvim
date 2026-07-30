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

--- Non-symbolic remote-tracking branches in source order.
--- @param items table[]
--- @return table[]
function M.remote_tracking(items)
  return filtered_copy(items, function(item)
    return type(item) == "table"
      and item.kind == "remote"
      and not item.remote_default
      and M.remote_name(item) == nil
  end)
end

--- The branch path after `<remote>/`, derived only from the full ref.
--- @param item table
--- @return string|nil
--- @return string|nil
function M.tracking_name(item)
  if type(item) ~= "table" or item.kind ~= "remote" then
    return nil, "expected a remote-tracking branch record"
  end
  if type(item.ref) ~= "string" then
    return nil, "remote-tracking branch ref is malformed"
  end
  local name = item.ref:match("^refs/remotes/[^/]+/(.+)$")
  if not name then
    return nil, "remote-tracking branch ref is malformed"
  end
  if item.remote_default or name == "HEAD" then
    return nil, "symbolic remote default has no tracking branch name"
  end
  return name
end

return M
