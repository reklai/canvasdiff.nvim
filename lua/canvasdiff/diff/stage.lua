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

--- The first hunk whose b-side window overlaps `span` ({lo, hi}, b-side line
--- numbers); nil when none. `span` is a hull -- it may run wider than the
--- hunk it names -- so this is an overlap test, not containment.
function S.pick(hunks, span)
  for _, hunk in ipairs(hunks) do
    local lo, hi = window(hunk)
    if span.lo <= hi and span.hi >= lo then
      return hunk
    end
  end
end

--- `a_text` with exactly `hunk` applied from `b_text`.
---
--- The terminator is the a side's and is never rewritten: a splice may not
--- silently add or drop a file's final newline, which is also why the one
--- change this cannot stage is that newline itself.
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

return S
