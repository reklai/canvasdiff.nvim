local R = {}

local PREFIX = {
  ctx = " ",
  del = "-",
  add = "+",
}

local HL_GROUP = {
  file_hdr = "GalleyFileHeader",
  hunk_hdr = "GalleyHunkHeader",
  binary = "GalleyBinary",
  del = "DiffDelete",
  add = "DiffAdd",
}

function R.section_lines(section)
  local lines = {}
  for i, e in ipairs(section.entries) do
    if e.kind == "file_hdr" then
      -- "(+0 −0)" on a binary file would read as "nothing changed", which is
      -- the opposite of the truth -- it changed, we just won't show how.
      local counts = section.binary and "  (binary)"
        or ("  (+%d −%d)"):format(section.adds, section.dels)
      lines[i] = "▎ " .. e.content .. counts
    elseif e.kind == "hunk_hdr" then
      lines[i] = e.content
    elseif e.kind == "binary" then
      lines[i] = "  " .. e.content
    else
      lines[i] = PREFIX[e.kind] .. e.content
    end
  end
  return lines
end

--- Single-line summary shown in place of a collapsed section's body.
function R.placeholder(section)
  if section.binary then
    return "▸ " .. section.path .. "  (binary)"
  end
  return "▸ " .. section.path .. ("  (%d hunks, +%d −%d)"):format(section.nhunks, section.adds, section.dels)
end

--- `virt_lines` chunk spec for an entry's deleted lines, or nil when it has none.
---
--- `which` is "ghosts" (deletions that came BEFORE this row) or "ghosts_after" (ones
--- with no row after them at all -- a delete-only hunk, or end of file).
---
--- Shape is what nvim_buf_set_extmark wants: a list of lines, each a list of
--- `{ text, hl }` chunks. One chunk per line here, so a deleted line renders whole.
--- Intra-line word-diff on the ghost side is deliberately NOT attempted: extmarks
--- cannot reach into virtual text, so it would mean splitting each ghost into
--- unchanged/changed/unchanged chunks at render time. The ADD side keeps its
--- word-diff marks, which is the half that says what the code became.
---
--- Keeps the `-` prefix so a ghost still reads as a deletion at a glance, and so the
--- column of content lines up with the ` `/`+` rows around it.
function R.ghost_lines(entry, which)
  local ghosts = entry and entry[which or "ghosts"]
  if not ghosts or #ghosts == 0 then
    return nil
  end
  local lines = {}
  for i, g in ipairs(ghosts) do
    lines[i] = { { PREFIX.del .. (g.content or ""), "GalleyGhost" } }
  end
  return lines
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
