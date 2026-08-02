-- A mutable logical row sequence over authenticated Pages. Readers address
-- stable zero-based rows while splice and compaction publish a new generation;
-- pins fence those replacements for the duration of a caller's read. The
-- resident LRU and reservations enforce the configured page and byte bounds.
local Page = require("canvasdiff.canvas.Page")

local PageList = {}
PageList.__index = PageList

local assert = assert
local ERROR = error
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
local LAYOUT_STATES = setmetatable({}, { __mode = "kv" })
local NODE_LINEAGES = setmetatable({}, { __mode = "k" })
local PIN_LEASES = setmetatable({}, { __mode = "k" })
local NODE_CAPABILITIES = setmetatable({}, { __mode = "k" })
local HANDLE_LAYOUT_ACCESS = {}
local PAGE_VALIDATE = Page.validate
local PAGE_ROW = Page.row
local PAGE_ROWS = Page.rows
local PAGE_METADATA = Page.metadata
local PAGE_CREATION_CHECKPOINT = Page.creation_checkpoint
local PAGE_CLAIM = Page.claim
local PAGE_IS_AUTHORIZED = Page.is_authorized
local PAGE_PREPARE_COLD = Page.prepare_cold
local PAGE_CANDIDATE_METADATA = Page.candidate_metadata
local PAGE_DISCARD_CANDIDATE = Page.discard_candidate
local PAGE_PUBLISH_COLD = Page.publish_cold
local PAGE_READ_VIEW = Page.read_view
local PAGE_RELEASE_VIEW = Page.release_view
local PAGE_VALIDATE_VIEW = Page.validate_view
local PAGE_VIEW_METADATA = Page.view_metadata
local PAGE_VIEW_ROW = Page.view_row
local PAGE_VIEW_ROWS = Page.view_rows
local PAGE_CANCEL_RESTORE = Page.cancel_restore
local validate_list

PageList.DEFAULT_RESIDENT_MAX_PAGES = 8
PageList.DEFAULT_RESIDENT_MAX_BYTES = 532512

local function copy_resident_config(config)
  config = config or {}
  return {
    max_pages = rawget(config, "max_pages")
      or PageList.DEFAULT_RESIDENT_MAX_PAGES,
    max_bytes = rawget(config, "max_bytes")
      or PageList.DEFAULT_RESIDENT_MAX_BYTES,
    codec = rawget(config, "codec"),
    encode = rawget(config, "encode"),
    decode = rawget(config, "decode"),
    crc32 = rawget(config, "crc32"),
  }
end

local function own(fields, lineage, resident_config)
  lineage = lineage or {}
  local list = setmetatable(fields, PageList)
  rawset(list, "_lineage", lineage)
  rawset(list, "_resident_config", copy_resident_config(resident_config))
  rawset(list, "_resident_state", {
    token = {},
    entries = {},
    pages = 0,
    bytes = 0,
    reserved_pages = 0,
    reserved_bytes = 0,
    lru_head = nil,
    lru_tail = nil,
    lru_pages = 0,
  })
  local current = {}
  local pages = rawget(fields, "_pages")
  if type(pages) == "table" then
    for index = 1, #pages do
      local node = rawget(pages, index)
      current[node] = true
    end
  end
  rawset(list, "_pin_state", {
    token = {},
    active = {},
    counts = {},
    current = current,
    retired = {},
    active_leases = 0,
    pin_references = 0,
    current_pinned_pages = 0,
    retired_pinned_pages = 0,
  })
  return list
end

local function publish_layout(layout)
  -- The private metatable slot gives the otherwise empty handle one ordinary
  -- strong ownership edge to its layout. The weak-kv registry is lookup-only,
  -- so callback -> handle cycles remain collectible under LuaJIT.
  local handle_metatable = {
    [HANDLE_LAYOUT_ACCESS] = layout,
    __index = PageList,
    __metatable = PageList,
  }
  rawset(layout, "_handle_metatable", handle_metatable)
  local handle = setmetatable({}, handle_metatable)
  rawset(layout, "_handle_ref", setmetatable({ handle }, {
    __mode = "v",
  }))
  LAYOUT_STATES[handle] = layout
  return handle
end

PageList.DEFAULT_MAX_ROWS = Page.DEFAULT_MAX_ROWS
PageList.DEFAULT_MAX_BYTES = Page.DEFAULT_MAX_BYTES

local U32_MAX = 0xFFFFFFFF
local MAX_SAFE_INTEGER = 9007199254740991
local TRUSTED_INSTANCE_METHODS = {
  "row_count",
  "page_count",
  "generation",
  "inspect_page",
  "locate_page",
  "row",
  "rows",
  "splice",
  "stats",
  "pin_range",
  "release_pin",
  "pin_is_current",
  "pin_stats",
  "compact_page",
  "pinned_row",
  "pinned_rows",
  "resident_stats",
  "validate",
}
local PAGE_REPRESENTATION_FIELDS = {
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

local function integer(value)
  return type(value) == "number"
    and value >= 0
    and value < MATH.huge
    and value == MATH.floor(value)
end

local function positive_integer(value)
  return integer(value) and value > 0
end

local function resident_options(opts)
  local resident = rawget(opts, "resident")
  if RAW_EQUAL(resident, nil) then
    resident = {}
  elseif type(resident) ~= "table" then
    return nil, "resident cache options must be a table"
  end

  local max_pages = rawget(resident, "max_pages")
  if RAW_EQUAL(max_pages, nil) then
    max_pages = PageList.DEFAULT_RESIDENT_MAX_PAGES
  end
  local max_bytes = rawget(resident, "max_bytes")
  if RAW_EQUAL(max_bytes, nil) then
    max_bytes = PageList.DEFAULT_RESIDENT_MAX_BYTES
  end
  if not integer(max_pages) or max_pages > MAX_SAFE_INTEGER then
    return nil, "resident max_pages must be a safe non-negative integer"
  end
  if not integer(max_bytes) or max_bytes > MAX_SAFE_INTEGER then
    return nil, "resident max_bytes must be a safe non-negative integer"
  end

  local restore = rawget(resident, "restore")
  local config = {
    max_pages = max_pages,
    max_bytes = max_bytes,
  }
  if RAW_EQUAL(restore, nil) then
    return config
  end
  if type(restore) ~= "table" then
    return nil, "resident restore adapter must be a table"
  end
  local codec = rawget(restore, "codec")
  local encode = rawget(restore, "encode")
  local decode = rawget(restore, "decode")
  local crc32 = rawget(restore, "crc32")
  if type(codec) ~= "string" or codec == "" or codec == "raw" then
    return nil, "resident restore codec must be a non-raw string"
  end
  if type(encode) ~= "function" then
    return nil, "resident restore encode must be a function"
  end
  if type(decode) ~= "function" then
    return nil, "resident restore decode must be a function"
  end
  if type(crc32) ~= "function" then
    return nil, "resident restore crc32 must be a function"
  end
  config.codec = codec
  config.encode = encode
  config.decode = decode
  config.crc32 = crc32
  return config
end

local function validate_resident_config(config)
  if type(config) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(config), nil) then
    return nil, "page-list resident configuration is invalid"
  end
  local max_pages = rawget(config, "max_pages")
  local max_bytes = rawget(config, "max_bytes")
  if not integer(max_pages) or max_pages > MAX_SAFE_INTEGER
      or not integer(max_bytes) or max_bytes > MAX_SAFE_INTEGER then
    return nil, "page-list resident limits are invalid"
  end
  local codec = rawget(config, "codec")
  local encode = rawget(config, "encode")
  local decode = rawget(config, "decode")
  local crc32 = rawget(config, "crc32")
  if RAW_EQUAL(codec, nil) then
    if not RAW_EQUAL(encode, nil)
        or not RAW_EQUAL(decode, nil)
        or not RAW_EQUAL(crc32, nil) then
      return nil, "page-list resident adapter is incomplete"
    end
    return true
  end
  if type(codec) ~= "string" or codec == "" or codec == "raw"
      or type(encode) ~= "function"
      or type(decode) ~= "function"
      or type(crc32) ~= "function" then
    return nil, "page-list resident adapter is invalid"
  end
  return true
end

local function options(opts)
  if RAW_EQUAL(opts, nil) then
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
  local resident, resident_err = resident_options(opts)
  if not resident then
    return nil, resident_err
  end
  return {
    max_rows = max_rows,
    max_bytes = max_bytes,
    resident = resident,
  }
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
  local lineage = rawget(list, "_lineage")
  if not lineage or not RAW_EQUAL(RAW_METATABLE(list), PageList) then
    return nil, nil, "page list is not an owned PageList"
  end
  local state = rawget(list, "_pin_state")
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
  local state = rawget(list, "_pin_state")
  if type(state) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(state), nil) then
    return nil, "page-list pin state is invalid"
  end

  local token = rawget(state, "token")
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
  local expected_current = {}
  for index = 1, page_count do
    expected_current[rawget(pages, index)] = true
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
    local lease_start = rawget(record, "start0")
    local lease_count = rawget(record, "count")
    local node_set = rawget(record, "node_set")
    if not integer(lease_start)
        or not integer(lease_count)
        or lease_start > MAX_SAFE_INTEGER - lease_count
        or type(node_set) ~= "table"
        or not RAW_EQUAL(RAW_METATABLE(node_set), nil) then
      return nil, "page-list pin lease has an invalid range"
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
      if not RAW_EQUAL(rawget(node_set, node), true) then
        return nil, "pin lease node membership is incomplete"
      end
      if not RAW_EQUAL(NODE_LINEAGES[node], lineage)
          or (not current[node] and not retired[node]) then
        return nil, "pin lease references an unowned page node"
      end
      expected_counts[node] = (expected_counts[node] or 0) + 1
      reference_count = reference_count + 1
    end
    local member_count = 0
    for node, present in next, node_set do
      if not seen[node] or not RAW_EQUAL(present, true) then
        return nil, "pin lease node membership is invalid"
      end
      member_count = member_count + 1
    end
    if member_count ~= node_count
        or (lease_count == 0 and node_count ~= 0)
        or (lease_count > 0 and node_count == 0) then
      return nil, "pin lease range does not match its page nodes"
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
    local capability = NODE_CAPABILITIES[node]
    if not PAGE_IS_AUTHORIZED(page, node, capability) then
      return nil, STRING_FORMAT(
        "retired page %d is not owned by its PageList node",
        node_id
      )
    end
    local metadata, metadata_err = PAGE_METADATA(page)
    if not metadata then
      return nil, STRING_FORMAT(
        "retired page %d has invalid metadata: %s",
        node_id,
        metadata_err
      )
    end
    if metadata.max_rows ~= max_rows
        or metadata.max_bytes ~= max_bytes then
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
    rawset(entries, key, entry)
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
    if not RAW_EQUAL(rawget(snapshot.entries, key), entry) then
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

local function snapshot_handle_owner(list)
  local handle_ref = rawget(list, "_handle_ref")
  local handle = rawget(handle_ref, 1)
  local handle_metatable = RAW_METATABLE(handle)
  return {
    ref = handle_ref,
    handle = handle,
    layout = list,
    registry = LAYOUT_STATES,
    metatable = handle_metatable,
    handle_snapshot = snapshot_table(handle),
    metatable_snapshot = snapshot_table(handle_metatable),
    ref_snapshot = snapshot_table(handle_ref),
    ref_metatable_snapshot =
      snapshot_table(RAW_METATABLE(handle_ref)),
  }
end

local function handle_owner_matches(list, snapshot)
  return RAW_EQUAL(rawget(list, "_handle_ref"), snapshot.ref)
    and RAW_EQUAL(rawget(snapshot.ref, 1), snapshot.handle)
    and RAW_EQUAL(
      RAW_METATABLE(snapshot.handle),
      snapshot.metatable
    )
    and RAW_EQUAL(
      rawget(snapshot.registry, snapshot.handle),
      snapshot.layout
    )
    and table_matches_snapshot(snapshot.handle_snapshot)
    and table_matches_snapshot(snapshot.metatable_snapshot)
    and table_matches_snapshot(snapshot.ref_snapshot)
    and table_matches_snapshot(snapshot.ref_metatable_snapshot)
end

local function restore_handle_owner(snapshot)
  restore_table(snapshot.metatable_snapshot)
  restore_table(snapshot.handle_snapshot)
  restore_table(snapshot.ref_metatable_snapshot)
  restore_table(snapshot.ref_snapshot)
  rawset(snapshot.registry, snapshot.handle, snapshot.layout)
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
  local pin_state = rawget(list, "_pin_state")
  local retired = pin_state and rawget(pin_state, "retired") or nil
  if type(retired) == "table" then
    for node in next, retired do
      capture(node)
      capture(rawget(node, "page"))
    end
  end
  return {
    tables = snapshots,
    owner = snapshot_handle_owner(list),
  }
end

local function graph_matches_snapshots(list_graph)
  if not handle_owner_matches(list_graph.tables[1].value, list_graph.owner) then
    return false
  end
  for _, snapshot in ipairs(list_graph.tables) do
    if not table_matches_snapshot(snapshot) then
      return false
    end
  end
  return true
end

local function restore_graph(list_graph)
  for index = #list_graph.tables, 1, -1 do
    restore_table(list_graph.tables[index])
  end
  restore_handle_owner(list_graph.owner)
end

local function resident_state_for(list)
  local state = rawget(list, "_resident_state")
  if type(state) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(state), nil)
      or type(rawget(state, "token")) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(rawget(state, "token")), nil)
      or type(rawget(state, "entries")) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(rawget(state, "entries")), nil) then
    return nil, "page-list resident state is invalid"
  end
  return state
end

local function resident_is_active(list)
  local active = rawget(list, "_resident_active")
  if active then
    rawset(active, "reentered", true)
    return true
  end
  return false
end

local function resident_unlink(state, entry)
  if not rawget(entry, "linked") then
    return
  end
  local previous = rawget(entry, "previous")
  local following = rawget(entry, "following")
  if previous then
    rawset(previous, "following", following)
  else
    rawset(state, "lru_head", following)
  end
  if following then
    rawset(following, "previous", previous)
  else
    rawset(state, "lru_tail", previous)
  end
  rawset(entry, "previous", nil)
  rawset(entry, "following", nil)
  rawset(entry, "linked", false)
  rawset(state, "lru_pages", rawget(state, "lru_pages") - 1)
end

local function resident_link_mru(state, entry)
  if rawget(entry, "linked") then
    resident_unlink(state, entry)
  end
  local head = rawget(state, "lru_head")
  rawset(entry, "previous", nil)
  rawset(entry, "following", head)
  rawset(entry, "linked", true)
  if head then
    rawset(head, "previous", entry)
  else
    rawset(state, "lru_tail", entry)
  end
  rawset(state, "lru_head", entry)
  rawset(state, "lru_pages", rawget(state, "lru_pages") + 1)
end

local function release_resident_view(view)
  if not view then
    return true
  end
  local called, released, release_err = pcall(PAGE_RELEASE_VIEW, view)
  if not called then
    return nil, "resident raw-view release threw"
  end
  if RAW_EQUAL(released, nil) then
    return nil, release_err or "resident raw-view release failed"
  end
  return true
end

local function resident_drop_entry(state, entry)
  local node = rawget(entry, "node")
  if not RAW_EQUAL(rawget(rawget(state, "entries"), node), entry) then
    return nil, "resident entry is not published"
  end
  resident_unlink(state, entry)
  rawset(rawget(state, "entries"), node, nil)
  rawset(state, "pages", rawget(state, "pages") - 1)
  rawset(state, "bytes",
    rawget(state, "bytes") - rawget(entry, "bytes"))
  local view = rawget(entry, "view")
  rawset(entry, "node", nil)
  rawset(entry, "page", nil)
  rawset(entry, "view", nil)
  rawset(entry, "bytes", nil)
  rawset(entry, "revision", nil)
  rawset(entry, "linked", false)
  return release_resident_view(view)
end

local function resident_stats_snapshot(list, state)
  local config = rawget(list, "_resident_config")
  local pages = rawget(state, "pages")
  local unpinned_pages = rawget(state, "lru_pages")
  return {
    pages = pages,
    bytes = rawget(state, "bytes"),
    pinned_pages = pages - unpinned_pages,
    unpinned_pages = unpinned_pages,
    reserved_pages = rawget(state, "reserved_pages"),
    reserved_bytes = rawget(state, "reserved_bytes"),
    max_pages = rawget(config, "max_pages"),
    max_bytes = rawget(config, "max_bytes"),
  }
end

local function validate_resident_state(list, lineage, pin_state)
  local state, state_err = resident_state_for(list)
  if not state then
    return nil, state_err
  end
  local config = rawget(list, "_resident_config")
  local pages = rawget(state, "pages")
  local bytes = rawget(state, "bytes")
  local reserved_pages = rawget(state, "reserved_pages")
  local reserved_bytes = rawget(state, "reserved_bytes")
  local lru_pages = rawget(state, "lru_pages")
  if not integer(pages)
      or not integer(bytes)
      or not integer(reserved_pages)
      or not integer(reserved_bytes)
      or not integer(lru_pages)
      or lru_pages > pages
      or pages + reserved_pages > rawget(config, "max_pages")
      or bytes + reserved_bytes > rawget(config, "max_bytes") then
    return nil, "page-list resident totals are invalid"
  end
  local active = rawget(list, "_resident_active")
  if (reserved_pages > 0 or reserved_bytes > 0) and not active then
    return nil, "page-list resident reservation has no owner"
  end
  if active and (
      type(active) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(active), nil)
    ) then
    return nil, "page-list resident activity token is invalid"
  end

  local entries = rawget(state, "entries")
  local entry_count = 0
  local byte_count = 0
  local linked_count = 0
  local linked_entries = {}
  for node, entry in next, entries do
    entry_count = entry_count + 1
    if type(node) ~= "table"
        or type(entry) ~= "table"
        or not RAW_EQUAL(RAW_METATABLE(entry), nil)
        or not RAW_EQUAL(rawget(entry, "node"), node)
        or not RAW_EQUAL(NODE_LINEAGES[node], lineage)
        or (not pin_state.current[node]
          and not pin_state.retired[node]) then
      return nil, "page-list resident entry has invalid ownership"
    end
    local page = rawget(entry, "page")
    local revision = rawget(entry, "revision")
    local entry_bytes = rawget(entry, "bytes")
    if not RAW_EQUAL(rawget(node, "page"), page)
        or not integer(revision)
        or not integer(entry_bytes)
        or not PAGE_IS_AUTHORIZED(
          page,
          node,
          NODE_CAPABILITIES[node]
        ) then
      return nil, "page-list resident entry has invalid provenance"
    end
    local metadata = PAGE_METADATA(page)
    if not metadata
        or not RAW_EQUAL(metadata.kind, "cold")
        or not RAW_EQUAL(metadata.revision, revision)
        or not RAW_EQUAL(metadata.view_bytes, entry_bytes)
        or metadata.quarantined then
      return nil, "page-list resident entry has stale Page metadata"
    end
    local view = rawget(entry, "view")
    local view_ok = PAGE_VALIDATE_VIEW(view, page, revision)
    local view_metadata = view_ok and PAGE_VIEW_METADATA(view) or nil
    if not view_ok
        or not view_metadata
        or not RAW_EQUAL(view_metadata.kind, "cold-restored")
        or not RAW_EQUAL(view_metadata.revision, revision)
        or not RAW_EQUAL(
          view_metadata.row_count,
          metadata.row_count
        )
        or not RAW_EQUAL(view_metadata.view_bytes, entry_bytes) then
      return nil, "page-list resident raw view is invalid"
    end
    local pin_count = rawget(pin_state.counts, node)
    if pin_count then
      if not positive_integer(pin_count)
          or rawget(entry, "linked") then
        return nil, "pinned resident entry is linked in the LRU"
      end
    else
      if not pin_state.current[node]
          or not RAW_EQUAL(rawget(entry, "linked"), true) then
        return nil, "unpinned resident entry is outside the LRU"
      end
      linked_entries[entry] = true
      linked_count = linked_count + 1
    end
    byte_count = byte_count + entry_bytes
  end
  if entry_count ~= pages
      or byte_count ~= bytes
      or linked_count ~= lru_pages then
    return nil, "page-list resident totals do not match entries"
  end

  local cursor = rawget(state, "lru_head")
  local previous
  local traversed = 0
  local seen = {}
  while cursor do
    traversed = traversed + 1
    if seen[cursor]
        or not linked_entries[cursor]
        or not RAW_EQUAL(rawget(cursor, "previous"), previous) then
      return nil, "page-list resident LRU links are invalid"
    end
    seen[cursor] = true
    previous = cursor
    cursor = rawget(cursor, "following")
  end
  if traversed ~= lru_pages
      or not RAW_EQUAL(previous, rawget(state, "lru_tail"))
      or (lru_pages == 0 and (
        rawget(state, "lru_head") ~= nil
        or rawget(state, "lru_tail") ~= nil
      )) then
    return nil, "page-list resident LRU endpoints are invalid"
  end
  return true
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
  local page_metadata, metadata_err = PAGE_METADATA(page)
  if not page_metadata then
    return nil, "page creation returned invalid metadata: " .. metadata_err
  end
  if not created_during_call(page) then
    return nil, "page creation did not return a fresh Page"
  end
  if page_metadata.max_rows ~= state._max_rows
      or page_metadata.max_bytes ~= state._max_bytes then
    return nil, "page creation returned a Page with different limits"
  end
  if page_metadata.row_count ~= #expected_rows then
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
  local lineage = rawget(state, "_lineage")
  NODE_LINEAGES[node] = lineage
  local claimed, capability_or_err = PAGE_CLAIM(page, node)
  if not claimed then
    return nil,
      "page creation returned an unavailable Page: " .. capability_or_err
  end
  NODE_CAPABILITIES[node] = capability_or_err
  if not PAGE_IS_AUTHORIZED(page, node, capability_or_err) then
    return nil, "page creation returned an unauthorized Page"
  end

  state._next_page_id = state._next_page_id + 1
  local start0 = state._row_count
  state._starts[#state._starts + 1] = start0
  state._pages[#state._pages + 1] = node
  local pin_state = rawget(state, "_pin_state")
  pin_state.current[node] = true
  state._row_count = state._row_count + page_metadata.row_count
  state._decoded_bytes =
    state._decoded_bytes + page_metadata.decoded_bytes
  state._storage_bytes =
    state._storage_bytes + page_metadata.storage_bytes
  if page_metadata.oversized then
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
  }, seed.lineage, seed.resident or limits.resident)

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
        or not PAGE_IS_AUTHORIZED(
          record.page,
          record.node,
          NODE_CAPABILITIES[record.node]
        ) then
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
  local layout, build_err = build(function()
    index = index + 1
    if index > count then
      return nil
    end
    return rawget(snapshot, index)
  end, limits)
  if not layout then
    return nil, build_err
  end
  return publish_layout(layout)
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
  local layout, build_err = build(next_row, limits)
  if not layout then
    return nil, build_err
  end
  return publish_layout(layout)
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

local function node_metadata(node)
  if type(node) ~= "table" then
    return nil, nil, "page node must be a table"
  end
  local page = rawget(node, "page")
  local capability = NODE_CAPABILITIES[node]
  local authorized, authorization_err =
    PAGE_IS_AUTHORIZED(page, node, capability)
  if not authorized then
    return nil, nil, authorization_err
  end
  local metadata, metadata_err = PAGE_METADATA(page)
  if not metadata then
    return nil, nil, metadata_err
  end
  return metadata, page
end

local function inspection_generation(self, expected_generation)
  if not RAW_EQUAL(expected_generation, nil)
      and (
        not integer(expected_generation)
        or expected_generation > MAX_SAFE_INTEGER
      ) then
    return nil, "expected generation must be a safe non-negative integer"
  end

  local generation = rawget(self, "_generation")
  if not integer(generation)
      or generation > MAX_SAFE_INTEGER then
    return nil, "page list cannot inspect invalid metadata"
  end
  if not RAW_EQUAL(expected_generation, nil)
      and not RAW_EQUAL(expected_generation, generation) then
    return nil, "page-list generation changed before inspection"
  end
  return generation
end

local function page_snapshot_at(
    self,
    state,
    lineage,
    page_index0,
    generation
)
  local pages = rawget(self, "_pages")
  local starts = rawget(self, "_starts")
  if type(pages) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(pages), nil)
      or type(starts) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(starts), nil) then
    return nil, "page list cannot inspect invalid metadata"
  end
  if not integer(page_index0) or page_index0 >= #pages then
    return nil, "page index is outside the list"
  end

  local page_index = page_index0 + 1
  local node = rawget(pages, page_index)
  local start0 = rawget(starts, page_index)
  if type(node) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(node), nil)
      or not RAW_EQUAL(NODE_LINEAGES[node], lineage)
      or not RAW_EQUAL(rawget(state.current, node), true)
      or not integer(start0) then
    return nil, "page list cannot inspect invalid metadata"
  end

  local id = rawget(node, "id")
  local created_generation = rawget(node, "created_generation")
  local pin_count = rawget(state.counts, node)
  if not positive_integer(id)
      or not integer(created_generation)
      or created_generation > generation
      or (
        not RAW_EQUAL(pin_count, nil)
        and not positive_integer(pin_count)
      ) then
    return nil, "page list cannot inspect invalid metadata"
  end

  local metadata, _, metadata_err = node_metadata(node)
  if not metadata then
    return nil, metadata_err
  end
  return {
    generation = generation,
    page_index = page_index0,
    id = id,
    created_generation = created_generation,
    start0 = start0,
    end0 = start0 + metadata.row_count,
    row_count = metadata.row_count,
    kind = metadata.kind,
    codec = metadata.codec,
    revision = metadata.revision,
    offset_width = metadata.offset_width,
    decoded_bytes = metadata.decoded_bytes,
    max_rows = metadata.max_rows,
    max_bytes = metadata.max_bytes,
    oversized = metadata.oversized,
    storage_bytes = metadata.storage_bytes,
    resident_bytes = metadata.resident_bytes,
    restore_bytes = metadata.restore_bytes,
    view_bytes = metadata.view_bytes,
    quarantined = metadata.quarantined,
    pin_count = pin_count or 0,
  }
end

--- Return a detached scalar snapshot for one current zero-based page index.
---
--- The optional generation fence is checked before Page metadata is read.
--- No Page, node, capability, payload, offsets, or internal table escapes.
function PageList:inspect_page(page_index0, expected_generation)
  local state, lineage, state_err = pin_state_for(self)
  if not state then
    return nil, state_err
  end
  local generation, generation_err =
    inspection_generation(self, expected_generation)
  if not generation then
    return nil, generation_err
  end
  return page_snapshot_at(
    self,
    state,
    lineage,
    page_index0,
    generation
  )
end

--- Locate a logical row and return detached page metadata plus local row.
---
--- The optional generation fence is checked before Page metadata is read.
function PageList:locate_page(row0, expected_generation)
  local state, lineage, state_err = pin_state_for(self)
  if not state then
    return nil, state_err
  end
  local generation, generation_err =
    inspection_generation(self, expected_generation)
  if not generation then
    return nil, generation_err
  end

  local row_count = rawget(self, "_row_count")
  if not integer(row_count) then
    return nil, "page list cannot inspect invalid metadata"
  end
  local node, local_row0, page_index0 = locate_layout(
    rawget(self, "_pages"),
    rawget(self, "_starts"),
    row_count,
    row0
  )
  if not node then
    return nil, local_row0
  end
  local snapshot, snapshot_err = page_snapshot_at(
    self,
    state,
    lineage,
    page_index0,
    generation
  )
  if not snapshot then
    return nil, snapshot_err
  end
  return snapshot, local_row0
end

local function compaction_is_active(list)
  local active = rawget(list, "_compact_active")
  if active then
    rawset(active, "reentered", true)
    return true
  end
  return false
end

-- Resident restore snapshots only a target-bounded internal graph: the layout
-- shell plus every exact target node/Page/slot, never non-target pages.
-- Exact public-handle rollback additionally scales with caller-inserted raw
-- decoys (normally none).
-- Unrelated private writes to non-target layout slots remain out-of-band
-- corruption for PageList.validate.
local function snapshot_resident_source(self, targets)
  local layout_pages = rawget(self, "_pages")
  local layout_starts = rawget(self, "_starts")
  local target_snapshots = {}
  for index, target in ipairs(targets) do
    target_snapshots[index] = {
      node = snapshot_table(target.node),
      page = snapshot_table(target.page),
      page_index = target.page_index,
      layout_page = rawget(layout_pages, target.page_index),
      layout_start = rawget(layout_starts, target.page_index),
    }
  end
  return {
    list = snapshot_table(self),
    owner = snapshot_handle_owner(self),
    layout_pages = layout_pages,
    layout_pages_metatable = RAW_METATABLE(layout_pages),
    layout_starts = layout_starts,
    layout_starts_metatable = RAW_METATABLE(layout_starts),
    targets = target_snapshots,
  }
end

local function resident_source_matches(source)
  if not table_matches_snapshot(source.list)
      or not handle_owner_matches(source.list.value, source.owner)
      or not RAW_EQUAL(
        RAW_METATABLE(source.layout_pages),
        source.layout_pages_metatable
      )
      or not RAW_EQUAL(
        RAW_METATABLE(source.layout_starts),
        source.layout_starts_metatable
      ) then
    return false
  end
  for _, target in ipairs(source.targets) do
    if not table_matches_snapshot(target.node)
        or not table_matches_snapshot(target.page)
        or not RAW_EQUAL(
          rawget(source.layout_pages, target.page_index),
          target.layout_page
        )
        or not RAW_EQUAL(
          rawget(source.layout_starts, target.page_index),
          target.layout_start
        ) then
      return false
    end
  end
  return true
end

local function restore_resident_source(source)
  restore_handle_owner(source.owner)
  RAW_SET_METATABLE(
    source.layout_pages,
    source.layout_pages_metatable
  )
  RAW_SET_METATABLE(
    source.layout_starts,
    source.layout_starts_metatable
  )
  for _, target in ipairs(source.targets) do
    rawset(
      source.layout_pages,
      target.page_index,
      target.layout_page
    )
    rawset(
      source.layout_starts,
      target.page_index,
      target.layout_start
    )
    restore_table(target.page)
    restore_table(target.node)
  end
  restore_table(source.list)
end

local function resident_entry_matches(entry, target)
  if type(entry) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(entry), nil)
      or not RAW_EQUAL(rawget(entry, "node"), target.node)
      or not RAW_EQUAL(rawget(entry, "page"), target.page)
      or not RAW_EQUAL(rawget(entry, "revision"), target.revision)
      or not RAW_EQUAL(rawget(entry, "bytes"), target.view_bytes) then
    return false
  end
  local view = rawget(entry, "view")
  local called, valid = pcall(
    PAGE_VALIDATE_VIEW,
    view,
    target.page,
    target.revision
  )
  if not called or not valid then
    return false
  end
  local metadata_called, metadata = pcall(PAGE_VIEW_METADATA, view)
  return metadata_called
    and type(metadata) == "table"
    and RAW_EQUAL(metadata.kind, "cold-restored")
    and RAW_EQUAL(metadata.revision, target.revision)
    and RAW_EQUAL(metadata.row_count, target.row_count)
    and RAW_EQUAL(metadata.view_bytes, target.view_bytes)
    and not target.quarantined
end

local function resident_fence(transaction)
  local self = transaction.list
  local state = transaction.state
  local active = transaction.active
  if not RAW_EQUAL(rawget(self, "_resident_active"), active)
      or rawget(active, "reentered")
      or not RAW_EQUAL(rawget(self, "_resident_state"), state)
      or not RAW_EQUAL(
        rawget(state, "reserved_pages"),
        transaction.reserved_pages
      )
      or not RAW_EQUAL(
        rawget(state, "reserved_bytes"),
        transaction.reserved_bytes
      )
      or not RAW_EQUAL(rawget(state, "pages"), transaction.pages)
      or not RAW_EQUAL(rawget(state, "bytes"), transaction.bytes)
      or not RAW_EQUAL(rawget(self, "_pin_state"), transaction.pin_state)
      or not RAW_EQUAL(
        rawget(self, "_resident_config"),
        transaction.config
      )
      or not resident_source_matches(transaction.source) then
    return nil, "page-list changed during resident restore"
  end
  local pin_state = transaction.pin_state
  if not RAW_EQUAL(
        rawget(self, "_generation"),
        transaction.generation
      )
      or not RAW_EQUAL(
        rawget(self, "_row_count"),
        transaction.row_count
      )
      or not RAW_EQUAL(
        rawget(self, "_pages"),
        transaction.pages_layout
      )
      or not RAW_EQUAL(
        rawget(self, "_starts"),
        transaction.starts_layout
      ) then
    return nil, "page-list changed during resident restore"
  end
  for _, target in ipairs(transaction.targets) do
    if not RAW_EQUAL(
          rawget(transaction.pages_layout, target.page_index),
          target.node
        )
        or not RAW_EQUAL(
          rawget(transaction.starts_layout, target.page_index),
          target.start
        )
        or not RAW_EQUAL(rawget(target.node, "page"), target.page)
        or not RAW_EQUAL(
          rawget(pin_state.current, target.node),
          true
        )
        or not RAW_EQUAL(
          rawget(pin_state.counts, target.node),
          target.pin_count
        )
        or not RAW_EQUAL(
          NODE_CAPABILITIES[target.node],
          target.capability
        )
        or not PAGE_IS_AUTHORIZED(
          target.page,
          target.node,
          target.capability
        ) then
      return nil, "page-list changed during resident restore"
    end
    local metadata = PAGE_METADATA(target.page)
    if not metadata
        or not RAW_EQUAL(metadata.kind, target.kind)
        or not RAW_EQUAL(metadata.revision, target.revision)
        or not RAW_EQUAL(metadata.row_count, target.row_count)
        or not RAW_EQUAL(metadata.view_bytes, target.view_bytes)
        or metadata.quarantined then
      return nil, "page-list changed during resident restore"
    end
  end
  return true
end

local function resident_cancel_result(transaction, target, scope)
  local fence_ok, fence_err = resident_fence(transaction)
  if fence_ok then
    return nil
  end
  transaction.callback_err = fence_err
  restore_resident_source(transaction.source)
  local cancellation, cancellation_err = PAGE_CANCEL_RESTORE(
    target.page,
    target.revision,
    target.capability,
    scope,
    fence_err
  )
  if not cancellation then
    transaction.cancellation_err = cancellation_err
  end
  return cancellation
end

local function abort_resident_preparation(transaction)
  local state = transaction.state
  for _, target in ipairs(transaction.misses) do
    if target.pending_view then
      release_resident_view(target.pending_view)
      target.pending_view = nil
    end
  end
  rawset(state, "reserved_pages", 0)
  rawset(state, "reserved_bytes", 0)
  if transaction.source
      and not resident_source_matches(transaction.source) then
    restore_resident_source(transaction.source)
  end
end

local function restore_resident_misses(transaction)
  for _, target in ipairs(transaction.misses) do
    local function decode_callback(block, expected_bytes, scope)
      local decoded =
        transaction.config.decode(block, expected_bytes)
      local cancellation =
        resident_cancel_result(transaction, target, scope)
      if cancellation then
        return cancellation
      end
      return decoded
    end
    local function checksum_callback(body, scope)
      local checksum = transaction.config.crc32(body)
      local cancellation =
        resident_cancel_result(transaction, target, scope)
      if cancellation then
        return cancellation
      end
      return checksum
    end
    local view, view_err = PAGE_READ_VIEW(
      target.page,
      target.revision,
      {
        codec = rawget(transaction.config, "codec"),
        decode = decode_callback,
        crc32 = checksum_callback,
      },
      target.capability
    )
    if not view then
      return nil,
        transaction.callback_err
          or transaction.cancellation_err
          or view_err
    end
    target.pending_view = view
    local fence_ok, fence_err = resident_fence(transaction)
    if not fence_ok then
      return nil, fence_err
    end
    local view_ok, view_validation_err = PAGE_VALIDATE_VIEW(
      view,
      target.page,
      target.revision
    )
    if not view_ok then
      return nil, view_validation_err
    end
    local view_metadata, view_metadata_err =
      PAGE_VIEW_METADATA(view)
    if not view_metadata
        or not RAW_EQUAL(view_metadata.kind, "cold-restored")
        or not RAW_EQUAL(
          view_metadata.revision,
          target.revision
        )
        or not RAW_EQUAL(
          view_metadata.row_count,
          target.row_count
        )
        or not RAW_EQUAL(
          view_metadata.view_bytes,
          target.view_bytes
        ) then
      return nil,
        view_metadata_err or "resident raw-view metadata is invalid"
    end
  end
  return true
end

local function prepare_resident_targets(
    self,
    pin_state,
    targets,
    config
)
  local state, state_err = resident_state_for(self)
  if not state then
    return nil, state_err
  end
  if not RAW_EQUAL(rawget(state, "reserved_pages"), 0)
      or not RAW_EQUAL(rawget(state, "reserved_bytes"), 0)
      or rawget(self, "_resident_active") then
    return nil, "page-list resident state is busy"
  end
  local entries = rawget(state, "entries")
  local protected = {}
  local purges = {}
  local purge_seen = {}
  local misses = {}
  local reserved_bytes = 0
  for _, target in ipairs(targets) do
    local entry = rawget(entries, target.node)
    if target.kind == "raw" then
      if entry and not purge_seen[entry] then
        purge_seen[entry] = true
        purges[#purges + 1] = entry
      end
    elseif entry and resident_entry_matches(entry, target) then
      target.entry = entry
      protected[entry] = true
    else
      if entry and not purge_seen[entry] then
        purge_seen[entry] = true
        purges[#purges + 1] = entry
      end
      misses[#misses + 1] = target
      reserved_bytes = reserved_bytes + target.view_bytes
    end
  end

  if #misses > 0 and not rawget(config, "codec") then
    return nil, "page-list resident restore adapter is not configured"
  end
  local max_pages = rawget(config, "max_pages")
  local max_bytes = rawget(config, "max_bytes")
  local planned_pages = rawget(state, "pages")
  local planned_bytes = rawget(state, "bytes")
  for _, entry in ipairs(purges) do
    planned_pages = planned_pages - 1
    planned_bytes = planned_bytes - rawget(entry, "bytes")
  end
  planned_pages = planned_pages + #misses
  planned_bytes = planned_bytes + reserved_bytes

  local victims = {}
  local victim_seen = {}
  local cursor = rawget(state, "lru_tail")
  while planned_pages > max_pages or planned_bytes > max_bytes do
    while cursor
        and (protected[cursor]
          or purge_seen[cursor]
          or victim_seen[cursor]) do
      cursor = rawget(cursor, "previous")
    end
    if not cursor then
      return nil, "resident cache limits cannot fit the pin range"
    end
    local victim = cursor
    cursor = rawget(victim, "previous")
    victim_seen[victim] = true
    victims[#victims + 1] = victim
    planned_pages = planned_pages - 1
    planned_bytes = planned_bytes - rawget(victim, "bytes")
  end

  local active
  if #misses > 0 then
    active = { reentered = false }
    rawset(self, "_resident_active", active)
  end
  local source = snapshot_resident_source(self, targets)
  for _, entry in ipairs(purges) do
    resident_drop_entry(state, entry)
  end
  for _, entry in ipairs(victims) do
    resident_drop_entry(state, entry)
  end
  if #misses == 0 then
    return {
      list = self,
      state = state,
      targets = targets,
      misses = misses,
      source = source,
    }
  end

  rawset(state, "reserved_pages", #misses)
  rawset(state, "reserved_bytes", reserved_bytes)
  local transaction = {
    list = self,
    state = state,
    pin_state = pin_state,
    config = config,
    active = active,
    generation = rawget(self, "_generation"),
    row_count = rawget(self, "_row_count"),
    pages_layout = rawget(self, "_pages"),
    starts_layout = rawget(self, "_starts"),
    pages = rawget(state, "pages"),
    bytes = rawget(state, "bytes"),
    reserved_pages = #misses,
    reserved_bytes = reserved_bytes,
    targets = targets,
    misses = misses,
    source = source,
  }
  local called, restored, restore_err =
    pcall(restore_resident_misses, transaction)
  if not called or not restored then
    abort_resident_preparation(transaction)
    rawset(self, "_resident_active", nil)
    if not called then
      return nil,
        "page-list resident restore threw: " .. diagnostic(restored)
    end
    return nil, restore_err
  end
  return transaction
end

local function commit_resident_preparation(transaction)
  local state = transaction.state
  local entries = rawget(state, "entries")
  for _, target in ipairs(transaction.misses) do
    local entry = {
      node = target.node,
      page = target.page,
      revision = target.revision,
      bytes = target.view_bytes,
      view = target.pending_view,
      linked = false,
    }
    target.pending_view = nil
    target.entry = entry
    rawset(entries, target.node, entry)
    rawset(state, "pages", rawget(state, "pages") + 1)
    rawset(state, "bytes",
      rawget(state, "bytes") + target.view_bytes)
  end
  rawset(state, "reserved_pages", 0)
  rawset(state, "reserved_bytes", 0)
  transaction.committed = true
  rawset(transaction.list, "_resident_active", nil)
end

local pin_range_trusted
local pin_range_impl
local release_pin_trusted
local release_pin_impl
local pinned_row_trusted
local pinned_rows_trusted
local SPLICE_PIN_ACCESS = {}

function PageList:row(row0)
  if resident_is_active(self) then
    return nil, "page-list resident restore is already active"
  end
  if compaction_is_active(self) then
    return nil, "page-list compaction is already active"
  end
  local node, local_row0 = locate(self, row0)
  if not node then
    return nil, local_row0
  end
  local metadata, _, metadata_err = node_metadata(node)
  if not metadata then
    return nil, metadata_err
  end
  local page_start = row0 - local_row0
  local lease, lease_err = pin_range_trusted(
    self,
    page_start,
    metadata.row_count,
    rawget(self, "_generation")
  )
  if not lease then
    return nil, lease_err
  end
  local row, row_err = pinned_row_trusted(self, lease, row0)
  local released, release_err = release_pin_trusted(self, lease)
  if not released then
    return nil, release_err
  end
  return row, row_err
end

--- Return the half-open logical range [start0, start0 + count).
function PageList:rows(start0, count)
  if resident_is_active(self) then
    return nil, "page-list resident restore is already active"
  end
  if compaction_is_active(self) then
    return nil, "page-list compaction is already active"
  end
  local row_count = rawget(self, "_row_count")
  if not integer(start0) or not integer(count)
      or not integer(row_count)
      or start0 > row_count
      or count > row_count - start0 then
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
  local absolute_row0 = start0
  local generation = rawget(self, "_generation")
  while remaining > 0 do
    local metadata, _, metadata_err = node_metadata(node)
    if not metadata then
      return nil, metadata_err
    end
    local available = metadata.row_count - local_row0
    local take = MATH.min(available, remaining)
    local lease, lease_err = pin_range_trusted(
      self,
      absolute_row0,
      take,
      generation
    )
    if not lease then
      return nil, lease_err
    end
    local page_rows, page_err = pinned_rows_trusted(
      self,
      lease,
      absolute_row0,
      take
    )
    local released, release_err =
      release_pin_trusted(self, lease)
    if not released then
      return nil, release_err
    end
    if not page_rows then
      return nil, page_err
    end
    for _, row in ipairs(page_rows) do
      result[#result + 1] = row
    end

    remaining = remaining - take
    absolute_row0 = absolute_row0 + take
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
pin_range_impl = function(
    self,
    start0,
    count,
    expected_generation,
    internal_access
)
  local state, lineage, state_err = pin_state_for(self)
  if not state then
    return nil, state_err
  end
  if resident_is_active(self) then
    return nil, "page-list resident restore is already active"
  end
  if not RAW_EQUAL(rawget(self, "_splice_active"), nil) then
    if not RAW_EQUAL(internal_access, SPLICE_PIN_ACCESS) then
      return nil, "page-list splice is already active"
    end
  elseif RAW_EQUAL(internal_access, SPLICE_PIN_ACCESS) then
    return nil, "internal splice pin is outside its transaction"
  end
  if compaction_is_active(self) then
    return nil, "page-list compaction is already active"
  end
  if not RAW_EQUAL(internal_access, nil)
      and not RAW_EQUAL(internal_access, SPLICE_PIN_ACCESS) then
    return nil, "page-list splice is already active"
  end

  local pin_generation = rawget(self, "_generation")
  local row_count = rawget(self, "_row_count")
  local pages = rawget(self, "_pages")
  local starts = rawget(self, "_starts")
  if not integer(pin_generation) or pin_generation > MAX_SAFE_INTEGER
      or not integer(row_count)
      or type(pages) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(pages), nil)
      or type(starts) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(starts), nil) then
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
  local targets = {}
  local target_by_node = {}
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
          or not PAGE_IS_AUTHORIZED(
            rawget(node, "page"),
            node,
            NODE_CAPABILITIES[node]
          ) then
        return nil, "pin range resolved an invalid page node"
      end
      local prefix = rawget(starts, page_index0 + 1)
      if not integer(prefix) then
        return nil, "pin range resolved invalid page metadata"
      end
      if seen[node] then
        return nil, "pin range repeats a concrete page node"
      end
      local metadata, page, metadata_err = node_metadata(node)
      if not metadata then
        return nil, metadata_err
      end
      seen[node] = true
      nodes[#nodes + 1] = node
      local target = {
        node = node,
        page = page,
        page_index = page_index0 + 1,
        start = rawget(starts, page_index0 + 1),
        kind = metadata.kind,
        revision = metadata.revision,
        row_count = metadata.row_count,
        view_bytes = metadata.view_bytes,
        quarantined = metadata.quarantined,
        capability = NODE_CAPABILITIES[node],
        pin_count = rawget(state.counts, node),
      }
      targets[#targets + 1] = target
      target_by_node[node] = target
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

  local config = rawget(self, "_resident_config")
  local prepared, resident_err =
    prepare_resident_targets(self, state, targets, config)
  if not prepared then
    return nil, resident_err
  end

  local final_generation = rawget(self, "_generation")
  local final_row_count = rawget(self, "_row_count")
  if not integer(final_generation)
      or final_generation ~= pin_generation
      or not integer(final_row_count)
      or final_row_count ~= row_count
      or not RAW_EQUAL(rawget(self, "_pages"), pages)
      or not RAW_EQUAL(rawget(self, "_starts"), starts)
      or not resident_source_matches(prepared.source) then
    abort_resident_preparation(prepared)
    rawset(self, "_resident_active", nil)
    return nil, "page-list generation changed before pin publication"
  end

  commit_resident_preparation(prepared)
  local lease = {}
  local node_set = {}
  for _, node in ipairs(nodes) do
    node_set[node] = true
  end
  local record = {
    token = state.token,
    generation = pin_generation,
    start0 = start0,
    count = count,
    nodes = nodes,
    node_set = node_set,
    released = false,
  }
  PIN_LEASES[lease] = record
  state.active[lease] = record
  state.active_leases = active_leases + 1
  state.pin_references = pin_references + #nodes
  for _, node in ipairs(nodes) do
    local node_count = rawget(state.counts, node)
    local target = target_by_node[node]
    if target and target.entry then
      resident_unlink(prepared.state, target.entry)
    end
    if node_count == nil then
      state.counts[node] = 1
      state.current_pinned_pages = state.current_pinned_pages + 1
    else
      state.counts[node] = node_count + 1
    end
  end
  return lease
end
pin_range_trusted = function(
    self,
    start0,
    count,
    expected_generation
)
  return pin_range_impl(
    self,
    start0,
    count,
    expected_generation,
    nil
  )
end
PageList.pin_range = pin_range_trusted

local function current_pin_read_record(self, lease)
  local state, _, state_err = pin_state_for(self)
  if not state then
    return nil, nil, state_err
  end
  local record, record_err = pin_record_for(state, lease)
  if not record then
    return nil, nil, record_err
  end
  if rawget(record, "released") then
    return nil, nil, "pin lease is released"
  end
  if not RAW_EQUAL(rawget(state.active, lease), record) then
    return nil, nil, "pin lease is not active"
  end
  local generation = rawget(self, "_generation")
  local lease_generation = rawget(record, "generation")
  if not integer(generation)
      or generation > MAX_SAFE_INTEGER
      or not RAW_EQUAL(lease_generation, generation) then
    return nil, nil, "pin lease generation is stale"
  end
  local node_set = rawget(record, "node_set")
  if type(node_set) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(node_set), nil) then
    return nil, nil, "pin lease node membership is invalid"
  end
  return state, record
end

local function pinned_page_rows(
    self,
    pin_state,
    record,
    node,
    first,
    last
)
  if not RAW_EQUAL(rawget(rawget(record, "node_set"), node), true)
      or not positive_integer(rawget(pin_state.counts, node)) then
    return nil, "row is not covered by this pin lease"
  end
  local metadata, page, metadata_err = node_metadata(node)
  if not metadata then
    return nil, metadata_err
  end
  if metadata.kind == "raw" then
    return PAGE_ROWS(page, first, last)
  end

  local resident_state, resident_err = resident_state_for(self)
  if not resident_state then
    return nil, resident_err
  end
  local entry = rawget(
    rawget(resident_state, "entries"),
    node
  )
  local target = {
    node = node,
    page = page,
    revision = metadata.revision,
    row_count = metadata.row_count,
    view_bytes = metadata.view_bytes,
    quarantined = metadata.quarantined,
  }
  if not entry or not resident_entry_matches(entry, target) then
    if entry then
      resident_drop_entry(resident_state, entry)
    end
    return nil, "resident raw view is unavailable for the pin lease"
  end
  return PAGE_VIEW_ROWS(rawget(entry, "view"), first, last)
end

pinned_rows_trusted = function(self, lease, start0, count)
  if resident_is_active(self) then
    return nil, "page-list resident restore is already active"
  end
  if compaction_is_active(self) then
    return nil, "page-list compaction is already active"
  end
  local state, record, record_err =
    current_pin_read_record(self, lease)
  if not state then
    return nil, record_err
  end
  local lease_start = rawget(record, "start0")
  local lease_count = rawget(record, "count")
  if not integer(lease_start)
      or not integer(lease_count)
      or not integer(start0)
      or not integer(count)
      or start0 < lease_start
      or start0 > lease_start + lease_count
      or count > lease_start + lease_count - start0 then
    return nil, "row range is outside the pin lease"
  end
  if count == 0 then
    return {}
  end

  local pages = rawget(self, "_pages")
  local starts = rawget(self, "_starts")
  local row_count = rawget(self, "_row_count")
  local node, local_row0, page_index0 =
    locate_layout(pages, starts, row_count, start0)
  if not node then
    return nil, local_row0
  end
  local result = {}
  local remaining = count
  while remaining > 0 do
    if not RAW_EQUAL(
      rawget(rawget(record, "node_set"), node),
      true
    ) then
      return nil, "row range is not covered by this pin lease"
    end
    local metadata, _, metadata_err = node_metadata(node)
    if not metadata then
      return nil, metadata_err
    end
    local available = metadata.row_count - local_row0
    local take = MATH.min(available, remaining)
    local rows, rows_err = pinned_page_rows(
      self,
      state,
      record,
      node,
      local_row0 + 1,
      local_row0 + take
    )
    if not rows then
      return nil, rows_err
    end
    for _, row in ipairs(rows) do
      result[#result + 1] = row
    end
    remaining = remaining - take
    page_index0 = page_index0 + 1
    local_row0 = 0
    if remaining > 0 then
      node = rawget(pages, page_index0 + 1)
    end
  end
  return result
end
PageList.pinned_rows = pinned_rows_trusted

pinned_row_trusted = function(self, lease, row0)
  if not integer(row0) then
    return nil, "row index is outside the pin lease"
  end
  local rows, rows_err =
    pinned_rows_trusted(self, lease, row0, 1)
  if not rows then
    return nil, rows_err
  end
  return rawget(rows, 1)
end
PageList.pinned_row = pinned_row_trusted

--- Release one exact lease. A generation change never prevents cleanup: the
--- lease decrements the concrete nodes it originally pinned, including nodes
--- retired by a later splice.
release_pin_impl = function(self, lease, internal_access)
  local state, _, state_err = pin_state_for(self)
  if not state then
    return nil, state_err
  end
  if resident_is_active(self) then
    return nil, "page-list resident restore is already active"
  end
  if not RAW_EQUAL(rawget(self, "_splice_active"), nil) then
    if not RAW_EQUAL(internal_access, SPLICE_PIN_ACCESS) then
      return nil, "page-list splice is already active"
    end
  elseif RAW_EQUAL(internal_access, SPLICE_PIN_ACCESS) then
    return nil, "internal splice pin is outside its transaction"
  end
  if compaction_is_active(self) then
    return nil, "page-list compaction is already active"
  end
  local resident_state, resident_err = resident_state_for(self)
  if not resident_state then
    return nil, resident_err
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
      local resident_entry = rawget(
        rawget(resident_state, "entries"),
        node
      )
      if state.retired[node] then
        if resident_entry then
          resident_drop_entry(resident_state, resident_entry)
        end
        state.retired[node] = nil
        NODE_CAPABILITIES[node] = nil
        rawset(node, "page", nil)
        state.retired_pinned_pages = state.retired_pinned_pages - 1
      else
        if resident_entry then
          resident_link_mru(resident_state, resident_entry)
        end
        state.current_pinned_pages = state.current_pinned_pages - 1
      end
    else
      state.counts[node] = count
    end
  end
  record.nodes = nil
  record.node_set = nil
  record.start0 = nil
  record.count = nil
  record.released = true
  return true
end
release_pin_trusted = function(self, lease)
  return release_pin_impl(self, lease, nil)
end
PageList.release_pin = release_pin_trusted

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
  if not integer(generation)
      or generation > MAX_SAFE_INTEGER then
    return nil, "page-list generation metadata is inconsistent"
  end
  return rawget(record, "generation") == generation
end

function PageList:pin_stats()
  local state, _, state_err = pin_state_for(self)
  if not state then
    return nil, state_err
  end
  return pin_stats_snapshot(state)
end

function PageList:resident_stats()
  local _, _, owned_err = pin_state_for(self)
  if owned_err then
    return nil, owned_err
  end
  local state, state_err = resident_state_for(self)
  if not state then
    return nil, state_err
  end
  local config_ok, config_err =
    validate_resident_config(rawget(self, "_resident_config"))
  if not config_ok then
    return nil, config_err
  end
  return resident_stats_snapshot(self, state)
end

-- Compact-one is a scheduler primitive, so its internal source snapshot is
-- deliberately bounded independently of page count: the layout/node/Page
-- shells plus the exact target slots. Exact public-handle rollback additionally
-- scales with caller-inserted raw decoys (normally none). Unrelated private
-- writes into non-target layout slots are out-of-band corruption for validate;
-- sanctioned PageList calls and top-level/target mutation are transactional.
local function snapshot_compact_source(self, node, page, page_index)
  local layout_pages = rawget(self, "_pages")
  local layout_starts = rawget(self, "_starts")
  return {
    list = snapshot_table(self),
    owner = snapshot_handle_owner(self),
    node = snapshot_table(node),
    page = snapshot_table(page),
    page_index = page_index,
    layout_pages = layout_pages,
    layout_pages_metatable = RAW_METATABLE(layout_pages),
    layout_page = rawget(layout_pages, page_index),
    layout_starts = layout_starts,
    layout_starts_metatable = RAW_METATABLE(layout_starts),
    layout_start = rawget(layout_starts, page_index),
  }
end

local function compact_source_matches(source)
  if not table_matches_snapshot(source.list)
      or not handle_owner_matches(source.list.value, source.owner)
      or not table_matches_snapshot(source.node)
      or not table_matches_snapshot(source.page)
      or not RAW_EQUAL(
        RAW_METATABLE(source.layout_pages),
        source.layout_pages_metatable
      )
      or not RAW_EQUAL(
        RAW_METATABLE(source.layout_starts),
        source.layout_starts_metatable
      ) then
    return false
  end
  return RAW_EQUAL(
    rawget(source.layout_pages, source.page_index),
    source.layout_page
  ) and RAW_EQUAL(
    rawget(source.layout_starts, source.page_index),
    source.layout_start
  )
end

local function restore_compact_source(source)
  restore_handle_owner(source.owner)
  RAW_SET_METATABLE(
    source.layout_pages,
    source.layout_pages_metatable
  )
  RAW_SET_METATABLE(
    source.layout_starts,
    source.layout_starts_metatable
  )
  rawset(
    source.layout_pages,
    source.page_index,
    source.layout_page
  )
  rawset(
    source.layout_starts,
    source.page_index,
    source.layout_start
  )
  restore_table(source.page)
  restore_table(source.node)
  restore_table(source.list)
end

local function compact_fence(self, snapshot)
  local active = rawget(self, "_compact_active")
  if not RAW_EQUAL(active, snapshot.active)
      or rawget(snapshot.active, "reentered")
      or not compact_source_matches(snapshot.source) then
    return nil, "page-list changed during compaction"
  end
  if not RAW_EQUAL(rawget(self, "_splice_active"), nil)
      or not RAW_EQUAL(rawget(self, "_pin_state"), snapshot.pin_state)
      or not RAW_EQUAL(rawget(self, "_resident_config"), snapshot.config)
      or not RAW_EQUAL(
        rawget(self, "_generation"),
        snapshot.generation
      )
      or not RAW_EQUAL(rawget(self, "_pages"), snapshot.pages)
      or not RAW_EQUAL(rawget(self, "_starts"), snapshot.starts)
      or not RAW_EQUAL(rawget(self, "_row_count"), snapshot.row_count)
      or not RAW_EQUAL(
        rawget(self, "_storage_bytes"),
        snapshot.storage_bytes
      )
      or not RAW_EQUAL(
        rawget(snapshot.pages, snapshot.page_index),
        snapshot.node
      )
      or not RAW_EQUAL(
        rawget(snapshot.starts, snapshot.page_index),
        snapshot.page_start
      )
      or not RAW_EQUAL(rawget(snapshot.node, "page"), snapshot.page)
      or not RAW_EQUAL(
        rawget(snapshot.pin_state.current, snapshot.node),
        true
      )
      or not RAW_EQUAL(
        rawget(snapshot.pin_state.counts, snapshot.node),
        nil
      )
      or not RAW_EQUAL(
        NODE_CAPABILITIES[snapshot.node],
        snapshot.capability
      ) then
    return nil, "page-list changed during compaction"
  end
  local authorized = PAGE_IS_AUTHORIZED(
    snapshot.page,
    snapshot.node,
    snapshot.capability
  )
  if not authorized then
    return nil, "page-list changed during compaction"
  end
  local page_ok = PAGE_VALIDATE(snapshot.page)
  if not page_ok then
    return nil, "page-list changed during compaction"
  end
  local metadata = PAGE_METADATA(snapshot.page)
  if not metadata
      or not RAW_EQUAL(metadata.kind, "raw")
      or not RAW_EQUAL(metadata.revision, snapshot.revision)
      or not RAW_EQUAL(
        metadata.storage_bytes,
        snapshot.page_storage_bytes
      )
      or not RAW_EQUAL(
        metadata.restore_bytes,
        snapshot.restore_bytes
      )
      or metadata.quarantined then
    return nil, "page-list changed during compaction"
  end
  return true
end

local function compact_page_transaction(
    self,
    page_index0,
    expected_generation,
    active,
    context
)
  local pin_state, lineage, state_err = pin_state_for(self)
  if not pin_state then
    return nil, state_err
  end
  local config = rawget(self, "_resident_config")
  local config_ok, config_err = validate_resident_config(config)
  if not config_ok then
    return nil, config_err
  end
  if not rawget(config, "codec") then
    return nil, "page-list resident restore adapter is not configured"
  end
  for _, method in ipairs(TRUSTED_INSTANCE_METHODS) do
    if not RAW_EQUAL(rawget(self, method), nil) then
      return nil, "page list cannot compact from invalid metadata"
    end
  end
  local pages = rawget(self, "_pages")
  local starts = rawget(self, "_starts")
  local generation = rawget(self, "_generation")
  local row_count = rawget(self, "_row_count")
  local current = rawget(pin_state, "current")
  local counts = rawget(pin_state, "counts")
  local storage_bytes = rawget(self, "_storage_bytes")
  local max_rows = rawget(self, "_max_rows")
  local max_bytes = rawget(self, "_max_bytes")
  local next_page_id = rawget(self, "_next_page_id")
  if not RAW_EQUAL(rawget(self, "_compact_active"), active)
      or rawget(active, "reentered")
      or not integer(generation)
      or generation > MAX_SAFE_INTEGER
      or not integer(row_count)
      or not integer(storage_bytes)
      or not positive_integer(max_rows)
      or not positive_integer(max_bytes)
      or max_bytes > U32_MAX
      or not positive_integer(next_page_id)
      or next_page_id > MAX_SAFE_INTEGER
      or type(current) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(current), nil)
      or type(counts) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(counts), nil)
      or type(pages) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(pages), nil)
      or type(starts) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(starts), nil) then
    return nil, "page list cannot compact from invalid metadata"
  end
  local page_count = #pages
  if #starts ~= page_count then
    return nil, "page list cannot compact from invalid metadata"
  end
  if not integer(page_index0)
      or page_index0 >= page_count then
    return nil, "page index is outside the list"
  end
  if not RAW_EQUAL(expected_generation, nil) then
    if not integer(expected_generation)
        or expected_generation > MAX_SAFE_INTEGER then
      return nil, "expected generation must be a safe non-negative integer"
    end
    if not RAW_EQUAL(expected_generation, generation) then
      return nil, "page-list generation changed before compaction"
    end
  end

  local page_index = page_index0 + 1
  local node = rawget(pages, page_index)
  local node_id = type(node) == "table" and rawget(node, "id") or nil
  local node_generation =
    type(node) == "table" and rawget(node, "created_generation") or nil
  local page_start = rawget(starts, page_index)
  if type(node) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(node), nil)
      or not RAW_EQUAL(NODE_LINEAGES[node], lineage)
      or not positive_integer(node_id)
      or node_id >= next_page_id
      or not integer(node_generation)
      or node_generation > generation
      or not RAW_EQUAL(rawget(current, node), true)
      or not RAW_EQUAL(rawget(counts, node), nil)
      or not integer(page_start) then
    return nil, "page is not an unpinned current PageList node"
  end
  local page = rawget(node, "page")
  local page_ok, page_err = PAGE_VALIDATE(page)
  if not page_ok then
    return nil, page_err
  end
  local metadata, _, metadata_err = node_metadata(node)
  if not metadata then
    return nil, metadata_err
  end
  if not RAW_EQUAL(metadata.max_rows, max_rows)
      or not RAW_EQUAL(metadata.max_bytes, max_bytes) then
    return nil, "page uses different PageList limits"
  end
  if metadata.kind ~= "raw" then
    return false, "only a raw page can be compacted"
  end
  if rawget(config, "max_pages") < 1
      or metadata.restore_bytes > rawget(config, "max_bytes") then
    return false, "page restore view exceeds resident cache limits"
  end

  local snapshot = {
    active = active,
    pin_state = pin_state,
    config = config,
    generation = generation,
    row_count = row_count,
    storage_bytes = storage_bytes,
    pages = pages,
    starts = starts,
    page_index = page_index,
    page_start = page_start,
    node = node,
    page = page,
    capability = NODE_CAPABILITIES[node],
    revision = metadata.revision,
    page_storage_bytes = metadata.storage_bytes,
    restore_bytes = metadata.restore_bytes,
  }
  snapshot.source =
    snapshot_compact_source(self, node, page, page_index)
  context.source = snapshot.source
  local callback_fence_err
  local function fence_callback()
    local fence_ok, fence_err = compact_fence(self, snapshot)
    if not fence_ok then
      callback_fence_err = fence_err
      ERROR("page-list compaction callback invalidated its source", 0)
    end
  end
  local function encode_callback(body, budget)
    local block = config.encode(body, budget)
    fence_callback()
    return block
  end
  local function checksum_callback(body)
    local checksum = config.crc32(body)
    fence_callback()
    return checksum
  end
  local candidate, prepare_err = PAGE_PREPARE_COLD(
    page,
    metadata.revision,
    {
      codec = rawget(config, "codec"),
      encode = encode_callback,
      crc32 = checksum_callback,
    },
    snapshot.capability
  )
  if not compact_source_matches(context.source) then
    restore_compact_source(context.source)
    context.source = nil
    if candidate then
      PAGE_DISCARD_CANDIDATE(candidate)
    end
    return nil, "resident codec mutated the source PageList"
  end
  context.source = nil
  if rawget(active, "reentered") then
    if candidate then
      PAGE_DISCARD_CANDIDATE(candidate)
    end
    return nil, "page-list changed during compaction"
  end
  if callback_fence_err then
    if candidate then
      PAGE_DISCARD_CANDIDATE(candidate)
    end
    return nil, callback_fence_err
  end
  if not candidate then
    return candidate, prepare_err
  end
  context.candidate = candidate

  local fence_ok, fence_err = compact_fence(self, snapshot)
  if not fence_ok then
    PAGE_DISCARD_CANDIDATE(candidate)
    context.candidate = nil
    return nil, fence_err
  end
  local candidate_metadata, candidate_err =
    PAGE_CANDIDATE_METADATA(candidate)
  if not candidate_metadata then
    PAGE_DISCARD_CANDIDATE(candidate)
    context.candidate = nil
    return nil, candidate_err
  end
  local next_storage = snapshot.storage_bytes
    - snapshot.page_storage_bytes
    + candidate_metadata.storage_bytes

  fence_ok, fence_err = compact_fence(self, snapshot)
  if not fence_ok then
    PAGE_DISCARD_CANDIDATE(candidate)
    context.candidate = nil
    return nil, fence_err
  end
  local published, old_storage, new_storage, revision =
    PAGE_PUBLISH_COLD(
      page,
      candidate,
      snapshot.revision,
      snapshot.capability
    )
  context.candidate = nil
  if not published then
    PAGE_DISCARD_CANDIDATE(candidate)
    return nil, old_storage
  end
  rawset(self, "_storage_bytes", next_storage)
  if old_storage ~= snapshot.page_storage_bytes
      or new_storage ~= candidate_metadata.storage_bytes
      or revision ~= snapshot.revision + 1 then
    return nil, "page publication returned inconsistent storage metadata"
  end
  return true, old_storage, new_storage, revision
end

--- Compact one exact current, unpinned raw Page using the snapshotted adapter.
--- Codec callbacks run behind a private reentry fence; publication itself is
--- callback-free and leaves the logical PageList generation unchanged.
function PageList:compact_page(page_index0, expected_generation)
  if type(self) ~= "table" then
    return nil, "page list must be a table"
  end
  if resident_is_active(self) then
    return nil, "page-list resident restore is already active"
  end
  if not RAW_EQUAL(rawget(self, "_splice_active"), nil) then
    return nil, "page-list splice is already active"
  end
  if compaction_is_active(self) then
    return nil, "page-list compaction is already active"
  end

  local active = { reentered = false }
  rawset(self, "_compact_active", active)
  local context = {}
  local called, compacted, second, third, fourth = pcall(
    compact_page_transaction,
    self,
    page_index0,
    expected_generation,
    active,
    context
  )
  if context.source then
    restore_compact_source(context.source)
    context.source = nil
  end
  if context.candidate then
    PAGE_DISCARD_CANDIDATE(context.candidate)
  end
  rawset(self, "_compact_active", nil)
  if not called then
    return nil, "page-list compaction threw: " .. diagnostic(compacted)
  end
  return compacted, second, third, fourth
end

local function summarize_pages(pages)
  local starts = {}
  local row_count = 0
  local decoded_bytes = 0
  local storage_bytes = 0
  local oversized_pages = 0
  for index, node in ipairs(pages) do
    local metadata, _, metadata_err = node_metadata(node)
    if not metadata then
      return nil, metadata_err
    end
    starts[index] = row_count
    row_count = row_count + metadata.row_count
    decoded_bytes = decoded_bytes + metadata.decoded_bytes
    storage_bytes = storage_bytes + metadata.storage_bytes
    if metadata.oversized then
      oversized_pages = oversized_pages + 1
    end
  end
  return starts, row_count, decoded_bytes, storage_bytes, oversized_pages
end

local function page_slice(
    self,
    page_start0,
    first,
    last,
    generation
)
  if first > last then
    return {}
  end
  local start0 = page_start0 + first - 1
  local count = last - first + 1
  local lease, lease_err = pin_range_impl(
    self,
    start0,
    count,
    generation,
    SPLICE_PIN_ACCESS
  )
  if not lease then
    return nil, lease_err
  end
  local rows, rows_err =
    pinned_rows_trusted(self, lease, start0, count)
  local released, release_err =
    release_pin_impl(self, lease, SPLICE_PIN_ACCESS)
  if not released then
    return nil, release_err
  end
  return rows, rows_err
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
    local first_metadata, first_page, first_metadata_err =
      node_metadata(first_node)
    if not first_metadata then
      return nil, first_metadata_err
    end
    local last_metadata, last_page, last_metadata_err =
      node_metadata(last_node)
    if not last_metadata then
      return nil, last_metadata_err
    end

    if first_local0 > 0 then
      local first_start0 = rawget(self._starts, first_page0 + 1)
      local rows, err = page_slice(
        self,
        first_start0,
        1,
        first_local0,
        before_generation
      )
      if not rows then
        return nil, err
      end
      left_rows = rows
    end

    local last_start0 = self._starts[last_page0 + 1]
    local first_retained1 = end0 - last_start0 + 1
    if first_retained1 <= last_metadata.row_count then
      local rows, err = page_slice(
        self,
        last_start0,
        first_retained1,
        last_metadata.row_count,
        before_generation
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
      local metadata, page, metadata_err = node_metadata(node)
      if not metadata then
        return nil, metadata_err
      end

      local page_start0 = rawget(self._starts, page_index0 + 1)
      local rows, err = page_slice(
        self,
        page_start0,
        1,
        local_row0,
        before_generation
      )
      if not rows then
        return nil, err
      end
      left_rows = rows
      rows, err = page_slice(
        self,
        page_start0,
        local_row0 + 1,
        metadata.row_count,
        before_generation
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
    lineage = rawget(self, "_lineage"),
    resident = rawget(self, "_resident_config"),
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
  if not starts then
    return nil, row_count
  end
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
  }, rawget(self, "_lineage"), rawget(self, "_resident_config"))
  local candidate_ok, candidate_err = validate_list(candidate)
  if not candidate_ok then
    return nil, candidate_err
  end

  local pin_state = rawget(self, "_pin_state")
  local resident_state, resident_state_err = resident_state_for(self)
  if not resident_state then
    return nil, resident_state_err
  end
  local next_current = {}
  for _, node in ipairs(candidate._pages) do
    next_current[node] = true
  end
  local retiring = {}
  local discarding = {}
  for node in next, pin_state.current do
    if not next_current[node] then
      if pin_state.counts[node] then
        retiring[#retiring + 1] = node
      else
        discarding[#discarding + 1] = node
      end
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
  for _, node in ipairs(retiring) do
    local entry = rawget(rawget(resident_state, "entries"), node)
    if entry then
      resident_unlink(resident_state, entry)
    end
    pin_state.retired[node] = true
    pin_state.current_pinned_pages =
      pin_state.current_pinned_pages - 1
    pin_state.retired_pinned_pages =
      pin_state.retired_pinned_pages + 1
  end
  for _, node in ipairs(discarding) do
    local entry = rawget(rawget(resident_state, "entries"), node)
    if entry then
      resident_drop_entry(resident_state, entry)
    end
    NODE_CAPABILITIES[node] = nil
    rawset(node, "page", nil)
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
  if resident_is_active(self) then
    return nil, "page-list resident restore is already active"
  end
  if not RAW_EQUAL(rawget(self, "_splice_active"), nil) then
    return nil, "page-list splice is already active"
  end
  if compaction_is_active(self) then
    return nil, "page-list compaction is already active"
  end

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
  local pin_stats = pin_stats_snapshot(rawget(self, "_pin_state"))
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
  local lineage = rawget(list, "_lineage")
  if not lineage or not RAW_EQUAL(RAW_METATABLE(list), PageList) then
    return nil, "page list is not an owned PageList"
  end
  for _, method in ipairs(TRUSTED_INSTANCE_METHODS) do
    if not RAW_EQUAL(rawget(list, method), nil) then
      return nil, "page list shadows trusted method " .. method
    end
  end
  local resident_ok, resident_err =
    validate_resident_config(rawget(list, "_resident_config"))
  if not resident_ok then
    return nil, resident_err
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
    local capability = NODE_CAPABILITIES[node]
    if not PAGE_IS_AUTHORIZED(page, node, capability) then
      return nil, STRING_FORMAT(
        "page %d is not owned by its PageList node",
        node_id
      )
    end
    local metadata, metadata_err = PAGE_METADATA(page)
    if not metadata then
      return nil, STRING_FORMAT(
        "page %d has invalid metadata: %s",
        node_id,
        metadata_err
      )
    end
    if metadata.max_rows ~= max_rows
        or metadata.max_bytes ~= max_bytes then
      return nil, STRING_FORMAT(
        "page %d uses different limits",
        node_id
      )
    end

    expected_start = expected_start + metadata.row_count
    decoded_bytes = decoded_bytes + metadata.decoded_bytes
    storage_bytes = storage_bytes + metadata.storage_bytes
    if metadata.oversized then
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
  local resident_state_ok, resident_state_err =
    validate_resident_state(
      list,
      lineage,
      rawget(list, "_pin_state")
    )
  if not resident_state_ok then
    return nil, resident_state_err
  end
  return true
end
PageList.validate = validate_list

local function public_layout(self)
  if type(self) ~= "table" then
    return nil, "page list must be a table"
  end
  local layout = LAYOUT_STATES[self]
  local handle_metatable =
    type(layout) == "table"
      and rawget(layout, "_handle_metatable")
      or nil
  local handle_ref =
    type(layout) == "table"
      and rawget(layout, "_handle_ref")
      or nil
  local handle_ref_metatable =
    type(handle_ref) == "table"
      and RAW_METATABLE(handle_ref)
      or nil
  if type(layout) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(layout), PageList)
      or type(handle_metatable) ~= "table"
      or type(handle_ref) ~= "table"
      or type(handle_ref_metatable) ~= "table"
      or not RAW_EQUAL(rawget(handle_ref_metatable, "__mode"), "v")
      or not RAW_EQUAL(rawget(handle_ref, 1), self)
      or not RAW_EQUAL(RAW_METATABLE(self), handle_metatable)
      or not RAW_EQUAL(
        rawget(handle_metatable, "__index"),
        PageList
      )
      or not RAW_EQUAL(
        rawget(handle_metatable, HANDLE_LAYOUT_ACCESS),
        layout
      )
      or not RAW_EQUAL(
        rawget(handle_metatable, "__metatable"),
        PageList
      ) then
    return nil, "page list is not an owned PageList"
  end
  for key in next, handle_metatable do
    if not RAW_EQUAL(key, "__index")
        and not RAW_EQUAL(key, "__metatable")
        and not RAW_EQUAL(key, HANDLE_LAYOUT_ACCESS) then
      return nil, "page list is not an owned PageList"
    end
  end
  for key in next, handle_ref do
    if not RAW_EQUAL(key, 1) then
      return nil, "page list is not an owned PageList"
    end
  end
  for key in next, handle_ref_metatable do
    if not RAW_EQUAL(key, "__mode") then
      return nil, "page list is not an owned PageList"
    end
  end
  return layout
end

local function wrap_instance_method(implementation)
  local function retain_handle(_, ...)
    return ...
  end
  return function(self, ...)
    local layout, layout_err = public_layout(self)
    if not layout then
      return nil, layout_err
    end
    return retain_handle(self, implementation(layout, ...))
  end
end

for _, method in ipairs(TRUSTED_INSTANCE_METHODS) do
  PageList[method] = wrap_instance_method(PageList[method])
end

return PageList
