-- Staging is a line splice on blob content, never a patch: both sides are
-- in hand, so applying hunk N is arithmetic, immune to context drift.
-- Everything here is pure; the git writes live in source/repository.
local algorithm = require("canvasdiff.diff.algorithm")

local S = {}

--- Bytes are content here: "\n" is the only separator, so a "\r" belongs to
--- the line it ends, and the terminating newline -- which survives here only
--- as an empty last field -- is splice()'s to restore.
local function lines_of(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

function S.pair_hunks(a_text, b_text)
  return algorithm.hunks(a_text, b_text)
end

--- The b-side lines a hunk occupies. A zero count writes no line at all, so
--- an exact window would be empty and nothing could ever land on it; a
--- deletion is instead found by the seam, the two lines its cut sits between.
local function window(hunk)
  local start_b, count_b = hunk[3], hunk[4]
  if count_b > 0 then
    return start_b, start_b + count_b - 1
  end
  return start_b, start_b + 1
end

--- Every hunk whose b-side window overlaps `span` ({lo, hi}, b-side line
--- numbers), in the order the pair reported them; empty when none.
---
--- `span` is a HULL -- first through last line one displayed hunk writes --
--- and context merging can seat SEVERAL pair hunks inside one of them, so
--- this is an overlap test, not containment, and it answers with all of them.
--- Staging the first alone would stage half of what the user pointed at.
function S.pick_all(hunks, span)
  -- A hunk that only deletes writes no new-side line, so its hull publishes
  -- neither bound and the caller must substitute the seam around the cut. A
  -- nil arriving here is that substitution missing: a bug worth a traceback,
  -- because answering "nothing overlaps" would make staging quietly do nothing.
  assert(span and span.lo and span.hi,
    "stage: a span needs lo and hi; a pure-deletion hunk publishes neither, "
    .. "so the caller substitutes the seam around its cut")

  local found = {}
  for _, hunk in ipairs(hunks) do
    local lo, hi = window(hunk)
    if span.lo <= hi and span.hi >= lo then
      found[#found + 1] = hunk
    end
  end
  return found
end

--- The first hunk `pick_all` finds, or nil: the "is there anything to do
--- here?" question. Applying the span needs every one of them.
function S.pick(hunks, span)
  return S.pick_all(hunks, span)[1]
end

--- `a_text` with exactly `hunk` applied from `b_text`.
---
--- The terminator is the a side's and is never rewritten: a splice may not
--- silently add or drop a file's final newline. Known limitation of that
--- rule: a change consisting SOLELY of the final newline cannot be expressed
--- as a line splice, so it stays on screen instead of staging.
function S.splice(a_text, b_text, hunk)
  local a, b = lines_of(a_text), lines_of(b_text)
  local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
  -- A zero a-side count is an insertion AFTER start_a, so that line is kept.
  local upto = count_a > 0 and start_a - 1 or start_a

  local out = {}
  for i = 1, upto do
    out[#out + 1] = a[i]
  end
  for i = start_b, start_b + count_b - 1 do
    out[#out + 1] = b[i]
  end
  for i = upto + count_a + 1, #a do
    out[#out + 1] = a[i]
  end

  local text = table.concat(out, "\n")
  if #out > 0 and (a_text == "" or a_text:sub(-1) == "\n") then
    return text .. "\n"
  end
  return text
end

--- `a_text` with every hunk in `hunks` applied from `b_text`.
---
--- Later hunks go first. A splice rewrites only a-side lines at or after its
--- own start, so once the last hunk has landed every earlier hunk's a-side
--- indices are still the ones the pair reported; ascending order would carry
--- them off the moment one hunk changed the line count above the next. The b
--- side is never rewritten, so its indices hold whatever the order.
function S.splice_many(a_text, b_text, hunks)
  local descending = {}
  for i, hunk in ipairs(hunks) do
    descending[i] = hunk
  end
  table.sort(descending, function(left, right) return left[1] > right[1] end)

  local text = a_text
  for _, hunk in ipairs(descending) do
    text = S.splice(text, b_text, hunk)
  end
  return text
end

--- Reconstruct final-newline shape from `reference_text`: if `out` is non-empty
--- and `reference_text` was empty or ended in `\n`, keep a trailing `\n`.
local function join_preserving_eol(out, reference_text)
  local text = table.concat(out, "\n")
  if #out > 0 and (reference_text == "" or reference_text:sub(-1) == "\n") then
    return text .. "\n"
  end
  return text
end

--- Apply ONLY the selected changes from `b_text` onto `a_text` (line-level
--- staging). `selection` carries sets in b-side coordinates (plus optional
--- `a_lines` for wholly-deleted files where deletions render as real rows):
---   * `b_lines`: `{ [b_lnum] = true }` selected new-side lines
---   * `seams`:   `{ [b_seam] = true }` selected ghost-deletion seams
---   * `a_lines`: `{ [a_lnum] = true }` selected old-side lines (deleted files)
---
--- Pure line arithmetic, never a patch: preserves CRLF and `a_text`'s final
--- newline. Returns `new_a_text, changed`.
function S.splice_lines(a_text, b_text, selection)
  selection = selection or {}
  local b_lines = selection.b_lines or {}
  local seams = selection.seams or {}
  local a_lines = selection.a_lines or {}

  local hunks = S.pair_hunks(a_text, b_text)
  if #hunks == 0 then
    return a_text, false
  end

  local a, b = lines_of(a_text), lines_of(b_text)
  local out = {}
  local pos_a = 1
  local changed = false

  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    local upto = count_a > 0 and (start_a - 1) or start_a
    for i = pos_a, upto do
      out[#out + 1] = a[i]
    end

    if count_a == 0 and count_b > 0 then
      -- Pure addition: include only selected b lines.
      for lnum = start_b, start_b + count_b - 1 do
        if b_lines[lnum] then
          out[#out + 1] = b[lnum]
          changed = true
        end
      end
    elseif count_a > 0 and count_b == 0 then
      -- Pure deletion: drop selected a lines (wholly-deleted file) or drop the
      -- whole block when its ghost seam is selected.
      if next(a_lines) ~= nil then
        for lnum = start_a, start_a + count_a - 1 do
          if a_lines[lnum] then
            changed = true
          else
            out[#out + 1] = a[lnum]
          end
        end
      elseif seams[start_b] then
        changed = true
      else
        for lnum = start_a, start_a + count_a - 1 do
          out[#out + 1] = a[lnum]
        end
      end
    else
      -- Replacement (`count_a > 0, count_b > 0`): ghosts hang on `start_b`
      -- (seam `start_b - 1`). Drop old lines when that seam is selected, and
      -- emit every selected new line.
      local drop_a = seams[start_b - 1] == true
      if drop_a then
        changed = true
      else
        for lnum = start_a, start_a + count_a - 1 do
          out[#out + 1] = a[lnum]
        end
      end
      for lnum = start_b, start_b + count_b - 1 do
        if b_lines[lnum] then
          out[#out + 1] = b[lnum]
          changed = true
        end
      end
    end

    pos_a = upto + count_a + 1
  end

  for i = pos_a, #a do
    out[#out + 1] = a[i]
  end
  if not changed then
    return a_text, false
  end
  local result = join_preserving_eol(out, a_text)
  return result, result ~= a_text
end

--- Revert ONLY the selected changes in `b_text` back toward `a_text`
--- (line-level unstaging `HEAD -> index` and line-level discarding
--- `index -> worktree`). `selection` has the same shape as `splice_lines`.
---
--- Returns `new_b_text, removed_lines, changed`, where `removed_lines` lists
--- the exact b-side lines dropped (with trailing `\r` stripped for the unnamed
--- register on discard).
function S.revert_lines(a_text, b_text, selection)
  selection = selection or {}
  local b_lines = selection.b_lines or {}
  local seams = selection.seams or {}
  local a_lines = selection.a_lines or {}

  local hunks = S.pair_hunks(a_text, b_text)
  if #hunks == 0 then
    return b_text, {}, false
  end

  local a, b = lines_of(a_text), lines_of(b_text)
  local out = {}
  local removed = {}
  local pos_b = 1
  local changed = false

  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    local upto_b = count_b > 0 and (start_b - 1) or start_b
    for i = pos_b, upto_b do
      out[#out + 1] = b[i]
    end

    if count_a == 0 and count_b > 0 then
      -- Pure addition: drop selected b lines, keep unselected ones.
      for lnum = start_b, start_b + count_b - 1 do
        if b_lines[lnum] then
          removed[#removed + 1] = (b[lnum] or ""):gsub("\r$", "")
          changed = true
        else
          out[#out + 1] = b[lnum]
        end
      end
    elseif count_a > 0 and count_b == 0 then
      -- Pure deletion: restore selected a lines (or all when seam selected).
      if next(a_lines) ~= nil then
        for lnum = start_a, start_a + count_a - 1 do
          if a_lines[lnum] then
            out[#out + 1] = a[lnum]
            changed = true
          end
        end
      elseif seams[start_b] then
        for lnum = start_a, start_a + count_a - 1 do
          out[#out + 1] = a[lnum]
        end
        changed = true
      end
    else
      -- Replacement: restore old lines when the ghost seam `start_b - 1` is
      -- selected, and drop each selected new line.
      if seams[start_b - 1] then
        for lnum = start_a, start_a + count_a - 1 do
          out[#out + 1] = a[lnum]
        end
        changed = true
      end
      for lnum = start_b, start_b + count_b - 1 do
        if b_lines[lnum] then
          removed[#removed + 1] = (b[lnum] or ""):gsub("\r$", "")
          changed = true
        else
          out[#out + 1] = b[lnum]
        end
      end
    end

    pos_b = upto_b + count_b + 1
  end

  for i = pos_b, #b do
    out[#out + 1] = b[i]
  end
  if not changed then
    return b_text, {}, false
  end
  local result = join_preserving_eol(out, b_text)
  return result, removed, result ~= b_text
end

return S
