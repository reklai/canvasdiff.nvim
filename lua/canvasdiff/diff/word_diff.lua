--- Pure intra-line word diff and interleaved hunk builder for on-demand hunk
--- inspection (`ui/hunk_peek.lua`).
---
--- Similarity-gated token LCS: pairs deleted and added lines only when their
--- shared characters meet SIMILARITY_THRESHOLD, avoiding the word-diff
--- confetti that naive positional pairing produces on rewritten blocks.
local W = {}

local SIMILARITY_THRESHOLD = 0.35
local MAX_DP_CELLS = 40000

--- Split `line` into `{ text, start_col, end_col }` tokens (0-based byte
--- columns), keeping word runs, whitespace runs, and multi-byte UTF-8
--- codepoints intact.
function W.tokenize(line)
  local toks = {}
  local i, len = 1, #(line or "")
  while i <= len do
    local b = string.byte(line, i)
    local j = i
    if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 then
      -- ASCII identifier / number run
      while j <= len do
        local c = string.byte(line, j)
        if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 then
          j = j + 1
        else
          break
        end
      end
    elseif b == 32 or b == 9 then
      -- Whitespace run
      while j <= len do
        local c = string.byte(line, j)
        if c == 32 or c == 9 then
          j = j + 1
        else
          break
        end
      end
    elseif b >= 0x80 then
      -- Single multi-byte UTF-8 sequence
      j = i + 1
      while j <= len do
        local c = string.byte(line, j)
        if c >= 0x80 and c < 0xC0 then
          j = j + 1
        else
          break
        end
      end
    else
      -- Single ASCII punctuation / control byte
      j = i + 1
    end
    toks[#toks + 1] = {
      text = line:sub(i, j - 1),
      start_col = i - 1,
      end_col = j - 1,
    }
    i = j
  end
  return toks
end

local function coalesce(toks, keep)
  local spans = {}
  local cur_lo, cur_hi
  for idx, tok in ipairs(toks) do
    if not keep[idx] then
      if cur_hi and cur_hi == tok.start_col then
        cur_hi = tok.end_col
      else
        if cur_lo then
          spans[#spans + 1] = { cur_lo, cur_hi }
        end
        cur_lo, cur_hi = tok.start_col, tok.end_col
      end
    end
  end
  if cur_lo then
    spans[#spans + 1] = { cur_lo, cur_hi }
  end
  return spans
end

--- Common-prefix / common-suffix fallback for ultra-long lines that exceed the
--- DP token budget (e.g. minified bundles).
local function prefix_suffix_diff(old_line, new_line)
  local lo, ln = #old_line, #new_line
  local min_len = math.min(lo, ln)
  local pre = 0
  while pre < min_len and old_line:byte(pre + 1) == new_line:byte(pre + 1) do
    pre = pre + 1
  end
  -- Back up to UTF-8 lead boundary if we stopped inside a continuation byte.
  while pre > 0 and old_line:byte(pre + 1) and old_line:byte(pre + 1) >= 0x80 and old_line:byte(pre + 1) < 0xC0 do
    pre = pre - 1
  end
  local suf = 0
  while suf < (min_len - pre)
      and old_line:byte(lo - suf) == new_line:byte(ln - suf) do
    suf = suf + 1
  end
  while suf > 0 and old_line:byte(lo - suf + 1) and old_line:byte(lo - suf + 1) >= 0x80 and old_line:byte(lo - suf + 1) < 0xC0 do
    suf = suf - 1
  end
  local max_len = math.max(lo, ln)
  local sim = max_len > 0 and ((pre + suf) / max_len) or 1
  if sim < SIMILARITY_THRESHOLD then
    return nil, nil, sim
  end
  local old_spans = (lo - suf > pre) and { { pre, lo - suf } } or {}
  local new_spans = (ln - suf > pre) and { { pre, ln - suf } } or {}
  return old_spans, new_spans, sim
end

--- Compute symmetric intra-line changed byte spans `{ { start_col, end_col }, ... }`
--- on BOTH `old_line` and `new_line`. Returns `nil, nil, similarity` when the
--- two lines are too dissimilar (`< SIMILARITY_THRESHOLD`) to pair cleanly.
function W.diff_pair(old_line, new_line)
  old_line = old_line or ""
  new_line = new_line or ""
  if old_line == new_line then
    return {}, {}, 1
  end
  if old_line == "" or new_line == "" then
    return nil, nil, 0
  end

  local ot = W.tokenize(old_line)
  local nt = W.tokenize(new_line)
  local m, n = #ot, #nt
  if m * n > MAX_DP_CELLS then
    return prefix_suffix_diff(old_line, new_line)
  end

  -- DP LCS over token text, weighted by token byte length so matching a real
  -- identifier beats matching single spaces or punctuation.
  local dp = {}
  for i = 1, m + 1 do
    local row = {}
    for j = 1, n + 1 do
      row[j] = 0
    end
    dp[i] = row
  end
  for i = m, 1, -1 do
    local otxt = ot[i].text
    local olen = #otxt
    local cur = dp[i]
    local nxt = dp[i + 1]
    for j = n, 1, -1 do
      if otxt == nt[j].text then
        cur[j] = nxt[j + 1] + olen
      else
        local down = nxt[j]
        local right = cur[j + 1]
        cur[j] = down >= right and down or right
      end
    end
  end

  local matched_bytes = dp[1][1]
  local max_bytes = math.max(#old_line, #new_line)
  local sim = max_bytes > 0 and (matched_bytes / max_bytes) or 1
  if sim < SIMILARITY_THRESHOLD then
    return nil, nil, sim
  end

  local keep_o, keep_n = {}, {}
  local i, j = 1, 1
  while i <= m and j <= n do
    if ot[i].text == nt[j].text then
      keep_o[i] = true
      keep_n[j] = true
      i, j = i + 1, j + 1
    elseif dp[i + 1][j] >= dp[i][j + 1] then
      i = i + 1
    else
      j = j + 1
    end
  end

  return coalesce(ot, keep_o), coalesce(nt, keep_n), sim
end

--- Pair contiguous deleted and added rows within one change block, attaching
--- symmetric `word_spans` whenever a pair passes the similarity gate.
local function annotate_block(rows, del_lo, del_hi, add_lo, add_hi)
  local nd = del_hi - del_lo + 1
  local na = add_hi - add_lo + 1
  if nd <= 0 or na <= 0 then
    return
  end
  -- Same-length runs pair positionally (gated by similarity); uneven runs pair
  -- greedily in order so a single inserted line doesn't shift every pair off.
  if nd == na then
    for k = 0, nd - 1 do
      local drow = rows[del_lo + k]
      local arow = rows[add_lo + k]
      local osp, nsp = W.diff_pair(drow.content, arow.content)
      if osp and nsp then
        drow.word_spans = osp
        arow.word_spans = nsp
      end
    end
    return
  end

  local next_add = add_lo
  for d = del_lo, del_hi do
    if next_add > add_hi then
      break
    end
    local best_a, best_sim, best_o, best_n
    local limit = math.min(add_hi, next_add + 4)
    for a = next_add, limit do
      local osp, nsp, sim = W.diff_pair(rows[d].content, rows[a].content)
      if osp and nsp and (not best_sim or sim > best_sim) then
        best_a, best_sim, best_o, best_n = a, sim, osp, nsp
      end
    end
    if best_a then
      rows[d].word_spans = best_o
      rows[best_a].word_spans = best_n
      next_add = best_a + 1
    end
  end
end

--- Reconstruct one hunk as classic interleaved real rows (`ctx`, `del`, `add`)
--- with symmetric intra-line `word_spans` attached to paired `-`/`+` rows.
--- Returns `{ path, header, rows }` or nil when the hunk does not exist.
function W.hunk_rows(section, hunk_idx)
  if type(section) ~= "table" or not section.hunks or not section.hunks[hunk_idx] then
    return nil
  end
  local hunk = section.hunks[hunk_idx]
  local rows = {}
  for _, entry in ipairs(section.entries or {}) do
    if entry.hunk_idx == hunk_idx then
      if entry.ghosts then
        for _, g in ipairs(entry.ghosts) do
          rows[#rows + 1] = {
            kind = "del",
            content = g.content or "",
            old_lnum = g.old_lnum,
          }
        end
      end
      if entry.kind == "ctx" or entry.kind == "add" or entry.kind == "del" then
        rows[#rows + 1] = {
          kind = entry.kind,
          content = entry.content or "",
          old_lnum = entry.old_lnum,
          new_lnum = entry.new_lnum,
        }
      end
      if entry.ghosts_after then
        for _, g in ipairs(entry.ghosts_after) do
          rows[#rows + 1] = {
            kind = "del",
            content = g.content or "",
            old_lnum = g.old_lnum,
          }
        end
      end
    end
  end

  -- Walk contiguous (del*, add*) blocks and attach intra-line word spans.
  local idx = 1
  while idx <= #rows do
    if rows[idx].kind == "del" then
      local del_lo = idx
      while idx <= #rows and rows[idx].kind == "del" do
        idx = idx + 1
      end
      local del_hi = idx - 1
      local add_lo = idx
      while idx <= #rows and rows[idx].kind == "add" do
        idx = idx + 1
      end
      local add_hi = idx - 1
      if add_hi >= add_lo then
        annotate_block(rows, del_lo, del_hi, add_lo, add_hi)
      end
    else
      idx = idx + 1
    end
  end

  return {
    path = section.path,
    header = hunk.header or "",
    rows = rows,
  }
end

return W
