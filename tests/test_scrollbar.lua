local H = require("helpers")
local model = require("finding_myself.model")
local scrollbar = require("finding_myself.scrollbar")

local T = {}

T["scroll_kinds flattens sections in render order"] = function()
  -- one modified line, context 3: file_hdr, hunk_hdr, ctx, del, add, ctx, ctx, ctx
  local s = model.build_section("a.txt",
    "l1\nl2\nl3\nl4\nl5\n", "l1\nl2x\nl3\nl4\nl5\n", "M")
  local kinds = scrollbar.line_kinds({ s, s })
  H.eq(#kinds, 16)
  H.eq(vim.list_slice(kinds, 1, 8),
    { "hdr", "ctx", "ctx", "del", "add", "ctx", "ctx", "ctx" })
  H.eq(kinds[9], "hdr")
end

T["scroll_column buckets density and file boundaries"] = function()
  -- 40 lines, height 4: buckets of 10
  local kinds = {}
  for i = 1, 40 do kinds[i] = "ctx" end
  kinds[1] = "hdr"        -- bucket 1: file boundary wins
  kinds[15] = "add"       -- bucket 2: adds only
  kinds[25] = "del"       -- bucket 3: dels only
  kinds[35] = "add"
  kinds[36] = "del"       -- bucket 4: mixed
  local cells = scrollbar.column(kinds, 4, 100, 100) -- viewport far away: no thumb
  H.eq(#cells, 4)
  H.eq({ cells[1].char, cells[1].hl }, { "─", "FmScrollFile" })
  H.eq({ cells[2].char, cells[2].hl }, { "│", "FmScrollAdd" })
  H.eq({ cells[3].char, cells[3].hl }, { "│", "FmScrollDel" })
  H.eq({ cells[4].char, cells[4].hl }, { "│", "FmScrollChanged" })
  for r = 1, 4 do H.eq(cells[r].thumb, false) end
end

T["scroll_column blank buckets render empty"] = function()
  local kinds = {}
  for i = 1, 20 do kinds[i] = "ctx" end
  local cells = scrollbar.column(kinds, 2, 100, 100)
  H.eq(cells[1], { char = " ", hl = nil, thumb = false })
  H.eq(cells[2], { char = " ", hl = nil, thumb = false })
end

T["scroll_column thumb covers viewport-intersecting rows only"] = function()
  local kinds = {}
  for i = 1, 100 do kinds[i] = "ctx" end
  -- height 10: row r covers lines [(r-1)*10, r*10); viewport lines 35..54
  local cells = scrollbar.column(kinds, 10, 35, 54)
  local thumbs = {}
  for r = 1, 10 do thumbs[r] = cells[r].thumb end
  H.eq(thumbs, { false, false, false, true, true, true, false, false, false, false })
end

T["scroll_column degenerate inputs are safe"] = function()
  H.eq(scrollbar.column({}, 0, 0, 0), {})
  local cells = scrollbar.column({}, 3, 0, 10)
  H.eq(#cells, 3)
  for r = 1, 3 do
    H.eq(cells[r], { char = " ", hl = nil, thumb = false })
  end
  -- fewer lines than rows: line 1 lands in a well-defined bucket, no crash
  local one = scrollbar.column({ "add" }, 4, 0, 0)
  H.eq(#one, 4)
end

T["scroll_column empty buckets never claim the thumb"] = function()
  -- n=2, height=5: buckets r1=[0,0) r2=[0,0) r3=[0,1) r4=[1,1) r5=[1,2);
  -- viewport [0,1] covers both lines; only the NON-empty buckets r3/r5 thumb
  local cells = scrollbar.column({ "ctx", "ctx" }, 5, 0, 1)
  local thumbs = {}
  for r = 1, 5 do thumbs[r] = cells[r].thumb end
  H.eq(thumbs, { false, false, true, false, true })
end

return T
