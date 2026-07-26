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

--- Attach the identity/source metadata every kind of section carries.
---
--- `metadata` is optional so direct model callers keep the compact historical
--- signature. collect passes its complete file record, which makes old_path and
--- old_rev available to rendering now and to rename-aware navigation later.
local function with_metadata(section, path, old_text, new_text, status, metadata)
  metadata = metadata or {}
  section.path = path
  section.old_path = metadata.old_path or path
  section.old_rev = metadata.old_rev
  section.status = status
  section.staged = metadata.staged
  section.unstaged = metadata.unstaged
  section.renamed = section.old_path ~= path
  section.old_text = old_text or ""
  section.new_text = new_text or ""
  return section
end

--- Section shown for a file we refuse to diff. Carries no ctx/add/del
--- entries at all, which is what keeps every downstream consumer safe without
--- each needing its own binary check: the word-diff tier only pairs del/add
--- runs, treesitter highlighting only colors content rows, the statuscolumn
--- only numbers rows with a new_lnum, and hunk motions only stop at hunk
--- headers. None of them find anything here.
local function binary_section(path, old_text, new_text, status, metadata)
  return with_metadata({
    binary = true,
    adds = 0, dels = 0, nhunks = 0,
    entries = {
      { kind = "file_hdr", content = path, new_lnum = nil, old_lnum = nil, hunk_idx = nil },
      { kind = "binary", content = "binary file — no diff shown",
        new_lnum = nil, old_lnum = nil, hunk_idx = nil },
    },
  }, path, old_text, new_text, status, metadata)
end

--- Build one section.
---
--- The optional sixth argument carries source identity without making the pure
--- diff inputs positional: `{ old_path, old_rev, staged, unstaged }`.
function M.build_section(path, old_text, new_text, status, context, metadata)
  context = context or DEFAULT_CONTEXT
  local old = old_text or ""
  local new = new_text or ""
  local old_path = metadata and metadata.old_path or path
  local renamed = old_path ~= path
  local binary = util.is_binary(old) or util.is_binary(new)

  -- Identity is itself a reviewable change. Git reports a pure rename with
  -- byte-identical blobs, so differ.hunks quite correctly returns nothing;
  -- retain it as one header row instead of mistaking "no text delta" for "no
  -- change". This deliberately precedes the binary branch: an unchanged binary
  -- rename is safe to show because no blob content ever enters a buffer row.
  if old == new then
    if not renamed then
      return nil
    end
    return with_metadata({
      binary = binary or nil,
      rename_only = true,
      adds = 0, dels = 0, nhunks = 0,
      entries = {
        { kind = "file_hdr", content = path,
          new_lnum = nil, old_lnum = nil, hunk_idx = nil },
      },
    }, path, old, new, status, metadata)
  end

  -- Binary never gets diffed. vim.text.diff would emit meaningless line noise
  -- for a zip, and the NUL bytes are actively fatal: Vim strings cannot hold
  -- NUL, so one reaching vim.fn.split in the word-diff tier becomes a Blob and
  -- throws E976, taking the whole open() down. git refuses too, printing
  -- "Binary files differ" rather than a patch.
  if binary then
    return binary_section(path, old, new, status, metadata)
  end

  local old_lines = split_lines(old)
  local new_lines = split_lines(new)
  local raw_hunks = differ.hunks(old, new)

  -- Ghosting deletions needs something real for them to hang off, and a file with no
  -- new side has nothing: a result view of a wholly-deleted file is EMPTY. Every line
  -- would become virtual text -- unyankable, unsearchable, impossible to put a cursor
  -- on -- when those lines are the only content the section has to show.
  --
  -- So the rule is: the result view applies when there is a result. When there is not,
  -- deletions stay real rows and the section renders the way it always did. That also
  -- keeps `D`-status files navigable, which is the case a user is most likely to want
  -- to read closely rather than skim.
  local ghost_dels = #new_lines > 0

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
    local pending_del -- deletions waiting for a row to hang off

    -- Deletions are NOT rows. They ride on the entry that follows them, as `ghosts`,
    -- and get drawn as virtual lines above it.
    --
    -- The hard constraint this respects: `entries` must stay 1:1 with rendered rows,
    -- because canvas.locate turns a buffer-row offset straight into an entry index --
    -- and viewport anchors, the statuscolumn and hunk motions all read entries by that
    -- index. A "del entry that doesn't render" would desynchronise every one of them.
    -- Virtual lines cost zero buffer rows (verified: buffer line count, header rows,
    -- line("w0"), winrestview and ]f are all unaffected by them), so this is the one
    -- shape that keeps the arithmetic exactly as it was.
    --
    -- What it buys: every remaining row has a real new_lnum. The statuscolumn stops
    -- printing `·` for rows that do not exist in the file, and jump.enter's
    -- target_lnum -- which walks FORWARD off a del row to find a line it can use, so
    -- pressing Enter on a deletion silently lands you somewhere else -- always has the
    -- row you actually pointed at.
    local function push(kind, content, old_lnum, new_lnum)
      if kind == "del" and ghost_dels then
        pending_del = pending_del or {}
        pending_del[#pending_del + 1] = { content = content, old_lnum = old_lnum }
        return
      end
      local e = {
        kind = kind, content = content, new_lnum = new_lnum, old_lnum = old_lnum, hunk_idx = gi,
      }
      if pending_del then
        e.ghosts = pending_del
        pending_del = nil
      end
      hunk_entries[#hunk_entries + 1] = e
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

    local hdr = {
      kind = "hunk_hdr", content = hunk_header(a, b, c, d),
      new_lnum = nil, old_lnum = nil, hunk_idx = gi,
    }
    entries[#entries + 1] = hdr
    for _, e in ipairs(hunk_entries) do
      entries[#entries + 1] = e
    end

    -- Deletions with nothing after them in this group -- a hunk that only removes
    -- lines, or one at end-of-file. They hang BELOW the last row instead, and when the
    -- group is nothing but deletions (reachable with context = 0) the hunk header is
    -- the only row there is to hang them on. Measured on this repo's own changeset:
    -- 2 of 179 hunks delete without adding, so this is rare but not theoretical, and
    -- dropping the pending list on the floor would silently lose those lines.
    if pending_del then
      local anchor = hunk_entries[#hunk_entries] or hdr
      anchor.ghosts_after = pending_del
      pending_del = nil
    end
  end

  return with_metadata({
    adds = adds, dels = dels, nhunks = #groups,
    entries = entries,
  }, path, old, new, status, metadata)
end

--- Identity of a section's CONTENT, for "has this changed since I last looked at
--- it" comparisons (fold.stale). Cheap to store per path and stable across
--- rebuilds of the same content.
---
--- Deliberately over new_text alone, not old_text too: toggling the diff base
--- (worktree vs HEAD / vs index) rewrites every section's old_text without anyone
--- having edited anything, and marking the whole changeset as changed for that
--- would be noise. The question is "did the file change", not "did the comparison
--- change".
function M.fingerprint(section)
  return vim.fn.sha256(section and section.new_text or "")
end

--- True when `sec` was staged and then modified again -- git's own durable version of
--- "you said you were done with this, then changed it". Independent of the lens, and
--- of our session file's fingerprints, because git tracks it whether or not this
--- plugin was ever open.
function M.staged_then_changed(sec)
  return sec ~= nil and sec.staged ~= nil and sec.unstaged ~= nil
end

function M.build(files, context)
  local sections = {}
  for _, f in ipairs(files) do
    local s = M.build_section(
      f.path, f.old_text, f.new_text, f.status, context, f)
    if s then
      sections[#sections + 1] = s
    end
  end
  table.sort(sections, function(a, b) return a.path < b.path end)
  return sections
end

return M
