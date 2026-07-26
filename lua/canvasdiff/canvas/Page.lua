local Page = {}
Page.__index = Page

Page.DEFAULT_MAX_ROWS = 256
Page.DEFAULT_MAX_BYTES = 64 * 1024

local U16_MAX = 0xFFFF
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

local function encode_u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function encode_u32(value)
  local low = value % 65536
  local high = math.floor(value / 65536)
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
  local a, b, c, d = string.byte(encoded, at, at + width - 1)
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

--- Validate a raw page representation without trusting any decoded offset.
--- Returns true, or nil plus a bounded diagnostic.
function Page.validate(page)
  if type(page) ~= "table" then
    return nil, "page must be a table"
  end
  if page.codec ~= "raw" then
    return nil, "unsupported page codec"
  end
  if type(page.payload) ~= "string" or type(page.offsets) ~= "string" then
    return nil, "page payload and offsets must be strings"
  end
  if not positive_integer(page.row_count) then
    return nil, "page row_count must be a positive integer"
  end
  if page.offset_width ~= 2 and page.offset_width ~= 4 then
    return nil, "page offset_width must be 2 or 4"
  end
  if not integer(page.decoded_bytes) or page.decoded_bytes > U32_MAX then
    return nil, "page decoded_bytes must be a 32-bit integer"
  end
  if #page.payload ~= page.decoded_bytes then
    return nil, "page payload length does not match decoded_bytes"
  end
  if #page.offsets ~= (page.row_count + 1) * page.offset_width then
    return nil, "page offset table has the wrong length"
  end
  if not positive_integer(page.max_rows) or not positive_integer(page.max_bytes)
      or page.max_bytes > U32_MAX then
    return nil, "page limits must be positive integers"
  end
  if type(page.oversized) ~= "boolean" then
    return nil, "page oversized flag must be a boolean"
  end
  if page.row_count > page.max_rows then
    return nil, "page exceeds its row limit"
  end
  if page.decoded_bytes > page.max_bytes and page.row_count ~= 1 then
    return nil, "only a single oversized row may exceed the byte limit"
  end
  if page.offset_width == 2 and page.decoded_bytes > U16_MAX then
    return nil, "16-bit offsets cannot address the payload"
  end
  if page.oversized ~= (page.decoded_bytes > page.max_bytes) then
    return nil, "page oversized flag does not match its payload"
  end

  local previous
  for index = 1, page.row_count + 1 do
    local offset = decode_offset(page.offsets, page.offset_width, index)
    if index == 1 and offset ~= 0 then
      return nil, "page offsets must start at zero"
    end
    if previous and offset < previous then
      return nil, "page offsets must be monotonic"
    end
    if offset > page.decoded_bytes then
      return nil, "page offset exceeds the payload"
    end
    previous = offset
  end
  if previous ~= page.decoded_bytes then
    return nil, "page offsets must end at decoded_bytes"
  end
  return true
end

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
      return nil, ("row %d must be a string"):format(index)
    end
    if row:find("\n", 1, true) then
      return nil, ("row %d contains a line-feed delimiter"):format(index)
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

  local page = setmetatable({
    codec = "raw",
    payload = table.concat(rows),
    offsets = table.concat(encoded_offsets),
    offset_width = offset_width,
    row_count = count,
    decoded_bytes = decoded_bytes,
    max_rows = limits.max_rows,
    max_bytes = limits.max_bytes,
    oversized = decoded_bytes > limits.max_bytes,
  }, Page)

  local ok, err = Page.validate(page)
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
  local page = setmetatable({
    codec = spec.codec,
    payload = spec.payload,
    offsets = spec.offsets,
    offset_width = spec.offset_width,
    row_count = spec.row_count,
    decoded_bytes = spec.decoded_bytes,
    max_rows = max_rows,
    max_bytes = max_bytes,
    oversized = spec.oversized,
  }, Page)
  local ok, err = Page.validate(page)
  if not ok then
    return nil, err
  end
  return page
end

function Page:encoded()
  return {
    codec = self.codec,
    payload = self.payload,
    offsets = self.offsets,
    offset_width = self.offset_width,
    row_count = self.row_count,
    decoded_bytes = self.decoded_bytes,
    max_rows = self.max_rows,
    max_bytes = self.max_bytes,
    oversized = self.oversized,
  }
end

--- Zero-based byte bounds [start, end) for a 1-based logical row.
function Page:byte_range(index)
  if not positive_integer(index) or index > self.row_count then
    return nil, "row index is outside the page"
  end
  return decode_offset(self.offsets, self.offset_width, index),
    decode_offset(self.offsets, self.offset_width, index + 1)
end

function Page:row(index)
  local start_byte, end_byte = self:byte_range(index)
  if start_byte == nil then
    return nil, end_byte
  end
  return self.payload:sub(start_byte + 1, end_byte)
end

function Page:rows(first, last)
  first = first or 1
  last = last or self.row_count
  if not positive_integer(first) or not positive_integer(last)
      or first > last or last > self.row_count then
    return nil, "row range is outside the page"
  end
  local rows = {}
  for index = first, last do
    rows[#rows + 1] = assert(self:row(index))
  end
  return rows
end

function Page:storage_bytes()
  return #self.offsets + #self.payload
end

return Page
