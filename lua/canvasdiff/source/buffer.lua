local system = require("canvasdiff.os")

local M = {}

--- Find a currently-loaded buffer showing `abs_path`, if any.
local function find_loaded(abs_path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
        and vim.api.nvim_buf_get_name(buf) == abs_path then
      return buf
    end
  end
  return nil
end

local function split_path(path)
  local slashed = path:gsub("\\", "/")
  local prefix, rest
  if slashed:match("^%a:/") then
    prefix, rest = slashed:sub(1, 3), slashed:sub(4)
  elseif slashed:sub(1, 2) == "//" then
    prefix, rest = "//", slashed:sub(3)
  elseif slashed:sub(1, 1) == "/" then
    prefix, rest = "/", slashed:sub(2)
  else
    rest = slashed
  end
  local parts = {}
  for part in rest:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return prefix, parts
end

local function join_parts(prefix, parts)
  local body = table.concat(parts, "/")
  if prefix == "/" or prefix == "//" then
    return prefix .. body
  end
  if prefix then
    return prefix .. body
  end
  return body
end

-- Resolve symlinks one component at a time, before applying a following `..`.
-- Normalizing the whole link destination first is wrong: `dir/..` does not
-- return to the lexical parent when `dir` itself is a symlink.
local function lexical_realpath(path)
  local prefix, pending = split_path(path)
  if not prefix then
    return nil, false
  end
  local resolved = {}
  local expansions = 0
  local traverses_symlink = false
  while #pending > 0 do
    local part = table.remove(pending, 1)
    if part == "." or part == "" then
      -- no-op
    elseif part == ".." then
      resolved[#resolved] = nil
    else
      local candidate_parts = {}
      for i, component in ipairs(resolved) do
        candidate_parts[i] = component
      end
      candidate_parts[#candidate_parts + 1] = part
      local candidate = join_parts(prefix, candidate_parts)
      local lstat = vim.uv.fs_lstat(candidate)
      if lstat and lstat.type == "link" then
        local link = vim.uv.fs_readlink(candidate)
        if not link then
          return nil, true
        end
        traverses_symlink = true
        expansions = expansions + 1
        if expansions > 256 then
          return nil, true
        end
        local link_prefix, link_parts = split_path(link)
        if link_prefix then
          prefix = link_prefix
          resolved = {}
        end
        vim.list_extend(link_parts, pending)
        pending = link_parts
      else
        resolved[#resolved + 1] = part
      end
    end
  end
  return join_parts(prefix, resolved), traverses_symlink
end

--- Whether a loaded target buffer has edits that Git cannot see on disk.
--- @param root string
--- @param file { path: string, old_path: string? }
--- @return boolean
function M.modified(root, file)
  local targets = {}
  for _, rel_path in ipairs({ file and file.path, file and file.old_path }) do
    if type(rel_path) == "string" and rel_path ~= "" then
      local path = vim.fs.joinpath(root, rel_path)
      local stat = vim.uv.fs_stat(path)
      targets[#targets + 1] = {
        normalized = vim.fs.normalize(path),
        lexical = lexical_realpath(path),
        real = vim.uv.fs_realpath(path),
        dev = stat and stat.dev or nil,
        ino = stat and stat.ino or nil,
      }
    end
  end
  local stages_deletion = file and file.unstaged == "D"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
        and vim.api.nvim_get_option_value("modified", { buf = buf }) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local stat = vim.uv.fs_stat(name)
        local normalized = vim.fs.normalize(name)
        local lexical = lexical_realpath(name)
        local real = vim.uv.fs_realpath(name)
        for _, target in ipairs(targets) do
          if normalized == target.normalized
              or (lexical and target.lexical and lexical == target.lexical)
              or (real and target.real and real == target.real)
              or (stat and target.dev ~= nil and target.ino ~= nil
                and stat.dev == target.dev and stat.ino == target.ino) then
            return true
          end
          -- Once a deletion removes the target inode, a hard-link relationship
          -- cannot be disproved from current filesystem state. This includes a
          -- buffer whose alias path was also removed. Refuse conservatively;
          -- existing targets retain exact identity checks above, so unrelated
          -- ordinary edits remain non-blocking.
          if stages_deletion then
            return true
          end
        end
      end
    end
  end
  return false
end

--- Byte-exact text of a loaded buffer, as it sits on disk.
---
--- `nvim_buf_get_lines` returns bare lines: Neovim strips `\r` on read and
--- records it in 'fileformat', and it records a missing final newline in
--- 'endofline'. Reconstructing both preserves the same bytes an unloaded disk
--- read would return. 'fixendofline' is deliberately ignored because it only
--- takes effect when the buffer is written.
local function text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    return ""
  end
  local fileformat = vim.api.nvim_get_option_value("fileformat", { buf = buf })
  local separator = (fileformat == "dos" and "\r\n")
    or (fileformat == "mac" and "\r")
    or "\n"
  local endofline = vim.api.nvim_get_option_value("endofline", { buf = buf })
  return table.concat(lines, separator) .. (endofline and separator or "")
end

--- Current worktree content for a changed file: prefer a loaded buffer's
--- possibly-unsaved lines, else read the file fresh off disk. A deleted or
--- otherwise unreadable worktree path has an empty new side.
---
--- Keep the deliberately forgiving legacy read semantics here: an open/read
--- failure is an empty worktree side and close failures are not promoted.
--- @param root string
--- @param rel_path string
--- @param status string|nil
--- @return string
function M.read_worktree(root, rel_path, status)
  if status == "D" then
    return ""
  end

  local abs_path = vim.fs.joinpath(root, rel_path)
  local buf = find_loaded(abs_path)
  if buf then
    return text(buf)
  end

  local ok, content = pcall(system.read_file, abs_path)
  if not ok or content == nil then
    return ""
  end
  return content
end

return M
