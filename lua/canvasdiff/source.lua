local repository = require("canvasdiff.source.repository")

-- The source domain's exact repository surface. Collection remains in its
-- legacy owner until the following migration slice.
return {
  changed_files = repository.changed_files,
  diff_files = repository.diff_files,
  resolve_commit = repository.resolve_commit,
  root = repository.root,
  show = repository.show,
  show_head = repository.show_head,
}
