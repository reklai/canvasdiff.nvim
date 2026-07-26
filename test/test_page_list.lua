local H = require("helpers")
local Page = require("canvasdiff.canvas.Page")
local PageList = require("canvasdiff.canvas.PageList")

local T = {}

local function test_crc32(raw)
  local checksum = 0
  for index = 1, #raw do
    checksum = (checksum + string.byte(raw, index) * index) % 4294967296
  end
  return checksum
end

local function test_resident_adapter(overrides)
  overrides = overrides or {}
  local bodies = {}
  local next_block = 0
  return {
    codec = "page-list-test-v1",
    encode = overrides.encode or function(body)
      next_block = next_block + 1
      local block = string.char(next_block)
      bodies[block] = body
      return block
    end,
    decode = overrides.decode or function(block)
      return bodies[block]
    end,
    crc32 = overrides.crc32 or test_crc32,
  }
end

local function load_isolated_pagelist(page_overrides)
  local module_name = "canvasdiff.canvas.PageList"
  local prior_module = package.loaded[module_name]
  local originals = {}
  for name, replacement in pairs(page_overrides) do
    originals[name] = Page[name]
    Page[name] = replacement
  end
  package.loaded[module_name] = nil
  local called, isolated = pcall(require, module_name)
  package.loaded[module_name] = prior_module
  for name, original in pairs(originals) do
    Page[name] = original
  end
  assert(called, isolated)
  return isolated
end

local function page_rows(list, page_index0)
  local node = assert(list:page_at(page_index0))
  return assert(node.page:rows())
end

local function list_nodes(list)
  local nodes = {}
  for page_index0 = 0, list:page_count() - 1 do
    nodes[#nodes + 1] = assert(list:page_at(page_index0))
  end
  return nodes
end

local function oracle_splice(rows, start0, delete_count, insert_rows)
  local result = {}
  for index = 1, start0 do
    result[#result + 1] = rows[index]
  end
  for index = 1, #insert_rows do
    result[#result + 1] = insert_rows[index]
  end
  for index = start0 + delete_count + 1, #rows do
    result[#result + 1] = rows[index]
  end
  return result
end

T["page_list_ loads without an editor runtime"] = function()
  local root = vim.fs.dirname(vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
  local chunk = assert(loadfile(
    vim.fs.joinpath(root, "lua", "canvasdiff", "canvas", "PageList.lua")
  ))
  local runtime = _G.vim
  _G.vim = nil
  local ok, loaded = pcall(chunk)
  _G.vim = runtime
  assert(ok, loaded)
  H.eq(type(loaded.new), "function")
  H.eq(type(loaded.from_iterator), "function")
  H.eq(type(loaded.splice), "function")
  H.eq(type(loaded.compact_page), "function")
  H.eq(loaded.DEFAULT_RESIDENT_MAX_PAGES, 8)
  H.eq(loaded.DEFAULT_RESIDENT_MAX_BYTES, 532512)
end

T["page_list_ empty input owns no phantom page"] = function()
  local list = PageList.new({})
  H.eq(list:stats(), {
    generation = 0,
    row_count = 0,
    page_count = 0,
    active_leases = 0,
    pin_references = 0,
    current_pinned_pages = 0,
    retired_pinned_pages = 0,
    decoded_bytes = 0,
    storage_bytes = 0,
    oversized_pages = 0,
    max_rows = 256,
    max_bytes = 65536,
  })
  H.eq(list:row_count(), 0)
  H.eq(list:page_count(), 0)
  H.eq(list:rows(0, 0), {})
  H.eq(list:row(0), nil)
  H.eq(list:locate(0), nil)
  H.eq(list:page_at(0), nil)
  H.eq(PageList.validate(list), true)
end

T["page_list_ row target splits at 256 with stable monotonic ids"] = function()
  local rows = {}
  for index = 1, 257 do
    rows[index] = "row-" .. index
  end
  local list = PageList.new(rows)

  H.eq(list:page_count(), 2)
  H.eq(assert(list:page_at(0)).id, 1)
  H.eq(assert(list:page_at(1)).id, 2)
  H.eq(assert(list:page_at(0)).page.row_count, 256)
  H.eq(assert(list:page_at(1)).page.row_count, 1)

  local first, first_local, first_page = list:locate(0)
  H.eq({ first.id, first_local, first_page }, { 1, 0, 0 })
  local boundary, boundary_local, boundary_page = list:locate(256)
  H.eq({ boundary.id, boundary_local, boundary_page }, { 2, 0, 1 })
  H.eq(list:row(255), "row-256")
  H.eq(list:row(256), "row-257")
  H.eq(PageList.validate(list), true)
end

T["page_list_ page inspection returns detached scalar snapshots"] =
  function()
    local list = PageList.new({
      "a",
      "bb",
      "ccc",
      "dddd",
      "",
    }, {
      max_rows = 2,
      max_bytes = 16,
    })
    local lease = assert(list:pin_range(2, 1, 0))
    local snapshot = assert(list:inspect_page(1, 0))
    H.eq(snapshot.generation, 0)
    H.eq(snapshot.page_index, 1)
    H.eq(snapshot.id, 2)
    H.eq(snapshot.created_generation, 0)
    H.eq(snapshot.start0, 2)
    H.eq(snapshot.end0, 4)
    H.eq(snapshot.row_count, 2)
    H.eq(snapshot.kind, "raw")
    H.eq(snapshot.codec, "raw")
    H.eq(snapshot.revision, 0)
    H.eq(snapshot.decoded_bytes, 7)
    H.eq(snapshot.max_rows, 2)
    H.eq(snapshot.max_bytes, 16)
    H.eq(snapshot.oversized, false)
    H.eq(snapshot.view_bytes, 0)
    H.eq(snapshot.quarantined, false)
    H.eq(snapshot.pin_count, 1)

    local scalar_types = {
      boolean = true,
      number = true,
      string = true,
    }
    for key, value in pairs(snapshot) do
      H.eq(type(key), "string")
      assert(scalar_types[type(value)],
        key .. " escaped a " .. type(value))
    end
    for _, forbidden in ipairs({
      "node",
      "page",
      "capability",
      "payload",
      "offsets",
    }) do
      H.eq(rawget(snapshot, forbidden), nil)
    end

    local pristine = assert(list:inspect_page(1, 0))
    snapshot.id = -1
    snapshot.start0 = 999
    snapshot.pin_count = 999
    snapshot.page = assert(list:page_at(0)).page
    snapshot.offsets = {}
    setmetatable(snapshot, {
      __index = function()
        return "forged"
      end,
      __newindex = function()
        error("snapshot is hostile", 0)
      end,
    })

    H.eq(list:inspect_page(1, 0), pristine)
    H.eq(list:rows(0, 5), { "a", "bb", "ccc", "dddd", "" })
    H.eq(PageList.validate(list), true)
    H.eq(list:release_pin(lease), true)
    H.eq(assert(list:inspect_page(1, 0)).pin_count, 0)
  end

T["page_list_ locate_page returns exact detached page ranges"] = function()
  local rows = {
    "a",
    "bb",
    "ccc",
    "dddd",
    "eeeee",
    "ffffff",
    "ggggggg",
  }
  local list = PageList.new(rows, { max_rows = 2, max_bytes = 32 })

  for row0 = 0, #rows - 1 do
    local snapshot, local_row0 = assert(list:locate_page(row0, 0))
    local expected_page0 = math.floor(row0 / 2)
    H.eq(snapshot.page_index, expected_page0)
    H.eq(local_row0, row0 % 2)
    H.eq(snapshot.start0 + local_row0, row0)
    assert(row0 < snapshot.end0)
    H.eq(snapshot, list:inspect_page(expected_page0, 0))
    H.eq(list:row(row0), rows[row0 + 1])
  end

  local snapshot, err = list:locate_page(-1, 0)
  H.eq(snapshot, nil)
  assert(err:find("outside the list", 1, true), err)
  snapshot, err = list:locate_page(#rows, 0)
  H.eq(snapshot, nil)
  assert(err:find("outside the list", 1, true), err)
  H.eq(PageList.new({}):locate_page(0, 0), nil)
  H.eq(PageList.validate(list), true)
end

T["page_list_ inspection generations fence before Page metadata"] =
  function()
    local metadata_calls = 0
    local original_metadata = Page.metadata
    local Isolated = load_isolated_pagelist({
      metadata = function(...)
        metadata_calls = metadata_calls + 1
        return original_metadata(...)
      end,
    })
    local list = Isolated.new({ "a", "b" }, { max_rows = 1 })
    metadata_calls = 0

    local invalid_generations = {
      -1,
      0.5,
      math.huge,
      "0",
    }
    for _, expected_generation in ipairs(invalid_generations) do
      local snapshot, err =
        list:inspect_page(0, expected_generation)
      H.eq(snapshot, nil)
      assert(err:find("expected generation", 1, true), err)
      snapshot, err = list:locate_page(0, expected_generation)
      H.eq(snapshot, nil)
      assert(err:find("expected generation", 1, true), err)
    end
    H.eq(metadata_calls, 0)

    local snapshot, err = list:inspect_page(99, 1)
    H.eq(snapshot, nil)
    assert(err:find("generation changed", 1, true), err)
    snapshot, err = list:locate_page(99, 1)
    H.eq(snapshot, nil)
    assert(err:find("generation changed", 1, true), err)
    H.eq(metadata_calls, 0,
      "stale generations must fence before Page metadata")

    snapshot = assert(list:inspect_page(0, 0))
    H.eq(snapshot.generation, 0)
    H.eq(metadata_calls, 1)
    metadata_calls = 0
    snapshot = assert(list:locate_page(0, 0))
    H.eq(snapshot.page_index, 0)
    H.eq(metadata_calls, 1)

    assert(list:splice(0, 0, { "new" }))
    metadata_calls = 0
    snapshot, err = list:inspect_page(0, 0)
    H.eq(snapshot, nil)
    assert(err:find("generation changed", 1, true), err)
    snapshot, err = list:locate_page(0, 0)
    H.eq(snapshot, nil)
    assert(err:find("generation changed", 1, true), err)
    H.eq(metadata_calls, 0)
    H.eq(Isolated.validate(list), true)
  end

T["page_list_ byte target is greedy at exact and over boundaries"] = function()
  local almost = string.rep("a", 65535)
  local list = PageList.new({ almost, "", "b", "c" })

  H.eq(list:page_count(), 2)
  H.eq(page_rows(list, 0), { almost, "", "b" })
  H.eq(page_rows(list, 1), { "c" })
  H.eq(assert(list:page_at(0)).page.decoded_bytes, 65536)
  H.eq(assert(list:page_at(0)).page.offset_width, 4)

  local exact = PageList.new({ string.rep("x", 65536), "" })
  H.eq(exact:page_count(), 1)
  H.eq(assert(exact:page_at(0)).page.row_count, 2)
  H.eq(exact:rows(0, 2), { string.rep("x", 65536), "" })

  local split = PageList.new({ string.rep("x", 40000), string.rep("y", 30000) })
  H.eq(split:page_count(), 2)
  H.eq(assert(split:page_at(0)).page.decoded_bytes, 40000)
  H.eq(assert(split:page_at(1)).page.decoded_bytes, 30000)
end

T["page_list_ oversized rows are isolated singleton pages"] = function()
  local huge = string.rep("h", 65537)
  local list = PageList.new({ "before", huge, "", "after" })

  H.eq(list:page_count(), 3)
  H.eq(page_rows(list, 0), { "before" })
  H.eq(page_rows(list, 1), { huge })
  H.eq(page_rows(list, 2), { "", "after" })
  H.eq(assert(list:page_at(1)).page.oversized, true)
  H.eq(list:stats().oversized_pages, 1)
  H.eq(list:rows(0, 4), { "before", huge, "", "after" })
  H.eq(PageList.validate(list), true)
end

T["page_list_ preserves empty rows and arbitrary non-LF bytes"] = function()
  local rows = {
    "",
    "nul\0byte",
    string.char(0xFF, 0xFE, 0x80),
    "carriage\rreturn",
    "終わり",
    "",
  }
  local list = PageList.new(rows, { max_rows = 2, max_bytes = 32 })

  H.eq(list:page_count(), 3)
  H.eq(list:rows(0, #rows), rows)
  for row0 = 0, #rows - 1 do
    H.eq(list:row(row0), rows[row0 + 1])
  end
  H.eq(PageList.validate(list), true)
end

T["page_list_ half-open ranges cross page boundaries exactly"] = function()
  local rows = { "a", "b", "c", "d", "e", "f", "g" }
  local list = PageList.new(rows, { max_rows = 3, max_bytes = 16 })

  H.eq(list:rows(0, 7), rows)
  H.eq(list:rows(2, 4), { "c", "d", "e", "f" })
  H.eq(list:rows(3, 3), { "d", "e", "f" })
  H.eq(list:rows(7, 0), {})
  H.eq(list:rows(0, 0), {})

  for _, args in ipairs({
    { -1, 0 },
    { 0, -1 },
    { 8, 0 },
    { 6, 2 },
    { 0.5, 1 },
    { 0, math.huge },
  }) do
    local result, err = list:rows(args[1], args[2])
    H.eq(result, nil)
    assert(type(err) == "string")
  end
  H.eq(list:row(-1), nil)
  H.eq(list:row(7), nil)
  H.eq(list:locate(0.5), nil)
  H.eq(list:page_at(-1), nil)
  H.eq(list:page_at(3), nil)
end

T["page_list_ rejects malformed sequences rows and options explicitly"] = function()
  local cases = {
    { false, nil, "sequence" },
    { { [1] = "a", [3] = "c" }, nil, "dense" },
    { { [0] = "a" }, nil, "positive integer" },
    { { "a", false }, nil, "row 2" },
    { { "a\nb" }, nil, "line%-feed" },
    { { "a" }, false, "options" },
    { { "a" }, { max_rows = false }, "max_rows" },
    { { "a" }, { max_bytes = false }, "max_bytes" },
    { { "a" }, { max_rows = math.huge }, "max_rows" },
    { { "a" }, { max_bytes = math.huge }, "max_bytes" },
  }

  for _, case in ipairs(cases) do
    local list, err = PageList.create(case[1], case[2])
    H.eq(list, nil)
    assert(type(err) == "string" and err:match(case[3]), tostring(err))
  end

  local synthetic = setmetatable({ [2] = "real" }, {
    __index = function()
      return "synthetic"
    end,
  })
  H.eq(PageList.create(synthetic), nil, "metatable rows do not fill sequence holes")
end

T["page_list_ binary lookup and range reads match a large oracle"] = function()
  local rows = {}
  for index = 1, 4097 do
    if index % 17 == 0 then
      rows[index] = ""
    elseif index % 23 == 0 then
      rows[index] = string.char(0xFF) .. tostring(index)
    else
      rows[index] = ("row-%04d"):format(index)
    end
  end
  local list = PageList.new(rows, { max_rows = 3, max_bytes = 24 })

  for row0 = 0, #rows - 1 do
    H.eq(list:row(row0), rows[row0 + 1], "row oracle at " .. row0)
  end
  for start0 = 0, #rows, 97 do
    local count = math.min(113, #rows - start0)
    local expected = {}
    for index = start0 + 1, start0 + count do
      expected[#expected + 1] = rows[index]
    end
    H.eq(list:rows(start0, count), expected, "range oracle at " .. start0)
  end

  local last_id = 0
  for page_index0 = 0, list:page_count() - 1 do
    local node = assert(list:page_at(page_index0))
    assert(node.id > last_id, "construction IDs must be monotonic")
    last_id = node.id
  end
  H.eq(PageList.validate(list), true)
end

T["page_list_ does not retain input rows and stats are snapshots"] = function()
  local rows = { "one", "two", "three" }
  local list = PageList.new(rows, { max_rows = 2 })
  rows[1] = "changed"
  rows[4] = "late"
  H.eq(list:rows(0, 3), { "one", "two", "three" })

  local stats = list:stats()
  stats.row_count = 999
  H.eq(list:row_count(), 3)
  H.eq(PageList.validate(list), true)
end

T["page_list_ splice no-ops and invalid requests are atomic"] = function()
  local list = PageList.new({ "a", "b", "c", "d" }, {
    max_rows = 2,
    max_bytes = 8,
  })
  local pages = list._pages
  local starts = list._starts
  local nodes = list_nodes(list)
  local stats = list:stats()
  local next_page_id = list._next_page_id

  H.eq(list:splice(2, 0, {}), true)
  H.eq(list:generation(), 0)
  assert(list._pages == pages)
  assert(list._starts == starts)

  local invalid_calls = {
    function() return list:splice(-1, 0, {}) end,
    function() return list:splice(0.5, 0, {}) end,
    function() return list:splice(5, 0, {}) end,
    function() return list:splice(3, 2, {}) end,
    function() return list:splice(0, -1, {}) end,
    function() return list:splice(0, math.huge, {}) end,
    function() return list:splice(0, 0, false) end,
    function() return list:splice(0, 0, { [2] = "hole" }) end,
    function() return list:splice(0, 0, { "valid", false }) end,
    function() return list:splice(0, 0, { "has\nlf" }) end,
  }
  for index, call in ipairs(invalid_calls) do
    local result, err = call()
    H.eq(result, nil, "invalid splice " .. index)
    assert(type(err) == "string", "invalid splice must return an error")
    H.eq(list:stats(), stats)
    H.eq(list._next_page_id, next_page_id)
    assert(list._pages == pages)
    assert(list._starts == starts)
    for node_index, node in ipairs(nodes) do
      assert(list._pages[node_index] == node)
    end
  end

  local insert_rows = {}
  for index = 1, 513 do
    insert_rows[index] = "row-" .. index
  end
  insert_rows[514] = false
  local original = Page.create
  local allocations = 0
  Page.create = function(...)
    allocations = allocations + 1
    return original(...)
  end
  local called, result, err = pcall(list.splice, list, 0, 0, insert_rows)
  Page.create = original

  assert(called, result)
  H.eq(result, nil)
  assert(err:match("row 514"), err)
  H.eq(allocations, 0,
    "insert rows must be completely preflighted before Page allocation")
  H.eq(list:stats(), stats)
  H.eq(list._next_page_id, next_page_id)
  assert(list._pages == pages)
  assert(list._starts == starts)
end

T["page_list_ every requested splice advances one generation"] = function()
  local list = PageList.new({ "a", "b", "c", "d" }, {
    max_rows = 2,
    max_bytes = 8,
  })
  local first = assert(list:page_at(0))
  local second = assert(list:page_at(1))
  H.eq(list:generation(), 0)
  H.eq(first.created_generation, 0)
  H.eq(second.created_generation, 0)

  H.eq(list:splice(1, 1, { "b" }), true)
  H.eq(list:generation(), 1)
  H.eq(list:stats().generation, 1)
  H.eq(list:rows(0, 4), { "a", "b", "c", "d" })
  assert(assert(list:page_at(list:page_count() - 1)) == second,
    "a byte-identical request is still a mutation, but untouched pages survive")
  assert(assert(list:page_at(0)) ~= first)
  H.eq(assert(list:page_at(0)).created_generation, 1)

  H.eq(list:splice(4, 0, { "" }), true)
  H.eq(list:generation(), 2)

  H.eq(list:splice(4, 1, {}), true)
  H.eq(list:generation(), 3)

  H.eq(list:splice(4, 0, {}), true)
  H.eq(list:generation(), 3)
  H.eq(PageList.validate(list), true)
end

T["page_list_ splice preserves identities outside exact touched pages"] = function()
  local list = PageList.new({ "a", "b", "c", "d", "e", "f" }, {
    max_rows = 2,
    max_bytes = 32,
  })
  local first = assert(list:page_at(0))
  local second = assert(list:page_at(1))
  local third = assert(list:page_at(2))

  H.eq(list:splice(2, 0, { "x" }), true)
  H.eq(list:rows(0, 7), { "a", "b", "x", "c", "d", "e", "f" })
  assert(assert(list:page_at(0)) == first)
  assert(assert(list:page_at(2)) == second)
  assert(assert(list:page_at(3)) == third)
  local inserted = assert(list:page_at(1))
  assert(inserted.id > third.id)
  H.eq(inserted.created_generation, 1)

  H.eq(list:splice(4, 0, { "y" }), true)
  H.eq(list:rows(0, 8), { "a", "b", "x", "c", "y", "d", "e", "f" })
  assert(assert(list:page_at(0)) == first)
  assert(assert(list:page_at(1)) == inserted)
  assert(assert(list:page_at(list:page_count() - 1)) == third)
  for page_index0 = 2, list:page_count() - 2 do
    assert(assert(list:page_at(page_index0)).id > inserted.id)
  end
  H.eq(PageList.validate(list), true)

  local exact = PageList.new({ "a", "b", "c", "d", "e", "f" }, {
    max_rows = 2,
    max_bytes = 32,
  })
  local exact_first = assert(exact:page_at(0))
  local exact_middle = assert(exact:page_at(1))
  local exact_last = assert(exact:page_at(2))
  H.eq(exact:splice(2, 2, {}), true)
  H.eq(exact:rows(0, 4), { "a", "b", "e", "f" })
  assert(exact_middle ~= assert(exact:page_at(0)))
  assert(exact_middle ~= assert(exact:page_at(1)))
  assert(assert(exact:page_at(0)) == exact_first)
  assert(assert(exact:page_at(1)) == exact_last)
  H.eq(PageList.validate(exact), true)
end

T["page_list_ splice handles empty transitions caps and non-reused ids"] = function()
  local list = PageList.new({}, { max_rows = 2, max_bytes = 3 })
  H.eq(list:generation(), 0)

  local huge = string.rep("h", 4)
  assert(list:splice(0, 0, { "a", "", huge }))
  H.eq(list:generation(), 1)
  H.eq(list:rows(0, 3), { "a", "", huge })
  H.eq(list:page_count(), 2)
  H.eq(list:stats().oversized_pages, 1)
  local old_nodes = list_nodes(list)
  H.eq(old_nodes[1].created_generation, 1)
  H.eq(old_nodes[2].created_generation, 1)
  local greatest_old_id = math.max(old_nodes[1].id, old_nodes[2].id)

  assert(list:splice(0, 3, {}))
  H.eq(list:generation(), 2)
  H.eq(list:row_count(), 0)
  H.eq(list:page_count(), 0)
  H.eq(list:rows(0, 0), {})
  H.eq(list:stats().oversized_pages, 0)

  assert(list:splice(0, 0, { "again" }))
  H.eq(list:generation(), 3)
  local new_node = assert(list:page_at(0))
  assert(new_node.id > greatest_old_id, "deleted page ids must never be reused")
  H.eq(new_node.created_generation, 3)
  H.eq(new_node.page.oversized, true)
  H.eq(PageList.validate(list), true)
end

T["page_list_ Page creation failure leaves a splice wholly unpublished"] = function()
  local list = PageList.new({ "a", "b", "c", "d" }, {
    max_rows = 2,
    max_bytes = 8,
  })
  local pages = list._pages
  local starts = list._starts
  local nodes = list_nodes(list)
  local lease = assert(list:pin_range(2, 1))
  local stats = list:stats()
  local next_page_id = list._next_page_id

  local original = Page.create
  local calls = 0
  Page.create = function(...)
    calls = calls + 1
    if calls == 2 then
      return nil, "injected page failure"
    end
    return original(...)
  end
  local called, change, err = pcall(
    list.splice,
    list,
    2,
    0,
    { "u", "v", "w", "x", "y" }
  )
  Page.create = original

  assert(called, change)
  H.eq(change, nil)
  H.eq(err, "injected page failure")
  H.eq(calls, 2)
  H.eq(list:stats(), stats)
  H.eq(list._next_page_id, next_page_id)
  assert(list._pages == pages)
  assert(list._starts == starts)
  for index, node in ipairs(nodes) do
    assert(list._pages[index] == node)
  end
  H.eq(list:pin_is_current(lease), true)
  H.eq(list:pin_count(nodes[2]), 1)
  H.eq(PageList.validate(list), true)

  Page.create = function()
    error("injected page throw", 0)
  end
  called, change, err = pcall(list.splice, list, 2, 0, { "z" })
  Page.create = original

  assert(called, change)
  H.eq(change, nil)
  assert(err:match("page creation threw"), err)
  assert(err:match("injected page throw"), err)
  H.eq(list:stats(), stats)
  H.eq(list._next_page_id, next_page_id)
  assert(list._pages == pages)
  assert(list._starts == starts)
  for index, node in ipairs(nodes) do
    assert(list._pages[index] == node)
  end
  H.eq(list:pin_is_current(lease), true)
  H.eq(list:pin_count(nodes[2]), 1)
  H.eq(list:release_pin(lease), true)
  H.eq(PageList.validate(list), true)
end

T["page_list_ Page creation hostile successes cannot change requested rows"] = function()
  local original = Page.create

  local function exercise(replacement, start0, insert_rows, expected_error)
    local list = PageList.new({ "a", "b" }, { max_rows = 2, max_bytes = 8 })
    local pages = list._pages
    local starts = list._starts
    local nodes = list_nodes(list)
    local stats = list:stats()
    local next_page_id = list._next_page_id

    Page.create = function(rows, opts)
      return replacement(list, rows, opts, original)
    end
    local called, change, err = pcall(
      PageList.splice,
      list,
      start0,
      0,
      insert_rows
    )
    Page.create = original

    assert(called, change)
    H.eq(change, nil)
    assert(err:match(expected_error), err)
    H.eq(list:stats(), stats)
    H.eq(list._next_page_id, next_page_id)
    assert(list._pages == pages)
    assert(list._starts == starts)
    for index, node in ipairs(nodes) do
      assert(list._pages[index] == node)
    end
    H.eq(rawget(list, "_splice_active"), nil)
    H.eq(list:rows(0, 2), { "a", "b" })
    H.eq(PageList.validate(list), true)
  end

  exercise(function(_, _, opts, create)
    return create({ "EVIL" }, opts)
  end, 1, { "wanted" }, "different rows")

  exercise(function(_, rows, opts, create)
    rows[1] = "Q"
    return create(rows, opts)
  end, 1, { "wanted" }, "changed row 1")

  exercise(function(list)
    return assert(list:page_at(0)).page
  end, 0, { "a", "b" }, "fresh Page")

  exercise(function(_, rows, opts, create)
    local page = assert(create(rows, opts))
    local fake = page:encoded()
    setmetatable(fake, {
      __metatable = Page,
      __index = Page,
    })
    assert(getmetatable(fake) == Page)
    return fake
  end, 1, { "wanted" }, "not an owned Page")
end

T["page_list_ Page creation rejects cross-list and historical aliases"] = function()
  local original = Page.create
  local owner = PageList.new({ "same" })
  local borrowed = assert(owner:page_at(0)).page
  local target = PageList.new({})

  Page.create = function()
    return borrowed
  end
  local called, change, err = pcall(
    PageList.splice,
    target,
    0,
    0,
    { "same" }
  )
  Page.create = original

  assert(called, change)
  H.eq(change, nil)
  assert(err:match("fresh Page"), err)
  H.eq(target:rows(0, 0), {})
  H.eq(owner:rows(0, 1), { "same" })
  H.eq(PageList.validate(target), true)
  H.eq(PageList.validate(owner), true)

  local list = PageList.new({ "a", "b" }, { max_rows = 2 })
  local historical = assert(list:page_at(0)).page
  local pages = list._pages
  local starts = list._starts
  local stats = list:stats()

  Page.create = function()
    return historical
  end
  called, change, err = pcall(
    PageList.splice,
    list,
    0,
    2,
    { "a", "b" }
  )
  Page.create = original

  assert(called, change)
  H.eq(change, nil)
  assert(err:match("fresh Page"), err)
  assert(list._pages == pages)
  assert(list._starts == starts)
  H.eq(list:stats(), stats)
  H.eq(list:rows(0, 2), { "a", "b" })
  H.eq(rawget(list, "_splice_active"), nil)
  H.eq(PageList.validate(list), true)

  local nested_owner = PageList.new({})
  local nested_target = PageList.new({})
  local recursing = false
  Page.create = function(rows, opts)
    if recursing then
      return original(rows, opts)
    end
    recursing = true
    local nested_change, nested_err =
      nested_owner:splice(0, 0, { rows[1] })
    recursing = false
    assert(nested_change, nested_err)
    return assert(nested_owner:page_at(0)).page
  end
  called, change, err = pcall(
    PageList.splice,
    nested_target,
    0,
    0,
    { "nested" }
  )
  Page.create = original

  assert(called, change)
  H.eq(change, nil)
  assert(err:match("already claimed"), err)
  H.eq(nested_target:rows(0, 0), {})
  H.eq(nested_owner:rows(0, 1), { "nested" })
  H.eq(rawget(nested_target, "_splice_active"), nil)
  H.eq(rawget(nested_owner, "_splice_active"), nil)
  H.eq(PageList.validate(nested_target), true)
  H.eq(PageList.validate(nested_owner), true)
end

T["page_list_ build rejects mutation of a previously returned Page"] = function()
  local source = { "a", "b" }
  local original = Page.create
  local previous

  Page.create = function(...)
    if previous then
      previous.payload = "z"
    end
    local page, err = original(...)
    previous = page
    return page, err
  end
  local called, list, err = pcall(
    PageList.create,
    source,
    { max_rows = 1 }
  )
  Page.create = original

  assert(called, list)
  H.eq(list, nil)
  assert(err:match("mutated prior page 1 field payload"), err)
  H.eq(source, { "a", "b" })
end

T["page_list_ constructor checks capture trusted iteration"] = function()
  local original_create = Page.create
  local original_ipairs = _G.ipairs

  Page.create = function(_, opts)
    local page = assert(original_create({ "EVIL" }, opts))
    _G.ipairs = function()
      return function()
        return nil
      end
    end
    return page
  end
  local called, list, err = pcall(
    PageList.create,
    { "wanted" },
    { max_rows = 1 }
  )
  Page.create = original_create
  _G.ipairs = original_ipairs

  assert(called, list)
  H.eq(list, nil)
  assert(err:match("changed row 1"), err)
end

T["page_list_ splice restores direct source graph mutation by Page callbacks"] =
  function()
    local list = PageList.new({ "a", "b", "c" }, { max_rows = 1 })
    local original = Page.create
    local pages = list._pages
    local starts = list._starts
    local nodes = list_nodes(list)
    local stats = list:stats()
    local first_page = nodes[1].page
    local evil_page = Page.new({ "z" }, { max_rows = 1 })
    local original_eq = Page.__eq

    Page.create = function(...)
      Page.__eq = function()
        return true
      end
      list._pages[1], list._pages[3] = list._pages[3], list._pages[1]
      nodes[1].page = evil_page
      first_page.payload = "z"
      return original(...)
    end
    local called, change, err = pcall(
      PageList.splice,
      list,
      1,
      0,
      { "x" }
    )
    Page.create = original
    Page.__eq = original_eq

    assert(called, change)
    H.eq(change, nil)
    assert(err:match("mutated the source PageList"), err)
    assert(list._pages == pages)
    assert(list._starts == starts)
    for index, node in ipairs(nodes) do
      assert(list._pages[index] == node)
    end
    assert(nodes[1].page == first_page)
    H.eq(first_page.payload, "a")
    H.eq(list:stats(), stats)
    H.eq(list:rows(0, 3), { "a", "b", "c" })
    H.eq(rawget(list, "_splice_active"), nil)
    H.eq(PageList.validate(list), true)
  end

T["page_list_ splice rollback survives poisoned standard formatting"] =
  function()
    local list = PageList.new({ "a", "b", "c" }, { max_rows = 1 })
    local original_create = Page.create
    local original_format = string.format
    local pages = list._pages
    local starts = list._starts
    local nodes = list_nodes(list)
    local stats = list:stats()
    local first_candidate
    local calls = 0

    Page.create = function(rows, opts)
      calls = calls + 1
      local page = assert(original_create(rows, opts))
      if calls == 1 then
        first_candidate = page
      elseif calls == 2 then
        first_candidate.row = function()
          return "forged"
        end
        list._row_count = 999
        string.format = function()
          error("poisoned string.format", 0)
        end
      end
      return page
    end
    local called, change, err = pcall(
      PageList.splice,
      list,
      1,
      0,
      { "x", "y" }
    )
    Page.create = original_create
    string.format = original_format

    assert(called, change)
    H.eq(change, nil)
    assert(err:match("mutated the source PageList"), err)
    assert(calls >= 2)
    assert(list._pages == pages)
    assert(list._starts == starts)
    for index, node in ipairs(nodes) do
      assert(list._pages[index] == node)
    end
    H.eq(list:stats(), stats)
    H.eq(list:rows(0, 3), { "a", "b", "c" })
    H.eq(rawget(list, "_splice_active"), nil)
    H.eq(PageList.validate(list), true)
  end

T["page_list_ pin ranges count exact overlapping concrete pages"] = function()
  local list = PageList.new({
    "a", "b", "c", "d", "e", "f", "g", "h",
  }, { max_rows = 2 })
  local nodes = list_nodes(list)

  local wide = assert(list:pin_range(1, 4, 0))
  local narrow = assert(list:pin_range(2, 2, 0))
  local empty = assert(list:pin_range(8, 0, 0))

  H.eq(list:pin_count(nodes[1]), 1)
  H.eq(list:pin_count(nodes[2]), 2)
  H.eq(list:pin_count(nodes[3]), 1)
  H.eq(list:pin_count(nodes[4]), 0)
  H.eq(list:pin_stats(), {
    active_leases = 3,
    pin_references = 4,
    current_pinned_pages = 3,
    retired_pinned_pages = 0,
  })
  H.eq(list:pin_is_current(wide), true)
  H.eq(list:pin_is_current(narrow), true)
  H.eq(list:pin_is_current(empty), true)
  H.eq(PageList.validate(list), true)

  H.eq(list:release_pin(narrow), true)
  H.eq(list:pin_count(nodes[2]), 1)
  H.eq(list:release_pin(empty), true)
  H.eq(list:release_pin(wide), true)
  H.eq(list:pin_stats(), {
    active_leases = 0,
    pin_references = 0,
    current_pinned_pages = 0,
    retired_pinned_pages = 0,
  })
  H.eq(PageList.validate(list), true)
end

T["page_list_ pin acquisition is generation fenced and atomic"] = function()
  local list = PageList.new({ "a", "b", "c" }, { max_rows = 1 })
  local stats = list:pin_stats()

  local lease, err = list:pin_range(0, 1, 1)
  H.eq(lease, nil)
  assert(err:match("generation changed"), err)
  H.eq(list:pin_range(-1, 1), nil)
  H.eq(list:pin_range(3, 1), nil)
  H.eq(list:pin_range(0, 4), nil)
  H.eq(list:pin_range(0, 1, math.huge), nil)
  H.eq(list:pin_stats(), stats)

  local node = assert(list:page_at(2))
  lease = assert(list:pin_range(2, 1, list:generation()))
  H.eq(list:splice(0, 0, { "x" }), true)
  H.eq(list:pin_is_current(lease), false)
  H.eq(list:pin_count(node), 1)
  H.eq(list:pin_stats().retired_pinned_pages, 0)
  H.eq(list:pin_range(0, 1, 0), nil)
  H.eq(list:release_pin(lease), true)
  H.eq(PageList.validate(list), true)
end

T["page_list_ pin generation authorization is private"] = function()
  local list = PageList.new({ "a" }, { max_rows = 1 })
  H.eq(list:splice(1, 0, { "b" }), true)
  local lease = assert(list:pin_range(0, 1, 1))
  local stats = list:pin_stats()

  list._generation = 0
  local acquired, acquire_err = list:pin_range(0, 1, 0)
  H.eq(acquired, nil)
  assert(acquire_err:match("invalid metadata"), acquire_err)
  local current, current_err = list:pin_is_current(lease)
  H.eq(current, nil)
  assert(current_err:match("generation metadata is inconsistent"), current_err)
  H.eq(list:pin_stats(), stats)

  H.eq(list:release_pin(lease), true)
  H.eq(list:pin_stats(), {
    active_leases = 0,
    pin_references = 0,
    current_pinned_pages = 0,
    retired_pinned_pages = 0,
  })

  list._generation = 2
  local ok, validate_err = PageList.validate(list)
  H.eq(ok, nil)
  assert(validate_err:match("pin generation is inconsistent"), validate_err)

  list._generation = 1
  H.eq(PageList.validate(list), true)
end

T["page_list_ generation fences never invoke cdata equality"] = function()
  local ffi = require("ffi")
  ffi.cdef([[
    typedef struct {
      int value;
    } canvasdiff_pin_generation_probe;
  ]])

  local list = PageList.new({ "a" })
  local old = assert(list:pin_range(0, 1, 0))
  local stats = list:pin_stats()
  local calls = 0
  local Probe = ffi.metatype("canvasdiff_pin_generation_probe", {
    __eq = function()
      calls = calls + 1
      if calls == 2 then
        list._generation = 0
        assert(list:release_pin(old))
      end
      return true
    end,
  })
  list._generation = Probe(0)

  local lease, err = list:pin_range(0, 1, 0)
  H.eq(lease, nil)
  assert(err:match("invalid metadata"), err)
  H.eq(calls, 0)
  H.eq(list:pin_stats(), stats)

  local current, current_err = list:pin_is_current(old)
  H.eq(current, nil)
  assert(current_err:match("generation metadata is inconsistent"), current_err)
  H.eq(calls, 0)
  H.eq(list:pin_stats(), stats)

  list._generation = 0
  H.eq(list:release_pin(old), true)
  H.eq(PageList.validate(list), true)
end

T["page_list_ pin acquisition rejects public page reordering atomically"] =
  function()
    local list = PageList.new({ "a", "b" }, { max_rows = 1 })
    local first = assert(list:page_at(0))
    local second = assert(list:page_at(1))
    local stats = list:pin_stats()

    list._pages[1], list._pages[2] = second, first
    local lease, err = list:pin_range(0, 1)
    H.eq(lease, nil)
    assert(err:match("disagrees with public page metadata"), err)
    H.eq(list:pin_stats(), stats)
    H.eq(list:pin_count(first), 0)
    H.eq(list:pin_count(second), 0)

    local ok, validate_err = PageList.validate(list)
    H.eq(ok, nil)
    assert(validate_err:match("trusted pin layout is inconsistent"), validate_err)

    list._pages[1], list._pages[2] = first, second
    H.eq(PageList.validate(list), true)
  end

T["page_list_ pin lookup cannot execute hostile public prefixes"] = function()
  local list = PageList.new({ "a", "b" }, { max_rows = 1 })
  local original = list._starts[1]
  local called = false
  list._starts[1] = setmetatable({}, {
    __le = function()
      called = true
      list._starts[1] = original
      assert(list:splice(2, 0, { "c" }))
      return true
    end,
  })

  local lease, err = list:pin_range(0, 1, 0)
  H.eq(lease, nil)
  assert(err:match("disagrees with public page metadata"), err)
  H.eq(called, false)
  H.eq(list:generation(), 0)
  H.eq(list:pin_stats(), {
    active_leases = 0,
    pin_references = 0,
    current_pinned_pages = 0,
    retired_pinned_pages = 0,
  })

  list._starts[1] = original
  H.eq(PageList.validate(list), true)
end

T["page_list_ pin lookup does not invoke cdata prefix equality"] = function()
  local ffi = require("ffi")
  ffi.cdef([[
    typedef struct {
      int value;
    } canvasdiff_pin_prefix_probe;
  ]])

  local list = PageList.new({ "a", "b" }, { max_rows = 1 })
  local first = assert(list:page_at(0))
  local second = assert(list:page_at(1))
  local called = false
  local Probe = ffi.metatype("canvasdiff_pin_prefix_probe", {
    __eq = function()
      called = true
      list._starts[1] = 0
      list._pages[1] = second
      return true
    end,
  })
  list._starts[1] = Probe(0)

  local lease, err = list:pin_range(0, 1, 0)
  H.eq(lease, nil)
  assert(err:match("disagrees with public page metadata"), err)
  H.eq(called, false)
  H.eq(list:pin_count(first), 0)
  H.eq(list:pin_count(second), 0)

  list._starts[1] = 0
  H.eq(PageList.validate(list), true)
end

T["page_list_ private prefixes prevent wrong-node pin routing"] = function()
  local list = PageList.new({ "a", "b" }, { max_rows = 1 })
  local first = assert(list:page_at(0))
  local second = assert(list:page_at(1))
  list._starts[2] = 0

  local lease = assert(list:pin_range(0, 1, 0))
  H.eq(list:pin_count(first), 1)
  H.eq(list:pin_count(second), 0)
  H.eq(list:release_pin(lease), true)

  local rejected, err = list:pin_range(1, 1, 0)
  H.eq(rejected, nil)
  assert(err:match("disagrees with public page metadata"), err)
  H.eq(list:pin_stats(), {
    active_leases = 0,
    pin_references = 0,
    current_pinned_pages = 0,
    retired_pinned_pages = 0,
  })

  list._starts[2] = 1
  H.eq(PageList.validate(list), true)
end

T["page_list_ removed pinned pages retire until every lease releases"] =
  function()
    local list = PageList.new({ "a", "b", "c" }, { max_rows = 1 })
    local node = assert(list:page_at(1))
    local first = assert(list:pin_range(1, 1))
    local second = assert(list:pin_range(1, 1))

    H.eq(list:splice(1, 1, {}), true)
    H.eq(list:rows(0, 2), { "a", "c" })
    H.eq(list:pin_count(node), 2)
    H.eq(list:pin_is_current(first), false)
    H.eq(list:pin_is_current(second), false)
    H.eq(list:pin_stats(), {
      active_leases = 2,
      pin_references = 2,
      current_pinned_pages = 0,
      retired_pinned_pages = 1,
    })
    H.eq(PageList.validate(list), true)

    H.eq(list:release_pin(first), true)
    H.eq(list:pin_count(node), 1)
    H.eq(list:pin_stats().retired_pinned_pages, 1)
    H.eq(list:release_pin(second), true)
    H.eq(list:pin_count(node), nil)
    H.eq(list:pin_stats(), {
      active_leases = 0,
      pin_references = 0,
      current_pinned_pages = 0,
      retired_pinned_pages = 0,
    })
    H.eq(PageList.validate(list), true)
  end

T["page_list_ validation fully checks retired pinned nodes"] = function()
  local cases = {
    {
      mutate = function(node)
        node.id = -1
      end,
      error = "invalid id",
    },
    {
      mutate = function(node)
        node.id = 2
      end,
      error = "duplicated",
    },
    {
      mutate = function(node)
        node.created_generation = 99
      end,
      error = "creation generation",
    },
    {
      mutate = function(node)
        node.page = Page.new({ "evil" }, { max_rows = 1 })
      end,
      error = "not owned",
    },
    {
      mutate = function(node)
        node.page.payload = "evil"
      end,
      error = "retired page 1 is invalid",
    },
    {
      mutate = function(node)
        setmetatable(node, {})
      end,
      error = "plain table",
    },
  }

  for _, case in ipairs(cases) do
    local list = PageList.new({ "a", "b" }, { max_rows = 1 })
    local node = assert(list:page_at(0))
    local lease = assert(list:pin_range(0, 1))
    H.eq(list:splice(0, 1, {}), true)
    case.mutate(node)

    local ok, err = PageList.validate(list)
    H.eq(ok, nil)
    assert(err:match(case.error), err)

    H.eq(list:release_pin(lease), true)
    H.eq(PageList.validate(list), true)
  end
end

T["page_list_ pin leases use exact private list identity and release once"] =
  function()
    local left = PageList.new({ "a", "b" }, { max_rows = 1 })
    local right = PageList.new({ "a", "b" }, { max_rows = 1 })
    local node = assert(left:page_at(0))
    local lease = assert(left:pin_range(0, 1))
    local forged = setmetatable({}, {
      __eq = function()
        return true
      end,
    })

    H.eq(right:release_pin(lease), nil)
    H.eq(left:release_pin(forged), nil)
    H.eq(left:pin_count(node), 1)

    lease.generation = -1
    setmetatable(lease, {
      __eq = function()
        return true
      end,
    })
    H.eq(left:pin_is_current(lease), true)
    H.eq(PageList.validate(left), true)
    H.eq(left:release_pin(lease), true)
    H.eq(left:release_pin(lease), nil)
    H.eq(left:pin_is_current(lease), false)
    H.eq(left:pin_count(node), 0)
    H.eq(PageList.validate(left), true)
    H.eq(PageList.validate(right), true)
  end

T["page_list_ private splice fence protects pin state from callbacks"] =
  function()
    local list = PageList.new({ "a", "b", "c" }, { max_rows = 1 })
    local pinned_node = assert(list:page_at(2))
    local lease = assert(list:pin_range(2, 1))
    local original = Page.create
    local attempts = 0

    Page.create = function(...)
      attempts = attempts + 1
      rawset(list, "_splice_active", nil)
      local acquired, acquire_err = list:pin_range(0, 1)
      H.eq(acquired, nil)
      assert(acquire_err:match("splice is already active"), acquire_err)
      local released, release_err = list:release_pin(lease)
      H.eq(released, nil)
      assert(release_err:match("splice is already active"), release_err)
      local nested, nested_err = list:splice(0, 0, { "nested" })
      H.eq(nested, nil)
      assert(nested_err:match("splice is already active"), nested_err)
      rawset(list, "_splice_active", true)
      return original(...)
    end
    local called, change, err = pcall(
      PageList.splice,
      list,
      0,
      0,
      { "x" }
    )
    Page.create = original

    assert(called, change)
    assert(change, err)
    H.eq(attempts, 1)
    H.eq(list:rows(0, 4), { "x", "a", "b", "c" })
    H.eq(list:pin_count(pinned_node), 1)
    H.eq(list:pin_is_current(lease), false)
    H.eq(list:release_pin(lease), true)
    H.eq(rawget(list, "_splice_active"), nil)
    H.eq(PageList.validate(list), true)
  end

T["page_list_ splice rollback restores retired pinned page graphs"] =
  function()
    local list = PageList.new({ "a", "b" }, { max_rows = 1 })
    local node = assert(list:page_at(0))
    local page = node.page
    local node_id = node.id
    local lease = assert(list:pin_range(0, 1))
    H.eq(list:splice(0, 1, {}), true)
    local stats = list:stats()
    local original = Page.create

    Page.create = function(...)
      node.id = -1
      page.payload = "corrupt"
      setmetatable(node, {})
      return original(...)
    end
    local called, change, err = pcall(
      PageList.splice,
      list,
      1,
      0,
      { "x" }
    )
    Page.create = original

    assert(called, change)
    H.eq(change, nil)
    assert(err:match("mutated the source PageList"), err)
    H.eq(list:rows(0, 1), { "b" })
    H.eq(list:stats(), stats)
    H.eq(node.id, node_id)
    assert(node.page == page)
    H.eq(page.payload, "a")
    H.eq(getmetatable(node), nil)
    H.eq(list:pin_count(node), 1)
    H.eq(list:release_pin(lease), true)
    H.eq(PageList.validate(list), true)
  end

T["page_list_ retired pin lifetime ends on exact release"] = function()
  local list = PageList.new({ "a", "b" }, { max_rows = 1 })
  local node = assert(list:page_at(0))
  local lease = assert(list:pin_range(0, 1))
  local weak = setmetatable({ node }, { __mode = "v" })

  H.eq(list:splice(0, 1, {}), true)
  node = nil
  collectgarbage("collect")
  collectgarbage("collect")
  assert(weak[1], "an active retired pin must retain its exact node")

  H.eq(list:release_pin(lease), true)
  lease = nil
  collectgarbage("collect")
  collectgarbage("collect")
  H.eq(weak[1], nil, "release must drop the retired node lifetime")
  H.eq(PageList.validate(list), true)
end

T["page_list_ a live node cannot lose its Page claim through GC"] = function()
  local list = PageList.new({ "a" })
  local node = assert(list:page_at(0))
  node.page = nil
  collectgarbage("collect")
  collectgarbage("collect")

  local evil = Page.new({ "z" })
  local claimed, err = Page.claim(evil, node)
  H.eq(claimed, nil)
  assert(err:match("node already has a Page"), err)
end

T["page_list_ splice rejects a Page method-shadow forgery"] = function()
  local list = PageList.new({ "a", "b", "c" })
  local pages = list._pages
  local starts = list._starts
  local stats = list:stats()
  local node = assert(list:page_at(0))

  node.page.row = function(_, index)
    return "forged-" .. index
  end
  local change, err = list:splice(1, 0, { "x" })
  H.eq(change, nil)
  assert(err:match("shadows trusted method row"), err)
  H.eq(list:stats(), stats)
  assert(list._pages == pages)
  assert(list._starts == starts)
  assert(list._pages[1] == node)

  node.page.row = nil
  H.eq(list:rows(0, 3), { "a", "b", "c" })
  H.eq(PageList.validate(list), true)
end

T["page_list_ splice rejects stateful node page substitution"] = function()
  local list = PageList.new({ "a", "b", "c" })
  local pages = list._pages
  local starts = list._starts
  local stats = list:stats()
  local node = assert(list:page_at(0))
  local original_page = node.page
  local evil_page = Page.new({ "evil-a", "evil-b", "evil-c" })
  local reads = 0

  node.page = nil
  setmetatable(node, {
    __index = function(_, key)
      if key == "page" then
        reads = reads + 1
        if reads <= 9 then
          return original_page
        end
        return evil_page
      end
    end,
  })

  local change, err = list:splice(1, 0, { "x" })
  H.eq(change, nil)
  assert(err:match("page node 1 must be a plain table"), err)
  H.eq(reads, 0, "validation must not consult a node metatable")
  H.eq(list:stats(), stats)
  assert(list._pages == pages)
  assert(list._starts == starts)
  H.eq(rawget(list, "_splice_active"), nil)

  setmetatable(node, nil)
  node.page = original_page
  H.eq(list:rows(0, 3), { "a", "b", "c" })
  H.eq(PageList.validate(list), true)
end

T["page_list_ trusted dispatch rejects PageList method shadows"] = function()
  local methods = {
    "row_count",
    "page_count",
    "generation",
    "page_at",
    "locate",
    "inspect_page",
    "locate_page",
    "row",
    "rows",
    "splice",
    "stats",
    "pin_range",
    "release_pin",
    "pin_is_current",
    "pin_count",
    "pin_stats",
  }
  for _, method in ipairs(methods) do
    local list = PageList.new({ "a", "b", "c" })
    list[method] = function()
      return "forged"
    end
    local ok, err = PageList.validate(list)
    H.eq(ok, nil)
    assert(err:match("shadows trusted method " .. method), err)
  end

  local list = PageList.new({ "a", "b", "c" })
  local node = assert(list:page_at(0))
  list.locate = function()
    return node, 0, 0
  end

  H.eq(list:row(1), "b")
  H.eq(list:rows(1, 2), { "b", "c" })
  local change, err = PageList.splice(list, 1, 0, { "x" })
  H.eq(change, nil)
  assert(err:match("shadows trusted method locate"), err)
  H.eq(PageList.rows(list, 0, 3), { "a", "b", "c" })
  H.eq(rawget(list, "_splice_active"), nil)

  list.locate = nil
  H.eq(list:splice(1, 0, { "x" }), true)
  H.eq(list:rows(0, 4), { "a", "x", "b", "c" })
  H.eq(PageList.validate(list), true)
end

T["page_list_ trusted splice bypasses a monkeypatched class locator"] = function()
  local list = PageList.new({ "a", "b", "c" }, { max_rows = 1 })
  local original = PageList.locate
  local first = assert(list:page_at(0))

  PageList.locate = function()
    return first, 0, 0
  end
  local called, change, err = pcall(
    PageList.splice,
    list,
    1,
    1,
    { "x" }
  )
  PageList.locate = original

  assert(called, change)
  H.eq(change, true)
  H.eq(err, nil)
  H.eq(list:rows(0, 3), { "a", "x", "c" })
  H.eq(PageList.validate(list), true)
end

T["page_list_ splice fences re-entry from Page creation"] = function()
  local list = PageList.new({ "a", "b" }, { max_rows = 2 })
  local original = Page.create
  local injected = false
  local inner_change
  local inner_err

  Page.create = function(...)
    if not injected then
      injected = true
      inner_change, inner_err = list:splice(2, 0, { "inner" })
    end
    return original(...)
  end
  local called, outer_change, outer_err = pcall(
    PageList.splice,
    list,
    1,
    0,
    { "outer" }
  )
  Page.create = original

  assert(called, outer_change)
  H.eq(outer_change, true)
  H.eq(outer_err, nil)
  H.eq(inner_change, nil)
  assert(inner_err:match("already active"), inner_err)
  H.eq(list:rows(0, 3), { "a", "outer", "b" })
  H.eq(list:generation(), 1)
  H.eq(rawget(list, "_splice_active"), nil)
  H.eq(PageList.validate(list), true)
end

T["page_list_ splice snapshots caller rows before Page callbacks"] = function()
  local list = PageList.new({ "a", "b" }, { max_rows = 2 })
  local insert_rows = { "outer", "stable" }
  local original = Page.create
  local injected = false

  Page.create = function(...)
    if not injected then
      injected = true
      insert_rows[2] = "mutated"
    end
    return original(...)
  end
  local called, change, err = pcall(
    PageList.splice,
    list,
    1,
    0,
    insert_rows
  )
  Page.create = original

  assert(called, change)
  H.eq(change, true)
  H.eq(err, nil)
  H.eq(insert_rows, { "outer", "mutated" })
  H.eq(list:rows(0, 4), { "a", "outer", "stable", "b" })
  H.eq(rawget(list, "_splice_active"), nil)
  H.eq(PageList.validate(list), true)
end

T["page_list_fuzz_ splice matches an eager oracle and stable id registry"] = function()
  local oracle = { "seed", "", "nul\0" }
  local list = PageList.new(oracle, { max_rows = 4, max_bytes = 9 })
  local random_state = 104729
  local function random0(limit)
    random_state = (random_state * 48271) % 2147483647
    return random_state % limit
  end
  local function random_row()
    local kind = random0(7)
    if kind == 0 then
      return ""
    elseif kind == 1 then
      return "nul\0" .. string.char(48 + random0(10))
    elseif kind == 2 then
      local byte = random0(255)
      if byte >= 10 then
        byte = byte + 1
      end
      return string.char(0xFF, 0x80, byte)
    elseif kind == 3 then
      return string.rep("o", 10 + random0(6))
    end
    return string.rep(string.char(97 + random0(26)), 1 + random0(8))
  end

  local id_registry = {}
  local greatest_id = 0
  for _, node in ipairs(list_nodes(list)) do
    id_registry[node.id] = node
    greatest_id = math.max(greatest_id, node.id)
    H.eq(node.created_generation, 0)
  end

  for iteration = 1, 1200 do
    local start0 = random0(#oracle + 1)
    local delete_limit = math.min(5, #oracle - start0)
    local delete_count = random0(delete_limit + 1)
    local insert_count = random0(5)
    if iteration % 17 == 0 then
      delete_count = 0
      insert_count = 0
    elseif delete_count == 0 and insert_count == 0 then
      insert_count = 1
    end

    local insert_rows = {}
    for index = 1, insert_count do
      insert_rows[index] = random_row()
    end
    local before_generation = list:generation()
    H.eq(list:splice(start0, delete_count, insert_rows), true)
    local requested = delete_count > 0 or insert_count > 0
    local expected_generation = before_generation + (requested and 1 or 0)
    H.eq(list:generation(), expected_generation,
      "generation at randomized splice " .. iteration)
    oracle = oracle_splice(oracle, start0, delete_count, insert_rows)
    H.eq(list:row_count(), #oracle, "row count at randomized splice " .. iteration)
    H.eq(list:rows(0, #oracle), oracle,
      "row oracle at randomized splice " .. iteration)
    if #oracle > 0 then
      local probe0 = random0(#oracle)
      H.eq(list:row(probe0), oracle[probe0 + 1],
        "lookup oracle at randomized splice " .. iteration)
    end
    H.eq(list:stats().generation, expected_generation)
    H.eq(PageList.validate(list), true,
      "invariants at randomized splice " .. iteration)

    for _, node in ipairs(list_nodes(list)) do
      local registered = id_registry[node.id]
      if registered then
        assert(registered == node,
          "a committed page id must always identify the same node")
      else
        assert(node.id > greatest_id,
          "new page ids must advance beyond every historical id")
        greatest_id = node.id
        id_registry[node.id] = node
        H.eq(node.created_generation, expected_generation)
      end
      assert(node.created_generation <= expected_generation)
      if node.page.oversized then
        H.eq(node.page.row_count, 1)
        assert(node.page.decoded_bytes > 9)
      else
        assert(node.page.row_count <= 4)
        assert(node.page.decoded_bytes <= 9)
      end
    end
  end
end

T["page_list_fuzz_ pins remain exact across randomized splices"] = function()
  local oracle = { "a", "b", "c", "d", "e", "f" }
  local list = PageList.new(oracle, { max_rows = 3, max_bytes = 12 })
  local leases = {}
  local random_state = 32452843
  local function random0(limit)
    random_state = (random_state * 48271) % 2147483647
    return random_state % limit
  end
  local function range_nodes(start0, count)
    if count == 0 then
      return {}
    end
    local _, _, first_page0 = assert(list:locate(start0))
    local _, _, last_page0 = assert(list:locate(start0 + count - 1))
    local nodes = {}
    for page_index0 = first_page0, last_page0 do
      nodes[#nodes + 1] = assert(list:page_at(page_index0))
    end
    return nodes
  end

  for iteration = 1, 600 do
    local action = random0(8)
    if action <= 3 then
      local start0 = random0(#oracle + 1)
      local limit = math.min(10, #oracle - start0)
      local count = random0(limit + 1)
      local generation = list:generation()
      leases[#leases + 1] = {
        lease = assert(list:pin_range(start0, count, generation)),
        nodes = range_nodes(start0, count),
        generation = generation,
      }
    elseif action <= 5 and #leases > 0 then
      local index = random0(#leases) + 1
      H.eq(list:release_pin(leases[index].lease), true)
      table.remove(leases, index)
    else
      local start0 = random0(#oracle + 1)
      local delete_count = random0(
        math.min(3, #oracle - start0) + 1
      )
      local insert_count = random0(4)
      local inserted = {}
      for index = 1, insert_count do
        inserted[index] = ("p%d-%d"):format(iteration, index)
      end
      H.eq(list:splice(start0, delete_count, inserted), true)
      oracle = oracle_splice(
        oracle,
        start0,
        delete_count,
        inserted
      )
      H.eq(list:rows(0, #oracle), oracle)
    end

    local current = {}
    for _, node in ipairs(list_nodes(list)) do
      current[node] = true
    end
    local expected = {}
    local references = 0
    for _, record in ipairs(leases) do
      H.eq(
        list:pin_is_current(record.lease),
        record.generation == list:generation()
      )
      for _, node in ipairs(record.nodes) do
        expected[node] = (expected[node] or 0) + 1
        references = references + 1
      end
    end
    local current_pinned = 0
    local retired_pinned = 0
    for node, count in pairs(expected) do
      H.eq(list:pin_count(node), count)
      if current[node] then
        current_pinned = current_pinned + 1
      else
        retired_pinned = retired_pinned + 1
      end
    end
    for node in pairs(current) do
      H.eq(list:pin_count(node), expected[node] or 0)
    end
    H.eq(list:pin_stats(), {
      active_leases = #leases,
      pin_references = references,
      current_pinned_pages = current_pinned,
      retired_pinned_pages = retired_pinned,
    })
    H.eq(
      PageList.validate(list),
      true,
      "pin invariants at randomized operation " .. iteration
    )
  end

  while #leases > 0 do
    H.eq(list:release_pin(leases[#leases].lease), true)
    leases[#leases] = nil
  end
  H.eq(list:pin_stats(), {
    active_leases = 0,
    pin_references = 0,
    current_pinned_pages = 0,
    retired_pinned_pages = 0,
  })
  H.eq(PageList.validate(list), true)
end

T["page_list_ validate rejects corrupt prefixes ids pages and totals"] = function()
  H.eq(PageList.validate(false), nil)

  local duplicate = PageList.new({ "a", "b" }, { max_rows = 1 })
  duplicate._pages[2].id = duplicate._pages[1].id
  local ok, err = PageList.validate(duplicate)
  H.eq(ok, nil)
  assert(err:match("duplicated"), err)

  local prefix = PageList.new({ "a", "b" }, { max_rows = 1 })
  prefix._starts[2] = 0
  ok, err = PageList.validate(prefix)
  H.eq(ok, nil)
  assert(err:match("prefix"), err)

  local totals = PageList.new({ "a" })
  totals._row_count = 2
  ok, err = PageList.validate(totals)
  H.eq(ok, nil)
  assert(err:match("row_count"), err)

  local page = PageList.new({ "a" })
  page._pages[1].page.oversized = true
  ok, err = PageList.validate(page)
  H.eq(ok, nil)
  assert(err:match("page 1 is invalid"), err)

  local encoded = PageList.new({ "a" })
  encoded._pages[1].page = encoded._pages[1].page:encoded()
  local call_ok, validation_ok, ownership_err = pcall(PageList.validate, encoded)
  H.eq(call_ok, true, "validation must reject a plain encoded table without throwing")
  H.eq(validation_ok, nil)
  assert(ownership_err:match("owned Page"), ownership_err)

  local forged = PageList.new({ "a" })
  forged._pages[1].page.storage_bytes = function()
    return 999
  end
  forged._storage_bytes = 999
  ok, err = PageList.validate(forged)
  H.eq(ok, nil)
  assert(err:match("storage_bytes"), err)

  local generation = PageList.new({ "a" })
  generation._generation = -1
  ok, err = PageList.validate(generation)
  H.eq(ok, nil)
  assert(err:match("generation"), err)

  local creation_generation = PageList.new({ "a" })
  creation_generation._pages[1].created_generation = 1
  ok, err = PageList.validate(creation_generation)
  H.eq(ok, nil)
  assert(err:match("creation generation"), err)

  local allocator = PageList.new({ "a" })
  allocator._next_page_id = math.huge
  ok, err = PageList.validate(allocator)
  H.eq(ok, nil)
  assert(err:match("next page id"), err)

  local shared = PageList.new({ "a", "b" }, { max_rows = 1 })
  shared._pages[2].page = shared._pages[1].page
  ok, err = PageList.validate(shared)
  H.eq(ok, nil)
  assert(err:match("shares a Page object"), err)

  local unclaimed = PageList.new({ "a" })
  local original_page = unclaimed._pages[1].page
  local replacement_page = Page.new({ "a" })
  local claim_ok, claim_err =
    Page.claim(replacement_page, unclaimed._pages[1])
  H.eq(claim_ok, nil)
  assert(claim_err:match("node already has a Page"), claim_err)
  unclaimed._pages[1].page = replacement_page
  ok, err = PageList.validate(unclaimed)
  H.eq(ok, nil)
  assert(err:match("not owned by its PageList node"), err)
  unclaimed._pages[1].page = original_page
  H.eq(PageList.validate(unclaimed), true)

  local left = PageList.new({ "a" })
  local right = PageList.new({ "a" })
  right._pages[1].page = left._pages[1].page
  ok, err = PageList.validate(right)
  H.eq(ok, nil)
  assert(err:match("not owned by its PageList node"), err)

  local copied_node = PageList.new({ "a" })
  copied_node._pages[1] = left._pages[1]
  ok, err = PageList.validate(copied_node)
  H.eq(ok, nil)
  assert(err:match("belongs to another PageList"), err)

  local indexed = PageList.new({ "a" })
  setmetatable(indexed._pages, {
    __index = function()
      error("page index metatable must never run", 0)
    end,
  })
  call_ok, validation_ok, ownership_err = pcall(PageList.validate, indexed)
  H.eq(call_ok, true)
  H.eq(validation_ok, nil)
  assert(ownership_err:match("plain dense sequence"), ownership_err)

  local source = PageList.new({ "a" })
  local fake = {
    _pages = source._pages,
    _starts = source._starts,
    _row_count = source._row_count,
    _decoded_bytes = source._decoded_bytes,
    _storage_bytes = source._storage_bytes,
    _oversized_pages = source._oversized_pages,
    _next_page_id = source._next_page_id,
    _generation = source._generation,
    _max_rows = source._max_rows,
    _max_bytes = source._max_bytes,
  }
  setmetatable(fake, {
    __metatable = PageList,
    __index = PageList,
  })
  assert(getmetatable(fake) == PageList)
  ok, err = PageList.validate(fake)
  H.eq(ok, nil)
  assert(err:match("not an owned PageList"), err)
end

T["page_list_ streaming and table construction have identical pages"] = function()
  local rows = {
    "aa",
    "",
    "bbb",
    string.rep("h", 7),
    "nul\0",
    string.char(0xFF),
    "last",
  }
  local index = 0
  local streamed = assert(PageList.from_iterator(function()
    index = index + 1
    return rows[index]
  end, { max_rows = 3, max_bytes = 6 }))
  local tabled = PageList.new(rows, { max_rows = 3, max_bytes = 6 })

  H.eq(streamed:stats(), tabled:stats())
  H.eq(streamed:page_count(), tabled:page_count())
  for page_index0 = 0, tabled:page_count() - 1 do
    local streamed_node = assert(streamed:page_at(page_index0))
    local tabled_node = assert(tabled:page_at(page_index0))
    H.eq(streamed_node.id, tabled_node.id)
    H.eq(streamed_node.page:encoded(), tabled_node.page:encoded())
  end
  H.eq(streamed:rows(0, #rows), rows)
  H.eq(PageList.validate(streamed), true)
end

T["page_list_ streaming preserves every packing boundary"] = function()
  local rows = {}
  for index = 1, 257 do
    rows[index] = "r"
  end
  rows[#rows + 1] = string.rep("x", 65535)
  rows[#rows + 1] = ""
  rows[#rows + 1] = "y"
  rows[#rows + 1] = string.rep("z", 65537)
  rows[#rows + 1] = "after"

  local index = 0
  local list = assert(PageList.from_iterator(function()
    index = index + 1
    return rows[index]
  end))

  H.eq(list:rows(0, #rows), rows)
  H.eq(list:stats().oversized_pages, 1)
  local oversized
  for page_index0 = 0, list:page_count() - 1 do
    local page = assert(list:page_at(page_index0)).page
    if page.oversized then
      oversized = page
      break
    end
  end
  assert(oversized)
  H.eq(oversized.row_count, 1)
  H.eq(oversized:row(1), string.rep("z", 65537))
  H.eq(PageList.validate(list), true)
end

T["page_list_ streaming late failures never publish a partial list"] = function()
  local calls = 0
  local list, err = PageList.from_iterator(function()
    calls = calls + 1
    if calls <= 513 then
      return "row-" .. calls
    end
    return nil, "source vanished"
  end, { max_rows = 2 })
  H.eq(list, nil)
  assert(err:match("row 514"), err)
  assert(err:match("source vanished"), err)

  calls = 0
  list, err = PageList.from_iterator(function()
    calls = calls + 1
    if calls <= 300 then
      return ""
    end
    error("iterator exploded", 0)
  end, { max_rows = 3 })
  H.eq(list, nil)
  assert(err:match("threw at row 301"), err)
  assert(err:match("iterator exploded"), err)

  calls = 0
  list, err = PageList.from_iterator(function()
    calls = calls + 1
    if calls <= 260 then
      return "ok"
    end
    return "bad\nrow"
  end)
  H.eq(list, nil)
  assert(err:match("row 261"), err)
  assert(err:match("line%-feed"), err)
end

T["page_list_ table preflight rejects late corruption before allocating pages"] = function()
  local rows = {}
  for index = 1, 513 do
    rows[index] = "row-" .. index
  end
  rows[514] = false

  local original = Page.create
  local allocations = 0
  Page.create = function(...)
    allocations = allocations + 1
    return original(...)
  end
  local called, list, err = pcall(PageList.create, rows, { max_rows = 2 })
  Page.create = original

  assert(called, list)
  H.eq(list, nil)
  assert(err:match("row 514"), err)
  H.eq(allocations, 0,
    "table-backed construction must preflight before allocating any Page")
end

T["page_list_ table construction snapshots rows before Page callbacks"] = function()
  local source = { "a", "b", "c" }
  local original = Page.create
  local injected = false

  Page.create = function(...)
    if not injected then
      injected = true
      source[2] = "EVIL"
    end
    return original(...)
  end
  local called, list, err = pcall(PageList.create, source, { max_rows = 1 })
  Page.create = original

  assert(called, list)
  assert(list, err)
  H.eq(source, { "a", "EVIL", "c" })
  H.eq(list:rows(0, 3), { "a", "b", "c" })
  H.eq(PageList.validate(list), true)
end

T["page_list_ streaming contains adversarial iterator results"] = function()
  local list, err = PageList.from_iterator(false)
  H.eq(list, nil)
  assert(err:match("function"), err)

  list, err = PageList.from_iterator(function()
    return nil, false
  end)
  H.eq(list, nil)
  assert(err:match("failed at row 1"), err)
  assert(err:match("false"), err)

  list, err = PageList.from_iterator(function()
    return "row", "also an error"
  end)
  H.eq(list, nil)
  assert(err:match("row and error"), err)

  local unprintable = setmetatable({}, {
    __tostring = function()
      error("tostring failed")
    end,
  })
  list, err = PageList.from_iterator(function()
    error(unprintable, 0)
  end)
  H.eq(list, nil)
  assert(err:find("<unprintable error>", 1, true), err)

  list, err = PageList.from_iterator(function()
    return nil
  end, false)
  H.eq(list, nil)
  assert(err:match("options"), err)
end

T["page_list_ resident options are raw snapshotted and bounded"] = function()
  local adapter = test_resident_adapter()
  local invalid = {
    { resident = false, reason = "resident cache options" },
    { resident = { max_pages = -1 }, reason = "max_pages" },
    { resident = { max_pages = 1.5 }, reason = "max_pages" },
    { resident = { max_bytes = math.huge }, reason = "max_bytes" },
    { resident = { restore = false }, reason = "restore adapter" },
    {
      resident = {
        restore = {
          codec = "raw",
          encode = adapter.encode,
          decode = adapter.decode,
          crc32 = adapter.crc32,
        },
      },
      reason = "codec",
    },
    {
      resident = {
        restore = {
          codec = "missing-encode",
          decode = adapter.decode,
          crc32 = adapter.crc32,
        },
      },
      reason = "encode",
    },
    {
      resident = {
        restore = {
          codec = "missing-decode",
          encode = adapter.encode,
          crc32 = adapter.crc32,
        },
      },
      reason = "decode",
    },
    {
      resident = {
        restore = {
          codec = "missing-crc",
          encode = adapter.encode,
          decode = adapter.decode,
        },
      },
      reason = "crc32",
    },
  }
  for _, case in ipairs(invalid) do
    local list, err = PageList.create({ "alpha" }, case)
    H.eq(list, nil)
    assert(err:find(case.reason, 1, true), err)
  end

  local callback_calls = 0
  local restore = setmetatable(test_resident_adapter(), {
    __index = function()
      callback_calls = callback_calls + 1
      error("restore options must be raw-read")
    end,
  })
  local resident = setmetatable({
    max_pages = 1,
    max_bytes = 128,
    restore = restore,
  }, {
    __index = function()
      callback_calls = callback_calls + 1
      error("resident options must be raw-read")
    end,
  })
  local list = PageList.new({ "alpha-alpha" }, { resident = resident })
  restore.encode = function()
    error("the caller adapter must not remain live")
  end
  restore.codec = "mutated"
  resident.max_pages = 0
  H.eq(list:compact_page(0, 0), true)
  H.eq(Page.metadata(assert(list:page_at(0)).page).codec,
    "page-list-test-v1")
  H.eq(callback_calls, 0)
  H.eq(rawget(assert(list:page_at(0)), "capability"), nil)
  H.eq(PageList.validate(list), true)

  local raw_only = PageList.new({ "raw" }, {
    resident = { max_pages = 0, max_bytes = 0 },
  })
  H.eq(raw_only:row(0), "raw")
  local compacted, compact_err = raw_only:compact_page(0)
  H.eq(compacted, nil)
  assert(compact_err:find("not configured", 1, true), compact_err)
end

T["page_list_ compact_page publishes one exact unpinned page"] = function()
  local encode_calls = 0
  local adapter = test_resident_adapter({
    encode = function()
      encode_calls = encode_calls + 1
      return "\1"
    end,
  })
  local list = PageList.new({
    "first-first-first",
    "second-second-second",
  }, {
    max_rows = 1,
    resident = {
      max_pages = 1,
      max_bytes = 128,
      restore = adapter,
    },
  })
  local first = assert(list:page_at(0))
  local before_page = Page.metadata(first.page)
  local before_stats = list:stats()

  H.eq(list:compact_page(3, 0), nil)
  H.eq(list:compact_page(0, 1), nil)
  H.eq(encode_calls, 0)
  local lease = assert(list:pin_range(0, 1, 0))
  local compacted, compact_err = list:compact_page(0, 0)
  H.eq(compacted, nil)
  assert(compact_err:find("unpinned", 1, true), compact_err)
  H.eq(encode_calls, 0)
  H.eq(list:release_pin(lease), true)

  local ok, old_storage, new_storage, revision =
    list:compact_page(0, 0)
  H.eq(ok, true)
  H.eq(old_storage, before_page.storage_bytes)
  H.eq(new_storage, 1)
  H.eq(revision, 1)
  H.eq(encode_calls, 1)
  H.eq(list:generation(), 0)
  H.eq(list:stats().storage_bytes,
    before_stats.storage_bytes - old_storage + new_storage)
  local after = Page.metadata(first.page)
  H.eq(after.kind, "cold")
  H.eq(after.revision, 1)
  H.eq(after.restore_bytes, before_page.restore_bytes)
  H.eq(PageList.validate(list), true)

  compacted, compact_err = list:compact_page(0, 0)
  H.eq(compacted, false)
  assert(compact_err:find("raw page", 1, true), compact_err)
  H.eq(encode_calls, 1)
end

T["page_list_ cold metadata caps and adapter survive an untouched splice"] =
  function()
    local adapter = test_resident_adapter()
    local list = PageList.new({ "first-first", "second-second" }, {
      max_rows = 1,
      resident = { restore = adapter },
    })
    local first = assert(list:page_at(0))
    H.eq(list:compact_page(0, 0), true)
    H.eq(Page.metadata(first.page).kind, "cold")

    H.eq(list:splice(2, 0, { "third-third" }), true)
    H.eq(list:generation(), 1)
    assert(list:page_at(0) == first)
    H.eq(Page.metadata(first.page).kind, "cold")
    H.eq(list:compact_page(2, 1), true)
    H.eq(Page.metadata(assert(list:page_at(2)).page).kind, "cold")
    H.eq(PageList.validate(list), true)
  end

T["page_list_ compact_page preflights resident capacity before encode"] =
  function()
    for _, limits in ipairs({
      { max_pages = 0, max_bytes = 1000 },
      { max_pages = 1, max_bytes = 1 },
    }) do
      local encode_calls = 0
      local adapter = test_resident_adapter({
        encode = function()
          encode_calls = encode_calls + 1
          return "\1"
        end,
      })
      local list = PageList.new({ "capacity-capacity" }, {
        resident = {
          max_pages = limits.max_pages,
          max_bytes = limits.max_bytes,
          restore = adapter,
        },
      })
      local before = list:stats()
      local compacted, err = list:compact_page(0, 0)
      H.eq(compacted, false)
      assert(err:find("cache limits", 1, true), err)
      H.eq(encode_calls, 0)
      H.eq(list:stats(), before)
      H.eq(Page.metadata(assert(list:page_at(0)).page).kind, "raw")
      H.eq(PageList.validate(list), true)
    end
  end

T["page_list_ compact_page faults and no-benefit stay atomic"] = function()
  local modes = { "decline", "throw" }
  for _, mode in ipairs(modes) do
    local adapter = test_resident_adapter({
      encode = function(body)
        if mode == "throw" then
          error(string.rep("codec-fault", 100))
        end
        return body
      end,
    })
    local list = PageList.new({ "fault-fault-fault" }, {
      resident = { restore = adapter },
    })
    local before = list:stats()
    local compacted, err = list:compact_page(0, 0)
    if mode == "decline" then
      H.eq(compacted, false)
      assert(err:find("not smaller", 1, true), err)
    else
      H.eq(compacted, nil)
      assert(err:find("encode callback failed", 1, true), err)
      assert(#err < 100, err)
    end
    H.eq(list:stats(), before)
    H.eq(Page.metadata(assert(list:page_at(0)).page).kind, "raw")
    H.eq(PageList.validate(list), true)
  end
end

T["page_list_ compact callbacks cannot reenter or mutate the list"] =
  function()
    local list
    local lease
    local reenter = true
    local nested = {}
    local crc_calls = 0
    local adapter = test_resident_adapter({
      encode = function()
        if reenter then
          nested.row = { list:row(0) }
          nested.rows = { list:rows(0, 1) }
          nested.pin = { list:pin_range(0, 1) }
          nested.release = { list:release_pin(lease) }
          nested.splice = { list:splice(0, 0, { "x" }) }
          nested.compact = { list:compact_page(0) }
        end
        return "\1"
      end,
      crc32 = function(raw)
        crc_calls = crc_calls + 1
        return test_crc32(raw)
      end,
    })
    list = PageList.new({
      "target-target-target",
      "pinned-pinned-pinned",
    }, {
      max_rows = 1,
      resident = { restore = adapter },
    })
    lease = assert(list:pin_range(1, 1, 0))
    local before = list:stats()
    local compacted, err = list:compact_page(0, 0)
    H.eq(compacted, nil)
    assert(err:find("changed during compaction", 1, true), err)
    for name, result in pairs(nested) do
      H.eq(result[1], nil, name)
      assert(result[2]:find("compaction is already active", 1, true),
        result[2])
    end
    H.eq(list:stats(), before)
    H.eq(crc_calls, 0, "encode-side reentry must stop before CRC")
    H.eq(list:pin_is_current(lease), true)
    H.eq(Page.metadata(assert(list:page_at(0)).page).kind, "raw")
    H.eq(PageList.validate(list), true)

    reenter = false
    H.eq(list:compact_page(0, 0), true)
    H.eq(crc_calls, 1)
    H.eq(list:pin_is_current(lease), true)
    H.eq(list:release_pin(lease), true)
    H.eq(PageList.validate(list), true)
  end

T["page_list_ compact crc callback reentry discards its candidate"] =
  function()
    local list
    local reenter = true
    local crc_calls = 0
    local adapter = test_resident_adapter({
      crc32 = function(raw)
        crc_calls = crc_calls + 1
        if reenter then
          local row, err = list:row(0)
          H.eq(row, nil)
          assert(err:find("compaction is already active", 1, true), err)
        end
        return test_crc32(raw)
      end,
    })
    list = PageList.new({ "crc-reentry-crc-reentry" }, {
      resident = { restore = adapter },
    })
    local before = list:stats()
    local compacted, err = list:compact_page(0, 0)
    H.eq(compacted, nil)
    assert(err:find("changed during compaction", 1, true), err)
    H.eq(crc_calls, 1)
    H.eq(list:stats(), before)
    H.eq(Page.metadata(assert(list:page_at(0)).page).kind, "raw")
    H.eq(PageList.validate(list), true)

    reenter = false
    H.eq(list:compact_page(0, 0), true)
    H.eq(crc_calls, 2)
    H.eq(PageList.validate(list), true)
  end

T["page_list_ compact callback graph mutation is rolled back"] = function()
  local list
  local mutate = true
  local crc_calls = 0
  local adapter = test_resident_adapter({
    encode = function()
      if mutate then
        list._generation = 99
        list._storage_bytes = 0
        list._pages[1].page = Page.new({ "forged" })
      end
      return "\1"
    end,
    crc32 = function(raw)
      crc_calls = crc_calls + 1
      return test_crc32(raw)
    end,
  })
  list = PageList.new({ "graph-graph-graph" }, {
    resident = { restore = adapter },
  })
  local node = assert(list:page_at(0))
  local page = node.page
  local before = list:stats()
  local compacted, err = list:compact_page(0, 0)
  H.eq(compacted, nil)
  assert(err:find("mutated the source", 1, true), err)
  H.eq(list:stats(), before)
  H.eq(crc_calls, 0, "encode-side mutation must stop before CRC")
  assert(list:page_at(0) == node)
  assert(node.page == page)
  H.eq(Page.metadata(page).kind, "raw")
  H.eq(PageList.validate(list), true)

  mutate = false
  H.eq(list:compact_page(0, 0), true)
  H.eq(crc_calls, 1)
  H.eq(PageList.validate(list), true)
end

T["page_list_ compact callback shell additions are exactly rolled back"] =
  function()
    for _, target in ipairs({ "page", "node", "list" }) do
      local list
      local node
      local mutate = true
      local crc_calls = 0
      local adapter = test_resident_adapter({
        encode = function()
          if mutate then
            if target == "page" then
              node.page.evil = true
            elseif target == "node" then
              node.evil = true
            else
              list.row = function()
                return "evil"
              end
              _G.error = function()
                return nil
              end
            end
          end
          return "\1"
        end,
        crc32 = function(raw)
          crc_calls = crc_calls + 1
          return test_crc32(raw)
        end,
      })
      list = PageList.new({ "shell-shell-shell" }, {
        resident = { restore = adapter },
      })
      node = assert(list:page_at(0))
      local before = list:stats()
      local original_error = _G.error
      local called, compacted, err = pcall(
        list.compact_page,
        list,
        0,
        0
      )
      _G.error = original_error

      assert(called, compacted)
      H.eq(compacted, nil, target)
      assert(err:find("mutated the source", 1, true)
        or err:find("changed during compaction", 1, true), err)
      H.eq(rawget(node.page, "evil"), nil)
      H.eq(rawget(node, "evil"), nil)
      H.eq(rawget(list, "row"), nil)
      H.eq(crc_calls, 0,
        "a poisoned global error must not let a doomed encode reach CRC")
      H.eq(list:stats(), before)
      H.eq(PageList.validate(list), true)

      mutate = false
      H.eq(list:compact_page(0, 0), true)
      H.eq(crc_calls, 1)
      H.eq(PageList.validate(list), true)
    end
  end

T["page_list_ compact fences avoid hostile equality and length hooks"] =
  function()
    local ffi = require("ffi")
    ffi.cdef([[
      typedef struct {
        int value;
      } canvasdiff_compact_fence_probe;
    ]])

    local equality_calls = 0
    local Probe = ffi.metatype("canvasdiff_compact_fence_probe", {
      __eq = function()
        equality_calls = equality_calls + 1
        return true
      end,
    })
    for _, field in ipairs({ "_generation", "_row_count" }) do
      local list = PageList.new({ "public-scalar-probe" }, {
        resident = { restore = test_resident_adapter() },
      })
      local original = rawget(list, field)
      rawset(list, field, Probe(original))
      local compacted, err = list:compact_page(0, 0)
      H.eq(compacted, nil)
      assert(err:find("invalid metadata", 1, true), err)
      H.eq(equality_calls, 0)
      rawset(list, field, original)
      H.eq(PageList.validate(list), true)
    end

    for _, target in ipairs({ "id", "created_generation", "start" }) do
      local list
      local node
      local adapter = test_resident_adapter({
        encode = function()
          if target == "start" then
            list._starts[1] = Probe(0)
          else
            node[target] = Probe(rawget(node, target))
          end
          return "\1"
        end,
      })
      list = PageList.new({ "target-scalar-probe" }, {
        resident = { restore = adapter },
      })
      node = assert(list:page_at(0))
      local compacted, err = list:compact_page(0, 0)
      H.eq(compacted, nil)
      assert(err:find("mutated the source", 1, true), err)
      H.eq(equality_calls, 0)
      H.eq(PageList.validate(list), true)
    end

    local list
    local length_calls = 0
    local hostile_metatable = {
      __len = function()
        length_calls = length_calls + 1
        return 1
      end,
    }
    local adapter = test_resident_adapter({
      encode = function()
        setmetatable(list._pages, hostile_metatable)
        setmetatable(list._starts, hostile_metatable)
        return "\1"
      end,
    })
    list = PageList.new({ "layout-metatable-probe" }, {
      resident = { restore = adapter },
    })
    local compacted, err = list:compact_page(0, 0)
    H.eq(compacted, nil)
    assert(err:find("mutated the source", 1, true), err)
    H.eq(length_calls, 0)
    H.eq(getmetatable(list._pages), nil)
    H.eq(getmetatable(list._starts), nil)
    H.eq(PageList.validate(list), true)
  end

T["page_list_ compact treats unrelated raw layout writes as corruption"] =
  function()
    local list
    local adapter = test_resident_adapter({
      encode = function()
        list._pages[2], list._pages[3] =
          list._pages[3], list._pages[2]
        return "\1"
      end,
    })
    list = PageList.new({ "first", "second", "third" }, {
      max_rows = 1,
      resident = { restore = adapter },
    })

    -- compact_page intentionally fences only the target slot in O(1).
    H.eq(list:compact_page(0, 0), true)
    local valid, validate_err = PageList.validate(list)
    H.eq(valid, nil)
    assert(validate_err:find("trusted pin layout", 1, true), validate_err)

    list._pages[2], list._pages[3] =
      list._pages[3], list._pages[2]
    H.eq(PageList.validate(list), true)
  end

T["page_list_ streaming supports one million rows without an input table"] = function()
  local logical_rows = 1000000
  local emitted = 0
  local list = assert(PageList.from_iterator(function()
    if emitted == logical_rows then
      return nil
    end
    emitted = emitted + 1
    return ""
  end))

  H.eq(emitted, logical_rows)
  H.eq(list:row_count(), logical_rows)
  H.eq(list:page_count(), math.ceil(logical_rows / 256))
  H.eq(list:row(0), "")
  H.eq(list:row(logical_rows - 1), "")
  H.eq(list:stats().decoded_bytes, 0)
  H.eq(PageList.validate(list), true)

  local first_node = assert(list:page_at(0))
  local last_node = assert(list:page_at(list:page_count() - 1))
  local page_count = list:page_count()
  H.eq(list:splice(500000, 0, { "needle" }), true)
  H.eq(list:row_count(), logical_rows + 1)
  H.eq(list:page_count(), page_count + 1)
  H.eq(list:generation(), 1)
  H.eq(list:row(499999), "")
  H.eq(list:row(500000), "needle")
  H.eq(list:row(500001), "")
  assert(list:page_at(0) == first_node)
  assert(list:page_at(list:page_count() - 1) == last_node)
  H.eq(PageList.validate(list), true)
end

T["page_list_ streaming does not retain its iterator closure"] = function()
  local weak = setmetatable({}, { __mode = "v" })

  local function build_with_token()
    local token = {}
    weak[1] = token
    local count = 0
    return assert(PageList.from_iterator(function()
      if token and count < 4 then
        count = count + 1
        return tostring(count)
      end
      return nil
    end))
  end

  local list = build_with_token()
  collectgarbage("collect")
  collectgarbage("collect")
  H.eq(weak[1], nil, "the completed list must not retain the source closure")
  H.eq(list:rows(0, 4), { "1", "2", "3", "4" })
end

return T
