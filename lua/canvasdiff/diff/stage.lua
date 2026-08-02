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

return S
