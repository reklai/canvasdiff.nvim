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
