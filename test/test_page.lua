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
  H.eq(type(loaded.revision), "function")
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

T["page_ public representation mutations cannot alter trusted reads"] =
  function()
    local rows = { "alpha", "beta" }
    local page = Page.new(rows, { max_rows = 8, max_bytes = 64 })
    local original = page:encoded()
    local storage_bytes = #original.payload + #original.offsets
    local mutations = {
      { "codec", "RAW" },
      { "payload", "ALPHAbeta" },
      { "offsets", u16(0) .. u16(4) .. u16(9) },
      { "offset_width", 4 },
      { "row_count", 1 },
      { "decoded_bytes", 8 },
      { "max_rows", 9 },
      { "max_bytes", 65 },
      { "oversized", true },
    }

    H.eq(Page.revision(page), 0)
    for _, mutation in ipairs(mutations) do
      local field, value = mutation[1], mutation[2]
      page[field] = value

      H.eq(Page.encoded(page), original, field .. " encoded authority")
      H.eq({ Page.byte_range(page, 1) }, { 0, 5 },
        field .. " offset authority")
      H.eq(Page.row(page, 1), "alpha", field .. " row authority")
      H.eq(Page.rows(page), rows, field .. " rows authority")
      H.eq(Page.storage_bytes(page), storage_bytes,
        field .. " storage authority")
      H.eq(Page.revision(page), 0, field .. " revision authority")

      local ok, err = Page.validate(page)
      H.eq(ok, nil, field .. " mutation must be rejected")
      assert(err:find(field, 1, true), err)

      page[field] = original[field]
      H.eq(Page.validate(page), true)
    end
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

T["page_ trusted decode rejects and bypasses instance method shadows"] = function()
  local page = Page.new({ "alpha", "", "omega" })
  page.byte_range = function()
    return 0, 0
  end
  H.eq(Page.row(page, 1), "alpha")
  local ok, err = Page.validate(page)
  H.eq(ok, nil)
  assert(err:match("shadows trusted method byte_range"), err)
  page.byte_range = nil

  page.row = function(_, index)
    return "forged-" .. index
  end
  H.eq(Page.rows(page, 1, 3), { "alpha", "", "omega" })
  ok, err = Page.validate(page)
  H.eq(ok, nil)
  assert(err:match("shadows trusted method row"), err)
  page.row = nil

  page.revision = function()
    return 99
  end
  H.eq(Page.revision(page), 0)
  ok, err = Page.validate(page)
  H.eq(ok, nil)
  assert(err:match("shadows trusted method revision"), err)
end

T["page_ validation never invokes cdata shadow equality"] = function()
  local ffi = require("ffi")
  ffi.cdef([[
    typedef struct {
      int value;
    } canvasdiff_page_shadow_probe;
  ]])

  local calls = 0
  local Probe = ffi.metatype("canvasdiff_page_shadow_probe", {
    __eq = function()
      calls = calls + 1
      return false
    end,
  })
  local page = Page.new({ "alpha" })
  page.row = Probe(0)

  local ok, err = Page.validate(page)
  H.eq(ok, nil)
  assert(err:match("shadows trusted method row"), err)
  H.eq(calls, 0)

  page.row = nil
  H.eq(Page.validate(page), true)
end

T["page_ ownership cannot be forged with a protected metatable"] = function()
  local page = Page.new({ "alpha", "omega" })
  local fake = page:encoded()
  setmetatable(fake, {
    __metatable = Page,
    __index = Page,
  })

  assert(getmetatable(fake) == Page,
    "the public metatable API should demonstrate the forged identity")
  local ok, err = Page.validate(fake)
  H.eq(ok, nil)
  assert(err:match("not an owned Page"), err)
  H.eq(Page.validate(page), true)
end

return T
