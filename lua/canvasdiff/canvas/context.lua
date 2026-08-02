--- What granularity the verb under the cursor is standing on: the hunk, when
--- the row is one of that hunk's own, and otherwise the file -- a file header,
--- a binary notice, a pure rename's single row, or a folded placeholder.
---
--- The ONE home for that decision. The canvas keymaps and the sidebar rows
--- both route through here, so `s` can never mean "stage this hunk" in one
--- place and "stage this file" in the other.
---
--- A canvas concern, not a diff one, because the question starts from a canvas
--- ROW and only the canvas knows what a row is. The diff domain has no
--- outgoing edges by design, so asking Canvas.locate from there is both a
--- forbidden dependency and a load-time require cycle.
local Canvas = require("canvasdiff.canvas.Canvas")
local fold = require("canvasdiff.diff").fold

local C = {}

--- `{ scope = "hunk", section = i, hunk = gi }` or `{ scope = "file",
--- section = i }` for 0-based canvas row `row0`; nil when no section is under
--- it. `hunk` is the section's hunk ordinal -- the index into `section.hunks`,
--- and the same `gi` that `entry.hunk_idx` carries.
function C.resolve(state, row0)
  local index, offset = Canvas.locate(state, row0)
  if not index then
    return nil
  end
  local section = state.sections[index]
  -- Mapping section.entries onto rows obliges a reader to consult fold.hidden
  -- first (see diff.fold): a hidden section still HAS all its entries, and it
  -- renders as one placeholder row regardless. File scope is settled before
  -- any offset is read.
  if not section or fold.hidden(state, section.path) then
    return { scope = "file", section = index }
  end
  local entry = section.entries[offset]
  if not entry or entry.hunk_idx == nil then
    return { scope = "file", section = index }
  end
  return { scope = "hunk", section = index, hunk = entry.hunk_idx }
end

return C
