-- Semantic viewport anchors for restoring a stable reading position.
local V = {}

--- Resolve a semantic anchor against a section's line entries.
--- anchor = { new_lnum = int|nil, content = string|nil }
--- entries = list of { new_lnum = int|nil, content = string, kind = string } (1-indexed)
--- Returns the 1-based index of the best match, or nil if entries is empty.
function V.resolve(anchor, entries)
  if #entries == 0 then return nil end

  -- 1. exact match: new_lnum and content both equal.
  for i, e in ipairs(entries) do
    if e.new_lnum == anchor.new_lnum and e.content == anchor.content then
      return i
    end
  end

  -- 2. content match within +/-20 of anchor.new_lnum; nearest by
  --    |new_lnum - anchor.new_lnum| wins ties (first hit breaks exact ties).
  --    A concrete-distance match ALWAYS beats a nil-distance one (nil
  --    new_lnum on either side means the position is unknown, not "close");
  --    nil-distance content matches are only eligible when no concrete
  --    in-range match exists.
  do
    local best_idx, best_dist
    local nil_idx
    for i, e in ipairs(entries) do
      if e.content == anchor.content then
        if e.new_lnum == nil or anchor.new_lnum == nil then
          if nil_idx == nil then nil_idx = i end
        else
          local dist = math.abs(e.new_lnum - anchor.new_lnum)
          if dist <= 20 and (best_idx == nil or dist < best_dist) then
            best_idx, best_dist = i, dist
          end
        end
      end
    end
    if best_idx then return best_idx end
    if nil_idx then return nil_idx end
  end

  -- 3. same new_lnum regardless of content; prefer kind "ctx" over "add".
  do
    local best_idx, best_kind
    for i, e in ipairs(entries) do
      if e.new_lnum == anchor.new_lnum then
        if best_idx == nil then
          best_idx, best_kind = i, e.kind
        elseif best_kind ~= "ctx" and e.kind == "ctx" then
          best_idx, best_kind = i, e.kind
        end
      end
    end
    if best_idx then return best_idx end
  end

  -- 4. nearest hunk_hdr by hunk order, compared against the following
  --    entry's new_lnum.
  if anchor.new_lnum ~= nil then
    local best_idx, best_dist
    for i, e in ipairs(entries) do
      if e.kind == "hunk_hdr" then
        local follow = entries[i + 1]
        local follow_lnum = follow and follow.new_lnum
        if follow_lnum ~= nil then
          local dist = math.abs(follow_lnum - anchor.new_lnum)
          if best_idx == nil or dist < best_dist then
            best_idx, best_dist = i, dist
          end
        end
      end
    end
    if best_idx then return best_idx end
  end

  -- 5. fall back to the first entry.
  return 1
end

--- Capture a semantic anchor for the topmost visible line of a section.
--- entries = a section's line entries (1-indexed)
--- top_offset = 1-based index into entries of the topmost visible line
--- Returns { new_lnum, content, screen_offset } where screen_offset is the
--- delta (chosen index - top_offset), so callers can re-derive topline as
--- resolved_row - screen_offset.
function V.capture_from_entries(entries, top_offset)
  local chosen

  -- walk down from top_offset looking for the first ctx entry within 5 entries
  for i = top_offset, math.min(top_offset + 5, #entries) do
    if entries[i].kind == "ctx" then
      chosen = i
      break
    end
  end

  -- else walk up
  if not chosen then
    for i = top_offset, math.max(top_offset - 5, 1), -1 do
      if entries[i].kind == "ctx" then
        chosen = i
        break
      end
    end
  end

  -- else use the entry at top_offset itself
  if not chosen then
    chosen = top_offset
  end

  local e = entries[chosen]
  return {
    new_lnum = e.new_lnum,
    content = e.content,
    screen_offset = chosen - top_offset,
  }
end

return V
