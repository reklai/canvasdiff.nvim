local H = require("helpers")
local PageList = require("canvasdiff.canvas.PageList")
local Projection = require("canvasdiff.canvas.Projection")
local canvas = require("canvasdiff.canvas")

local T = {}

local API = vim.api

local function checksum(body)
  local sum = 0
  for index = 1, #body do
    sum = (sum + body:byte(index) * index) % 4294967296
  end
  return sum
end

local function assert_rejected(value, err, pattern)
  H.eq(value, nil)
  assert(type(err) == "string" and err ~= "", tostring(err))
  if pattern then
    assert(err:find(pattern, 1, true), err)
  end
end

local function assert_call_rejected(pattern, callback)
  local called, value, err = pcall(callback)
  assert(called, value)
  assert_rejected(value, err, pattern)
end

local function assert_no_leases(list)
  local stats = assert(list:pin_stats())
  H.eq(stats.active_leases, 0)
  H.eq(stats.pin_references, 0)
  H.eq(stats.current_pinned_pages, 0)
  H.eq(stats.retired_pinned_pages, 0)
end

local function assert_no_persistent_marks(projection)
  local buffer = assert(projection:buffer())
  H.eq(API.nvim_buf_get_extmarks(
    buffer,
    Projection.NAMESPACE,
    0,
    -1,
    {}
  ), {})
end

local function configure_window(window)
  local options = {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    wrap = false,
    list = false,
    scrolloff = 0,
  }
  for name, value in pairs(options) do
    API.nvim_set_option_value(name, value, { win = window })
  end
  pcall(API.nvim_set_option_value, "statuscolumn", "", { win = window })
end

local function screen_prefix(window, visual_row0, count)
  local position = API.nvim_win_get_position(window)
  local row1 = position[1] + visual_row0 + 1
  local column1 = position[2] + 1
  local cells = {}
  for offset = 0, count - 1 do
    cells[#cells + 1] =
      vim.fn.screenstring(row1, column1 + offset)
  end
  return table.concat(cells)
end

local function window_topline(window)
  return API.nvim_win_call(window, function()
    return vim.fn.line("w0")
  end)
end

local function put_at_top(window, line1)
  API.nvim_win_set_cursor(window, { line1, 0 })
  API.nvim_win_call(window, function()
    vim.cmd("normal! zt")
  end)
end

local function with_clean_tab(callback)
  local original_tab = API.nvim_get_current_tabpage()
  local old_laststatus = vim.o.laststatus
  local old_showtabline = vim.o.showtabline
  local old_ruler = vim.o.ruler
  local old_showcmd = vim.o.showcmd

  vim.cmd("tabnew")
  local test_tab = API.nvim_get_current_tabpage()
  vim.o.laststatus = 0
  vim.o.showtabline = 0
  vim.o.ruler = false
  vim.o.showcmd = false
  configure_window(API.nvim_get_current_win())

  local ok, result = xpcall(callback, debug.traceback)

  if API.nvim_tabpage_is_valid(test_tab) then
    pcall(API.nvim_set_current_tabpage, test_tab)
    pcall(vim.cmd, "tabclose!")
  end
  if API.nvim_tabpage_is_valid(original_tab) then
    pcall(API.nvim_set_current_tabpage, original_tab)
  end
  vim.o.laststatus = old_laststatus
  vim.o.showtabline = old_showtabline
  vim.o.ruler = old_ruler
  vim.o.showcmd = old_showcmd

  if not ok then
    error(result, 0)
  end
  return result
end

local function show_projection(projection, line1)
  local buffer = assert(projection:buffer())
  API.nvim_set_current_buf(buffer)
  local window = API.nvim_get_current_win()
  configure_window(window)
  put_at_top(window, line1 or 1)
  assert(projection:redraw())
  return window
end

local function adapter_fixture()
  local state = {
    bodies = {},
    decode_calls = {},
    next_block = 0,
  }
  state.adapter = {
    codec = "projection-test-v1",
    encode = function(body)
      state.next_block = state.next_block + 1
      local block = tostring(state.next_block)
      state.bodies[block] = body
      return block
    end,
    decode = function(block, expected_bytes)
      state.decode_calls[block] =
        (state.decode_calls[block] or 0) + 1
      if state.on_decode then
        return state.on_decode(
          block,
          expected_bytes,
          state.bodies[block]
        )
      end
      return state.bodies[block]
    end,
    crc32 = checksum,
  }
  return state
end

local function count_calls(calls)
  local count = 0
  for _, calls_for_block in pairs(calls) do
    count = count + calls_for_block
  end
  return count
end

local function compact_all(list)
  local generation = list:generation()
  for page_index0 = 0, list:page_count() - 1 do
    local compacted, err =
      list:compact_page(page_index0, generation)
    assert(compacted, err)
  end
end

T["projection_ cold viewport restores only a bounded range and cache hits"] =
  function()
    with_clean_tab(function()
      local height = API.nvim_win_get_height(0)
      local row_count = height * 4 + 31
      local rows = {}
      for index = 1, row_count do
        rows[index] = ("cold-%04d"):format(index)
      end

      local fixture = adapter_fixture()
      local list = PageList.new(rows, {
        max_rows = 1,
        resident = {
          max_pages = row_count,
          max_bytes = 1024 * 1024,
          restore = fixture.adapter,
        },
      })
      compact_all(list)
      fixture.decode_calls = {}

      local projection = Projection.new(list, {
        overscan_rows = 3,
        skeleton_chunk_rows = 7,
      })
      local window = show_projection(projection)
      local top1 = window_topline(window)
      H.eq(
        screen_prefix(window, 0, #rows[top1]),
        rows[top1]
      )

      local first_calls = count_calls(fixture.decode_calls)
      local resident = assert(list:resident_stats())
      H.eq(first_calls, math.min(row_count, height + 3),
        "top viewport must pin only visible rows plus lower overscan")
      H.eq(resident.pages, first_calls)
      H.eq(fixture.decode_calls[tostring(row_count)], nil)
      H.eq(resident.pinned_pages, 0)
      H.eq(resident.reserved_pages, 0)
      H.eq(resident.reserved_bytes, 0)
      assert_no_leases(list)
      assert_no_persistent_marks(projection)

      assert(projection:redraw())
      H.eq(count_calls(fixture.decode_calls), first_calls)

      local target = math.min(row_count, height * 2 + 7)
      put_at_top(window, target)
      assert(projection:redraw())
      local new_top1 = window_topline(window)
      H.eq(
        screen_prefix(window, 0, #rows[new_top1]),
        rows[new_top1]
      )
      assert(count_calls(fixture.decode_calls) > first_calls)
      H.eq(fixture.decode_calls[tostring(row_count)], nil)
      assert_no_leases(list)
      assert_no_persistent_marks(projection)
      H.eq(projection:validate(), true)
      H.eq(PageList.validate(list), true)
      assert(projection:dispose())
    end)
  end

T["projection_ empty text keeps one blank native skeleton row"] = function()
  with_clean_tab(function()
    local list = PageList.new({})
    local projection = assert(canvas.project(list, {
      overscan_rows = 0,
      skeleton_chunk_rows = 1,
    }))
    local buffer = assert(projection:buffer())
    H.eq(API.nvim_buf_line_count(buffer), 1)
    H.eq(API.nvim_buf_get_lines(buffer, 0, -1, true), { "" })
    H.eq(projection:row_count(), 0)
    H.eq(projection:rows(0, 0), {})
    H.eq(projection:export(0, 0), "")
    H.eq(
      projection:export(0, 0, {
        separator = "\0",
        terminal_eol = true,
      }),
      ""
    )

    local window = show_projection(projection)
    H.eq(screen_prefix(window, 0, 1), " ")
    assert_no_leases(list)
    assert_no_persistent_marks(projection)
    H.eq(projection:validate(), true)
    assert(projection:dispose())
  end)
end

T["projection_ invalid construction and export options are ordinary errors"] =
  function()
    local list = PageList.new({ "a", "b" })
    for _, case in ipairs({
      false,
      { overscan_rows = -1 },
      { overscan_rows = 0.5 },
      { overscan_rows = math.huge },
      { overscan_rows = 65537 },
      { skeleton_chunk_rows = 0 },
      { skeleton_chunk_rows = 1.5 },
      { skeleton_chunk_rows = math.huge },
      { skeleton_chunk_rows = 65537 },
    }) do
      assert_rejected(Projection.create(list, case))
    end
    assert_call_rejected("projection text is invalid", function()
      return Projection.create(false)
    end)

    local projection = Projection.new(list)
    assert_call_rejected("export options", function()
      return projection:export(0, 1, false)
    end)
    assert_call_rejected("separator", function()
      return projection:export(0, 1, { separator = false })
    end)
    assert_call_rejected("terminal_eol", function()
      return projection:export(0, 1, { terminal_eol = "yes" })
    end)
    assert_rejected(projection:export(1, 2))
    assert_call_rejected("delete_buffer", function()
      return projection:dispose("yes")
    end)
    H.eq(projection:validate(), true)
    assert(projection:dispose())
  end

T["projection_ logical access and export preserve exact bytes"] = function()
  local rows = {
    "alpha",
    "",
    "two\0bytes",
    "trailing ",
  }
  local list = PageList.new(rows, {
    max_rows = 2,
    max_bytes = 32,
  })
  local projection = Projection.new(list, {
    skeleton_chunk_rows = 1,
  })
  local buffer = assert(projection:buffer())

  H.eq(API.nvim_buf_line_count(buffer), #rows)
  H.eq(
    API.nvim_buf_get_lines(buffer, 0, -1, true),
    { "", "", "", "" }
  )
  H.eq(
    API.nvim_get_option_value("buftype", { buf = buffer }),
    "nofile"
  )
  H.eq(
    API.nvim_get_option_value("modifiable", { buf = buffer }),
    false
  )
  H.eq(projection:row_count(), #rows)
  H.eq(projection:row(2), rows[3])
  H.eq(projection:rows(1, 2), { rows[2], rows[3] })
  H.eq(projection:export(0, #rows), table.concat(rows, "\n"))
  H.eq(
    projection:export(1, 2, {
      separator = "\0",
      terminal_eol = true,
    }),
    "\0two\0bytes\0"
  )
  assert_no_persistent_marks(projection)
  H.eq(projection:validate(), true)
  assert(projection:dispose())
  H.eq(API.nvim_buf_is_valid(buffer), false)

  assert_call_rejected("disposed", function()
    return projection:buffer()
  end)
  assert_call_rejected("disposed", function()
    return projection:row_count()
  end)
  assert_call_rejected("disposed", function()
    return projection:row(0)
  end)
  assert_call_rejected("disposed", function()
    return projection:rows(0, 0)
  end)
  assert_call_rejected("disposed", function()
    return projection:export(0, 0)
  end)
  assert_call_rejected("disposed", function()
    return projection:redraw()
  end)
  H.eq(projection:validate(), true)
end

T["projection_ native skeleton poisoning is detected scrubbed and recovered"] =
  function()
    with_clean_tab(function()
      local logical = {
        "logical-a",
        "logical-b",
        "logical-c",
      }
      local list = PageList.new(logical, { max_rows = 2 })
      local projection = Projection.new(list, {
        skeleton_chunk_rows = 1,
      })
      local buffer = assert(projection:buffer())

      API.nvim_set_option_value(
        "modifiable",
        true,
        { buf = buffer }
      )
      API.nvim_buf_set_lines(
        buffer,
        1,
        2,
        false,
        { "persistent-native-poison" }
      )
      API.nvim_set_option_value(
        "modifiable",
        false,
        { buf = buffer }
      )
      H.eq(API.nvim_buf_line_count(buffer), #logical)
      H.eq(
        API.nvim_buf_get_lines(buffer, 0, -1, true),
        { "", "persistent-native-poison", "" }
      )
      assert_rejected(projection:validate())
      H.eq(projection:rows(0, #logical), logical)
      H.eq(projection:export(0, #logical), table.concat(logical, "\n"))

      H.eq(projection:refresh(), true)
      H.eq(
        API.nvim_buf_get_lines(buffer, 0, -1, true),
        { "", "", "" }
      )
      H.eq(projection:rows(0, #logical), logical)
      H.eq(projection:validate(), true)

      local window = show_projection(projection)
      H.eq(
        screen_prefix(window, 0, #logical[1]),
        logical[1]
      )
      assert_no_persistent_marks(projection)
      assert_no_leases(list)
      H.eq(PageList.validate(list), true)
      assert(projection:dispose())
    end)
  end

T["projection_ multiple overlapping windows render independently"] =
  function()
    with_clean_tab(function()
      local rows = {}
      for index = 1, 160 do
        rows[index] = ("logical-%03d"):format(index)
      end
      local list = PageList.new(rows, { max_rows = 5 })
      local projection = Projection.new(list, {
        overscan_rows = 4,
      })
      local buffer = assert(projection:buffer())
      API.nvim_set_current_buf(buffer)
      local first = API.nvim_get_current_win()
      vim.cmd("vsplit")
      local second = API.nvim_get_current_win()
      API.nvim_win_set_buf(second, buffer)
      configure_window(first)
      configure_window(second)
      local height = API.nvim_win_get_height(first)
      put_at_top(first, 1)
      put_at_top(second, math.max(2, math.floor(height / 2)))

      assert(projection:redraw())
      local first_top1 = window_topline(first)
      local second_top1 = window_topline(second)
      H.eq(
        screen_prefix(first, 0, #rows[first_top1]),
        rows[first_top1]
      )
      H.eq(
        screen_prefix(second, 0, #rows[second_top1]),
        rows[second_top1]
      )
      assert(first_top1 < second_top1)
      assert(
        second_top1 < first_top1 + height,
        "the two window viewports must overlap"
      )
      H.eq(projection:stats().active_leases, 0)
      assert_no_leases(list)
      assert_no_persistent_marks(projection)
      H.eq(projection:validate(), true)
      assert(projection:dispose())
    end)
  end

T["projection_ restore reentry is contained and a forced redraw recovers"] =
  function()
    with_clean_tab(function()
      local fixture = adapter_fixture()
      local list
      local nested
      fixture.on_decode = function(_, _, body)
        local lease, err =
          list:pin_range(0, 1, list:generation())
        nested = { lease, err }
        return body
      end
      list = PageList.new({ "recover-after-reentry" }, {
        max_rows = 1,
        resident = {
          max_pages = 1,
          max_bytes = 128,
          restore = fixture.adapter,
        },
      })
      compact_all(list)

      local projection = Projection.new(list, { overscan_rows = 0 })
      local buffer = assert(projection:buffer())
      API.nvim_set_current_buf(buffer)
      local window = API.nvim_get_current_win()
      configure_window(window)
      put_at_top(window, 1)
      assert(projection:redraw())

      assert(nested)
      assert_rejected(
        nested[1],
        nested[2],
        "resident restore is already active"
      )
      local diagnostic = projection:last_error()
      assert(type(diagnostic) == "string" and diagnostic ~= "")
      assert(
        diagnostic:find("changed during resident restore", 1, true),
        diagnostic
      )
      assert(#diagnostic <= 512)
      H.eq(assert(list:inspect_page(0)).quarantined, false)
      local resident = assert(list:resident_stats())
      H.eq(resident.pages, 0)
      H.eq(resident.reserved_pages, 0)
      H.eq(resident.reserved_bytes, 0)
      assert_no_leases(list)
      assert_no_persistent_marks(projection)

      fixture.on_decode = nil
      assert(projection:redraw())
      H.eq(
        screen_prefix(window, 0, #"recover-after-reentry"),
        "recover-after-reentry"
      )
      H.eq(projection:last_error(), nil)
      resident = assert(list:resident_stats())
      H.eq(resident.pages, 1)
      H.eq(resident.pinned_pages, 0)
      H.eq(resident.reserved_pages, 0)
      assert_no_leases(list)
      H.eq(projection:validate(), true)
      H.eq(PageList.validate(list), true)
      assert(projection:dispose())
    end)
  end

T["projection_ splice growth shrink and empty transitions refresh skeleton"] =
  function()
    with_clean_tab(function()
      local list = PageList.new({
        "before-a",
        "before-b",
        "before-c",
      }, {
        max_rows = 2,
      })
      local projection = Projection.new(list, {
        overscan_rows = 0,
        skeleton_chunk_rows = 2,
      })
      local buffer = assert(projection:buffer())
      local window = show_projection(projection)
      H.eq(screen_prefix(window, 0, #"before-a"), "before-a")

      assert(list:splice(0, 1, { "same-count" }))
      H.eq(list:generation(), 1)
      assert_call_rejected("not synchronized", function()
        return projection:validate()
      end)
      local stale = projection:stats()
      H.eq(stale.projected_generation, 0)
      H.eq(stale.source_generation, 1)
      H.eq(stale.skeleton_rows, 3)
      assert(projection:redraw())
      H.eq(screen_prefix(window, 0, #"same-count"), "same-count")
      H.eq(API.nvim_buf_line_count(buffer), 3)

      assert(list:splice(1, 0, {
        "grown-1",
        "grown-2",
        "grown-3",
      }))
      H.eq(list:generation(), 2)
      assert_call_rejected("not synchronized", function()
        return projection:validate()
      end)
      stale = projection:stats()
      H.eq(stale.logical_rows, 6)
      H.eq(stale.skeleton_rows, 3)
      H.eq(projection:refresh(), true)
      H.eq(API.nvim_buf_line_count(buffer), 6)
      H.eq(projection:stats().logical_rows, 6)
      H.eq(projection:stats().skeleton_rows, 6)
      H.eq(projection:validate(), true)
      assert(projection:redraw())

      assert(list:splice(0, 6, {}))
      H.eq(list:generation(), 3)
      assert_call_rejected("not synchronized", function()
        return projection:validate()
      end)
      stale = projection:stats()
      H.eq(stale.logical_rows, 0)
      H.eq(stale.skeleton_rows, 6)
      assert(projection:redraw())
      H.eq(API.nvim_buf_line_count(buffer), 1)
      H.eq(projection:stats().logical_rows, 0)
      H.eq(projection:stats().skeleton_rows, 1)
      H.eq(projection:validate(), true)

      assert(list:splice(0, 0, { "reborn-a", "reborn-b" }))
      H.eq(list:generation(), 4)
      assert_call_rejected("not synchronized", function()
        return projection:validate()
      end)
      stale = projection:stats()
      H.eq(stale.logical_rows, 2)
      H.eq(stale.skeleton_rows, 1)
      assert(projection:redraw())
      H.eq(API.nvim_buf_line_count(buffer), 2)
      H.eq(screen_prefix(window, 0, #"reborn-a"), "reborn-a")
      H.eq(projection:rows(0, 2), { "reborn-a", "reborn-b" })
      H.eq(projection:stats().logical_rows, 2)
      H.eq(projection:stats().skeleton_rows, 2)
      assert_no_leases(list)
      assert_no_persistent_marks(projection)
      H.eq(projection:validate(), true)
      H.eq(PageList.validate(list), true)
      assert(projection:dispose())
    end)
  end

T["projection_ wipe and explicit disposal release every resource"] =
  function()
    with_clean_tab(function()
      local list = PageList.new({ "wipe-a", "wipe-b" }, {
        max_rows = 1,
      })
      local projection = Projection.new(list)
      local buffer = assert(projection:buffer())
      show_projection(projection)
      assert_no_leases(list)
      API.nvim_buf_delete(buffer, { force = true })

      local stats = projection:stats()
      H.eq(stats.disposed, true)
      H.eq(stats.finalized, true)
      H.eq(stats.active_leases, 0)
      assert_no_leases(list)
      assert_call_rejected("disposed", function()
        return projection:buffer()
      end)
      assert_call_rejected("disposed", function()
        return projection:redraw()
      end)
      H.eq(projection:validate(), true)
      H.eq(projection:dispose(), true)

      local retained_list = PageList.new({ "retained" })
      local retained = Projection.new(retained_list)
      local retained_buffer = assert(retained:buffer())
      H.eq(retained:dispose(false), true)
      H.eq(API.nvim_buf_is_valid(retained_buffer), true)
      H.eq(retained:stats().disposed, true)
      H.eq(retained:stats().finalized, true)
      H.eq(retained:validate(), true)
      assert_no_leases(retained_list)
      API.nvim_buf_delete(retained_buffer, { force = true })
    end)
  end

-- Like the zz case below, this replaces the extmark primitive and reloads the
-- module so the wrapper is the one the provider captured -- the only way to
-- observe an EPHEMERAL mark's options, which nvim_buf_get_extmarks never
-- reports. Sorted after every ordinary case for the same reason zz is last:
-- the isolated provider must not affect them; the cleanup path reinstalls a
-- fresh canonical provider.
T["projection_ z decorator prefix_hl splits the overlay into two chunks"] =
  function()
    local module_name = "canvasdiff.canvas.Projection"
    local original_set_extmark = API.nvim_buf_set_extmark
    local seen = {}
    API.nvim_buf_set_extmark = function(...)
      local arguments = { ... }
      seen[#seen + 1] = { row0 = arguments[3], options = arguments[5] }
      return original_set_extmark(...)
    end
    package.loaded[module_name] = nil
    local isolated_projection = require(module_name)
    local projection
    local ok, failure = xpcall(function()
      with_clean_tab(function()
        local rows = {}
        for index = 1, 40 do
          rows[index] = ("+row-%03d"):format(index)
        end
        -- An added blank line: the row is the prefix glyph alone. Its margin
        -- hue must survive, matching the eager canvas.
        rows[2] = "+"
        local list = PageList.new(rows, { max_rows = 8 })
        projection = isolated_projection.new(list, {
          overscan_rows = 0,
          decorate = function(row0)
            if row0 == 0 then
              return {
                hl_group = "CanvasDiffAdd",
                prefix_hl = "CanvasDiffPrefixAdd",
                prefix_len = 1,
              }
            end
            if row0 == 1 then
              return {
                hl_group = "CanvasDiffAdd",
                prefix_hl = "CanvasDiffPrefixAdd",
                prefix_len = 1,
              }
            end
            -- Contained per row: a length that cannot address this row's
            -- bytes (past the text, or not an integer) must degrade to the
            -- plain single-chunk overlay, never throw or truncate.
            if row0 == 2 then
              return {
                hl_group = "CanvasDiffAdd",
                prefix_hl = "CanvasDiffPrefixAdd",
                prefix_len = #rows[3] + 1,
              }
            end
            if row0 == 3 then
              return {
                hl_group = "CanvasDiffAdd",
                prefix_hl = "CanvasDiffPrefixAdd",
                prefix_len = 1.5,
              }
            end
            return nil
          end,
        })
        local buffer = assert(projection:buffer())
        API.nvim_set_current_buf(buffer)
        local window = API.nvim_get_current_win()
        configure_window(window)
        put_at_top(window, 1)
        seen = {}
        assert(projection:redraw())

        local overlays = {}
        for _, mark in ipairs(seen) do
          if mark.options.ephemeral and mark.options.virt_text then
            overlays[mark.row0] = mark.options.virt_text
          end
        end
        H.eq(overlays[0], {
          { "+", "CanvasDiffPrefixAdd" },
          { "row-001", "CanvasDiffAdd" },
        }, "a valid prefix_len splits the drawn overlay at the byte boundary")
        H.eq(overlays[1], {
          { "+", "CanvasDiffPrefixAdd" },
          { "", "CanvasDiffAdd" },
        }, "a prefix-only row keeps the margin hue; its tail chunk is empty")
        H.eq(overlays[2], { { rows[3], "CanvasDiffAdd" } },
          "a prefix_len past the text falls back to one chunk")
        H.eq(overlays[3], { { rows[4], "CanvasDiffAdd" } },
          "a fractional prefix_len falls back to one chunk")
        H.eq(overlays[4], { { rows[5], "Normal" } },
          "an undecorated row keeps the plain single-chunk overlay")

        assert_no_persistent_marks(projection)
        H.eq(projection:validate(), true)
      end)
    end, debug.traceback)

    if projection then
      pcall(isolated_projection.dispose, projection)
    end
    API.nvim_buf_set_extmark = original_set_extmark
    package.loaded[module_name] = nil
    local restored_projection = require(module_name)
    local sentinel = restored_projection.new(PageList.new({}))
    assert(sentinel:dispose())

    if not ok then
      error(failure, 0)
    end
  end

-- This case deliberately replaces the provider's captured extmark primitive.
-- It is sorted last so the isolated provider cannot affect earlier cases. A
-- fresh canonical Projection provider is installed in the cleanup path.
T["projection_ zz provider faults and mid-cycle splice never leak leases"] =
  function()
    local module_name = "canvasdiff.canvas.Projection"
    local page_list_name = "canvasdiff.canvas.PageList"
    local canonical_page_list = package.loaded[page_list_name]
    local original_set_extmark = API.nvim_buf_set_extmark
    local original_set_lines = API.nvim_buf_set_lines
    local original_delete_buffer = API.nvim_buf_delete
    local original_schedule = vim.schedule
    local fault_mode
    local fault_list
    local fault_projection
    local refresh_from_provider
    local delete_from_provider
    local dispose_from_provider
    local spliced = false
    local seen_options = {}
    local observing_provider = false
    local forbidden_provider_calls = {}

    API.nvim_buf_set_lines = function(...)
      if observing_provider then
        forbidden_provider_calls[#forbidden_provider_calls + 1] =
          "nvim_buf_set_lines"
      end
      return original_set_lines(...)
    end
    API.nvim_buf_delete = function(...)
      if observing_provider then
        forbidden_provider_calls[#forbidden_provider_calls + 1] =
          "nvim_buf_delete"
      end
      return original_delete_buffer(...)
    end
    vim.schedule = function(...)
      if observing_provider then
        forbidden_provider_calls[#forbidden_provider_calls + 1] =
          "vim.schedule"
      end
      return original_schedule(...)
    end

    API.nvim_buf_set_extmark = function(...)
      local arguments = { ... }
      local options = arguments[5]
      seen_options[#seen_options + 1] = options
      if fault_mode == "splice" and not spliced then
        spliced = true
        local changed, err =
          fault_list:splice(0, 1, { "mid-cycle-new" })
        assert(changed, err)
        refresh_from_provider = {
          fault_projection:refresh(),
        }
      elseif fault_mode == "throw" then
        error(string.rep("provider-extmark-fault-", 80), 0)
      elseif fault_mode == "dispose" and not dispose_from_provider then
        delete_from_provider = {
          fault_projection:dispose(),
        }
        dispose_from_provider = {
          fault_projection:dispose(false),
        }
      end
      return original_set_extmark(...)
    end

    package.loaded[module_name] = nil
    local isolated_projection = require(module_name)
    local projection
    local ok, failure = xpcall(function()
      with_clean_tab(function()
        fault_list = PageList.new({
          "mid-cycle-old",
          "stable-b",
          "stable-c",
        }, {
          max_rows = 1,
        })
        projection = isolated_projection.new(fault_list, {
          overscan_rows = 0,
        })
        fault_projection = projection
        local buffer = assert(projection:buffer())
        API.nvim_set_current_buf(buffer)
        local window = API.nvim_get_current_win()
        configure_window(window)
        put_at_top(window, 1)

        fault_mode = "splice"
        observing_provider = true
        assert(projection:redraw())
        observing_provider = false
        H.eq(fault_list:generation(), 1)
        assert_rejected(
          refresh_from_provider[1],
          refresh_from_provider[2],
          "provider callback"
        )
        assert_no_leases(fault_list)
        H.eq(PageList.validate(fault_list), true)
        local pending = projection:stats()
        H.eq(pending.projected_generation, 0)
        H.eq(pending.source_generation, 1)
        H.eq(pending.needs_sync, true)
        assert_call_rejected("not synchronized", function()
          return projection:validate()
        end)
        assert(#seen_options > 0)
        for _, options in ipairs(seen_options) do
          H.eq(options.ephemeral, true)
        end
        H.eq(API.nvim_buf_get_extmarks(
          buffer,
          isolated_projection.NAMESPACE,
          0,
          -1,
          {}
        ), {})

        fault_mode = nil
        seen_options = {}
        assert(projection:redraw())
        H.eq(projection:validate(), true)
        H.eq(
          screen_prefix(window, 0, #"mid-cycle-new"),
          "mid-cycle-new"
        )
        H.eq(projection:last_error(), nil)
        assert_no_leases(fault_list)

        fault_mode = "throw"
        observing_provider = true
        assert(projection:redraw())
        observing_provider = false
        local diagnostic = projection:last_error()
        assert(type(diagnostic) == "string" and diagnostic ~= "")
        assert(
          diagnostic:find("projection on_range threw", 1, true),
          diagnostic
        )
        assert(#diagnostic <= 512)
        assert_no_leases(fault_list)
        H.eq(API.nvim_buf_get_extmarks(
          buffer,
          isolated_projection.NAMESPACE,
          0,
          -1,
          {}
        ), {})

        fault_mode = nil
        assert(projection:redraw())
        H.eq(
          screen_prefix(window, 0, #"mid-cycle-new"),
          "mid-cycle-new"
        )
        H.eq(projection:last_error(), nil)
        assert_no_leases(fault_list)
        H.eq(projection:validate(), true)
        assert(projection:dispose())
        projection = nil

        local dispose_list = PageList.new({
          "dispose-during-provider-a",
          "dispose-during-provider-b",
        }, {
          max_rows = 1,
        })
        projection = isolated_projection.new(dispose_list, {
          overscan_rows = 0,
        })
        fault_projection = projection
        local dispose_buffer = assert(projection:buffer())
        API.nvim_set_current_buf(dispose_buffer)
        window = API.nvim_get_current_win()
        configure_window(window)
        put_at_top(window, 1)
        fault_mode = "dispose"
        observing_provider = true
        local redraw_called, redraw_ok, redraw_err =
          pcall(isolated_projection.redraw, projection)
        observing_provider = false
        assert(redraw_called, redraw_ok)
        if not redraw_ok then
          assert(
            type(redraw_err) == "string" and redraw_err ~= "",
            tostring(redraw_err)
          )
        end
        assert_rejected(
          delete_from_provider[1],
          delete_from_provider[2],
          "provider callback"
        )
        H.eq(dispose_from_provider[1], true)
        H.eq(API.nvim_buf_is_valid(dispose_buffer), true)
        H.eq(projection:stats().disposed, true)
        H.eq(projection:stats().finalized, true)
        assert_no_leases(dispose_list)
        H.eq(PageList.validate(dispose_list), true)
        H.eq(projection:validate(), true)
        H.eq(projection:dispose(), true)
        API.nvim_buf_delete(dispose_buffer, { force = true })
        projection = nil
        H.eq(forbidden_provider_calls, {})
      end)
    end, debug.traceback)

    observing_provider = false
    if projection then
      pcall(isolated_projection.dispose, projection)
    end
    API.nvim_buf_set_extmark = original_set_extmark
    API.nvim_buf_set_lines = original_set_lines
    API.nvim_buf_delete = original_delete_buffer
    vim.schedule = original_schedule
    package.loaded[page_list_name] = canonical_page_list
    package.loaded[module_name] = nil
    local restored_projection = require(module_name)
    local sentinel = restored_projection.new(PageList.new({}))
    assert(sentinel:dispose())

    if not ok then
      error(failure, 0)
    end
  end

T["projection_ the decorator styles visible rows and leaves no marks"] =
  function()
    with_clean_tab(function()
      local rows = {}
      for index = 1, 200 do
        rows[index] = ("logical-%03d"):format(index)
      end
      local list = PageList.new(rows, { max_rows = 8 })

      -- A page-backed canvas has to colour diff rows without persisting a
      -- single extmark, so the decorator is asked per visible row and its
      -- answer is drawn ephemerally. Recording every ask is how we prove the
      -- rows off screen are never asked about at all.
      local asked = {}
      local projection = Projection.new(list, {
        overscan_rows = 2,
        decorate = function(row0, text)
          asked[#asked + 1] = { row0 = row0, text = text }
          if row0 % 2 == 0 then
            return { hl_group = "DiffAdd", line_hl_group = "DiffAdd" }
          end
          return nil
        end,
      })
      local buffer = assert(projection:buffer())
      API.nvim_set_current_buf(buffer)
      local window = API.nvim_get_current_win()
      configure_window(window)
      put_at_top(window, 1)
      assert(projection:redraw())

      assert(#asked > 0, "the decorator was never asked about a visible row")
      local height = API.nvim_win_get_height(window)
      assert(#asked <= height + 2 * 2 + 2, (
        "the decorator was asked about %d rows for a %d-row window"
      ):format(#asked, height))
      for _, ask in ipairs(asked) do
        H.eq(ask.text, rows[ask.row0 + 1],
          ("the decorator saw the wrong text at row %d"):format(ask.row0))
      end

      -- The text still renders, decorated or not.
      H.eq(screen_prefix(window, 0, #rows[1]), rows[1])
      H.eq(screen_prefix(window, 1, #rows[2]), rows[2])

      -- And the two rows genuinely differ on screen: row 0 was styled, row 1
      -- was not. Comparing attributes is what proves the decoration reached
      -- the screen rather than merely being requested.
      local position = API.nvim_win_get_position(window)
      local styled = vim.fn.screenattr(position[1] + 1, position[2] + 1)
      local plain = vim.fn.screenattr(position[1] + 2, position[2] + 1)
      assert(styled ~= plain,
        "a decorated row and an undecorated row rendered identically")

      assert_no_persistent_marks(projection)
      H.eq(projection:validate(), true)
      assert(projection:dispose())
    end)
  end

T["projection_ a decorator that misbehaves costs its row and nothing else"] =
  function()
    with_clean_tab(function()
      local rows = {}
      for index = 1, 120 do
        rows[index] = ("logical-%03d"):format(index)
      end
      local list = PageList.new(rows, { max_rows = 8 })

      -- The decorator is owner code running inside a decoration-provider
      -- callback, where a throw would take down the provider for every
      -- projection in the process. So each row is contained on its own.
      local projection = Projection.new(list, {
        overscan_rows = 1,
        decorate = function(row0)
          if row0 == 0 then
            error("injected decorator failure")
          end
          if row0 == 1 then
            return "not a table"
          end
          return nil
        end,
      })
      local buffer = assert(projection:buffer())
      API.nvim_set_current_buf(buffer)
      local window = API.nvim_get_current_win()
      configure_window(window)
      put_at_top(window, 1)
      assert(projection:redraw())

      -- Both bad rows still show their text.
      H.eq(screen_prefix(window, 0, #rows[1]), rows[1])
      H.eq(screen_prefix(window, 1, #rows[2]), rows[2])
      H.eq(screen_prefix(window, 2, #rows[3]), rows[3])

      local reported = projection:last_error()
      assert(type(reported) == "string" and reported ~= "",
        "a misbehaving decorator was not reported at all")

      assert_no_persistent_marks(projection)
      H.eq(projection:validate(), true)
      assert(projection:dispose())
    end)
  end

T["projection_ a decorator that is not a function is refused"] = function()
  local list = PageList.new({ "one", "two" })
  local projection, err = Projection.create(list, { decorate = "nope" })
  assert_rejected(projection, err, "decorate")
end

return T
