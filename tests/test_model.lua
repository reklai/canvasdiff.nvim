local H = require("helpers")
local model = require("finding_myself.model")
local render = require("finding_myself.render")

return {
  ["model: modified file entries"] = function()
    local s = model.build_section("f.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n",
                                            "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\n", "M")
    H.eq(s.adds, 1); H.eq(s.dels, 1); H.eq(s.nhunks, 1)
    H.eq(s.entries[1].kind, "file_hdr")
    H.eq(s.entries[2].kind, "hunk_hdr")
    -- 3 ctx above, del e, add E, 3 ctx below
    H.eq(s.entries[3], { kind = "ctx", content = "b", new_lnum = 2, old_lnum = 2, hunk_idx = 1 })
    H.eq(s.entries[6], { kind = "del", content = "e", new_lnum = nil, old_lnum = 5, hunk_idx = 1 })
    H.eq(s.entries[7], { kind = "add", content = "E", new_lnum = 5, old_lnum = nil, hunk_idx = 1 })
    H.eq(s.entries[10].content, "h")
  end,
  ["model: new file all adds"] = function()
    local s = model.build_section("n.txt", nil, "x\ny\n", "?")
    H.eq(s.adds, 2); H.eq(s.dels, 0)
    H.eq(s.entries[3].kind, "add")
    H.eq(s.entries[3].old_lnum, nil)
  end,
  ["model: deleted file all dels"] = function()
    local s = model.build_section("d.txt", "x\ny\n", "", "D")
    H.eq(s.dels, 2); H.eq(s.adds, 0)
    H.eq(s.entries[3].kind, "del")
  end,
  ["model: unchanged is nil"] = function()
    H.eq(model.build_section("s.txt", "x\n", "x\n", "M"), nil)
  end,
  ["model: context param overrides default 3"] = function()
    local s = model.build_section("f.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n",
                                            "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\n", "M", 1)
    H.eq(s.adds, 1); H.eq(s.dels, 1); H.eq(s.nhunks, 1)
    H.eq(s.entries[1].kind, "file_hdr")
    H.eq(s.entries[2], { kind = "hunk_hdr", content = "@@ -4,3 +4,3 @@", new_lnum = nil, old_lnum = nil, hunk_idx = 1 })
    -- 1 ctx line each side instead of 3
    H.eq(s.entries[3], { kind = "ctx", content = "d", new_lnum = 4, old_lnum = 4, hunk_idx = 1 })
    H.eq(s.entries[4], { kind = "del", content = "e", new_lnum = nil, old_lnum = 5, hunk_idx = 1 })
    H.eq(s.entries[5], { kind = "add", content = "E", new_lnum = 5, old_lnum = nil, hunk_idx = 1 })
    H.eq(s.entries[6], { kind = "ctx", content = "f", new_lnum = 6, old_lnum = 6, hunk_idx = 1 })
    H.eq(#s.entries, 6)
  end,
  ["model: build threads context to build_section"] = function()
    local ss = model.build({
      { path = "f.txt", old_text = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n",
        new_text = "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\n", status = "M" },
    }, 1)
    H.eq(#ss[1].entries, 6)
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
      "ctx", "ctx", "ctx", "del", "add",
      "ctx", "ctx", "ctx", "ctx", "ctx", "ctx", "del", "add",
      "ctx", "ctx", "ctx",
    })

    local hunk_hdrs = {}
    for _, e in ipairs(s.entries) do
      if e.kind == "hunk_hdr" then hunk_hdrs[#hunk_hdrs + 1] = e end
    end
    H.eq(#hunk_hdrs, 1)
    H.eq(hunk_hdrs[1].content, "@@ -2,14 +2,14 @@")

    H.eq(s.entries[6], { kind = "del", content = "e", new_lnum = nil, old_lnum = 5, hunk_idx = 1 })
    H.eq(s.entries[7], { kind = "add", content = "E", new_lnum = 5, old_lnum = nil, hunk_idx = 1 })
    H.eq(s.entries[14], { kind = "del", content = "l", new_lnum = nil, old_lnum = 12, hunk_idx = 1 })
    H.eq(s.entries[15], { kind = "add", content = "L", new_lnum = 12, old_lnum = nil, hunk_idx = 1 })
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
      "hunk_hdr", "ctx", "ctx", "ctx", "del", "add", "ctx", "ctx", "ctx",
      "hunk_hdr", "ctx", "ctx", "ctx", "del", "add", "ctx", "ctx", "ctx",
    })

    local hunk_hdrs = {}
    for _, e in ipairs(s.entries) do
      if e.kind == "hunk_hdr" then hunk_hdrs[#hunk_hdrs + 1] = e end
    end
    H.eq(#hunk_hdrs, 2)
    H.eq(hunk_hdrs[1].content, "@@ -2,7 +2,7 @@")
    H.eq(hunk_hdrs[2].content, "@@ -10,7 +10,7 @@")

    H.eq(s.entries[6], { kind = "del", content = "e", new_lnum = nil, old_lnum = 5, hunk_idx = 1 })
    H.eq(s.entries[7], { kind = "add", content = "E", new_lnum = 5, old_lnum = nil, hunk_idx = 1 })
    H.eq(s.entries[15], { kind = "del", content = "m", new_lnum = nil, old_lnum = 13, hunk_idx = 2 })
    H.eq(s.entries[16], { kind = "add", content = "M", new_lnum = 13, old_lnum = nil, hunk_idx = 2 })
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
    H.eq(lines[4], "-b")
    H.eq(lines[5], "+B")
    local hl = render.section_hl(s)
    H.eq(hl[1], { row = 0, group = "FmFileHeader" })
    H.eq(hl[2], { row = 1, group = "FmHunkHeader" })
    H.eq(hl[3], { row = 3, group = "DiffDelete" })
    H.eq(hl[4], { row = 4, group = "DiffAdd" })
  end,
}
