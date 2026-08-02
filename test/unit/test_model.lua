local H = require("helpers")
local model = require("canvasdiff.diff")
local render = require("canvasdiff.canvas").format
local lens = model.lens

return {
  ["lens: range construction validates identity and preserves operator"] = function()
    H.eq(lens.range("main", "topic", ".."), {
      id = "range:main..topic",
      old = "main",
      new = "topic",
      operator = "..",
      label = "READ-ONLY  main → topic",
    })
    H.eq(lens.range("main", "topic", "..."), {
      id = "range:main...topic",
      old = "main",
      new = "topic",
      operator = "...",
      label = "READ-ONLY  main → topic",
    })
    H.eq(lens.range("", "topic", ".."), nil, "an omitted endpoint is normalized by the parser")
    H.eq(lens.range("main", "", ".."), nil)
    H.eq(lens.range("main", "topic", "--"), nil, "only Git range operators are accepted")
  end,
  ["lens: range validity classification and equality include the operator"] = function()
    local two = assert(lens.range("main", "topic", ".."))
    local three = assert(lens.range("main", "topic", "..."))
    H.eq(lens.valid(two), true)
    H.eq(lens.is_range(two), true)
    H.eq(lens.is_range(lens.branch("main")), false)
    H.eq(lens.valid({
      id = "range:other..topic",
      old = "main",
      new = "topic",
      operator = "..",
    }), false, "a restored range's stable identity must agree with its sides")
    H.eq(lens.valid({
      id = "range:main--topic",
      old = "main",
      new = "topic",
      operator = "--",
    }), false)
    H.eq(lens.same(two, lens.range("main", "topic", "..")), true)
    H.eq(lens.same(two, three), false,
      "two-dot and three-dot have different old sides after resolution")
  end,
  ["lens: malformed kind tags cannot fall through to sentinel validation"] = function()
    local staged_with_operator = {
      id = "staged",
      old = "HEAD",
      new = ":0",
      operator = "..",
      label = "index vs HEAD (staged)",
    }
    H.eq(lens.valid(staged_with_operator), false,
      "an operator-bearing named record is not a fixed lens")
    H.eq(lens.same(staged_with_operator, lens.get("staged")), true,
      "operator sensitivity belongs only to two canonical ranges")
    H.eq(lens.valid({
      id = "branch:main",
      old = "main",
      new = "worktree",
      operator = "..",
      label = "worktree vs main",
    }), false, "an operator-bearing branch record is not a branch lens")
    H.eq(lens.valid({
      id = "range:main..worktree",
      old = "main",
      new = "worktree",
      operator = "--",
      label = "x",
    }), false, "a malformed range cannot fall through via the worktree sentinel")
    H.eq(lens.valid({
      id = "range:main..:0",
      old = "main",
      new = ":0",
      operator = "--",
      label = "x",
    }), false, "a malformed range cannot fall through via the index sentinel")
  end,
  ["model: modified file entries"] = function()
    local s = model.build_section("f.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n",
                                            "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\n", "M")
    H.eq(s.adds, 1); H.eq(s.dels, 1); H.eq(s.nhunks, 1)
    H.eq(s.entries[1].kind, "file_hdr")
    H.eq(s.entries[2].kind, "hunk_hdr")
    -- 3 ctx above, then the add -- the deleted line is NOT a row any more, it rides
    -- on the add as a ghost and is drawn as a virtual line above it. `entries` has to
    -- stay 1:1 with rendered rows: canvas.locate turns a row offset straight into an
    -- entry index, and the viewport anchors, statuscolumn and hunk motions all read
    -- entries by it.
    H.eq(s.entries[3], { kind = "ctx", content = "b", new_lnum = 2, old_lnum = 2, hunk_idx = 1 })
    H.eq(s.entries[6], { kind = "add", content = "E", new_lnum = 5, old_lnum = nil, hunk_idx = 1,
      ghosts = { { content = "e", old_lnum = 5 } } })
    H.eq(s.entries[9].content, "h")
    -- Still counted: dels is 1 even though no row is a deletion.
    H.eq(s.dels, 1)
    -- And every remaining row carries a real file line number, which is the point.
    for i = 3, #s.entries do
      assert(s.entries[i].new_lnum, "row " .. i .. " must map to a real file line")
    end
  end,
  ["model: new file all adds"] = function()
    local s = model.build_section("n.txt", nil, "x\ny\n", "?")
    H.eq(s.adds, 2); H.eq(s.dels, 0)
    H.eq(s.entries[3].kind, "add")
    H.eq(s.entries[3].old_lnum, nil)
  end,
  -- A file with no new side is the one case that keeps deletions as REAL rows: a
  -- result view of a wholly-deleted file is empty, so ghosting would turn its entire
  -- content into virtual text you cannot yank, search or put a cursor on -- when those
  -- lines are all the section has to show.
  ["model: deleted file all dels"] = function()
    local s = model.build_section("d.txt", "x\ny\n", "", "D")
    H.eq(s.dels, 2); H.eq(s.adds, 0)
    H.eq(s.entries[3].kind, "del", "no result to view, so deletions stay rows")
    H.eq(s.entries[3].ghosts, nil, "and carry no ghosts")
  end,
  ["model: unchanged is nil"] = function()
    H.eq(model.build_section("s.txt", "x\n", "x\n", "M"), nil)
  end,
  ["model: pure rename is one metadata-rich escaped header row"] = function()
    local old_path = "old\tline\nslash\\name.txt"
    local new_path = "new\tline\nslash\\name.txt"
    local sections = model.build({
      {
        path = new_path,
        old_path = old_path,
        old_rev = "abc123",
        new_rev = "def456",
        status = "R",
        staged = "R",
        unstaged = "M",
        old_text = "same body\n",
        new_text = "same body\n",
      },
    }, 3)
    H.eq(#sections, 1, "identity alone is a reviewable change")
    local s = sections[1]
    H.eq({
      s.path, s.old_path, s.old_rev, s.new_rev, s.status, s.staged, s.unstaged,
      s.renamed, s.rename_only, s.adds, s.dels, s.nhunks,
    }, {
      new_path, old_path, "abc123", "def456", "R", "R", "M",
      true, true, 0, 0, 0,
    })
    H.eq(#s.entries, 1, "a pure rename has only its file header")
    H.eq(s.entries[1].content, new_path, "the model retains the raw destination path")
    H.eq(render.section_lines(s), {
      "▎ old\\tline\\nslash\\\\name.txt → new\\tline\\nslash\\\\name.txt  (renamed) ●○",
    }, "controls are escaped at the display boundary without changing identity")
    H.eq(render.placeholder(s),
      "▸ old\\tline\\nslash\\\\name.txt → new\\tline\\nslash\\\\name.txt  (renamed) ●○")
  end,
  ["model: a content-changing rename names both paths and keeps counts"] = function()
    local s = model.build_section(
      "after.txt", "before\n", "after\n", "R", 3,
      { old_path = "before.txt", old_rev = "HEAD" })
    H.eq(s.renamed, true)
    H.eq(s.rename_only, nil)
    H.eq(s.old_rev, "HEAD")
    H.eq(render.section_lines(s)[1], "▎ before.txt → after.txt  (+1 −1)")
    H.eq(render.placeholder(s), "▸ before.txt → after.txt  (1 hunks, +1 −1)")
  end,
  ["model: context param overrides default 3"] = function()
    local s = model.build_section("f.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n",
                                            "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\n", "M", 1)
    H.eq(s.adds, 1); H.eq(s.dels, 1); H.eq(s.nhunks, 1)
    H.eq(s.entries[1].kind, "file_hdr")
    H.eq(s.entries[2], { kind = "hunk_hdr", content = "@@ -4,3 +4,3 @@", new_lnum = nil, old_lnum = nil, hunk_idx = 1 })
    -- 1 ctx line each side instead of 3
    H.eq(s.entries[3], { kind = "ctx", content = "d", new_lnum = 4, old_lnum = 4, hunk_idx = 1 })
    H.eq(s.entries[4], { kind = "add", content = "E", new_lnum = 5, old_lnum = nil, hunk_idx = 1,
      ghosts = { { content = "e", old_lnum = 5 } } })
    H.eq(s.entries[5], { kind = "ctx", content = "f", new_lnum = 6, old_lnum = 6, hunk_idx = 1 })
    H.eq(#s.entries, 5, "one fewer row than before: the deletion is virtual")
  end,
  ["model: build threads context to build_section"] = function()
    local ss = model.build({
      { path = "f.txt", old_text = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n",
        new_text = "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\n", status = "M" },
    }, 1)
    H.eq(#ss[1].entries, 5)
    H.eq(ss[1].entries[3].content, "d")
  end,
  ["model: hunk merge -- context windows touch => one merged hunk"] = function()
    -- 20-line file; changes at old lines 5 and 12 (gap of 6 unchanged lines
    -- between them). With default context=3, ctx windows are [2,8] and
    -- [9,15]: they touch (9 <= 8+1), so they merge into ONE displayed hunk.
    local letters = {}
    for i = 1, 20 do letters[i] = string.char(96 + i) end -- a..t
    local old_lines, new_lines = {}, {}
    for i = 1, 20 do old_lines[i] = letters[i]; new_lines[i] = letters[i] end
    new_lines[5] = "E"
    new_lines[12] = "L"
    local old_text = table.concat(old_lines, "\n") .. "\n"
    local new_text = table.concat(new_lines, "\n") .. "\n"

    local s = model.build_section("f.txt", old_text, new_text, "M")
    H.eq(s.nhunks, 1)
    H.eq(s.adds, 2); H.eq(s.dels, 2)

    local kinds = {}
    for _, e in ipairs(s.entries) do kinds[#kinds + 1] = e.kind end
    H.eq(kinds, {
      "file_hdr", "hunk_hdr",
      "ctx", "ctx", "ctx", "add",
      "ctx", "ctx", "ctx", "ctx", "ctx", "ctx", "add",
      "ctx", "ctx", "ctx",
    })

    local hunk_hdrs = {}
    for _, e in ipairs(s.entries) do
      if e.kind == "hunk_hdr" then hunk_hdrs[#hunk_hdrs + 1] = e end
    end
    H.eq(#hunk_hdrs, 1)
    H.eq(hunk_hdrs[1].content, "@@ -2,14 +2,14 @@")

    H.eq(s.entries[6], { kind = "add", content = "E", new_lnum = 5, old_lnum = nil, hunk_idx = 1,
      ghosts = { { content = "e", old_lnum = 5 } } })
    H.eq(s.entries[13], { kind = "add", content = "L", new_lnum = 12, old_lnum = nil, hunk_idx = 1,
      ghosts = { { content = "l", old_lnum = 12 } } })
  end,
  ["model: hunk merge -- context windows apart => two separate hunks"] = function()
    -- Same shape but changes at old lines 5 and 13 (gap of 7 unchanged
    -- lines). ctx windows are [2,8] and [10,16]: 10 > 8+1, so they do NOT
    -- merge -- two displayed hunks.
    local letters = {}
    for i = 1, 20 do letters[i] = string.char(96 + i) end -- a..t
    local old_lines, new_lines = {}, {}
    for i = 1, 20 do old_lines[i] = letters[i]; new_lines[i] = letters[i] end
    new_lines[5] = "E"
    new_lines[13] = "M"
    local old_text = table.concat(old_lines, "\n") .. "\n"
    local new_text = table.concat(new_lines, "\n") .. "\n"

    local s = model.build_section("f.txt", old_text, new_text, "M")
    H.eq(s.nhunks, 2)
    H.eq(s.adds, 2); H.eq(s.dels, 2)

    local kinds = {}
    for _, e in ipairs(s.entries) do kinds[#kinds + 1] = e.kind end
    H.eq(kinds, {
      "file_hdr",
      "hunk_hdr", "ctx", "ctx", "ctx", "add", "ctx", "ctx", "ctx",
      "hunk_hdr", "ctx", "ctx", "ctx", "add", "ctx", "ctx", "ctx",
    })

    local hunk_hdrs = {}
    for _, e in ipairs(s.entries) do
      if e.kind == "hunk_hdr" then hunk_hdrs[#hunk_hdrs + 1] = e end
    end
    H.eq(#hunk_hdrs, 2)
    H.eq(hunk_hdrs[1].content, "@@ -2,7 +2,7 @@")
    H.eq(hunk_hdrs[2].content, "@@ -10,7 +10,7 @@")

    H.eq(s.entries[6], { kind = "add", content = "E", new_lnum = 5, old_lnum = nil, hunk_idx = 1,
      ghosts = { { content = "e", old_lnum = 5 } } })
    H.eq(s.entries[14], { kind = "add", content = "M", new_lnum = 13, old_lnum = nil, hunk_idx = 2,
      ghosts = { { content = "m", old_lnum = 13 } } })
  end,
  ["model: build sorts alphabetically"] = function()
    local ss = model.build({
      { path = "z.txt", old_text = "a\n", new_text = "b\n", status = "M" },
      { path = "a.txt", old_text = "a\n", new_text = "b\n", status = "M" },
    })
    H.eq({ ss[1].path, ss[2].path }, { "a.txt", "z.txt" })
  end,
  ["model: sections publish per-hunk metadata"] = function()
    local old = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n"
    local new = "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\neight\nnine\nten\nELEVEN\n"
    local s = model.build_section("a.lua", old, new, "M", 3)
    H.eq(#s.hunks, s.nhunks, "one metadata row per hunk")
    H.eq(s.hunks[1], {
      header = "@@ -1,6 +1,6 @@",
      new_lo = 3, new_hi = 3,
      adds = 1, dels = 1,
      label = "THREE",
      pure_del = false,
    })
    -- Counts belong to ONE hunk each: bookkeeping shared across groups would
    -- report adds = 2 and dels = 1 for this trailing append.
    H.eq(s.hunks[2], {
      header = "@@ -8,3 +8,4 @@",
      new_lo = 11, new_hi = 11,
      adds = 1, dels = 0,
      label = "ELEVEN",
      pure_del = false,
    })
    local headers, rows = {}, {}
    for _, h in ipairs(s.hunks) do headers[#headers + 1] = h.header end
    for _, e in ipairs(s.entries) do
      if e.kind == "hunk_hdr" then rows[#rows + 1] = e.content end
    end
    H.eq(headers, rows, "hunk `gi` metadata and the `gi`th header row agree, in order")
  end,
  ["model: a pure-deletion hunk labels its removed line"] = function()
    local old = "one\ntwo\nGONE\nthree\nfour\nfive\nsix\nseven\n"
    local new = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n"
    local s = model.build_section("a.lua", old, new, "M", 1)
    H.eq(#s.hunks, s.nhunks)
    -- The removed line is a ghost, not a row, so the label has to be captured
    -- before the deletion leaves the entry stream. `seam` is the new-side line
    -- the cut sits after, and it is here rather than on new_lo/new_hi because
    -- this hunk writes no new-side line to range over.
    H.eq(s.hunks[1], {
      header = "@@ -2,3 +2,2 @@",
      new_lo = nil, new_hi = nil,
      seam = 2,
      adds = 0, dels = 1,
      label = "GONE",
      pure_del = true,
    })
  end,
  ["model: a pure-deletion hunk seams even with no context row to carry it"] = function()
    -- context = 0 leaves this hunk NO row but its header, whose new_lnum is
    -- nil, so the seam is the only record of where the cut is. It names the
    -- same two lines the ghost carrier would have named at any wider context.
    local old = "one\ntwo\nGONE\nthree\nfour\n"
    local new = "one\ntwo\nthree\nfour\n"
    local zero = model.build_section("a.lua", old, new, "M", 0)
    H.eq(zero.hunks[1].seam, 2)
    H.eq(zero.hunks[1].header, "@@ -3,1 +2,0 @@")
    local rows = {}
    for _, e in ipairs(zero.entries) do rows[#rows + 1] = e.kind end
    H.eq(rows, { "file_hdr", "hunk_hdr" },
      "sanity: not one row of this hunk's own survives at context 0")
    H.eq(model.build_section("a.lua", old, new, "M", 3).hunks[1].seam, 2,
      "and a wider context does not move it")

    -- A wholly deleted file has no new side to seam INTO: its deletions are
    -- real rows, and its hunk is not distinguishable from the file.
    H.eq(model.build_section("a.lua", old, "", "D").hunks[1].seam, nil)
  end,
  ["model: a file's counts are exactly the sum of its hunks'"] = function()
    -- A file row shows `+2 −2` and its hunk rows show the parts, so the two
    -- have to agree wherever both are on screen. They are separate counters
    -- incremented on adjacent lines, which is precisely why nothing else
    -- would notice one of them being moved.
    local old_lines = {}
    for i = 1, 20 do old_lines[i] = "line " .. i end
    local new_lines = vim.deepcopy(old_lines)
    new_lines[2] = "line 2 CHANGED"
    table.remove(new_lines, 10)          -- a hunk that only deletes
    table.insert(new_lines, 17, "EXTRA") -- and one that only adds
    local s = model.build_section("a.lua",
      table.concat(old_lines, "\n") .. "\n",
      table.concat(new_lines, "\n") .. "\n", "M", 1)

    H.eq(#s.hunks, 3, "sanity: three separated hunks, one of each shape")
    local adds, dels = 0, 0
    for _, h in ipairs(s.hunks) do
      adds, dels = adds + h.adds, dels + h.dels
    end
    H.eq({ adds, dels }, { s.adds, s.dels },
      "the file's counts are the sum of its hunks'")
    H.eq({ s.adds, s.dels }, { 2, 2 }, "and both are actually counting")
  end,
  ["model: a merged hunk spans every line it writes"] = function()
    local letters = {}
    for i = 1, 20 do letters[i] = string.char(96 + i) end
    local old_lines, new_lines = {}, {}
    for i = 1, 20 do old_lines[i] = letters[i]; new_lines[i] = letters[i] end
    new_lines[5] = "E"
    new_lines[12] = "L"
    local s = model.build_section("f.txt",
      table.concat(old_lines, "\n") .. "\n", table.concat(new_lines, "\n") .. "\n", "M")
    H.eq(s.nhunks, 1)
    H.eq(#s.hunks, 1)
    H.eq({ s.hunks[1].new_lo, s.hunks[1].new_hi }, { 5, 12 },
      "two changes merged into one hunk span from the first written line to the last")
    H.eq({ s.hunks[1].adds, s.hunks[1].dels }, { 2, 2 })
    H.eq(s.hunks[1].label, "E", "the label is the FIRST changed line, not the last")
  end,
  ["model: sections without a diff still publish a hunk list"] = function()
    local bin = model.build_section("a.zip", "a\0b\n", "c\0d\n", "M")
    H.eq(bin.binary, true)
    H.eq(bin.hunks, {}, "consumers iterate section.hunks without a nil check")
    local ren = model.build_section("after.txt", "same\n", "same\n", "R", 3,
      { old_path = "before.txt" })
    H.eq(ren.rename_only, true)
    H.eq(ren.hunks, {})
  end,
  ["render: line text and highlights"] = function()
    local s = model.build_section("f.txt", "a\nb\n", "a\nB\n", "M")
    local lines = render.section_lines(s)
    H.eq(lines[1], "▎ f.txt  (+1 −1)")
    assert(lines[2]:match("^@@"))
    H.eq(lines[3], " a")
    -- No "-b" row: it renders as a virtual line above "+B" instead.
    H.eq(lines[4], "+B")
    H.eq(lines[5], nil, "the deletion consumed no buffer row")
    -- ghost_lines: prefix and content are separate chunks so the margin hue
    -- reaches ghosts too.
    H.eq(render.ghost_lines(s.entries[4]),
      { { { "-", "CanvasDiffPrefixDel" }, { "b", "CanvasDiffGhost" } } },
      "and comes back as a two-chunk virt_lines spec")
    -- section_hl: each add/del row yields its field mark AND a prefix span
    -- (an `end_col` mark covering only the prefix glyph's bytes).
    local hl = render.section_hl(s)
    local row_marks, prefix_marks = {}, {}
    for _, m in ipairs(hl) do
      if m.end_col then prefix_marks[#prefix_marks + 1] = m
      else row_marks[#row_marks + 1] = m end
    end
    H.eq(row_marks[1], { row = 0, group = "CanvasDiffFileHeader" })
    H.eq(row_marks[2], { row = 1, group = "CanvasDiffHunkHeader" })
    -- CanvasDiff* aliases, not DiffDelete/DiffAdd directly. Every other visual element
    -- already went through an overridable group; these were the last two that did not,
    -- so tuning the diff rows meant redefining the groups your ordinary vimdiff uses.
    H.eq(row_marks[3], { row = 3, group = "CanvasDiffAdd" })
    H.eq(row_marks[4], nil, "only one content row is highlighted now")
    H.eq(#prefix_marks, 1, "one prefix span, for the one add row")
    H.eq(prefix_marks[1].group, "CanvasDiffPrefixAdd")
    H.eq(prefix_marks[1].end_col, #"+")
    H.eq(prefix_marks[1].row, row_marks[3].row,
      "the prefix span sits on its own row's field mark")
  end,
  -- Real `-` rows exist only for a wholly-deleted file; their prefix carries
  -- the red margin hue the same way ghosts do.
  ["render: del rows carry a red prefix span"] = function()
    local s = model.build_section("gone.txt", "bye1\nbye2\n", "", "D")
    local prefix_marks = {}
    for _, m in ipairs(render.section_hl(s)) do
      if m.end_col then prefix_marks[#prefix_marks + 1] = m end
    end
    H.eq(#prefix_marks, 2, "one span per real del row")
    for _, m in ipairs(prefix_marks) do
      H.eq(m.group, "CanvasDiffPrefixDel")
      H.eq(m.end_col, #"-")
    end
  end,
  -- Glyphs are user-overridable and may be multi-byte; the spans must be the
  -- glyph's byte length at call time, never a hardcoded 1.
  ["render: prefix spans and ghost chunks track the live glyphs"] = function()
    local glyphs = render.glyphs
    local saved = { add = glyphs.add, del = glyphs.del }
    glyphs.add, glyphs.del = "✚", "✖"
    local ok, err = pcall(function()
      local s = model.build_section("f.txt", "a\nb\n", "a\nB\n", "M")
      H.eq(render.section_lines(s)[4], "✚B")
      local prefix
      for _, m in ipairs(render.section_hl(s)) do
        if m.end_col then prefix = m end
      end
      H.eq(prefix.group, "CanvasDiffPrefixAdd")
      H.eq(prefix.end_col, #"✚")
      H.eq(render.ghost_lines(s.entries[4]),
        { { { "✖", "CanvasDiffPrefixDel" }, { "b", "CanvasDiffGhost" } } })
    end)
    glyphs.add, glyphs.del = saved.add, saved.del
    assert(ok, err)
  end,
  -- The canvas headers carry the SAME stage marks as the sidebar rows -- same
  -- stage_mark truth, same glyphs, same order -- so closing the sidebar loses no
  -- information. A section with no status facts renders nothing, never "clean".
  ["render: file headers carry the sidebar's stage markers"] = function()
    local function built(staged, unstaged)
      return model.build_section("f.txt", "a\n", "b\n", "M", 3,
        { staged = staged, unstaged = unstaged })
    end
    H.eq(render.section_lines(built("M", nil))[1], "▎ f.txt  (+1 −1) ●")
    H.eq(render.section_lines(built(nil, "M"))[1], "▎ f.txt  (+1 −1) ○")
    H.eq(render.section_lines(built("M", "M"))[1], "▎ f.txt  (+1 −1) ●○",
      "staged-then-changed keeps both facts, exactly like the sidebar row")
    H.eq(render.section_lines(built(nil, nil))[1], "▎ f.txt  (+1 −1)",
      "no status information renders nothing, never 'clean'")
  end,
  ["render: the placeholder keeps stage marks before the stale mark"] = function()
    local function built(staged, unstaged)
      return model.build_section("f.txt", "a\n", "b\n", "M", 3,
        { staged = staged, unstaged = unstaged })
    end
    H.eq(render.placeholder(built("M", "M")), "▸ f.txt  (1 hunks, +1 −1) ●○")
    H.eq(render.placeholder(built("M", "M"), true), "▸ f.txt  (1 hunks, +1 −1) ●○ ●",
      "stale stays LAST, so the trailing ● keeps meaning exactly one thing")
    H.eq(render.placeholder(built("M", nil)), "▸ f.txt  (1 hunks, +1 −1) ●")
    H.eq(render.placeholder(built(nil, nil), true), "▸ f.txt  (1 hunks, +1 −1) ●",
      "stale alone stays glued to the counts, as before")
    H.eq(render.placeholder({ path = "a.zip", binary = true, staged = "M" }),
      "▸ a.zip  (binary) ●", "the binary placeholder carries the marks too")
  end,
  -- Byte spans, because STALE and STAGED are the same `●` and only the highlight
  -- separates them -- the same load-bearing arithmetic test_sidebar pins for rows.
  ["render: header marker spans land on the right glyphs"] = function()
    local s = model.build_section("f.txt", "a\n", "b\n", "M", 3,
      { staged = "M", unstaged = "M" })
    local line = render.section_lines(s)[1]
    local spans = render.marker_spans(line, s.staged, s.unstaged, nil)
    H.eq(#spans, 2, "an expanded header never carries a stale span")
    local at = {}
    for _, sp in ipairs(spans) do
      at[sp[3]] = { col = sp[1], text = line:sub(sp[1] + 1, sp[2]) }
    end
    H.eq(at.CanvasDiffStaged.text, render.glyphs.staged)
    H.eq(at.CanvasDiffUnstaged.text, render.glyphs.unstaged)
    H.eq(spans[1][2], #line, "the marker block ends at end-of-line")

    local ph = render.placeholder(s, true)
    local pspans = render.marker_spans(ph, s.staged, s.unstaged, true)
    H.eq(#pspans, 4, "staged, unstaged, stale colour, stale emphasis")
    local pat = {}
    for _, sp in ipairs(pspans) do
      pat[sp[3]] = { col = sp[1], text = ph:sub(sp[1] + 1, sp[2]) }
    end
    H.eq(pat.CanvasDiffStale.text, render.glyphs.stale)
    H.eq(pat.CanvasDiffStaleEmphasis.col, pat.CanvasDiffStale.col)
    assert(pat.CanvasDiffStaged.col < pat.CanvasDiffStale.col,
      "stage marks are appended before stale, so their spans sit to the left")
    H.eq(pspans[1][2], #ph, "the stale span reaches end-of-line")
  end,
  ["render: headers read the live glyph table, so ASCII stays coherent"] = function()
    local glyphs = render.glyphs
    local saved = { staged = glyphs.staged, unstaged = glyphs.unstaged }
    glyphs.staged, glyphs.unstaged = "*", "o"
    local ok, err = pcall(function()
      local s = model.build_section("f.txt", "a\n", "b\n", "M", 3,
        { staged = "M", unstaged = "M" })
      H.eq(render.section_lines(s)[1], "▎ f.txt  (+1 −1) *o")
      H.eq(render.placeholder(s), "▸ f.txt  (1 hunks, +1 −1) *o")
    end)
    glyphs.staged, glyphs.unstaged = saved.staged, saved.unstaged
    assert(ok, err)
  end,
  ["model_section carries old_text and new_text"] = function()
    local s = model.build_section("t.lua", "a\n", "b\n", "M")
    H.eq(s.old_text, "a\n")
    H.eq(s.new_text, "b\n")
    local s2 = model.build_section("n.lua", nil, "b\n", "?")
    H.eq(s2.old_text, "")
  end,
}
