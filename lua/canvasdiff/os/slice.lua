-- Cooperative time slicing for work too large to run in one main-loop turn.
--
-- Neovim runs Lua on the thread that also reads keys and redraws, so a
-- million-row build done in one call is a freeze of the same length. The work
-- runs in a coroutine instead and reports progress through `pace`; once the
-- current slice has spent its budget, `pace` yields and the work resumes on a
-- later loop turn, with input and redraw processed in between.
--
-- Whether work may yield at all is decided by the units it reports, not by
-- time: below `after_units` it never yields, so small work completes inside
-- `run` exactly as a plain call would, and its caller sees no asynchrony that
-- depends on machine load. The pace call that first crosses the threshold
-- yields unconditionally, which makes "large work completes later" just as
-- deterministic.

local S = {}

-- Raised through the work by `pace` after `cancel`, so an abandoned build
-- unwinds at its next checkpoint instead of running to completion unseen.
S.CANCELLED = "canvasdiff: sliced work cancelled"

--- True when `err` is the cancellation `on_done` reports, as opposed to a
--- failure of the work itself.
function S.cancelled(err)
  return err == S.CANCELLED
end

local hrtime = vim.uv.hrtime
local yield = coroutine.yield
local running = coroutine.running

local DEFAULT_BUDGET_MS = 12

local function pack(...)
  return { n = select("#", ...), ... }
end

local Handle = {}
Handle.__index = Handle

--- True until `on_done` has been called.
function Handle:pending()
  return not self.finished
end

--- Abandon the work. It stops at its next `pace` and `on_done` receives
--- (false, S.CANCELLED); a no-op once finished. Work cancelled from inside
--- itself (reentrant code during a blocking call) after its last checkpoint
--- still completes normally, so an owner that cancels keeps its own
--- staleness check rather than trusting `ok` alone.
function Handle:cancel()
  if self.finished or self.cancelled then
    return
  end
  -- A suspended task always has its next step queued; that step resumes into
  -- `pace`, which raises CANCELLED.
  self.cancelled = true
end

--- Run `work(pace)` in time slices.
---
--- `pace(units)` is the work's checkpoint: call it from inside loops with the
--- units done since the last call. It is a no-op when called from any other
--- coroutine, so a pacer handed through a nested runner cannot yield the
--- wrong one.
---
--- `on_done(ok, ...)` runs exactly once, on the main loop and never in a fast
--- context: `true` plus the work's return values, `false, S.CANCELLED` after
--- `cancel`, or `false` plus a traceback when the work raised. When the work
--- never yields it runs before `run` returns.
--- @param work fun(pace: fun(units: integer|nil)): ...
--- @param opts { budget_ms: integer|nil, after_units: integer|nil }|nil
--- @param on_done fun(ok: boolean, ...)
--- @return table handle { pending(), cancel() }
function S.run(work, opts, on_done)
  opts = opts or {}
  local budget = (opts.budget_ms or DEFAULT_BUDGET_MS) * 1e6
  local after_units = opts.after_units or 0
  local handle = setmetatable({
    finished = false,
    cancelled = false,
  }, Handle)

  local units = 0
  local deadline = 0
  local co

  local function pace(n)
    if running() ~= co then
      return
    end
    if handle.cancelled then
      error(S.CANCELLED, 0)
    end
    local before = units
    units = units + (n or 0)
    if units < after_units then
      return
    end
    if before < after_units or hrtime() >= deadline then
      yield()
      if handle.cancelled then
        error(S.CANCELLED, 0)
      end
    end
  end

  co = coroutine.create(function()
    return xpcall(work, function(err)
      if err == S.CANCELLED then
        return err
      end
      return debug.traceback(err, 2)
    end, pace)
  end)

  local function finish(...)
    handle.finished = true
    on_done(...)
  end

  function handle.step()
    if handle.finished then
      return
    end
    deadline = hrtime() + budget
    local results = pack(coroutine.resume(co))
    if coroutine.status(co) ~= "dead" then
      -- Through a libuv timer, not vim.schedule. A step that reschedules
      -- itself with vim.schedule lands in the queue being drained, so every
      -- slice ran in one drain and libuv never polled between them: timers
      -- and keyboard input waited for the whole build (measured: a 335 ms
      -- freeze in a "sliced" million-row open; test_slice guards it).
      vim.defer_fn(handle.step, 0)
      return
    end
    if not results[1] then
      -- resume itself failed: the work body is a protected call, so this is
      -- a bug in this module rather than in the work.
      return finish(false, results[2])
    end
    return finish(unpack(results, 2, results.n))
  end

  handle.step()
  return handle
end

return S
