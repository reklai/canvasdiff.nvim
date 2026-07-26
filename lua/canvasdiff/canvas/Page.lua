local Page = {}
Page.__index = Page

local assert = assert
local ipairs = ipairs
local pairs = pairs
local rawget = rawget
local setmetatable = setmetatable
local type = type
local MATH = {
  floor = math.floor,
  huge = math.huge,
}
local STRING_BYTE = string.byte
local STRING_CHAR = string.char
local STRING_FIND = string.find
local STRING_FORMAT = string.format
local STRING_SUB = string.sub
local TABLE_CONCAT = table.concat

Page.DEFAULT_MAX_ROWS = 256
Page.DEFAULT_MAX_BYTES = 64 * 1024

local U16_MAX = 0xFFFF
local U32_MAX = 0xFFFFFFFF
local RAW_METATABLE = debug.getmetatable
local RAW_EQUAL = rawequal
local OWNED_PAGES = setmetatable({}, { __mode = "k" })
local CREATION_IDS = setmetatable({}, { __mode = "k" })
local CLAIMED_PAGES = setmetatable({}, { __mode = "k" })
local PAGE_OWNERS = setmetatable({}, { __mode = "kv" })
local NODE_PAGES = setmetatable({}, { __mode = "k" })
local PAGE_STATES = setmetatable({}, { __mode = "k" })
local REPRESENTATION_FIELDS = {
  "codec",
  "payload",
  "offsets",
  "offset_width",
  "row_count",
  "decoded_bytes",
  "max_rows",
  "max_bytes",
  "oversized",
}
local next_creation_id = 1

local function own(page)
  local state = { revision = 0 }
  for _, field in ipairs(REPRESENTATION_FIELDS) do
    state[field] = rawget(page, field)
  end

  setmetatable(page, Page)
  OWNED_PAGES[page] = true
  CREATION_IDS[page] = next_creation_id
  PAGE_STATES[page] = state
  next_creation_id = next_creation_id + 1
  return page
end

--- Return a scoped freshness predicate for a constructor transaction.
--- PageList captures this function before any injectable Page.create callback
--- can run, so a callback cannot substitute a Page owned by another node.
local function creation_checkpoint()
  local first_allowed_id = next_creation_id
  return function(page)
    local creation_id = CREATION_IDS[page]
    return creation_id ~= nil and creation_id >= first_allowed_id
  end
end
Page.creation_checkpoint = creation_checkpoint

--- Consume the right to place a Page into a PageList node. Claims never move:
--- abandoned transactions may discard a claimed Page, but no later list can
--- alias a Page that was already associated with another node.
local function claim(page, node)
  if not OWNED_PAGES[page] or not RAW_EQUAL(RAW_METATABLE(page), Page) then
    return nil, "page is not an owned Page"
  end
  if type(node) ~= "table" then
    return nil, "page owner must be a node table"
  end
  if CLAIMED_PAGES[page] then
    return nil, "page is already claimed by a PageList node"
  end
  if NODE_PAGES[node] then
    return nil, "page owner node already has a Page"
  end
  CLAIMED_PAGES[page] = true
  PAGE_OWNERS[page] = node
  NODE_PAGES[node] = page
  return true
end
Page.claim = claim

local function is_owned_by(page, node)
  return RAW_EQUAL(PAGE_OWNERS[page], node)
    and RAW_EQUAL(NODE_PAGES[node], page)
end
Page.is_owned_by = is_owned_by

local function integer(value)
  return type(value) == "number"
    and value >= 0
    and value < MATH.huge
    and value == MATH.floor(value)
end

local function positive_integer(value)
  return integer(value) and value > 0
end

local function encode_u16(value)
  return STRING_CHAR(value % 256, MATH.floor(value / 256) % 256)
end

local function encode_u32(value)
  local low = value % 65536
  local high = MATH.floor(value / 65536)
  return encode_u16(low) .. encode_u16(high)
end

local function encode_offset(value, width)
  if width == 2 then
    return encode_u16(value)
  end
  return encode_u32(value)
end

local function decode_offset(encoded, width, index)
  local at = (index - 1) * width + 1
  local a, b, c, d = STRING_BYTE(encoded, at, at + width - 1)
  if width == 2 then
    return a + b * 256
  end
  return a + b * 256 + c * 65536 + d * 16777216
end

local function options(opts)
  if opts == nil then
    opts = {}
  elseif type(opts) ~= "table" then
    return nil, "page options must be a table"
  end
  local max_rows = opts.max_rows
  if max_rows == nil then
    max_rows = Page.DEFAULT_MAX_ROWS
  end
  local max_bytes = opts.max_bytes
  if max_bytes == nil then
    max_bytes = Page.DEFAULT_MAX_BYTES
  end
  if not positive_integer(max_rows) then
    return nil, "max_rows must be a positive integer"
  end
  if not positive_integer(max_bytes) or max_bytes > U32_MAX then
    return nil, "max_bytes must be a positive 32-bit integer"
  end
  return { max_rows = max_rows, max_bytes = max_bytes }
end

local function sequence_length(rows)
  if type(rows) ~= "table" then
    return nil, "rows must be a sequence"
  end

  local count = 0
  for key in pairs(rows) do
    if not positive_integer(key) then
      return nil, "rows must use consecutive positive integer keys"
    end
    count = count + 1
  end
  if count ~= #rows then
    return nil, "rows must be a dense sequence"
  end
  if count == 0 then
    return nil, "a page must contain at least one row"
  end
  return count
end

--- Validate the private raw representation without trusting any decoded offset.
--- Public fields are only compatible snapshots and are reconciled separately.
local function validate_raw(state)
  local codec = rawget(state, "codec")
  local payload = rawget(state, "payload")
  local offsets = rawget(state, "offsets")
  local row_count = rawget(state, "row_count")
  local offset_width = rawget(state, "offset_width")
  local decoded_bytes = rawget(state, "decoded_bytes")
  local max_rows = rawget(state, "max_rows")
  local max_bytes = rawget(state, "max_bytes")
  local oversized = rawget(state, "oversized")
  local revision = rawget(state, "revision")

  if type(codec) ~= "string" or codec ~= "raw" then
    return nil, "unsupported page codec"
  end
  if type(payload) ~= "string" or type(offsets) ~= "string" then
    return nil, "page payload and offsets must be strings"
  end
  if not positive_integer(row_count) then
    return nil, "page row_count must be a positive integer"
  end
  if type(offset_width) ~= "number"
      or (offset_width ~= 2 and offset_width ~= 4) then
    return nil, "page offset_width must be 2 or 4"
  end
  if not integer(decoded_bytes) or decoded_bytes > U32_MAX then
    return nil, "page decoded_bytes must be a 32-bit integer"
  end
  if #payload ~= decoded_bytes then
    return nil, "page payload length does not match decoded_bytes"
  end
  if #offsets ~= (row_count + 1) * offset_width then
    return nil, "page offset table has the wrong length"
  end
  if not positive_integer(max_rows) or not positive_integer(max_bytes)
      or max_bytes > U32_MAX then
    return nil, "page limits must be positive integers"
  end
  if type(oversized) ~= "boolean" then
    return nil, "page oversized flag must be a boolean"
  end
  if not integer(revision) then
    return nil, "page revision must be a non-negative integer"
  end
  if row_count > max_rows then
    return nil, "page exceeds its row limit"
  end
  if decoded_bytes > max_bytes and row_count ~= 1 then
    return nil, "only a single oversized row may exceed the byte limit"
  end
  if offset_width == 2 and decoded_bytes > U16_MAX then
    return nil, "16-bit offsets cannot address the payload"
  end
  if oversized ~= (decoded_bytes > max_bytes) then
    return nil, "page oversized flag does not match its payload"
  end

  local previous
  for index = 1, row_count + 1 do
    local offset = decode_offset(offsets, offset_width, index)
    if index == 1 and offset ~= 0 then
      return nil, "page offsets must start at zero"
    end
    if previous and offset < previous then
      return nil, "page offsets must be monotonic"
    end
    if offset > decoded_bytes then
      return nil, "page offset exceeds the payload"
    end
    previous = offset
  end
  if previous ~= decoded_bytes then
    return nil, "page offsets must end at decoded_bytes"
  end
  return true
end

--- Reconcile every compatible public snapshot without invoking callbacks, then
--- validate only the private representation that trusted reads consume.
--- Returns true, or nil plus a bounded diagnostic.
local function validate(page)
  if type(page) ~= "table" then
    return nil, "page must be a table"
  end
  if not OWNED_PAGES[page] or not RAW_EQUAL(RAW_METATABLE(page), Page) then
    return nil, "page is not an owned Page"
  end
  local state = PAGE_STATES[page]
  if type(state) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(state), nil) then
    return nil, "page has no private representation state"
  end
  for _, method in ipairs({
    "encoded",
    "byte_range",
    "row",
    "rows",
    "storage_bytes",
    "revision",
  }) do
    if not RAW_EQUAL(rawget(page, method), nil) then
      return nil, "page shadows trusted method " .. method
    end
  end
  for _, field in ipairs(REPRESENTATION_FIELDS) do
    if not RAW_EQUAL(rawget(page, field), rawget(state, field)) then
      return nil,
        "page " .. field .. " snapshot does not match private state"
    end
  end
  return validate_raw(state)
end
Page.validate = validate

--- Build one checked raw page from logical rows. Rows are byte strings without
--- line-feed delimiters; empty rows, carriage returns, NUL, invalid UTF-8, and
--- a single row larger than the ordinary byte target are all preserved.
function Page.create(rows, opts)
  local limits, limits_err = options(opts)
  if not limits then
    return nil, limits_err
  end

  local count, count_err = sequence_length(rows)
  if not count then
    return nil, count_err
  end
  if count > limits.max_rows then
    return nil, "page exceeds its row limit"
  end

  local offsets = { 0 }
  local decoded_bytes = 0
  for index = 1, count do
    local row = rows[index]
    if type(row) ~= "string" then
      return nil, STRING_FORMAT("row %d must be a string", index)
    end
    if STRING_FIND(row, "\n", 1, true) then
      return nil, STRING_FORMAT("row %d contains a line-feed delimiter", index)
    end
    decoded_bytes = decoded_bytes + #row
    if decoded_bytes > U32_MAX then
      return nil, "page payload exceeds the 32-bit offset limit"
    end
    offsets[index + 1] = decoded_bytes
  end
  if decoded_bytes > limits.max_bytes and count ~= 1 then
    return nil, "only a single oversized row may exceed the byte limit"
  end

  local offset_width = decoded_bytes <= U16_MAX and 2 or 4
  local encoded_offsets = {}
  for index, offset in ipairs(offsets) do
    encoded_offsets[index] = encode_offset(offset, offset_width)
  end

  local page = own({
    codec = "raw",
    payload = TABLE_CONCAT(rows),
    offsets = TABLE_CONCAT(encoded_offsets),
    offset_width = offset_width,
    row_count = count,
    decoded_bytes = decoded_bytes,
    max_rows = limits.max_rows,
    max_bytes = limits.max_bytes,
    oversized = decoded_bytes > limits.max_bytes,
  })

  local ok, err = validate(page)
  if not ok then
    return nil, err
  end
  return page
end

function Page.new(rows, opts)
  local page, err = Page.create(rows, opts)
  assert(page, err)
  return page
end

--- Rehydrate a serialized raw representation through the same invariant gate.
--- Strings are immutable, so the returned page cannot share mutable offset
--- storage with the caller.
function Page.from_encoded(spec)
  if type(spec) ~= "table" then
    return nil, "encoded page must be a table"
  end
  local max_rows = spec.max_rows
  if max_rows == nil then
    max_rows = Page.DEFAULT_MAX_ROWS
  end
  local max_bytes = spec.max_bytes
  if max_bytes == nil then
    max_bytes = Page.DEFAULT_MAX_BYTES
  end
  local page = own({
    codec = spec.codec,
    payload = spec.payload,
    offsets = spec.offsets,
    offset_width = spec.offset_width,
    row_count = spec.row_count,
    decoded_bytes = spec.decoded_bytes,
    max_rows = max_rows,
    max_bytes = max_bytes,
    oversized = spec.oversized,
  })
  local ok, err = validate(page)
  if not ok then
    return nil, err
  end
  return page
end

local function encoded(self)
  local state = PAGE_STATES[self]
  if not state then
    return nil, "page has no private representation state"
  end
  return {
    codec = rawget(state, "codec"),
    payload = rawget(state, "payload"),
    offsets = rawget(state, "offsets"),
    offset_width = rawget(state, "offset_width"),
    row_count = rawget(state, "row_count"),
    decoded_bytes = rawget(state, "decoded_bytes"),
    max_rows = rawget(state, "max_rows"),
    max_bytes = rawget(state, "max_bytes"),
    oversized = rawget(state, "oversized"),
  }
end
Page.encoded = encoded

--- Zero-based byte bounds [start, end) for a 1-based logical row.
local function state_byte_range(state, index)
  local row_count = rawget(state, "row_count")
  if not positive_integer(index) or index > row_count then
    return nil, "row index is outside the page"
  end
  local offsets = rawget(state, "offsets")
  local offset_width = rawget(state, "offset_width")
  return decode_offset(offsets, offset_width, index),
    decode_offset(offsets, offset_width, index + 1)
end

local function byte_range(self, index)
  local state = PAGE_STATES[self]
  if not state then
    return nil, "page has no private representation state"
  end
  return state_byte_range(state, index)
end
Page.byte_range = byte_range

local function state_row(state, index)
  local start_byte, end_byte = state_byte_range(state, index)
  if start_byte == nil then
    return nil, end_byte
  end
  return STRING_SUB(rawget(state, "payload"), start_byte + 1, end_byte)
end

local function row(self, index)
  local state = PAGE_STATES[self]
  if not state then
    return nil, "page has no private representation state"
  end
  return state_row(state, index)
end
Page.row = row

local function rows(self, first, last)
  local state = PAGE_STATES[self]
  if not state then
    return nil, "page has no private representation state"
  end
  first = first or 1
  local row_count = rawget(state, "row_count")
  last = last or row_count
  if not positive_integer(first) or not positive_integer(last)
      or first > last or last > row_count then
    return nil, "row range is outside the page"
  end
  local result = {}
  for index = first, last do
    result[#result + 1] = assert(state_row(state, index))
  end
  return result
end
Page.rows = rows

local function storage_bytes(self)
  local state = PAGE_STATES[self]
  if not state then
    return nil, "page has no private representation state"
  end
  return #rawget(state, "offsets") + #rawget(state, "payload")
end
Page.storage_bytes = storage_bytes

local function revision(self)
  local state = PAGE_STATES[self]
  if not state then
    return nil, "page has no private representation state"
  end
  return rawget(state, "revision")
end
Page.revision = revision

return Page
