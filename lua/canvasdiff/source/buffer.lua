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

local function absolute(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function within(root, path)
  if root == path then
    return true
  end
  local separator = root:sub(-1) == "/" and "" or "/"
  return path:sub(1, #root + #separator) == root .. separator
end

local function repository_file_buffer(buf)
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
  if buftype ~= "" and buftype ~= "acwrite" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and not name:match("^%a[%w+.-]*://")
end

--- First modified file-backed buffer whose normalized or real path is under root.
--- @param root string
--- @return string|nil
function M.modified_in_root(root)
  if type(root) ~= "string" or root == "" then
    return nil
  end
  local normalized_root = absolute(root)
  local real_root = vim.uv.fs_realpath(normalized_root)
  local paths = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
        and repository_file_buffer(buf)
        and vim.api.nvim_get_option_value("modified", { buf = buf }) then
      local name = vim.api.nvim_buf_get_name(buf)
      local normalized = absolute(name)
      local real = vim.uv.fs_realpath(normalized)
      if within(normalized_root, normalized)
          or (real_root and real and within(real_root, real)) then
        paths[#paths + 1] = normalized
      end
    end
  end
  table.sort(paths)
  return paths[1]
end

local text

--- Every loaded file buffer under `root` holding edits the disk does not:
--- { path, text } with `path` repository-relative and `text` the buffer's
--- byte-exact content, sorted by path. Empty when there are none.
---
--- The set `read_worktree` would answer differently from a disk read for --
--- which is exactly what a snapshot of "the worktree as the review shows it"
--- has to lay over the files on disk.
--- @param root string
--- @return { path: string, text: string }[]
function M.unsaved_in_root(root)
  local out = {}
  if type(root) ~= "string" or root == "" then
    return out
  end
  local normalized_root = absolute(root)
  local real_root = vim.uv.fs_realpath(normalized_root)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
        and repository_file_buffer(buf)
        and vim.api.nvim_get_option_value("modified", { buf = buf }) then
      local normalized = absolute(vim.api.nvim_buf_get_name(buf))
      local real = vim.uv.fs_realpath(normalized)
      local rel
      if normalized ~= normalized_root and within(normalized_root, normalized) then
        rel = vim.fs.relpath(normalized_root, normalized)
      elseif real_root and real and real ~= real_root and within(real_root, real) then
        rel = vim.fs.relpath(real_root, real)
      end
      if rel then
        out[#out + 1] = { path = rel, text = text(buf) }
      end
    end
  end
  table.sort(out, function(a, b) return a.path < b.path end)
  return out
end

--- Byte-exact text of a loaded buffer, as it sits on disk.
---
--- `nvim_buf_get_lines` returns bare lines: Neovim strips `\r` on read and
--- records it in 'fileformat', and it records a missing final newline in
--- 'endofline'. Reconstructing both preserves the same bytes an unloaded disk
--- read would return. 'fixendofline' is deliberately ignored because it only
--- takes effect when the buffer is written.
text = function(buf)
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
  -- Git's content for a symlink is the link PAYLOAD -- the path string itself,
  -- stored as a 120000 blob -- so the payload is what diffs against the
  -- committed side and what staging must write back. A regular read here would
  -- follow the link to the target's bytes instead; so would a loaded buffer at
  -- this path, which shows the target's lines. Dangling and directory links
  -- still carry a payload, so readlink covers them too.
  local lstat = vim.uv.fs_lstat(abs_path)
  if lstat and lstat.type == "link" then
    return vim.uv.fs_readlink(abs_path) or ""
  end
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

--- Replace a worktree file's whole content with `content` (disk-exact bytes).
---
--- The write side of `read_worktree`, and it prefers the same thing: a loaded
--- buffer on the path. Going through the buffer is what makes the rewrite
--- UNDOABLE -- it lands as one change in that buffer's undo history, touching
--- only the lines that differ so marks and extmarks elsewhere survive -- and
--- it is the only route that cannot overwrite unsaved text, because the text
--- being rewritten is the buffer's own.
---
--- Answers how it landed, or nil and a message with nothing changed:
---   "saved"   through a buffer that had no unsaved edits, then written, so
---             disk and buffer agree as they did before
---   "buffer"  through a buffer that already had unsaved edits (or whose
---             write failed -- the second return then says why): the rewrite
---             is in the buffer, and the save stays the user's
---   "disk"    no buffer was loaded; written straight to the file
---
--- Refuses a symlink (its content is the link payload, not a file to rewrite),
--- a buffer that cannot be modified, and a 'fileformat' other than unix/dos.
--- A save is an ordinary `:write` of that buffer: its autocommands run and its
--- own 'fixendofline' decides a missing final newline, as for any save.
--- @param root string
--- @param rel_path string
--- @param content string
--- @return "saved"|"buffer"|"disk"|nil how
--- @return string|nil err
function M.write_worktree(root, rel_path, content)
  local abs_path = vim.fs.joinpath(root, rel_path)
  local lstat = vim.uv.fs_lstat(abs_path)
  if lstat and lstat.type == "link" then
    return nil, rel_path .. " is a symlink"
  end

  local buf = find_loaded(abs_path)
  if not buf then
    local ok, err = pcall(system.write_file, abs_path, content)
    if not ok then
      return nil, tostring(err)
    end
    return "disk"
  end

  local fileformat = vim.api.nvim_get_option_value("fileformat", { buf = buf })
  if fileformat ~= "unix" and fileformat ~= "dos" then
    return nil, ("cannot rewrite a %s-format buffer"):format(fileformat)
  end
  if not vim.api.nvim_get_option_value("modifiable", { buf = buf }) then
    return nil, rel_path .. " is open in a buffer that cannot be modified"
  end

  -- `text` above in reverse: "\n" separates, the terminator survives only as
  -- an empty last field and becomes 'endofline', and a dos buffer's lines
  -- drop the "\r" Neovim strips on read.
  local lines = vim.split(content, "\n", { plain = true })
  local endofline = lines[#lines] == ""
  if endofline then
    table.remove(lines)
  end
  if fileformat == "dos" then
    for i, line in ipairs(lines) do
      if line:sub(-1) == "\r" then
        lines[i] = line:sub(1, -2)
      end
    end
  end

  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local head = 0
  while head < #current and head < #lines
      and current[head + 1] == lines[head + 1] do
    head = head + 1
  end
  local tail = 0
  while tail < #current - head and tail < #lines - head
      and current[#current - tail] == lines[#lines - tail] do
    tail = tail + 1
  end
  local middle = {}
  for i = head + 1, #lines - tail do
    middle[#middle + 1] = lines[i]
  end

  local was_modified = vim.api.nvim_get_option_value("modified", { buf = buf })
  local ok, err = pcall(
    vim.api.nvim_buf_set_lines, buf, head, #current - tail, false, middle)
  if not ok then
    return nil, tostring(err)
  end
  if #lines > 0
      and vim.api.nvim_get_option_value("endofline", { buf = buf }) ~= endofline then
    vim.api.nvim_set_option_value("endofline", endofline, { buf = buf })
  end
  if was_modified then
    return "buffer"
  end
  local wrote, write_err = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent write")
  end)
  if not wrote then
    return "buffer", tostring(write_err)
  end
  return "saved"
end

return M
