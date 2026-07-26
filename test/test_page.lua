local H = require("helpers")
local Page = require("canvasdiff.canvas.Page")

local T = {}
local TEST_CODEC = "test-block-v1"

local function test_crc32(raw)
  local checksum = 0
  for index = 1, #raw do
    checksum = (checksum + string.byte(raw, index) * index) % 4294967296
  end
  return checksum
end

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
  H.eq(type(loaded.prepare_cold), "function")
  H.eq(type(loaded.publish_cold), "function")
  H.eq(type(loaded.discard_candidate), "function")
  H.eq(type(loaded.read_view), "function")
  H.eq(type(loaded.cancel_restore), "function")
  H.eq(type(loaded.release_view), "function")
  H.eq(type(loaded.is_authorized), "function")
  H.eq(type(loaded.view_metadata), "function")
  H.eq(type(loaded.validate_view), "function")
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
      { "crc32", 1 },
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

T["page_ snapshots only raw dense row sequences"] = function()
  local callback_calls = 0
  local sparse = setmetatable({
    [1] = "a",
    [2] = "b",
    [4] = "d",
    [100] = "z",
  }, {
    __index = function()
      callback_calls = callback_calls + 1
      error("row lookup callback must not run")
    end,
    __len = function()
      callback_calls = callback_calls + 1
      return 4
    end,
    __pairs = function()
      callback_calls = callback_calls + 1
      error("row iteration callback must not run")
    end,
  })

  local page, err = Page.create(sparse)
  H.eq(page, nil)
  assert(err:find("dense", 1, true), err)
  H.eq(callback_calls, 0)

  local virtual_hole = setmetatable({ [1] = "a", [3] = "c" }, {
    __index = function(_, key)
      callback_calls = callback_calls + 1
      if key == 2 then
        return "b"
      end
    end,
  })
  page, err = Page.create(virtual_hole)
  H.eq(page, nil)
  assert(err:find("dense", 1, true), err)
  H.eq(callback_calls, 0)

  local dense = setmetatable({ "alpha", "beta" }, {
    __index = function()
      callback_calls = callback_calls + 1
      error("row lookup callback must not run")
    end,
  })
  H.eq(Page.rows(assert(Page.create(dense))), { "alpha", "beta" })
  H.eq(callback_calls, 0)
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

  local original_payload = page.payload
  local callback_calls = 0
  page.payload = Probe(1)
  local candidate, candidate_err = Page.prepare_cold(page, 0, {
    codec = TEST_CODEC,
    encode = function()
      callback_calls = callback_calls + 1
      return "\1"
    end,
    crc32 = test_crc32,
  })
  H.eq(candidate, nil)
  assert(candidate_err:find("payload", 1, true), candidate_err)
  H.eq(callback_calls, 0)
  H.eq(calls, 0)
  page.payload = original_payload
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

T["page_ trusted metadata and raw views ignore public snapshots"] = function()
  local rows = { "alpha", "", "nul\0tail" }
  local page = Page.new(rows, { max_rows = 8, max_bytes = 64 })
  local before = page:encoded()
  local metadata = assert(Page.metadata(page))

  H.eq(metadata.kind, "raw")
  H.eq(metadata.codec, "raw")
  H.eq(metadata.row_count, 3)
  H.eq(metadata.offset_width, 2)
  H.eq(metadata.decoded_bytes, #table.concat(rows))
  H.eq(metadata.max_rows, 8)
  H.eq(metadata.max_bytes, 64)
  H.eq(metadata.oversized, false)
  H.eq(metadata.storage_bytes, #before.offsets + #before.payload)
  H.eq(metadata.resident_bytes, metadata.storage_bytes)
  H.eq(metadata.restore_bytes, metadata.storage_bytes)
  H.eq(metadata.view_bytes, 0)
  H.eq(metadata.revision, 0)
  H.eq(metadata.quarantined, false)

  local hostile_options = setmetatable({}, {
    __index = function()
      error("raw views must not inspect codec callbacks")
    end,
  })
  local view = assert(Page.read_view(page, 0, hostile_options))
  H.eq(getmetatable(view), false)
  H.eq(next(view), nil)
  H.eq(rawget(view, "payload"), nil)
  H.eq(Page.view_rows(view), rows)
  H.eq(Page.view_row(view, 2), "")
  H.eq({ Page.view_byte_range(view, 3) }, { 5, 13 })
  H.eq(Page.view_metadata(view), {
    kind = "raw",
    revision = 0,
    row_count = 3,
    view_bytes = 0,
  })
  H.eq(Page.validate_view(view, page, 0), true)
  H.eq(Page.validate_view(view, page, 1), nil)
  H.eq(Page.validate_view(view, Page.new({ "other" }), 0), nil)

  page.row_count = 99
  H.eq(Page.metadata(page).row_count, 3)
  H.eq(Page.view_rows(view), rows)
  H.eq(Page.view_rows(assert(Page.read_view(page, 0))), rows)
  page.row_count = before.row_count
  H.eq(Page.validate(page), true)

  rawset(view, "row", function()
    return "forged"
  end)
  H.eq(Page.validate_view(view, page, 0), nil)
  H.eq(Page.view_row(view, 1), nil)
end

T["page_ cold candidates are canonical private and atomically published"] =
  function()
    local rows = { "alpha", "", "omega\0tail" }
    local page = Page.new(rows, { max_rows = 8, max_bytes = 64 })
    local identity = page
    local before = page:encoded()
    local body = before.offsets .. before.payload
    local encoded_input
    local encoded_budget
    local checksum_input
    local encode_calls = 0
    local checksum_calls = 0
    local block = "\1"

    local candidate = assert(Page.prepare_cold(page, 0, {
      codec = TEST_CODEC,
      encode = function(raw, budget)
        encode_calls = encode_calls + 1
        encoded_input = raw
        encoded_budget = budget
        return block
      end,
      crc32 = function(raw)
        checksum_calls = checksum_calls + 1
        checksum_input = raw
        return test_crc32(raw)
      end,
    }))

    H.eq(rawequal(page, identity), true)
    H.eq(page:encoded(), before)
    H.eq(Page.revision(page), 0)
    H.eq(encoded_input, body)
    H.eq(checksum_input, body)
    H.eq(encoded_budget, #body - 1)
    H.eq(encode_calls, 1)
    H.eq(checksum_calls, 1)
    H.eq(Page.candidate_metadata(candidate), {
      codec = TEST_CODEC,
      storage_bytes = #block,
      raw_bytes = #body,
      crc32 = test_crc32(body),
    })
    H.eq(getmetatable(candidate), false)
    H.eq(rawget(candidate, "payload"), nil)

    local other = Page.new({ "other" })
    local published, publish_err =
      Page.publish_cold(other, candidate, 0)
    H.eq(published, nil)
    assert(publish_err:find("another Page", 1, true), publish_err)
    H.eq(Page.revision(page), 0)

    local ok, old_storage, new_storage, revision =
      Page.publish_cold(page, candidate, 0)
    H.eq(ok, true)
    H.eq(old_storage, #body)
    H.eq(new_storage, #block)
    H.eq(revision, 1)
    H.eq(encode_calls, 1, "publish must be callback-free")
    H.eq(checksum_calls, 1, "publish must be callback-free")
    H.eq(rawequal(page, identity), true)
    H.eq(Page.revision(page), 1)
    H.eq(Page.storage_bytes(page), #block)
    H.eq(Page.validate(page), true)

    local after = page:encoded()
    H.eq(after.codec, TEST_CODEC)
    H.eq(after.payload, block)
    H.eq(after.offsets, "")
    H.eq(after.crc32, test_crc32(body))
    H.eq(after.row_count, before.row_count)
    H.eq(after.offset_width, before.offset_width)
    H.eq(after.decoded_bytes, before.decoded_bytes)
    H.eq(after.max_rows, before.max_rows)
    H.eq(after.max_bytes, before.max_bytes)
    H.eq(after.oversized, before.oversized)

    local cold_metadata = Page.metadata(page)
    H.eq(cold_metadata.kind, "cold")
    H.eq(cold_metadata.codec, TEST_CODEC)
    H.eq(cold_metadata.row_count, #rows)
    H.eq(cold_metadata.restore_bytes, #body)
    H.eq(cold_metadata.view_bytes, #body)
    H.eq(cold_metadata.storage_bytes, #block)
    H.eq(cold_metadata.revision, 1)
    H.eq(cold_metadata.quarantined, false)
    H.eq(Page.candidate_metadata(candidate), nil)
    local row, row_err = Page.row(page, 1)
    H.eq(row, nil)
    assert(row_err:find("not resident", 1, true), row_err)
  end

T["page_ cold preparation keeps no-benefit and callback faults atomic"] =
  function()
    local page = Page.new({ "repeat-repeat-repeat" })
    local before = page:encoded()
    local body = before.offsets .. before.payload
    local checksum_calls = 0

    local candidate, err = Page.prepare_cold(page, 0, {
      codec = TEST_CODEC,
      encode = function()
        return body
      end,
      crc32 = function(raw)
        checksum_calls = checksum_calls + 1
        return test_crc32(raw)
      end,
    })
    H.eq(candidate, false)
    assert(err:find("not smaller", 1, true), err)
    H.eq(checksum_calls, 0)
    H.eq(Page.revision(page), 0)
    H.eq(page:encoded(), before)

    local crc_calls = 0
    candidate, err = Page.prepare_cold(page, 0, {
      codec = TEST_CODEC,
      encode = function()
        page.validate = function()
          return true
        end
        return "\1"
      end,
      crc32 = function(raw)
        crc_calls = crc_calls + 1
        return test_crc32(raw)
      end,
    })
    H.eq(candidate, nil)
    assert(err:find("changed during cold preparation", 1, true), err)
    H.eq(crc_calls, 0)
    page.validate = nil
    H.eq(Page.validate(page), true)

    candidate, err = Page.prepare_cold(page, 0, {
      codec = TEST_CODEC,
      encode = function()
        error(string.rep("untrusted", 1000))
      end,
      crc32 = test_crc32,
    })
    H.eq(candidate, nil)
    assert(err:find("encode callback failed", 1, true), err)
    assert(#err < 100, err)
    H.eq(Page.revision(page), 0)
    H.eq(page:encoded(), before)

    candidate, err = Page.prepare_cold(page, 0, {
      codec = TEST_CODEC,
      encode = function()
        return "\1"
      end,
      crc32 = function()
        return 0 / 0
      end,
    })
    H.eq(candidate, nil)
    assert(err:find("invalid checksum", 1, true), err)
    H.eq(Page.revision(page), 0)
    H.eq(page:encoded(), before)

    H.eq(Page.prepare_cold(page, 1, {
      codec = TEST_CODEC,
      encode = function()
        error("must not run")
      end,
      crc32 = test_crc32,
    }), nil)
    H.eq(Page.revision(page), 0)
  end

T["page_ cold publication preserves wide and oversized metadata"] = function()
  local cases = {
    {
      page = Page.new({ string.rep("x", 32) }, {
        max_rows = 1,
        max_bytes = 8,
      }),
      offset_width = 2,
      oversized = true,
    },
    {
      page = Page.new({ string.rep("y", 65536) }, {
        max_rows = 1,
        max_bytes = 65536,
      }),
      offset_width = 4,
      oversized = false,
    },
  }

  for _, case in ipairs(cases) do
    local before = Page.metadata(case.page)
    local body
    local candidate = assert(Page.prepare_cold(case.page, 0, {
      codec = TEST_CODEC,
      encode = function(raw)
        body = raw
        return "\6"
      end,
      crc32 = test_crc32,
    }))
    assert(Page.publish_cold(case.page, candidate, 0))
    local after = Page.metadata(case.page)
    H.eq(after.offset_width, case.offset_width)
    H.eq(after.oversized, case.oversized)
    H.eq(after.row_count, before.row_count)
    H.eq(after.decoded_bytes, before.decoded_bytes)
    H.eq(after.max_rows, before.max_rows)
    H.eq(after.max_bytes, before.max_bytes)
    H.eq(after.restore_bytes, #body)
    H.eq(after.revision, 1)
  end
end

T["page_ reentrant preparation and stale candidates cannot overwrite"] =
  function()
    local page = Page.new({ "reentrant-reentrant" })
    local inner_published = false
    local outer_crc_calls = 0

    local outer, outer_err = Page.prepare_cold(page, 0, {
      codec = "outer-codec",
      encode = function()
        local inner = assert(Page.prepare_cold(page, 0, {
          codec = "inner-codec",
          encode = function()
            return "i"
          end,
          crc32 = test_crc32,
        }))
        inner_published = assert(Page.publish_cold(page, inner, 0))
        return "o"
      end,
      crc32 = function(raw)
        outer_crc_calls = outer_crc_calls + 1
        return test_crc32(raw)
      end,
    })
    H.eq(outer, nil)
    assert(outer_err:find("changed during cold preparation", 1, true),
      outer_err)
    H.eq(inner_published, true)
    H.eq(outer_crc_calls, 0)
    H.eq(Page.revision(page), 1)
    H.eq(Page.encoded(page).codec, "inner-codec")
    H.eq(Page.encoded(page).payload, "i")

    local second = Page.new({ "two-candidates-two-candidates" })
    local function prepare(block)
      return assert(Page.prepare_cold(second, 0, {
        codec = TEST_CODEC,
        encode = function()
          return block
        end,
        crc32 = test_crc32,
      }))
    end
    local first = prepare("a")
    local stale = prepare("b")
    H.eq(Page.publish_cold(second, first, 0), true)
    local published, stale_err = Page.publish_cold(second, stale, 0)
    H.eq(published, nil)
    assert(stale_err:find("no longer valid", 1, true), stale_err)
    H.eq(Page.candidate_metadata(stale), nil)
    H.eq(Page.revision(second), 1)
    H.eq(Page.encoded(second).payload, "a")
  end

T["page_ opaque candidates and views have explicit terminal release"] =
  function()
    local page = Page.new({ "release-release-release" })
    local candidate = assert(Page.prepare_cold(page, 0, {
      codec = TEST_CODEC,
      encode = function()
        return "\1"
      end,
      crc32 = test_crc32,
    }))
    local published, err = Page.publish_cold(page, candidate, 1)
    H.eq(published, nil)
    assert(err:find("stale", 1, true), err)
    assert(Page.candidate_metadata(candidate))
    H.eq(Page.discard_candidate(candidate), true)
    H.eq(Page.candidate_metadata(candidate), nil)
    H.eq(Page.discard_candidate(candidate), false)

    local forged_candidate = assert(Page.prepare_cold(page, 0, {
      codec = TEST_CODEC,
      encode = function()
        return "\2"
      end,
      crc32 = test_crc32,
    }))
    debug.setmetatable(forged_candidate, {})
    H.eq(Page.discard_candidate(forged_candidate), true)

    local raw_page = Page.new({ "view-release" })
    local view = assert(Page.read_view(raw_page, 0))
    H.eq(Page.release_view(view), true)
    H.eq(Page.view_row(view, 1), nil)
    H.eq(Page.release_view(view), false)

    local forged_view = assert(Page.read_view(raw_page, 0))
    debug.setmetatable(forged_view, {})
    H.eq(Page.release_view(forged_view), true)
  end

T["page_ terminal handle shells cannot retain Page storage"] = function()
  local row = string.rep("x", 128 * 1024)

  local function weak_page(page)
    return setmetatable({ [page] = true }, { __mode = "k" })
  end

  local function assert_collected(weak, message)
    for _ = 1, 3 do
      collectgarbage("collect")
    end
    H.eq(next(weak), nil, message)
  end

  local function published_view_shell()
    local page = Page.new({ row })
    local weak = weak_page(page)
    local view = assert(Page.read_view(page, 0))
    local candidate = assert(Page.prepare_cold(page, 0, {
      codec = TEST_CODEC,
      encode = function()
        return "\1"
      end,
      crc32 = test_crc32,
    }))
    assert(Page.publish_cold(page, candidate, 0))
    return weak, view
  end

  local weak, shell = published_view_shell()
  assert_collected(weak, "a stale raw-view shell retained its Page")
  H.eq(Page.view_row(shell, 1), nil)

  local function sibling_candidate_shell()
    local page = Page.new({ row })
    local weak = weak_page(page)
    local function prepare(block)
      return assert(Page.prepare_cold(page, 0, {
        codec = TEST_CODEC,
        encode = function()
          return block
        end,
        crc32 = test_crc32,
      }))
    end
    local winner = prepare("\2")
    local sibling = prepare("\3")
    assert(Page.publish_cold(page, winner, 0))
    return weak, sibling
  end

  weak, shell = sibling_candidate_shell()
  assert_collected(weak, "a stale candidate shell retained its Page")
  H.eq(Page.candidate_metadata(shell), nil)

  local function quarantined_view_shell()
    local page = Page.new({ row })
    local weak = weak_page(page)
    local body
    local candidate = assert(Page.prepare_cold(page, 0, {
      codec = TEST_CODEC,
      encode = function(raw)
        body = raw
        return "\4"
      end,
      crc32 = test_crc32,
    }))
    assert(Page.publish_cold(page, candidate, 0))
    local view = assert(Page.read_view(page, 1, {
      codec = TEST_CODEC,
      decode = function()
        return body
      end,
      crc32 = test_crc32,
    }))
    H.eq(Page.read_view(page, 1, {
      codec = TEST_CODEC,
      decode = function()
        return nil
      end,
      crc32 = test_crc32,
    }), nil)
    return weak, view
  end

  weak, shell = quarantined_view_shell()
  assert_collected(weak, "a quarantined view shell retained its Page")
  H.eq(Page.view_row(shell, 1), nil)

  local function explicitly_released_shells()
    local candidate_page = Page.new({ row })
    local candidate_weak = weak_page(candidate_page)
    local candidate = assert(Page.prepare_cold(candidate_page, 0, {
      codec = TEST_CODEC,
      encode = function()
        return "\5"
      end,
      crc32 = test_crc32,
    }))
    assert(Page.discard_candidate(candidate))

    local view_page = Page.new({ row })
    local view_weak = weak_page(view_page)
    local view = assert(Page.read_view(view_page, 0))
    assert(Page.release_view(view))
    return candidate_weak, candidate, view_weak, view
  end

  local candidate_weak, candidate_shell, view_weak, view_shell =
    explicitly_released_shells()
  assert_collected(candidate_weak,
    "a discarded candidate shell retained its Page")
  assert_collected(view_weak, "a released view shell retained its Page")
  H.eq(Page.candidate_metadata(candidate_shell), nil)
  H.eq(Page.view_row(view_shell, 1), nil)
end

T["page_ representation authorization is fenced across callbacks"] =
  function()
    local preparing = Page.new({ "prepare-claim-prepare-claim" })
    local prepare_node = {}
    local prepare_cap
    local crc_calls = 0
    local candidate, err = Page.prepare_cold(preparing, 0, {
      codec = TEST_CODEC,
      encode = function()
        local claimed
        claimed, prepare_cap = Page.claim(preparing, prepare_node)
        assert(claimed)
        return "\1"
      end,
      crc32 = function(raw)
        crc_calls = crc_calls + 1
        return test_crc32(raw)
      end,
    })
    H.eq(candidate, nil)
    assert(err:find("changed during cold preparation", 1, true), err)
    H.eq(crc_calls, 0)
    H.eq(Page.is_authorized(preparing, prepare_node, prepare_cap), true)

    local function make_cold()
      local page = Page.new({ "restore-claim-restore-claim" })
      local body
      local prepared = assert(Page.prepare_cold(page, 0, {
        codec = TEST_CODEC,
        encode = function(raw)
          body = raw
          return "\2"
        end,
        crc32 = test_crc32,
      }))
      assert(Page.publish_cold(page, prepared, 0))
      return page, body
    end

    local decoding, decode_body = make_cold()
    local decode_node = {}
    local decode_cap
    local view
    view, err = Page.read_view(decoding, 1, {
      codec = TEST_CODEC,
      decode = function()
        local claimed
        claimed, decode_cap = Page.claim(decoding, decode_node)
        assert(claimed)
        return decode_body
      end,
      crc32 = test_crc32,
    })
    H.eq(view, nil)
    assert(err:find("changed during cold restore", 1, true), err)
    H.eq(Page.metadata(decoding).quarantined, false)
    H.eq(Page.view_rows(assert(Page.read_view(decoding, 1, {
      codec = TEST_CODEC,
      decode = function()
        return decode_body
      end,
      crc32 = test_crc32,
    }, decode_cap))), { "restore-claim-restore-claim" })

    local checksumming, checksum_body = make_cold()
    local checksum_node = {}
    local checksum_cap
    view, err = Page.read_view(checksumming, 1, {
      codec = TEST_CODEC,
      decode = function()
        return checksum_body
      end,
      crc32 = function(raw)
        local claimed
        claimed, checksum_cap = Page.claim(checksumming, checksum_node)
        assert(claimed)
        return test_crc32(raw)
      end,
    })
    H.eq(view, nil)
    assert(err:find("changed during cold restore", 1, true), err)
    H.eq(Page.metadata(checksumming).quarantined, false)
    H.eq(Page.is_authorized(checksumming, checksum_node, checksum_cap), true)
  end

T["page_ authenticated restore returns a nonmutating opaque raw view"] =
  function()
    local rows = { "alpha", "", "omega\0tail" }
    local page = Page.new(rows)
    local raw_view = assert(Page.read_view(page, 0))
    local raw_body
    local block = "\2"
    local candidate = assert(Page.prepare_cold(page, 0, {
      codec = TEST_CODEC,
      encode = function(body)
        raw_body = body
        return block
      end,
      crc32 = test_crc32,
    }))
    assert(Page.publish_cold(page, candidate, 0))
    H.eq(Page.view_row(raw_view, 1), nil,
      "a raw view must expire when its Page transitions")

    local before = page:encoded()
    local before_metadata = Page.metadata(page)
    local decode_calls = 0
    local crc_calls = 0
    local expected_size
    local seen_block
    local restore_options = {
      codec = TEST_CODEC,
      decode = function(encoded_block, expected)
        decode_calls = decode_calls + 1
        seen_block = encoded_block
        expected_size = expected
        return raw_body
      end,
      crc32 = function(body)
        crc_calls = crc_calls + 1
        return test_crc32(body)
      end,
    }

    local stale_view, stale_err = Page.read_view(page, 0, restore_options)
    H.eq(stale_view, nil)
    assert(stale_err:find("stale", 1, true), stale_err)
    H.eq(decode_calls, 0)

    local view = assert(Page.read_view(page, 1, restore_options))
    H.eq(decode_calls, 1)
    H.eq(crc_calls, 1)
    H.eq(seen_block, block)
    H.eq(expected_size, #raw_body)
    H.eq(getmetatable(view), false)
    H.eq(rawget(view, "offsets"), nil)
    H.eq(Page.view_rows(view), rows)
    H.eq(Page.view_row(view, 3), "omega\0tail")
    H.eq(Page.view_metadata(view), {
      kind = "cold-restored",
      revision = 1,
      row_count = #rows,
      view_bytes = #raw_body,
    })
    H.eq(Page.validate_view(view, page, 1), true)
    H.eq(page:encoded(), before)
    H.eq(Page.metadata(page), before_metadata)
    H.eq(Page.revision(page), 1)
    local resident, resident_err = Page.rows(page)
    H.eq(resident, nil)
    assert(resident_err:find("not resident", 1, true), resident_err)
  end

T["page_ authenticated restore cancellation preserves valid cold bytes"] =
  function()
    local function make_cold(rows, block)
      local page = Page.new(rows)
      local node = {}
      local claimed, capability = Page.claim(page, node)
      H.eq(claimed, true)
      local body
      local candidate = assert(Page.prepare_cold(page, 0, {
        codec = TEST_CODEC,
        encode = function(raw)
          body = raw
          return block
        end,
        crc32 = test_crc32,
      }, capability))
      assert(Page.publish_cold(page, candidate, 0, capability))
      return page, capability, body
    end

    local rows = { "cancel-cancel", "omega" }
    local page, capability, body = make_cold(rows, "\7")
    local before = Page.encoded(page)
    local missing_scope, missing_scope_err = Page.cancel_restore(
      page,
      1,
      capability,
      {},
      "out-of-band cancellation"
    )
    H.eq(missing_scope, nil)
    assert(missing_scope_err:find("scope", 1, true), missing_scope_err)

    local decode_cancellation
    local crc_calls = 0
    local view, err = Page.read_view(page, 1, {
      codec = TEST_CODEC,
      decode = function(_, _, scope)
        local wrong, wrong_err = Page.cancel_restore(
          page,
          1,
          {},
          scope,
          "forged cancellation"
        )
        H.eq(wrong, nil)
        assert(wrong_err:find("capability", 1, true), wrong_err)
        decode_cancellation = assert(Page.cancel_restore(
          page,
          1,
          capability,
          scope,
          "page-list restore source changed"
        ))
        H.eq(getmetatable(decode_cancellation), false)
        H.eq(next(decode_cancellation), nil)
        return decode_cancellation
      end,
      crc32 = function()
        crc_calls = crc_calls + 1
        return 0
      end,
    }, capability)
    H.eq(view, nil)
    assert(err:find("page-list restore source changed", 1, true), err)
    H.eq(crc_calls, 0, "CRC must not run after decode cancellation")
    H.eq(Page.metadata(page).quarantined, false)
    H.eq(Page.encoded(page), before)

    local restored = assert(Page.read_view(page, 1, {
      codec = TEST_CODEC,
      decode = function()
        return body
      end,
      crc32 = test_crc32,
    }, capability))
    H.eq(Page.view_rows(restored), rows)

    -- A used token is malformed decoder output, not a standing exemption from
    -- authentication. Reuse therefore quarantines this exact cold revision.
    view, err = Page.read_view(page, 1, {
      codec = TEST_CODEC,
      decode = function()
        return decode_cancellation
      end,
      crc32 = function()
        crc_calls = crc_calls + 1
        return 0
      end,
    }, capability)
    H.eq(view, nil)
    assert(err:find("decode failed", 1, true), err)
    H.eq(crc_calls, 0)
    H.eq(Page.metadata(page).quarantined, true)

    local crc_page, crc_capability, crc_body =
      make_cold({ "checksum-cancel" }, "\8")
    local checksum_calls = 0
    view, err = Page.read_view(crc_page, 1, {
      codec = TEST_CODEC,
      decode = function()
        return crc_body
      end,
      crc32 = function(_, scope)
        checksum_calls = checksum_calls + 1
        return assert(Page.cancel_restore(
          crc_page,
          1,
          crc_capability,
          scope,
          "page-list checksum source changed"
        ))
      end,
    }, crc_capability)
    H.eq(view, nil)
    assert(err:find("page-list checksum source changed", 1, true), err)
    H.eq(checksum_calls, 1)
    H.eq(Page.metadata(crc_page).quarantined, false)

    restored = assert(Page.read_view(crc_page, 1, {
      codec = TEST_CODEC,
      decode = function()
        return crc_body
      end,
      crc32 = test_crc32,
    }, crc_capability))
    H.eq(Page.view_rows(restored), { "checksum-cancel" })

    -- Even an authentic token is bound to one Page, revision, stage, and
    -- callback scope. Returning it from another restore is ordinary corrupt
    -- decoder output and quarantines the target, while leaving the source
    -- revision untouched.
    local source, source_capability, source_body =
      make_cold({ "source-token" }, "\9")
    local foreign
    assert(Page.read_view(source, 1, {
      codec = TEST_CODEC,
      decode = function(_, _, scope)
        foreign = assert(Page.cancel_restore(
          source,
          1,
          source_capability,
          scope,
          "captured but not returned"
        ))
        return source_body
      end,
      crc32 = test_crc32,
    }, source_capability))

    local target, target_capability =
      make_cold({ "target-token" }, "\10")
    view, err = Page.read_view(target, 1, {
      codec = TEST_CODEC,
      decode = function()
        return foreign
      end,
      crc32 = test_crc32,
    }, target_capability)
    H.eq(view, nil)
    assert(err:find("decode failed", 1, true), err)
    H.eq(Page.metadata(target).quarantined, true)
    H.eq(Page.metadata(source).quarantined, false)

    local forged = {}
    debug.setmetatable(forged, debug.getmetatable(foreign))
    local forged_target, forged_capability =
      make_cold({ "forged-token" }, "\11")
    view, err = Page.read_view(forged_target, 1, {
      codec = TEST_CODEC,
      decode = function()
        return forged
      end,
      crc32 = test_crc32,
    }, forged_capability)
    H.eq(view, nil)
    assert(err:find("decode failed", 1, true), err)
    H.eq(Page.metadata(forged_target).quarantined, true)
  end

T["page_ corrupt cold restore quarantines once without changing revision"] =
  function()
    local function make_cold(crc32)
      local page = Page.new({ "alpha", "omega" })
      local body
      local candidate = assert(Page.prepare_cold(page, 0, {
        codec = TEST_CODEC,
        encode = function(raw)
          body = raw
          return "\3"
        end,
        crc32 = crc32 or test_crc32,
      }))
      assert(Page.publish_cold(page, candidate, 0))
      return page, body
    end

    local cases = {
      {
        name = "decode",
        make = function()
          return make_cold()
        end,
        decode = function()
          return nil
        end,
        crc32 = test_crc32,
        reason = "decode failed",
      },
      {
        name = "size",
        make = function()
          return make_cold()
        end,
        decode = function(body)
          return body .. "x"
        end,
        crc32 = test_crc32,
        reason = "size mismatch",
      },
      {
        name = "checksum",
        make = function()
          return make_cold()
        end,
        decode = function(body)
          return body
        end,
        crc32 = function(body)
          return (test_crc32(body) + 1) % 4294967296
        end,
        reason = "checksum mismatch",
      },
      {
        name = "offsets",
        make = function()
          return make_cold(function()
            return 7
          end)
        end,
        decode = function(body)
          return "\1" .. body:sub(2)
        end,
        crc32 = function()
          return 7
        end,
        reason = "offsets are invalid",
      },
    }

    for _, case in ipairs(cases) do
      local page, body = case.make()
      local before = page:encoded()
      local calls = 0
      local options = {
        codec = TEST_CODEC,
        decode = function()
          calls = calls + 1
          return case.decode(body)
        end,
        crc32 = case.crc32,
      }
      local view, err = Page.read_view(page, 1, options)
      H.eq(view, nil, case.name)
      assert(err:find(case.reason, 1, true), err)
      H.eq(calls, 1, case.name)
      H.eq(Page.revision(page), 1, case.name)
      H.eq(page:encoded(), before, case.name)
      H.eq(Page.metadata(page).quarantined, true, case.name)
      H.eq(Page.validate(page), true, case.name)

      view, err = Page.read_view(page, 1, options)
      H.eq(view, nil, case.name)
      assert(err:find("quarantined", 1, true), err)
      H.eq(calls, 1, case.name .. " must not decode twice")
      local row, row_err = Page.row(page, 1)
      H.eq(row, nil)
      assert(row_err:find("quarantined", 1, true), row_err)
    end
  end

T["page_ restore callback mutations and reentry cannot publish a view"] =
  function()
    local page = Page.new({ "callback-callback", "omega" })
    local body
    local candidate = assert(Page.prepare_cold(page, 0, {
      codec = TEST_CODEC,
      encode = function(raw)
        body = raw
        return "\4"
      end,
      crc32 = test_crc32,
    }))
    assert(Page.publish_cold(page, candidate, 0))
    local encoded = page:encoded()

    local view, err = Page.read_view(page, 1, {
      codec = TEST_CODEC,
      decode = function()
        page.payload = "public mutation"
        return body
      end,
      crc32 = test_crc32,
    })
    H.eq(view, nil)
    assert(err:find("changed during cold restore", 1, true), err)
    H.eq(Page.metadata(page).quarantined, false)
    H.eq(Page.revision(page), 1)
    page.payload = encoded.payload
    H.eq(Page.validate(page), true)

    view, err = Page.read_view(page, 1, {
      codec = TEST_CODEC,
      decode = function()
        return body
      end,
      crc32 = function(raw)
        page.read_view = function()
          return nil
        end
        return test_crc32(raw)
      end,
    })
    H.eq(view, nil)
    assert(err:find("changed during cold restore", 1, true), err)
    H.eq(Page.metadata(page).quarantined, false)
    page.read_view = nil
    H.eq(Page.validate(page), true)

    local prior_view = assert(Page.read_view(page, 1, {
      codec = TEST_CODEC,
      decode = function()
        return body
      end,
      crc32 = test_crc32,
    }))
    H.eq(Page.view_row(prior_view, 1), "callback-callback")

    local outer_crc_calls = 0
    view, err = Page.read_view(page, 1, {
      codec = TEST_CODEC,
      decode = function()
        local inner, inner_err = Page.read_view(page, 1, {
          codec = TEST_CODEC,
          decode = function()
            return nil
          end,
          crc32 = test_crc32,
        })
        H.eq(inner, nil)
        assert(inner_err:find("decode failed", 1, true), inner_err)
        return body
      end,
      crc32 = function(raw)
        outer_crc_calls = outer_crc_calls + 1
        return test_crc32(raw)
      end,
    })
    H.eq(view, nil)
    assert(err:find("quarantined", 1, true), err)
    H.eq(outer_crc_calls, 0)
    H.eq(Page.metadata(page).quarantined, true)
    local stale_row, stale_err = Page.view_row(prior_view, 1)
    H.eq(stale_row, nil)
    assert(stale_err:find("no longer valid", 1, true), stale_err)
    H.eq(Page.view_metadata(prior_view), nil)
  end

T["page_ claimed representation operations require the exact private cap"] =
  function()
    local ffi = require("ffi")
    ffi.cdef([[
      typedef struct {
        int value;
      } canvasdiff_page_capability_probe;
    ]])
    local equality_calls = 0
    local Probe = ffi.metatype("canvasdiff_page_capability_probe", {
      __eq = function()
        equality_calls = equality_calls + 1
        return true
      end,
    })
    local cdata_cap = Probe(0)

    local revoking = Page.new({ "preclaim-preclaim-preclaim" })
    local preclaim_view = assert(Page.read_view(revoking, 0))
    local preclaim_candidate = assert(Page.prepare_cold(revoking, 0, {
      codec = TEST_CODEC,
      encode = function()
        return "\1"
      end,
      crc32 = test_crc32,
    }))
    assert(Page.claim(revoking, {}))
    H.eq(Page.view_row(preclaim_view, 1), nil)
    H.eq(Page.candidate_metadata(preclaim_candidate), nil)

    local page = Page.new({ "claimed-claimed", "omega" })
    local node = {}
    local claimed, capability = Page.claim(page, node)
    H.eq(claimed, true)
    H.eq(getmetatable(capability), false)
    H.eq(next(capability), nil)
    H.eq(Page.is_authorized(page, node, capability), true)
    H.eq(Page.is_owned_by(nil, nil), false)
    H.eq(Page.is_owned_by({}, {}), false)
    H.eq(Page.is_authorized(nil, nil, nil), nil)
    H.eq(Page.is_authorized({}, {}, nil), nil)
    local self_owned = Page.new({ string.rep("x", 1024) })
    local self_claimed, self_claim_err = Page.claim(self_owned, self_owned)
    H.eq(self_claimed, nil)
    assert(self_claim_err:find("cannot own itself", 1, true),
      self_claim_err)
    local abandoned = setmetatable({}, { __mode = "k" })
    do
      local abandoned_page = Page.new({ string.rep("z", 1024) })
      local abandoned_node = {}
      abandoned_page.owner = abandoned_node
      assert(Page.claim(abandoned_page, abandoned_node))
      abandoned[abandoned_page] = true
      abandoned[abandoned_node] = true
    end
    for _ = 1, 3 do
      collectgarbage("collect")
    end
    H.eq(next(abandoned), nil,
      "weak ownership indexes must not close a hostile back-reference cycle")
    H.eq(Page.is_authorized(page, {}, capability), nil)
    H.eq(Page.is_authorized(page, node), nil)
    H.eq(Page.is_authorized(page, node, cdata_cap), nil)
    H.eq(equality_calls, 0)
    local body
    local encode_calls = 0
    local options = {
      codec = TEST_CODEC,
      encode = function(raw)
        encode_calls = encode_calls + 1
        body = raw
        return "\5"
      end,
      crc32 = test_crc32,
    }

    local missing, missing_err = Page.prepare_cold(page, 0, options)
    H.eq(missing, nil)
    assert(missing_err:find("capability", 1, true), missing_err)
    for _, wrong in ipairs({ false, {}, cdata_cap }) do
      local candidate, err =
        Page.prepare_cold(page, 0, options, wrong)
      H.eq(candidate, nil)
      assert(err:find("capability", 1, true), err)
    end
    H.eq(encode_calls, 0)
    H.eq(equality_calls, 0)

    local candidate = assert(Page.prepare_cold(
      page,
      0,
      options,
      capability
    ))
    H.eq(encode_calls, 1)
    local missing_publish, missing_publish_err =
      Page.publish_cold(page, candidate, 0)
    H.eq(missing_publish, nil)
    assert(missing_publish_err:find("capability", 1, true),
      missing_publish_err)
    for _, wrong in ipairs({ false, {}, cdata_cap }) do
      local published, err =
        Page.publish_cold(page, candidate, 0, wrong)
      H.eq(published, nil)
      assert(err:find("capability", 1, true), err)
      H.eq(Page.revision(page), 0)
    end
    H.eq(equality_calls, 0)
    H.eq(Page.publish_cold(page, candidate, 0, capability), true)

    local decode_calls = 0
    local restore_options = {
      codec = TEST_CODEC,
      decode = function()
        decode_calls = decode_calls + 1
        return body
      end,
      crc32 = test_crc32,
    }
    local missing_view, missing_view_err =
      Page.read_view(page, 1, restore_options)
    H.eq(missing_view, nil)
    assert(missing_view_err:find("capability", 1, true), missing_view_err)
    for _, wrong in ipairs({ false, {}, cdata_cap }) do
      local view, err = Page.read_view(page, 1, restore_options, wrong)
      H.eq(view, nil)
      assert(err:find("capability", 1, true), err)
    end
    H.eq(decode_calls, 0)
    H.eq(equality_calls, 0)
    H.eq(Page.view_rows(assert(Page.read_view(
      page,
      1,
      restore_options,
      capability
    ))), { "claimed-claimed", "omega" })
    H.eq(decode_calls, 1)
    H.eq(rawget(Page.metadata(page), "capability"), nil)
    H.eq(rawget(Page.encoded(page), "capability"), nil)
  end

return T
