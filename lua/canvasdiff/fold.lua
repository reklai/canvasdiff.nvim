--- Which sections render as a one-row placeholder right now, and whose doing it is.
---
--- Two gestures hide a file, and they are one concept to the user:
---   * collapsing it outright  -- state.collapsed[filepath] = "user" | "auto"
---   * folding a parent dir    -- state.folded["lua/mod/"]
---
--- A collapse also records WHOSE it was: "user" for a deliberate gesture,
--- "auto" for one the virtualizer made to keep a huge changeset cheap. Both
--- render as a placeholder; only "user" is something navigation should step
--- over or a session should persist.
---
--- Visibility is DERIVED from both rather than stored once. Folding never
--- writes into state.collapsed, so unfolding restores the exact per-file
--- collapse state that was there before the fold -- nothing has to remember
--- which of the two gestures hid what, and a file the user collapsed by hand
--- before folding its parent survives the round trip.
---
--- Pure, and requires nothing, so every module can read the predicate without
--- a dependency cycle and it unit-tests standalone.
local F = {}

--- True when a folded ancestor directory of `path` is in `folded`.
---
--- Walks `path`'s own cumulative prefixes instead of iterating `folded`, so
--- the cost is O(depth) hash lookups no matter how many directories are
--- folded -- this runs per section per scroll (scrollbar.update) and per
--- navigation keypress.
---
--- Fold keys carry a trailing slash ("lua/", "lua/mod/" -- the cumulative form
--- sidebar.build_entries creates). That slash is load-bearing: it is what
--- stops a folded "lua/mod/" from also hiding "lua/modules/x.lua".
function F.hides(folded, path)
  if not folded or not path then
    return false
  end
  local from = 1
  while true do
    local slash = string.find(path, "/", from, true)
    if not slash then
      return false
    end
    if folded[string.sub(path, 1, slash)] then
      return true
    end
    from = slash + 1
  end
end

--- Every folded ancestor of `path`, outermost first; empty when nothing hides
--- it. Revealing a path means clearing the WHOLE chain -- with both "lua/" and
--- "lua/mod/" folded, dropping either one alone leaves the file hidden and
--- nothing visibly happens.
function F.folds_hiding(folded, path)
  local dirs = {}
  if not folded or not path then
    return dirs
  end
  local from = 1
  while true do
    local slash = string.find(path, "/", from, true)
    if not slash then
      return dirs
    end
    local dir = string.sub(path, 1, slash)
    if folded[dir] then
      dirs[#dirs + 1] = dir
    end
    from = slash + 1
  end
end

--- True when `path`'s section renders as its single placeholder row right now.
---
--- This is the RENDERING predicate. Every reader that maps section.entries
--- onto buffer rows has to agree with it: a section rendered as one row still
--- has all its entries, so a reader that thinks it is expanded computes rows
--- that land inside the FOLLOWING files (highlight marks, hunk jump targets,
--- viewport anchors). Navigation wants F.user_folded instead -- see there.
function F.hidden(state, path)
  if not state then
    return false
  end
  if state.collapsed and state.collapsed[path] then
    return true
  end
  return F.hides(state.folded, path)
end

--- `{[path] = true}` for every hidden section. Takes plain tables rather than
--- `state` so callers that are pure over a set stay pure (scrollbar.line_kinds
--- is the one that matters). Intent-blind, like F.hidden: both kinds of collapse
--- occupy one row.
function F.hidden_set(sections, collapsed, folded)
  local set = {}
  for _, sec in ipairs(sections or {}) do
    if (collapsed and collapsed[sec.path]) or F.hides(folded, sec.path) then
      set[sec.path] = true
    end
  end
  return set
end

--- True when the USER folded `path` -- by folding the file, or by folding a
--- directory above it. A section the virtualizer collapsed on its own is module
--- bookkeeping, not a decision the user made, so navigation must still be able
--- to land there.
---
--- Deliberately NOT F.hidden. Rendering cares what occupies a single row;
--- navigation cares what you chose to put away. The two answers differ exactly
--- on virt's auto-collapses.
---
--- Well-defined by construction rather than by convention: state.collapsed
--- stores WHICH of the two a collapse is ("user" / "auto"), so a path cannot be
--- both, and no cross-module handshake has to keep them apart.
function F.user_folded(state, path)
  if not state then
    return false
  end
  if F.hides(state.folded, path) then
    return true
  end
  return (state.collapsed and state.collapsed[path]) == "user"
end

--- `{[path] = true}` for every user-folded section.
---
--- Delegates rather than re-deriving, so the sidebar's `▸` markers and the
--- staleness check can never disagree about whose fold a placeholder is.
function F.user_folded_set(sections, state)
  local set = {}
  for _, sec in ipairs(sections or {}) do
    if F.user_folded(state, sec.path) then
      set[sec.path] = true
    end
  end
  return set
end

--- True when `path` is folded AND its diff no longer looks like it did when the
--- user put it away. `current_fp` is the section's fingerprint right now
--- (model.fingerprint) -- passed in rather than computed here so this module stays
--- pure and dependency-free. `lens_id` scopes the comparison (see below).
---
--- Detection is a COMPARISON, not a flag, and that is the point: canvas.render_all
--- re-renders a folded section straight into placeholder form without going
--- through resplice or replace_section, so anything that set a flag from a mutation
--- site would miss `:CanvasDiff refresh` and watch's full-render paths. Comparing at
--- read time covers every path that can ever change a section, including ones added
--- later.
---
--- `state.folded_seen[path]` holds `{ lens = <id>, fp = <fingerprint> }` captured when
--- the section went away, with `fp = false` for one that arrived already hidden (a
--- new file under a live fold) -- never seen, so never what you reviewed, so always
--- stale.
---
--- SCOPED BY LENS, and it has to be. The fingerprint hashes the section's new side,
--- and the `staged` lens moves that side from the worktree to the index -- so a pivot
--- changes the content for reasons nobody edited. Comparing across lenses would
--- report every folded file as changed and destroy the signal. A lens mismatch
--- means "not comparable", which is emphatically not the same as "changed".
--- (`all` and `unstaged` differ only in their OLD side, so they already agreed; the
--- scoping is what makes that true by construction rather than by luck.)
---
--- Gated on F.user_folded, not F.hidden: the virtualizer's own collapses are its
--- bookkeeping and were never a decision the user made, so there is nothing for
--- them to be stale relative to.
function F.stale(state, path, current_fp, lens_id)
  if not state or not state.folded_seen then
    return false
  end
  local seen = state.folded_seen[path]
  if seen == nil then
    return false
  end
  if seen.lens ~= lens_id then
    return false -- captured through a different lens: no basis for comparison
  end
  if not F.user_folded(state, path) then
    return false
  end
  return seen.fp ~= current_fp
end

--- `{[path] = true}` for every stale section. `fp_of(section)` yields a section's
--- current fingerprint. Delegates to F.stale for the same reason F.user_folded_set
--- delegates to F.user_folded: the canvas placeholder and the sidebar row promise to
--- agree, and two copies of the rule would not stay that way.
function F.stale_set(sections, state, fp_of, lens_id)
  local set = {}
  for _, sec in ipairs(sections or {}) do
    if F.stale(state, sec.path, fp_of(sec), lens_id) then
      set[sec.path] = true
    end
  end
  return set
end

--- Indices of the sections under directory `dir` (a fold key, trailing
--- slash). Ascending, and contiguous in practice because sections are
--- path-sorted (model.build) and a fold key is a path prefix.
function F.indices_under(sections, dir)
  local out = {}
  if not sections or not dir or dir == "" then
    return out
  end
  for i, sec in ipairs(sections) do
    if string.sub(sec.path, 1, #dir) == dir then
      out[#out + 1] = i
    end
  end
  return out
end

--- `folded` minus every key with no section under it any more.
---
--- A fold says "I'm done with these changes", so it has to die with them.
--- Without this, folding "src/" and then committing everything under it leaves
--- the key behind -- invisible, because the sidebar only draws a dir row for a
--- directory that still has sections -- and the next edit to any file under
--- src/ opens as a placeholder that navigation steps over. It is persisted, so
--- that outlives the Neovim session too.
---
--- Returns a new table; never mutates `folded`.
function F.prune(sections, folded)
  local out = {}
  if not folded then
    return out
  end
  for dir in pairs(folded) do
    for _, sec in ipairs(sections or {}) do
      if string.sub(sec.path, 1, #dir) == dir then
        out[dir] = true
        break
      end
    end
  end
  return out
end

return F
