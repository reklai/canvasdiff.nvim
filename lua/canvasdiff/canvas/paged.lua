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
-- Deletion ghosts are the one thing the decorator cannot carry. The eager
-- canvas draws them as `virt_lines` extmarks so a deleted line costs zero
-- buffer rows. Measured rather than assumed: an EPHEMERAL extmark silently
-- ignores `virt_lines` -- no error is raised and no rows appear -- while a
-- persistent one placed outside the provider renders correctly and leaves the
-- line count untouched. So ghosts are persistent marks maintained for the
-- VISIBLE RANGE only, by `refresh_ghosts` below. That is bounded by the
-- window rather than by the canvas, so it does not reintroduce the per-logical
-- -row structure the whole design exists to avoid.

local PageList = require("canvasdiff.canvas.PageList")
local Projection = require("canvasdiff.canvas.Projection")
local Restore = require("canvasdiff.canvas.compression.restore")
local Scheduler = require("canvasdiff.canvas.Scheduler")
local render = require("canvasdiff.canvas.format")

local Paged = {}

-- Priorities mirror the eager canvas so the two look the same: the file bar
-- sits BELOW the header's own group, because CanvasDiffFileHeader links to
-- Title, which is foreground-only, and the two compose rather than fight.
local FILE_BAR_GROUP = "CanvasDiffFileBar"

-- Ghosts get their own namespace so the whole visible set can be cleared in
-- one call without touching anything else drawn on the buffer.
local GHOST_NS = vim.api.nvim_create_namespace("canvasdiff.canvas.paged.ghosts")
Paged.GHOST_NS = GHOST_NS

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

  -- The bounded idle compactor. Without one the pages stay raw and the store
  -- costs what the eager canvas cost; with one it settles to a fraction of it
  -- while the canvas sits open. It is created here and disposed with the
  -- projection so the two can never outlive each other.
  paged.scheduler = Scheduler.create(list, opts.scheduler)

  -- The state shape the display stack already understands. `paged` is what the
  -- canvas API dispatches on: with it set, `section_rows`, `locate` and
  -- `set_collapsed` go to the store instead of to extmark anchors, and every
  -- other reader keeps working because the skeleton has one row per logical
  -- row and the buffer is a buffer.
  paged.state = {
    buf = paged.buffer,
    sections = sections,
    collapsed = {},
    paged = paged,
  }
  for index, section in ipairs(sections) do
    if collapsed_state[index] then
      paged.state.collapsed[section.path] = "user"
    end
  end
  return paged
end

--- The logical row range one section occupies, end-exclusive.
---
--- The eager canvas resolves this from extmark anchors, which drift with every
--- edit and have to be repaired. A paged canvas keeps the starts array
--- authoritative and rewrites it on every splice, so there is nothing to
--- drift.
--- @return integer|nil start0
--- @return integer|nil end0
function Paged.section_rows(paged, index)
  local starts = paged and paged.starts
  if type(starts) ~= "table" or type(index) ~= "number"
      or starts[index] == nil then
    return nil
  end
  local start0 = starts[index]
  local end0 = starts[index + 1] or (paged.list and paged.list:row_count() or start0)
  return start0, end0
end

--- Collapse or expand one section, splicing the store rather than rebuilding.
---
--- This is where paging has to earn itself: folding a file in a million-row
--- review must cost the rows of THAT file, not a re-render of the canvas. The
--- splice replaces exactly the section's rows, and every later section's start
--- shifts by the difference.
--- @return boolean|nil changed
--- @return string|nil error
function Paged.set_collapsed(paged, index, collapsed, opts)
  if type(paged) ~= "table" or type(paged.starts) ~= "table" then
    return nil, "paged canvas is unavailable"
  end
  local section = paged.sections and paged.sections[index]
  if not section then
    return nil, "no such section"
  end
  collapsed = collapsed and true or false
  if paged.collapsed[index] == collapsed then
    return false
  end

  local start0, end0 = Paged.section_rows(paged, index)
  if not start0 then
    return nil, "section has no rows"
  end
  local stale_for = (opts and opts.stale) or function() return false end
  local replacement = collapsed
    and { render.placeholder(section, stale_for(section) and true or false) }
    or render.section_lines(section)

  local spliced, splice_err =
    paged.list:splice(start0, end0 - start0, replacement)
  if not spliced then
    return nil, "could not splice the paged canvas: " .. tostring(splice_err)
  end

  -- Only after the store agrees: a failed splice must leave the maps
  -- describing what the store still holds, not what was asked for.
  local delta = #replacement - (end0 - start0)
  for later = index + 1, #paged.starts do
    paged.starts[later] = paged.starts[later] + delta
  end
  paged.collapsed[index] = collapsed
  paged.styles[index] = section_styles(section, collapsed)

  -- The skeleton has to grow or shrink with the store before anything reads a
  -- row through it, and the ghosts of the rows that just moved are stale.
  local refreshed, refresh_err = paged.projection:refresh()
  if not refreshed then
    return nil, "could not refresh the projection: " .. tostring(refresh_err)
  end
  if paged.buffer and vim.api.nvim_buf_is_valid(paged.buffer) then
    vim.api.nvim_buf_clear_namespace(paged.buffer, GHOST_NS, 0, -1)
  end
  return true
end

--- Replace one section, or delete it when `section` is nil.
---
--- The same splice `set_collapsed` performs, over a different set of rows, and
--- it is what refresh and the file watcher need: re-rendering a review because
--- one file changed is exactly the cost paging exists to avoid.
--- @return boolean|nil changed
--- @return string|nil error
function Paged.replace_section(paged, index, section, opts)
  if type(paged) ~= "table" or type(paged.starts) ~= "table" then
    return nil, "paged canvas is unavailable"
  end
  if paged.sections[index] == nil then
    return nil, "no such section"
  end

  local start0, end0 = Paged.section_rows(paged, index)
  if not start0 then
    return nil, "section has no rows"
  end

  local replacement = {}
  local collapsed = false
  if section ~= nil then
    local collapsed_for = (opts and opts.collapsed) or function() return false end
    local stale_for = (opts and opts.stale) or function() return false end
    collapsed = collapsed_for(section.path) and true or false
    replacement = collapsed
      and { render.placeholder(section, stale_for(section) and true or false) }
      or render.section_lines(section)
  end

  -- A canvas with no rows at all cannot exist -- the eager one always has at
  -- least a blank line -- so deleting the last section leaves one behind.
  local removing_last = section == nil and #paged.sections == 1
  if removing_last then
    replacement = { "" }
  end

  local spliced, splice_err =
    paged.list:splice(start0, end0 - start0, replacement)
  if not spliced then
    return nil, "could not splice the paged canvas: " .. tostring(splice_err)
  end

  local delta = #replacement - (end0 - start0)
  if section == nil and not removing_last then
    table.remove(paged.sections, index)
    table.remove(paged.starts, index)
    table.remove(paged.styles, index)
    table.remove(paged.collapsed, index)
    for later = index, #paged.starts do
      paged.starts[later] = paged.starts[later] + delta
    end
  else
    if section ~= nil then
      paged.sections[index] = section
      paged.styles[index] = section_styles(section, collapsed)
      paged.collapsed[index] = collapsed
    end
    for later = index + 1, #paged.starts do
      paged.starts[later] = paged.starts[later] + delta
    end
  end
  if paged.state then
    paged.state.sections = paged.sections
  end

  local refreshed, refresh_err = paged.projection:refresh()
  if not refreshed then
    return nil, "could not refresh the projection: " .. tostring(refresh_err)
  end
  if paged.buffer and vim.api.nvim_buf_is_valid(paged.buffer) then
    vim.api.nvim_buf_clear_namespace(paged.buffer, GHOST_NS, 0, -1)
  end
  return true
end

--- Redraw the deletion ghosts for what `window` is currently showing.
---
--- Every ghost outside the visible range is removed and every ghost inside it
--- is placed fresh, so the number of marks on the buffer is bounded by the
--- window height however large the canvas is. Call it after any redraw and
--- after any scroll; calling it more often than necessary is wasted work but
--- never wrong, because it is a full rebuild of a bounded range.
--- @return integer|nil placed how many ghosts are now on the buffer
--- @return string|nil error
function Paged.refresh_ghosts(paged, window, opts)
  if type(paged) ~= "table" or not paged.buffer then
    return nil, "paged canvas is unavailable"
  end
  local buffer = paged.buffer
  if not vim.api.nvim_buf_is_valid(buffer) then
    return nil, "paged canvas buffer is no longer valid"
  end
  if type(window) ~= "number" or not vim.api.nvim_win_is_valid(window)
      or vim.api.nvim_win_get_buf(window) ~= buffer then
    -- A window that is not showing this canvas has no visible range to draw,
    -- which is an ordinary state during teardown rather than a fault.
    vim.api.nvim_buf_clear_namespace(buffer, GHOST_NS, 0, -1)
    return 0
  end

  local overscan = (opts and opts.overscan) or 0
  -- One table, because `nvim_win_call` hands back only its first return value.
  --
  -- Note that this range is measured BEFORE the ghosts are placed, and placing
  -- them changes it: virtual lines occupy screen rows, so fewer logical rows
  -- fit afterwards. The resulting set is therefore a slight superset of what
  -- ends up visible, which is what you want -- the extra ghosts belong to the
  -- rows just below the fold, which are the next ones to be scrolled into.
  local visible = vim.api.nvim_win_call(window, function()
    return { vim.fn.line("w0") - 1, vim.fn.line("w$") - 1 }
  end)
  local first0, last0 = visible[1], visible[2]
  local total = paged.list and paged.list:row_count() or 0
  local start0 = math.max(0, first0 - overscan)
  local end0 = math.min(total - 1, last0 + overscan)

  vim.api.nvim_buf_clear_namespace(buffer, GHOST_NS, 0, -1)
  local placed = 0
  for row0 = start0, end0 do
    local index, offset = Paged.locate(paged, row0)
    -- Collapsed sections render one placeholder row and have no entry to
    -- carry a deletion, so they are skipped rather than mis-indexed.
    if index and not paged.collapsed[index] then
      local entry = paged.sections[index].entries[offset + 1]
      local above = entry and render.ghost_lines(entry, "ghosts")
      if above then
        vim.api.nvim_buf_set_extmark(buffer, GHOST_NS, row0, 0, {
          virt_lines = above,
          virt_lines_above = true,
        })
        placed = placed + 1
      end
    end
  end
  return placed
end

--- Render the section list from scratch, in place.
---
--- The store is spliced wholesale rather than rebuilt so the projection keeps
--- its identity: rebuilding would hand out a new buffer, and every window,
--- lease and mapping pointing at the old one would be pointing at nothing.
--- @return boolean|nil rendered
--- @return string|nil error
function Paged.render_all(paged, sections, opts)
  if type(paged) ~= "table" or not paged.list then
    return nil, "paged canvas is unavailable"
  end
  if type(sections) ~= "table" then
    return nil, "paged canvas requires a section list"
  end
  opts = opts or {}
  local collapsed_for = opts.collapsed or function() return false end
  local stale_for = opts.stale or function() return false end

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
  if #rows == 0 then
    rows[1] = ""
  end

  local spliced, splice_err =
    paged.list:splice(0, paged.list:row_count(), rows)
  if not spliced then
    return nil, "could not re-render the paged canvas: " .. tostring(splice_err)
  end

  paged.sections = sections
  paged.starts = starts
  paged.styles = styles
  paged.collapsed = collapsed_state
  if paged.state then
    paged.state.sections = sections
  end

  local refreshed, refresh_err = paged.projection:refresh()
  if not refreshed then
    return nil, "could not refresh the projection: " .. tostring(refresh_err)
  end
  if paged.buffer and vim.api.nvim_buf_is_valid(paged.buffer) then
    vim.api.nvim_buf_clear_namespace(paged.buffer, GHOST_NS, 0, -1)
  end
  return true
end

--- Insert `section` before position `index`, splicing in only its rows.
--- @return boolean|nil inserted
--- @return string|nil error
function Paged.insert_section(paged, index, section, opts)
  if type(paged) ~= "table" or not paged.list then
    return nil, "paged canvas is unavailable"
  end
  if type(section) ~= "table" then
    return nil, "a section is required"
  end
  local count = #paged.sections
  if type(index) ~= "number" or index < 1 or index > count + 1 then
    return nil, "insert position is outside the canvas"
  end

  opts = opts or {}
  local collapsed_for = opts.collapsed or function() return false end
  local stale_for = opts.stale or function() return false end
  local collapsed = collapsed_for(section.path) and true or false
  local lines = collapsed
    and { render.placeholder(section, stale_for(section) and true or false) }
    or render.section_lines(section)

  -- Inserting into an empty canvas replaces the blank row that stands in for
  -- one, rather than pushing it down and leaving it there forever.
  local empty = count == 0
  local at = empty and 0
    or (index <= count and paged.starts[index] or paged.list:row_count())
  local delete_count = empty and paged.list:row_count() or 0

  local spliced, splice_err = paged.list:splice(at, delete_count, lines)
  if not spliced then
    return nil, "could not splice the paged canvas: " .. tostring(splice_err)
  end

  table.insert(paged.sections, index, section)
  table.insert(paged.starts, index, at)
  table.insert(paged.styles, index, section_styles(section, collapsed))
  table.insert(paged.collapsed, index, collapsed)
  local delta = #lines - delete_count
  for later = index + 1, #paged.starts do
    paged.starts[later] = paged.starts[later] + delta
  end
  if paged.state then
    paged.state.sections = paged.sections
  end

  local refreshed, refresh_err = paged.projection:refresh()
  if not refreshed then
    return nil, "could not refresh the projection: " .. tostring(refresh_err)
  end
  if paged.buffer and vim.api.nvim_buf_is_valid(paged.buffer) then
    vim.api.nvim_buf_clear_namespace(paged.buffer, GHOST_NS, 0, -1)
  end
  return true
end

--- Find the next row matching `pattern`, reading through the store.
---
--- A paged canvas cannot use Neovim's own search, and the reason is the whole
--- design: the buffer holds one BLANK line per logical row, so `/` matches
--- nothing and reports "pattern not found" on a canvas that plainly contains
--- the text. Measured, not assumed -- a needle at logical row 6 leaves buffer
--- line 6 as the empty string, and `search()` returns 0.
---
--- The scan is chunked rather than whole-canvas: a million-row search must not
--- decode a million rows at once, and stopping at the first match usually
--- means decoding very few.
--- @return integer|nil row0 the matching logical row
--- @return string|nil error
function Paged.search(paged, pattern, opts)
  if type(paged) ~= "table" or not paged.list then
    return nil, "paged canvas is unavailable"
  end
  if type(pattern) ~= "string" or pattern == "" then
    return nil, "search pattern must be a non-empty string"
  end
  local compiled, regex_err = pcall(vim.regex, pattern)
  if not compiled then
    return nil, "invalid search pattern: " .. tostring(regex_err)
  end
  local regex = regex_err

  opts = opts or {}
  local total = paged.list:row_count()
  if total == 0 then
    return nil, "the canvas has no rows"
  end
  local from0 = opts.from0 or 0
  if type(from0) ~= "number" or from0 % 1 ~= 0 then
    return nil, "search start must be an integer row"
  end
  local backward = opts.backward and true or false
  local wrap = opts.wrap ~= false

  -- Visit every row exactly once, starting just past `from0` and wrapping,
  -- so a search that finds nothing terminates rather than looping.
  local visited = 0
  local cursor = backward and (from0 - 1) or (from0 + 1)
  local CHUNK = 256
  while visited < total do
    if cursor < 0 or cursor >= total then
      if not wrap then
        return nil
      end
      cursor = cursor < 0 and (total - 1) or 0
    end
    local start0 = backward and math.max(0, cursor - CHUNK + 1) or cursor
    local count = backward and (cursor - start0 + 1)
      or math.min(CHUNK, total - cursor)
    local rows, rows_err = paged.list:rows(start0, count)
    if not rows then
      return nil, "could not read the canvas: " .. tostring(rows_err)
    end
    if backward then
      for index = #rows, 1, -1 do
        if regex:match_str(rows[index]) then
          return start0 + index - 1
        end
        visited = visited + 1
        if visited >= total then
          return nil
        end
      end
      cursor = start0 - 1
    else
      for index = 1, #rows do
        if regex:match_str(rows[index]) then
          return start0 + index - 1
        end
        visited = visited + 1
        if visited >= total then
          return nil
        end
      end
      cursor = start0 + #rows
    end
  end
  return nil
end

--- Put a range of the canvas into a register, as text rather than as blanks.
---
--- Same reason as `search`: yanking on the skeleton buffer copies empty lines,
--- because that is what is in it. Measured -- yanking a 9-row canvas produced
--- 9 bytes and none of the text.
--- @return string|nil text what was placed in the register
--- @return string|nil error
function Paged.yank(paged, start0, count, opts)
  if type(paged) ~= "table" or not paged.projection then
    return nil, "paged canvas is unavailable"
  end
  opts = opts or {}
  local text, export_err = paged.projection:export(start0, count, {
    terminal_eol = true,
  })
  if not text then
    return nil, "could not export the canvas: " .. tostring(export_err)
  end
  local register = opts.register or '"'
  if type(register) ~= "string" or #register ~= 1 then
    return nil, "register must be a single character"
  end
  -- Linewise, because a range of canvas rows is a range of lines. `V` is what
  -- makes a later `p` put them on their own lines rather than inline.
  local set, set_err = pcall(vim.fn.setreg, register, text, "V")
  if not set then
    return nil, "could not set register: " .. tostring(set_err)
  end
  return text
end

--- Tell the compactor the canvas is being used.
---
--- A user scrolling must not be racing a background compactor for the same
--- pages, so activity resets the idle timer rather than competing with it.
--- Silent when there is no scheduler, because an eager canvas has none and
--- every activity hook would otherwise have to know which kind it has.
function Paged.touch(paged)
  local scheduler = paged and paged.scheduler
  if not scheduler then
    return true
  end
  local ok, err = pcall(function() return scheduler:touch() end)
  if not ok then
    return nil, tostring(err)
  end
  return true
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
  if paged.buffer and vim.api.nvim_buf_is_valid(paged.buffer) then
    pcall(vim.api.nvim_buf_clear_namespace, paged.buffer, GHOST_NS, 0, -1)
  end
  local scheduler = paged.scheduler
  paged.scheduler = nil
  if scheduler then
    pcall(function() scheduler:dispose() end)
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
