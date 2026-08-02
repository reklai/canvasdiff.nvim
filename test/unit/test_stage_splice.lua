-- Staging one hunk, as arithmetic over a pair of blobs: no git, no canvas,
-- no cursor. Every expectation here is a byte string, because the result of
-- this module IS the bytes that get written into someone's index.

local H = require("helpers")
local stage = require("canvasdiff.diff").stage

local T = {}

--- Two rewrites and a trailing addition, spaced so they stay three hunks.
local A = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n"
local B = "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nten\nELEVEN\n"

--- Two deletions, the first of them two lines long. Both have a zero b-side
--- count, so neither owns a new-side line to be found by.
local DEL_A = "alpha\nGONE\nALSO\nbravo\ncharlie\ndelta\necho\nfoxtrot\nDROP\ngolf\n"
local DEL_B = "alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\ngolf\n"

--- One hunk three lines wide: a window with a distinguishable first and last
--- line, which a single-line hunk cannot give an edge test.
local WIDE_A = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n"
local WIDE_B = "one\nTWO\nTHREE\nFOUR\nfive\nsix\nseven\n"

T["stage_pair_hunks reports the pair's index tuples"] = function()
  H.eq(stage.pair_hunks(A, B), { { 2, 1, 2, 1 }, { 9, 1, 9, 1 }, { 10, 0, 11, 1 } },
    "two rewrites and an insert after a-line 10")
  H.eq(stage.pair_hunks(DEL_A, DEL_B), { { 2, 2, 1, 0 }, { 9, 1, 6, 0 } },
    "a deletion is a zero b-side count at the seam it cuts")
  H.eq(stage.pair_hunks(A, A), {}, "an identical pair has no hunks")
end

T["stage_splice applies one hunk and leaves the other changes alone"] = function()
  local hunks = stage.pair_hunks(A, B)
  H.eq(stage.splice(A, B, stage.pick(hunks, { lo = 2, hi = 2 })),
    "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n",
    "TWO lands; NINE and ELEVEN stay behind on the b side")
  H.eq(stage.splice(A, B, stage.pick(hunks, { lo = 9, hi = 9 })),
    "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nten\n",
    "and the middle hunk alone, with two and the addition untouched")
end

T["stage_splice replaces a multi-line hunk with its b-side lines"] = function()
  local h = stage.pick(stage.pair_hunks(WIDE_A, WIDE_B), { lo = 2, hi = 4 })
  H.eq(stage.splice(WIDE_A, WIDE_B, h), "one\nTWO\nTHREE\nFOUR\nfive\nsix\nseven\n",
    "three lines out, three lines in, and five still follows")
end

T["stage_splice inserts a trailing addition instead of replacing"] = function()
  local h = stage.pick(stage.pair_hunks(A, B), { lo = 11, hi = 11 })
  H.eq(stage.splice(A, B, h),
    "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\nELEVEN\n",
    "ten survives the line appended after it")
end

T["stage_splice removes exactly the lines one deletion drops"] = function()
  local hunks = stage.pair_hunks(DEL_A, DEL_B)
  H.eq(stage.splice(DEL_A, DEL_B, stage.pick(hunks, { lo = 1, hi = 2 })),
    "alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\nDROP\ngolf\n",
    "both lines of the first deletion go, and DROP stays")
  H.eq(stage.splice(DEL_A, DEL_B, stage.pick(hunks, { lo = 6, hi = 7 })),
    "alpha\nGONE\nALSO\nbravo\ncharlie\ndelta\necho\nfoxtrot\ngolf\n",
    "the second deletion alone, with GONE and ALSO still there")
end

T["stage_splice deletes the first line of a file"] = function()
  local a, b = "GONE\none\ntwo\n", "one\ntwo\n"
  local h = stage.pick(stage.pair_hunks(a, b), { lo = 1, hi = 1 })
  H.eq(stage.splice(a, b, h), "one\ntwo\n", "nothing precedes the cut to keep")
end

T["stage_splice keeps hunks a single line apart independent"] = function()
  local a, b = "a\nb\nc\nd\ne\n", "a\nB\nc\nD\ne\n"
  local hunks = stage.pair_hunks(a, b)
  H.eq(#hunks, 2, "one unchanged line between them is enough to keep them apart")
  H.eq(stage.splice(a, b, stage.pick(hunks, { lo = 2, hi = 2 })), "a\nB\nc\nd\ne\n",
    "the earlier hunk alone")
  H.eq(stage.splice(a, b, stage.pick(hunks, { lo = 4, hi = 4 })), "a\nb\nc\nD\ne\n",
    "the later hunk alone")
end

T["stage_splice preserves the a side's trailing-newline shape"] = function()
  local bare_a, bare_b = "one\ntwo\nthree", "one\nTWO\nthree"
  H.eq(stage.splice(bare_a, bare_b, stage.pick(stage.pair_hunks(bare_a, bare_b), { lo = 2, hi = 2 })),
    "one\nTWO\nthree", "a blob with no final newline splices back without one")

  local term_a, term_b = "one\ntwo\nthree\n", "one\nTWO\nthree\n"
  H.eq(stage.splice(term_a, term_b, stage.pick(stage.pair_hunks(term_a, term_b), { lo = 2, hi = 2 })),
    "one\nTWO\nthree\n", "and one that ends with a newline keeps it")

  local lost_a, lost_b = "one\ntwo\n", "one\ntwo"
  H.eq(stage.splice(lost_a, lost_b, stage.pick(stage.pair_hunks(lost_a, lost_b), { lo = 2, hi = 2 })),
    "one\ntwo\n", "the terminator is the a side's; a b side that dropped it cannot")
end

T["stage_splice is byte-exact over CRLF content"] = function()
  local a = "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\n"
  local b = "one\r\nTWO\r\nthree\r\nfour\r\nfive\r\nSIX\r\n"
  local h = stage.pick(stage.pair_hunks(a, b), { lo = 2, hi = 2 })
  H.eq(stage.splice(a, b, h), "one\r\nTWO\r\nthree\r\nfour\r\nfive\r\nsix\r\n",
    "every carriage return survives, and only the first hunk moved")
end

T["stage_splice fills an empty a side from the b side"] = function()
  local b = "alpha\nbravo\n"
  local h = stage.pick(stage.pair_hunks("", b), { lo = 1, hi = 2 })
  H.eq(stage.splice("", b, h), "alpha\nbravo\n", "a file with no index blob yet")
end

T["stage_splice empties the a side when the hunk deletes every line"] = function()
  local a = "one\ntwo\n"
  local h = stage.pick(stage.pair_hunks(a, ""), { lo = 1, hi = 1 })
  H.eq(stage.splice(a, "", h), "", "an emptied file is empty, not a lone newline")
end

T["stage_pick returns nil when no hunk overlaps the span"] = function()
  local hunks = stage.pair_hunks(A, B)
  H.eq(stage.pick(hunks, { lo = 5, hi = 5 }), nil, "unchanged ground between hunks")
  H.eq(stage.pick(hunks, { lo = 4, hi = 7 }), nil, "a wide span still clear of both")
  H.eq(stage.pick({}, { lo = 1, hi = 1 }), nil, "no hunks at all")
end

-- A span from the canvas is a HULL: first through last worktree line the
-- displayed hunk writes, unchanged lines between merged changes included. So
-- the test is overlap, never equality or containment.
T["stage_pick matches a hull wider than the hunk it names"] = function()
  local hunks = stage.pair_hunks(A, B)
  H.eq(stage.pick(hunks, { lo = 2, hi = 4 }), hunks[1], "the hull runs past the change")
  H.eq(stage.pick(hunks, { lo = 1, hi = 3 }), hunks[1], "and can start before it")
  H.eq(stage.pick(hunks, { lo = 8, hi = 12 }), hunks[2],
    "a hull swallowing two hunks answers with the first of them")
end

T["stage_pick matches a span meeting either edge of the hunk window"] = function()
  local hunks = stage.pair_hunks(WIDE_A, WIDE_B)
  H.eq(hunks[1], { 2, 3, 2, 3 }, "sanity: the window is b-lines 2 through 4")
  H.eq(stage.pick(hunks, { lo = 1, hi = 2 }), hunks[1], "span ends on the window's first line")
  H.eq(stage.pick(hunks, { lo = 4, hi = 6 }), hunks[1], "span starts on the window's last line")
  H.eq(stage.pick(hunks, { lo = 1, hi = 1 }), nil, "one line short below it")
  H.eq(stage.pick(hunks, { lo = 5, hi = 7 }), nil, "one line past it")
end

-- A deletion writes no new-side line, so an exact window would be empty and
-- nothing could ever land on it. Its window is the seam: the two lines the
-- cut sits between.
T["stage_pick widens a deletion into the seam around the cut"] = function()
  local hunks = stage.pair_hunks(DEL_A, DEL_B)
  H.eq(stage.pick(hunks, { lo = 1, hi = 1 }), hunks[1], "the line before the first cut")
  H.eq(stage.pick(hunks, { lo = 2, hi = 2 }), hunks[1], "and the line after it")
  H.eq(stage.pick(hunks, { lo = 6, hi = 6 }), hunks[2], "the line before the second cut")
  H.eq(stage.pick(hunks, { lo = 7, hi = 7 }), hunks[2], "and the line after that one")
  H.eq(stage.pick(hunks, { lo = 3, hi = 3 }), nil, "one line past the first seam")
  H.eq(stage.pick(hunks, { lo = 5, hi = 5 }), nil, "one line short of the second")
end

T["stage_pick finds a deletion whose seam opens the file"] = function()
  local hunks = stage.pair_hunks("GONE\none\ntwo\n", "one\ntwo\n")
  H.eq(hunks[1], { 1, 1, 0, 0 }, "sanity: the cut sits before b-line 1")
  H.eq(stage.pick(hunks, { lo = 1, hi = 1 }), hunks[1], "the only line the seam can be found by")
  H.eq(stage.pick(hunks, { lo = 2, hi = 2 }), nil, "a line clear of the seam is not it")
end

return T
