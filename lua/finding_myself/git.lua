local M = {}

--- Run `git -C dir <args...>` synchronously.
local function run(dir, args)
  local cmd = { "git", "-C", dir }
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  return vim.system(cmd, { text = true }):wait()
end

--- @param dir string
--- @return string|nil
function M.root(dir)
  local res = run(dir, { "rev-parse", "--show-toplevel" })
  if res.code ~= 0 or not res.stdout then
    return nil
  end
  local out = res.stdout:gsub("%s+$", "")
  if out == "" then
    return nil
  end
  return out
end

-- Given the XY status pair of a porcelain v2 "1" (ordinary) record, pick the
-- worktree column when it's not ".", else fall back to the index column.
local function ordinary_status(xy)
  local index_char = xy:sub(1, 1)
  local worktree_char = xy:sub(2, 2)
  if worktree_char ~= "." then
    return worktree_char
  end
  return index_char
end

--- @param root string
--- @return { path: string, status: string }[]
function M.changed_files(root)
  local res = run(root, { "status", "--porcelain=v2", "-z", "--untracked-files=all" })
  if res.code ~= 0 or not res.stdout or res.stdout == "" then
    return {}
  end

  local tokens = vim.split(res.stdout, "\0", { plain = true })
  if tokens[#tokens] == "" then
    table.remove(tokens)
  end

  local files = {}
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    local kind = tok:sub(1, 1)

    if kind == "1" then
      -- "1 XY sub mH mI mW hH hI path"
      local xy, sub, path = tok:match("^1 (%S+) (%S+) %S+ %S+ %S+ %S+ %S+ (.*)$")
      if xy and sub:sub(1, 1) ~= "S" then
        files[#files + 1] = { path = path, status = ordinary_status(xy) }
      end
      i = i + 1
    elseif kind == "2" then
      -- "2 XY sub mH mI mW hH hI Xscore newpath" NUL "origpath"
      local sub, newpath = tok:match("^2 %S+ (%S+) %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
      -- consume the origpath token unconditionally so it never leaks into
      -- the next iteration as a bogus record.
      i = i + 2
      if sub and sub:sub(1, 1) ~= "S" then
        files[#files + 1] = { path = newpath, status = "R" }
      end
    elseif kind == "?" then
      local path = tok:match("^%? (.*)$")
      if path then
        files[#files + 1] = { path = path, status = "?" }
      end
      i = i + 1
    else
      -- Unhandled record kind (e.g. "u" unmerged, "!" ignored): skip.
      i = i + 1
    end
  end

  table.sort(files, function(a, b) return a.path < b.path end)
  return files
end

--- @param root string
--- @param path string
--- @return string|nil
function M.show_head(root, path)
  local res = run(root, { "show", "HEAD:" .. path })
  if res.code ~= 0 or res.stdout == nil then
    return nil
  end
  return res.stdout
end

return M
