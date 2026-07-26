local H = require("helpers")
local Page = require("canvasdiff.canvas.Page")
local PageList = require("canvasdiff.canvas.PageList")

local T = {}

local function test_crc32(raw)
  local checksum = 0
  for index = 1, #raw do
    checksum =
      (checksum + string.byte(raw, index) * index) % 4294967296
  end
  return checksum
end

local function expected_view_bytes(row)
  -- Every fixture below uses one row per Page and therefore two u16 offsets.
  return #row + 4
end

local function new_adapter_state()
  local state = {
    bodies = {},
    block_ids = {},
    encode_calls = 0,
    decode_calls = {},
    crc_calls = 0,
    ready = false,
  }

  local adapter = {
    codec = "page-cache-test-v1",
    encode = function(body)
      state.encode_calls = state.encode_calls + 1
      local block = string.char(state.encode_calls)
      state.bodies[block] = body
      state.block_ids[block] = state.encode_calls
      return block
    end,
    decode = function(block, expected_bytes)
      local id = state.block_ids[block]
      state.decode_calls[id] = (state.decode_calls[id] or 0) + 1
      if state.ready and state.on_decode then
        return state.on_decode(
          block,
          expected_bytes,
          state.bodies[block],
          id
        )
      end
      return state.bodies[block]
    end,
    crc32 = function(body)
      if state.ready then
        state.crc_calls = state.crc_calls + 1
        if state.on_crc32 then
          return state.on_crc32(body)
        end
      end
      return test_crc32(body)
    end,
  }
  state.adapter = adapter
  return state
end

local function cold_fixture(rows, limits, Module)
  Module = Module or PageList
  limits = limits or {}
  local state = new_adapter_state()
  local list = assert(Module.new(rows, {
    max_rows = 1,
    resident = {
      max_pages = limits.max_pages or #rows,
      max_bytes = limits.max_bytes or 1024 * 1024,
      restore = state.adapter,
    },
  }))
  state.list = list

  for page_index0 = 0, list:page_count() - 1 do
    local compacted, compact_err =
      list:compact_page(page_index0, list:generation())
    assert(compacted, compact_err)
  end

  state.view_bytes = {}
  for page_index0 = 0, list:page_count() - 1 do
    local metadata = assert(list:inspect_page(page_index0))
    H.eq(metadata.kind, "cold")
    state.view_bytes[page_index0 + 1] = metadata.view_bytes
  end
  state.decode_calls = {}
  state.crc_calls = 0
  state.ready = true
  return list, state
end

local function cache_stats(
    max_pages,
    max_bytes,
    pages,
    bytes,
    pinned_pages,
    unpinned_pages,
    reserved_pages,
    reserved_bytes
)
  return {
    pages = pages or 0,
    bytes = bytes or 0,
    pinned_pages = pinned_pages or 0,
    unpinned_pages = unpinned_pages or 0,
    reserved_pages = reserved_pages or 0,
    reserved_bytes = reserved_bytes or 0,
    max_pages = max_pages,
    max_bytes = max_bytes,
  }
end

local function assert_cache(
    list,
    max_pages,
    max_bytes,
    pages,
    bytes,
    pinned_pages,
    unpinned_pages,
    reserved_pages,
    reserved_bytes
)
  H.eq(list:resident_stats(), cache_stats(
    max_pages,
    max_bytes,
    pages,
    bytes,
    pinned_pages,
    unpinned_pages,
    reserved_pages,
    reserved_bytes
  ))
end

local function decode_count(state, page_index1)
  return state.decode_calls[page_index1] or 0
end

local function assert_rejected(value, err)
  H.eq(value, nil)
  assert(type(err) == "string" and err ~= "", tostring(err))
end

local function collect_until(predicate)
  for _ = 1, 20 do
    collectgarbage("collect")
  end
  return predicate()
end

local function launch_worker(run)
  local result = {}
  local function worker_body()
    run(result)
    result.done = true
  end
  if type(jit) == "table" and type(jit.off) == "function" then
    jit.off(run, true)
    jit.off(worker_body, true)
  end
  local worker = coroutine.create(worker_body)
  local weak_worker = setmetatable({ worker }, { __mode = "v" })
  local resumed, err = coroutine.resume(worker)
  assert(resumed, err)
  worker = nil
  -- LuaJIT traces may retain dead coroutine slots after the weak thread
  -- reference clears. Flush only after the exercised code has completed so
  -- this probe measures the object graph rather than a stale trace snapshot.
  if type(jit) == "table" and type(jit.flush) == "function" then
    jit.flush()
  end
  H.eq(result.done, true)
  return weak_worker, result
end

local function corrupt_handle_metatable(handle, mode)
  local metatable = debug.getmetatable(handle)
  local hostile_index = function()
    error("corrupt owner index executed")
  end
  if mode == "replace" then
    debug.setmetatable(handle, {
      __index = hostile_index,
      __metatable = false,
    })
  else
    rawset(metatable, "__index", hostile_index)
    rawset(metatable, "evil", true)
  end
end

local function assert_handle_metatable(handle, metatable, index)
  assert(debug.getmetatable(handle) == metatable)
  assert(rawget(metatable, "__index") == index)
  H.eq(rawget(metatable, "__metatable"), PageList)
  local count = 0
  local private_count = 0
  for key, value in next, metatable do
    if key ~= "__index" and key ~= "__metatable" then
      assert(type(key) == "table", tostring(key))
      assert(type(value) == "table")
      assert(rawget(value, "_handle_metatable") == metatable)
      private_count = private_count + 1
    end
    count = count + 1
  end
  H.eq(count, 3)
  H.eq(private_count, 1)
end

local function debug_layout_for_test(handle)
  local metatable = debug.getmetatable(handle)
  for key, value in next, metatable do
    if type(value) == "table"
        and rawget(value, "_handle_metatable") == metatable
        and type(rawget(value, "_handle_ref")) == "table" then
      return value, key
    end
  end
  error("opaque test handle has no private layout slot")
end

local function debug_layout_registry_for_test(handle, layout)
  local wrapper_index = 1
  while true do
    local wrapper_name, wrapper_value =
      debug.getupvalue(PageList.rows, wrapper_index)
    if wrapper_name == nil then
      break
    end
    if type(wrapper_value) == "function" then
      local owner_index = 1
      while true do
        local owner_name, owner_value =
          debug.getupvalue(wrapper_value, owner_index)
        if owner_name == nil then
          break
        end
        local metatable = type(owner_value) == "table"
          and debug.getmetatable(owner_value)
          or nil
        if type(metatable) == "table"
            and rawget(metatable, "__mode") == "kv"
            and rawget(owner_value, handle) == layout then
          return owner_value
        end
        owner_index = owner_index + 1
      end
    end
    wrapper_index = wrapper_index + 1
  end
  error("opaque test handle has no private layout registry")
end

local function seed_handle_decoys(handle)
  local layout, layout_key = debug_layout_for_test(handle)
  local handle_ref = rawget(layout, "_handle_ref")
  local snapshot = {
    pages = { "intentional pages decoy" },
    starts = "intentional starts decoy",
    generation = 37,
    layout = layout,
    layout_key = layout_key,
    layout_registry =
      debug_layout_registry_for_test(handle, layout),
    handle_ref = handle_ref,
    handle_ref_metatable = debug.getmetatable(handle_ref),
  }
  rawset(handle, "pages", snapshot.pages)
  rawset(handle, "starts", snapshot.starts)
  rawset(handle, "generation", snapshot.generation)
  return snapshot
end

local function corrupt_handle_entries(handle, registry_mode, layout_mode)
  rawset(handle, "pages", { "replacement pages decoy" })
  rawset(handle, "starts", nil)
  rawset(handle, "rows", function()
    error("hostile raw rows shadow executed")
  end)
  local layout, layout_key = debug_layout_for_test(handle)
  local layout_registry =
    debug_layout_registry_for_test(handle, layout)
  local handle_ref = rawget(layout, "_handle_ref")
  local handle_ref_metatable = debug.getmetatable(handle_ref)
  rawset(handle_ref, 1, nil)
  rawset(handle_ref, "evil", true)
  rawset(handle_ref_metatable, "__mode", "k")
  rawset(handle_ref_metatable, "evil", true)
  debug.setmetatable(handle_ref, {})
  rawset(
    debug.getmetatable(handle),
    layout_key,
    layout_mode == "replace" and {} or nil
  )
  rawset(
    layout_registry,
    handle,
    registry_mode == "replace" and {} or nil
  )
end

local function assert_handle_decoys(handle, snapshot)
  assert(rawget(handle, "pages") == snapshot.pages)
  H.eq(rawget(handle, "starts"), snapshot.starts)
  H.eq(rawget(handle, "generation"), snapshot.generation)
  H.eq(rawget(handle, "rows"), nil)
  local count = 0
  for key in next, handle do
    assert(
      key == "pages" or key == "starts" or key == "generation",
      tostring(key)
    )
    count = count + 1
  end
  H.eq(count, 3)
  assert(
    rawget(debug.getmetatable(handle), snapshot.layout_key)
      == snapshot.layout
  )
  assert(
    rawget(snapshot.layout_registry, handle) == snapshot.layout
  )
  local handle_ref = rawget(snapshot.layout, "_handle_ref")
  assert(handle_ref == snapshot.handle_ref)
  assert(rawget(handle_ref, 1) == handle)
  H.eq(rawget(handle_ref, "evil"), nil)
  assert(debug.getmetatable(handle_ref) == snapshot.handle_ref_metatable)
  H.eq(rawget(snapshot.handle_ref_metatable, "__mode"), "v")
  H.eq(rawget(snapshot.handle_ref_metatable, "evil"), nil)
  local metatable_count = 0
  for key in next, snapshot.handle_ref_metatable do
    H.eq(key, "__mode")
    metatable_count = metatable_count + 1
  end
  H.eq(metatable_count, 1)
  count = 0
  for key in next, handle_ref do
    H.eq(key, 1)
    count = count + 1
  end
  H.eq(count, 1)
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

local function isolated_pagelist_with_claims()
  local claims = {}
  local original_claim = Page.claim
  local Isolated = load_isolated_pagelist({
    claim = function(page, node)
      local claimed, capability = original_claim(page, node)
      if claimed then
        claims[#claims + 1] = {
          node = node,
          page = page,
        }
      end
      return claimed, capability
    end,
  })
  return Isolated, claims
end

local function isolated_pagelist_with_weak_claims()
  local nodes = setmetatable({}, { __mode = "v" })
  local pages = setmetatable({}, { __mode = "v" })
  local claim_count = 0
  local original_claim = Page.claim
  local Isolated = load_isolated_pagelist({
    claim = function(page, node)
      local claimed, capability = original_claim(page, node)
      if claimed then
        claim_count = claim_count + 1
        nodes[claim_count] = node
        pages[claim_count] = page
      end
      return claimed, capability
    end,
  })
  return Isolated, nodes, pages
end

T["page_cache_ raw pages bypass zero-capacity cache"] = function()
  local rows = { "raw-a", "raw-b", "raw-c" }
  local list = PageList.new(rows, {
    max_rows = 1,
    resident = { max_pages = 0, max_bytes = 0 },
  })
  assert_cache(list, 0, 0)

  local lease = assert(list:pin_range(0, #rows, 0))
  assert_cache(list, 0, 0)
  H.eq(list:pinned_row(lease, 0), rows[1])
  H.eq(list:pinned_row(lease, 2), rows[3])
  H.eq(list:pinned_rows(lease, 0, #rows), rows)
  H.eq(list:release_pin(lease), true)
  assert_cache(list, 0, 0)
  H.eq(PageList.validate(list), true)
end

T["page_cache_ hard page and byte limits fail before callbacks"] =
  function()
    local page_limited, page_state = cold_fixture({
      "page-limit-a",
      "page-limit-b",
    }, {
      max_pages = 1,
      max_bytes = 1024,
    })
    local lease, err = page_limited:pin_range(0, 2, 0)
    assert_rejected(lease, err)
    H.eq(page_state.decode_calls, {})
    H.eq(page_state.crc_calls, 0)
    assert_cache(page_limited, 1, 1024)
    H.eq(PageList.validate(page_limited), true)

    local rows = {
      string.rep("a", 12),
      string.rep("b", 17),
    }
    local sum_bytes =
      expected_view_bytes(rows[1]) + expected_view_bytes(rows[2])
    local byte_limited, byte_state = cold_fixture(rows, {
      max_pages = 2,
      max_bytes = sum_bytes - 1,
    })
    H.eq(byte_state.view_bytes, {
      expected_view_bytes(rows[1]),
      expected_view_bytes(rows[2]),
    })
    lease, err = byte_limited:pin_range(0, 2, 0)
    assert_rejected(lease, err)
    H.eq(byte_state.decode_calls, {})
    H.eq(byte_state.crc_calls, 0)
    assert_cache(byte_limited, 2, sum_bytes - 1)
    H.eq(PageList.validate(byte_limited), true)
  end

T["page_cache_ reservations expose exact hard-bound accounting"] =
  function()
    local rows = {
      string.rep("a", 12),
      string.rep("b", 17),
    }
    local sum_bytes =
      expected_view_bytes(rows[1]) + expected_view_bytes(rows[2])
    local list, state = cold_fixture(rows, {
      max_pages = 2,
      max_bytes = sum_bytes,
    })
    local observed = {}
    local function observe(phase)
      local stats = list:resident_stats()
      observed[#observed + 1] = { phase = phase, stats = stats }
      assert(stats.pages + stats.reserved_pages <= stats.max_pages)
      assert(stats.bytes + stats.reserved_bytes <= stats.max_bytes)
      H.eq(stats.reserved_pages, 2)
      H.eq(stats.reserved_bytes, sum_bytes)
    end
    state.on_decode = function(_, _, body)
      observe("decode")
      return body
    end
    state.on_crc32 = function(body)
      observe("crc32")
      return test_crc32(body)
    end

    local lease = assert(list:pin_range(0, 2, 0))
    H.eq(#observed, 4)
    H.eq(observed[1].phase, "decode")
    H.eq(observed[1].stats.reserved_pages, 2)
    H.eq(observed[1].stats.reserved_bytes, sum_bytes)
    assert_cache(list, 2, sum_bytes, 2, sum_bytes, 2, 0)
    H.eq(list:pinned_rows(lease, 0, 2), rows)
    H.eq(list:release_pin(lease), true)
    assert_cache(list, 2, sum_bytes, 2, sum_bytes, 0, 2)
    H.eq(PageList.validate(list), true)
  end

T["page_cache_ overlapping leases share one restored view"] = function()
  local row = "overlap-overlap-overlap"
  local bytes = expected_view_bytes(row)
  local list, state = cold_fixture({ row }, {
    max_pages = 1,
    max_bytes = bytes,
  })

  local first = assert(list:pin_range(0, 1, 0))
  H.eq(decode_count(state, 1), 1)
  assert_cache(list, 1, bytes, 1, bytes, 1, 0)
  local second = assert(list:pin_range(0, 1, 0))
  H.eq(decode_count(state, 1), 1)
  assert_cache(list, 1, bytes, 1, bytes, 1, 0)
  H.eq(list:pinned_row(first, 0), row)
  H.eq(list:pinned_row(second, 0), row)

  H.eq(list:release_pin(first), true)
  assert_cache(list, 1, bytes, 1, bytes, 1, 0)
  H.eq(list:pinned_row(second, 0), row)
  H.eq(list:release_pin(second), true)
  assert_cache(list, 1, bytes, 1, bytes, 0, 1)

  local third = assert(list:pin_range(0, 1, 0))
  H.eq(decode_count(state, 1), 1)
  H.eq(list:release_pin(third), true)
  H.eq(PageList.validate(list), true)
end

T["page_cache_ hit pinning and terminal release update exact LRU"] =
  function()
    local rows = {
      "lru-a-lru-a",
      "lru-b-lru-b",
      "lru-c-lru-c",
    }
    local bytes = expected_view_bytes(rows[1])
    local list, state = cold_fixture(rows, {
      max_pages = 2,
      max_bytes = bytes * 2,
    })

    local a = assert(list:pin_range(0, 1, 0))
    H.eq(list:release_pin(a), true)
    local b = assert(list:pin_range(1, 1, 0))
    H.eq(list:release_pin(b), true)
    H.eq({ decode_count(state, 1), decode_count(state, 2) }, { 1, 1 })
    assert_cache(list, 2, bytes * 2, 2, bytes * 2, 0, 2)

    -- A hit must detach A while pinned and return it exactly once at MRU.
    a = assert(list:pin_range(0, 1, 0))
    assert_cache(list, 2, bytes * 2, 2, bytes * 2, 1, 1)
    H.eq(list:release_pin(a), true)

    local c = assert(list:pin_range(2, 1, 0))
    H.eq(decode_count(state, 3), 1)
    H.eq(list:pinned_row(c, 2), rows[3])
    H.eq(list:release_pin(c), true)

    -- B was LRU after A's hit and therefore had to be the first victim.
    b = assert(list:pin_range(1, 1, 0))
    H.eq(decode_count(state, 2), 2)
    assert_cache(list, 2, bytes * 2, 2, bytes * 2, 1, 1)
    local c_hit = assert(list:pin_range(2, 1, 0))
    H.eq(decode_count(state, 3), 1)
    H.eq(list:release_pin(c_hit), true)
    H.eq(list:release_pin(b), true)
    H.eq(PageList.validate(list), true)
  end

T["page_cache_ infeasible request preserves cache but feasible fault evicts"] =
  function()
    local rows = {
      "victim-a-victim-a",
      "fault-b-fault-b",
    }
    local bytes = expected_view_bytes(rows[1])
    local list, state = cold_fixture(rows, {
      max_pages = 1,
      max_bytes = bytes,
    })

    local held = assert(list:pin_range(0, 1, 0))
    local before_calls = decode_count(state, 2)
    local rejected, err = list:pin_range(1, 1, 0)
    assert_rejected(rejected, err)
    H.eq(decode_count(state, 2), before_calls)
    assert_cache(list, 1, bytes, 1, bytes, 1, 0)
    H.eq(list:pinned_row(held, 0), rows[1])

    H.eq(list:release_pin(held), true)
    state.on_decode = function(_, _, body, id)
      if id == 2 then
        return false
      end
      return body
    end
    rejected, err = list:pin_range(1, 1, 0)
    assert_rejected(rejected, err)
    H.eq(decode_count(state, 2), before_calls + 1)
    -- The now-unpinned A had to be released before B's hard reservation.
    assert_cache(list, 1, bytes)

    state.on_decode = nil
    local restored = assert(list:pin_range(0, 1, 0))
    H.eq(decode_count(state, 1), 2)
    H.eq(list:pinned_row(restored, 0), rows[1])
    H.eq(list:release_pin(restored), true)
    H.eq(PageList.validate(list), true)

    -- A failed transaction must not detach or promote a protected hit.
    rows = {
      "protected-a-protected-a",
      "protected-b-protected-b",
      "protected-c-protected-c",
    }
    bytes = expected_view_bytes(rows[1])
    list, state = cold_fixture(rows, {
      max_pages = 2,
      max_bytes = bytes * 2,
    })
    local a = assert(list:pin_range(0, 1, 0))
    H.eq(list:release_pin(a), true)
    local b = assert(list:pin_range(1, 1, 0))
    H.eq(list:release_pin(b), true)
    a = assert(list:pin_range(0, 1, 0))
    before_calls = decode_count(state, 3)
    rejected, err = list:pin_range(1, 2, 0)
    assert_rejected(rejected, err)
    H.eq(decode_count(state, 3), before_calls)
    H.eq(list:release_pin(a), true)

    local c = assert(list:pin_range(2, 1, 0))
    H.eq(decode_count(state, 3), before_calls + 1)
    b = assert(list:pin_range(1, 1, 0))
    H.eq(decode_count(state, 2), 2,
      "failed protected hit must remain the next LRU victim")
    H.eq(list:release_pin(b), true)
    H.eq(list:release_pin(c), true)
    H.eq(PageList.validate(list), true)
  end

T["page_cache_ mixed cold and raw range accounts only restored bytes"] =
  function()
    local state = new_adapter_state()
    local rows = {
      "cold-cold-cold",
      "raw-raw-raw",
    }
    local cold_bytes = expected_view_bytes(rows[1])
    local list = PageList.new(rows, {
      max_rows = 1,
      resident = {
        max_pages = 1,
        max_bytes = cold_bytes,
        restore = state.adapter,
      },
    })
    assert(list:compact_page(0, 0))
    state.decode_calls = {}
    state.crc_calls = 0
    state.ready = true

    local lease = assert(list:pin_range(0, 2, 0))
    H.eq(decode_count(state, 1), 1)
    H.eq(state.crc_calls, 1)
    assert_cache(list, 1, cold_bytes, 1, cold_bytes, 1, 0)
    H.eq(list:pinned_rows(lease, 0, 2), rows)
    H.eq(list:release_pin(lease), true)
    assert_cache(list, 1, cold_bytes, 1, cold_bytes, 0, 1)
    H.eq(PageList.validate(list), true)
  end

T["page_cache_ stale and empty leases fence their absolute ranges"] =
  function()
    local list = PageList.new({ "a", "b", "c" }, {
      max_rows = 1,
      resident = { max_pages = 0, max_bytes = 0 },
    })
    local lease = assert(list:pin_range(1, 2, 0))
    H.eq(list:pinned_row(lease, 1), "b")
    H.eq(list:pinned_row(lease, 2), "c")
    H.eq(list:pinned_rows(lease, 1, 2), { "b", "c" })
    local value, err = list:pinned_row(lease, 0)
    assert_rejected(value, err)
    value, err = list:pinned_row(lease, 3)
    assert_rejected(value, err)
    value, err = list:pinned_rows(lease, 0, 1)
    assert_rejected(value, err)

    local empty = assert(list:pin_range(3, 0, 0))
    H.eq(list:pinned_rows(empty, 3, 0), {})
    value, err = list:pinned_row(empty, 3)
    assert_rejected(value, err)

    assert(list:splice(3, 0, { "d" }))
    value, err = list:pinned_row(lease, 1)
    assert_rejected(value, err)
    value, err = list:pinned_rows(empty, 3, 0)
    assert_rejected(value, err)
    H.eq(list:release_pin(empty), true)
    H.eq(list:release_pin(lease), true)
    H.eq(PageList.validate(list), true)
  end

T["page_cache_ retired final release purges view and hides lease internals"] =
  function()
    local weak_worker, result = launch_worker(function(result)
      local row = "retired-retired-retired"
      local bytes = expected_view_bytes(row)
      local Isolated, weak_nodes, weak_pages =
        isolated_pagelist_with_weak_claims()
      local list, state = cold_fixture({ row }, {
        max_pages = 1,
        max_bytes = bytes,
      }, Isolated)
      local lease = assert(list:pin_range(0, 1, 0))
      H.eq(next(lease), nil)
      H.eq(decode_count(state, 1), 1)
      assert(list:splice(0, 1, {}))
      H.eq(list:pin_is_current(lease), false)
      H.eq(next(lease), nil)
      assert_cache(list, 1, bytes, 1, bytes, 1, 0)
      local value, err = list:pinned_row(lease, 0)
      assert_rejected(value, err)
      collectgarbage("collect")
      collectgarbage("collect")

      H.eq(list:release_pin(lease), true)
      assert_cache(list, 1, bytes)
      H.eq(next(lease), nil)
      H.eq(list:pin_stats().retired_pinned_pages, 0)
      H.eq(rawget(assert(weak_nodes[1]), "page"), nil)
      H.eq(Isolated.validate(list), true)

      local scrub_row = "scrub-scrub-scrub"
      local scrub_bytes = expected_view_bytes(scrub_row)
      local scrub = cold_fixture({ scrub_row }, {
        max_pages = 1,
        max_bytes = scrub_bytes,
      }, Isolated)
      local scrub_lease = assert(scrub:pin_range(0, 1, 0))
      H.eq(scrub:release_pin(scrub_lease), true)
      H.eq(Isolated.validate(scrub), true)
      result.Isolated = Isolated
      result.list = list
      result.weak_nodes = weak_nodes
      result.weak_pages = weak_pages
    end)
    assert(collect_until(function()
      return weak_worker[1] == nil
    end), "retired cache setup worker was retained")
    local Isolated = result.Isolated
    local list = result.list
    local weak_nodes = result.weak_nodes
    local weak_pages = result.weak_pages
    local collected = collect_until(function()
      return weak_nodes[1] == nil and weak_pages[1] == nil
    end)
    if not collected then
      error(("released retired lease/cache retained node=%s Page=%s"):format(
        tostring(weak_nodes[1] ~= nil),
        tostring(weak_pages[1] ~= nil)
      ))
    end
    H.eq(Isolated.validate(list), true)
  end

T["page_cache_ malformed restore quarantines without partial cache"] =
  function()
    local cases = {
      {
        name = "decode throw",
        decode = function()
          error(string.rep("decode-fault", 100))
        end,
      },
      {
        name = "decode decline",
        decode = function()
          return false
        end,
      },
      {
        name = "decode nil",
        decode = function()
          return nil
        end,
      },
      {
        name = "decode type",
        decode = function()
          return {}
        end,
      },
      {
        name = "decode size",
        decode = function(_, _, body)
          return body .. "\0"
        end,
      },
      {
        name = "offsets",
        decode = function(_, expected_bytes)
          return string.rep("\255", expected_bytes)
        end,
      },
      {
        name = "crc throw",
        crc32 = function()
          error(string.rep("crc-fault", 100))
        end,
      },
      {
        name = "crc type",
        crc32 = function()
          return false
        end,
      },
      {
        name = "crc mismatch",
        crc32 = function(body)
          return (test_crc32(body) + 1) % 4294967296
        end,
      },
    }

    for _, case in ipairs(cases) do
      local row = "malformed-" .. case.name .. "-payload"
      local bytes = expected_view_bytes(row)
      local list, state = cold_fixture({ row }, {
        max_pages = 1,
        max_bytes = bytes,
      })
      state.on_decode = case.decode
      state.on_crc32 = case.crc32
      local lease, err = list:pin_range(0, 1, 0)
      assert_rejected(lease, err)
      assert_cache(list, 1, bytes)
      H.eq(list:pin_stats().active_leases, 0)
      local metadata = assert(list:inspect_page(0))
      H.eq(metadata.quarantined, true, case.name)

      local decode_calls = decode_count(state, 1)
      local crc_calls = state.crc_calls
      lease, err = list:pin_range(0, 1, 0)
      assert_rejected(lease, err)
      H.eq(decode_count(state, 1), decode_calls, case.name)
      H.eq(state.crc_calls, crc_calls, case.name)
      assert_cache(list, 1, bytes)
      H.eq(PageList.validate(list), true)
    end
  end

T["page_cache_ later miss failure releases every pending raw view"] =
  function()
    local release_calls = 0
    local original_release = Page.release_view
    local Isolated = load_isolated_pagelist({
      release_view = function(view)
        release_calls = release_calls + 1
        return original_release(view)
      end,
    })
    local rows = {
      "pending-good-pending-good",
      "pending-bad-pending-bad",
    }
    local bytes =
      expected_view_bytes(rows[1]) + expected_view_bytes(rows[2])
    local list, state = cold_fixture(rows, {
      max_pages = 2,
      max_bytes = bytes,
    }, Isolated)
    state.on_decode = function(_, _, body, id)
      if id == 2 then
        return false
      end
      return body
    end

    local lease, err = list:pin_range(0, 2, 0)
    assert_rejected(lease, err)
    H.eq(release_calls, 1)
    assert_cache(list, 2, bytes)
    H.eq(list:pin_stats().active_leases, 0)

    state.on_decode = nil
    lease = assert(list:pin_range(0, 1, 0))
    H.eq(decode_count(state, 1), 2)
    H.eq(list:pinned_row(lease, 0), rows[1])
    H.eq(list:release_pin(lease), true)
    H.eq(Isolated.validate(list), true)
  end

T["page_cache_ invalid cache hit is purged and restored at same revision"] =
  function()
    local reject_once = false
    local validate_calls = 0
    local original_validate = Page.validate_view
    local Isolated = load_isolated_pagelist({
      validate_view = function(view, page, revision)
        validate_calls = validate_calls + 1
        if reject_once then
          reject_once = false
          return nil, "injected stale resident view"
        end
        return original_validate(view, page, revision)
      end,
    })
    local row = "validate-hit-validate-hit"
    local bytes = expected_view_bytes(row)
    local list, state = cold_fixture({ row }, {
      max_pages = 1,
      max_bytes = bytes,
    }, Isolated)

    local first = assert(list:pin_range(0, 1, 0))
    H.eq(list:release_pin(first), true)
    H.eq(decode_count(state, 1), 1)
    local before_validate = validate_calls

    reject_once = true
    local second = assert(list:pin_range(0, 1, 0))
    assert(validate_calls > before_validate)
    H.eq(decode_count(state, 1), 2)
    H.eq(list:pinned_row(second, 0), row)
    assert_cache(list, 1, bytes, 1, bytes, 1, 0)
    H.eq(list:release_pin(second), true)
    H.eq(Isolated.validate(list), true)
  end

T["page_cache_ quarantined hit is purged without a revision shortcut"] =
  function()
    local capabilities = setmetatable({}, { __mode = "k" })
    local captured_page
    local original_claim = Page.claim
    local Isolated = load_isolated_pagelist({
      claim = function(page, node)
        local claimed, capability = original_claim(page, node)
        if claimed then
          capabilities[page] = capability
          captured_page = page
        end
        return claimed, capability
      end,
    })
    local row = "quarantine-hit-quarantine-hit"
    local bytes = expected_view_bytes(row)
    local list, state = cold_fixture({ row }, {
      max_pages = 1,
      max_bytes = bytes,
    }, Isolated)
    local page = assert(captured_page)
    local before = assert(Page.metadata(page))

    local lease = assert(list:pin_range(0, 1, 0))
    H.eq(list:release_pin(lease), true)
    assert_cache(list, 1, bytes, 1, bytes, 0, 1)
    local decode_calls = decode_count(state, 1)

    local view, quarantine_err = Page.read_view(page, before.revision, {
      codec = state.adapter.codec,
      decode = function()
        return false
      end,
      crc32 = test_crc32,
    }, assert(capabilities[page]))
    H.eq(view, nil)
    assert(quarantine_err:find("decode failed", 1, true), quarantine_err)
    local quarantined = assert(Page.metadata(page))
    H.eq(quarantined.revision, before.revision)
    H.eq(quarantined.quarantined, true)

    lease, quarantine_err = list:pin_range(0, 1, 0)
    assert_rejected(lease, quarantine_err)
    H.eq(decode_count(state, 1), decode_calls,
      "a quarantined hit must not invoke the adapter again")
    assert_cache(list, 1, bytes)
    H.eq(Page.metadata(page).revision, before.revision)
    H.eq(Isolated.validate(list), true)
  end

T["page_cache_ decode and crc reentry poison every lease operation"] =
  function()
    for _, phase in ipairs({ "decode", "crc32" }) do
      local rows = {
        "reentry-target-reentry-target",
        "reentry-keeper-reentry-keeper",
      }
      local bytes =
        expected_view_bytes(rows[1]) + expected_view_bytes(rows[2])
      local list, state = cold_fixture(rows, {
        max_pages = 2,
        max_bytes = bytes,
      })
      local keeper = assert(list:pin_range(1, 1, 0))
      local before_crc = state.crc_calls
      local nested
      local function reenter()
        nested = {
          pin = { list:pin_range(1, 1, 0) },
          row = { list:row(0) },
          rows = { list:rows(0, 1) },
          pinned_row = { list:pinned_row(keeper, 1) },
          pinned_rows = { list:pinned_rows(keeper, 1, 1) },
          release = { list:release_pin(keeper) },
          splice = { list:splice(2, 0, { "nested" }) },
          compact = { list:compact_page(0, 0) },
        }
        return list:resident_stats()
      end
      if phase == "decode" then
        state.on_decode = function(_, _, body)
          local stats = reenter()
          H.eq(stats.reserved_pages, 1)
          return body
        end
      else
        state.on_crc32 = function(body)
          local stats = reenter()
          H.eq(stats.reserved_pages, 1)
          return test_crc32(body)
        end
      end

      local lease, err = list:pin_range(0, 1, 0)
      assert_rejected(lease, err)
      assert(err:find("changed during resident restore", 1, true), err)
      assert(nested, phase)
      for name, result in pairs(nested) do
        H.eq(result[1], nil, phase .. " " .. name)
        assert(
          result[2]:find("resident restore is already active", 1, true),
          phase .. " " .. name .. ": " .. tostring(result[2])
        )
      end
      if phase == "decode" then
        H.eq(state.crc_calls, before_crc,
          "decode cancellation must stop before CRC")
      else
        H.eq(state.crc_calls, before_crc + 1)
      end
      H.eq(
        assert(list:inspect_page(0)).quarantined,
        false,
        phase
      )
      H.eq(list:pinned_row(keeper, 1), rows[2])
      assert_cache(
        list,
        2,
        bytes,
        1,
        expected_view_bytes(rows[2]),
        1,
        0
      )

      state.on_decode = nil
      state.on_crc32 = nil
      lease = assert(list:pin_range(0, 1, 0))
      H.eq(list:pinned_row(lease, 0), rows[1])
      H.eq(list:release_pin(lease), true)
      H.eq(list:release_pin(keeper), true)
      H.eq(PageList.validate(list), true)
    end
  end

T["page_cache_ restore callbacks restore the opaque owner metatable"] =
  function()
    for _, phase in ipairs({ "decode", "crc32" }) do
      for _, mode in ipairs({ "mutate", "replace" }) do
        local row = "owner-metatable-owner-metatable"
        local bytes = expected_view_bytes(row)
        local list, state = cold_fixture({ row }, {
          max_pages = 1,
          max_bytes = bytes,
        })
        local metatable = debug.getmetatable(list)
        local index = rawget(metatable, "__index")
        local page_before = assert(list:inspect_page(0))
        local pins_before = list:pin_stats()
        local function corrupt()
          corrupt_handle_metatable(list, mode)
        end
        if phase == "decode" then
          state.on_decode = function(_, _, body)
            corrupt()
            return body
          end
        else
          state.on_crc32 = function(body)
            corrupt()
            return test_crc32(body)
          end
        end

        local lease, err = PageList.pin_range(list, 0, 1, 0)
        assert_rejected(lease, err)
        assert(err:find("changed during resident restore", 1, true), err)
        assert_handle_metatable(list, metatable, index)
        H.eq(list:inspect_page(0), page_before)
        H.eq(list:pin_stats(), pins_before)
        assert_cache(list, 1, bytes)
        H.eq(PageList.validate(list), true)

        state.on_decode = nil
        state.on_crc32 = nil
        lease = assert(list:pin_range(0, 1, 0))
        H.eq(list:pinned_row(lease, 0), row)
        H.eq(list:release_pin(lease), true)
        H.eq(PageList.validate(list), true)
      end
    end
  end

T["page_cache_ restore callbacks restore raw opaque owner entries"] =
  function()
    for _, phase in ipairs({ "decode", "crc32" }) do
      local row = "owner-entries-owner-entries"
      local bytes = expected_view_bytes(row)
      local list, state = cold_fixture({ row }, {
        max_pages = 1,
        max_bytes = bytes,
      })
      local decoys = seed_handle_decoys(list)
      local page_before = assert(list:inspect_page(0))
      local pins_before = list:pin_stats()
      local function corrupt()
        local mode = phase == "decode" and "delete" or "replace"
        corrupt_handle_entries(list, mode, mode)
      end
      if phase == "decode" then
        state.on_decode = function(_, _, body)
          corrupt()
          return body
        end
      else
        state.on_crc32 = function(body)
          corrupt()
          return test_crc32(body)
        end
      end

      local lease, err = PageList.pin_range(list, 0, 1, 0)
      assert_rejected(lease, err)
      assert(err:find("changed during resident restore", 1, true), err)
      assert_handle_decoys(list, decoys)
      H.eq(list:inspect_page(0), page_before)
      H.eq(list:pin_stats(), pins_before)
      assert_cache(list, 1, bytes)
      H.eq(PageList.validate(list), true)

      state.on_decode = nil
      state.on_crc32 = nil
      lease = assert(list:pin_range(0, 1, 0))
      H.eq(list:pinned_row(lease, 0), row)
      H.eq(list:release_pin(lease), true)
      assert_handle_decoys(list, decoys)
      H.eq(PageList.validate(list), true)
    end
  end

T["page_cache_ callback target graph mutation cancels without quarantine"] =
  function()
    for _, phase in ipairs({ "decode", "crc32" }) do
      local rows = {
        "mutation-target-mutation-target",
        "mutation-neighbor-mutation-neighbor",
      }
      local bytes =
        expected_view_bytes(rows[1]) + expected_view_bytes(rows[2])
      local Isolated, claims = isolated_pagelist_with_claims()
      local list, state = cold_fixture(rows, {
        max_pages = 2,
        max_bytes = bytes,
      }, Isolated)
      local node = assert(claims[1]).node
      local page = assert(claims[1]).page
      local mutate = true
      local function mutate_target()
        if not mutate then
          return
        end
        node.evil = true
        page.evil = true
        page.payload = "forged"
        node.page = Page.new({ "forged" }, { max_rows = 1 })
        setmetatable(node, {})
        setmetatable(page, {})
        _G.error = function()
          return nil
        end
      end
      if phase == "decode" then
        state.on_decode = function(_, _, body)
          mutate_target()
          return body
        end
      else
        state.on_crc32 = function(body)
          mutate_target()
          return test_crc32(body)
        end
      end

      local original_error = _G.error
      local called, lease, err =
        pcall(list.pin_range, list, 0, 1, 0)
      _G.error = original_error
      assert(called, lease)
      assert_rejected(lease, err)
      assert(err:find("changed during resident restore", 1, true), err)
      H.eq(rawget(node, "evil"), nil)
      H.eq(rawget(page, "evil"), nil)
      assert(node.page == page)
      H.eq(getmetatable(node), nil)
      H.eq(getmetatable(page), Page)
      H.eq(Page.metadata(page).quarantined, false)
      if phase == "decode" then
        H.eq(state.crc_calls, 0,
          "decode mutation cancellation must stop before CRC")
      else
        H.eq(state.crc_calls, 1)
      end
      assert_cache(list, 2, bytes)
      H.eq(Isolated.validate(list), true)

      mutate = false
      state.on_decode = nil
      state.on_crc32 = nil
      lease = assert(list:pin_range(0, 1, 0))
      H.eq(list:pinned_row(lease, 0), rows[1])
      H.eq(list:release_pin(lease), true)
      H.eq(Isolated.validate(list), true)
    end
  end

T["page_cache_ partial splice reads a compacted boundary page"] =
  function()
    for _, warm in ipairs({ false, true }) do
      local rows = {
        "splice-a-splice-a",
        "splice-b-splice-b",
        "splice-c-splice-c",
        "splice-d-splice-d",
      }
      local state = new_adapter_state()
      local max_bytes = 1024
      local list = PageList.new(rows, {
        max_rows = 4,
        resident = {
          max_pages = 1,
          max_bytes = max_bytes,
          restore = state.adapter,
        },
      })
      H.eq(list:page_count(), 1)
      assert(list:compact_page(0, 0))
      state.decode_calls = {}
      state.crc_calls = 0
      state.ready = true

      if warm then
        local lease = assert(list:pin_range(0, #rows, 0))
        H.eq(list:release_pin(lease), true)
      end
      H.eq(list:splice(1, 1, { "replacement" }), true)
      H.eq(decode_count(state, 1), 1, warm and "hit" or "miss")
      H.eq(list:rows(0, 4), {
        rows[1],
        "replacement",
        rows[3],
        rows[4],
      })
      H.eq(list:generation(), 1)
      assert_cache(list, 1, max_bytes)
      H.eq(PageList.validate(list), true)
    end

    -- The two retained fragments may belong to different cold Pages. They
    -- must be read and released sequentially so a one-page cache is enough.
    local rows = {
      "first-a-first-a",
      "first-b-first-b",
      "middle-a-middle-a",
      "middle-b-middle-b",
      "last-a-last-a",
      "last-b-last-b",
    }
    local state = new_adapter_state()
    local list = PageList.new(rows, {
      max_rows = 2,
      resident = {
        max_pages = 1,
        max_bytes = 1024,
        restore = state.adapter,
      },
    })
    H.eq(list:page_count(), 3)
    for page_index0 = 0, 2 do
      assert(list:compact_page(page_index0, 0))
    end
    state.decode_calls = {}
    state.crc_calls = 0
    state.ready = true
    H.eq(list:splice(1, 4, { "replacement" }), true)
    H.eq(list:rows(0, 3), {
      rows[1],
      "replacement",
      rows[6],
    })
    H.eq({
      decode_count(state, 1),
      decode_count(state, 2),
      decode_count(state, 3),
    }, { 1, 0, 1 })
    assert_cache(list, 1, 1024)
    H.eq(PageList.validate(list), true)
  end

T["page_cache_ splice boundary restore reentry cancels outer mutation"] =
  function()
    local rows = {
      "outer-a-outer-a",
      "outer-b-outer-b",
      "outer-c-outer-c",
    }
    local state = new_adapter_state()
    local list = PageList.new(rows, {
      max_rows = 3,
      resident = {
        max_pages = 1,
        max_bytes = 1024,
        restore = state.adapter,
      },
    })
    assert(list:compact_page(0, 0))
    state.decode_calls = {}
    state.crc_calls = 0
    state.ready = true
    local nested
    state.on_decode = function(_, _, body)
      nested = { list:splice(0, 0, { "nested" }) }
      return body
    end

    local changed, err = list:splice(1, 1, { "replacement" })
    assert_rejected(changed, err)
    assert(err:find("changed during resident restore", 1, true), err)
    assert_rejected(nested[1], nested[2])
    assert(
      nested[2]:find("resident restore is already active", 1, true),
      nested[2]
    )
    H.eq(state.crc_calls, 0)
    H.eq(assert(list:inspect_page(0)).quarantined, false)
    H.eq(list:generation(), 0)
    assert_cache(list, 1, 1024)
    H.eq(PageList.validate(list), true)

    state.on_decode = nil
    H.eq(list:splice(1, 1, { "replacement" }), true)
    H.eq(list:rows(0, 3), {
      rows[1],
      "replacement",
      rows[3],
    })
    H.eq(PageList.validate(list), true)
  end

return T
