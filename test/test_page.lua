local H = require("helpers")
local Page = require("canvasdiff.canvas.Page")

local T = {}

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function encoded(payload, values, fields)
  fields = fields or {}
  local offsets = {}
  for index, value in ipairs(values) do
    offsets[index] = u16(value)
  end
  local oversized = fields.oversized
  if oversized == nil then
    oversized = false
  end
  return {
    codec = fields.codec == nil and "raw" or fields.codec,
    payload = payload,
    offsets = table.concat(offsets),
    offset_width = fields.offset_width == nil and 2 or fields.offset_width,
    row_count = fields.row_count == nil and (#values - 1) or fields.row_count,
    decoded_bytes = fields.decoded_bytes == nil and #payload or fields.decoded_bytes,
    max_rows = fields.max_rows == nil and 256 or fields.max_rows,
    max_bytes = fields.max_bytes == nil and 65536 or fields.max_bytes,
    oversized = oversized,
  }
end

T["page_ loads without an editor runtime"] = function()
  local root = vim.fs.dirname(vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
  local chunk = assert(loadfile(vim.fs.joinpath(root, "lua", "canvasdiff", "canvas", "Page.lua")))
  local runtime = _G.vim
  _G.vim = nil
  local ok, loaded = pcall(chunk)
  _G.vim = runtime
  assert(ok, loaded)
  H.eq(type(loaded.new), "function")
end

T["page_ round-trips byte rows and empty rows"] = function()
  local rows = {
    "",
    "plain",
    "carriage\rreturn",
    "nul\0byte",
    string.char(0xFF, 0xFE, 0x80),
    "終わり",
    "",
  }
  local page = Page.new(rows)

  H.eq(page.row_count, #rows)
  H.eq(page:rows(), rows)
  H.eq(page:row(1), "")
  H.eq(page:row(#rows), "")
  H.eq(page.decoded_bytes, #table.concat(rows))
  H.eq(page:storage_bytes(), #page.payload + (#rows + 1) * page.offset_width)
  H.eq(Page.validate(page), true)
end

T["page_ chooses the narrowest safe offset table"] = function()
  local narrow = Page.new({ string.rep("x", 65535) })
  H.eq(narrow.offset_width, 2)
  H.eq(narrow.oversized, false)

  local wide = Page.new({ string.rep("x", 65536) })
  H.eq(wide.offset_width, 4)
  H.eq(wide.oversized, false)
  H.eq(wide:row(1), string.rep("x", 65536))

  local oversized = Page.new({ string.rep("x", 65537) })
  H.eq(oversized.offset_width, 4)
  H.eq(oversized.oversized, true)
end

T["page_ enforces dense rows and structural limits"] = function()
  local cases = {
    { {}, "at least one" },
    { { "a", false }, "row 2" },
    { { "a\nb" }, "line%-feed" },
    { setmetatable({ [1] = "a", [3] = "c" }, {}), "dense" },
  }
  for _, case in ipairs(cases) do
    local page, err = Page.create(case[1])
    H.eq(page, nil)
    assert(err:match(case[2]), err)
  end

  local too_many = {}
  for index = 1, 257 do
    too_many[index] = "x"
  end
  H.eq(Page.create(too_many), nil)
  H.eq(Page.create({ string.rep("x", 40000), string.rep("y", 40000) }), nil)

  local page, err = Page.create({ "x" }, { max_rows = 0 })
  H.eq(page, nil)
  assert(err:match("max_rows"), err)
  H.eq(Page.create({ "x" }, { max_rows = false }), nil)
  H.eq(Page.create({ "x" }, { max_bytes = false }), nil)
  H.eq(Page.create({ "x" }, false), nil)
  H.eq(Page.create({ "x" }, { max_rows = math.huge }), nil)
  H.eq(Page.create({ "x" }, { max_bytes = math.huge }), nil)
end

T["page_ encoded input rejects every offset invariant break"] = function()
  local cases = {
    { encoded("abc", { 1, 2, 3 }), "start at zero" },
    { encoded("abc", { 0, 3, 2 }), "monotonic" },
    { encoded("abc", { 0, 2, 4 }), "exceeds the payload" },
    { encoded("abc", { 0, 1, 2 }), "end at decoded_bytes" },
    { encoded("abc", { 0, 1, 3 }, { decoded_bytes = 2 }), "payload length" },
    { encoded("abc", { 0, 1, 3 }, { row_count = 1 }), "wrong length" },
    { encoded("abc", { 0, 1, 3 }, { codec = "mystery" }), "unsupported page codec" },
    { encoded("abc", { 0, 3 }, { max_bytes = 2 }), "oversized flag" },
    { encoded("abc", { 0, 3 }, { max_rows = false }), "limits" },
    { encoded("abc", { 0, 3 }, { max_bytes = false }), "limits" },
    { encoded("abc", { 0, 3 }, { oversized = 0 }), "must be a boolean" },
    { encoded("abc", { 0, 3 }, { oversized = "false" }), "must be a boolean" },
  }

  for _, case in ipairs(cases) do
    local page, err = Page.from_encoded(case[1])
    H.eq(page, nil)
    assert(err:find(case[2], 1, true) or err:match(case[2]), err)
  end
end

T["page_ encoded round-trip is representation exact"] = function()
  local original = Page.new({ "alpha", "", "omega" }, { max_rows = 8, max_bytes = 64 })
  local restored = assert(Page.from_encoded(original:encoded()))

  H.eq(restored:encoded(), original:encoded())
  H.eq(restored:rows(), { "alpha", "", "omega" })
  H.eq(restored:byte_range(2), 5)
  H.eq(select(2, restored:byte_range(2)), 5)
  H.eq(restored:row(0), nil)
  H.eq(restored:rows(3, 2), nil)
end

return T
