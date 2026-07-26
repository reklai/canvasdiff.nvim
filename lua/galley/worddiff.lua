local differ = require("galley.differ")

local W = {}

-- Guard against quadratic char-diff blowups on minified/generated lines.
local MAX_LINE_BYTES = 500

-- offs[i] = 0-based byte offset where char i starts; offs[#chars + 1] = #line.
local function byte_offsets(chars)
  local offs = { 0 }
  for i, c in ipairs(chars) do
    offs[i + 1] = offs[i] + #c
  end
  return offs
end

local function pair_marks(out, del_row, del_content, add_row, add_content)
  if del_content == add_content or del_content == "" or add_content == "" then
    return
  end
  if #del_content > MAX_LINE_BYTES or #add_content > MAX_LINE_BYTES then
    return
  end

  -- Char-level diff: one character per "line", then map char indices back to
  -- byte columns (multibyte safe -- \zs splits between characters).
  local dc = vim.fn.split(del_content, "\\zs")
  local ac = vim.fn.split(add_content, "\\zs")
  local hunks = differ.hunks(table.concat(dc, "\n"), table.concat(ac, "\n"))
  local doff, aoff = byte_offsets(dc), byte_offsets(ac)

  for _, h in ipairs(hunks) do
    local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]
    -- `del_row = nil` means the deleted line has no buffer row to mark -- it is a
    -- virtual line, and extmarks cannot be placed inside virtual text. Emitting a mark
    -- with a nil row would reach hl.place and throw, so the del side is simply skipped.
    -- Callers that CAN mark a del row still pass one.
    if old_count > 0 and del_row ~= nil then
      out[#out + 1] = {
        row = del_row,
        col = doff[old_start] + 1,
        end_col = doff[old_start + old_count] + 1,
        group = "GalleyWordDel",
        priority = 105,
      }
    end
    if new_count > 0 then
      out[#out + 1] = {
        row = add_row,
        col = aoff[new_start] + 1,
        end_col = aoff[new_start + new_count] + 1,
        group = "GalleyWordAdd",
        priority = 105,
      }
    end
  end
end

--- Char-level word-diff marks for one section (pure data, same shape as
--- hl.section_ts_marks but priority 105). Within each consecutive del-run
--- followed by an add-run, del k pairs with add k; leftovers are unpaired.
function W.section_marks(section)
  local marks = {}
  local entries = section.entries
  for i, e in ipairs(entries) do
    -- Deletions are no longer rows: they ride on the entry that follows them, as
    -- `ghosts`. So the run that used to be "del rows then add rows" is now "this
    -- entry's ghost list, then this entry and the add rows after it", and ghost k
    -- pairs with add k exactly as del k paired with add k before.
    local ghosts = e.ghosts
    if ghosts and e.kind == "add" then
      local astart = i
      local j = i
      while j <= #entries and entries[j].kind == "add" and (j == i or not entries[j].ghosts) do
        j = j + 1
      end
      local npairs = math.min(#ghosts, j - astart)
      for k = 0, npairs - 1 do
        -- Only the ADD side gets marks now. The deleted line is a virtual line, and
        -- extmarks cannot reach into virtual text -- marking its changed span would
        -- mean splitting the ghost into chunks in render.ghost_lines instead. Dropped
        -- deliberately: the add side is the half that says what the code became, and
        -- the ghost renders whole beside it.
        pair_marks(
          marks,
          nil, ghosts[k + 1].content,
          astart + k - 1, entries[astart + k].content
        )
      end
    end
  end
  return marks
end

return W
