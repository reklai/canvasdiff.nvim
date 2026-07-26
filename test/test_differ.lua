local H = require("helpers")
local differ = require("canvasdiff.differ")
return {
  ["differ: simple change"] = function()
    local h = differ.hunks("a\nb\nc\n", "a\nX\nc\n")
    H.eq(h, { { 2, 1, 2, 1 } })
  end,
  ["differ: pure addition"] = function()
    local h = differ.hunks("a\nc\n", "a\nb\nc\n")
    H.eq(h, { { 1, 0, 2, 1 } })
  end,
  ["differ: empty old side (new file)"] = function()
    local h = differ.hunks("", "a\nb\n")
    H.eq(#h, 1)
    H.eq(h[1][4], 2) -- new_count covers whole file
  end,
}
