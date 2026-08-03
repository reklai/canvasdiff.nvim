local buffer = require("canvasdiff.source.buffer")
local collect = require("canvasdiff.source.collect")
local ref = require("canvasdiff.source.ref")
local repository = require("canvasdiff.source.repository")

-- Repository inspection and changeset collection enter the source domain
-- through this exact facade. Live-buffer and protocol details remain owned by
-- internal modules below it.
-- Unless noted below, every git-touching call here answers its result on
-- success and `nil, err` on failure; the pure ref helpers never error.
return {
  -- Branch records { ref, name, kind, current?, remote_default? }. Full refs
  -- stay the execution identity; short names exist only for display.
  branches = repository.branches,
  -- True when a loaded buffer holds edits git cannot see for this file --
  -- conservatively true once a staged deletion makes identity unprovable.
  -- Never errors.
  buffer_modified = buffer.modified,
  -- Porcelain-v2 records sorted by path, each carrying both halves of the XY
  -- status (`staged`/`unstaged`, nil where the column is ".").
  changed_files = repository.changed_files,
  -- The full refs/heads ref HEAD is attached to, or a bare nil (no message)
  -- for a detached, unborn, or unreadable HEAD.
  current_branch = repository.current_branch,
  diff_files = repository.diff_files,
  -- Lazy collection: an iterator that reads one file's two sides per call --
  -- nil at EOF, `nil, err` at the file that failed. `files` materializes the
  -- same stream, transactionally: the whole list or `nil, err`.
  file_stream = collect.file_stream,
  files = collect.files,
  format_ref = ref.format,
  local_branches = ref.local_branches,
  merge_base = repository.merge_base,
  -- First modified file-backed buffer path under root, or nil. Never errors.
  modified_buffer_in_root = buffer.modified_in_root,
  -- The remote a symbolic remote-default ref names, or a bare nil.
  remote_name = ref.remote_name,
  remote_tracking_branches = ref.remote_tracking,
  resolve_commit = repository.resolve_commit,
  -- The repository toplevel for a directory, or a bare nil (no message).
  root = repository.root,
  -- The streaming and eager section collectors, same contracts as
  -- file_stream/files with each file already built into a section.
  section_stream = collect.section_stream,
  sections = collect.sections,
  set_index_blob = repository.set_index_blob,
  show = repository.show,
  show_head = repository.show_head,
  stage = repository.stage,
  -- Both may answer `true, err`: git reported a failure but the end state
  -- verifies (HEAD landed on the requested ref), so the caller can treat it
  -- as done while still surfacing the message.
  switch_branch = repository.switch_branch,
  track_branch = repository.track_branch,
  tracking_branch_name = ref.tracking_name,
  unstage = repository.unstage,
  -- Always a string: a loaded buffer's possibly-unsaved bytes, else the disk
  -- file, and "" for a deleted or unreadable worktree path. Never errors.
  worktree_text = buffer.read_worktree,
}
