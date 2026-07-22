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
