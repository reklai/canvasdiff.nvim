local collect = require("canvasdiff.source.collect")
local repository = require("canvasdiff.source.repository")

-- Repository inspection and changeset collection enter the source domain
-- through this exact facade. Live-buffer and protocol details remain owned by
-- internal modules below it.
return {
  changed_files = repository.changed_files,
  diff_files = repository.diff_files,
  files = collect.files,
  resolve_commit = repository.resolve_commit,
  root = repository.root,
  sections = collect.sections,
  show = repository.show,
  show_head = repository.show_head,
}
