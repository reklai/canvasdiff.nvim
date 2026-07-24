local R = {}

local PREFIX = {
  ctx = " ",
  del = "-",
  add = "+",
}

local HL_GROUP = {
  file_hdr = "GalleyFileHeader",
  hunk_hdr = "GalleyHunkHeader",
  del = "DiffDelete",
  add = "DiffAdd",
}

function R.section_lines(section)
  local lines = {}
  for i, e in ipairs(section.entries) do
    if e.kind == "file_hdr" then
      lines[i] = "▎ " .. e.content .. ("  (+%d −%d)"):format(section.adds, section.dels)
    elseif e.kind == "hunk_hdr" then
      lines[i] = e.content
    else
      lines[i] = PREFIX[e.kind] .. e.content
    end
  end
  return lines
end

--- Single-line summary shown in place of a collapsed section's body.
function R.placeholder(section)
  return "▸ " .. section.path .. ("  (%d hunks, +%d −%d)"):format(section.nhunks, section.adds, section.dels)
end

function R.section_hl(section)
  local marks = {}
  for i, e in ipairs(section.entries) do
    local group = HL_GROUP[e.kind]
    if group then
      marks[#marks + 1] = { row = i - 1, group = group }
    end
  end
  return marks
end

return R
