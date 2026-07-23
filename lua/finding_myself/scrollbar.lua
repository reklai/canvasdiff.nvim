local S = {}

--- One kind per canvas line, sections in render order. hunk_hdr counts as
--- "ctx" (structural, uncolored); file_hdr becomes "hdr" (boundary rows).
function S.line_kinds(sections)
  local kinds = {}
  for _, section in ipairs(sections) do
    for _, e in ipairs(section.entries) do
      if e.kind == "file_hdr" then
        kinds[#kinds + 1] = "hdr"
      elseif e.kind == "add" or e.kind == "del" then
        kinds[#kinds + 1] = e.kind
      else
        kinds[#kinds + 1] = "ctx"
      end
    end
  end
  return kinds
end

--- Bucket per-line kinds into `height` display cells. Row r (1-based)
--- covers 0-based canvas lines [floor((r-1)*n/H), floor(r*n/H)).
--- cell = { char, hl (nil = blank), thumb } per the phase contract.
function S.column(kinds, height, top0, bot0)
  local cells = {}
  if height <= 0 then
    return cells
  end
  local n = #kinds

  for r = 1, height do
    local lo = math.floor((r - 1) * n / height)
    local hi = math.floor(r * n / height) -- exclusive

    local has_hdr, has_add, has_del = false, false, false
    for i = lo + 1, hi do
      local k = kinds[i]
      if k == "hdr" then
        has_hdr = true
      elseif k == "add" then
        has_add = true
      elseif k == "del" then
        has_del = true
      end
    end

    local char, hl = " ", nil
    if has_hdr then
      char, hl = "─", "FmScrollFile"
    elseif has_add and has_del then
      char, hl = "│", "FmScrollChanged"
    elseif has_add then
      char, hl = "│", "FmScrollAdd"
    elseif has_del then
      char, hl = "│", "FmScrollDel"
    end

    -- Thumb: this row's bucket intersects the viewport line range. For the
    -- degenerate n == 0 canvas every bucket is empty -> no thumb.
    local thumb = n > 0 and lo <= bot0 and hi > top0

    cells[r] = { char = char, hl = hl, thumb = thumb }
  end

  return cells
end

return S
