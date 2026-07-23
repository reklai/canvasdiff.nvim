local differ = require("finding_myself.differ")

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
    if old_count > 0 then
      out[#out + 1] = {
        row = del_row,
        col = doff[old_start] + 1,
        end_col = doff[old_start + old_count] + 1,
        group = "FmWordDel",
        priority = 105,
      }
    end
    if new_count > 0 then
      out[#out + 1] = {
        row = add_row,
        col = aoff[new_start] + 1,
        end_col = aoff[new_start + new_count] + 1,
        group = "FmWordAdd",
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
  local i = 1
  while i <= #entries do
    if entries[i].kind == "del" then
      local dstart = i
      while i <= #entries and entries[i].kind == "del" do
        i = i + 1
      end
      local astart = i
      while i <= #entries and entries[i].kind == "add" do
        i = i + 1
      end
      local npairs = math.min(astart - dstart, i - astart)
      for k = 0, npairs - 1 do
        pair_marks(
          marks,
          dstart + k - 1, entries[dstart + k].content,
          astart + k - 1, entries[astart + k].content
        )
      end
    else
      i = i + 1
    end
  end
  return marks
end

return W
