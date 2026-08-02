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
---
--- "No section under it" is narrower than it sounds on the eager path:
--- Canvas.locate CLAMPS, answering the nearest section for a row past the last
--- one rather than refusing it. So nil means the canvas has no sections at
--- all, and a caller cannot use it to detect a cursor off the end.
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

--- The deleted lines drawn around 0-based canvas row `row0`, in the order they
--- appear, or `{}` when it carries none.
---
--- Deletions are virtual text, which is display-only: the cursor cannot enter a
--- ghost and `y` cannot reach one. So the only handle on removed text is the
--- real row it hangs on, and this is that handle. `ghosts` draw above that row;
--- `ghosts_after` draw below it, which is where deletions running past the last
--- surviving line have to go. A reader sees no difference between the two, so
--- neither does this.
function C.ghosts(state, row0)
  local index, offset = Canvas.locate(state, row0)
  if not index then
    return {}
  end
  local section = state.sections[index]
  -- A folded section draws one placeholder row and no ghosts at all, so its
  -- entries name text that is not on screen to be copied.
  if not section or fold.hidden(state, section.path) then
    return {}
  end
  local entry = section.entries[offset]
  if not entry then
    return {}
  end
  -- Taken one list at a time on purpose: `ipairs{ entry.ghosts,
  -- entry.ghosts_after }` stops at the first nil, so a row carrying only
  -- trailing deletions would answer with nothing at all.
  local out = {}
  local function take(list)
    for _, ghost in ipairs(list or {}) do
      out[#out + 1] = ghost.content
    end
  end
  take(entry.ghosts)
  take(entry.ghosts_after)
  return out
end

--- The 0-based canvas row of hunk `gi`'s header in section `section_i` --
--- `resolve` read backwards, for a caller that names a hunk without a cursor
--- to point at it. nil when that section or that hunk is not there.
---
--- A folded section answers with its own start row, and that is arithmetic
--- rather than policy: it renders as ONE row however many entries it still
--- carries, so `start0 + offset` would land inside the FOLLOWING file. The same
--- reason motions.hunk_stops treats a folded file as exactly one stop.
function C.hunk_row(state, section_i, gi)
  local section = state.sections[section_i]
  if not section then
    return nil
  end
  local start0 = (Canvas.section_rows(state, section_i))
  if fold.hidden(state, section.path) then
    return start0
  end
  for offset, entry in ipairs(section.entries or {}) do
    if entry.kind == "hunk_hdr" and entry.hunk_idx == gi then
      return start0 + offset - 1
    end
  end
  return nil
end

return C
