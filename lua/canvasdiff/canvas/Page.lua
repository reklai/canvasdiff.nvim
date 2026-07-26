local Page = {}
Page.__index = Page

local assert = assert
local ipairs = ipairs
local next = next
local pcall = pcall
local rawget = rawget
local rawset = rawset
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
local MAX_SAFE_INTEGER = 9007199254740991
local RAW_METATABLE = debug.getmetatable
local RAW_EQUAL = rawequal
local OWNED_PAGES = setmetatable({}, { __mode = "k" })
local CREATION_IDS = setmetatable({}, { __mode = "k" })
local CLAIMED_PAGES = setmetatable({}, { __mode = "k" })
local PAGE_OWNERS = setmetatable({}, { __mode = "kv" })
local NODE_PAGES = setmetatable({}, { __mode = "k" })
local PAGE_REPRESENTATION_CAPS = setmetatable({}, { __mode = "k" })
local PAGE_STATES = setmetatable({}, { __mode = "k" })
local PAGE_QUARANTINES = setmetatable({}, { __mode = "k" })
local COLD_CANDIDATES = setmetatable({}, { __mode = "k" })
local PAGE_CANDIDATES = setmetatable({}, { __mode = "k" })
local RAW_VIEW_STATES = setmetatable({}, { __mode = "k" })
local PAGE_RAW_VIEWS = setmetatable({}, { __mode = "k" })
local ColdCandidate = {}
ColdCandidate.__metatable = false
local RepresentationCapability = {}
RepresentationCapability.__metatable = false
local RawView = {}
RawView.__index = RawView
RawView.__metatable = false
local REPRESENTATION_FIELDS = {
  "codec",
  "payload",
  "offsets",
  "crc32",
  "offset_width",
  "row_count",
  "decoded_bytes",
  "max_rows",
  "max_bytes",
  "oversized",
}
local REPRESENTATION_FIELD_SET = {}
for _, field in ipairs(REPRESENTATION_FIELDS) do
  REPRESENTATION_FIELD_SET[field] = true
end
local next_creation_id = 1

local function handle_set(registry, page)
  local handles = rawget(registry, page)
  if not handles then
    handles = setmetatable({}, { __mode = "k" })
    rawset(registry, page, handles)
  end
  return handles
end

local invalidate_candidates
local invalidate_raw_views

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
  if RAW_EQUAL(page, node) then
    return nil, "page cannot own itself as a PageList node"
  end
  if CLAIMED_PAGES[page] then
    return nil, "page is already claimed by a PageList node"
  end
  if NODE_PAGES[node] then
    return nil, "page owner node already has a Page"
  end
  local capability = setmetatable({}, RepresentationCapability)
  CLAIMED_PAGES[page] = true
  PAGE_OWNERS[page] = node
  NODE_PAGES[node] = true
  PAGE_REPRESENTATION_CAPS[page] = capability
  invalidate_candidates(page)
  invalidate_raw_views(page)
  return true, capability
end
Page.claim = claim

local function is_owned_by(page, node)
  if type(page) ~= "table" or type(node) ~= "table" then
    return false
  end
  local owner = rawget(PAGE_OWNERS, page)
  return not RAW_EQUAL(owner, nil)
    and RAW_EQUAL(owner, node)
    and RAW_EQUAL(rawget(NODE_PAGES, node), true)
end
Page.is_owned_by = is_owned_by

local function representation_authorized(page, offered)
  local required = rawget(PAGE_REPRESENTATION_CAPS, page)
  if RAW_EQUAL(required, nil) then
    return true
  end
  if not RAW_EQUAL(required, offered) then
    return nil, "claimed Page representation capability is required"
  end
  return true
end

local function is_authorized(page, node, capability)
  if not is_owned_by(page, node) then
    return nil, "page is not owned by this PageList node"
  end
  return representation_authorized(page, capability)
end
Page.is_authorized = is_authorized

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
  if RAW_EQUAL(opts, nil) then
    opts = {}
  elseif type(opts) ~= "table" then
    return nil, "page options must be a table"
  end
  local max_rows = rawget(opts, "max_rows")
  if RAW_EQUAL(max_rows, nil) then
    max_rows = Page.DEFAULT_MAX_ROWS
  end
  local max_bytes = rawget(opts, "max_bytes")
  if RAW_EQUAL(max_bytes, nil) then
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

local function sequence_snapshot(rows)
  if type(rows) ~= "table" then
    return nil, "rows must be a sequence"
  end

  local count = 0
  local last_index = 0
  for key in next, rows do
    if not positive_integer(key) then
      return nil, "rows must use consecutive positive integer keys"
    end
    count = count + 1
    if key > last_index then
      last_index = key
    end
  end
  if count == 0 then
    return nil, "a page must contain at least one row"
  end
  if count ~= last_index then
    return nil, "rows must be a dense sequence"
  end

  local snapshot = {}
  for index = 1, count do
    snapshot[index] = rawget(rows, index)
  end
  return snapshot, count
end

local function validate_metadata(state)
  local row_count = rawget(state, "row_count")
  local offset_width = rawget(state, "offset_width")
  local decoded_bytes = rawget(state, "decoded_bytes")
  local max_rows = rawget(state, "max_rows")
  local max_bytes = rawget(state, "max_bytes")
  local oversized = rawget(state, "oversized")
  local revision = rawget(state, "revision")

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
  if not positive_integer(max_rows) or not positive_integer(max_bytes)
      or max_bytes > U32_MAX then
    return nil, "page limits must be positive integers"
  end
  if type(oversized) ~= "boolean" then
    return nil, "page oversized flag must be a boolean"
  end
  if not integer(revision) or revision > MAX_SAFE_INTEGER then
    return nil, "page revision must be a safe non-negative integer"
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
  return true
end

--- Validate the private raw representation without trusting any decoded offset.
--- Public fields are only compatible snapshots and are reconciled separately.
local function validate_raw(state)
  local metadata_ok, metadata_err = validate_metadata(state)
  if not metadata_ok then
    return nil, metadata_err
  end

  local codec = rawget(state, "codec")
  local payload = rawget(state, "payload")
  local offsets = rawget(state, "offsets")
  local row_count = rawget(state, "row_count")
  local offset_width = rawget(state, "offset_width")
  local decoded_bytes = rawget(state, "decoded_bytes")

  if type(codec) ~= "string" or codec ~= "raw" then
    return nil, "unsupported page codec"
  end
  if type(payload) ~= "string" or type(offsets) ~= "string" then
    return nil, "page payload and offsets must be strings"
  end
  if not RAW_EQUAL(rawget(state, "crc32"), nil) then
    return nil, "raw pages must not carry a cold checksum"
  end
  if #payload ~= decoded_bytes then
    return nil, "page payload length does not match decoded_bytes"
  end
  if #offsets ~= (row_count + 1) * offset_width then
    return nil, "page offset table has the wrong length"
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

--- Cold state deliberately retains no decoded offsets or payload. Its block is
--- authenticated before offsets are ever trusted again.
local function validate_cold(state)
  local metadata_ok, metadata_err = validate_metadata(state)
  if not metadata_ok then
    return nil, metadata_err
  end

  local codec = rawget(state, "codec")
  local block = rawget(state, "payload")
  local offsets = rawget(state, "offsets")
  local checksum = rawget(state, "crc32")
  if type(codec) ~= "string" or codec == "" or codec == "raw" then
    return nil, "cold page codec must be a non-raw string"
  end
  if type(block) ~= "string" then
    return nil, "cold page block must be a string"
  end
  if type(offsets) ~= "string" or offsets ~= "" then
    return nil, "cold page offsets must not remain resident"
  end
  if not integer(checksum) or checksum > U32_MAX then
    return nil, "cold page crc32 must be an unsigned 32-bit integer"
  end

  local offset_bytes =
    (rawget(state, "row_count") + 1) * rawget(state, "offset_width")
  local raw_body_bytes = offset_bytes + rawget(state, "decoded_bytes")
  if not integer(offset_bytes)
      or not integer(raw_body_bytes)
      or raw_body_bytes > MAX_SAFE_INTEGER then
    return nil, "cold page decoded body size is unsafe"
  end
  if #block >= raw_body_bytes then
    return nil, "cold page block is not smaller than its raw body"
  end
  return true
end

local function validate_private_state(state)
  local codec = rawget(state, "codec")
  if type(codec) ~= "string" then
    return nil, "unsupported page codec"
  end
  if codec == "raw" then
    return validate_raw(state)
  end
  return validate_cold(state)
end

local function private_state_for(page)
  if type(page) ~= "table" then
    return nil, "page must be a table"
  end
  if not rawget(OWNED_PAGES, page)
      or not RAW_EQUAL(RAW_METATABLE(page), Page) then
    return nil, "page is not an owned Page"
  end
  local state = rawget(PAGE_STATES, page)
  if type(state) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(state), nil) then
    return nil, "page has no private representation state"
  end
  return state
end

--- Reconcile every compatible public snapshot without invoking callbacks, then
--- validate only the private representation that trusted reads consume.
--- Returns true, or nil plus a bounded diagnostic.
local function validate(page)
  local state, state_err = private_state_for(page)
  if not state then
    return nil, state_err
  end
  for key in next, page do
    if not rawget(REPRESENTATION_FIELD_SET, key) then
      if type(key) == "string" and type(rawget(Page, key)) == "function" then
        return nil, "page shadows trusted method " .. key
      end
      return nil, "page has an unexpected public field"
    end
  end
  for _, field in ipairs(REPRESENTATION_FIELDS) do
    if not RAW_EQUAL(rawget(page, field), rawget(state, field)) then
      return nil,
        "page " .. field .. " snapshot does not match private state"
    end
  end
  return validate_private_state(state)
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

  local snapshot, count_or_err = sequence_snapshot(rows)
  if not snapshot then
    return nil, count_or_err
  end
  local count = count_or_err
  if count > limits.max_rows then
    return nil, "page exceeds its row limit"
  end

  local offsets = { 0 }
  local decoded_bytes = 0
  for index = 1, count do
    local row = snapshot[index]
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
    payload = TABLE_CONCAT(snapshot),
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
  local codec = rawget(spec, "codec")
  if type(codec) ~= "string" or codec ~= "raw" then
    return nil, "unsupported page codec"
  end
  local max_rows = rawget(spec, "max_rows")
  if RAW_EQUAL(max_rows, nil) then
    max_rows = Page.DEFAULT_MAX_ROWS
  end
  local max_bytes = rawget(spec, "max_bytes")
  if RAW_EQUAL(max_bytes, nil) then
    max_bytes = Page.DEFAULT_MAX_BYTES
  end
  local page = own({
    codec = codec,
    payload = rawget(spec, "payload"),
    offsets = rawget(spec, "offsets"),
    crc32 = nil,
    offset_width = rawget(spec, "offset_width"),
    row_count = rawget(spec, "row_count"),
    decoded_bytes = rawget(spec, "decoded_bytes"),
    max_rows = max_rows,
    max_bytes = max_bytes,
    oversized = rawget(spec, "oversized"),
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
    crc32 = rawget(state, "crc32"),
    offset_width = rawget(state, "offset_width"),
    row_count = rawget(state, "row_count"),
    decoded_bytes = rawget(state, "decoded_bytes"),
    max_rows = rawget(state, "max_rows"),
    max_bytes = rawget(state, "max_bytes"),
    oversized = rawget(state, "oversized"),
  }
end
Page.encoded = encoded

local function raw_body_bytes(state)
  return (rawget(state, "row_count") + 1)
    * rawget(state, "offset_width")
    + rawget(state, "decoded_bytes")
end

local function state_storage_bytes(state)
  if rawget(state, "codec") == "raw" then
    return #rawget(state, "offsets") + #rawget(state, "payload")
  end
  return #rawget(state, "payload")
end

local function state_is_quarantined(page, state)
  return RAW_EQUAL(rawget(PAGE_QUARANTINES, page), state)
end

--- Return only trusted scalar metadata. No public Page field is consulted.
local function metadata(self)
  local state, state_err = private_state_for(self)
  if not state then
    return nil, state_err
  end
  local state_ok, validation_err = validate_private_state(state)
  if not state_ok then
    return nil, validation_err
  end
  local codec = rawget(state, "codec")
  local storage = state_storage_bytes(state)
  local restore = raw_body_bytes(state)
  return {
    kind = codec == "raw" and "raw" or "cold",
    codec = codec,
    row_count = rawget(state, "row_count"),
    offset_width = rawget(state, "offset_width"),
    decoded_bytes = rawget(state, "decoded_bytes"),
    max_rows = rawget(state, "max_rows"),
    max_bytes = rawget(state, "max_bytes"),
    oversized = rawget(state, "oversized"),
    storage_bytes = storage,
    resident_bytes = storage,
    restore_bytes = restore,
    view_bytes = codec == "raw" and 0 or restore,
    revision = rawget(state, "revision"),
    quarantined = state_is_quarantined(self, state),
  }
end
Page.metadata = metadata

local function expected_revision(state, expected)
  if not integer(expected) or expected > MAX_SAFE_INTEGER then
    return nil, "expected page revision must be a safe non-negative integer"
  end
  if rawget(state, "revision") ~= expected then
    return nil, "page revision is stale"
  end
  return true
end

local function protected_callback(operation, callback, ...)
  local ok, value = pcall(callback, ...)
  if not ok then
    return nil, nil, "page " .. operation .. " callback failed"
  end
  return true, value
end

local function preparation_fence(page, state, revision, capability)
  if not RAW_EQUAL(rawget(PAGE_STATES, page), state)
      or rawget(state, "revision") ~= revision then
    return nil, "page changed during cold preparation"
  end
  local authorized = representation_authorized(page, capability)
  if not authorized then
    return nil, "page changed during cold preparation"
  end
  local page_ok = validate(page)
  if not page_ok then
    return nil, "page changed during cold preparation"
  end
  return true
end

local function cold_options(opts, operation)
  if type(opts) ~= "table" then
    return nil, "cold " .. operation .. " options must be a table"
  end
  local codec = rawget(opts, "codec")
  local callback = rawget(opts, operation)
  local crc32 = rawget(opts, "crc32")
  if type(codec) ~= "string" or codec == "" or codec == "raw" then
    return nil, "cold codec must be a non-raw string"
  end
  if type(callback) ~= "function" then
    return nil, "cold " .. operation .. " callback must be a function"
  end
  if type(crc32) ~= "function" then
    return nil, "cold crc32 callback must be a function"
  end
  return {
    codec = codec,
    callback = callback,
    crc32 = crc32,
  }
end

--- Prepare an authenticated cold candidate without mutating the Page.
---
--- `encode` receives the canonical `offsets .. payload` body and a destination
--- budget one byte smaller than that body. The returned candidate is opaque and
--- can only be published back to this exact Page revision.
local function prepare_cold(self, expected, opts, capability)
  local page_ok, page_err = validate(self)
  if not page_ok then
    return nil, page_err
  end
  local authorized, authorization_err =
    representation_authorized(self, capability)
  if not authorized then
    return nil, authorization_err
  end
  local state = rawget(PAGE_STATES, self)
  local revision_ok, revision_err = expected_revision(state, expected)
  if not revision_ok then
    return nil, revision_err
  end
  if rawget(state, "codec") ~= "raw" then
    return nil, "only a raw page can prepare a cold candidate"
  end
  if expected >= MAX_SAFE_INTEGER then
    return nil, "page revision is exhausted"
  end

  local configured, options_err = cold_options(opts, "encode")
  if not configured then
    return nil, options_err
  end

  local body_ok, body = pcall(function()
    return rawget(state, "offsets") .. rawget(state, "payload")
  end)
  if not body_ok then
    return nil, "could not allocate the canonical raw page body"
  end
  local body_bytes = #body
  local called, block, callback_err = protected_callback(
    "encode",
    configured.callback,
    body,
    body_bytes - 1
  )
  local fence_ok, fence_err =
    preparation_fence(self, state, expected, capability)
  if not fence_ok then
    return nil, fence_err
  end
  if not called then
    return nil, callback_err
  end
  if RAW_EQUAL(block, false) then
    return false, "cold codec declined the raw body"
  end
  if RAW_EQUAL(block, nil) then
    return nil, "page encode callback failed"
  end
  if type(block) ~= "string" then
    return nil, "page encode callback returned a non-string block"
  end
  if #block >= body_bytes then
    return false, "cold block is not smaller than the raw body"
  end

  local checksum_called, checksum, checksum_err = protected_callback(
    "crc32",
    configured.crc32,
    body
  )
  fence_ok, fence_err = preparation_fence(
    self,
    state,
    expected,
    capability
  )
  if not fence_ok then
    return nil, fence_err
  end
  if not checksum_called then
    return nil, checksum_err
  end
  if not integer(checksum) or checksum > U32_MAX then
    return nil, "page crc32 callback returned an invalid checksum"
  end

  local cold_state = {
    codec = configured.codec,
    payload = block,
    offsets = "",
    crc32 = checksum,
    offset_width = rawget(state, "offset_width"),
    row_count = rawget(state, "row_count"),
    decoded_bytes = rawget(state, "decoded_bytes"),
    max_rows = rawget(state, "max_rows"),
    max_bytes = rawget(state, "max_bytes"),
    oversized = rawget(state, "oversized"),
    revision = expected + 1,
  }
  local cold_ok, cold_err = validate_cold(cold_state)
  if not cold_ok then
    return nil, cold_err
  end

  fence_ok, fence_err = preparation_fence(
    self,
    state,
    expected,
    capability
  )
  if not fence_ok then
    return nil, fence_err
  end
  local candidate = setmetatable({}, ColdCandidate)
  rawset(COLD_CANDIDATES, candidate, {
    page = self,
    source_state = state,
    source_revision = expected,
    cold_state = cold_state,
    raw_bytes = body_bytes,
    storage_bytes = #block,
    crc32 = checksum,
    codec = configured.codec,
  })
  rawset(handle_set(PAGE_CANDIDATES, self), candidate, true)
  return candidate
end
Page.prepare_cold = prepare_cold

local function drop_candidate(candidate, record)
  record = record or rawget(COLD_CANDIDATES, candidate)
  rawset(COLD_CANDIDATES, candidate, nil)
  if type(record) == "table" then
    local page = rawget(record, "page")
    local candidates = rawget(PAGE_CANDIDATES, page)
    if candidates then
      rawset(candidates, candidate, nil)
    end
  end
end

invalidate_candidates = function(page)
  local candidates = rawget(PAGE_CANDIDATES, page)
  if not candidates then
    return
  end
  while true do
    local candidate = next(candidates)
    if not candidate then
      break
    end
    drop_candidate(candidate)
  end
  rawset(PAGE_CANDIDATES, page, nil)
end

local function candidate_record(candidate)
  if type(candidate) ~= "table" then
    return nil, "cold candidate is not owned by Page"
  end
  if not RAW_EQUAL(RAW_METATABLE(candidate), ColdCandidate) then
    drop_candidate(candidate)
    return nil, "cold candidate is not owned by Page"
  end
  local record = rawget(COLD_CANDIDATES, candidate)
  if type(record) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(record), nil) then
    return nil, "cold candidate is no longer valid"
  end
  if not RAW_EQUAL(next(candidate), nil) then
    drop_candidate(candidate, record)
    return nil, "cold candidate has unexpected public fields"
  end
  local page = rawget(record, "page")
  local source_state = rawget(record, "source_state")
  if not RAW_EQUAL(rawget(PAGE_STATES, page), source_state)
      or rawget(source_state, "revision")
        ~= rawget(record, "source_revision") then
    drop_candidate(candidate, record)
    return nil, "cold candidate was prepared from a stale Page revision"
  end
  return record
end

local function candidate_metadata(candidate)
  local record, record_err = candidate_record(candidate)
  if not record then
    return nil, record_err
  end
  return {
    codec = rawget(record, "codec"),
    storage_bytes = rawget(record, "storage_bytes"),
    raw_bytes = rawget(record, "raw_bytes"),
    crc32 = rawget(record, "crc32"),
  }
end
Page.candidate_metadata = candidate_metadata

local function discard_candidate(candidate)
  if type(candidate) ~= "table" then
    return nil, "cold candidate is not owned by Page"
  end
  local record = rawget(COLD_CANDIDATES, candidate)
  if not record then
    if not RAW_EQUAL(RAW_METATABLE(candidate), ColdCandidate) then
      return nil, "cold candidate is not owned by Page"
    end
    return false, "cold candidate is no longer valid"
  end
  drop_candidate(candidate, record)
  return true
end
Page.discard_candidate = discard_candidate

--- Publish a prepared candidate without invoking callbacks.
---
--- On success returns true, old storage bytes, new storage bytes, and the new
--- Page revision. Cross-Page, consumed, or stale candidates cannot publish.
local function publish_cold(self, candidate, expected, capability)
  local record, record_err = candidate_record(candidate)
  if not record then
    return nil, record_err
  end
  if not RAW_EQUAL(rawget(record, "page"), self) then
    return nil, "cold candidate belongs to another Page"
  end
  local authorized, authorization_err =
    representation_authorized(self, capability)
  if not authorized then
    return nil, authorization_err
  end
  local state, state_err = private_state_for(self)
  if not state then
    return nil, state_err
  end
  local revision_ok, revision_err = expected_revision(state, expected)
  if not revision_ok then
    return nil, revision_err
  end
  if expected ~= rawget(record, "source_revision")
      or not RAW_EQUAL(state, rawget(record, "source_state")) then
    return nil, "cold candidate was prepared from a stale Page revision"
  end
  local page_ok, page_err = validate(self)
  if not page_ok then
    return nil, page_err
  end
  local cold_state = rawget(record, "cold_state")
  local cold_ok, cold_err = validate_cold(cold_state)
  if not cold_ok then
    return nil, cold_err
  end

  local old_storage = state_storage_bytes(state)
  local new_storage = state_storage_bytes(cold_state)
  rawset(PAGE_STATES, self, cold_state)
  rawset(PAGE_QUARANTINES, self, nil)
  for _, field in ipairs(REPRESENTATION_FIELDS) do
    rawset(self, field, rawget(cold_state, field))
  end
  invalidate_candidates(self)
  invalidate_raw_views(self)
  return true, old_storage, new_storage, rawget(cold_state, "revision")
end
Page.publish_cold = publish_cold

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

local function resident_raw_state(self)
  local state, state_err = private_state_for(self)
  if not state then
    return nil, state_err
  end
  if rawget(state, "codec") ~= "raw" then
    if state_is_quarantined(self, state) then
      return nil, "page revision is quarantined"
    end
    return nil, "page rows are not resident"
  end
  return state
end

local function byte_range(self, index)
  local state, state_err = resident_raw_state(self)
  if not state then
    return nil, state_err
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
  local state, state_err = resident_raw_state(self)
  if not state then
    return nil, state_err
  end
  return state_row(state, index)
end
Page.row = row

local function state_rows(state, first, last)
  if RAW_EQUAL(first, nil) then
    first = 1
  end
  local row_count = rawget(state, "row_count")
  if RAW_EQUAL(last, nil) then
    last = row_count
  end
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

local function rows(self, first, last)
  local state, state_err = resident_raw_state(self)
  if not state then
    return nil, state_err
  end
  return state_rows(state, first, last)
end
Page.rows = rows

local function own_raw_view(page, source_state, raw_state)
  local view = setmetatable({}, RawView)
  local source_kind =
    rawget(source_state, "codec") == "raw" and "raw" or "cold-restored"
  rawset(RAW_VIEW_STATES, view, {
    page = page,
    source_state = source_state,
    revision = rawget(source_state, "revision"),
    raw_state = raw_state,
    kind = source_kind,
    view_bytes = source_kind == "raw" and 0 or raw_body_bytes(raw_state),
  })
  rawset(handle_set(PAGE_RAW_VIEWS, page), view, true)
  return view
end

local function drop_raw_view(view, record)
  record = record or rawget(RAW_VIEW_STATES, view)
  rawset(RAW_VIEW_STATES, view, nil)
  if type(record) == "table" then
    local page = rawget(record, "page")
    local views = rawget(PAGE_RAW_VIEWS, page)
    if views then
      rawset(views, view, nil)
    end
  end
end

invalidate_raw_views = function(page)
  local views = rawget(PAGE_RAW_VIEWS, page)
  if not views then
    return
  end
  while true do
    local view = next(views)
    if not view then
      break
    end
    drop_raw_view(view)
  end
  rawset(PAGE_RAW_VIEWS, page, nil)
end

local function release_view(view)
  if type(view) ~= "table" then
    return nil, "raw view is not owned by Page"
  end
  local record = rawget(RAW_VIEW_STATES, view)
  if not record then
    if not RAW_EQUAL(RAW_METATABLE(view), RawView) then
      return nil, "raw view is not owned by Page"
    end
    return false, "raw view is no longer valid"
  end
  drop_raw_view(view, record)
  return true
end
Page.release_view = release_view

local function raw_view_record(view)
  if type(view) ~= "table" then
    return nil, "raw view is not owned by Page"
  end
  if not RAW_EQUAL(RAW_METATABLE(view), RawView) then
    drop_raw_view(view)
    return nil, "raw view is not owned by Page"
  end
  if not RAW_EQUAL(next(view), nil) then
    drop_raw_view(view)
    return nil, "raw view has unexpected public fields"
  end
  local record = rawget(RAW_VIEW_STATES, view)
  if type(record) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(record), nil) then
    return nil, "raw view is no longer valid"
  end
  local page = rawget(record, "page")
  local source_state = rawget(record, "source_state")
  if not RAW_EQUAL(rawget(PAGE_STATES, page), source_state)
      or rawget(source_state, "revision") ~= rawget(record, "revision") then
    drop_raw_view(view, record)
    return nil, "raw view belongs to a stale Page revision"
  end
  if state_is_quarantined(page, source_state) then
    drop_raw_view(view, record)
    return nil, "page revision is quarantined"
  end
  return record
end

local function raw_view_state(view)
  local record, record_err = raw_view_record(view)
  if not record then
    return nil, record_err
  end
  local state = rawget(record, "raw_state")
  if type(state) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(state), nil) then
    return nil, "raw view is no longer valid"
  end
  return state
end

local function view_metadata(view)
  local record, record_err = raw_view_record(view)
  if not record then
    return nil, record_err
  end
  local state = rawget(record, "raw_state")
  return {
    kind = rawget(record, "kind"),
    revision = rawget(record, "revision"),
    row_count = rawget(state, "row_count"),
    view_bytes = rawget(record, "view_bytes"),
  }
end
Page.view_metadata = view_metadata

local function validate_view(view, page, revision)
  local record, record_err = raw_view_record(view)
  if not record then
    return nil, record_err
  end
  if not integer(revision) or revision > MAX_SAFE_INTEGER then
    return nil, "raw view revision must be a safe non-negative integer"
  end
  if not RAW_EQUAL(rawget(record, "page"), page)
      or rawget(record, "revision") ~= revision then
    return nil, "raw view provenance does not match the Page revision"
  end
  return true
end
Page.validate_view = validate_view

local function view_byte_range(view, index)
  local state, state_err = raw_view_state(view)
  if not state then
    return nil, state_err
  end
  return state_byte_range(state, index)
end
Page.view_byte_range = view_byte_range

local function view_row(view, index)
  local state, state_err = raw_view_state(view)
  if not state then
    return nil, state_err
  end
  return state_row(state, index)
end
Page.view_row = view_row

local function view_rows(view, first, last)
  local state, state_err = raw_view_state(view)
  if not state then
    return nil, state_err
  end
  return state_rows(state, first, last)
end
Page.view_rows = view_rows

local function restore_fence(page, state, expected, capability)
  if not RAW_EQUAL(rawget(PAGE_STATES, page), state)
      or rawget(state, "revision") ~= expected then
    return nil, "page changed during cold restore"
  end
  local authorized = representation_authorized(page, capability)
  if not authorized then
    return nil, "page changed during cold restore"
  end
  if state_is_quarantined(page, state) then
    return nil, "page revision is quarantined"
  end
  local page_ok = validate(page)
  if not page_ok then
    return nil, "page changed during cold restore"
  end
  return true
end

local function quarantine_current(
  page,
  state,
  expected,
  capability,
  reason
)
  local fence_ok, fence_err =
    restore_fence(page, state, expected, capability)
  if not fence_ok then
    return nil, fence_err
  end
  rawset(PAGE_QUARANTINES, page, state)
  invalidate_raw_views(page)
  return nil, reason
end

--- Return an opaque raw snapshot for one exact Page revision.
---
--- Raw pages require no options and invoke no callbacks. Cold pages require a
--- matching codec decoder and CRC-32 callback; successful restore never mutates
--- the cold Page. Any decode, authentication, or offset failure quarantines only
--- the exact unchanged state that was examined.
local function read_view(self, expected, opts, capability)
  local state, state_err = private_state_for(self)
  if not state then
    return nil, state_err
  end
  local authorized, authorization_err =
    representation_authorized(self, capability)
  if not authorized then
    return nil, authorization_err
  end
  local state_ok, validation_err = validate_private_state(state)
  if not state_ok then
    return nil, validation_err
  end
  local revision_ok, revision_err = expected_revision(state, expected)
  if not revision_ok then
    return nil, revision_err
  end
  if rawget(state, "codec") == "raw" then
    return own_raw_view(self, state, state)
  end
  if state_is_quarantined(self, state) then
    return nil, "page revision is quarantined"
  end
  local page_ok = validate(self)
  if not page_ok then
    return nil, "page changed during cold restore"
  end

  local configured, options_err = cold_options(opts, "decode")
  if not configured then
    return nil, options_err
  end
  if configured.codec ~= rawget(state, "codec") then
    return nil, "cold decoder does not match the page codec"
  end

  local expected_bytes = raw_body_bytes(state)
  local called, decoded = protected_callback(
    "decode",
    configured.callback,
    rawget(state, "payload"),
    expected_bytes
  )
  local fence_ok, fence_err =
    restore_fence(self, state, expected, capability)
  if not fence_ok then
    return nil, fence_err
  end
  if not called
      or RAW_EQUAL(decoded, nil)
      or RAW_EQUAL(decoded, false)
      or type(decoded) ~= "string" then
    return quarantine_current(
      self,
      state,
      expected,
      capability,
      "cold page decode failed"
    )
  end
  if #decoded ~= expected_bytes then
    return quarantine_current(
      self,
      state,
      expected,
      capability,
      "cold page decoded size mismatch"
    )
  end

  local checksum_called, checksum = protected_callback(
    "crc32",
    configured.crc32,
    decoded
  )
  fence_ok, fence_err = restore_fence(
    self,
    state,
    expected,
    capability
  )
  if not fence_ok then
    return nil, fence_err
  end
  if not checksum_called
      or not integer(checksum)
      or checksum > U32_MAX then
    return quarantine_current(
      self,
      state,
      expected,
      capability,
      "cold page checksum failed"
    )
  end
  if checksum ~= rawget(state, "crc32") then
    return quarantine_current(
      self,
      state,
      expected,
      capability,
      "cold page checksum mismatch"
    )
  end

  local offset_bytes =
    (rawget(state, "row_count") + 1) * rawget(state, "offset_width")
  local raw_state = {
    codec = "raw",
    payload = STRING_SUB(decoded, offset_bytes + 1),
    offsets = STRING_SUB(decoded, 1, offset_bytes),
    crc32 = nil,
    offset_width = rawget(state, "offset_width"),
    row_count = rawget(state, "row_count"),
    decoded_bytes = rawget(state, "decoded_bytes"),
    max_rows = rawget(state, "max_rows"),
    max_bytes = rawget(state, "max_bytes"),
    oversized = rawget(state, "oversized"),
    revision = expected,
  }
  local raw_ok = validate_raw(raw_state)
  if not raw_ok then
    return quarantine_current(
      self,
      state,
      expected,
      capability,
      "cold page offsets are invalid"
    )
  end
  fence_ok, fence_err = restore_fence(
    self,
    state,
    expected,
    capability
  )
  if not fence_ok then
    return nil, fence_err
  end
  return own_raw_view(self, state, raw_state)
end
Page.read_view = read_view

local function storage_bytes(self)
  local state, state_err = private_state_for(self)
  if not state then
    return nil, state_err
  end
  return state_storage_bytes(state)
end
Page.storage_bytes = storage_bytes

local function revision(self)
  local state, state_err = private_state_for(self)
  if not state then
    return nil, state_err
  end
  return rawget(state, "revision")
end
Page.revision = revision

return Page
