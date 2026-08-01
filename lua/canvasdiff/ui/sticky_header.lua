-- The sticky file-header row: a one-row float pinned under the winbar that
-- mirrors the in-buffer header of the section under the topline. This half
-- is pure: given a state and a 0-based topline, what (if anything) should
-- the row show. The float half arrives with open/update/close below.
local canvas = require("canvasdiff.canvas")
local render = canvas.format
local fold = require("canvasdiff.diff").fold

local SH = {}

--- nil = show nothing: empty canvas, nothing resolvable, a folded
--- placeholder (that single row IS the header), or the real header row
--- sitting exactly at the top -- pinning a copy over the original would
--- double it.
function SH.content(st, top0)
  if type(st) ~= "table" or type(st.sections) ~= "table"
      or #st.sections == 0 then
    return nil
  end
  local index, offset = canvas.locate(st, top0)
  local section = index and st.sections[index] or nil
  if not section then
    return nil
  end
  if fold.hidden(st, section.path) or offset == 1 then
    return nil
  end
  local line = render.section_line(section, 1)
  if not line then
    return nil
  end
  return {
    line = line,
    -- Never a stale span: the pinned section is on screen, and fold.stale
    -- is false by construction for anything you can see (the same reason
    -- the expanded in-buffer header carries none).
    spans = render.marker_spans(line, section.staged, section.unstaged, false),
  }
end

return SH
