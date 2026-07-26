local H = require("helpers")
local Page = require("canvasdiff.canvas.Page")
local PageList = require("canvasdiff.canvas.PageList")

local T = {}

local function page_rows(list, page_index0)
  local node = assert(list:page_at(page_index0))
  return assert(node.page:rows())
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
end

T["page_list_ empty input owns no phantom page"] = function()
  local list = PageList.new({})
  H.eq(list:stats(), {
    row_count = 0,
    page_count = 0,
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
