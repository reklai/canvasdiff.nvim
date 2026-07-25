local canvas = require("galley.canvas")
local fold = require("galley.fold")
local config = require("galley.config")
local virt = require("galley.virt")

local M = {}

local function canvas_showing(state)
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

--- Jump `count` sections forward (dir=1) or backward (dir=-1) from the section
--- under the cursor, clamping at the ends and stepping over anything the user
--- set aside. `count` defaults to `vim.v.count1` (so a real `]f`/`[f` mapping
--- honors a leading count).
---
--- The count applies to navigable sections only, so `3]f` means "three files
--- forward that I haven't put away" rather than three indices.
function M.goto_file(state, dir, count)
  count = count or vim.v.count1
  local n = #state.sections
  if n == 0 or not canvas_showing(state) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local i = (canvas.locate(state, cursor[1] - 1)) or 1

  local target
  if config.options.navigate.skip_set_aside then
    local nav = fold.navigable(state.sections, state, virt.auto_set())
    target = fold.step_clamped(nav, i, dir, count)
  else
    target = math.min(math.max(i + dir * count, 1), n)
  end
  if not target then
    return -- nothing to travel to in that direction; stay put
  end

  local start0 = (canvas.section_rows(state, target))
  vim.api.nvim_win_set_cursor(state.win, { start0 + 1, 0 })
end

--- Jump `count` hunk headers forward/backward from the cursor row, across
--- every section that isn't set aside, clamping at the list ends. No-op when
--- there are no hunk headers at all.
---
--- The set-aside check is not an optimization: a set-aside section renders as
--- one row but still carries all its entries, so `start0 + idx - 1` for its
--- hunk headers points into the FOLLOWING files' bodies.
function M.goto_hunk(state, dir, count)
  count = count or vim.v.count1
  if not canvas_showing(state) then
    return
  end

  local rows = {}
  for i, section in ipairs(state.sections) do
    if not fold.hidden(state, section.path) then
      local start0 = (canvas.section_rows(state, i))
      for idx, entry in ipairs(section.entries) do
        if entry.kind == "hunk_hdr" then
          rows[#rows + 1] = start0 + idx - 1
        end
      end
    end
  end
  if #rows == 0 then
    return
  end
  table.sort(rows)

  local cursor_row0 = vim.api.nvim_win_get_cursor(state.win)[1] - 1
  -- `anchor_idx` is the index of the nearest qualifying row (first row
  -- strictly after the cursor for dir=1, or the closest strictly-before row
  -- for dir=-1). No qualifying row means nothing lies in the direction of
  -- travel: clamp at the end and never reverse direction, so return without
  -- moving the cursor. Stepping `count - 1` further in the same direction
  -- from an anchor that DOES qualify and clamping gives the count-th
  -- qualifying row.
  local anchor_idx
  if dir > 0 then
    for i, r in ipairs(rows) do
      if r > cursor_row0 then
        anchor_idx = i
        break
      end
    end
  else
    for i = #rows, 1, -1 do
      if rows[i] < cursor_row0 then
        anchor_idx = i
        break
      end
    end
  end
  if not anchor_idx then
    return
  end

  local target_idx = math.min(math.max(anchor_idx + dir * (count - 1), 1), #rows)
  vim.api.nvim_win_set_cursor(state.win, { rows[target_idx] + 1, 0 })
end

return M
