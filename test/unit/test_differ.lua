local H = require("helpers")
local differ = require("canvasdiff.diff")
return {
  -- Bounded ingestion needs a section to be able to outlive the file it was
  -- built from. Everything except syntax highlighting already reads only the
  -- entries and the fingerprint; these pin that down.
  ["differ: release_text drops both sides and keeps the fingerprint"] = function()
    local old = "one\ntwo\nthree\n"
    local new = "one\nTWO\nthree\n"
    local section = differ.build_section("a.txt", old, new, "M")
    local before = differ.fingerprint(section)
    local old_before = section.old_fingerprint
    assert(type(old_before) == "string" and old_before ~= "",
      "the old-side identity is computed while text is resident")
    local entries = #section.entries
    assert(before ~= "" and entries > 0, "sanity: a real section")

    H.eq(differ.release_text(section), section, "release returns its section")
    H.eq(section.old_text, nil, "the old side is released")
    H.eq(section.new_text, nil, "and the new side with it")
    H.eq(#section.entries, entries, "the rendered entries are unaffected")
    H.eq(differ.fingerprint(section), before,
      "the fingerprint outlives the text it summarizes")
    H.eq(section.old_fingerprint, old_before,
      "the old-side identity also outlives the released text")
    H.eq(section.path, "a.txt")
    H.eq(section.old_path, "a.txt")
    H.eq(section.status, "M")
  end,
  -- A weak table cannot prove this: Lua never removes strings from one, since
  -- they have no explicit construction. Audit what the section still holds
  -- instead, and separately measure that releasing many of them frees the heap.
  ["differ: a released section retains no file-sized string"] = function()
    local line = ("y"):rep(120)
    local old = (line .. "\n"):rep(400)
    local new = (line .. "z\n"):rep(400)
    local section = differ.build_section("big.txt", old, new, "M")

    local retained = {}
    for key, value in pairs(section) do
      if type(value) == "string" and #value > 1024 then
        retained[#retained + 1] = key
      end
    end
    table.sort(retained)
    H.eq(retained, { "new_text", "old_text" },
      "sanity: a freshly built section holds exactly its two sides")

    differ.release_text(section)
    local after = {}
    for key, value in pairs(section) do
      if type(value) == "string" and #value > 1024 then
        after[#after + 1] = key
      end
    end
    H.eq(after, {}, "a released section holds no file-sized string at all")

    -- Its entries hold per-line content, which is the rendered model rather
    -- than a second copy of the file, and is what the canvas draws from.
    assert(#section.entries > 0, "the rendered entries survive release")
  end,
  ["differ: releasing many sections returns their text to the heap"] = function()
    local line = ("q"):rep(200)
    local old = (line .. "\n"):rep(500)
    local new = (line .. "r\n"):rep(500)

    local sections = {}
    for i = 1, 12 do
      -- Distinct per section, so interning cannot share one copy between them.
      sections[i] = differ.build_section(
        ("f%d.txt"):format(i), old .. i .. "\n", new .. i .. "\n", "M")
    end
    collectgarbage("collect")
    local held = collectgarbage("count")

    for _, section in ipairs(sections) do
      differ.release_text(section)
    end
    collectgarbage("collect")
    collectgarbage("collect")
    local freed = held - collectgarbage("count")

    -- 12 sections of roughly 100 KiB per side. Deliberately a loose floor: the
    -- claim is that the text is gone, not that a precise number of bytes is.
    assert(freed > 1024, ("releasing 12 sections freed only %.0f KiB"):format(freed))
    for _, section in ipairs(sections) do
      assert(#section.entries > 0, "and every section still renders")
      assert(differ.fingerprint(section) ~= "", "and still fingerprints")
    end
  end,
  ["differ: fingerprint still answers for a section built the ordinary way"] = function()
    local same = differ.build_section("a.txt", "o\n", "n\n", "M")
    local other = differ.build_section("b.txt", "o\n", "n\n", "M")
    local changed = differ.build_section("a.txt", "o\n", "N\n", "M")
    H.eq(differ.fingerprint(same), differ.fingerprint(other),
      "identical new sides fingerprint identically, whatever the path")
    assert(differ.fingerprint(same) ~= differ.fingerprint(changed),
      "a different new side does not")
    H.eq(differ.fingerprint(nil), differ.fingerprint(
      differ.build_section("empty.txt", "", "", "M")),
      "and an absent section reads as empty, as it always has")
  end,
  ["diff facade: exports only the curated public operations"] = function()
    local names = vim.tbl_keys(differ)
    table.sort(names)
    H.eq(names, {
      "anchor",
      "build",
      "build_section",
      "fingerprint",
      "fold",
      "hunks",
      "is_binary",
      "lens",
      "release_text",
      "stage",
      "staged_then_changed",
      "word_marks",
    })
  end,
  ["differ: simple change"] = function()
    local h = differ.hunks("a\nb\nc\n", "a\nX\nc\n")
    H.eq(h, { { 2, 1, 2, 1 } })
  end,
  ["differ: pure addition"] = function()
    local h = differ.hunks("a\nc\n", "a\nb\nc\n")
    H.eq(h, { { 1, 0, 2, 1 } })
  end,
  ["differ: empty old side (new file)"] = function()
    local h = differ.hunks("", "a\nb\n")
    H.eq(#h, 1)
    H.eq(h[1][4], 2) -- new_count covers whole file
  end,
}
