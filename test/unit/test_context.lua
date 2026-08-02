-- What granularity a verb is standing on, resolved from one canvas row.

local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")
local context = canvas.context

local T = {}

-- 1-based offsets into a two-hunk section's entries -- the same offsets
-- canvas.locate answers with. Asserted against the built section in
-- two_hunk_section, so a change in how build_section lays out context rows
-- fails there rather than silently retargeting every row assertion below.
local FILE_HDR, HUNK1_HDR, HUNK1_BODY = 1, 2, 6
local HUNK1_LAST, HUNK2_HDR, HUNK2_BODY = 9, 10, 14

--- 30 lines with line 5 and line 25 rewritten: far enough apart that the
--- default context window keeps them two separate hunks.
local function two_hunk_section(path)
  local old, new = {}, {}
  for i = 1, 30 do
    old[i], new[i] = "line " .. i, "line " .. i
  end
  new[5] = "line 5 CHANGED"
  new[25] = "line 25 CHANGED"
  local section = model.build_section(
    path, table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", "M")

  H.eq(section.nhunks, 2, path .. ": fixture must have exactly two hunks")
  H.eq(section.entries[FILE_HDR].kind, "file_hdr", path .. ": FILE_HDR offset moved")
  H.eq(section.entries[HUNK1_HDR].kind, "hunk_hdr", path .. ": HUNK1_HDR offset moved")
  H.eq(section.entries[HUNK1_BODY].kind, "add", path .. ": HUNK1_BODY offset moved")
  H.eq(section.entries[HUNK1_LAST].hunk_idx, 1, path .. ": HUNK1_LAST offset moved")
  H.eq(section.entries[HUNK2_HDR].kind, "hunk_hdr", path .. ": HUNK2_HDR offset moved")
  H.eq(section.entries[HUNK2_BODY].kind, "add", path .. ": HUNK2_BODY offset moved")
  return section
end

local function binary_section(path)
  local section = model.build_section(path, "old\0bytes", "new\0bytes", "M")
  H.eq(section.binary, true, path .. ": fixture must be binary")
  H.eq(section.entries[2].kind, "binary", path .. ": binary notice offset moved")
  return section
end

local function open_canvas()
  return canvas.open({
    two_hunk_section("one/a.lua"),
    two_hunk_section("two/b.lua"),
    binary_section("three/bin.dat"),
  }, {})
end

--- 0-based canvas row of section `i`'s entry at 1-based `offset`.
local function row(st, i, offset)
  return (canvas.section_rows(st, i)) + offset - 1
end

T["context_resolve a hunk body row resolves to the hunk it belongs to"] = function()
  local st = open_canvas()
  H.eq(context.resolve(st, row(st, 1, HUNK1_BODY)),
    { scope = "hunk", section = 1, hunk = 1 })
  H.eq(context.resolve(st, row(st, 1, HUNK2_BODY)),
    { scope = "hunk", section = 1, hunk = 2 })
end

T["context_resolve a hunk header resolves to its own hunk"] = function()
  local st = open_canvas()
  H.eq(context.resolve(st, row(st, 1, HUNK1_HDR)),
    { scope = "hunk", section = 1, hunk = 1 })
  H.eq(context.resolve(st, row(st, 1, HUNK2_HDR)),
    { scope = "hunk", section = 1, hunk = 2 })
  -- The row immediately above the second header still belongs to the first
  -- hunk: the boundary is where an off-by-one offset would show up.
  H.eq(context.resolve(st, row(st, 1, HUNK1_LAST)),
    { scope = "hunk", section = 1, hunk = 1 })
end

T["context_resolve a file header is file scope, not the hunk under it"] = function()
  local st = open_canvas()
  H.eq(context.resolve(st, row(st, 1, FILE_HDR)), { scope = "file", section = 1 })
end

T["context_resolve a binary notice is file scope"] = function()
  local st = open_canvas()
  H.eq(context.resolve(st, row(st, 3, 1)), { scope = "file", section = 3 })
  H.eq(context.resolve(st, row(st, 3, 2)), { scope = "file", section = 3 })
end

T["context_resolve a folded placeholder is file scope"] = function()
  local st = open_canvas()
  st.folded = { ["two/"] = true }
  canvas.resync_visibility(st)

  local placeholder = (canvas.section_rows(st, 2))
  H.eq(context.resolve(st, placeholder), { scope = "file", section = 2 })
  -- The one row a folded section occupies is all of it: the next row is
  -- already the following section.
  H.eq(context.resolve(st, placeholder + 1), { scope = "file", section = 3 })
  -- And an unfolded neighbour still resolves to its hunk.
  H.eq(context.resolve(st, row(st, 1, HUNK2_BODY)),
    { scope = "hunk", section = 1, hunk = 2 })
end

T["context_resolve names the section the row is in, not the first one"] = function()
  local st = open_canvas()
  H.eq(context.resolve(st, row(st, 2, HUNK1_BODY)),
    { scope = "hunk", section = 2, hunk = 1 })
  H.eq(context.resolve(st, row(st, 2, HUNK2_HDR)),
    { scope = "hunk", section = 2, hunk = 2 })
  H.eq(context.resolve(st, row(st, 2, FILE_HDR)), { scope = "file", section = 2 })
end

T["context_resolve is nil when there is no section under the row"] = function()
  local st = canvas.open({}, {})
  H.eq(context.resolve(st, 0), nil)
end

return T
