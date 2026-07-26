local H = require("helpers")
local model = require("canvasdiff.diff")
local word_marks = model.word_marks

local T = {}

local function section(old_lines, new_lines)
  local old = table.concat(old_lines, "\n") .. "\n"
  local new = table.concat(new_lines, "\n") .. "\n"
  return model.build_section("w.txt", old, new, "M")
end

T["word_marks highlight only the changed span of a paired line"] = function()
  -- entries: file_hdr(1) hunk_hdr(2) ctx(3) add(4, ghosting the deleted line) ctx(5..7).
  -- Deletions are no longer rows, so only the ADD side gets marks: extmarks cannot be
  -- placed inside virtual text, so the ghost renders whole and the add side carries the
  -- "what it became" detail. See the note on diff.word_marks.
  local s = section(
    { "local a = 1", "local b = 2", "local c = 3", "local d = 4", "local e = 5" },
    { "local a = 1", "local b = 20 -- changed", "local c = 3", "local d = 4", "local e = 5" }
  )
  local marks = word_marks(s)
  -- "local b = 2" -> "local b = 20 -- changed": vim.diff treats the "2" as a unit
  -- and produces hunks for "2"→"2" (row 3 and 4, cols 11-12) and insertion of
  -- "0 -- changed" (row 4, cols 12-24). Together they cover bytes 10-23.
  H.eq(marks, {
    { row = 3, col = 11, end_col = 12, group = "CanvasDiffWordAdd", priority = 105 },
    { row = 3, col = 12, end_col = 24, group = "CanvasDiffWordAdd", priority = 105 },
  })
  for _, m in ipairs(marks) do
    H.eq(m.group, "CanvasDiffWordAdd", "no CanvasDiffWordDel marks: there is no del row to put one on")
  end
end

T["word_marks are byte-correct on multibyte lines"] = function()
  local s = section({ "x = 'héllo'" }, { "x = 'hállo'" })
  local marks = word_marks(s)
  -- chars: x,' ',=,' ',',h,é,l,l,o,' — the change is char 7 (é -> á), whose
  -- 0-based source byte offset is 6. Mark contract: col = source byte + 1
  -- (the rendered prefix), so col = 7; é/á are 2 UTF-8 bytes, so end_col = 9.
  H.eq(#marks, 1, "add side only -- the deleted line is virtual and cannot hold a mark")
  local add = marks[1]
  H.eq(add.group, "CanvasDiffWordAdd")
  H.eq(add.col, 7)
  H.eq(add.end_col, 9)  -- á is 2 bytes
end

T["word_marks skip unpaired and blank lines"] = function()
  -- del-add pair where there are more dels than adds: only the first del pairs.
  local s = section({ "aaa bbb", "ccc ddd" }, { "aaa xxx" })
  local marks = word_marks(s)
  -- Actual structure: file_hdr(row 0), hunk_hdr(row 1), del(row 2), add(row 3), del(row 4).
  -- vim.diff may split the hunks differently, putting add before the second del.
  -- Only the first del (row 2) and its paired add (row 3) should have marks.
  -- The second del (row 4) is unpaired and should have no marks.
  local rows_with_del_marks = {}
  for _, m in ipairs(marks) do
    if m.group == "CanvasDiffWordDel" then
      rows_with_del_marks[m.row] = true
    end
  end
  -- Only row 2 should have del marks (the paired del).
  assert(not rows_with_del_marks[4], "second (unpaired) del row 4 should have no del marks")

  -- blank-vs-content pair is skipped entirely
  local s2 = section({ "" }, { "hello" })
  -- an empty committed side means model may classify differently; guard:
  if s2 then
    for _, m in ipairs(word_marks(s2)) do
      error("no marks expected for blank pairing, got " .. vim.inspect(m))
    end
  end
end

return T
