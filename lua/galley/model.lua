local differ = require("galley.differ")
local util = require("galley.util")

local M = {}

local DEFAULT_CONTEXT = 3

local function split_lines(text)
  text = text or ""
  if text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if text:sub(-1) == "\n" then
    lines[#lines] = nil
  end
  return lines
end

-- Old-side "range" of a hunk. Pure-add hunks (old_count == 0) occupy no old
-- lines; treat them as an empty range anchored immediately after old_start,
-- i.e. [old_start + 1, old_start] (start > stop, per the brief's algorithm).
local function old_range(hunk)
  local old_start, old_count = hunk[1], hunk[2]
  if old_count > 0 then
    return old_start, old_start + old_count - 1
  end
  return old_start + 1, old_start
end

local function ctx_window(hunk, context)
  local lo, hi = old_range(hunk)
  return math.max(1, lo - context), hi + context
end

-- Group hunks whose context windows touch or overlap into one displayed hunk.
local function group_hunks(hunks, context)
  local sorted = {}
  for i, h in ipairs(hunks) do sorted[i] = h end
  table.sort(sorted, function(a, b) return a[1] < b[1] end)

  local groups = {}
  local cur, cur_lo, cur_hi
  for _, h in ipairs(sorted) do
    local lo, hi = ctx_window(h, context)
    if cur == nil then
      cur, cur_lo, cur_hi = { h }, lo, hi
    elseif lo <= cur_hi + 1 then
      cur[#cur + 1] = h
      cur_hi = math.max(cur_hi, hi)
    else
      groups[#groups + 1] = { hunks = cur, lo = cur_lo, hi = cur_hi }
      cur, cur_lo, cur_hi = { h }, lo, hi
    end
  end
  if cur then
    groups[#groups + 1] = { hunks = cur, lo = cur_lo, hi = cur_hi }
  end
  return groups
end

local function hunk_header(a, b, c, d)
  return ("@@ -%d,%d +%d,%d @@"):format(a, b, c, d)
end

--- Section shown for a file we refuse to diff. Carries no ctx/add/del
--- entries at all, which is what keeps every downstream consumer safe without
--- each needing its own binary check: the word-diff tier only pairs del/add
--- runs, treesitter highlighting only colors content rows, the statuscolumn
--- only numbers rows with a new_lnum, and hunk motions only stop at hunk
--- headers. None of them find anything here.
local function binary_section(path, old_text, new_text, status)
  return {
    path = path, status = status, binary = true,
    adds = 0, dels = 0, nhunks = 0,
    entries = {
      { kind = "file_hdr", content = path, new_lnum = nil, old_lnum = nil, hunk_idx = nil },
      { kind = "binary", content = "binary file — no diff shown",
        new_lnum = nil, old_lnum = nil, hunk_idx = nil },
    },
    old_text = old_text or "", new_text = new_text or "",
  }
end

function M.build_section(path, old_text, new_text, status, context)
  context = context or DEFAULT_CONTEXT

  -- Binary never gets diffed. vim.text.diff would emit meaningless line noise
  -- for a zip, and the NUL bytes are actively fatal: Vim strings cannot hold
  -- NUL, so one reaching vim.fn.split in the word-diff tier becomes a Blob and
  -- throws E976, taking the whole open() down. git refuses too, printing
  -- "Binary files differ" rather than a patch.
  if util.is_binary(old_text) or util.is_binary(new_text) then
    if (old_text or "") == (new_text or "") then
      return nil
    end
    return binary_section(path, old_text, new_text, status)
  end

  local old_lines = split_lines(old_text)
  local new_lines = split_lines(new_text)
  local raw_hunks = differ.hunks(old_text or "", new_text or "")

  if #raw_hunks == 0 then
    return nil
  end

  local entries = {
    { kind = "file_hdr", content = path, new_lnum = nil, old_lnum = nil, hunk_idx = nil },
  }
  local adds, dels = 0, 0
  local groups = group_hunks(raw_hunks, context)
  local offset = 0 -- new_lnum - old_lnum, valid for unchanged lines up to this point

  for gi, group in ipairs(groups) do
    local window_lo = math.max(1, group.lo)
    local window_hi = math.min(group.hi, #old_lines)
    local offset_before = offset

    local b = math.max(0, window_hi - window_lo + 1)
    local a = b > 0 and window_lo or math.max(0, window_lo - 1)

    local cursor = window_lo
    local hunk_entries = {}
    local new_span_lo, new_span_hi -- track new-side extremes emitted in this group

    local function push(kind, content, old_lnum, new_lnum)
      hunk_entries[#hunk_entries + 1] = {
        kind = kind, content = content, new_lnum = new_lnum, old_lnum = old_lnum, hunk_idx = gi,
      }
      if new_lnum ~= nil then
        new_span_lo = new_span_lo or new_lnum
        new_span_hi = new_lnum
      end
    end

    for _, h in ipairs(group.hunks) do
      local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]

      local ctx_before_end = old_count > 0 and (old_start - 1) or old_start
      for lnum = cursor, ctx_before_end do
        push("ctx", old_lines[lnum], lnum, lnum + offset)
      end

      for i = 0, old_count - 1 do
        local lnum = old_start + i
        push("del", old_lines[lnum], lnum, nil)
        dels = dels + 1
      end

      for i = 0, new_count - 1 do
        local lnum = new_start + i
        push("add", new_lines[lnum], nil, lnum)
        adds = adds + 1
      end

      cursor = ctx_before_end + 1 + old_count
      offset = offset + (new_count - old_count)
    end

    for lnum = cursor, window_hi do
      push("ctx", old_lines[lnum], lnum, lnum + offset)
    end

    local d = 0
    local c
    if new_span_lo then
      d = new_span_hi - new_span_lo + 1
      c = new_span_lo
    else
      c = math.max(0, window_lo + offset_before - 1)
    end

    entries[#entries + 1] = {
      kind = "hunk_hdr", content = hunk_header(a, b, c, d),
      new_lnum = nil, old_lnum = nil, hunk_idx = gi,
    }
    for _, e in ipairs(hunk_entries) do
      entries[#entries + 1] = e
    end
  end

  return {
    path = path, status = status, adds = adds, dels = dels, nhunks = #groups,
    entries = entries,
    old_text = old_text or "", new_text = new_text or "",
  }
end

function M.build(files, context)
  local sections = {}
  for _, f in ipairs(files) do
    local s = M.build_section(f.path, f.old_text, f.new_text, f.status, context)
    if s then
      sections[#sections + 1] = s
    end
  end
  table.sort(sections, function(a, b) return a.path < b.path end)
  return sections
end

return M
