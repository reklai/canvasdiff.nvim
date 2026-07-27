-- The page-backed canvas renderer.
--
-- The eager canvas writes every diff row into a buffer and places one extmark
-- per highlighted row. At a million rows both are fatal: the text is the
-- memory, and the marks are a per-row structure Neovim has to keep sorted.
--
-- This renderer keeps neither. The text lives in a `PageList`, compacted and
-- bounded by a resident cache; the buffer is a `Projection` skeleton holding
-- one BLANK line per logical row, which is what keeps native scrolling, marks
-- and search positions exact; and the highlighting is emitted per visible row
-- by the projection's decoration provider, so the rows off screen are never
-- asked about and cost nothing.
--
-- What it does NOT yet render is deletion ghosts. The eager canvas draws them
-- as `virt_lines` extmarks so a deleted line costs zero buffer rows. Measured
-- rather than assumed: an EPHEMERAL extmark silently ignores `virt_lines` --
-- no error is raised and no rows appear. Ghosts therefore cannot ride the
-- decorator, and need marks placed for the visible range and removed as it
-- moves. That is bounded by the viewport rather than by the canvas, so it does
-- not reintroduce a per-logical-row structure, but it is a separate mechanism
-- and is not built here.

local PageList = require("canvasdiff.canvas.PageList")
local Projection = require("canvasdiff.canvas.Projection")
local Restore = require("canvasdiff.canvas.compression.restore")
local render = require("canvasdiff.canvas.format")

local Paged = {}

-- Priorities mirror the eager canvas so the two look the same: the file bar
-- sits BELOW the header's own group, because CanvasDiffFileHeader links to
-- Title, which is foreground-only, and the two compose rather than fight.
local FILE_BAR_GROUP = "CanvasDiffFileBar"

--- Which section owns a logical row, by binary search over section starts.
---
--- Linear scan would be O(sections) per visible row on every redraw, which at
--- a few hundred files is a measurable cost repeated sixty times a second for
--- no reason.
local function section_at(starts, row0)
  local low, high = 1, #starts
  local found = nil
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if starts[middle] <= row0 then
      found = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end
  return found
end

--- Build the row-relative highlight map for one section, once.
---
--- Held per section rather than per row: a section's map is as large as its
--- entries, and the sum over sections is the canvas -- but it holds group
--- NAMES, not extmarks, so Neovim never sees it and it costs no redraw work.
local function section_styles(section, collapsed)
  if collapsed then
    return { [0] = { hl_group = "CanvasDiffFileHeader" } }
  end
  local styles = {}
  for _, mark in ipairs(render.section_hl(section)) do
    styles[mark.row] = { hl_group = mark.group }
  end
  -- The file header's full-width bar, so crossing from one file into the next
  -- is visible in peripheral vision while scrolling. Expanded sections only,
  -- exactly as in the eager canvas: a collapsed placeholder is already one
  -- visually distinct row and has no body below it to delimit.
  local header = styles[0] or {}
  styles[0] = {
    hl_group = header.hl_group,
    line_hl_group = FILE_BAR_GROUP,
  }
  return styles
end

--- Render `sections` into a page-backed canvas.
---
--- `opts.collapsed(path)` decides whether a section renders as its single
--- placeholder row; `opts.stale(section)` decides whether that placeholder
--- carries the stale marker. Both default to "no", so the plain call renders
--- every section expanded.
--- @return table|nil paged { list, projection, buffer, sections, starts, styles }
--- @return string|nil error
function Paged.render(sections, opts)
  if type(sections) ~= "table" then
    return nil, "paged canvas requires a section list"
  end
  opts = opts or {}
  if type(opts) ~= "table" then
    return nil, "paged canvas options must be a table"
  end
  local collapsed_for = opts.collapsed or function() return false end
  local stale_for = opts.stale or function() return false end
  if type(collapsed_for) ~= "function" or type(stale_for) ~= "function" then
    return nil, "paged canvas collapsed/stale must be functions"
  end

  local rows = {}
  local starts = {}
  local styles = {}
  local collapsed_state = {}
  for index, section in ipairs(sections) do
    local collapsed = collapsed_for(section.path) and true or false
    collapsed_state[index] = collapsed
    starts[index] = #rows
    styles[index] = section_styles(section, collapsed)
    local lines = collapsed
      and { render.placeholder(section, stale_for(section) and true or false) }
      or render.section_lines(section)
    for _, line in ipairs(lines) do
      rows[#rows + 1] = line
    end
  end
  -- A Projection needs at least the shape of a canvas. An empty review is one
  -- blank logical row, matching the eager canvas, which cannot have a
  -- zero-line buffer either.
  if #rows == 0 then
    rows[1] = ""
  end

  local restore = Restore.adapter()
  local list, list_err = PageList.create(rows, restore and {
    resident = { restore = restore },
  } or nil)
  if not list then
    return nil, "could not page the canvas: " .. tostring(list_err)
  end

  local paged = {
    list = list,
    sections = sections,
    starts = starts,
    styles = styles,
    collapsed = collapsed_state,
  }

  --- The decorator: what this logical row looks like.
  ---
  --- Runs inside a decoration-provider callback for visible rows only, so it
  --- does table lookups and no allocation beyond the answer itself.
  local function decorate(row0)
    local index = section_at(paged.starts, row0)
    if not index then
      return nil
    end
    local map = paged.styles[index]
    return map and map[row0 - paged.starts[index]] or nil
  end

  local projection, projection_err = Projection.create(list, {
    decorate = decorate,
  })
  if not projection then
    return nil, "could not project the canvas: " .. tostring(projection_err)
  end
  paged.projection = projection
  paged.buffer = projection:buffer()
  return paged
end

--- The logical text of a paged canvas, in the shape `canvas.logical` answers.
---
--- Having the same shape is the point: a reader that works against the eager
--- canvas works against this one without knowing which it has.
--- @return table logical
function Paged.logical(paged)
  return {
    row_count = function()
      return paged.list:row_count()
    end,
    rows = function(start0, count)
      return paged.list:rows(start0, count)
    end,
    row = function(row0)
      return paged.list:row(row0)
    end,
    export = function(start0, count, export_opts)
      return paged.projection:export(start0, count, export_opts)
    end,
  }
end

--- Which section and row-within-section a logical row belongs to.
---
--- The display stack asks this instead of reading buffer text: it is what
--- `section_rows`, the sidebar's row mapping and hunk/file motions actually
--- need from a canvas.
function Paged.locate(paged, row0)
  local index = section_at(paged.starts, row0)
  if not index then
    return nil
  end
  return index, row0 - paged.starts[index]
end

--- Release the projection and forget the store.
function Paged.dispose(paged)
  if not paged then
    return true
  end
  local projection = paged.projection
  paged.projection = nil
  paged.list = nil
  if projection then
    return projection:dispose(true)
  end
  return true
end

return Paged
