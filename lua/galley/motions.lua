local canvas = require("galley.canvas")
local fold = require("galley.fold")

local M = {}

local function canvas_showing(state)
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

--- The section index `count` steps from section `i` in direction `dir`. `wrap`
--- selects the Ctrl+N / Ctrl+P semantics over ]f / [f's clamping.
---
--- Every section is a stop, including a folded one -- a folded file renders as a
--- single placeholder row, and landing on it is the point: you press Tab there to
--- unfold and carry on. Navigation used to step OVER folded files, which made
--- folding mean "done with this" instead of just "collapsed", and needed a whole
--- parallel index space (a navigable-indices list plus two stepping functions) to
--- express.
---
--- One home for the arithmetic, shared by goto_file and sidebar.cycle, so a count
--- of 0 cannot mean different things in the two of them -- it clamps to 1 here,
--- matching Vim's count1 semantics (there is no zero-count motion).
function M.step(state, i, dir, count, wrap)
  count = math.max(1, count or 1)
  local n = #state.sections
  if n == 0 then
    return nil
  end
  if wrap then
    return ((i - 1 + dir * count) % n) + 1
  end
  return math.min(math.max(i + dir * count, 1), n)
end

--- Jump `count` sections forward (dir=1) or backward (dir=-1) from the section
--- under the cursor, clamping at the ends. Lands on a folded file's placeholder
--- like any other section. `count` defaults to `vim.v.count1`, so a real `]f`/`[f`
--- mapping honors a leading count.
function M.goto_file(state, dir, count)
  if #state.sections == 0 or not canvas_showing(state) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local i = (canvas.locate(state, cursor[1] - 1)) or 1

  local target = M.step(state, i, dir, count or vim.v.count1, false)
  if not target then
    return -- nothing to travel to in that direction; stay put
  end

  local start0 = (canvas.section_rows(state, target))
  vim.api.nvim_win_set_cursor(state.win, { start0 + 1, 0 })
end

--- Jump `count` stops forward/backward from the cursor row, clamping at the list
--- ends. No-op when there are no stops at all.
---
--- A stop is a hunk header -- except in a FOLDED file, which contributes exactly
--- one: its placeholder row. So `]h` walks into a folded file rather than over it,
--- and you press Tab there to unfold and keep going. That is what a closed fold
--- means in Vim too: one line that motions land on.
---
--- The folded case cannot use the section's entries, and that part is arithmetic
--- rather than policy: a folded section renders as one row but still carries every
--- entry, so `start0 + idx - 1` for its hunk headers would point into the FOLLOWING
--- files' bodies. Its start row is the only row it actually owns.
---
--- A folded DIRECTORY is therefore one stop PER FILE under it, not one stop total --
--- the canvas has no directory rows, only a placeholder per file, and you can only
--- land on rows that exist.
---
--- PRECONDITION: `state.folded`/`state.collapsed` and the buffer agree about which
--- sections are one row. Every mutation site guarantees that by calling
--- canvas.resync_visibility (init.reveal, sidebar.select, session.restore) or by
--- going through canvas.set_collapsed. Assigning `state.folded` directly without a
--- resync makes this compute rows past the end of the buffer and throw out of the
--- keymap. Deliberately NOT clamped: a divergence like that is a bug worth a
--- traceback, and clamping would turn it into `]h` quietly landing somewhere wrong.
function M.goto_hunk(state, dir, count)
  count = count or vim.v.count1
  if not canvas_showing(state) then
    return
  end

  local rows = {}
  for i, section in ipairs(state.sections) do
    local start0 = (canvas.section_rows(state, i))
    if fold.hidden(state, section.path) then
      rows[#rows + 1] = start0
    else
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
