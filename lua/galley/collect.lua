local git = require("galley.git")
local util = require("galley.util")
local lens = require("galley.lens")

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
    return util.buf_text(buf)
  end

  local f = io.open(abs_path, "r")
  if not f then
    return ""
  end
  local content = f:read("*a") or ""
  f:close()
  return content
end

--- All changed files with both sides of the current lens, ready for model.build.
---
--- Accepts a lens record or, for compatibility, the older `base` string
--- ("HEAD" | "index") that only ever named the old side -- config.options.base and
--- previously-saved sessions still speak it. lens.from_base does the translation.
---
--- @param root string
--- @param spec GalleyLens|string|nil a lens, a legacy base string, or nil
function M.files(root, spec)
  local l = type(spec) == "table" and spec or lens.from_base(spec)
  local files = {}
  for _, f in ipairs(git.changed_files(root)) do
    files[#files + 1] = {
      path = f.path,
      status = f.status,
      -- Carried through so the canvas can say WHICH KIND of change each file is,
      -- independently of the lens you happen to be looking through.
      staged = f.staged,
      unstaged = f.unstaged,
      old_text = git.show(root, l.old, f.path) or "",
      new_text = M.new_side(root, l, f.path, f.status),
    }
  end
  return files
end

--- The lens's NEW side for one path: the worktree as it stands (unsaved buffer
--- content included), or the staged blob.
---
--- Split out because it is the only place the two kinds of new side differ, and
--- because `status` only describes the worktree -- a "D" for a file deleted in the
--- worktree says nothing about whether the index still holds content for it, so the
--- index branch must ask git rather than short-circuit on status.
function M.new_side(root, l, path, status)
  if l.new == "worktree" then
    return read_worktree_content(root, path, status)
  end
  return git.show(root, l.new, path) or ""
end

return M
