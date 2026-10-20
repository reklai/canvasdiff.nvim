local H = require("helpers")
local system = require("canvasdiff.os")

local T = {}

local function busy(ms)
  local stop = vim.uv.hrtime() + ms * 1e6
  while vim.uv.hrtime() < stop do end
end

local function settle(handle)
  assert(vim.wait(5000, function() return not handle:pending() end, 1),
    "sliced work never finished")
end

T["slice_ work below its threshold completes inside the call, nils intact"] = function()
  local done
  local handle = system.sliced(function(pace)
    pace(10)
    pace(10)
    return "a", nil, "c", nil
  end, { after_units = 100, budget_ms = 0 }, function(...)
    done = { n = select("#", ...), ... }
  end)
  assert(done, "small work must not wait for the event loop")
  H.eq(handle:pending(), false)
  H.eq(done.n, 5, "every return value survives, trailing nils included")
  H.eq({ done[1], done[2], done[3], done[4], done[5] }, { true, "a", nil, "c", nil })
end

T["slice_ crossing the threshold always yields, then finishes"] = function()
  local done
  local handle = system.sliced(function(pace)
    pace(99)
    pace(1)
    return 42
  end, { after_units = 100, budget_ms = 10000 }, function(ok, value)
    done = { ok, value }
  end)
  H.eq(done, nil, "work that reached the threshold must finish later, whatever the clock says")
  settle(handle)
  H.eq(done, { true, 42 })
end

T["slice_ cancel stops the work at its next checkpoint"] = function()
  local done, after_cancel = nil, false
  local handle = system.sliced(function(pace)
    pace(1)
    after_cancel = true
    return "finished"
  end, { after_units = 1 }, function(ok, err)
    done = { ok, err }
  end)
  handle:cancel()
  settle(handle)
  H.eq(after_cancel, false, "nothing after the checkpoint may run")
  H.eq(done[1], false)
  assert(system.slice_cancelled(done[2]), tostring(done[2]))
end

T["slice_ an error reaches on_done with its traceback"] = function()
  local done
  local handle = system.sliced(function(pace)
    pace(1)
    error("broken work")
  end, { after_units = 1 }, function(ok, err)
    done = { ok, err }
  end)
  settle(handle)
  H.eq(done[1], false)
  assert(not system.slice_cancelled(done[2]))
  assert(tostring(done[2]):find("broken work", 1, true), tostring(done[2]))
  assert(tostring(done[2]):find("stack traceback", 1, true),
    "the traceback is the only evidence of where sliced work failed")
end

T["slice_ a pacer called from another coroutine is a no-op"] = function()
  local inner_done
  local handle = system.sliced(function(pace)
    local inner = coroutine.wrap(function()
      pace(1000)
      return "inner ran through"
    end)
    inner_done = inner()
    return true
  end, { after_units = 1, budget_ms = 0 }, function() end)
  settle(handle)
  H.eq(inner_done, "inner ran through",
    "yielding the wrong coroutine would hand its caller a bare yield")
end

-- The regression this guards: resuming with vim.schedule chains every slice
-- into one drain of the event queue, so libuv never polled between them --
-- timers (and with them keyboard input) waited for the whole build, and a
-- "sliced" million-row open still froze for ~335 ms. A timer that fires
-- between slices is the observable difference.
T["slice_ libuv timers run between slices"] = function()
  local ticks = 0
  local timer = assert(vim.uv.new_timer())
  timer:start(1, 1, function()
    ticks = ticks + 1
  end)
  local ticks_during
  local handle = system.sliced(function(pace)
    for _ = 1, 20 do
      busy(2)
      pace(1)
    end
    ticks_during = ticks
  end, { after_units = 1, budget_ms = 1 }, function() end)
  settle(handle)
  timer:stop()
  timer:close()
  assert(ticks_during >= 5, ("a 1 ms timer fired %d times across ~40 ms of sliced work")
    :format(ticks_during))
end

return T
