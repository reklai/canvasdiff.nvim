local Page = require("canvasdiff.canvas.Page")

local PageList = {}
PageList.__index = PageList

local assert = assert
local ipairs = ipairs
local next = next
local pcall = pcall
local rawget = rawget
local rawset = rawset
local setmetatable = setmetatable
local tostring = tostring
local type = type
local MATH = {
  floor = math.floor,
  huge = math.huge,
  max = math.max,
  min = math.min,
}
local STRING_FIND = string.find
local STRING_FORMAT = string.format
local STRING_SUB = string.sub

local RAW_METATABLE = debug.getmetatable
local RAW_SET_METATABLE = debug.setmetatable
local RAW_EQUAL = rawequal
local OWNED_LISTS = setmetatable({}, { __mode = "k" })
local NODE_LINEAGES = setmetatable({}, { __mode = "k" })
local PIN_STATES = setmetatable({}, { __mode = "k" })
local PIN_LEASES = setmetatable({}, { __mode = "k" })
local SPLICE_ACTIVE = setmetatable({}, { __mode = "k" })
local PAGE_VALIDATE = Page.validate
local PAGE_ROW = Page.row
local PAGE_ROWS = Page.rows
local PAGE_STORAGE_BYTES = Page.storage_bytes
local PAGE_CREATION_CHECKPOINT = Page.creation_checkpoint
local PAGE_CLAIM = Page.claim
local PAGE_IS_OWNED_BY = Page.is_owned_by
local validate_list

local function own(fields, lineage)
  lineage = lineage or {}
  local list = setmetatable(fields, PageList)
  OWNED_LISTS[list] = lineage
  local current = {}
  local trusted_pages = {}
  local trusted_starts = {}
  local pages = rawget(fields, "_pages")
  if type(pages) == "table" then
    for index = 1, #pages do
      local node = rawget(pages, index)
      current[node] = true
      trusted_pages[index] = node
    end
  end
  local starts = rawget(fields, "_starts")
  if type(starts) == "table" then
    for index = 1, #starts do
      trusted_starts[index] = rawget(starts, index)
    end
  end
  PIN_STATES[list] = {
    token = {},
    generation = rawget(fields, "_generation"),
    row_count = rawget(fields, "_row_count"),
    public_pages = pages,
    public_starts = starts,
    trusted_pages = trusted_pages,
    trusted_starts = trusted_starts,
    active = {},
    counts = {},
    current = current,
    retired = {},
    active_leases = 0,
    pin_references = 0,
    current_pinned_pages = 0,
    retired_pinned_pages = 0,
  }
  return list
end

PageList.DEFAULT_MAX_ROWS = Page.DEFAULT_MAX_ROWS
PageList.DEFAULT_MAX_BYTES = Page.DEFAULT_MAX_BYTES

local U32_MAX = 0xFFFFFFFF
local MAX_SAFE_INTEGER = 9007199254740991
local TRUSTED_INSTANCE_METHODS = {
  "row_count",
  "page_count",
  "generation",
  "page_at",
  "locate",
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
local PAGE_REPRESENTATION_FIELDS = {
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

local function integer(value)
  return type(value) == "number"
    and value >= 0
    and value < MATH.huge
    and value == MATH.floor(value)
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
      return nil, STRING_FORMAT("row %d must be a string", index)
    end
    if STRING_FIND(row, "\n", 1, true) then
      return nil, STRING_FORMAT("row %d contains a line-feed delimiter", index)
    end
    if #row > U32_MAX then
      return nil, STRING_FORMAT("row %d exceeds the 32-bit page limit", index)
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
    return STRING_SUB(message, 1, limit) .. "…"
  end
  return message
end

local function dense_table(value, label)
  if type(value) ~= "table" then
    return nil, label .. " must be a table"
  end
  if not RAW_EQUAL(RAW_METATABLE(value), nil) then
    return nil, label .. " must be a plain dense sequence"
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

local function pin_state_for(list)
  if type(list) ~= "table" then
    return nil, nil, "page list must be a table"
  end
  local lineage = OWNED_LISTS[list]
  if not lineage or not RAW_EQUAL(RAW_METATABLE(list), PageList) then
    return nil, nil, "page list is not an owned PageList"
  end
  local state = PIN_STATES[list]
  if type(state) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(state), nil) then
    return nil, nil, "page-list pin state is invalid"
  end
  return state, lineage
end

local function pin_stats_snapshot(state)
  return {
    active_leases = rawget(state, "active_leases"),
    pin_references = rawget(state, "pin_references"),
    current_pinned_pages = rawget(state, "current_pinned_pages"),
    retired_pinned_pages = rawget(state, "retired_pinned_pages"),
  }
end

local function validate_pin_state(
    list,
    lineage,
    pages,
    starts,
    page_count,
    row_count,
    generation,
    next_page_id,
    max_rows,
    max_bytes,
    seen_ids,
    seen_pages
)
  local state = PIN_STATES[list]
  if type(state) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(state), nil) then
    return nil, "page-list pin state is invalid"
  end

  local token = rawget(state, "token")
  local pin_generation = rawget(state, "generation")
  local pin_row_count = rawget(state, "row_count")
  local public_pages = rawget(state, "public_pages")
  local public_starts = rawget(state, "public_starts")
  local trusted_pages = rawget(state, "trusted_pages")
  local trusted_starts = rawget(state, "trusted_starts")
  local active = rawget(state, "active")
  local counts = rawget(state, "counts")
  local current = rawget(state, "current")
  local retired = rawget(state, "retired")
  if type(token) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(token), nil)
      or type(active) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(active), nil)
      or type(counts) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(counts), nil)
      or type(current) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(current), nil)
      or type(retired) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(retired), nil) then
    return nil, "page-list pin tables are invalid"
  end
  if not integer(pin_generation)
      or pin_generation > MAX_SAFE_INTEGER
      or pin_generation ~= generation then
    return nil, "page-list pin generation is inconsistent"
  end
  if pin_row_count ~= row_count
      or not RAW_EQUAL(public_pages, pages)
      or not RAW_EQUAL(public_starts, starts) then
    return nil, "page-list pin layout source is inconsistent"
  end
  local trusted_page_count, trusted_pages_err =
    dense_table(trusted_pages, "trusted pin pages")
  if trusted_page_count == nil then
    return nil, trusted_pages_err
  end
  local trusted_start_count, trusted_starts_err =
    dense_table(trusted_starts, "trusted pin starts")
  if trusted_start_count == nil then
    return nil, trusted_starts_err
  end
  if trusted_page_count ~= page_count
      or trusted_start_count ~= page_count then
    return nil, "page-list trusted pin layout has the wrong length"
  end
  for index = 1, page_count do
    if not RAW_EQUAL(
      rawget(trusted_pages, index),
      rawget(pages, index)
    ) or rawget(trusted_starts, index) ~= rawget(starts, index) then
      return nil, "page-list trusted pin layout is inconsistent"
    end
  end

  local expected_current = {}
  for index = 1, trusted_page_count do
    expected_current[rawget(trusted_pages, index)] = true
  end
  local current_count = 0
  for node, present in next, current do
    if present ~= true or not expected_current[node] then
      return nil, "page-list current pin membership is invalid"
    end
    current_count = current_count + 1
  end
  if current_count ~= page_count then
    return nil, "page-list current pin membership is incomplete"
  end

  local expected_counts = {}
  local active_count = 0
  local reference_count = 0
  for lease, record in next, active do
    active_count = active_count + 1
    if type(lease) ~= "table"
        or type(record) ~= "table"
        or not RAW_EQUAL(RAW_METATABLE(record), nil)
        or not RAW_EQUAL(PIN_LEASES[lease], record)
        or not RAW_EQUAL(rawget(record, "token"), token)
        or rawget(record, "released") ~= false then
      return nil, "page-list active pin lease is invalid"
    end
    local lease_generation = rawget(record, "generation")
    if not integer(lease_generation) or lease_generation > generation then
      return nil, "page-list pin lease has an invalid generation"
    end
    local nodes = rawget(record, "nodes")
    local node_count, nodes_err = dense_table(nodes, "pin lease nodes")
    if node_count == nil then
      return nil, nodes_err
    end
    local seen = {}
    for index = 1, node_count do
      local node = rawget(nodes, index)
      if seen[node] then
        return nil, "pin lease repeats a page node"
      end
      seen[node] = true
      if not RAW_EQUAL(NODE_LINEAGES[node], lineage)
          or (not current[node] and not retired[node]) then
        return nil, "pin lease references an unowned page node"
      end
      expected_counts[node] = (expected_counts[node] or 0) + 1
      reference_count = reference_count + 1
    end
  end

  local current_pinned_pages = 0
  local retired_pinned_pages = 0
  for node, count in next, counts do
    if not positive_integer(count)
        or count > MAX_SAFE_INTEGER
        or expected_counts[node] ~= count
        or not RAW_EQUAL(NODE_LINEAGES[node], lineage) then
      return nil, "page-list page pin count is invalid"
    end
    if current[node] then
      if retired[node] ~= nil then
        return nil, "current page node is also retired"
      end
      current_pinned_pages = current_pinned_pages + 1
    else
      if retired[node] ~= true then
        return nil, "non-current pinned page node is not retired"
      end
      retired_pinned_pages = retired_pinned_pages + 1
    end
  end
  for node in next, expected_counts do
    if rawget(counts, node) == nil then
      return nil, "page-list pin count is missing"
    end
  end

  local retired_count = 0
  for node, present in next, retired do
    if present ~= true
        or current[node]
        or rawget(counts, node) == nil
        or not RAW_EQUAL(NODE_LINEAGES[node], lineage) then
      return nil, "page-list retired pin membership is invalid"
    end
    if type(node) ~= "table"
        or not RAW_EQUAL(RAW_METATABLE(node), nil) then
      return nil, "retired page node must be a plain table"
    end
    local node_id = rawget(node, "id")
    local created_generation = rawget(node, "created_generation")
    local page = rawget(node, "page")
    if not positive_integer(node_id) then
      return nil, "retired page node has an invalid id"
    end
    if seen_ids[node_id] then
      return nil, STRING_FORMAT("retired page id %d is duplicated", node_id)
    end
    if node_id >= next_page_id then
      return nil, STRING_FORMAT(
        "retired page id %d is beyond the allocator",
        node_id
      )
    end
    if not integer(created_generation)
        or created_generation > generation then
      return nil, STRING_FORMAT(
        "retired page %d has an invalid creation generation",
        node_id
      )
    end
    local page_ok, page_err = PAGE_VALIDATE(page)
    if not page_ok then
      return nil, STRING_FORMAT(
        "retired page %d is invalid: %s",
        node_id,
        page_err
      )
    end
    if seen_pages[page] then
      return nil, STRING_FORMAT(
        "retired page %d shares a Page object",
        node_id
      )
    end
    if not PAGE_IS_OWNED_BY(page, node) then
      return nil, STRING_FORMAT(
        "retired page %d is not owned by its PageList node",
        node_id
      )
    end
    if rawget(page, "max_rows") ~= max_rows
        or rawget(page, "max_bytes") ~= max_bytes then
      return nil, STRING_FORMAT(
        "retired page %d uses different limits",
        node_id
      )
    end
    seen_ids[node_id] = true
    seen_pages[page] = true
    retired_count = retired_count + 1
  end
  if retired_count ~= retired_pinned_pages then
    return nil, "page-list retired pin membership is incomplete"
  end

  if rawget(state, "active_leases") ~= active_count
      or rawget(state, "pin_references") ~= reference_count
      or rawget(state, "current_pinned_pages") ~= current_pinned_pages
      or rawget(state, "retired_pinned_pages") ~= retired_pinned_pages then
    return nil, "page-list pin totals are inconsistent"
  end
  return true
end

local function snapshot_table(value)
  local entries = {}
  local count = 0
  for key, entry in next, value do
    entries[key] = entry
    count = count + 1
  end
  return {
    value = value,
    entries = entries,
    count = count,
    metatable = RAW_METATABLE(value),
  }
end

local function table_matches_snapshot(snapshot)
  local value = snapshot.value
  if not RAW_EQUAL(RAW_METATABLE(value), snapshot.metatable) then
    return false
  end
  local count = 0
  for key, entry in next, value do
    if not RAW_EQUAL(snapshot.entries[key], entry) then
      return false
    end
    count = count + 1
  end
  return count == snapshot.count
end

local function restore_table(snapshot)
  local value = snapshot.value
  for key in next, value do
    rawset(value, key, nil)
  end
  for key, entry in next, snapshot.entries do
    rawset(value, key, entry)
  end
  RAW_SET_METATABLE(value, snapshot.metatable)
end

local function snapshot_list_graph(list)
  local snapshots = {}
  local seen = {}
  local function capture(value)
    if not seen[value] then
      seen[value] = true
      snapshots[#snapshots + 1] = snapshot_table(value)
    end
  end

  capture(list)
  local pages = rawget(list, "_pages")
  local starts = rawget(list, "_starts")
  capture(pages)
  capture(starts)
  for index = 1, #pages do
    local node = rawget(pages, index)
    capture(node)
    capture(rawget(node, "page"))
  end
  local pin_state = PIN_STATES[list]
  local retired = pin_state and rawget(pin_state, "retired") or nil
  if type(retired) == "table" then
    for node in next, retired do
      capture(node)
      capture(rawget(node, "page"))
    end
  end
  return snapshots
end

local function graph_matches_snapshots(snapshots)
  for _, snapshot in ipairs(snapshots) do
    if not table_matches_snapshot(snapshot) then
      return false
    end
  end
  return true
end

local function restore_graph(snapshots)
  for index = #snapshots, 1, -1 do
    restore_table(snapshots[index])
  end
end

local function page_fingerprint(page)
  local fingerprint = {}
  for _, field in ipairs(PAGE_REPRESENTATION_FIELDS) do
    fingerprint[field] = rawget(page, field)
  end
  return fingerprint
end

local function append_page(state, rows, manifest)
  if state._next_page_id >= MAX_SAFE_INTEGER then
    return nil, "page id allocator is exhausted"
  end
  local expected_rows = {}
  local offered_rows = {}
  for index = 1, #rows do
    local row = rawget(rows, index)
    expected_rows[index] = row
    offered_rows[index] = row
  end

  local created_during_call = PAGE_CREATION_CHECKPOINT()
  local called, page, page_err = pcall(Page.create, offered_rows, {
    max_rows = state._max_rows,
    max_bytes = state._max_bytes,
  })
  if not called then
    return nil, "page creation threw: " .. diagnostic(page)
  end
  if not page then
    if type(page_err) == "string" then
      return nil, page_err
    end
    return nil, "page creation failed: " .. diagnostic(page_err)
  end
  if page_err ~= nil then
    return nil, "page creation returned both a page and an error"
  end
  local page_ok, page_validation_err = PAGE_VALIDATE(page)
  if not page_ok then
    return nil, "page creation returned an invalid Page: " .. page_validation_err
  end
  if not created_during_call(page) then
    return nil, "page creation did not return a fresh Page"
  end
  if rawget(page, "max_rows") ~= state._max_rows
      or rawget(page, "max_bytes") ~= state._max_bytes then
    return nil, "page creation returned a Page with different limits"
  end
  if rawget(page, "row_count") ~= #expected_rows then
    return nil, "page creation returned different rows"
  end
  for index, expected in ipairs(expected_rows) do
    local decoded, decode_err = PAGE_ROW(page, index)
    if decoded == nil then
      return nil, "page creation returned an unreadable Page: "
        .. diagnostic(decode_err)
    end
    if decoded ~= expected then
      return nil, STRING_FORMAT("page creation changed row %d", index)
    end
  end
  local node = {
    id = state._next_page_id,
    page = page,
    created_generation = state._generation,
  }
  local lineage = OWNED_LISTS[state]
  NODE_LINEAGES[node] = lineage
  local claimed, claim_err = PAGE_CLAIM(page, node)
  if not claimed then
    return nil, "page creation returned an unavailable Page: " .. claim_err
  end

  state._next_page_id = state._next_page_id + 1
  local start0 = state._row_count
  state._starts[#state._starts + 1] = start0
  state._pages[#state._pages + 1] = node
  local pin_state = PIN_STATES[state]
  pin_state.trusted_starts[#pin_state.trusted_starts + 1] = start0
  pin_state.trusted_pages[#pin_state.trusted_pages + 1] = node
  pin_state.current[node] = true
  state._row_count = state._row_count + rawget(page, "row_count")
  pin_state.row_count = state._row_count
  state._decoded_bytes =
    state._decoded_bytes + rawget(page, "decoded_bytes")
  state._storage_bytes =
    state._storage_bytes + PAGE_STORAGE_BYTES(page)
  if rawget(page, "oversized") then
    state._oversized_pages = state._oversized_pages + 1
  end
  manifest[#manifest + 1] = {
    node = node,
    page = page,
    fingerprint = page_fingerprint(page),
  }
  return true
end

--- Consume a row source into a private candidate. Nothing returns the
--- candidate before EOF, the final flush, and the invariant check succeed.
local function build(next_row, limits, seed)
  seed = seed or {}
  local state = own({
    _pages = {},
    _starts = {},
    _row_count = 0,
    _decoded_bytes = 0,
    _storage_bytes = 0,
    _oversized_pages = 0,
    _next_page_id = seed.next_page_id or 1,
    _generation = seed.generation or 0,
    _max_rows = limits.max_rows,
    _max_bytes = limits.max_bytes,
  }, seed.lineage)

  local pending = {}
  local pending_bytes = 0
  local row_number = 0
  local manifest = {}

  local function flush()
    if #pending == 0 then
      return true
    end
    local ok, err = append_page(state, pending, manifest)
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
      return nil, STRING_FORMAT(
        "row iterator threw at row %d: %s",
        row_number + 1,
        diagnostic(row)
      )
    end
    if row == nil then
      if source_err ~= nil then
        return nil, STRING_FORMAT(
          "row iterator failed at row %d: %s",
          row_number + 1,
          diagnostic(source_err)
        )
      end
      break
    end

    row_number = row_number + 1
    if source_err ~= nil then
      return nil, STRING_FORMAT(
        "row iterator returned a row and error at row %d",
        row_number
      )
    end
    if type(row) ~= "string" then
      return nil, STRING_FORMAT("row %d must be a string", row_number)
    end
    if STRING_FIND(row, "\n", 1, true) then
      return nil, STRING_FORMAT(
        "row %d contains a line-feed delimiter",
        row_number
      )
    end
    if #row > U32_MAX then
      return nil, STRING_FORMAT(
        "row %d exceeds the 32-bit page limit",
        row_number
      )
    end

    local row_bytes = #row

    if row_bytes > limits.max_bytes then
      local ok, err = flush()
      if not ok then
        return nil, err
      end
      ok, err = append_page(state, { row }, manifest)
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
  for index, record in ipairs(manifest) do
    if not RAW_EQUAL(rawget(record.node, "page"), record.page)
        or not PAGE_IS_OWNED_BY(record.page, record.node) then
      return nil, STRING_FORMAT(
        "page constructor changed ownership of page %d",
        index
      )
    end
    for _, field in ipairs(PAGE_REPRESENTATION_FIELDS) do
      if not RAW_EQUAL(
        rawget(record.page, field),
        record.fingerprint[field]
      ) then
        return nil, STRING_FORMAT(
          "page constructor mutated prior page %d field %s",
          index,
          field
        )
      end
    end
  end
  ok, flush_err = validate_list(state)
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
  local snapshot = {}
  for index = 1, count do
    snapshot[index] = rawget(rows, index)
  end

  local index = 0
  return build(function()
    index = index + 1
    if index > count then
      return nil
    end
    return rawget(snapshot, index)
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

function PageList:generation()
  return self._generation
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
local function locate_layout(pages, starts, row_count, row0)
  if not integer(row0) or not integer(row_count) or row0 >= row_count then
    return nil, "row index is outside the list"
  end
  if type(pages) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(pages), nil)
      or type(starts) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(starts), nil) then
    return nil, "page-list lookup metadata is invalid"
  end

  local low, high = 1, #starts
  local found = 0
  while low <= high do
    local middle = MATH.floor((low + high) / 2)
    local prefix = rawget(starts, middle)
    if not integer(prefix) then
      return nil, "page-list lookup prefix is invalid"
    end
    if prefix <= row0 then
      found = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end
  if found == 0 then
    return nil, "page-list lookup prefixes do not cover the row"
  end

  local node = rawget(pages, found)
  return node, row0 - rawget(starts, found), found - 1
end

local function locate(self, row0)
  return locate_layout(
    rawget(self, "_pages"),
    rawget(self, "_starts"),
    rawget(self, "_row_count"),
    row0
  )
end
PageList.locate = locate

function PageList:row(row0)
  local node, local_row0 = locate(self, row0)
  if not node then
    return nil, local_row0
  end
  return PAGE_ROW(node.page, local_row0 + 1)
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

  local node, local_row0, page_index0 = locate(self, start0)
  if not node then
    return nil, local_row0
  end

  local result = {}
  local remaining = count
  while remaining > 0 do
    local available = node.page.row_count - local_row0
    local take = MATH.min(available, remaining)
    local page_rows, page_err = PAGE_ROWS(
      node.page,
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

local function pin_record_for(state, lease)
  if type(lease) ~= "table" then
    return nil, "pin lease must be a table"
  end
  local record = PIN_LEASES[lease]
  if not record then
    return nil, "pin lease is not owned by a PageList"
  end
  if not RAW_EQUAL(rawget(record, "token"), rawget(state, "token")) then
    return nil, "pin lease belongs to another PageList"
  end
  return record
end

--- Pin every concrete page intersecting the half-open logical row range.
---
--- This is a viewport hot path: ownership/range checks and two binary lookups
--- are bounded by the requested range. Full graph reconciliation remains an
--- explicit PageList.validate operation.
function PageList:pin_range(start0, count, expected_generation)
  local state, lineage, state_err = pin_state_for(self)
  if not state then
    return nil, state_err
  end
  if SPLICE_ACTIVE[self]
      or not RAW_EQUAL(rawget(self, "_splice_active"), nil) then
    return nil, "page-list splice is already active"
  end

  local pin_generation = rawget(state, "generation")
  local row_count = rawget(state, "row_count")
  local pages = rawget(state, "trusted_pages")
  local starts = rawget(state, "trusted_starts")
  local public_pages = rawget(self, "_pages")
  local public_starts = rawget(self, "_starts")
  local public_generation = rawget(self, "_generation")
  local public_row_count = rawget(self, "_row_count")
  if not integer(pin_generation) or pin_generation > MAX_SAFE_INTEGER
      or not integer(public_generation)
      or public_generation ~= pin_generation
      or not integer(row_count)
      or not integer(public_row_count)
      or public_row_count ~= row_count
      or type(pages) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(pages), nil)
      or type(starts) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(starts), nil)
      or type(public_pages) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(public_pages), nil)
      or type(public_starts) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(public_starts), nil)
      or not RAW_EQUAL(public_pages, rawget(state, "public_pages"))
      or not RAW_EQUAL(public_starts, rawget(state, "public_starts")) then
    return nil, "page list cannot acquire pins from invalid metadata"
  end
  if not RAW_EQUAL(expected_generation, nil) then
    if not integer(expected_generation)
        or expected_generation > MAX_SAFE_INTEGER then
      return nil, "expected generation must be a safe non-negative integer"
    end
    if expected_generation ~= pin_generation then
      return nil, "page-list generation changed before pin acquisition"
    end
  end
  if not integer(start0) or not integer(count)
      or start0 > row_count
      or count > row_count - start0 then
    return nil, "pin range is outside the list"
  end

  local nodes = {}
  local seen = {}
  if count > 0 then
    local first, _, first_page0 =
      locate_layout(pages, starts, row_count, start0)
    local last, _, last_page0 =
      locate_layout(pages, starts, row_count, start0 + count - 1)
    if not first or not last then
      return nil, "pin range could not resolve its page nodes"
    end
    for page_index0 = first_page0, last_page0 do
      local node = rawget(pages, page_index0 + 1)
      if type(node) ~= "table"
          or not RAW_EQUAL(RAW_METATABLE(node), nil)
          or not RAW_EQUAL(NODE_LINEAGES[node], lineage)
          or rawget(state.current, node) ~= true
          or not PAGE_IS_OWNED_BY(rawget(node, "page"), node) then
        return nil, "pin range resolved an invalid page node"
      end
      local public_prefix = rawget(public_starts, page_index0 + 1)
      if not RAW_EQUAL(rawget(public_pages, page_index0 + 1), node)
          or not integer(public_prefix)
          or public_prefix ~= rawget(starts, page_index0 + 1) then
        return nil, "pin range disagrees with public page metadata"
      end
      if seen[node] then
        return nil, "pin range repeats a concrete page node"
      end
      seen[node] = true
      nodes[#nodes + 1] = node
    end
  end

  local active_leases = rawget(state, "active_leases")
  local pin_references = rawget(state, "pin_references")
  if not integer(active_leases) or active_leases >= MAX_SAFE_INTEGER
      or not integer(pin_references)
      or pin_references > MAX_SAFE_INTEGER - #nodes then
    return nil, "page-list pin counters are exhausted"
  end
  for _, node in ipairs(nodes) do
    local node_count = rawget(state.counts, node)
    if node_count ~= nil
        and (not positive_integer(node_count)
          or node_count >= MAX_SAFE_INTEGER) then
      return nil, "page-list page pin counter is exhausted"
    end
  end

  local final_generation = rawget(self, "_generation")
  local final_row_count = rawget(self, "_row_count")
  if rawget(state, "generation") ~= pin_generation
      or not integer(final_generation)
      or final_generation ~= pin_generation
      or rawget(state, "row_count") ~= row_count
      or not integer(final_row_count)
      or final_row_count ~= row_count
      or not RAW_EQUAL(rawget(self, "_pages"), public_pages)
      or not RAW_EQUAL(rawget(self, "_starts"), public_starts) then
    return nil, "page-list generation changed before pin publication"
  end

  local lease = {}
  local record = {
    token = state.token,
    generation = pin_generation,
    nodes = nodes,
    released = false,
  }
  PIN_LEASES[lease] = record
  state.active[lease] = record
  state.active_leases = active_leases + 1
  state.pin_references = pin_references + #nodes
  for _, node in ipairs(nodes) do
    local node_count = rawget(state.counts, node)
    if node_count == nil then
      state.counts[node] = 1
      state.current_pinned_pages = state.current_pinned_pages + 1
    else
      state.counts[node] = node_count + 1
    end
  end
  return lease
end

--- Release one exact lease. A generation change never prevents cleanup: the
--- lease decrements the concrete nodes it originally pinned, including nodes
--- retired by a later splice.
function PageList:release_pin(lease)
  local state, _, state_err = pin_state_for(self)
  if not state then
    return nil, state_err
  end
  if SPLICE_ACTIVE[self]
      or not RAW_EQUAL(rawget(self, "_splice_active"), nil) then
    return nil, "page-list splice is already active"
  end
  local record, record_err = pin_record_for(state, lease)
  if not record then
    return nil, record_err
  end
  if rawget(record, "released") then
    return nil, "pin lease is already released"
  end
  if not RAW_EQUAL(rawget(state.active, lease), record) then
    return nil, "pin lease is not active"
  end

  local nodes = rawget(record, "nodes")
  local node_count, nodes_err = dense_table(nodes, "pin lease nodes")
  if node_count == nil then
    return nil, nodes_err
  end
  if rawget(state, "active_leases") < 1
      or rawget(state, "pin_references") < node_count then
    return nil, "page-list pin totals are inconsistent"
  end
  for index = 1, node_count do
    local node = rawget(nodes, index)
    local count = rawget(state.counts, node)
    if not positive_integer(count)
        or (not state.current[node] and not state.retired[node]) then
      return nil, "pin lease references an untracked page node"
    end
  end

  state.active[lease] = nil
  state.active_leases = state.active_leases - 1
  state.pin_references = state.pin_references - node_count
  for index = 1, node_count do
    local node = rawget(nodes, index)
    local count = state.counts[node] - 1
    if count == 0 then
      state.counts[node] = nil
      if state.retired[node] then
        state.retired[node] = nil
        state.retired_pinned_pages = state.retired_pinned_pages - 1
      else
        state.current_pinned_pages = state.current_pinned_pages - 1
      end
    else
      state.counts[node] = count
    end
  end
  record.nodes = nil
  record.released = true
  return true
end

function PageList:pin_is_current(lease)
  local state, _, state_err = pin_state_for(self)
  if not state then
    return nil, state_err
  end
  local record, record_err = pin_record_for(state, lease)
  if not record then
    return nil, record_err
  end
  if rawget(record, "released") then
    return false, "pin lease is released"
  end
  if not RAW_EQUAL(rawget(state.active, lease), record) then
    return nil, "pin lease is not active"
  end
  local generation = rawget(self, "_generation")
  local pin_generation = rawget(state, "generation")
  if not integer(generation)
      or generation > MAX_SAFE_INTEGER
      or generation ~= pin_generation then
    return nil, "page-list generation metadata is inconsistent"
  end
  return rawget(record, "generation") == pin_generation
end

function PageList:pin_count(node)
  local state, lineage, state_err = pin_state_for(self)
  if not state then
    return nil, state_err
  end
  if type(node) ~= "table"
      or not RAW_EQUAL(NODE_LINEAGES[node], lineage)
      or (not state.current[node] and not state.retired[node]) then
    return nil, "page node does not belong to this PageList"
  end
  return rawget(state.counts, node) or 0
end

function PageList:pin_stats()
  local state, _, state_err = pin_state_for(self)
  if not state then
    return nil, state_err
  end
  return pin_stats_snapshot(state)
end

local function summarize_pages(pages)
  local starts = {}
  local row_count = 0
  local decoded_bytes = 0
  local storage_bytes = 0
  local oversized_pages = 0
  for index, node in ipairs(pages) do
    starts[index] = row_count
    row_count = row_count + node.page.row_count
    decoded_bytes = decoded_bytes + node.page.decoded_bytes
    storage_bytes = storage_bytes + PAGE_STORAGE_BYTES(node.page)
    if node.page.oversized then
      oversized_pages = oversized_pages + 1
    end
  end
  return starts, row_count, decoded_bytes, storage_bytes, oversized_pages
end

local function page_slice(page, first, last)
  if first > last then
    return {}
  end
  return PAGE_ROWS(page, first, last)
end

--- Atomically replace the half-open logical range
--- `[start0, start0 + delete_count)` with `insert_rows`.
---
--- Only pages intersecting the edit are rebuilt. An insertion exactly on a
--- page boundary touches neither neighbour, while an insertion inside a page
--- rebuilds that page around the inserted rows. Candidate pages and metadata
--- stay private until their complete list passes validation.
local function splice_transaction(
    self,
    start0,
    delete_count,
    insert_rows,
    context
)
  local list_ok, list_err = validate_list(self)
  if not list_ok then
    return nil, list_err
  end
  if not integer(start0) or not integer(delete_count)
      or start0 > self._row_count
      or delete_count > self._row_count - start0 then
    return nil, "splice range is outside the list"
  end
  local insert_count, insert_err = validate_rows(insert_rows)
  if insert_count == nil then
    return nil, insert_err
  end
  local insert_snapshot = {}
  for index = 1, insert_count do
    insert_snapshot[index] = rawget(insert_rows, index)
  end

  local before_generation = self._generation
  if delete_count == 0 and insert_count == 0 then
    return true
  end
  if before_generation >= MAX_SAFE_INTEGER then
    return nil, "page-list generation is exhausted"
  end
  local generation = before_generation + 1

  local prefix_count
  local suffix_index
  local left_rows = {}
  local right_rows = {}

  if delete_count > 0 then
    local end0 = start0 + delete_count
    local first_node, first_local0, first_page0 = locate(self, start0)
    local last_node, _, last_page0 = locate(self, end0 - 1)

    prefix_count = first_page0
    suffix_index = last_page0 + 2

    if first_local0 > 0 then
      local rows, err = page_slice(first_node.page, 1, first_local0)
      if not rows then
        return nil, err
      end
      left_rows = rows
    end

    local last_start0 = self._starts[last_page0 + 1]
    local first_retained1 = end0 - last_start0 + 1
    if first_retained1 <= last_node.page.row_count then
      local rows, err = page_slice(
        last_node.page,
        first_retained1,
        last_node.page.row_count
      )
      if not rows then
        return nil, err
      end
      right_rows = rows
    end
  elseif self._row_count == 0 then
    prefix_count = 0
    suffix_index = 1
  elseif start0 == self._row_count then
    prefix_count = #self._pages
    suffix_index = #self._pages + 1
  else
    local node, local_row0, page_index0 = locate(self, start0)
    if local_row0 == 0 then
      prefix_count = page_index0
      suffix_index = page_index0 + 1
    else
      prefix_count = page_index0
      suffix_index = page_index0 + 2

      local rows, err = page_slice(node.page, 1, local_row0)
      if not rows then
        return nil, err
      end
      left_rows = rows
      rows, err = page_slice(
        node.page,
        local_row0 + 1,
        node.page.row_count
      )
      if not rows then
        return nil, err
      end
      right_rows = rows
    end
  end

  local segments = { left_rows, insert_snapshot, right_rows }
  local segment_index = 1
  local row_index = 1
  local source_graph = snapshot_list_graph(self)
  context.source_graph = source_graph
  local replacement, replacement_err = build(function()
    while segment_index <= #segments do
      local row = rawget(segments[segment_index], row_index)
      if row ~= nil then
        row_index = row_index + 1
        return row
      end
      segment_index = segment_index + 1
      row_index = 1
    end
    return nil
  end, {
    max_rows = self._max_rows,
    max_bytes = self._max_bytes,
  }, {
    generation = generation,
    next_page_id = self._next_page_id,
    lineage = OWNED_LISTS[self],
  })
  if not graph_matches_snapshots(source_graph) then
    restore_graph(source_graph)
    context.source_graph = nil
    return nil, "page creation mutated the source PageList"
  end
  context.source_graph = nil
  if not replacement then
    return nil, replacement_err
  end

  local pages = {}
  for index = 1, prefix_count do
    pages[#pages + 1] = self._pages[index]
  end
  for _, node in ipairs(replacement._pages) do
    pages[#pages + 1] = node
  end
  for index = suffix_index, #self._pages do
    pages[#pages + 1] = self._pages[index]
  end

  local starts, row_count, decoded_bytes, storage_bytes, oversized_pages =
    summarize_pages(pages)
  local candidate = own({
    _pages = pages,
    _starts = starts,
    _row_count = row_count,
    _decoded_bytes = decoded_bytes,
    _storage_bytes = storage_bytes,
    _oversized_pages = oversized_pages,
    _next_page_id = replacement._next_page_id,
    _generation = generation,
    _max_rows = self._max_rows,
    _max_bytes = self._max_bytes,
  }, OWNED_LISTS[self])
  local candidate_ok, candidate_err = validate_list(candidate)
  if not candidate_ok then
    return nil, candidate_err
  end

  local pin_state = PIN_STATES[self]
  local candidate_pin_state = PIN_STATES[candidate]
  local next_current = {}
  for _, node in ipairs(candidate._pages) do
    next_current[node] = true
  end
  local retiring = {}
  for node in next, pin_state.current do
    if not next_current[node] and pin_state.counts[node] then
      retiring[#retiring + 1] = node
    end
  end

  rawset(self, "_pages", candidate._pages)
  rawset(self, "_starts", candidate._starts)
  rawset(self, "_row_count", candidate._row_count)
  rawset(self, "_decoded_bytes", candidate._decoded_bytes)
  rawset(self, "_storage_bytes", candidate._storage_bytes)
  rawset(self, "_oversized_pages", candidate._oversized_pages)
  rawset(self, "_next_page_id", candidate._next_page_id)
  rawset(self, "_generation", candidate._generation)
  pin_state.current = next_current
  pin_state.generation = candidate._generation
  pin_state.row_count = candidate_pin_state.row_count
  pin_state.public_pages = candidate._pages
  pin_state.public_starts = candidate._starts
  pin_state.trusted_pages = candidate_pin_state.trusted_pages
  pin_state.trusted_starts = candidate_pin_state.trusted_starts
  for _, node in ipairs(retiring) do
    pin_state.retired[node] = true
    pin_state.current_pinned_pages =
      pin_state.current_pinned_pages - 1
    pin_state.retired_pinned_pages =
      pin_state.retired_pinned_pages + 1
  end

  return true
end

--- Fence the transaction against sanctioned re-entry. Page construction is a
--- fault boundary and can be replaced by tests or future codecs; a callback
--- must not commit a nested edit while the outer edit owns stale metadata.
function PageList:splice(start0, delete_count, insert_rows)
  if type(self) ~= "table" then
    return nil, "page list must be a table"
  end
  if SPLICE_ACTIVE[self]
      or not RAW_EQUAL(rawget(self, "_splice_active"), nil) then
    return nil, "page-list splice is already active"
  end

  SPLICE_ACTIVE[self] = {}
  rawset(self, "_splice_active", true)
  local context = {}
  local called, change, err = pcall(
    splice_transaction,
    self,
    start0,
    delete_count,
    insert_rows,
    context
  )
  local source_restored = false
  if context.source_graph
      and not graph_matches_snapshots(context.source_graph) then
    restore_graph(context.source_graph)
    source_restored = true
  end
  rawset(self, "_splice_active", nil)
  SPLICE_ACTIVE[self] = nil

  if source_restored then
    return nil, "page creation mutated the source PageList"
  end
  if not called then
    return nil, "page-list splice threw: " .. diagnostic(change)
  end
  return change, err
end

function PageList:stats()
  local result = {
    generation = self._generation,
    row_count = self._row_count,
    page_count = #self._pages,
    decoded_bytes = self._decoded_bytes,
    storage_bytes = self._storage_bytes,
    oversized_pages = self._oversized_pages,
    max_rows = self._max_rows,
    max_bytes = self._max_bytes,
  }
  local pin_stats = pin_stats_snapshot(PIN_STATES[self])
  for name, value in next, pin_stats do
    result[name] = value
  end
  return result
end

--- Check structural metadata and every owned Page without reading through the
--- logical accessor. This is also the invariant hook used by later fuzz tests.
validate_list = function(list)
  if type(list) ~= "table" then
    return nil, "page list must be a table"
  end
  local lineage = OWNED_LISTS[list]
  if not lineage or not RAW_EQUAL(RAW_METATABLE(list), PageList) then
    return nil, "page list is not an owned PageList"
  end
  for _, method in ipairs(TRUSTED_INSTANCE_METHODS) do
    if not RAW_EQUAL(rawget(list, method), nil) then
      return nil, "page list shadows trusted method " .. method
    end
  end

  local pages = rawget(list, "_pages")
  local starts = rawget(list, "_starts")
  local max_rows = rawget(list, "_max_rows")
  local max_bytes = rawget(list, "_max_bytes")
  local row_count = rawget(list, "_row_count")
  local expected_decoded_bytes = rawget(list, "_decoded_bytes")
  local expected_storage_bytes = rawget(list, "_storage_bytes")
  local expected_oversized_pages = rawget(list, "_oversized_pages")
  local generation = rawget(list, "_generation")
  local next_page_id = rawget(list, "_next_page_id")

  local page_count, pages_err = dense_table(pages, "page list pages")
  if page_count == nil then
    return nil, pages_err
  end
  local start_count, starts_err = dense_table(starts, "page list starts")
  if start_count == nil then
    return nil, starts_err
  end
  if start_count ~= page_count then
    return nil, "page and prefix counts differ"
  end
  if not positive_integer(max_rows)
      or not positive_integer(max_bytes)
      or max_bytes > U32_MAX then
    return nil, "page-list limits must be positive integers"
  end
  if not integer(row_count)
      or not integer(expected_decoded_bytes)
      or not integer(expected_storage_bytes)
      or not integer(expected_oversized_pages) then
    return nil, "page-list totals must be finite non-negative integers"
  end
  if not integer(generation) or generation > MAX_SAFE_INTEGER then
    return nil, "page-list generation must be a safe non-negative integer"
  end
  if not positive_integer(next_page_id)
      or next_page_id > MAX_SAFE_INTEGER then
    return nil, "next page id must be a safe positive integer"
  end

  local expected_start = 0
  local decoded_bytes = 0
  local storage_bytes = 0
  local oversized_pages = 0
  local seen_ids = {}
  local seen_pages = {}
  local greatest_id = 0

  for index = 1, page_count do
    local node = rawget(pages, index)
    if type(node) ~= "table"
        or not RAW_EQUAL(RAW_METATABLE(node), nil) then
      return nil, STRING_FORMAT(
        "page node %d must be a plain table",
        index
      )
    end
    local node_id = rawget(node, "id")
    local created_generation = rawget(node, "created_generation")
    local page = rawget(node, "page")
    if not RAW_EQUAL(NODE_LINEAGES[node], lineage) then
      return nil, STRING_FORMAT(
        "page node %d belongs to another PageList",
        index
      )
    end
    if not positive_integer(node_id) then
      return nil, STRING_FORMAT(
        "page node %d has an invalid id",
        index
      )
    end
    if seen_ids[node_id] then
      return nil, STRING_FORMAT("page id %d is duplicated", node_id)
    end
    if node_id >= next_page_id then
      return nil, STRING_FORMAT(
        "page id %d is beyond the allocator",
        node_id
      )
    end
    if not integer(created_generation)
        or created_generation > generation then
      return nil, STRING_FORMAT(
        "page %d has an invalid creation generation",
        node_id
      )
    end
    seen_ids[node_id] = true
    greatest_id = MATH.max(greatest_id, node_id)

    local start = rawget(starts, index)
    if not integer(start) or start ~= expected_start then
      return nil, STRING_FORMAT(
        "page prefix %d is not contiguous",
        index
      )
    end
    local page_ok, page_err = PAGE_VALIDATE(page)
    if not page_ok then
      return nil, STRING_FORMAT(
        "page %d is invalid: %s",
        node_id,
        page_err
      )
    end
    if seen_pages[page] then
      return nil, STRING_FORMAT("page %d shares a Page object", node_id)
    end
    seen_pages[page] = true
    if not PAGE_IS_OWNED_BY(page, node) then
      return nil, STRING_FORMAT(
        "page %d is not owned by its PageList node",
        node_id
      )
    end
    if rawget(page, "max_rows") ~= max_rows
        or rawget(page, "max_bytes") ~= max_bytes then
      return nil, STRING_FORMAT(
        "page %d uses different limits",
        node_id
      )
    end

    expected_start = expected_start + rawget(page, "row_count")
    decoded_bytes = decoded_bytes + rawget(page, "decoded_bytes")
    storage_bytes = storage_bytes + PAGE_STORAGE_BYTES(page)
    if rawget(page, "oversized") then
      oversized_pages = oversized_pages + 1
    end
  end

  if next_page_id <= greatest_id then
    return nil, "next page id does not advance past allocated ids"
  end
  if expected_start ~= row_count then
    return nil, "page prefixes do not sum to row_count"
  end
  if decoded_bytes ~= expected_decoded_bytes then
    return nil, "page bytes do not sum to decoded_bytes"
  end
  if storage_bytes ~= expected_storage_bytes then
    return nil, "page storage does not sum to storage_bytes"
  end
  if oversized_pages ~= expected_oversized_pages then
    return nil, "oversized page count is inconsistent"
  end
  local pins_ok, pins_err = validate_pin_state(
    list,
    lineage,
    pages,
    starts,
    page_count,
    row_count,
    generation,
    next_page_id,
    max_rows,
    max_bytes,
    seen_ids,
    seen_pages
  )
  if not pins_ok then
    return nil, pins_err
  end
  return true
end
PageList.validate = validate_list

return PageList
