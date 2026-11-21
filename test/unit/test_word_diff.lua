local H = require("helpers")
local diff = require("canvasdiff.diff")
local ui = require("canvasdiff.ui")
local word = diff.word_diff

local T = {}

T["word_diff_ tokenize splits words, spaces, punctuation, and multibyte UTF-8 safely"] = function()
  local toks = word.tokenize("local foo_1 = 'café'")
  local texts = {}
  for i, t in ipairs(toks) do
    texts[i] = t.text
  end
  H.eq(texts, { "local", " ", "foo_1", " ", "=", " ", "'", "caf", "é", "'" })
  -- Exact byte round-trip.
  local rebuilt = ""
  for _, t in ipairs(toks) do
    rebuilt = rebuilt .. ("local foo_1 = 'café'"):sub(t.start_col + 1, t.end_col)
  end
  H.eq(rebuilt, "local foo_1 = 'café'")
end

T["word_diff_ diff_pair highlights symmetric changed tokens on both sides"] = function()
  local old = "local timeout = 3000"
  local new = "local timeout = 5000"
  local osp, nsp, sim = word.diff_pair(old, new)
  assert(osp and nsp, "similar lines pair")
  assert(sim > 0.7, "high similarity: " .. tostring(sim))
  H.eq(#osp, 1)
  H.eq(#nsp, 1)
  H.eq(old:sub(osp[1][1] + 1, osp[1][2]), "3000")
  H.eq(new:sub(nsp[1][1] + 1, nsp[1][2]), "5000")
end

T["word_diff_ diff_pair rejects unrelated lines to prevent reflow confetti"] = function()
  local osp, nsp, sim = word.diff_pair(
    "return compute_alpha(x, y)",
    "if not ready then error('boom') end"
  )
  H.eq(osp, nil)
  H.eq(nsp, nil)
  assert(sim < 0.35)
end

T["word_diff_ hunk_rows reconstructs real -/+ lines with word spans and hunk_peek builds marks"] = function()
  local sec = diff.build_section(
    "app.lua",
    "local a = 1\nlocal timeout = 3000\nreturn a\n",
    "local a = 1\nlocal timeout = 5000\nreturn a\n",
    "M", 3
  )
  local hr = word.hunk_rows(sec, 1)
  assert(hr, "hunk 1 reconstructed")
  local kinds = {}
  for i, r in ipairs(hr.rows) do kinds[i] = r.kind end
  H.eq(kinds, { "ctx", "del", "add", "ctx" })
  H.eq(hr.rows[2].content, "local timeout = 3000")
  H.eq(hr.rows[3].content, "local timeout = 5000")
  H.eq(#hr.rows[2].word_spans, 1)
  H.eq(#hr.rows[3].word_spans, 1)

  local built = ui.hunk_peek.build(sec, 1)
  assert(built, "peek builds lines and word extmarks")
  H.eq(#built.word_hl, 2, "one word span on `-`, one on `+`")
  H.eq(built.word_hl[1].group, "CanvasDiffWordDel")
  H.eq(built.word_hl[2].group, "CanvasDiffWordAdd")
  -- Verify byte offsets account for the 1-byte `-`/`+` prefix.
  local del_line = built.lines[built.word_hl[1].row + 1]
  local add_line = built.lines[built.word_hl[2].row + 1]
  H.eq(del_line:sub(built.word_hl[1].col_start + 1, built.word_hl[1].col_end), "3000")
  H.eq(add_line:sub(built.word_hl[2].col_start + 1, built.word_hl[2].col_end), "5000")
end

T["word_diff_ deleted_lines_at extracts row ghosts, trailing ghosts, or hunk ghosts"] = function()
  local sec = diff.build_section(
    "x.lua",
    "keep1\nold_a\nold_b\nkeep2\nold_eof\n",
    "keep1\nnew_a\nkeep2\n",
    "M", 3
  )
  -- Find the `new_a` entry carrying `old_a`, `old_b` as ghosts above it.
  local off_new, off_keep2, off_hdr
  for idx, e in ipairs(sec.entries) do
    if e.kind == "hunk_hdr" then off_hdr = idx end
    if e.content == "new_a" then off_new = idx end
    if e.content == "keep2" then off_keep2 = idx end
  end
  assert(off_new and off_keep2 and off_hdr)
  H.eq(diff.deleted_lines_at(sec, off_new), { "old_a" })
  H.eq(diff.deleted_lines_at(sec, off_keep2), { "old_b", "old_eof" })
  H.eq(diff.deleted_lines_at(sec, off_hdr), { "old_a", "old_b", "old_eof" })
  H.eq(diff.deleted_lines_at(sec, 1), {}, "file header has no deleted lines")
end

return T
