local buffer = require("canvasdiff.source.buffer")
local collect = require("canvasdiff.source.collect")
local ref = require("canvasdiff.source.ref")
local repository = require("canvasdiff.source.repository")

-- Repository inspection and changeset collection enter the source domain
-- through this exact facade. Live-buffer and protocol details remain owned by
-- internal modules below it.
return {
  branches = repository.branches,
  buffer_modified = buffer.modified,
  changed_files = repository.changed_files,
  diff_files = repository.diff_files,
  file_stream = collect.file_stream,
  files = collect.files,
  format_ref = ref.format,
  local_branches = ref.local_branches,
  merge_base = repository.merge_base,
  remote_name = ref.remote_name,
  remote_tracking_branches = ref.remote_tracking,
  resolve_commit = repository.resolve_commit,
  root = repository.root,
  section_stream = collect.section_stream,
  sections = collect.sections,
  show = repository.show,
  show_head = repository.show_head,
  stage = repository.stage,
  tracking_branch_name = ref.tracking_name,
  unstage = repository.unstage,
  worktree_text = buffer.read_worktree,
}
