local git = require("canvasdiff.git")
local util = require("canvasdiff.util")
local lens = require("canvasdiff.lens")
local model = require("canvasdiff.model")

local M = {}

--- The path pair visible through one fixed lens.
---
--- Porcelain's rename record names the worktree destination in `path` and the
--- origin in `old_path`, but those are not the right addresses for every pair
--- of sides:
---
---   all       HEAD old path  -> worktree new path
---   staged    HEAD old path  -> index new path      (when X == R)
---   unstaged  index new path -> worktree new path   (when X == R)
---
--- The mirror case, Y == R, belongs only to the unstaged comparison: the
--- staged lens still addresses the index at the origin. Selecting both the
--- effective new-side path and old-side path here prevents a rename in one
--- half from turning into a fabricated add/delete in the other.
local function fixed_paths(l, file)
  local path = file.path
  local old_path = path
  local status = file.status

  if lens.same(l, lens.named.staged) then
    status = file.staged or status
    if file.staged == "R" then
      old_path = file.old_path or path
    elseif file.unstaged == "R" and file.old_path then
      path = file.old_path
      old_path = path
    end
  elseif lens.same(l, lens.named.unstaged) then
    status = file.unstaged or status
    if file.unstaged == "R" then
      old_path = file.old_path or path
    end
  else
    -- The all lens sees the complete HEAD -> worktree identity change.
    old_path = file.old_path or path
  end

  return path, old_path, status
end

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
--- @param spec CanvasDiffLens|string|nil a lens, a legacy base string, or nil
--- @return table[]|nil files
--- @return string|nil err
function M.files(root, spec)
  local l = type(spec) == "table" and spec or lens.from_base(spec)
  local is_branch = lens.is_branch(l)
  local changed
  local old_rev = l.old

  if is_branch then
    local err
    old_rev, err = git.resolve_commit(root, l.old)
    if not old_rev then
      return nil, err
    end

    changed, err = git.diff_files(root, old_rev)
    if not changed then
      return nil, err
    end

    -- The ref-relative diff says WHICH paths belong in this comparison.
    -- Porcelain status says how those same paths currently relate to
    -- HEAD/index/worktree, which drives the staged/unstaged sidebar markers.
    -- It also supplies untracked paths, which `git diff <commit>` never emits.
    local status_files
    status_files, err = git.changed_files(root)
    if not status_files then
      return nil, err
    end

    local status_by_path = {}
    for _, f in ipairs(status_files) do
      status_by_path[f.path] = f
    end

    local by_path = {}
    for _, f in ipairs(changed) do
      local status = status_by_path[f.path]
      if status then
        f.staged = status.staged
        f.unstaged = status.unstaged
      end
      by_path[f.path] = f
    end

    for _, status in ipairs(status_files) do
      if status.status == "?" then
        local existing = by_path[status.path]
        if existing then
          -- A path deleted from tracked history and recreated as an untracked
          -- worktree file is one old-vs-new comparison, not a D plus a duplicate
          -- ?. It must not retain D, because read_worktree_content deliberately
          -- turns a D new side into "" without touching the filesystem.
          if existing.status == "D" then
            existing.status = "M"
          end
          existing.unstaged = "?"
        else
          existing = {
            path = status.path,
            old_path = status.path,
            status = "?",
            staged = nil,
            unstaged = "?",
          }
          changed[#changed + 1] = existing
          by_path[status.path] = existing
        end
      end
    end
    table.sort(changed, function(a, b) return a.path < b.path end)
  else
    local err
    changed, err = git.changed_files(root)
    if not changed then
      return nil, err
    end
  end

  local files = {}
  for _, f in ipairs(changed) do
    local path, old_path, status
    if is_branch then
      path = f.path
      old_path = f.old_path or path
      status = f.status
    else
      path, old_path, status = fixed_paths(l, f)
    end
    local old_text, old_err = git.show(root, old_rev, old_path)
    if old_text == nil and is_branch and f.status ~= "A" and f.status ~= "?" then
      return nil, ("cannot read old side %s:%s for %s change: %s")
        :format(old_rev, old_path, f.status, old_err or "unknown git error")
    end
    files[#files + 1] = {
      path = path,
      old_path = old_path,
      old_rev = old_rev,
      status = status,
      -- Carried through so the canvas can say WHICH KIND of change each file is,
      -- independently of the lens you happen to be looking through.
      staged = f.staged,
      unstaged = f.unstaged,
      old_text = old_text or "",
      new_text = M.new_side(root, l, path, status),
    }
  end
  -- fixed_paths can remap an unstaged-rename destination back to the index
  -- origin for the staged lens, so porcelain's current-path order is not
  -- necessarily this lens's effective path order.
  table.sort(files, function(a, b) return a.path < b.path end)
  return files
end

--- Collect and build the complete desired section list without mutating a
--- canvas. Open, manual pivots, and file-watch reconciliation all go through
--- this boundary so a failed ref lookup is distinguishable from a valid empty
--- diff before any buffer, lens, view, or UI state is touched.
--- @param root string
--- @param spec CanvasDiffLens|string|nil
--- @param context integer|nil
--- @return table[]|nil sections
--- @return string|nil err
function M.sections(root, spec, context)
  local files, err = M.files(root, spec)
  if not files then
    return nil, err
  end
  return model.build(files, context)
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
