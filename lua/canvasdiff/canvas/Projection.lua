local PageList = require("canvasdiff.canvas.PageList")

local Projection = {}
Projection.__index = Projection
Projection.__metatable = "canvasdiff.canvas.Projection"

local API = vim.api
local CREATE_BUF = API.nvim_create_buf
local CREATE_NAMESPACE = API.nvim_create_namespace
local SET_PROVIDER = API.nvim_set_decoration_provider
local SET_LINES = API.nvim_buf_set_lines
local GET_LINES = API.nvim_buf_get_lines
local SET_EXTMARK = API.nvim_buf_set_extmark
local GET_EXTMARKS = API.nvim_buf_get_extmarks
local ATTACH_BUF = API.nvim_buf_attach
local DELETE_BUF = API.nvim_buf_delete
local BUF_IS_VALID = API.nvim_buf_is_valid
local BUF_LINE_COUNT = API.nvim_buf_line_count
local BUF_CHANGEDTICK = API.nvim_buf_get_changedtick
local BUF_SET_NAME = API.nvim_buf_set_name
local SET_OPTION = API.nvim_set_option_value
local GET_OPTION = API.nvim_get_option_value
local WIN_IS_VALID = API.nvim_win_is_valid
local WIN_GET_BUF = API.nvim_win_get_buf
local REDRAW = API.nvim__redraw
local WINDOW_LAST_LINE = vim.fn.line

local PAGE_LIST_VALIDATE = PageList.validate
local PAGE_LIST_ROW_COUNT = PageList.row_count
local PAGE_LIST_GENERATION = PageList.generation
local PAGE_LIST_ROW = PageList.row
local PAGE_LIST_ROWS = PageList.rows
local PAGE_LIST_PIN_RANGE = PageList.pin_range
local PAGE_LIST_PINNED_ROWS = PageList.pinned_rows
local PAGE_LIST_RELEASE_PIN = PageList.release_pin

local FLOOR = math.floor
local MAX = math.max
local MIN = math.min
local HUGE = math.huge
local NEXT = next
local PAIRS = pairs
local PCALL = pcall
local RAW_EQUAL = rawequal
local RAWGET = rawget
local RAWSET = rawset
local SETMETATABLE = setmetatable
local STRING_SUB = string.sub
local TABLE_CONCAT = table.concat
local TOSTRING = tostring
local TYPE = type

local DEFAULT_OVERSCAN_ROWS = 64
local DEFAULT_SKELETON_CHUNK_ROWS = 8192
local MAX_OVERSCAN_ROWS = 65536
local MAX_SKELETON_CHUNK_ROWS = 65536

local NAMESPACE =
  CREATE_NAMESPACE("canvasdiff.canvas.projection")
local STATES = SETMETATABLE({}, { __mode = "k" })
local BY_BUFFER = {}
local PENDING_DISPOSALS = {}
local provider_installed = false
local provider_depth = 0

local function finite_integer(value)
  return TYPE(value) == "number"
    and value == value
    and value ~= HUGE
    and value ~= -HUGE
    and value >= 0
    and value == FLOOR(value)
end

local function safe_diagnostic(value)
  if TYPE(value) == "string" then
    return value
  end
  local ok, result = PCALL(TOSTRING, value)
  if ok and TYPE(result) == "string" then
    return result
  end
  return "<unprintable error>"
end

local function state_for(self)
  if TYPE(self) ~= "table" then
    return nil, "projection must be a table"
  end
  local state = STATES[self]
  if not state then
    return nil, "projection is not owned by CanvasDiff"
  end
  return state
end

local function record_error(state, message)
  if TYPE(message) ~= "string" then
    message = safe_diagnostic(message)
  end
  if #message > 512 then
    message = STRING_SUB(message, 1, 509) .. "..."
  end
  RAWSET(state, "last_error", message)
  RAWSET(state, "cycle_failed", true)
end

local function blank_rows(count)
  local rows = {}
  for index = 1, count do
    rows[index] = ""
  end
  return rows
end

local function configure_buffer(buffer)
  local options = {
    buftype = "nofile",
    bufhidden = "hide",
    swapfile = false,
    undolevels = -1,
    modifiable = true,
  }
  for name, value in PAIRS(options) do
    SET_OPTION(name, value, { buf = buffer })
  end
end

local function populate_skeleton(buffer, logical_rows, chunk_rows)
  local physical_rows = MAX(1, logical_rows)
  local full_chunk = blank_rows(MIN(chunk_rows, physical_rows))
  SET_LINES(buffer, 0, -1, false, full_chunk)

  local inserted = #full_chunk
  while inserted < physical_rows do
    local count = MIN(chunk_rows, physical_rows - inserted)
    local rows = count == #full_chunk and full_chunk or blank_rows(count)
    SET_LINES(buffer, -1, -1, false, rows)
    inserted = inserted + count
  end
end

local function source_shape(state)
  local text = RAWGET(state, "text")
  local generation = PAGE_LIST_GENERATION(text)
  local logical_rows = PAGE_LIST_ROW_COUNT(text)
  if not finite_integer(generation)
      or not finite_integer(logical_rows) then
    return nil, nil, "projection source shape is invalid"
  end
  return generation, logical_rows
end

local function resize_skeleton(state, logical_rows)
  local buffer = RAWGET(state, "buffer")
  if not BUF_IS_VALID(buffer) then
    return nil, "projection buffer is invalid"
  end
  local target_rows = MAX(1, logical_rows)
  local current_rows = BUF_LINE_COUNT(buffer)
  local current_tick = BUF_CHANGEDTICK(buffer)
  local trusted_tick = RAWGET(state, "skeleton_tick")
  local modifiable =
    GET_OPTION("modifiable", { buf = buffer })
  local scrub = not RAW_EQUAL(current_tick, trusted_tick)
  if current_rows == target_rows
      and not scrub
      and RAW_EQUAL(modifiable, false) then
    return true
  end

  local unlocked, unlock_err =
    PCALL(SET_OPTION, "modifiable", true, { buf = buffer })
  if not unlocked then
    return nil, "could not unlock projection skeleton: "
      .. safe_diagnostic(unlock_err)
  end
  local changed, change_err = PCALL(function()
    if current_rows > target_rows then
      SET_LINES(buffer, target_rows, -1, false, {})
    elseif current_rows < target_rows then
      local chunk_rows = RAWGET(state, "skeleton_chunk_rows")
      local remaining = target_rows - current_rows
      local full_chunk = blank_rows(MIN(chunk_rows, remaining))
      while remaining > 0 do
        local count = MIN(chunk_rows, remaining)
        local rows =
          count == #full_chunk and full_chunk or blank_rows(count)
        SET_LINES(buffer, -1, -1, false, rows)
        remaining = remaining - count
      end
    end
    if scrub then
      local chunk_rows = RAWGET(state, "skeleton_chunk_rows")
      local full_chunk = blank_rows(MIN(chunk_rows, target_rows))
      local start0 = 0
      while start0 < target_rows do
        local count = MIN(chunk_rows, target_rows - start0)
        local rows =
          count == #full_chunk and full_chunk or blank_rows(count)
        SET_LINES(
          buffer,
          start0,
          start0 + count,
          false,
          rows
        )
        start0 = start0 + count
      end
    end
  end)
  local locked, lock_err =
    PCALL(SET_OPTION, "modifiable", false, { buf = buffer })
  if not changed then
    return nil, "could not resize projection skeleton: "
      .. safe_diagnostic(change_err)
  end
  if not locked then
    return nil, "could not lock projection skeleton: "
      .. safe_diagnostic(lock_err)
  end
  if BUF_LINE_COUNT(buffer) ~= target_rows then
    return nil, "projection skeleton resize was incomplete"
  end
  RAWSET(state, "skeleton_tick", BUF_CHANGEDTICK(buffer))
  return true
end

local function validate_blank_skeleton(state, buffer, row_count)
  local before_tick = BUF_CHANGEDTICK(buffer)
  if not RAW_EQUAL(before_tick, RAWGET(state, "skeleton_tick")) then
    return nil, "projection skeleton payload changed"
  end
  local chunk_rows = RAWGET(state, "skeleton_chunk_rows")
  local start0 = 0
  while start0 < row_count do
    local end0 = MIN(row_count, start0 + chunk_rows)
    local rows = GET_LINES(buffer, start0, end0, true)
    if #rows ~= end0 - start0 then
      return nil, "projection skeleton read was incomplete"
    end
    for index = 1, #rows do
      if not RAW_EQUAL(RAWGET(rows, index), "") then
        return nil, "projection skeleton retained native row text"
      end
    end
    start0 = end0
  end
  if not RAW_EQUAL(BUF_CHANGEDTICK(buffer), before_tick) then
    return nil, "projection skeleton changed during validation"
  end
  return true
end

local function lease_error(state, prefix, err)
  local message = prefix .. ": " .. safe_diagnostic(err)
  record_error(state, message)
  return nil, message
end

local function release_entry(state, window)
  local entries = RAWGET(state, "leases")
  local entry = RAWGET(entries, window)
  if not entry then
    return true
  end

  local released, release_err =
    PAGE_LIST_RELEASE_PIN(RAWGET(state, "text"), RAWGET(entry, "lease"))
  if not released then
    return lease_error(state, "could not release projection lease", release_err)
  end
  RAWSET(entries, window, nil)
  return true
end

local function release_all(state)
  local entries = RAWGET(state, "leases")
  local windows = {}
  for window in PAIRS(entries) do
    windows[#windows + 1] = window
  end
  local first_error
  for _, window in ipairs(windows) do
    local ok, err = release_entry(state, window)
    if not ok and not first_error then
      first_error = err
    end
  end
  if first_error then
    return nil, first_error
  end
  return true
end

local function sync_projection(state)
  if RAWGET(state, "disposed") then
    return nil, "projection is disposed"
  end
  local released, release_err = release_all(state)
  if not released then
    return nil, release_err
  end

  local generation, logical_rows, shape_err = source_shape(state)
  if generation == nil then
    return nil, shape_err
  end
  local resized, resize_err = resize_skeleton(state, logical_rows)
  if not resized then
    return nil, resize_err
  end

  local final_generation, final_rows, final_err = source_shape(state)
  if final_generation == nil then
    return nil, final_err
  end
  if not RAW_EQUAL(final_generation, generation)
      or not RAW_EQUAL(final_rows, logical_rows) then
    return nil, "projection source changed during skeleton refresh"
  end
  RAWSET(state, "projected_generation", generation)
  RAWSET(state, "projected_rows", logical_rows)
  RAWSET(state, "needs_sync", false)
  return true
end

local function projection_redraw(state)
  local called, redraw_err = PCALL(REDRAW, {
    buf = RAWGET(state, "buffer"),
    flush = true,
    valid = false,
  })
  if not called then
    return nil, "projection redraw failed: "
      .. safe_diagnostic(redraw_err)
  end
  return true
end

local function detect_shape_change(state)
  local generation, logical_rows, shape_err = source_shape(state)
  if generation == nil then
    return nil, shape_err
  end
  local buffer = RAWGET(state, "buffer")
  if not BUF_IS_VALID(buffer) then
    return nil, "projection buffer is invalid"
  end
  local changed =
    not RAW_EQUAL(
      generation,
      RAWGET(state, "projected_generation")
    )
    or not RAW_EQUAL(logical_rows, RAWGET(state, "projected_rows"))
    or BUF_LINE_COUNT(buffer) ~= MAX(1, logical_rows)
    or not RAW_EQUAL(
      BUF_CHANGEDTICK(buffer),
      RAWGET(state, "skeleton_tick")
    )
    or not RAW_EQUAL(
      GET_OPTION("modifiable", { buf = buffer }),
      false
    )
  if changed then
    RAWSET(state, "needs_sync", true)
  else
    RAWSET(state, "needs_sync", false)
  end
  return not changed
end

local function finish_disposal(state)
  local released = release_all(state)
  if not released then
    PENDING_DISPOSALS[state] = true
    return nil, RAWGET(state, "last_error")
  end

  PENDING_DISPOSALS[state] = nil
  if RAWGET(state, "delete_buffer")
      and not RAWGET(state, "deleting_buffer") then
    local buffer = RAWGET(state, "buffer")
    local valid_ok, valid = PCALL(BUF_IS_VALID, buffer)
    if valid_ok and valid then
      RAWSET(state, "deleting_buffer", true)
      local deleted, delete_err =
        PCALL(DELETE_BUF, buffer, { force = true })
      RAWSET(state, "deleting_buffer", false)
      if not deleted then
        record_error(
          state,
          "could not delete projection buffer: "
            .. safe_diagnostic(delete_err)
        )
        PENDING_DISPOSALS[state] = true
        return nil, RAWGET(state, "last_error")
      end
    end
  end

  RAWSET(state, "finalized", true)
  RAWSET(state, "text", nil)
  RAWSET(state, "leases", {})
  return true
end

local function request_disposal(state, delete_buffer)
  if RAWGET(state, "finalized") then
    return true
  end
  if delete_buffer then
    RAWSET(state, "delete_buffer", true)
  end
  if not RAWGET(state, "disposed") then
    RAWSET(state, "disposed", true)
    local buffer = RAWGET(state, "buffer")
    if RAW_EQUAL(RAWGET(BY_BUFFER, buffer), state) then
      RAWSET(BY_BUFFER, buffer, nil)
    end
  end
  return finish_disposal(state)
end

local function provider_fault(state, prefix, fault)
  record_error(
    state,
    prefix .. ": " .. safe_diagnostic(fault)
  )
  return false
end

local function on_start()
  for _, state in PAIRS(BY_BUFFER) do
    RAWSET(state, "cycle_seen", false)
    RAWSET(state, "cycle_failed", false)
    local called, released, release_err = PCALL(release_all, state)
    if not called then
      provider_fault(state, "projection lease cleanup threw", released)
    elseif not released then
      record_error(state, release_err)
    end
    local shape_called, shape_current, shape_err =
      PCALL(detect_shape_change, state)
    if not shape_called then
      provider_fault(
        state,
        "projection shape check threw",
        shape_current
      )
    elseif shape_current == nil then
      record_error(state, shape_err)
    end
  end
  return NEXT(BY_BUFFER) ~= nil
end

local function on_buf(_, buffer)
  local state = RAWGET(BY_BUFFER, buffer)
  return state ~= nil
    and not RAWGET(state, "disposed")
    and not RAWGET(state, "needs_sync")
end

local function on_win_impl(state, window, buffer, top_row, bottom_row)
  if RAWGET(state, "disposed")
      or not RAW_EQUAL(RAWGET(state, "buffer"), buffer)
      or not finite_integer(top_row)
      or not finite_integer(bottom_row) then
    return false
  end

  local valid = WIN_IS_VALID(window)
  if not valid or not RAW_EQUAL(WIN_GET_BUF(window), buffer) then
    return false
  end

  local prior_ok = release_entry(state, window)
  if not prior_ok then
    return false
  end

  local text = RAWGET(state, "text")
  local shape_current, shape_err = detect_shape_change(state)
  if shape_current == nil then
    record_error(state, shape_err)
    return false
  end
  if not shape_current then
    return false
  end
  local logical_rows = RAWGET(state, "projected_rows")
  if logical_rows == 0 or top_row >= logical_rows then
    return false
  end

  local overscan = RAWGET(state, "overscan_rows")
  local start0 = MAX(0, top_row - overscan)
  -- `botrow` is exclusive until the viewport reaches EOF, where Neovim
  -- reports the inclusive last row instead. line("w$") is one-based, so its
  -- numeric value is the exact zero-based end-exclusive visible bound in
  -- both cases (and it remains exact through folds and wrapping).
  local visible_end0 = WINDOW_LAST_LINE("w$", window)
  if not finite_integer(visible_end0) or visible_end0 <= top_row then
    return false
  end
  local end0 = MIN(logical_rows, visible_end0 + overscan)
  if end0 <= start0 then
    return false
  end
  local generation = PAGE_LIST_GENERATION(text)
  local lease, lease_err =
    PAGE_LIST_PIN_RANGE(text, start0, end0 - start0, generation)
  if not lease then
    lease_error(state, "could not pin projection viewport", lease_err)
    return false
  end

  if RAWGET(state, "disposed")
      or not RAW_EQUAL(RAWGET(BY_BUFFER, buffer), state)
      or not RAW_EQUAL(PAGE_LIST_GENERATION(text), generation) then
    local released, release_err = PAGE_LIST_RELEASE_PIN(text, lease)
    if not released then
      lease_error(
        state,
        "could not release invalidated projection lease",
        release_err
      )
      RAWSET(RAWGET(state, "leases"), window, {
        lease = lease,
        start0 = start0,
        count = end0 - start0,
        generation = generation,
      })
    end
    return false
  end

  RAWSET(RAWGET(state, "leases"), window, {
    lease = lease,
    start0 = start0,
    count = end0 - start0,
    generation = generation,
  })
  return true
end

local function on_win(_, window, buffer, top_row, bottom_row)
  local state = RAWGET(BY_BUFFER, buffer)
  if not state then
    return false
  end
  RAWSET(state, "cycle_seen", true)
  provider_depth = provider_depth + 1
  local called, result =
    PCALL(on_win_impl, state, window, buffer, top_row, bottom_row)
  provider_depth = provider_depth - 1
  if not called then
    return provider_fault(state, "projection on_win threw", result)
  end
  return result
end

local function on_range_impl(
    state,
    window,
    buffer,
    begin_row,
    begin_col,
    end_row,
    end_col
)
  if RAWGET(state, "disposed")
      or not finite_integer(begin_row)
      or not finite_integer(begin_col)
      or not finite_integer(end_row)
      or not finite_integer(end_col) then
    return false
  end
  local shape_current, shape_err = detect_shape_change(state)
  if shape_current == nil then
    record_error(state, shape_err)
    return false
  end
  if not shape_current then
    return false
  end
  local entry = RAWGET(RAWGET(state, "leases"), window)
  if not entry then
    return false
  end

  local requested_end = end_row
  if end_col > 0 then
    requested_end = requested_end + 1
  end
  local lease_start = RAWGET(entry, "start0")
  local lease_end = lease_start + RAWGET(entry, "count")
  local start0 = MAX(begin_row, lease_start)
  local end0 = MIN(requested_end, lease_end)
  if end0 <= start0 then
    return true
  end

  local rows, rows_err = PAGE_LIST_PINNED_ROWS(
    RAWGET(state, "text"),
    RAWGET(entry, "lease"),
    start0,
    end0 - start0
  )
  if not rows then
    lease_error(state, "could not read projection viewport", rows_err)
    return false
  end

  -- How a page-backed canvas gets diff colours without a single persistent
  -- extmark: the owner is asked, per visible row, what this row should look
  -- like, and the answer is drawn ephemerally alongside the text. The million
  -- rows that are not on screen are never asked about and cost nothing.
  --
  -- The decorator is owner code running inside a decoration-provider callback,
  -- where a throw would take down the provider for every projection in the
  -- process. So it is contained per row: a row whose decorator throws or
  -- answers with the wrong shape renders as plain text, and the fault is
  -- recorded rather than propagated.
  local decorate = RAWGET(state, "decorate")
  for index = 1, #rows do
    local row0 = start0 + index - 1
    local text_hl = "Normal"
    local line_hl = nil
    local prefix_hl = nil
    local prefix_len = nil
    if decorate then
      local called, style = PCALL(decorate, row0, rows[index])
      if not called then
        record_error(state, "projection decorator threw: "
          .. safe_diagnostic(style))
      elseif TYPE(style) == "table" then
        if TYPE(RAWGET(style, "hl_group")) == "string" then
          text_hl = RAWGET(style, "hl_group")
        end
        if TYPE(RAWGET(style, "line_hl_group")) == "string" then
          line_hl = RAWGET(style, "line_hl_group")
        end
        -- The prefix answer is honoured only when it can actually split this
        -- row's bytes into two non-empty chunks. Anything else -- wrong type,
        -- fractional, zero, past the text -- degrades to the single-chunk
        -- overlay, per the containment rule above: a bad answer costs its row
        -- some colour, never a throw or truncated text.
        local candidate_hl = RAWGET(style, "prefix_hl")
        local candidate_len = RAWGET(style, "prefix_len")
        if TYPE(candidate_hl) == "string"
            and finite_integer(candidate_len)
            and candidate_len >= 1
            and candidate_len < #rows[index] then
          prefix_hl = candidate_hl
          prefix_len = candidate_len
        end
      elseif style ~= nil then
        record_error(state, "projection decorator must answer a table or nil")
      end
    end
    local virt_text
    if prefix_hl then
      virt_text = {
        { STRING_SUB(rows[index], 1, prefix_len), prefix_hl },
        { STRING_SUB(rows[index], prefix_len + 1), text_hl },
      }
    else
      virt_text = { { rows[index], text_hl } }
    end
    SET_EXTMARK(buffer, NAMESPACE, row0, 0, {
      ephemeral = true,
      priority = 200,
      virt_text = virt_text,
      virt_text_pos = "overlay",
      hl_mode = "combine",
      -- A full-width tint, so a diff row's colour reaches past the end of its
      -- text the way it does on the eager canvas. Nil when the row has none.
      line_hl_group = line_hl,
    })
  end
  return true
end

local function on_range(
    _,
    window,
    buffer,
    begin_row,
    begin_col,
    end_row,
    end_col
)
  local state = RAWGET(BY_BUFFER, buffer)
  if not state then
    return false
  end
  provider_depth = provider_depth + 1
  local called, first, second = PCALL(
    on_range_impl,
    state,
    window,
    buffer,
    begin_row,
    begin_col,
    end_row,
    end_col
  )
  provider_depth = provider_depth - 1
  if not called then
    return provider_fault(state, "projection on_range threw", first)
  end
  return first, second
end

local function on_end()
  for _, state in PAIRS(BY_BUFFER) do
    local called, released, release_err = PCALL(release_all, state)
    if not called then
      provider_fault(state, "projection on_end threw", released)
    elseif not released then
      record_error(state, release_err)
    end
    if RAWGET(state, "cycle_seen")
        and not RAWGET(state, "cycle_failed") then
      RAWSET(state, "last_error", nil)
    end
  end
end

local function install_provider()
  if provider_installed then
    return true
  end
  SET_PROVIDER(NAMESPACE, {
    on_start = on_start,
    on_buf = on_buf,
    on_win = on_win,
    on_range = on_range,
    on_end = on_end,
  })
  provider_installed = true
  return true
end

local function projection_options(opts)
  if opts == nil then
    opts = {}
  elseif TYPE(opts) ~= "table" then
    return nil, "projection options must be a table"
  end
  local overscan_rows = RAWGET(opts, "overscan_rows")
  if overscan_rows == nil then
    overscan_rows = DEFAULT_OVERSCAN_ROWS
  end
  local chunk_rows = RAWGET(opts, "skeleton_chunk_rows")
  if chunk_rows == nil then
    chunk_rows = DEFAULT_SKELETON_CHUNK_ROWS
  end
  if not finite_integer(overscan_rows)
      or overscan_rows > MAX_OVERSCAN_ROWS then
    return nil, "projection overscan_rows must be a bounded non-negative integer"
  end
  if not finite_integer(chunk_rows)
      or chunk_rows < 1
      or chunk_rows > MAX_SKELETON_CHUNK_ROWS then
    return nil, "projection skeleton_chunk_rows must be a bounded positive integer"
  end
  local decorate = RAWGET(opts, "decorate")
  if decorate ~= nil and TYPE(decorate) ~= "function" then
    return nil, "projection decorate must be a function"
  end
  return {
    overscan_rows = overscan_rows,
    skeleton_chunk_rows = chunk_rows,
    decorate = decorate,
  }
end

function Projection.create(text, opts)
  local options, options_err = projection_options(opts)
  if not options then
    return nil, options_err
  end
  local valid, validation_err = PAGE_LIST_VALIDATE(text)
  if not valid then
    return nil, "projection text is invalid: " .. safe_diagnostic(validation_err)
  end
  if TYPE(PAGE_LIST_PINNED_ROWS) ~= "function" then
    return nil, "PageList pinned reads are unavailable"
  end

  local logical_rows = PAGE_LIST_ROW_COUNT(text)
  local generation = PAGE_LIST_GENERATION(text)
  local created, buffer_or_err = PCALL(CREATE_BUF, false, true)
  if not created then
    return nil, "could not create projection buffer: "
      .. safe_diagnostic(buffer_or_err)
  end
  local buffer = buffer_or_err
  local configured, configure_err = PCALL(function()
    configure_buffer(buffer)
    BUF_SET_NAME(buffer, "canvasdiff://projection/" .. buffer)
    populate_skeleton(
      buffer,
      logical_rows,
      options.skeleton_chunk_rows
    )
    SET_OPTION("modifiable", false, { buf = buffer })
    install_provider()
  end)
  if not configured then
    PCALL(DELETE_BUF, buffer, { force = true })
    return nil, "could not initialize projection buffer: "
      .. safe_diagnostic(configure_err)
  end

  local self = SETMETATABLE({}, Projection)
  local state = {
    buffer = buffer,
    text = text,
    overscan_rows = options.overscan_rows,
    skeleton_chunk_rows = options.skeleton_chunk_rows,
    decorate = options.decorate,
    leases = {},
    projected_generation = generation,
    projected_rows = logical_rows,
    skeleton_tick = BUF_CHANGEDTICK(buffer),
    needs_sync = false,
    disposed = false,
    finalized = false,
    delete_buffer = false,
  }
  STATES[self] = state
  local synchronized, synchronize_err = sync_projection(state)
  if not synchronized then
    request_disposal(state, true)
    return nil, "could not synchronize projection buffer: "
      .. safe_diagnostic(synchronize_err)
  end
  BY_BUFFER[buffer] = state

  local attach_called, attached, attach_err = PCALL(
    ATTACH_BUF,
    buffer,
    false,
    {
      on_detach = function(_, detached_buffer)
        local detached = RAWGET(BY_BUFFER, detached_buffer)
        if detached then
          request_disposal(detached, false)
        end
      end,
    }
  )
  if not attach_called or not attached then
    request_disposal(state, true)
    return nil, "could not attach projection buffer: "
      .. safe_diagnostic(attach_called and attach_err or attached)
  end
  return self
end

function Projection.new(text, opts)
  local projection, err = Projection.create(text, opts)
  assert(projection, err)
  return projection
end

function Projection:buffer()
  local state, err = state_for(self)
  if not state then
    return nil, err
  end
  if RAWGET(state, "disposed") then
    return nil, "projection is disposed"
  end
  return RAWGET(state, "buffer")
end

function Projection:row_count()
  local state, err = state_for(self)
  if not state then
    return nil, err
  end
  if RAWGET(state, "disposed") then
    return nil, "projection is disposed"
  end
  return PAGE_LIST_ROW_COUNT(RAWGET(state, "text"))
end

function Projection:row(row0)
  local state, err = state_for(self)
  if not state then
    return nil, err
  end
  if RAWGET(state, "disposed") then
    return nil, "projection is disposed"
  end
  return PAGE_LIST_ROW(RAWGET(state, "text"), row0)
end

function Projection:rows(start0, count)
  local state, err = state_for(self)
  if not state then
    return nil, err
  end
  if RAWGET(state, "disposed") then
    return nil, "projection is disposed"
  end
  return PAGE_LIST_ROWS(RAWGET(state, "text"), start0, count)
end

function Projection:export(start0, count, opts)
  local state, err = state_for(self)
  if not state then
    return nil, err
  end
  if RAWGET(state, "disposed") then
    return nil, "projection is disposed"
  end
  if opts == nil then
    opts = {}
  elseif TYPE(opts) ~= "table" then
    return nil, "export options must be a table"
  end
  local separator = RAWGET(opts, "separator")
  if separator == nil then
    separator = "\n"
  elseif TYPE(separator) ~= "string" then
    return nil, "export separator must be a string"
  end
  local terminal_eol = RAWGET(opts, "terminal_eol")
  if terminal_eol == nil then
    terminal_eol = false
  elseif TYPE(terminal_eol) ~= "boolean" then
    return nil, "export terminal_eol must be a boolean"
  end

  local rows, rows_err =
    PAGE_LIST_ROWS(RAWGET(state, "text"), start0, count)
  if not rows then
    return nil, rows_err
  end
  local result = TABLE_CONCAT(rows, separator)
  if terminal_eol and count > 0 then
    result = result .. separator
  end
  return result
end

function Projection:refresh()
  local state, err = state_for(self)
  if not state then
    return nil, err
  end
  if RAWGET(state, "disposed") then
    return nil, "projection is disposed"
  end
  if provider_depth > 0 then
    RAWSET(state, "needs_sync", true)
    return nil, "projection cannot refresh during a provider callback"
  end
  local called, refreshed, refresh_err =
    PCALL(sync_projection, state)
  if not called then
    return nil, "projection refresh threw: "
      .. safe_diagnostic(refreshed)
  end
  return refreshed, refresh_err
end

function Projection:redraw()
  local state, err = state_for(self)
  if not state then
    return nil, err
  end
  if RAWGET(state, "disposed") then
    return nil, "projection is disposed"
  end
  if provider_depth > 0 then
    RAWSET(state, "needs_sync", true)
    return nil, "projection cannot redraw during a provider callback"
  end
  local called, refreshed, refresh_err =
    PCALL(sync_projection, state)
  if not called then
    return nil, "projection refresh threw: "
      .. safe_diagnostic(refreshed)
  end
  if not refreshed then
    return nil, refresh_err
  end
  return projection_redraw(state)
end

function Projection:last_error()
  local state, err = state_for(self)
  if not state then
    return nil, err
  end
  return RAWGET(state, "last_error")
end

function Projection:stats()
  local state, err = state_for(self)
  if not state then
    return nil, err
  end
  local active_leases = 0
  for _ in PAIRS(RAWGET(state, "leases")) do
    active_leases = active_leases + 1
  end
  local logical_rows = 0
  local source_generation
  if not RAWGET(state, "finalized") then
    logical_rows = PAGE_LIST_ROW_COUNT(RAWGET(state, "text"))
    source_generation = PAGE_LIST_GENERATION(RAWGET(state, "text"))
  end
  local skeleton_rows = 0
  local buffer = RAWGET(state, "buffer")
  local valid_ok, valid = PCALL(BUF_IS_VALID, buffer)
  if valid_ok and valid then
    local count_ok, count = PCALL(BUF_LINE_COUNT, buffer)
    if count_ok then
      skeleton_rows = count
    end
  end
  return {
    buffer = buffer,
    logical_rows = logical_rows,
    skeleton_rows = skeleton_rows,
    active_leases = active_leases,
    overscan_rows = RAWGET(state, "overscan_rows"),
    projected_generation = RAWGET(state, "projected_generation"),
    source_generation = source_generation,
    needs_sync = RAWGET(state, "needs_sync"),
    disposed = RAWGET(state, "disposed"),
    finalized = RAWGET(state, "finalized"),
    last_error = RAWGET(state, "last_error"),
  }
end

function Projection:validate()
  local state, err = state_for(self)
  if not state then
    return nil, err
  end
  if RAWGET(state, "disposed") then
    if RAW_EQUAL(RAWGET(BY_BUFFER, RAWGET(state, "buffer")), state) then
      return nil, "disposed projection remains registered"
    end
    if not RAWGET(state, "finalized") then
      return nil,
        RAWGET(state, "last_error")
          or "projection disposal is still pending"
    end
    if RAWGET(state, "text") ~= nil
        or NEXT(RAWGET(state, "leases")) ~= nil then
      return nil, "finalized projection retained source state"
    end
    return true
  end
  local text_ok, text_err = PAGE_LIST_VALIDATE(RAWGET(state, "text"))
  if not text_ok then
    return nil, "projection text is invalid: " .. safe_diagnostic(text_err)
  end
  local buffer = RAWGET(state, "buffer")
  if not BUF_IS_VALID(buffer) then
    return nil, "projection buffer is invalid"
  end
  if not RAW_EQUAL(RAWGET(BY_BUFFER, buffer), state) then
    return nil, "projection buffer ownership is inconsistent"
  end
  local generation, logical_rows, shape_err = source_shape(state)
  if generation == nil then
    return nil, shape_err
  end
  if not RAW_EQUAL(
        generation,
        RAWGET(state, "projected_generation")
      )
      or not RAW_EQUAL(logical_rows, RAWGET(state, "projected_rows"))
      or RAWGET(state, "needs_sync") then
    return nil, "projection source shape is not synchronized"
  end
  local expected_rows = MAX(1, logical_rows)
  if BUF_LINE_COUNT(buffer) ~= expected_rows then
    return nil, "projection skeleton row count is inconsistent"
  end
  if not RAW_EQUAL(
    GET_OPTION("modifiable", { buf = buffer }),
    false
  ) then
    return nil, "projection skeleton is modifiable"
  end
  local blank, blank_err =
    validate_blank_skeleton(state, buffer, expected_rows)
  if not blank then
    return nil, blank_err
  end
  local marks = GET_EXTMARKS(buffer, NAMESPACE, 0, -1, {})
  if #marks ~= 0 then
    return nil, "projection retained persistent row extmarks"
  end
  return true
end

function Projection:dispose(delete_buffer)
  local state, err = state_for(self)
  if not state then
    return nil, err
  end
  if delete_buffer == nil then
    delete_buffer = true
  elseif TYPE(delete_buffer) ~= "boolean" then
    return nil, "delete_buffer must be a boolean"
  end
  if provider_depth > 0 and delete_buffer then
    return nil,
      "projection cannot delete its buffer during a provider callback"
  end
  return request_disposal(state, delete_buffer)
end

Projection.DEFAULT_OVERSCAN_ROWS = DEFAULT_OVERSCAN_ROWS
Projection.DEFAULT_SKELETON_CHUNK_ROWS = DEFAULT_SKELETON_CHUNK_ROWS
Projection.NAMESPACE = NAMESPACE

return Projection
