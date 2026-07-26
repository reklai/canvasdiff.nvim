local algorithm = require("canvasdiff.diff.algorithm")
local model = require("canvasdiff.diff.model")
local text = require("canvasdiff.diff.text")

-- The diff domain is pure over caller-provided text and file metadata.
-- Consumers outside this directory import only this curated facade.
return {
  build = model.build,
  build_section = model.build_section,
  fingerprint = model.fingerprint,
  hunks = algorithm.hunks,
  is_binary = text.is_binary,
  staged_then_changed = model.staged_then_changed,
}
