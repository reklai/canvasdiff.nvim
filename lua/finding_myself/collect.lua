local git = require("finding_myself.git")

local M = {}

--- Find a currently-loaded buffer showing `abs_path`, if any.
local function find_loaded_buf(abs_path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs_path then
      return b
    end
  end
  return nil
end

--- Current worktree content for a changed file: prefer a loaded buffer's
--- (possibly unsaved) lines, else read the file fresh off disk, else ""
--- when the file has been deleted or is otherwise unreadable.
local function read_worktree_content(root, rel_path, status)
  if status == "D" then
    return ""
  end

  local abs_path = vim.fs.joinpath(root, rel_path)
  local buf = find_loaded_buf(abs_path)
  if buf then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines == 0 or (#lines == 1 and lines[1] == "") then
      return ""
    end
    return table.concat(lines, "\n") .. "\n"
  end

  local f = io.open(abs_path, "r")
  if not f then
    return ""
  end
  local content = f:read("*a") or ""
  f:close()
  return content
end

--- All changed files with their HEAD and worktree contents, ready for
--- model.build.
function M.files(root)
  local files = {}
  for _, f in ipairs(git.changed_files(root)) do
    files[#files + 1] = {
      path = f.path,
      status = f.status,
      old_text = git.show_head(root, f.path) or "",
      new_text = read_worktree_content(root, f.path, f.status),
    }
  end
  return files
end

return M
