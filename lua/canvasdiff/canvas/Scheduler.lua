-- Idle-time compaction owner for one PageList. `touch` starts a generation-
-- fenced cycle and disposal retires its timer; faults remain observable through
-- stats without transferring lifetime to callers. Each slice inspects and
-- compacts only fixed budgets so background work stays bounded.
local PageList = require("canvasdiff.canvas.PageList")
local system = require("canvasdiff.os")

local Scheduler = {}
Scheduler.__index = Scheduler
Scheduler.__metatable = "canvasdiff.canvas.Scheduler"

local PAGE_LIST_VALIDATE = PageList.validate
local PAGE_LIST_GENERATION = PageList.generation
local PAGE_LIST_PAGE_COUNT = PageList.page_count
local PAGE_LIST_INSPECT_PAGE = PageList.inspect_page
local PAGE_LIST_RESIDENT_STATS = PageList.resident_stats
local PAGE_LIST_COMPACT_PAGE = PageList.compact_page
local NEW_TIMER = system.new_timer
local SCHEDULE = vim.schedule

local ASSERT = assert
local FLOOR = math.floor
local HUGE = math.huge
local IPAIRS = ipairs
local NEXT = next
local PCALL = pcall
local RAW_EQUAL = rawequal
local RAWGET = rawget
local RAWSET = rawset
local RAW_METATABLE = debug.getmetatable
local SETMETATABLE = setmetatable
local STRING_FIND = string.find
local STRING_SUB = string.sub
local TOSTRING = tostring
local TYPE = type

local DEFAULT_IDLE_MS = 250
local DEFAULT_CONTINUATION_MS = 1
local MAX_IDLE_MS = 60000
local MAX_CONTINUATION_MS = 1000
local INSPECTION_BUDGET = 8
local COMPACTION_BUDGET = 1
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_DIAGNOSTIC_BYTES = 512
local COUNTER_FIELDS = {
  "slices",
  "inspections",
  "attempts",
  "compacted",
  "skipped_cold",
  "skipped_incomplete",
  "skipped_quarantined",
  "skipped_capacity",
  "skipped_no_benefit",
  "skipped_rejected",
  "pinned_deferrals",
  "contention_deferrals",
  "generation_restarts",
  "error_count",
  "timer_faults",
  "schedule_faults",
  "compaction_faults",
  "source_faults",
}
local PHASES = {
  complete = true,
  continuation = true,
  disposed = true,
  ["fault-retry"] = true,
  ["generation-restart"] = true,
  idle = true,
  ["pinned-retry"] = true,
  scan = true,
  verification = true,
}

local STATES = SETMETATABLE({}, { __mode = "k" })

local run_slice
local arm

local function integer(value)
  return TYPE(value) == "number"
    and value == value
    and value ~= HUGE
    and value ~= -HUGE
    and value >= 0
    and value <= MAX_SAFE_INTEGER
    and value == FLOOR(value)
end

local function bounded_integer(value, maximum)
  return integer(value) and value <= maximum
end

local function safe_diagnostic(value)
  if TYPE(value) == "string" then
    return value
  end
  local called, rendered = PCALL(TOSTRING, value)
  if called and TYPE(rendered) == "string" then
    return rendered
  end
  return "<unprintable error>"
end

local function bounded_message(message)
  if TYPE(message) ~= "string" then
    message = safe_diagnostic(message)
  end
  if #message > MAX_DIAGNOSTIC_BYTES then
    return STRING_SUB(message, 1, MAX_DIAGNOSTIC_BYTES - 3) .. "..."
  end
  return message
end

local function record_error(state, category, prefix, detail)
  local message = prefix
  if detail ~= nil then
    message = message .. ": " .. safe_diagnostic(detail)
  end
  RAWSET(state, "last_error", bounded_message(message))
  RAWSET(state, "cycle_failed", true)
  RAWSET(state, "error_count", RAWGET(state, "error_count") + 1)
  if category == "timer" then
    RAWSET(state, "timer_faults", RAWGET(state, "timer_faults") + 1)
  elseif category == "schedule" then
    RAWSET(
      state,
      "schedule_faults",
      RAWGET(state, "schedule_faults") + 1
    )
  elseif category == "compaction" then
    RAWSET(
      state,
      "compaction_faults",
      RAWGET(state, "compaction_faults") + 1
    )
  else
    RAWSET(
      state,
      "source_faults",
      RAWGET(state, "source_faults") + 1
    )
  end
  return RAWGET(state, "last_error")
end

local function state_for(self)
  if TYPE(self) ~= "table" then
    return nil, "scheduler must be a table"
  end
  local state = STATES[self]
  if not state then
    return nil, "scheduler is not owned by CanvasDiff"
  end
  return state
end

local function slice_is_current(state, activity_token, arm_serial)
  return not RAWGET(state, "disposed")
    and RAW_EQUAL(RAWGET(state, "activity_token"), activity_token)
    and RAW_EQUAL(RAWGET(state, "arm_serial"), arm_serial)
end

local function options(opts)
  if opts == nil then
    opts = {}
  elseif TYPE(opts) ~= "table" then
    return nil, "scheduler options must be a table"
  end

  local idle_ms = RAWGET(opts, "idle_ms")
  if idle_ms == nil then
    idle_ms = DEFAULT_IDLE_MS
  end
  local continuation_ms = RAWGET(opts, "continuation_ms")
  if continuation_ms == nil then
    continuation_ms = DEFAULT_CONTINUATION_MS
  end
  if not bounded_integer(idle_ms, MAX_IDLE_MS) then
    return nil,
      "scheduler idle_ms must be a bounded non-negative integer"
  end
  if not bounded_integer(continuation_ms, MAX_CONTINUATION_MS) then
    return nil,
      "scheduler continuation_ms must be a bounded non-negative integer"
  end
  return {
    idle_ms = idle_ms,
    continuation_ms = continuation_ms,
  }
end

local function call_generation(state)
  local called, generation =
    PCALL(PAGE_LIST_GENERATION, RAWGET(state, "list"))
  if not called then
    return nil, "PageList generation threw: " .. safe_diagnostic(generation)
  end
  if not integer(generation) then
    return nil, "PageList returned an invalid generation"
  end
  return generation
end

local function call_page_count(state)
  local called, count =
    PCALL(PAGE_LIST_PAGE_COUNT, RAWGET(state, "list"))
  if not called then
    return nil, "PageList page count threw: " .. safe_diagnostic(count)
  end
  if not integer(count) then
    return nil, "PageList returned an invalid page count"
  end
  return count
end

local function call_resident_stats(state)
  local called, stats, stats_err =
    PCALL(PAGE_LIST_RESIDENT_STATS, RAWGET(state, "list"))
  if not called then
    return nil,
      "PageList resident stats threw: " .. safe_diagnostic(stats)
  end
  if TYPE(stats) ~= "table" then
    return nil, stats_err or "PageList resident stats are unavailable"
  end
  local max_pages = RAWGET(stats, "max_pages")
  local max_bytes = RAWGET(stats, "max_bytes")
  if not integer(max_pages) or not integer(max_bytes) then
    return nil, "PageList returned invalid resident limits"
  end
  return {
    max_pages = max_pages,
    max_bytes = max_bytes,
  }
end

local function valid_snapshot(snapshot, page_index0, generation)
  if TYPE(snapshot) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(snapshot), nil)
      or not RAW_EQUAL(RAWGET(snapshot, "generation"), generation)
      or not RAW_EQUAL(RAWGET(snapshot, "page_index"), page_index0)
      or not integer(RAWGET(snapshot, "id"))
      or RAWGET(snapshot, "id") < 1
      or not integer(RAWGET(snapshot, "revision"))
      or not integer(RAWGET(snapshot, "pin_count"))
      or not integer(RAWGET(snapshot, "storage_bytes"))
      or not integer(RAWGET(snapshot, "restore_bytes"))
      or TYPE(RAWGET(snapshot, "kind")) ~= "string"
      or TYPE(RAWGET(snapshot, "quarantined")) ~= "boolean" then
    return nil, "PageList returned an invalid page snapshot"
  end
  return true
end

local function call_inspect(state, page_index0, generation)
  local called, snapshot, snapshot_err = PCALL(
    PAGE_LIST_INSPECT_PAGE,
    RAWGET(state, "list"),
    page_index0,
    generation
  )
  if not called then
    return nil, "PageList inspection threw: " .. safe_diagnostic(snapshot)
  end
  if not snapshot then
    return nil, snapshot_err or "PageList inspection failed"
  end
  local valid, valid_err =
    valid_snapshot(snapshot, page_index0, generation)
  if not valid then
    return nil, valid_err
  end
  return snapshot
end

local function reset_pass(state)
  RAWSET(state, "cursor", 0)
  RAWSET(state, "pass_compacted", false)
  RAWSET(state, "pass_deferred", false)
  RAWSET(state, "pending_pinned", false)
  RAWSET(state, "deferred", {})
  RAWSET(state, "retry_entries", nil)
  RAWSET(state, "retry_cursor", 0)
end

local function restart_generation(state, generation)
  if RAWGET(state, "scan_generation") ~= nil then
    RAWSET(
      state,
      "generation_restarts",
      RAWGET(state, "generation_restarts") + 1
    )
  end
  RAWSET(state, "scan_generation", generation)
  RAWSET(state, "idle_complete_generation", nil)
  RAWSET(state, "verified_generation", nil)
  if not RAW_EQUAL(
      RAWGET(state, "rejected_generation"),
      generation
    ) then
    RAWSET(state, "rejected", {})
    RAWSET(state, "rejected_generation", generation)
  end
  RAWSET(state, "verification", false)
  RAWSET(state, "fault_rejected", {})
  reset_pass(state)
  RAWSET(state, "phase", "scan")
end

local function reject_snapshot(state, snapshot, durable)
  RAWSET(
    RAWGET(
      state,
      durable and "rejected" or "fault_rejected"
    ),
    RAWGET(snapshot, "id"),
    RAWGET(snapshot, "revision")
  )
end

local function snapshot_is_rejected(state, snapshot)
  local id = RAWGET(snapshot, "id")
  local revision = RAWGET(snapshot, "revision")
  return RAW_EQUAL(RAWGET(RAWGET(state, "rejected"), id), revision)
    or RAW_EQUAL(
      RAWGET(RAWGET(state, "fault_rejected"), id),
      revision
    )
end

local function contains(message, needle)
  return TYPE(message) == "string"
    and STRING_FIND(message, needle, 1, true) ~= nil
end

local function transient_compaction_error(message)
  return contains(message, "already active")
    or contains(message, "changed during compaction")
    or contains(message, "unpinned")
    or contains(message, "generation changed")
end

local function schedule_fault_retry(state)
  if RAWGET(state, "disposed") then
    return
  end
  RAWSET(state, "phase", "fault-retry")
  arm(state, RAWGET(state, "idle_ms"))
end

local function timer_callback(state, activity_token, arm_serial)
  if RAWGET(state, "disposed")
      or not RAWGET(state, "armed")
      or not RAW_EQUAL(RAWGET(state, "activity_token"), activity_token)
      or not RAW_EQUAL(RAWGET(state, "arm_serial"), arm_serial) then
    return
  end
  RAWSET(state, "armed", false)
  RAWSET(state, "scheduled", true)

  local scheduled_callback = function()
    if RAWGET(state, "disposed")
        or not RAW_EQUAL(
          RAWGET(state, "activity_token"),
          activity_token
        )
        or not RAW_EQUAL(RAWGET(state, "arm_serial"), arm_serial)
        or not RAWGET(state, "scheduled") then
      return
    end
    RAWSET(state, "scheduled", false)
    local called, slice_err = PCALL(
      run_slice,
      state,
      activity_token,
      arm_serial
    )
    if not slice_is_current(state, activity_token, arm_serial) then
      return
    end
    if not called then
      record_error(
        state,
        "source",
        "scheduler slice threw",
        slice_err
      )
      if slice_is_current(state, activity_token, arm_serial) then
        schedule_fault_retry(state)
      end
    end
  end

  local called, schedule_result = PCALL(SCHEDULE, scheduled_callback)
  if (not called or RAW_EQUAL(schedule_result, false))
      and RAWGET(state, "scheduled")
      and not RAWGET(state, "disposed")
      and RAW_EQUAL(RAWGET(state, "activity_token"), activity_token)
      and RAW_EQUAL(RAWGET(state, "arm_serial"), arm_serial) then
    RAWSET(state, "scheduled", false)
    record_error(
      state,
      "schedule",
      "scheduler callback could not be scheduled",
      called and "scheduler returned false" or schedule_result
    )
    schedule_fault_retry(state)
  end
end

arm = function(state, delay_ms)
  if RAWGET(state, "disposed") then
    return nil, "scheduler is disposed"
  end

  local timer = RAWGET(state, "timer")
  local activity_token = RAWGET(state, "activity_token")
  local arm_serial = RAWGET(state, "arm_serial") + 1

  -- Invalidate both async boundaries before touching the timer. A hostile
  -- stop() may synchronously deliver the callback it was meant to cancel.
  RAWSET(state, "arm_serial", arm_serial)
  RAWSET(state, "armed", false)
  RAWSET(state, "scheduled", false)
  RAWSET(state, "current_delay_ms", delay_ms)

  local stopped, stop_result = PCALL(function()
    return timer:stop()
  end)
  if not stopped or RAW_EQUAL(stop_result, false) then
    record_error(
      state,
      "timer",
      "scheduler timer stop failed",
      stopped and "timer returned false" or stop_result
    )
  end
  if RAWGET(state, "disposed")
      or not RAW_EQUAL(RAWGET(state, "activity_token"), activity_token)
      or not RAW_EQUAL(RAWGET(state, "arm_serial"), arm_serial) then
    return false, "scheduler arm was superseded"
  end

  RAWSET(state, "armed", true)
  local started, start_result = PCALL(function()
    return timer:start(delay_ms, 0, function()
      timer_callback(state, activity_token, arm_serial)
    end)
  end)
  if not started or RAW_EQUAL(start_result, false) then
    local diagnostic = record_error(
      state,
      "timer",
      "scheduler timer start failed",
      started and "timer returned false" or start_result
    )
    if RAW_EQUAL(RAWGET(state, "arm_serial"), arm_serial) then
      RAWSET(state, "armed", false)
      RAWSET(state, "scheduled", false)
      RAWSET(state, "arm_serial", arm_serial + 1)
      return nil, diagnostic
    end
    return false, "scheduler arm was superseded"
  end
  if RAWGET(state, "disposed")
      or not RAW_EQUAL(RAWGET(state, "activity_token"), activity_token)
      or not RAW_EQUAL(RAWGET(state, "arm_serial"), arm_serial)
      or not RAWGET(state, "armed") then
    return false, "scheduler arm was superseded"
  end
  return true
end

local function continue_after(state, delay_ms, phase)
  RAWSET(state, "phase", phase)
  local armed, arm_err = arm(state, delay_ms)
  if not armed and arm_err ~= "scheduler arm was superseded" then
    return nil, arm_err
  end
  return true
end

local function restart_if_changed(state, expected_generation)
  local generation, generation_err = call_generation(state)
  if generation == nil then
    record_error(
      state,
      "source",
      "scheduler could not verify PageList generation",
      generation_err
    )
    continue_after(state, RAWGET(state, "idle_ms"), "fault-retry")
    return true
  end
  if not RAW_EQUAL(generation, expected_generation) then
    restart_generation(state, generation)
    continue_after(
      state,
      RAWGET(state, "continuation_ms"),
      "generation-restart"
    )
    return true
  end
  return false
end

local function complete_pass(state)
  local generation = RAWGET(state, "scan_generation")
  if restart_if_changed(state, generation) then
    return
  end

  if RAWGET(state, "pass_deferred") then
    local deferred = RAWGET(state, "deferred")
    RAWSET(state, "verification", true)
    reset_pass(state)
    RAWSET(state, "retry_entries", deferred)
    RAWSET(state, "retry_cursor", 1)
    RAWSET(state, "pending_pinned", true)
    continue_after(state, RAWGET(state, "idle_ms"), "pinned-retry")
    return
  end

  if not RAWGET(state, "verification")
      or RAWGET(state, "pass_compacted") then
    RAWSET(state, "verification", true)
    reset_pass(state)
    continue_after(
      state,
      RAWGET(state, "continuation_ms"),
      "verification"
    )
    return
  end

  RAWSET(state, "phase", "complete")
  RAWSET(state, "idle_complete_generation", nil)
  RAWSET(state, "verified_generation", generation)
  RAWSET(state, "pending_pinned", false)
  RAWSET(state, "current_delay_ms", nil)
  if not RAWGET(state, "cycle_failed") then
    RAWSET(state, "last_error", nil)
  end
end

local function inspect_candidate(state, snapshot, resident, page_count)
  if RAWGET(snapshot, "page_index") == page_count - 1 then
    RAWSET(
      state,
      "skipped_incomplete",
      RAWGET(state, "skipped_incomplete") + 1
    )
    return false
  end
  if RAWGET(snapshot, "quarantined") then
    RAWSET(
      state,
      "skipped_quarantined",
      RAWGET(state, "skipped_quarantined") + 1
    )
    return false
  end
  if RAWGET(snapshot, "kind") ~= "raw" then
    RAWSET(
      state,
      "skipped_cold",
      RAWGET(state, "skipped_cold") + 1
    )
    return false
  end
  if snapshot_is_rejected(state, snapshot) then
    RAWSET(
      state,
      "skipped_rejected",
      RAWGET(state, "skipped_rejected") + 1
    )
    return false
  end
  if RAWGET(snapshot, "pin_count") > 0 then
    RAWSET(state, "pass_deferred", true)
    local deferred = RAWGET(state, "deferred")
    deferred[#deferred + 1] = {
      page_index = RAWGET(snapshot, "page_index"),
      id = RAWGET(snapshot, "id"),
      revision = RAWGET(snapshot, "revision"),
    }
    RAWSET(
      state,
      "pinned_deferrals",
      RAWGET(state, "pinned_deferrals") + 1
    )
    return false
  end
  if RAWGET(resident, "max_pages") < 1
      or RAWGET(snapshot, "restore_bytes")
        > RAWGET(resident, "max_bytes") then
    reject_snapshot(state, snapshot, true)
    RAWSET(
      state,
      "skipped_capacity",
      RAWGET(state, "skipped_capacity") + 1
    )
    return false
  end
  return true
end

local function attempt_compaction(
    state,
    snapshot,
    generation,
    activity_token,
    arm_serial
  )
  local called, compacted, compact_err = PCALL(
    PAGE_LIST_COMPACT_PAGE,
    RAWGET(state, "list"),
    RAWGET(snapshot, "page_index"),
    generation
  )
  if not slice_is_current(state, activity_token, arm_serial) then
    return "stale"
  end
  RAWSET(state, "attempts", RAWGET(state, "attempts") + 1)

  local current_generation, generation_err = call_generation(state)
  if current_generation == nil then
    record_error(
      state,
      "source",
      "scheduler could not verify generation after compaction",
      generation_err
    )
    continue_after(state, RAWGET(state, "idle_ms"), "fault-retry")
    return "rescheduled"
  end
  if not RAW_EQUAL(current_generation, generation) then
    restart_generation(state, current_generation)
    continue_after(
      state,
      RAWGET(state, "continuation_ms"),
      "generation-restart"
    )
    return "rescheduled"
  end

  if not called then
    reject_snapshot(state, snapshot, false)
    record_error(
      state,
      "compaction",
      "PageList compaction threw",
      compacted
    )
    return false
  end
  if compacted == true then
    RAWSET(state, "compacted", RAWGET(state, "compacted") + 1)
    RAWSET(state, "pass_compacted", true)
    return true
  end
  if compacted == false then
    reject_snapshot(state, snapshot, true)
    RAWSET(
      state,
      "skipped_no_benefit",
      RAWGET(state, "skipped_no_benefit") + 1
    )
    return false
  end

  if transient_compaction_error(compact_err) then
    RAWSET(state, "pass_deferred", true)
    RAWSET(
      state,
      "contention_deferrals",
      RAWGET(state, "contention_deferrals") + 1
    )
    return false
  end
  reject_snapshot(state, snapshot, false)
  record_error(
    state,
    "compaction",
    "PageList compaction failed",
    compact_err or "unknown failure"
  )
  return false
end

local function run_pinned_retry(
    state,
    generation,
    page_count,
    resident,
    activity_token,
    arm_serial
  )
  local entries = RAWGET(state, "retry_entries")
  if TYPE(entries) ~= "table" then
    return false
  end

  RAWSET(state, "phase", "pinned-retry")
  local cursor = RAWGET(state, "retry_cursor")
  local inspected = 0
  local attempted = 0
  while cursor <= #entries
      and inspected < INSPECTION_BUDGET
      and attempted < COMPACTION_BUDGET do
    local expected = entries[cursor]
    cursor = cursor + 1
    local page_index0 = RAWGET(expected, "page_index")
    local snapshot, snapshot_err =
      call_inspect(state, page_index0, generation)
    if not snapshot then
      if restart_if_changed(state, generation) then
        return true
      end
      record_error(
        state,
        "source",
        "scheduler deferred page inspection failed",
        snapshot_err
      )
      continue_after(state, RAWGET(state, "idle_ms"), "fault-retry")
      return true
    end
    if not RAW_EQUAL(
        RAWGET(snapshot, "id"),
        RAWGET(expected, "id")
      ) then
      record_error(
        state,
        "source",
        "scheduler deferred page identity changed"
      )
      restart_generation(state, generation)
      continue_after(
        state,
        RAWGET(state, "continuation_ms"),
        "generation-restart"
      )
      return true
    end

    inspected = inspected + 1
    RAWSET(state, "inspections", RAWGET(state, "inspections") + 1)
    if inspect_candidate(state, snapshot, resident, page_count) then
      attempted = attempted + 1
      local result = attempt_compaction(
        state,
        snapshot,
        generation,
        activity_token,
        arm_serial
      )
      if result == "rescheduled" or result == "stale" then
        return true
      end
    end
  end
  RAWSET(state, "retry_cursor", cursor)

  if restart_if_changed(state, generation) then
    return true
  end
  if cursor <= #entries then
    local delay = attempted > 0
        and RAWGET(state, "continuation_ms")
      or RAWGET(state, "idle_ms")
    local phase = attempted > 0 and "continuation" or "pinned-retry"
    continue_after(state, delay, phase)
    return true
  end

  local deferred = RAWGET(state, "deferred")
  RAWSET(state, "retry_entries", nil)
  RAWSET(state, "retry_cursor", 0)
  RAWSET(state, "deferred", {})
  if #deferred > 0 then
    RAWSET(state, "retry_entries", deferred)
    RAWSET(state, "retry_cursor", 1)
    RAWSET(state, "pending_pinned", true)
    continue_after(state, RAWGET(state, "idle_ms"), "pinned-retry")
    return true
  end

  RAWSET(state, "verification", true)
  reset_pass(state)
  continue_after(
    state,
    RAWGET(state, "continuation_ms"),
    "verification"
  )
  return true
end

run_slice = function(state, activity_token, arm_serial)
  if not slice_is_current(state, activity_token, arm_serial) then
    return
  end
  RAWSET(state, "slices", RAWGET(state, "slices") + 1)

  local generation, generation_err = call_generation(state)
  if generation == nil then
    record_error(
      state,
      "source",
      "scheduler could not read PageList generation",
      generation_err
    )
    continue_after(state, RAWGET(state, "idle_ms"), "fault-retry")
    return
  end
  local idle_complete_generation =
    RAWGET(state, "idle_complete_generation")
  if idle_complete_generation ~= nil then
    RAWSET(state, "idle_complete_generation", nil)
    if RAW_EQUAL(generation, idle_complete_generation) then
      RAWSET(state, "phase", "complete")
      RAWSET(state, "current_delay_ms", nil)
      if not RAWGET(state, "cycle_failed") then
        RAWSET(state, "last_error", nil)
      end
      return
    end
  end
  if not RAW_EQUAL(generation, RAWGET(state, "scan_generation")) then
    restart_generation(state, generation)
  end

  local page_count, page_count_err = call_page_count(state)
  if page_count == nil then
    record_error(
      state,
      "source",
      "scheduler could not read PageList page count",
      page_count_err
    )
    continue_after(state, RAWGET(state, "idle_ms"), "fault-retry")
    return
  end
  local resident, resident_err = call_resident_stats(state)
  if not resident then
    record_error(
      state,
      "source",
      "scheduler could not read resident limits",
      resident_err
    )
    continue_after(state, RAWGET(state, "idle_ms"), "fault-retry")
    return
  end
  if restart_if_changed(state, generation) then
    return
  end
  if run_pinned_retry(
      state,
      generation,
      page_count,
      resident,
      activity_token,
      arm_serial
    ) then
    return
  end

  RAWSET(state, "phase",
    RAWGET(state, "verification") and "verification" or "scan")
  local inspected = 0
  local attempted = 0
  while RAWGET(state, "cursor") < page_count
      and inspected < INSPECTION_BUDGET
      and attempted < COMPACTION_BUDGET do
    local page_index0 = RAWGET(state, "cursor")
    local snapshot, snapshot_err =
      call_inspect(state, page_index0, generation)
    if not snapshot then
      if restart_if_changed(state, generation) then
        return
      end
      record_error(
        state,
        "source",
        "scheduler page inspection failed",
        snapshot_err
      )
      continue_after(state, RAWGET(state, "idle_ms"), "fault-retry")
      return
    end

    RAWSET(state, "cursor", page_index0 + 1)
    inspected = inspected + 1
    RAWSET(state, "inspections", RAWGET(state, "inspections") + 1)
    if inspect_candidate(state, snapshot, resident, page_count) then
      attempted = attempted + 1
      local result = attempt_compaction(
        state,
        snapshot,
        generation,
        activity_token,
        arm_serial
      )
      if result == "rescheduled" or result == "stale" then
        return
      end
    end
  end

  if restart_if_changed(state, generation) then
    return
  end
  if RAWGET(state, "cursor") < page_count then
    continue_after(
      state,
      RAWGET(state, "continuation_ms"),
      "continuation"
    )
    return
  end
  complete_pass(state)
end

local function close_timer(state)
  local timer = RAWGET(state, "timer")
  if timer == nil then
    return true
  end
  if RAWGET(state, "closing_timer") then
    return nil, "scheduler timer close is already active"
  end
  RAWSET(state, "closing_timer", true)

  local function finish(result, err)
    RAWSET(state, "closing_timer", false)
    return result, err
  end

  local stopped, stop_result = PCALL(function()
    return timer:stop()
  end)
  if not stopped or RAW_EQUAL(stop_result, false) then
    record_error(
      state,
      "timer",
      "scheduler timer stop failed during disposal",
      stopped and "timer returned false" or stop_result
    )
  end

  local closing = false
  local checked, is_closing = PCALL(function()
    return timer:is_closing()
  end)
  if checked then
    closing = is_closing and true or false
  else
    record_error(
      state,
      "timer",
      "scheduler timer closing check failed",
      is_closing
    )
  end
  if not closing then
    local closed, close_result = PCALL(function()
      return timer:close()
    end)
    if not closed or RAW_EQUAL(close_result, false) then
      record_error(
        state,
        "timer",
        "scheduler timer close failed",
        closed and "timer returned false" or close_result
      )
      local verified, now_closing = PCALL(function()
        return timer:is_closing()
      end)
      if verified and now_closing then
        closing = true
      elseif not verified then
        record_error(
          state,
          "timer",
          "scheduler timer closing recheck failed",
          now_closing
        )
      end
    else
      closing = true
    end
  end
  if closing then
    RAWSET(state, "timer", nil)
    return finish(true)
  end
  return finish(
    nil,
    RAWGET(state, "last_error")
      or "scheduler timer could not be closed"
  )
end

local function validate_timer_handle(timer)
  local inspected, start, stop, close, is_closing = PCALL(function()
    return timer.start, timer.stop, timer.close, timer.is_closing
  end)
  if not inspected
      or TYPE(start) ~= "function"
      or TYPE(stop) ~= "function"
      or TYPE(close) ~= "function"
      or TYPE(is_closing) ~= "function" then
    if inspected and TYPE(close) == "function" then
      PCALL(close, timer)
    end
    return nil, "scheduler timer handle is invalid"
  end
  return true
end

function Scheduler.create(list, opts)
  local scheduler_options, options_err = options(opts)
  if not scheduler_options then
    return nil, options_err
  end
  local valid, validation_err = PAGE_LIST_VALIDATE(list)
  if not valid then
    return nil,
      "scheduler PageList is invalid: "
        .. safe_diagnostic(validation_err)
  end

  local allocated, timer = PCALL(NEW_TIMER)
  if not allocated then
    return nil, "could not allocate scheduler timer: "
      .. safe_diagnostic(timer)
  end
  if timer == nil then
    return nil, "could not allocate scheduler timer"
  end
  local timer_ok, timer_err = validate_timer_handle(timer)
  if not timer_ok then
    return nil, timer_err
  end

  local self = SETMETATABLE({}, Scheduler)
  local state = {
    list = list,
    timer = timer,
    idle_ms = scheduler_options.idle_ms,
    continuation_ms = scheduler_options.continuation_ms,
    activity_token = 0,
    arm_serial = 0,
    armed = false,
    scheduled = false,
    closing_timer = false,
    disposed = false,
    phase = "idle",
    current_delay_ms = nil,
    scan_generation = nil,
    idle_complete_generation = nil,
    verified_generation = nil,
    cursor = 0,
    verification = false,
    pass_compacted = false,
    pass_deferred = false,
    pending_pinned = false,
    rejected = {},
    rejected_generation = nil,
    fault_rejected = {},
    deferred = {},
    retry_entries = nil,
    retry_cursor = 0,
    cycle_failed = false,
    last_error = nil,
    slices = 0,
    inspections = 0,
    attempts = 0,
    compacted = 0,
    skipped_cold = 0,
    skipped_incomplete = 0,
    skipped_quarantined = 0,
    skipped_capacity = 0,
    skipped_no_benefit = 0,
    skipped_rejected = 0,
    pinned_deferrals = 0,
    contention_deferrals = 0,
    generation_restarts = 0,
    error_count = 0,
    timer_faults = 0,
    schedule_faults = 0,
    compaction_faults = 0,
    source_faults = 0,
  }
  STATES[self] = state
  local armed, arm_err = arm(state, scheduler_options.idle_ms)
  if armed then
    RAWSET(state, "phase", "idle")
  elseif arm_err ~= "scheduler arm was superseded" then
    RAWSET(state, "phase", "fault-retry")
  end
  return self
end

function Scheduler.new(list, opts)
  local scheduler, err = Scheduler.create(list, opts)
  ASSERT(scheduler, err)
  return scheduler
end

function Scheduler:touch()
  local state, state_err = state_for(self)
  if not state then
    return nil, state_err
  end
  if RAWGET(state, "disposed") then
    return nil, "scheduler is disposed"
  end

  local fast_generation
  if RAWGET(state, "phase") == "complete"
      and not RAWGET(state, "cycle_failed")
      and NEXT(RAWGET(state, "fault_rejected")) == nil
      and RAW_EQUAL(
        RAWGET(state, "scan_generation"),
        RAWGET(state, "verified_generation")
      ) then
    fast_generation = RAWGET(state, "verified_generation")
  end

  RAWSET(
    state,
    "activity_token",
    RAWGET(state, "activity_token") + 1
  )
  if fast_generation ~= nil then
    RAWSET(state, "idle_complete_generation", fast_generation)
  else
    RAWSET(state, "idle_complete_generation", nil)
    RAWSET(state, "verified_generation", nil)
    RAWSET(state, "scan_generation", nil)
    RAWSET(state, "verification", false)
    RAWSET(state, "fault_rejected", {})
    reset_pass(state)
  end
  RAWSET(state, "cycle_failed", false)
  local armed, arm_err = arm(state, RAWGET(state, "idle_ms"))
  if not armed then
    if arm_err == "scheduler arm was superseded" then
      return true
    end
    RAWSET(state, "phase", "fault-retry")
    return nil, arm_err
  end
  RAWSET(state, "phase", "idle")
  return true
end

Scheduler.reset_idle = Scheduler.touch

function Scheduler:last_error()
  local state, state_err = state_for(self)
  if not state then
    return nil, state_err
  end
  return RAWGET(state, "last_error")
end

function Scheduler:stats()
  local state, state_err = state_for(self)
  if not state then
    return nil, state_err
  end
  return {
    disposed = RAWGET(state, "disposed"),
    finalized = RAWGET(state, "disposed")
      and RAWGET(state, "timer") == nil,
    armed = RAWGET(state, "armed"),
    scheduled = RAWGET(state, "scheduled"),
    phase = RAWGET(state, "phase"),
    current_delay_ms = RAWGET(state, "current_delay_ms"),
    idle_ms = RAWGET(state, "idle_ms"),
    continuation_ms = RAWGET(state, "continuation_ms"),
    inspection_budget = INSPECTION_BUDGET,
    compaction_budget = COMPACTION_BUDGET,
    activity_token = RAWGET(state, "activity_token"),
    scan_generation = RAWGET(state, "scan_generation"),
    verified_generation = RAWGET(state, "verified_generation"),
    cursor = RAWGET(state, "cursor"),
    verification = RAWGET(state, "verification"),
    pending_pinned = RAWGET(state, "pending_pinned"),
    deferred_pages = RAWGET(state, "retry_entries")
        and #RAWGET(state, "retry_entries")
      or #RAWGET(state, "deferred"),
    retry_cursor = RAWGET(state, "retry_cursor"),
    slices = RAWGET(state, "slices"),
    inspections = RAWGET(state, "inspections"),
    attempts = RAWGET(state, "attempts"),
    compacted = RAWGET(state, "compacted"),
    skipped_cold = RAWGET(state, "skipped_cold"),
    skipped_incomplete = RAWGET(state, "skipped_incomplete"),
    skipped_quarantined = RAWGET(state, "skipped_quarantined"),
    skipped_capacity = RAWGET(state, "skipped_capacity"),
    skipped_no_benefit = RAWGET(state, "skipped_no_benefit"),
    skipped_rejected = RAWGET(state, "skipped_rejected"),
    pinned_deferrals = RAWGET(state, "pinned_deferrals"),
    contention_deferrals = RAWGET(state, "contention_deferrals"),
    generation_restarts = RAWGET(state, "generation_restarts"),
    error_count = RAWGET(state, "error_count"),
    timer_faults = RAWGET(state, "timer_faults"),
    schedule_faults = RAWGET(state, "schedule_faults"),
    compaction_faults = RAWGET(state, "compaction_faults"),
    source_faults = RAWGET(state, "source_faults"),
    last_error = RAWGET(state, "last_error"),
  }
end

local function valid_deferred_entries(entries)
  if TYPE(entries) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(entries), nil) then
    return false
  end
  local count = 0
  for index, entry in NEXT, entries do
    count = count + 1
    if not integer(index)
        or index < 1
        or TYPE(entry) ~= "table"
        or not RAW_EQUAL(RAW_METATABLE(entry), nil)
        or not integer(RAWGET(entry, "page_index"))
        or not integer(RAWGET(entry, "id"))
        or RAWGET(entry, "id") < 1
        or not integer(RAWGET(entry, "revision")) then
      return false
    end
  end
  return count == #entries
end

function Scheduler:validate()
  local state, state_err = state_for(self)
  if not state then
    return nil, state_err
  end
  if not RAW_EQUAL(RAW_METATABLE(self), Scheduler)
      or NEXT(self) ~= nil then
    return nil, "scheduler shell is invalid"
  end
  if not bounded_integer(RAWGET(state, "idle_ms"), MAX_IDLE_MS)
      or not bounded_integer(
        RAWGET(state, "continuation_ms"),
        MAX_CONTINUATION_MS
      )
      or not integer(RAWGET(state, "activity_token"))
      or not integer(RAWGET(state, "arm_serial"))
      or not integer(RAWGET(state, "cursor"))
      or TYPE(RAWGET(state, "armed")) ~= "boolean"
      or TYPE(RAWGET(state, "scheduled")) ~= "boolean"
      or TYPE(RAWGET(state, "closing_timer")) ~= "boolean"
      or RAWGET(state, "armed") and RAWGET(state, "scheduled")
      or TYPE(RAWGET(state, "disposed")) ~= "boolean"
      or TYPE(RAWGET(state, "verification")) ~= "boolean"
      or TYPE(RAWGET(state, "pending_pinned")) ~= "boolean"
      or TYPE(RAWGET(state, "phase")) ~= "string"
      or not RAWGET(PHASES, RAWGET(state, "phase"))
      or TYPE(RAWGET(state, "rejected")) ~= "table"
      or not RAW_EQUAL(RAW_METATABLE(RAWGET(state, "rejected")), nil)
      or TYPE(RAWGET(state, "fault_rejected")) ~= "table"
      or not RAW_EQUAL(
        RAW_METATABLE(RAWGET(state, "fault_rejected")),
        nil
      )
      or not valid_deferred_entries(RAWGET(state, "deferred"))
      or (
        RAWGET(state, "retry_entries") ~= nil
        and not valid_deferred_entries(
          RAWGET(state, "retry_entries")
        )
      )
      or not integer(RAWGET(state, "retry_cursor"))
      or (
        RAWGET(state, "retry_entries") == nil
        and RAWGET(state, "retry_cursor") ~= 0
      )
      or (
        RAWGET(state, "retry_entries") ~= nil
        and (
          RAWGET(state, "retry_cursor") < 1
          or RAWGET(state, "retry_cursor")
            > #RAWGET(state, "retry_entries") + 1
        )
      )
      or (
        RAWGET(state, "scan_generation") ~= nil
        and not integer(RAWGET(state, "scan_generation"))
      )
      or (
        RAWGET(state, "idle_complete_generation") ~= nil
        and not integer(RAWGET(state, "idle_complete_generation"))
      )
      or (
        RAWGET(state, "verified_generation") ~= nil
        and not integer(RAWGET(state, "verified_generation"))
      )
      or (
        RAWGET(state, "rejected_generation") ~= nil
        and not integer(RAWGET(state, "rejected_generation"))
      )
      or (
        RAWGET(state, "current_delay_ms") ~= nil
        and not bounded_integer(
          RAWGET(state, "current_delay_ms"),
          MAX_IDLE_MS
        )
      ) then
    return nil, "scheduler state is invalid"
  end
  for _, field in IPAIRS(COUNTER_FIELDS) do
    if not integer(RAWGET(state, field)) then
      return nil, "scheduler counter is invalid: " .. field
    end
  end
  for _, field in IPAIRS({ "rejected", "fault_rejected" }) do
    for id, revision in NEXT, RAWGET(state, field) do
      if not integer(id) or id < 1 or not integer(revision) then
        return nil, "scheduler rejection memo is invalid"
      end
    end
  end
  local last_error = RAWGET(state, "last_error")
  if last_error ~= nil
      and (
        TYPE(last_error) ~= "string"
        or #last_error > MAX_DIAGNOSTIC_BYTES
      ) then
    return nil, "scheduler diagnostics are invalid"
  end

  if RAWGET(state, "disposed") then
    if RAWGET(state, "list") ~= nil
        or RAWGET(state, "armed")
        or RAWGET(state, "scheduled")
        or RAWGET(state, "phase") ~= "disposed" then
      return nil, "disposed scheduler retained live state"
    end
    if RAWGET(state, "timer") ~= nil then
      return nil,
        RAWGET(state, "last_error")
          or "scheduler disposal is still pending"
    end
    return true
  end
  if RAWGET(state, "timer") == nil
      or RAWGET(state, "list") == nil
      or RAWGET(state, "closing_timer") then
    return nil, "live scheduler lost owned state"
  end
  local valid, validation_err =
    PAGE_LIST_VALIDATE(RAWGET(state, "list"))
  if not valid then
    return nil,
      "scheduler PageList is invalid: "
        .. safe_diagnostic(validation_err)
  end
  return true
end

function Scheduler:dispose()
  local state, state_err = state_for(self)
  if not state then
    return nil, state_err
  end
  if RAWGET(state, "disposed") then
    if RAWGET(state, "timer") == nil then
      return false
    end
    return close_timer(state)
  end

  -- Make every retained callback terminal before invoking hostile handle
  -- methods. No stop/close reentry can resurrect this scheduler.
  RAWSET(state, "disposed", true)
  RAWSET(
    state,
    "activity_token",
    RAWGET(state, "activity_token") + 1
  )
  RAWSET(state, "arm_serial", RAWGET(state, "arm_serial") + 1)
  RAWSET(state, "armed", false)
  RAWSET(state, "scheduled", false)
  RAWSET(state, "phase", "disposed")
  RAWSET(state, "current_delay_ms", nil)
  RAWSET(state, "scan_generation", nil)
  RAWSET(state, "idle_complete_generation", nil)
  RAWSET(state, "verified_generation", nil)
  RAWSET(state, "verification", false)
  reset_pass(state)
  RAWSET(state, "rejected", {})
  RAWSET(state, "rejected_generation", nil)
  RAWSET(state, "fault_rejected", {})
  RAWSET(state, "list", nil)
  return close_timer(state)
end

Scheduler.DEFAULT_IDLE_MS = DEFAULT_IDLE_MS
Scheduler.DEFAULT_CONTINUATION_MS = DEFAULT_CONTINUATION_MS
Scheduler.INSPECTION_BUDGET = INSPECTION_BUDGET
Scheduler.COMPACTION_BUDGET = COMPACTION_BUDGET

return Scheduler
