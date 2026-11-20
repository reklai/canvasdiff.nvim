local algorithm = require("canvasdiff.diff.algorithm")
local anchor = require("canvasdiff.diff.anchor")
local fold = require("canvasdiff.diff.fold")
local lens = require("canvasdiff.diff.lens")
local model = require("canvasdiff.diff.model")
local stage = require("canvasdiff.diff.stage")
local text = require("canvasdiff.diff.text")

-- The diff domain is pure over caller-provided text and file metadata.
-- Consumers outside this directory import only this curated facade.
return {
  -- Semantic viewport anchors. `capture_from_entries` returns
  -- { new_lnum, content, screen_offset }; `resolve` answers the best-matching
  -- 1-based entry index, falling back to 1 -- nil only for empty entries.
  -- `nearest` is the reverse of a jump: (entries, new-side line) -> the index
  -- of the entry showing that line plus `true`, else the nearest shown line
  -- plus `false`, else nil when no entry maps to a file line (a binary or
  -- wholly deleted file). All pure, none errors.
  anchor = {
    capture_from_entries = anchor.capture_from_entries,
    nearest = anchor.nearest,
    resolve = anchor.resolve,
  },
  -- Path-sorted section list from file records; a file with no reviewable
  -- change contributes nothing.
  build = model.build,
  -- One section table, or nil when old and new sides are identical and the
  -- file was not renamed. Binary and rename-only files still get a (bodyless)
  -- section. An optional 7th argument `pace(rows)` is called from the build
  -- loops as a time-slicing checkpoint and never changes the result. Never
  -- errors itself; whatever `pace` raises (a cancellation) propagates.
  build_section = model.build_section,
  -- (section, path, status, context, metadata) -> true when building those
  -- inputs would reproduce `section` exactly, so it can be kept instead of
  -- diffed again. `metadata` must carry old_fingerprint/new_fingerprint (from
  -- `text_fingerprint`); without them, or for a non-table, false. Pure.
  built_from = model.built_from,
  -- The sha256 hex digest every section fingerprint is made of. Persisted in
  -- session files, so it must never change silently. Never errors.
  text_fingerprint = model.text_fingerprint,
  -- Digest of the section's NEW side only, so pivoting the comparison's old
  -- side never reads as "the file changed" (fold.stale's input).
  fingerprint = model.fingerprint,
  -- Drops the section's retained old_text/new_text in place and returns it;
  -- entries, hunks and fingerprints stay usable without them.
  release_text = model.release_text,
  -- Pure visibility predicates and set builders over state.collapsed /
  -- state.folded. `hidden` is the RENDERING predicate, `user_folded` the
  -- navigation one -- they differ exactly on the virtualizer's auto-collapses.
  -- None of these mutate state or error; the set builders return fresh tables.
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
  -- Raw index quads { old_start, old_count, new_start, new_count } from the
  -- histogram diff; always a list, empty when the sides match.
  hunks = algorithm.hunks,
  -- NUL-sniff of the first 8000 bytes (git's own heuristic); false for nil/"".
  is_binary = text.is_binary,
  -- Pure lens identities and predicates. The constructors (get, range,
  -- branch, normalize) return a fresh validated lens table, or nil for input
  -- they refuse -- a session payload is hand-editable, so `valid` gates
  -- everything read back from disk.
  lens = {
    INDEX_REV = lens.INDEX_REV,
    branch = lens.branch,
    editable = lens.editable,
    from_base = lens.from_base,
    get = lens.get,
    is_branch = lens.is_branch,
    is_range = lens.is_range,
    normalize = lens.normalize,
    of = lens.of,
    range = lens.range,
    same = lens.same,
    step = lens.step,
    to_base = lens.to_base,
    valid = lens.valid,
  },
  -- Staging as pure line splices over both blobs -- never a patch, so nothing
  -- can fail to apply. `pick` answers the first hunk overlapping a span or
  -- nil; `pick_all` answers every one (and asserts on a span missing lo/hi:
  -- the caller must substitute the seam for a pure deletion). The splices
  -- return the rewritten a-side text and preserve its final-newline state.
  stage = {
    pair_hunks = stage.pair_hunks,
    pick = stage.pick,
    pick_all = stage.pick_all,
    splice = stage.splice,
    splice_many = stage.splice_many,
  },
  -- True when git's own XY pair says the file was staged and then modified
  -- again -- durable across sessions, independent of our fingerprints.
  staged_then_changed = model.staged_then_changed,
}
