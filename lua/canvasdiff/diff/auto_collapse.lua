--- Pure classification for smart auto-collapse: decides from path patterns,
--- `.gitattributes` facts, and cheap diff/file stats whether a section should
--- start collapsed and deferred without reading its blobs or running a diff.
---
--- Pure and dependency-free so both `source` (deciding before I/O) and unit
--- tests can call it through the `diff` facade without cycles.
local M = {}

local function escape_lua_pattern(ch)
  return ch:gsub("([%^%$%(%)%%%.%[%]%+%-%?%*])", "%%%1")
end

--- Translate a simple glob (`*` matches any chars, `?` matches one char) into
--- a case-insensitive anchored Lua pattern.
local function glob_to_pattern(glob)
  local parts = { "^" }
  for i = 1, #glob do
    local ch = glob:sub(i, i)
    if ch == "*" then
      parts[#parts + 1] = ".*"
    elseif ch == "?" then
      parts[#parts + 1] = "."
    else
      parts[#parts + 1] = escape_lua_pattern(ch)
    end
  end
  parts[#parts + 1] = "$"
  return table.concat(parts)
end

--- Case-insensitive glob match against `path`. Patterns without `/` match the
--- basename OR the full relative path so `"*lock*"` and `"*.min.js"` catch
--- nested files, while `"vendor/*"` anchors to the path hierarchy.
--- @param path string
--- @param pattern string
--- @return boolean
function M.match_glob(path, pattern)
  if type(path) ~= "string" or type(pattern) ~= "string" or pattern == "" then
    return false
  end
  local lower_path = path:lower()
  local lower_pat = pattern:lower()
  local lua_pat = glob_to_pattern(lower_pat)
  if lower_path:match(lua_pat) ~= nil then
    return true
  end
  if not lower_pat:find("/", 1, true) then
    local base = lower_path:match("[^/]+$") or lower_path
    if base:match(lua_pat) ~= nil then
      return true
    end
  end
  return false
end

--- Decide whether a file should be auto-collapsed before diffing.
--- Returns `"generated"` | `"large"` | `nil`.
--- @param path string
--- @param stats { adds?: integer, dels?: integer, bytes?: integer, binary?: boolean }|nil
--- @param attrs { generated?: boolean, no_diff?: boolean, binary?: boolean }|nil
--- @param opts table|nil
--- @return "generated"|"large"|nil
function M.classify(path, stats, attrs, opts)
  if type(opts) ~= "table" or opts.enabled == false then
    return nil
  end
  if opts.gitattributes ~= false and type(attrs) == "table" then
    if attrs.generated or attrs.no_diff then
      return "generated"
    end
  end
  if type(opts.patterns) == "table" then
    for _, pat in ipairs(opts.patterns) do
      if M.match_glob(path, pat) then
        return "generated"
      end
    end
  end
  if type(stats) == "table" then
    local max_lines = opts.max_lines
    if type(max_lines) == "number" and max_lines > 0 then
      if (stats.adds or 0) + (stats.dels or 0) > max_lines then
        return "large"
      end
    end
    local max_bytes = opts.max_bytes
    if type(max_bytes) == "number" and max_bytes > 0 then
      if (stats.bytes or 0) > max_bytes then
        return "large"
      end
    end
  end
  return nil
end

return M
