local algorithm = require("canvasdiff.diff.algorithm")
local anchor = require("canvasdiff.diff.anchor")
local fold = require("canvasdiff.diff.fold")
local lens = require("canvasdiff.diff.lens")
local model = require("canvasdiff.diff.model")
local text = require("canvasdiff.diff.text")
local word_diff = require("canvasdiff.diff.word_diff")

-- The diff domain is pure over caller-provided text and file metadata.
-- Consumers outside this directory import only this curated facade.
return {
  anchor = {
    capture_from_entries = anchor.capture_from_entries,
    resolve = anchor.resolve,
  },
  build = model.build,
  build_section = model.build_section,
  fingerprint = model.fingerprint,
  release_text = model.release_text,
  fold = {
    folds_hiding = fold.folds_hiding,
    hidden = fold.hidden,
    hidden_set = fold.hidden_set,
    hides = fold.hides,
    indices_under = fold.indices_under,
    prune = fold.prune,
    stale = fold.stale,
    stale_set = fold.stale_set,
    user_folded = fold.user_folded,
    user_folded_set = fold.user_folded_set,
  },
  hunks = algorithm.hunks,
  is_binary = text.is_binary,
  lens = {
    branch = lens.branch,
    editable = lens.editable,
    from_base = lens.from_base,
    get = lens.get,
    is_branch = lens.is_branch,
    of = lens.of,
    same = lens.same,
    step = lens.step,
    to_base = lens.to_base,
    valid = lens.valid,
  },
  staged_then_changed = model.staged_then_changed,
  word_marks = word_diff.section_marks,
}
