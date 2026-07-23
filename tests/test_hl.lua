local H = require("helpers")
local model = require("finding_myself.model")
local hl = require("finding_myself.hl")

local T = {}

local OLD = table.concat({
  "local a = 1",
  "local b = 2",
  "local c = 3",
  "local d = 4",
  "local e = 5",
}, "\n") .. "\n"

local NEW = table.concat({
  "local a = 1",
  "local b = 20 -- changed",
  "local c = 3",
  "local d = 4",
  "local e = 5",
}, "\n") .. "\n"

T["hl_lang_for maps lua files"] = function()
  H.eq(hl.lang_for("foo/bar.lua"), "lua")
end

T["hl_lang_for unknown extension is nil"] = function()
  H.eq(hl.lang_for("foo/bar.qqqzzz"), nil)
end

T["hl_section carries whole-file texts"] = function()
  local s = model.build_section("a.lua", OLD, NEW, "M")
  H.eq(s.old_text, OLD)
  H.eq(s.new_text, NEW)
end

T["hl_ts_marks land on content rows with +1 col offset"] = function()
  -- entries: file_hdr(1) hunk_hdr(2) ctx(3) del(4) add(5) ctx(6) ctx(7) ctx(8)
  local s = model.build_section("a.lua", OLD, NEW, "M")
  local marks = hl.section_ts_marks(s)
  assert(#marks > 0, "expected some marks")
  local by_row = {}
  for _, m in ipairs(marks) do
    by_row[m.row] = by_row[m.row] or {}
    table.insert(by_row[m.row], m)
    H.eq(m.priority, 110)
    assert(m.col >= 1, "col must include the 1-byte prefix offset")
    assert(m.end_col > m.col, "non-empty span")
    assert(m.group:sub(1, 1) == "@", "treesitter group: " .. m.group)
    assert(m.group:sub(-4) == ".lua", "lang-suffixed group: " .. m.group)
  end
  assert(by_row[2], "ctx row (entry 3) highlighted from new side")
  assert(by_row[3], "del row (entry 4) highlighted from old side")
  assert(by_row[4], "add row (entry 5) highlighted from new side")
  H.eq(by_row[0], nil, "file_hdr row never highlighted")
  H.eq(by_row[1], nil, "hunk_hdr row never highlighted")

  -- Known-capture correctness: "local a = 1" has a number capture on the "1"
  -- (source byte col 10) -> buffer cols [11, 12) after the prefix shift.
  local found_number = false
  for _, m in ipairs(by_row[2]) do
    if m.group:find("number", 1, true) then
      found_number = true
      H.eq(m.col, 11, "number starts after 'local a = ' plus prefix")
      H.eq(m.end_col, 12)
    end
  end
  assert(found_number, "expected a @number capture on the ctx line")
end

T["hl_ts_marks unknown language returns empty"] = function()
  local s = model.build_section("a.qqqzzz", OLD, NEW, "M")
  H.eq(hl.section_ts_marks(s), {})
end

T["hl_ts_marks clip multiline captures per displayed row"] = function()
  local old = "local x = 1\n"
  local new = "local x = 1\nlocal s = [[\nhello\nworld\n]]\n"
  -- entries: file_hdr(1) hunk_hdr(2) ctx(3, lnum 1) add(4..7, lnums 2..5)
  local s = model.build_section("ml.lua", old, new, "M")
  local marks = hl.section_ts_marks(s)
  local function full_row_string_mark(row, text)
    for _, m in ipairs(marks) do
      if m.row == row and m.group:find("string", 1, true)
        and m.col == 1 and m.end_col == #text + 1 then
        return true
      end
    end
    return false
  end
  -- middle lines of the [[...]] string ("hello" row 4, "world" row 5) must be
  -- fully covered by per-row clipped @string marks
  assert(full_row_string_mark(4, "hello"), "hello row covered")
  assert(full_row_string_mark(5, "world"), "world row covered")
end

T["hl_cache evicts LRU at capacity and invalidate drops one entry"] = function()
  -- fill well past capacity with distinct paths
  for k = 1, 25 do
    local s = model.build_section(("cache%d.lua"):format(k), OLD, NEW, "M")
    hl.section_ts_marks(s)
  end
  H.eq(hl._cache_size(), 20, "cache bounded at CACHE_CAP")
  hl.invalidate("cache25.lua")
  H.eq(hl._cache_size(), 19, "invalidate drops a cached path")
  hl.invalidate("cache25.lua")
  H.eq(hl._cache_size(), 19, "double invalidate is a no-op")
  hl.invalidate("no-such-path.lua")
  H.eq(hl._cache_size(), 19, "invalidating an unknown path is a no-op")
end

T["hl_cache evicted path still produces correct marks on re-request"] = function()
  local s1 = model.build_section("evictme.lua", OLD, NEW, "M")
  local before = hl.section_ts_marks(s1)
  for k = 1, 21 do
    hl.section_ts_marks(model.build_section(("refill%d.lua"):format(k), OLD, NEW, "M"))
  end
  local after = hl.section_ts_marks(s1)
  H.eq(after, before, "reparse after eviction yields identical marks")
end

return T
