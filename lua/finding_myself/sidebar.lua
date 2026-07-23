local S = {}

--- Flatten alphabetical sections into display-ordered dir/file entries.
--- `folded` is a set of dir paths ("lua/mod/" -- cumulative, trailing
--- slash); a folded dir is shown itself but none of its descendants are.
--- Sections are sorted by path, so each dir is emitted exactly once,
--- immediately before its first descendant.
function S.build_entries(sections, folded)
  folded = folded or {}
  local entries = {}
  local prev_dirs = {}

  for i, section in ipairs(sections) do
    local parts = vim.split(section.path, "/", { plain = true })
    local fname = table.remove(parts)

    local shared = 0
    for d = 1, math.min(#prev_dirs, #parts) do
      if prev_dirs[d] == parts[d] then
        shared = d
      else
        break
      end
    end

    local hidden = false
    local prefix = ""
    for d = 1, #parts do
      prefix = prefix .. parts[d] .. "/"
      if not hidden then
        if d > shared then
          entries[#entries + 1] = {
            kind = "dir", path = prefix, name = parts[d] .. "/",
            depth = d - 1, folded = folded[prefix] or false,
          }
        end
        if folded[prefix] then
          hidden = true
        end
      end
    end

    if not hidden then
      entries[#entries + 1] = {
        kind = "file", path = section.path, name = fname, depth = #parts,
        section_i = i, adds = section.adds, dels = section.dels,
      }
    end
    prev_dirs = parts
  end

  return entries
end

--- Render entries to display lines (pure).
function S.render_lines(entries)
  local lines = {}
  for i, e in ipairs(entries) do
    local indent = ("  "):rep(e.depth)
    if e.kind == "dir" then
      lines[i] = indent .. (e.folded and "▸ " or "▾ ") .. e.name
    else
      lines[i] = indent .. e.name .. ("  +%d −%d"):format(e.adds, e.dels)
    end
  end
  return lines
end

return S
