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
      "▎ old\\tline\\nslash\\\\name.txt → new\\tline\\nslash\\\\name.txt  (renamed)",
    }, "controls are escaped at the display boundary without changing identity")
    H.eq(render.placeholder(s),
      "▸ old\\tline\\nslash\\\\name.txt → new\\tline\\nslash\\\\name.txt  (renamed)")
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
  ["render: line text and highlights"] = function()
    local s = model.build_section("f.txt", "a\nb\n", "a\nB\n", "M")
    local lines = render.section_lines(s)
    H.eq(lines[1], "▎ f.txt  (+1 −1)")
    assert(lines[2]:match("^@@"))
    H.eq(lines[3], " a")
    -- No "-b" row: it renders as a virtual line above "+B" instead.
    H.eq(lines[4], "+B")
    H.eq(lines[5], nil, "the deletion consumed no buffer row")
    H.eq(render.ghost_lines(s.entries[4]), { { { "-b", "CanvasDiffGhost" } } },
      "and comes back as a virt_lines chunk spec")
    local hl = render.section_hl(s)
    H.eq(hl[1], { row = 0, group = "CanvasDiffFileHeader" })
    H.eq(hl[2], { row = 1, group = "CanvasDiffHunkHeader" })
    -- CanvasDiff* aliases, not DiffDelete/DiffAdd directly. Every other visual element
    -- already went through an overridable group; these were the last two that did not,
    -- so tuning the diff rows meant redefining the groups your ordinary vimdiff uses.
    H.eq(hl[3], { row = 3, group = "CanvasDiffAdd" })
    H.eq(hl[4], nil, "only one content row is highlighted now")
  end,
  ["model_section carries old_text and new_text"] = function()
    local s = model.build_section("t.lua", "a\n", "b\n", "M")
    H.eq(s.old_text, "a\n")
    H.eq(s.new_text, "b\n")
    local s2 = model.build_section("n.lua", nil, "b\n", "?")
    H.eq(s2.old_text, "")
  end,
}
