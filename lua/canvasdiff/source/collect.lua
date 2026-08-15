local buffer = require("canvasdiff.source.buffer")
local repository = require("canvasdiff.source.repository")
local diff = require("canvasdiff.diff")
local lens = diff.lens
local model = diff

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
  -- Porcelain's "?" records carry no mode columns: the file exists nowhere
  -- but the worktree. Both committed sides are absent, and the worktree
  -- side's own mode is read later, beside its content.
  local absent = file.status == "?" and "000000" or nil
  local old_mode, new_mode

  if lens.same(l, lens.get("staged")) then
    status = file.staged or status
    old_mode = file.mode_head or absent
    new_mode = file.mode_index or absent
    if file.staged == "R" then
      old_path = file.old_path or path
    elseif file.unstaged == "R" and file.old_path then
      path = file.old_path
      old_path = path
    end
  elseif lens.same(l, lens.get("unstaged")) then
    status = file.unstaged or status
    old_mode = file.mode_index or absent
    new_mode = file.mode_worktree
    if file.unstaged == "R" then
      old_path = file.old_path or path
    end
  else
    -- The all lens sees the complete HEAD -> worktree identity change.
    old_path = file.old_path or path
    old_mode = file.mode_head or absent
    new_mode = file.mode_worktree
  end

  return path, old_path, status, old_mode, new_mode
end

--- All changed files with both sides of the current lens, ready for diff.build.
---
--- Accepts a lens record or, for compatibility, the older `base` string
--- ("HEAD" | "index") that only ever named the old side -- config.options.base and
--- previously-saved sessions still speak it. lens.from_base does the translation.
---
--- Resolve WHICH paths this lens compares, and how each relates to
--- HEAD/index/worktree, without reading a single byte of file content.
---
--- Split from reading, because planning is one bounded round of git plumbing
--- while reading is proportional to the size of the changeset. Keeping them
--- apart is what lets content be read one file at a time.
--- @param root string
--- @param spec CanvasDiffLens|string|nil a lens, a legacy base string, or nil
--- @return table[]|nil plan
--- @return string|nil err
--- @return CanvasDiffLens|nil lens
--- @return string|nil old_rev
local function plan_files(root, spec)
  local l = type(spec) == "table" and spec or lens.from_base(spec)
  if not lens.valid(l) then
    return nil, "invalid lens"
  end
  local is_branch = lens.is_branch(l)
  local is_range = lens.is_range(l)
  local changed
  local old_rev = l.old
  local new_rev

  if is_range then
    local err
    new_rev, err = repository.resolve_commit(root, l.new)
    if not new_rev then
      return nil, err
    end
    if l.old == l.new then
      old_rev = new_rev
    elseif l.operator == "..." then
      old_rev, err = repository.merge_base(root, l.old, new_rev)
    else
      old_rev, err = repository.resolve_commit(root, l.old)
    end
    if not old_rev then
      return nil, err
    end
    changed, err = repository.diff_files(root, old_rev, new_rev)
    if not changed then
      return nil, err
    end
  elseif is_branch then
    local err
    old_rev, err = repository.resolve_commit(root, l.old)
    if not old_rev then
      return nil, err
    end

    changed, err = repository.diff_files(root, old_rev)
    if not changed then
      return nil, err
    end

    -- The ref-relative diff says WHICH paths belong in this comparison.
    -- Porcelain status says how those same paths currently relate to
    -- HEAD/index/worktree, which drives the staged/unstaged sidebar markers.
    -- It also supplies untracked paths, which `git diff <commit>` never emits.
    local status_files
    status_files, err = repository.changed_files(root)
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
          -- ?. It must not retain D, because the buffer owner deliberately
          -- turns a D worktree side into "" without touching the filesystem.
          if existing.status == "D" then
            existing.status = "M"
            -- The diff said the tracked worktree side was gone; the untracked
            -- recreation is invisible to it. Its real mode is read with its
            -- content.
            existing.new_mode = nil
          end
          existing.unstaged = "?"
        else
          existing = {
            path = status.path,
            old_path = status.path,
            status = "?",
            staged = nil,
            unstaged = "?",
            old_mode = "000000",
          }
          changed[#changed + 1] = existing
          by_path[status.path] = existing
        end
      end
    end
  else
    local err
    changed, err = repository.changed_files(root)
    if not changed then
      return nil, err
    end
  end

  local planned = {}
  for _, f in ipairs(changed) do
    local path, old_path, status, old_mode, new_mode
    if is_branch or is_range then
      path = f.path
      old_path = f.old_path or path
      status = f.status
      old_mode = f.old_mode
      new_mode = f.new_mode
    else
      path, old_path, status, old_mode, new_mode = fixed_paths(l, f)
    end
    planned[#planned + 1] = {
      path = path,
      old_path = old_path,
      old_rev = old_rev,
      new_rev = new_rev,
      status = status,
      -- Carried through so the canvas can say WHICH KIND of change each file is,
      -- independently of the lens you happen to be looking through.
      staged = f.staged,
      unstaged = f.unstaged,
      -- The lens pair's modes, "000000" for an absent side, nil when only the
      -- worktree can answer. What lets an equal-blob record (chmod-only, an
      -- empty file appearing) stay a change instead of vanishing.
      old_mode = old_mode,
      new_mode = new_mode,
    }
  end
  -- fixed_paths can remap an unstaged-rename destination back to the index
  -- origin for the staged lens, so porcelain's current-path order is not
  -- necessarily this lens's effective path order.
  table.sort(planned, function(a, b) return a.path < b.path end)
  return planned, nil, l, old_rev
end

--- The worktree-side mode of one path, in git's own index-mode vocabulary,
--- read only for entries whose plan could not know it (untracked files).
local function worktree_mode(root, rel_path)
  local stat = vim.uv.fs_lstat(vim.fs.joinpath(root, rel_path))
  if not stat then
    return "000000"
  end
  if stat.type == "link" then
    return "120000"
  end
  local executable = stat.type == "file"
    and bit.band(stat.mode, tonumber("100", 8)) ~= 0
  return executable and "100755" or "100644"
end

local ABSENT_MODE = "000000"

--- Whether the plan says this side EXISTS in its rev, so a nil read of it is
--- a command failure rather than expected absence. A nil mode means the plan
--- could not know (a caller without porcelain facts), which keeps the
--- historical forgiving read.
local function side_must_exist(mode)
  return mode ~= nil and mode ~= ABSENT_MODE
end

--- Read one planned file's two sides.
--- @return table|nil file
--- @return string|nil err
local function read_file(root, l, entry, is_range)
  if entry.new_mode == nil and l.new == "worktree" then
    entry.new_mode = worktree_mode(root, entry.path)
  end
  local old_text, old_err = repository.show(root, entry.old_rev, entry.old_path)
  if old_text == nil and side_must_exist(entry.old_mode) then
    return nil, ("cannot read old side %s:%s for %s change: %s")
      :format(entry.old_rev, entry.old_path, entry.status,
        old_err or "unknown git error")
  end
  local new_text, new_err
  if is_range then
    new_text, new_err = repository.show(root, entry.new_rev, entry.path)
  else
    new_text, new_err = M.new_side(root, l, entry.path, entry.status)
  end
  if new_text == nil and side_must_exist(entry.new_mode) then
    return nil, ("cannot read new side %s:%s for %s change: %s")
      :format(entry.new_rev or l.new, entry.path, entry.status,
        new_err or "unknown git error")
  end
  return {
    path = entry.path,
    old_path = entry.old_path,
    old_rev = entry.old_rev,
    new_rev = entry.new_rev,
    status = entry.status,
    staged = entry.staged,
    unstaged = entry.unstaged,
    old_mode = entry.old_mode,
    new_mode = entry.new_mode,
    old_text = old_text or "",
    new_text = new_text or "",
  }
end

--- Stream this lens's changed files in path order, reading each file's two
--- sides only when it is asked for.
---
--- The iterator returns `nil` when exhausted and `nil, err` when a side cannot
--- be read -- the same transactional failure `files` reports, surfaced at the
--- file that caused it rather than after the whole changeset was materialized.
--- @param root string
--- @param spec CanvasDiffLens|string|nil
--- @return fun(): table|nil, string|nil next_file
--- @return string|nil err
function M.file_stream(root, spec)
  local planned, err, l = plan_files(root, spec)
  if not planned then
    return nil, err
  end
  local is_range = lens.is_range(l)
  local index = 0
  return function()
    index = index + 1
    local entry = planned[index]
    if not entry then
      return nil
    end
    return read_file(root, l, entry, is_range)
  end
end

--- Every changed file with both its sides, in path order.
---
--- The whole changeset resident at once, which is what the eager canvas needs
--- and what `file_stream` exists to avoid for anything larger.
--- @param root string
--- @param spec CanvasDiffLens|string|nil a lens, a legacy base string, or nil
--- @return table[]|nil files
--- @return string|nil err
function M.files(root, spec)
  local next_file, stream_err = M.file_stream(root, spec)
  if not next_file then
    return nil, stream_err
  end
  local files = {}
  while true do
    local file, read_err = next_file()
    if read_err then
      return nil, read_err
    end
    if not file then
      return files
    end
    files[#files + 1] = file
  end
end

--- Stream this lens's sections in path order, one built section at a time.
---
--- The ingestion boundary: only one file's two sides are resident while its
--- section is built, so a caller that consumes sections as they arrive never
--- holds the whole changeset's text at once. `sections` is the eager consumer.
--- @param root string
--- @param spec CanvasDiffLens|string|nil
--- @param context integer|nil
--- @return fun(): table|nil, string|nil next_section
--- @return string|nil err
function M.section_stream(root, spec, context)
  local next_file, err = M.file_stream(root, spec)
  if not next_file then
    return nil, err
  end
  return function()
    while true do
      local file, read_err = next_file()
      if read_err then
        return nil, read_err
      end
      if not file then
        return nil
      end
      local section = model.build_section(
        file.path, file.old_text, file.new_text, file.status, context, file)
      if section then
        return section
      end
    end
  end
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
  local next_section, err = M.section_stream(root, spec, context)
  if not next_section then
    return nil, err
  end
  local sections = {}
  while true do
    local section, build_err = next_section()
    if build_err then
      return nil, build_err
    end
    if not section then
      break
    end
    sections[#sections + 1] = section
  end
  -- Already in path order from the plan, but sorting is what `model.build`
  -- promised and what watch reconciliation compares against.
  table.sort(sections, function(a, b) return a.path < b.path end)
  return sections
end

--- The lens's NEW side for one path: the worktree as it stands (unsaved buffer
--- content included), or the staged blob.
---
--- Split out because it is the only place the two kinds of new side differ, and
--- because `status` only describes the worktree -- a "D" for a file deleted in the
--- worktree says nothing about whether the index still holds content for it, so the
--- index branch must ask git rather than short-circuit on status.
---
--- An index read returns nil and the git error rather than "": the caller
--- knows from the plan's modes whether that nil is expected absence or a
--- command failure that must abort the collection.
function M.new_side(root, l, path, status)
  if l.new == "worktree" then
    return buffer.read_worktree(root, path, status)
  end
  return repository.show(root, l.new, path)
end

return M
