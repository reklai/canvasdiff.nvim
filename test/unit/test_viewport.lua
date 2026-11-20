local H = require("helpers")
local V = require("canvasdiff.diff").anchor

local function mkentries(n)
  local es = {}
  for i = 1, n do
    es[i] = { new_lnum = i, content = "line " .. i, kind = "ctx" }
  end
  return es
end

return {
  ["viewport: exact match wins"] = function()
    local es = mkentries(50)
    H.eq(V.resolve({ new_lnum = 10, content = "line 10" }, es), 10)
  end,
  ["viewport: content match survives line drift"] = function()
    local es = mkentries(50)
    table.insert(es, 5, { new_lnum = nil, content = "inserted", kind = "add" })
    -- entries after index 5 shifted; content "line 10" now at index 11
    H.eq(V.resolve({ new_lnum = 10, content = "line 10" }, es), 11)
  end,
  ["viewport: same lnum different content"] = function()
    local es = mkentries(50)
    es[10].content = "edited!"
    H.eq(V.resolve({ new_lnum = 10, content = "line 10 gone" }, es), 10)
  end,
  ["viewport: empty entries"] = function()
    H.eq(V.resolve({ new_lnum = 1, content = "x" }, {}), nil)
  end,
  ["viewport: rung2 prefers concrete distance over nil-distance content match"] = function()
    -- content "shared" matches both a del entry (unknown new_lnum) and a ctx
    -- entry 2 away from the anchor; the concrete-distance match must win.
    local es = {
      { new_lnum = nil, content = "shared", kind = "del" },
      { new_lnum = 12, content = "shared", kind = "ctx" },
    }
    H.eq(V.resolve({ new_lnum = 10, content = "shared" }, es), 2)
  end,
  ["viewport: rung4 falls back to nearest hunk_hdr when hunk vanished"] = function()
    local es = {
      { new_lnum = nil, content = "@@ hunk1 @@", kind = "hunk_hdr" },
      { new_lnum = 10, content = "line 10", kind = "ctx" },
      { new_lnum = nil, content = "@@ hunk2 @@", kind = "hunk_hdr" },
      { new_lnum = 50, content = "line 50", kind = "ctx" },
    }
    -- anchor's content matches nothing and its new_lnum (48) matches no
    -- entry; the second hunk_hdr is nearest (its following entry is 50).
    H.eq(V.resolve({ new_lnum = 48, content = "vanished line" }, es), 3)
  end,
  -- The reverse of a jump: a file line names its row outright, with no
  -- content rung, because every content row carries a distinct new_lnum.
  ["viewport: nearest names the row showing a file line"] = function()
    local es = {
      { content = "f", kind = "file_hdr" },
      { content = "@@", kind = "hunk_hdr" },
      { new_lnum = 10, content = "same", kind = "ctx" },
      { new_lnum = 11, content = "same", kind = "add" },
      { new_lnum = 12, content = "same", kind = "ctx" },
    }
    H.eq({ V.nearest(es, 11) }, { 4, true })
  end,
  ["viewport: nearest stands in the closest shown line for one off the canvas"] = function()
    local es = {
      { content = "f", kind = "file_hdr" },
      { content = "@@", kind = "hunk_hdr" },
      { new_lnum = 10, content = "a", kind = "ctx" },
      { new_lnum = 11, content = "b", kind = "add" },
      { content = "@@", kind = "hunk_hdr" },
      { new_lnum = 40, content = "c", kind = "add" },
      { new_lnum = 41, content = "d", kind = "ctx" },
    }
    H.eq({ V.nearest(es, 1) }, { 3, false }, "above the first hunk")
    H.eq({ V.nearest(es, 35) }, { 6, false }, "nearer the second hunk")
    H.eq({ V.nearest(es, 500) }, { 7, false }, "below the last hunk")
    -- 11 and 40 are both 14.5 +- .5 away from 25/26; the tie itself:
    es[6].new_lnum = 39
    H.eq({ V.nearest(es, 25) }, { 4, false }, "an equal distance goes to the earlier hunk")
  end,
  ["viewport: nearest answers nil when no row maps to a file line"] = function()
    H.eq({ V.nearest({}, 3) }, { nil, false })
    H.eq({ V.nearest({
      { content = "f", kind = "file_hdr" },
      { content = "gone", kind = "del" },
    }, 3) }, { nil, false })
  end,
  ["viewport: capture prefers ctx below top"] = function()
    local es = {
      { new_lnum = nil, content = "+new", kind = "add" },
      { new_lnum = 8, content = "stable", kind = "ctx" },
    }
    local a = V.capture_from_entries(es, 1)
    H.eq(a.content, "stable")
    H.eq(a.screen_offset, 1)
  end,
  ["viewport: fuzz - resolution lands within 2 of true position"] = function()
    math.randomseed(42)
    for trial = 1, 200 do
      local es = mkentries(100)
      local target = math.random(20, 80)
      local anchor = { new_lnum = es[target].new_lnum, content = es[target].content }
      -- random edits: insert/delete up to 10 entries away from target
      for _ = 1, math.random(0, 10) do
        local pos = math.random(1, #es)
        if math.abs(pos - target) > 3 then
          if math.random() < 0.5 then
            table.insert(es, pos, { new_lnum = nil, content = "noise " .. math.random(1e6), kind = "add" })
            if pos <= target then target = target + 1 end
          elseif #es > 30 then
            table.remove(es, pos)
            if pos < target then target = target - 1 end
          end
        end
      end
      local got = V.resolve(anchor, es)
      assert(got and math.abs(got - target) <= 2,
        ("trial %d: resolved %s, true %d"):format(trial, tostring(got), target))
    end
  end,
}
