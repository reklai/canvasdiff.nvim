local canvas = require("canvasdiff.canvas")
local fold = require("canvasdiff.diff").fold

local M = {}

local canvas_showing = canvas.win_showing_canvas

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
--- One home for the arithmetic, shared by goto_file and cycle, so a count
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
function M.goto_file(state, dir, count, win)
  win = win or state.win
  if #state.sections == 0 or not canvas_showing(state, win) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local i = (canvas.locate(state, cursor[1] - 1)) or 1

  local target = M.step(state, i, dir, count or vim.v.count1, false)
  if not target then
    return -- nothing to travel to in that direction; stay put
  end

  local start0 = (canvas.section_rows(state, target))
  vim.api.nvim_win_set_cursor(win, { start0 + 1, 0 })
  return target
end

--- Scroll one explicit Canvas window by sections, wrapping at both ends.
--- This is a Canvas motion even when no sidebar lease exists; the App may
--- separately ask an acquired sidebar lease to follow the resulting view.
function M.cycle(state, win, dir, count)
  win = win or state.win
  if #state.sections == 0 or not canvas_showing(state, win) then
    return
  end
  local top0 = vim.api.nvim_win_call(win, function()
    return vim.fn.line("w0") - 1
  end)
  local i = (canvas.locate(state, top0)) or 1
  local target = M.step(state, i, dir, count or vim.v.count1, true)
  if not target then
    return
  end

  local start0 = (canvas.section_rows(state, target))
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = start0 + 1, lnum = start0 + 1 })
  end)
  return target
end

--- Every row a hunk motion stops on, ascending, 0-based. One home for the stop
--- list, shared by `]h`/`[h` and by Ctrl+N/Ctrl+P -- the two differ in what they
--- do at the ends, not in where they may land.
---
--- A stop is a hunk header -- except in a FOLDED file, which contributes exactly
--- one: its placeholder row. So `]h` walks into a folded file rather than over it,
--- and you press Tab there to unfold and keep going. That is what a closed fold
--- means in Vim too: one line that motions land on.
---
--- A file header is never a stop: it is where hunks live, not a destination.
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
--- canvas.resync_visibility (App's reveal, sidebar.select, session.restore) or by
--- going through canvas.set_collapsed. Assigning `state.folded` directly without a
--- resync makes this compute rows past the end of the buffer and throw out of the
--- keymap. Deliberately NOT clamped: a divergence like that is a bug worth a
--- traceback, and clamping would turn it into `]h` quietly landing somewhere wrong.
function M.hunk_stops(state)
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
  table.sort(rows)
  return rows
end

--- Scroll `count` hunk stops, wrapping at both ends -- Ctrl+N / Ctrl+P's
--- mechanics at `]h`'s granularity, on the view rather than the cursor.
---
--- Where `]h` clamps, this wraps. That asymmetry is the point: clamping is what
--- makes "I have seen every hunk" detectable, so the sweep keeps its finish line
--- while this is the free-scrolling walk over the same stops.
---
--- The wrap is M.step's arithmetic in the stop index space. M.step itself indexes
--- SECTIONS, and there is no honest way to hand it a stop list without inventing a
--- second state to carry it.
---
--- @return integer|nil the 0-based row it scrolled to
function M.cycle_hunk(state, win, dir, count)
  win = win or state.win
  if not canvas_showing(state, win) then
    return
  end
  local stops = M.hunk_stops(state)
  if #stops == 0 then
    return
  end

  local top0 = vim.api.nvim_win_call(win, function()
    return vim.fn.line("w0") - 1
  end)
  -- Where we are: the last stop at or before the topline.
  local at = 0
  for i, row in ipairs(stops) do
    if row <= top0 then
      at = i
    else
      break
    end
  end
  -- A topline above every stop -- the rows before a file's first hunk header --
  -- is the one position the section cycle never sees, because locate() puts every
  -- row in a section while those rows belong to no stop. Forward it is "one before
  -- the first", so `at = 0` lands on stops[1]; backward it has to behave like
  -- BEING on the first, or the wrap would skip the last stop and hand back the
  -- one before it.
  if at == 0 and dir < 0 then
    at = 1
  end

  count = math.max(1, count or vim.v.count1)
  local row0 = stops[((at - 1 + dir * count) % #stops) + 1]
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = row0 + 1, lnum = row0 + 1 })
  end)
  return row0
end

--- Jump `count` stops forward/backward from the cursor row, clamping at the list
--- ends. No-op when there are no stops at all. The stops are M.hunk_stops's.
function M.goto_hunk(state, dir, count, win)
  win = win or state.win
  count = count or vim.v.count1
  if not canvas_showing(state, win) then
    return
  end

  local rows = M.hunk_stops(state)
  if #rows == 0 then
    return
  end

  local cursor_row0 = vim.api.nvim_win_get_cursor(win)[1] - 1
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
  vim.api.nvim_win_set_cursor(win, { rows[target_idx] + 1, 0 })
  return target_idx
end

return M
