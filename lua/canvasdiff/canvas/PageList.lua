local Page = require("canvasdiff.canvas.Page")

local PageList = {}
PageList.__index = PageList

PageList.DEFAULT_MAX_ROWS = Page.DEFAULT_MAX_ROWS
PageList.DEFAULT_MAX_BYTES = Page.DEFAULT_MAX_BYTES

local U32_MAX = 0xFFFFFFFF

local function integer(value)
  return type(value) == "number"
    and value >= 0
    and value < math.huge
    and value == math.floor(value)
end

local function positive_integer(value)
  return integer(value) and value > 0
end

local function options(opts)
  if opts == nil then
    opts = {}
  elseif type(opts) ~= "table" then
    return nil, "page-list options must be a table"
  end

  local max_rows = rawget(opts, "max_rows")
  if max_rows == nil then
    max_rows = PageList.DEFAULT_MAX_ROWS
  end
  local max_bytes = rawget(opts, "max_bytes")
  if max_bytes == nil then
    max_bytes = PageList.DEFAULT_MAX_BYTES
  end

  if not positive_integer(max_rows) then
    return nil, "max_rows must be a positive integer"
  end
  if not positive_integer(max_bytes) or max_bytes > U32_MAX then
    return nil, "max_bytes must be a positive 32-bit integer"
  end
  return { max_rows = max_rows, max_bytes = max_bytes }
end

--- Length of a dense one-based sequence, including the empty sequence.
--- `next` and `rawget` deliberately ignore metatable-supplied rows.
local function sequence_length(rows)
  if type(rows) ~= "table" then
    return nil, "rows must be a sequence"
  end

  local count = 0
  for key in next, rows do
    if not positive_integer(key) then
      return nil, "rows must use consecutive positive integer keys"
    end
    count = count + 1
  end
  for index = 1, count do
    if rawget(rows, index) == nil then
      return nil, "rows must be a dense sequence"
    end
  end
  return count
end

--- Validate table-backed construction completely before allocating any Page.
--- Unlike an iterator, a table is already resident and can be preflighted:
--- rejecting a malformed late row must not duplicate its entire valid prefix.
local function validate_rows(rows)
  local count, count_err = sequence_length(rows)
  if count == nil then
    return nil, count_err
  end
  for index = 1, count do
    local row = rawget(rows, index)
    if type(row) ~= "string" then
      return nil, ("row %d must be a string"):format(index)
    end
    if row:find("\n", 1, true) then
      return nil, ("row %d contains a line-feed delimiter"):format(index)
    end
    if #row > U32_MAX then
      return nil, ("row %d exceeds the 32-bit page limit"):format(index)
    end
  end
  return count
end

local function diagnostic(value)
  local ok, message = pcall(tostring, value)
  if not ok then
    return "<unprintable error>"
  end
  local limit = 256
  if #message > limit then
    return message:sub(1, limit) .. "…"
  end
  return message
end

local function dense_table(value, label)
  if type(value) ~= "table" then
    return nil, label .. " must be a table"
  end
  local count = 0
  for key in next, value do
    if not positive_integer(key) then
      return nil, label .. " must be a dense sequence"
    end
    count = count + 1
  end
  for index = 1, count do
    if rawget(value, index) == nil then
      return nil, label .. " must be a dense sequence"
    end
  end
  return count
end

local function append_page(state, rows)
  local page, page_err = Page.create(rows, {
    max_rows = state._max_rows,
    max_bytes = state._max_bytes,
  })
  if not page then
    return nil, page_err
  end

  local node = {
    id = state._next_page_id,
    page = page,
  }
  state._next_page_id = state._next_page_id + 1
  state._starts[#state._starts + 1] = state._row_count
  state._pages[#state._pages + 1] = node
  state._row_count = state._row_count + page.row_count
  state._decoded_bytes = state._decoded_bytes + page.decoded_bytes
  state._storage_bytes = state._storage_bytes + page:storage_bytes()
  if page.oversized then
    state._oversized_pages = state._oversized_pages + 1
  end
  return true
end

--- Consume a row source into a private candidate. Nothing returns the
--- candidate before EOF, the final flush, and the invariant check succeed.
local function build(next_row, limits)
  local state = setmetatable({
    _pages = {},
    _starts = {},
    _row_count = 0,
    _decoded_bytes = 0,
    _storage_bytes = 0,
    _oversized_pages = 0,
    _next_page_id = 1,
    _max_rows = limits.max_rows,
    _max_bytes = limits.max_bytes,
  }, PageList)

  local pending = {}
  local pending_bytes = 0
  local row_number = 0

  local function flush()
    if #pending == 0 then
      return true
    end
    local ok, err = append_page(state, pending)
    if not ok then
      return nil, err
    end
    pending = {}
    pending_bytes = 0
    return true
  end

  while true do
    local called, row, source_err = pcall(next_row)
    if not called then
      return nil, ("row iterator threw at row %d: %s"):format(
        row_number + 1,
        diagnostic(row)
      )
    end
    if row == nil then
      if source_err ~= nil then
        return nil, ("row iterator failed at row %d: %s"):format(
          row_number + 1,
          diagnostic(source_err)
        )
      end
      break
    end

    row_number = row_number + 1
    if source_err ~= nil then
      return nil, ("row iterator returned a row and error at row %d"):format(row_number)
    end
    if type(row) ~= "string" then
      return nil, ("row %d must be a string"):format(row_number)
    end
    if row:find("\n", 1, true) then
      return nil, ("row %d contains a line-feed delimiter"):format(row_number)
    end
    if #row > U32_MAX then
      return nil, ("row %d exceeds the 32-bit page limit"):format(row_number)
    end

    local row_bytes = #row

    if row_bytes > limits.max_bytes then
      local ok, err = flush()
      if not ok then
        return nil, err
      end
      ok, err = append_page(state, { row })
      if not ok then
        return nil, err
      end
    else
      if #pending > 0 and (
        #pending >= limits.max_rows
        or pending_bytes + row_bytes > limits.max_bytes
      ) then
        local ok, err = flush()
        if not ok then
          return nil, err
        end
      end

      pending[#pending + 1] = row
      pending_bytes = pending_bytes + row_bytes
      if #pending == limits.max_rows then
        local ok, err = flush()
        if not ok then
          return nil, err
        end
      end
    end
  end

  local ok, flush_err = flush()
  if not ok then
    return nil, flush_err
  end
  ok, flush_err = PageList.validate(state)
  if not ok then
    return nil, flush_err
  end
  return state
end

--- Build a checked, read-only logical row store from a dense sequence.
---
--- Pages are greedily filled up to both limits. A row larger than max_bytes is
--- represented by one oversized singleton page; it is never combined with a
--- neighbour. The input sequence is not retained.
function PageList.create(rows, opts)
  local limits, limits_err = options(opts)
  if not limits then
    return nil, limits_err
  end
  local count, rows_err = validate_rows(rows)
  if count == nil then
    return nil, rows_err
  end

  local index = 0
  return build(function()
    index = index + 1
    if index > count then
      return nil
    end
    return rawget(rows, index)
  end, limits)
end

--- Build from a pull source without materializing every logical row first.
---
--- `next_row` returns one row string, nil for EOF, or nil plus an error for a
--- source failure. Iterator throws are contained and become ordinary errors.
function PageList.from_iterator(next_row, opts)
  if type(next_row) ~= "function" then
    return nil, "row iterator must be a function"
  end
  local limits, limits_err = options(opts)
  if not limits then
    return nil, limits_err
  end
  return build(next_row, limits)
end

function PageList.new(rows, opts)
  local list, err = PageList.create(rows, opts)
  assert(list, err)
  return list
end

function PageList:row_count()
  return self._row_count
end

function PageList:page_count()
  return #self._pages
end

--- Return page metadata at a zero-based page index.
function PageList:page_at(page_index0)
  if not integer(page_index0) or page_index0 >= #self._pages then
    return nil, "page index is outside the list"
  end
  return self._pages[page_index0 + 1]
end

--- Locate one zero-based logical row in O(log page_count).
--- Returns the page node, zero-based row within that page, and zero-based page
--- index. EOF is a range boundary, not a row, and therefore does not locate.
function PageList:locate(row0)
  if not integer(row0) or row0 >= self._row_count then
    return nil, "row index is outside the list"
  end

  local low, high = 1, #self._starts
  local found = 0
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if self._starts[middle] <= row0 then
      found = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end

  local node = self._pages[found]
  return node, row0 - self._starts[found], found - 1
end

function PageList:row(row0)
  local node, local_row0 = self:locate(row0)
  if not node then
    return nil, local_row0
  end
  return node.page:row(local_row0 + 1)
end

--- Return the half-open logical range [start0, start0 + count).
function PageList:rows(start0, count)
  if not integer(start0) or not integer(count)
      or start0 > self._row_count
      or count > self._row_count - start0 then
    return nil, "row range is outside the list"
  end
  if count == 0 then
    return {}
  end

  local node, local_row0, page_index0 = self:locate(start0)
  if not node then
    return nil, local_row0
  end

  local result = {}
  local remaining = count
  while remaining > 0 do
    local available = node.page.row_count - local_row0
    local take = math.min(available, remaining)
    local page_rows, page_err = node.page:rows(
      local_row0 + 1,
      local_row0 + take
    )
    if not page_rows then
      return nil, page_err
    end
    for _, row in ipairs(page_rows) do
      result[#result + 1] = row
    end

    remaining = remaining - take
    page_index0 = page_index0 + 1
    local_row0 = 0
    if remaining > 0 then
      node = self._pages[page_index0 + 1]
    end
  end
  return result
end

function PageList:stats()
  return {
    row_count = self._row_count,
    page_count = #self._pages,
    decoded_bytes = self._decoded_bytes,
    storage_bytes = self._storage_bytes,
    oversized_pages = self._oversized_pages,
    max_rows = self._max_rows,
    max_bytes = self._max_bytes,
  }
end

--- Check structural metadata and every owned Page without reading through the
--- logical accessor. This is also the invariant hook used by later fuzz tests.
function PageList.validate(list)
  if type(list) ~= "table" then
    return nil, "page list must be a table"
  end

  local page_count, pages_err = dense_table(list._pages, "page list pages")
  if page_count == nil then
    return nil, pages_err
  end
  local start_count, starts_err = dense_table(list._starts, "page list starts")
  if start_count == nil then
    return nil, starts_err
  end
  if start_count ~= page_count then
    return nil, "page and prefix counts differ"
  end
  if not positive_integer(list._max_rows)
      or not positive_integer(list._max_bytes)
      or list._max_bytes > U32_MAX then
    return nil, "page-list limits must be positive integers"
  end
  if not integer(list._row_count)
      or not integer(list._decoded_bytes)
      or not integer(list._storage_bytes)
      or not integer(list._oversized_pages) then
    return nil, "page-list totals must be finite non-negative integers"
  end
  if not positive_integer(list._next_page_id) then
    return nil, "next page id must be a positive integer"
  end

  local expected_start = 0
  local decoded_bytes = 0
  local storage_bytes = 0
  local oversized_pages = 0
  local seen_ids = {}
  local greatest_id = 0

  for index = 1, page_count do
    local node = list._pages[index]
    if type(node) ~= "table" or not positive_integer(node.id) then
      return nil, ("page node %d has an invalid id"):format(index)
    end
    if seen_ids[node.id] then
      return nil, ("page id %d is duplicated"):format(node.id)
    end
    if node.id >= list._next_page_id then
      return nil, ("page id %d is beyond the allocator"):format(node.id)
    end
    seen_ids[node.id] = true
    greatest_id = math.max(greatest_id, node.id)

    if list._starts[index] ~= expected_start then
      return nil, ("page prefix %d is not contiguous"):format(index)
    end
    if type(node.page) ~= "table" or getmetatable(node.page) ~= Page then
      return nil, ("page %d is not an owned Page"):format(node.id)
    end
    local page_ok, page_err = Page.validate(node.page)
    if not page_ok then
      return nil, ("page %d is invalid: %s"):format(node.id, page_err)
    end
    if node.page.max_rows ~= list._max_rows
        or node.page.max_bytes ~= list._max_bytes then
      return nil, ("page %d uses different limits"):format(node.id)
    end

    expected_start = expected_start + node.page.row_count
    decoded_bytes = decoded_bytes + node.page.decoded_bytes
    storage_bytes = storage_bytes + Page.storage_bytes(node.page)
    if node.page.oversized then
      oversized_pages = oversized_pages + 1
    end
  end

  if list._next_page_id <= greatest_id then
    return nil, "next page id does not advance past allocated ids"
  end
  if expected_start ~= list._row_count then
    return nil, "page prefixes do not sum to row_count"
  end
  if decoded_bytes ~= list._decoded_bytes then
    return nil, "page bytes do not sum to decoded_bytes"
  end
  if storage_bytes ~= list._storage_bytes then
    return nil, "page storage does not sum to storage_bytes"
  end
  if oversized_pages ~= list._oversized_pages then
    return nil, "oversized page count is inconsistent"
  end
  return true
end

return PageList
