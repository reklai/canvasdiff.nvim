local H = require("helpers")
local PageList = require("canvasdiff.canvas.PageList")
local system = require("canvasdiff.os")

local T = {}

local MODULE = "canvasdiff.canvas.Scheduler"

local function fake_environment()
  local env = {
    timers = {},
    scheduled = {},
    next_start = 1,
    next_scheduled = 1,
    schedule_fault = false,
    allocate_fault = false,
    allocate_nil = false,
    allocate_value = nil,
    start_fault = false,
    start_return_false = false,
    start_callback_once = false,
    stop_fault = false,
    stop_return_false = false,
    close_fault = false,
    close_fault_before = false,
    close_return_false = false,
    schedule_immediate = false,
    schedule_return_false = false,
  }

  function env.new_timer()
    if env.allocate_fault then
      error(env.allocate_fault)
    end
    if env.allocate_nil then
      return nil
    end
    if env.allocate_value ~= nil then
      return env.allocate_value
    end
    local timer = {
      starts = {},
      stop_calls = 0,
      close_calls = 0,
      closed = false,
    }
    function timer:start(timeout, repeat_ms, callback)
      if env.start_fault then
        error(env.start_fault)
      end
      self.starts[#self.starts + 1] = {
        timeout = timeout,
        repeat_ms = repeat_ms,
        callback = callback,
      }
      if env.start_callback_once then
        env.start_callback_once = false
        callback()
      end
      if env.start_return_false then
        return false
      end
      return true
    end
    function timer:stop()
      self.stop_calls = self.stop_calls + 1
      if self.on_stop then
        local callback = self.on_stop
        self.on_stop = nil
        callback()
      end
      if env.stop_fault then
        error(env.stop_fault)
      end
      if env.stop_return_false then
        return false
      end
      return true
    end
    function timer:is_closing()
      return self.closed
    end
    function timer:close()
      self.close_calls = self.close_calls + 1
      if self.on_close then
        local callback = self.on_close
        self.on_close = nil
        callback()
      end
      if env.close_fault_before then
        error(env.close_fault_before)
      end
      self.closed = true
      if env.close_fault then
        error(env.close_fault)
      end
      if env.close_return_false then
        return false
      end
      return true
    end
    env.timers[#env.timers + 1] = timer
    return timer
  end

  function env.schedule(callback)
    if env.schedule_fault then
      error(env.schedule_fault)
    end
    if env.schedule_return_false then
      return false
    end
    if env.schedule_immediate then
      callback()
      return
    end
    env.scheduled[#env.scheduled + 1] = callback
  end

  function env:timer()
    return assert(self.timers[1], "scheduler did not allocate a timer")
  end

  function env:fire_next()
    local start = self:timer().starts[self.next_start]
    assert(start, "scheduler did not arm the next timer")
    self.next_start = self.next_start + 1
    start.callback()
    return start
  end

  function env:drain_next()
    local callback = self.scheduled[self.next_scheduled]
    assert(callback, "timer did not enqueue a scheduled callback")
    self.next_scheduled = self.next_scheduled + 1
    callback()
  end

  function env:step()
    local start = self:fire_next()
    self:drain_next()
    return start
  end

  return env
end

local function with_scheduler(callback)
  local old_new_timer = system.new_timer
  local old_schedule = vim.schedule
  local env = fake_environment()
  system.new_timer = env.new_timer
  vim.schedule = env.schedule
  package.loaded[MODULE] = nil
  local loaded, Scheduler = pcall(require, MODULE)

  local ok, err
  if loaded then
    ok, err = xpcall(function()
      callback(Scheduler, env)
    end, debug.traceback)
  else
    ok, err = false, Scheduler
  end

  system.new_timer = old_new_timer
  vim.schedule = old_schedule
  package.loaded[MODULE] = nil
  assert(ok, err)
end

local function adapter(spec)
  spec = spec or {}
  return {
    codec = "scheduler-test-v1",
    encode = spec.encode or function()
      return "\1"
    end,
    decode = spec.decode or function()
      return nil
    end,
    crc32 = spec.crc32 or function()
      return 7
    end,
  }
end

local function rows(count, prefix)
  local result = {}
  for index = 1, count do
    result[index] =
      (prefix or "compressible-row-") .. index .. string.rep("x", 24)
  end
  return result
end

local function list_with_adapter(count, spec)
  spec = spec or {}
  return PageList.new(rows(count, spec.prefix), {
    max_rows = 1,
    resident = {
      max_pages = spec.max_pages == nil and 8 or spec.max_pages,
      max_bytes = spec.max_bytes == nil and 1024 or spec.max_bytes,
      restore = spec.restore or adapter(spec),
    },
  })
end

local function drive_to_complete(scheduler, env, limit)
  limit = limit or 100
  for _ = 1, limit do
    local before = assert(scheduler:stats())
    if before.phase == "complete" then
      return
    end
    assert(before.armed, "an incomplete scheduler must own a pending timer")
    env:step()
    local after = assert(scheduler:stats())
    assert(after.inspections - before.inspections <= 8,
      "one slice inspected more than eight snapshots")
    assert(after.attempts - before.attempts <= 1,
      "one slice attempted more than one compaction")
  end
  error("scheduler did not complete within the deterministic step limit")
end

T["scheduler_ owns private state and touch resets the exact 250ms idle token"] =
  function()
    with_scheduler(function(Scheduler, env)
      local list = PageList.new({})
      local scheduler = assert(Scheduler.create(list))
      local timer = env:timer()

      H.eq(timer.starts[1].timeout, 250)
      H.eq(timer.starts[1].repeat_ms, 0)
      H.eq(scheduler:stats().idle_ms, 250)
      H.eq(scheduler:stats().continuation_ms, 1)
      H.eq(scheduler:stats().inspection_budget, 8)
      H.eq(scheduler:stats().compaction_budget, 1)
      H.eq(Scheduler.DEFAULT_IDLE_MS, 250)
      H.eq(Scheduler.DEFAULT_CONTINUATION_MS, 1)
      H.eq(Scheduler.INSPECTION_BUDGET, 8)
      H.eq(Scheduler.COMPACTION_BUDGET, 1)
      H.eq(scheduler:validate(), true)

      local stale_timer = timer.starts[1].callback
      H.eq(scheduler:touch(), true)
      H.eq(timer.starts[2].timeout, 250)
      H.eq(scheduler:stats().activity_token, 1)
      stale_timer()
      H.eq(#env.scheduled, 0,
        "a pre-touch timer callback cannot cross the first async fence")

      timer.starts[2].callback()
      H.eq(#env.scheduled, 1)
      local stale_scheduled = env.scheduled[1]
      H.eq(scheduler:reset_idle(), true)
      H.eq(timer.starts[3].timeout, 250)
      stale_scheduled()
      H.eq(scheduler:stats().slices, 0,
        "a pre-touch scheduled callback cannot cross the second fence")

      local detached = scheduler:stats()
      detached.phase = "forged"
      H.eq(scheduler:stats().phase, "idle")
      scheduler.evil = true
      H.eq(scheduler:validate(), nil)
      scheduler.evil = nil
      H.eq(scheduler:validate(), true)

      H.eq(scheduler:dispose(), true)
      H.eq(scheduler:dispose(), false)
      H.eq(scheduler:touch(), nil)
      H.eq(scheduler:validate(), true)
    end)
  end

T["scheduler_ each 1ms slice respects hard budgets and ends after verification"] =
  function()
    with_scheduler(function(Scheduler, env)
      local list = list_with_adapter(10)
      local scheduler = Scheduler.new(list)
      local timer = env:timer()
      H.eq(timer.starts[1].timeout, 250)

      drive_to_complete(scheduler, env)
      local stats = scheduler:stats()
      H.eq(stats.compacted, 9)
      H.eq(stats.attempts, 9)
      H.eq(stats.inspections, 20,
        "nine compacting slices plus complete scan and verification passes")
      H.eq(stats.skipped_incomplete, 2,
        "the live tail stays raw in both complete traversals")
      H.eq(stats.phase, "complete")
      H.eq(stats.armed, false)
      H.eq(stats.verification, true)
      H.eq(stats.last_error, nil)
      for index = 2, #timer.starts do
        H.eq(timer.starts[index].timeout, 1,
          "ordinary pending work must resume after exactly 1ms")
      end
      for page_index0 = 0, list:page_count() - 2 do
        H.eq(assert(list:inspect_page(page_index0)).kind, "cold")
      end
      H.eq(assert(list:inspect_page(list:page_count() - 1)).kind, "raw")
      H.eq(scheduler:validate(), true)
      scheduler:dispose()
    end)
  end

T["scheduler_ synchronous start and schedule reentry cannot overwrite its winner"] =
  function()
    with_scheduler(function(Scheduler, env)
      env.start_callback_once = true
      env.schedule_immediate = true
      local scheduler = Scheduler.new(PageList.new({}))
      local stats = scheduler:stats()
      H.eq(stats.slices, 1,
        "the deliberately synchronous first callback ran one slice")
      H.eq(stats.phase, "verification",
        "the superseded outer create arm cannot rewrite the inner phase")
      H.eq(stats.armed, true)
      H.eq(stats.current_delay_ms, 1)
      H.eq(#env:timer().starts, 2)
      H.eq(env:timer().starts[2].timeout, 1)
      H.eq(scheduler:validate(), true)
      scheduler:dispose()
    end)
  end

T["scheduler_ completed one-shot timer callback cannot fire twice"] =
  function()
    with_scheduler(function(Scheduler, env)
      local scheduler = Scheduler.new(PageList.new({}))

      env:step()
      local completed_timer = env:timer().starts[2].callback
      env:step()
      local complete = scheduler:stats()
      H.eq(complete.phase, "complete")
      H.eq(complete.armed, false)
      H.eq(complete.scheduled, false)

      completed_timer()
      H.eq(#env.scheduled, 2,
        "duplicate delivery cannot enqueue another scheduled callback")
      H.eq(scheduler:stats().slices, complete.slices,
        "duplicate delivery cannot enter another scheduler slice")
      scheduler:dispose()
    end)
  end

T["scheduler_ codec reentry cannot cross the active slice identity"] =
  function()
    with_scheduler(function(Scheduler, env)
      local scheduler
      local touched
      local list = list_with_adapter(2, {
        encode = function()
          touched = { scheduler:touch() }
          return "\1"
        end,
      })
      scheduler = Scheduler.new(list)
      env:step()

      H.eq(touched[1], true)
      local stats = scheduler:stats()
      H.eq(stats.phase, "idle")
      H.eq(stats.armed, true)
      H.eq(stats.current_delay_ms, 250)
      H.eq(stats.attempts, 0)
      H.eq(stats.compacted, 0)
      H.eq(stats.source_faults, 0)
      H.eq(#env:timer().starts, 2)
      H.eq(env:timer().starts[2].timeout, 250)
      H.eq(assert(list:inspect_page(0)).kind, "cold")
      scheduler:dispose()
    end)

    with_scheduler(function(Scheduler, env)
      local scheduler
      local disposed
      local list = list_with_adapter(2, {
        encode = function()
          disposed = { scheduler:dispose() }
          return "\1"
        end,
      })
      scheduler = Scheduler.new(list)
      env:step()

      H.eq(disposed[1], true)
      local stats = scheduler:stats()
      H.eq(stats.disposed, true)
      H.eq(stats.finalized, true)
      H.eq(stats.phase, "disposed")
      H.eq(stats.attempts, 0)
      H.eq(stats.source_faults, 0)
      H.eq(#env:timer().starts, 1)
      H.eq(env:timer().close_calls, 1)
      H.eq(scheduler:validate(), true)
    end)
  end

T["scheduler_ memoizes no-benefit pages and preflights impossible capacity"] =
  function()
    with_scheduler(function(Scheduler, env)
      local encode_calls = 0
      local no_benefit = list_with_adapter(4, {
        encode = function(body)
          encode_calls = encode_calls + 1
          return body
        end,
      })
      local scheduler = Scheduler.new(no_benefit)
      drive_to_complete(scheduler, env)
      local stats = scheduler:stats()
      H.eq(stats.attempts, 3)
      H.eq(stats.skipped_no_benefit, 3)
      H.eq(stats.skipped_rejected, 3)
      H.eq(stats.skipped_incomplete, 2)
      H.eq(encode_calls, 3,
        "verification must not retry an exact rejected revision")
      local settled_inspections = stats.inspections
      env.start_callback_once = true
      env.schedule_immediate = true
      H.eq(scheduler:touch(), true)
      H.eq(scheduler:stats().phase, "complete",
        "a synchronous fast-path callback remains the outer arm winner")
      drive_to_complete(scheduler, env)
      H.eq(encode_calls, 3,
        "activity cannot re-encode unchanged no-benefit revisions")
      H.eq(scheduler:stats().attempts, 3)
      H.eq(scheduler:stats().inspections, settled_inspections,
        "a verified unchanged generation needs no page rescan")
      scheduler:dispose()
    end)

    with_scheduler(function(Scheduler, env)
      local encode_calls = 0
      local impossible = list_with_adapter(11, {
        max_pages = 0,
        encode = function()
          encode_calls = encode_calls + 1
          return "\1"
        end,
      })
      local scheduler = Scheduler.new(impossible)
      drive_to_complete(scheduler, env)
      local stats = scheduler:stats()
      H.eq(stats.attempts, 0)
      H.eq(stats.skipped_capacity, 10)
      H.eq(stats.skipped_rejected, 10)
      H.eq(stats.skipped_incomplete, 2)
      H.eq(encode_calls, 0,
        "capacity-impossible pages must be skipped before the codec")
      scheduler:dispose()
    end)
  end

T["scheduler_ skips quarantined cold revisions without invoking compaction"] =
  function()
    with_scheduler(function(Scheduler, env)
      local list = list_with_adapter(2, {
        decode = function()
          return nil
        end,
      })
      H.eq(list:compact_page(0, 0), true)
      H.eq(list:row(0), nil)
      H.eq(assert(list:inspect_page(0)).quarantined, true)

      local scheduler = Scheduler.new(list)
      drive_to_complete(scheduler, env)
      local stats = scheduler:stats()
      H.eq(stats.attempts, 0)
      H.eq(stats.skipped_quarantined, 2,
        "initial and verification passes both observe quarantine")
      H.eq(stats.skipped_incomplete, 2)
      scheduler:dispose()
    end)
  end

T["scheduler_ generation changes restart and retire prior rejects"] =
  function()
    with_scheduler(function(Scheduler, env)
      local encode_calls = 0
      local list = list_with_adapter(12, {
        encode = function(body)
          encode_calls = encode_calls + 1
          return body
        end,
      })
      local scheduler = Scheduler.new(list)

      env:step()
      H.eq(scheduler:stats().cursor, 1)
      H.eq(scheduler:stats().scan_generation, 0)
      H.eq(encode_calls, 1)

      H.eq(list:splice(list:row_count(), 0, {
        "new-generation-row" .. string.rep("n", 24),
      }), true)
      H.eq(list:generation(), 1)
      env:step()
      local restarted = scheduler:stats()
      H.eq(restarted.generation_restarts, 1)
      H.eq(restarted.scan_generation, 1)
      H.eq(restarted.cursor, 1,
        "the changed generation is traversed again from page zero")
      H.eq(restarted.skipped_rejected, 0)
      H.eq(encode_calls, 2,
        "a structural generation retires the prior rejection memo")

      drive_to_complete(scheduler, env)
      H.eq(scheduler:stats().scan_generation, 1)
      H.eq(scheduler:validate(), true)
      scheduler:dispose()
    end)
  end

T["scheduler_ pinned raw pages retry after idle without a continuation spin"] =
  function()
    with_scheduler(function(Scheduler, env)
      local list = list_with_adapter(3)
      local lease = assert(list:pin_range(0, 1, 0))
      local scheduler = Scheduler.new(list)
      local timer = env:timer()

      env:step()
      H.eq(scheduler:stats().phase, "continuation")
      H.eq(timer.starts[#timer.starts].timeout, 1,
        "the untouched tail still requires one bounded scan continuation")
      env:step()
      local first = scheduler:stats()
      H.eq(first.compacted, 1)
      H.eq(first.pinned_deferrals, 1)
      H.eq(first.pending_pinned, true)
      H.eq(first.phase, "pinned-retry")
      H.eq(timer.starts[#timer.starts].timeout, 250,
        "a complete pass with pinned work must not spin at 1ms")

      env:step()
      local still_pinned = scheduler:stats()
      H.eq(still_pinned.pending_pinned, true)
      H.eq(timer.starts[#timer.starts].timeout, 250,
        "a persistently pinned page remains on an idle retry cadence")

      H.eq(list:release_pin(lease), true)
      env:step()
      H.eq(scheduler:stats().compacted, 2)
      H.eq(timer.starts[#timer.starts].timeout, 1,
        "successful retry returns to bounded continuation work")
      drive_to_complete(scheduler, env)
      H.eq(scheduler:stats().pending_pinned, false)
      scheduler:dispose()
    end)
  end

T["scheduler_ persistent pin retries only the deferred page at scale"] =
  function()
    with_scheduler(function(Scheduler, env)
      local list = list_with_adapter(129)
      local pinned_index0 = 64
      for page_index0 = 0, list:page_count() - 2 do
        if page_index0 ~= pinned_index0 then
          H.eq(list:compact_page(page_index0, 0), true)
        end
      end
      local lease = assert(list:pin_range(pinned_index0, 1, 0))
      local scheduler = Scheduler.new(list)
      local timer = env:timer()

      for _ = 1, 30 do
        env:step()
        if scheduler:stats().phase == "pinned-retry" then
          break
        end
      end
      local scanned = scheduler:stats()
      H.eq(scanned.phase, "pinned-retry")
      H.eq(scanned.inspections, 129)
      H.eq(scanned.deferred_pages, 1)
      H.eq(timer.starts[#timer.starts].timeout, 250)

      local starts_before = #timer.starts
      local inspections_before = scanned.inspections
      env:step()
      local retried = scheduler:stats()
      H.eq(retried.inspections, inspections_before + 1)
      H.eq(retried.deferred_pages, 1)
      H.eq(#timer.starts, starts_before + 1,
        "one persistent pin must arm one idle retry, not a full scan")
      H.eq(timer.starts[#timer.starts].timeout, 250)

      H.eq(list:release_pin(lease), true)
      env:step()
      H.eq(scheduler:stats().compacted, 1)
      H.eq(timer.starts[#timer.starts].timeout, 1)
      drive_to_complete(scheduler, env, 30)
      H.eq(assert(list:inspect_page(pinned_index0)).kind, "cold")
      H.eq(
        assert(list:inspect_page(list:page_count() - 1)).kind,
        "raw"
      )
      scheduler:dispose()
    end)
  end

T["scheduler_ timer and scheduling faults are bounded and recoverable"] =
  function()
    with_scheduler(function(Scheduler, env)
      env.allocate_fault = "allocate-fault"
      local scheduler, err = Scheduler.create(PageList.new({}))
      H.eq(scheduler, nil)
      assert(err:find("allocate-fault", 1, true), err)
    end)

    with_scheduler(function(Scheduler, env)
      env.allocate_nil = true
      local scheduler, err = Scheduler.create(PageList.new({}))
      H.eq(scheduler, nil)
      assert(err:find("allocate scheduler timer", 1, true), err)
    end)

    with_scheduler(function(Scheduler, env)
      env.allocate_value = {}
      local scheduler, err = Scheduler.create(PageList.new({}))
      H.eq(scheduler, nil)
      assert(err:find("timer handle is invalid", 1, true), err)
    end)

    with_scheduler(function(Scheduler, env)
      env.start_fault = string.rep("timer-start-fault", 100)
      local scheduler = assert(Scheduler.create(PageList.new({})))
      H.eq(scheduler:stats().armed, false)
      H.eq(scheduler:stats().timer_faults, 1)
      assert(#scheduler:last_error() <= 512)

      env.start_fault = false
      env.start_return_false = true
      H.eq(scheduler:touch(), nil)
      H.eq(scheduler:stats().armed, false)
      H.eq(scheduler:stats().timer_faults, 2)
      env.start_return_false = false
      H.eq(scheduler:touch(), true)
      H.eq(scheduler:stats().armed, true)
      env.stop_return_false = true
      H.eq(scheduler:touch(), true,
        "an explicit false stop is diagnosed but the new identity may arm")
      env.stop_return_false = false
      assert(scheduler:stats().timer_faults >= 3)
      env.schedule_fault = string.rep("schedule-fault", 100)
      env.next_start = #env:timer().starts
      env:fire_next()
      local faulted = scheduler:stats()
      H.eq(faulted.schedule_faults, 1)
      H.eq(faulted.phase, "fault-retry")
      H.eq(faulted.armed, true)
      H.eq(env:timer().starts[#env:timer().starts].timeout, 250)
      assert(#scheduler:last_error() <= 512)

      env.schedule_fault = false
      env.schedule_return_false = true
      env:fire_next()
      local false_return = scheduler:stats()
      H.eq(false_return.schedule_faults, 2)
      H.eq(false_return.scheduled, false)
      H.eq(false_return.phase, "fault-retry")
      H.eq(false_return.armed, true)
      H.eq(env:timer().starts[#env:timer().starts].timeout, 250)

      env.schedule_return_false = false
      env:fire_next()
      env:drain_next()
      H.eq(scheduler:stats().slices, 1)

      env.stop_fault = string.rep("timer-stop-fault", 100)
      env.close_fault = string.rep("timer-close-fault", 100)
      H.eq(scheduler:dispose(), true)
      local disposed = scheduler:stats()
      H.eq(disposed.disposed, true)
      assert(disposed.timer_faults >= 3)
      assert(#scheduler:last_error() <= 512)
      H.eq(scheduler:validate(), true)
    end)

    with_scheduler(function(Scheduler, env)
      local scheduler = Scheduler.new(PageList.new({}))
      local timer = env:timer()
      local nested_close
      timer.on_close = function()
        nested_close = { scheduler:dispose() }
      end
      env.close_fault_before = string.rep("pre-close-fault", 100)
      local disposed, dispose_err = scheduler:dispose()
      H.eq(disposed, nil)
      assert(dispose_err:find("pre-close-fault", 1, true),
        dispose_err)
      H.eq(nested_close[1], nil)
      assert(nested_close[2]:find("already active", 1, true),
        nested_close[2])
      H.eq(timer.close_calls, 1)
      H.eq(scheduler:stats().disposed, true)
      H.eq(scheduler:stats().finalized, false)
      H.eq(scheduler:touch(), nil,
        "a pending close cannot reactivate the terminal scheduler")
      H.eq(scheduler:validate(), nil,
        "validation reports the deliberately pending resource")

      env.close_fault_before = false
      H.eq(scheduler:dispose(), true,
        "a later terminal dispose retries the exact retained handle")
      H.eq(timer.close_calls, 2)
      H.eq(scheduler:stats().finalized, true)
      H.eq(scheduler:validate(), true)
      H.eq(scheduler:dispose(), false)
    end)
  end

T["scheduler_ codec faults stay contained and a clean touched cycle recovers"] =
  function()
    with_scheduler(function(Scheduler, env)
      local fault = true
      local encode_calls = 0
      local list = list_with_adapter(2, {
        encode = function()
          encode_calls = encode_calls + 1
          if fault then
            error(string.rep("injected-codec-fault", 100))
          end
          return "\1"
        end,
      })
      local scheduler = Scheduler.new(list)
      drive_to_complete(scheduler, env)
      local failed = scheduler:stats()
      H.eq(failed.compaction_faults, 1)
      H.eq(failed.attempts, 1)
      H.eq(encode_calls, 1)
      assert(failed.last_error:find("compaction failed", 1, true),
        failed.last_error)
      assert(#failed.last_error <= 512)
      H.eq(assert(list:inspect_page(0)).kind, "raw")

      fault = false
      H.eq(scheduler:touch(), true)
      drive_to_complete(scheduler, env)
      local recovered = scheduler:stats()
      H.eq(recovered.compacted, 1)
      H.eq(encode_calls, 2)
      H.eq(recovered.last_error, nil,
        "one clean touched cycle clears the prior bounded diagnostic")
      H.eq(assert(list:inspect_page(0)).kind, "cold")
      scheduler:dispose()
    end)
  end

T["scheduler_ dispose is terminal across timer scheduled and handle reentry"] =
  function()
    with_scheduler(function(Scheduler, env)
      local list = list_with_adapter(1)
      local scheduler = Scheduler.new(list)
      local timer = env:timer()
      local stale_timer = timer.starts[1].callback
      stale_timer()
      H.eq(#env.scheduled, 1)
      local stale_scheduled = env.scheduled[1]

      local reentrant_result
      local nested_dispose
      timer.on_stop = function()
        reentrant_result = { scheduler:touch() }
        nested_dispose = { scheduler:dispose() }
        stale_timer()
      end
      H.eq(scheduler:dispose(), true)
      H.eq(reentrant_result[1], nil)
      assert(reentrant_result[2]:find("disposed", 1, true),
        reentrant_result[2])
      H.eq(nested_dispose[1], nil)
      assert(nested_dispose[2]:find("already active", 1, true),
        nested_dispose[2])
      H.eq(timer.close_calls, 1)
      H.eq(timer.closed, true)

      stale_scheduled()
      stale_timer()
      H.eq(scheduler:stats().slices, 0)
      H.eq(scheduler:stats().attempts, 0)
      H.eq(assert(list:inspect_page(0)).kind, "raw")
      H.eq(scheduler:stats().disposed, true)
      H.eq(scheduler:validate(), true)
    end)
  end

T["scheduler_ timing overrides are bounded and options are raw-read"] =
  function()
    with_scheduler(function(Scheduler, env)
      local index_reads = 0
      local opts = setmetatable({
        idle_ms = 17,
        continuation_ms = 3,
      }, {
        __index = function()
          index_reads = index_reads + 1
          error("options must be raw-read")
        end,
      })
      local scheduler = Scheduler.new(PageList.new({}), opts)
      H.eq(env:timer().starts[1].timeout, 17)
      H.eq(scheduler:stats().continuation_ms, 3)
      H.eq(index_reads, 0)
      env:step()
      H.eq(env:timer().starts[2].timeout, 3)
      drive_to_complete(scheduler, env)
      scheduler:dispose()
    end)

    with_scheduler(function(Scheduler)
      for _, case in ipairs({
        { { idle_ms = -1 }, "idle_ms" },
        { { idle_ms = 60001 }, "idle_ms" },
        { { idle_ms = 0.5 }, "idle_ms" },
        { { continuation_ms = -1 }, "continuation_ms" },
        { { continuation_ms = 1001 }, "continuation_ms" },
        { { continuation_ms = 0 / 0 }, "continuation_ms" },
      }) do
        local scheduler, err =
          Scheduler.create(PageList.new({}), case[1])
        H.eq(scheduler, nil)
        assert(err:find(case[2], 1, true), err)
      end
      H.eq(Scheduler.create(PageList.new({}), "bad"), nil)
      H.eq(Scheduler.create({}), nil)
    end)
  end

return T
