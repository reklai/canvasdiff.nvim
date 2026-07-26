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

--- Ascending section indices a file motion may land on.
function F.navigable(sections, state, auto)
  local out = {}
  for i, sec in ipairs(sections or {}) do
    if not F.user_folded(state, sec.path) then
      out[#out + 1] = i
    end
  end
  return out
end

--- Position of `i` in the ascending list `nav`, plus the insertion point.
--- Returns (pos, nil) when `i` is in `nav`, else (nil, the first index whose
--- value exceeds `i`) -- which is #nav + 1 when `i` is past the end.
local function locate_in(nav, i)
  for p, k in ipairs(nav) do
    if k == i then
      return p, nil
    end
    if k > i then
      return nil, p
    end
  end
  return nil, #nav + 1
end

--- Step `count` navigable sections from section `i`, clamping at both ends --
--- the ]f / [f semantics. Returns a section index, or nil when there is
--- nowhere to go.
---
--- Clamping at the far end returns `i` itself rather than nil, deliberately, so
--- ]f on the last section still snaps the cursor to that section's start.
function F.step_clamped(nav, i, dir, count)
  local n = #nav
  if n == 0 then
    return nil -- nothing navigable: stay put rather than jumping to section one
  end
  count = math.max(1, count or 1)
  local p, after = locate_in(nav, i)
  if not p then
    -- The cursor sits on a set-aside section, so the first step is "reach the
    -- nearest navigable one in the direction of travel". Never reverse: with
    -- nothing that way, don't move at all -- the rule goto_hunk already
    -- follows when no qualifying row lies ahead.
    p = dir > 0 and after or (after - 1)
    if p < 1 or p > n then
      return nil
    end
    count = count - 1
  end
  local q = p + dir * count
  if q < 1 then
    q = 1
  elseif q > n then
    q = n
  end
  return nav[q]
end

--- Step `count` navigable sections from section `i`, wrapping -- the
--- <C-n> / <C-p> semantics. Returns a section index, or nil when nothing is
--- navigable.
function F.step_wrapped(nav, i, delta, count)
  local n = #nav
  if n == 0 then
    return nil
  end
  count = math.max(1, count or 1)
  local p, after = locate_in(nav, i)
  if not p then
    if delta > 0 then
      p = after > n and 1 or after
    else
      p = (after - 1 < 1) and n or (after - 1)
    end
    count = count - 1
  end
  -- Lua's % is non-negative for a positive modulus, so wrapping backwards
  -- needs no special case.
  return nav[((p - 1 + delta * count) % n) + 1]
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

return F
