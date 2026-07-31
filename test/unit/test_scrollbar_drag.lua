local H = require("helpers")
local scrollbar = require("canvasdiff.ui").scrollbar

-- S.locate is the pure inverse of the thumb: which topline does bar row r
-- name? The minimap float is exactly the canvas window's text height, so
-- `bar_height` doubles as the viewport height and the answer ranges over the
-- real scroll range [1, total - height + 1] -- the same positions the thumb
-- itself can occupy. Row 1 means "top of the canvas", the last row means "the
-- last full screen", and everything between is linear interpolation.

local T = {}

T["locate maps the top bar row to topline 1"] = function()
  H.eq(scrollbar.locate(1, 10, 100), 1)
  H.eq(scrollbar.locate(1, 22, 5000), 1)
end

T["locate maps the bottom bar row to the last full screen"] = function()
  H.eq(scrollbar.locate(10, 10, 100), 91)
  -- tall canvas: the bottom row still reaches the end, not floor((H-1)*n/H)
  H.eq(scrollbar.locate(20, 20, 1000), 981)
end

T["locate maps a middle row proportionally"] = function()
  -- H=10, n=100: scroll range spans 90 toplines over 9 row steps -> 10 each
  H.eq(scrollbar.locate(5, 10, 100), 41)
  H.eq(scrollbar.locate(6, 10, 100), 51)
  -- rounds to the nearest topline: row 7 of 20 over 1000 lines
  -- 1 + round(6 * 980 / 19) = 1 + round(309.47) = 310
  H.eq(scrollbar.locate(7, 20, 1000), 310)
end

T["locate clamps rows off both ends of the bar"] = function()
  -- drags keep firing after the pointer leaves the bar (spike Q3), so rows
  -- arrive out of range and must pin to the ends instead of extrapolating
  H.eq(scrollbar.locate(0, 10, 100), 1)
  H.eq(scrollbar.locate(-7, 10, 100), 1)
  H.eq(scrollbar.locate(11, 10, 100), 91)
  H.eq(scrollbar.locate(99, 10, 100), 91)
end

T["locate on a 1-line canvas always answers 1"] = function()
  H.eq(scrollbar.locate(1, 10, 1), 1)
  H.eq(scrollbar.locate(5, 10, 1), 1)
  H.eq(scrollbar.locate(10, 10, 1), 1)
end

T["locate on a canvas no taller than the bar has nothing to scroll"] = function()
  H.eq(scrollbar.locate(7, 10, 8), 1)
  H.eq(scrollbar.locate(10, 10, 10), 1)
end

T["locate degenerate bar heights are safe"] = function()
  H.eq(scrollbar.locate(1, 1, 100), 1)
  H.eq(scrollbar.locate(1, 0, 100), 1)
end

T["locate is monotonic down the bar"] = function()
  local previous = 0
  for row = 1, 22 do
    local top = scrollbar.locate(row, 22, 347)
    assert(top >= previous,
      ("row %d answered %d, below row %d's %d"):format(row, top, row - 1, previous))
    previous = top
  end
  H.eq(previous, 347 - 22 + 1, "the walk ends on the last full screen")
end

return T
