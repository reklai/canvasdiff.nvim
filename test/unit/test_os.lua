local H = require("helpers")
local system = require("canvasdiff.os")

local T = {}

T["os_ facade exports exactly the raw effect operations"] = function()
  local names = vim.tbl_keys(system)
  table.sort(names)
  H.eq(names, {
    "new_fs_event",
    "new_timer",
    "read_file",
    "run",
    "write_file",
  })
  for _, name in ipairs(names) do
    H.eq(type(system[name]), "function", name .. " is callable")
  end
end

T["os_ process and handle factories preserve exact adapter results"] = function()
  local real_system = vim.system
  local real_new_timer = vim.uv.new_timer
  local real_new_fs_event = vim.uv.new_fs_event
  local process_result = {}
  local timer = {}
  local event = {}
  local waited = 0

  vim.system = function(command, opts)
    H.eq(command, { "example", "--flag" })
    -- The caller's fields pass through untouched; the adapter's only
    -- addition is the default process bound (see the bounded-run tests).
    H.eq(opts, { text = false, timeout = 60000 })
    return {
      wait = function()
        waited = waited + 1
        return process_result
      end,
    }
  end
  vim.uv.new_timer = function() return timer end
  vim.uv.new_fs_event = function() return event end

  local ok, err = xpcall(function()
    assert(rawequal(system.run({ "example", "--flag" }, { text = false }), process_result),
      "process completion result must pass through unchanged")
    assert(rawequal(system.new_timer(), timer),
      "the timer factory must return the exact owned handle")
    assert(rawequal(system.new_fs_event(), event),
      "the filesystem factory must return the exact owned handle")
    H.eq(waited, 1)
  end, debug.traceback)

  vim.system = real_system
  vim.uv.new_timer = real_new_timer
  vim.uv.new_fs_event = real_new_fs_event
  assert(ok, err)
end

-- Every process run is bounded. All of the plugin's Git calls are local, but
-- local is not the same as prompt: an LFS smudge filter, an fsmonitor, or a
-- post-checkout hook can stall on the network, and `vim.system():wait()` with
-- no bound freezes the whole UI until the child exits -- potentially never.
T["os_ process runs are bounded: a hung child cannot freeze the loop"] = function()
  local started = vim.uv.hrtime()
  local result = system.run({ "sleep", "600" }, { timeout = 200 })
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  assert(elapsed_ms < 5000,
    ("a 200ms bound must not take %.0fms to enforce"):format(elapsed_ms))
  assert(result.code ~= 0, "a killed child must not report success")
  assert(tostring(result.stderr):find("timed out", 1, true),
    "the timeout must be readable in stderr, not just a bare exit code: "
      .. vim.inspect(result))
end

T["os_ process runs carry a default bound without mutating caller opts"] = function()
  local real_system = vim.system
  local seen
  vim.system = function(_, opts)
    seen = opts
    return { wait = function() return { code = 0 } end }
  end
  local caller_opts = { text = true }
  local ok, err = xpcall(function()
    system.run({ "example" }, caller_opts)
    H.eq(seen.text, true)
    assert(type(seen.timeout) == "number" and seen.timeout > 0,
      "a run with no explicit bound must still be bounded")
    H.eq(caller_opts.timeout, nil, "the caller's table is never mutated")
    system.run({ "example" }, { timeout = 5 })
    H.eq(seen.timeout, 5, "an explicit caller bound always wins")
    system.run({ "example" })
    assert(type(seen.timeout) == "number", "nil opts are bounded too")
  end, debug.traceback)
  vim.system = real_system
  assert(ok, err)
end

T["os_ file adapter owns complete reads writes and parent creation"] = function()
  local dir = H.tmpdir()
  local path = vim.fs.joinpath(dir, "nested", "state.json")
  local content = "one\r\ntwo\0three"

  local ok, err = xpcall(function()
    system.write_file(path, content)
    H.eq(system.read_file(path), content)
    H.eq(system.read_file(vim.fs.joinpath(dir, "missing")), nil)
  end, debug.traceback)

  vim.fn.delete(dir, "rf")
  assert(ok, err)
end

T["os_ file adapter rejects every opened-handle failure"] = function()
  local real_open = io.open
  local closes = 0
  local path = "/tmp/canvasdiff-os-fault"

  local function expect_failure(operation, failure_at)
    local message = ("injected %s %s failure"):format(operation, failure_at)
    io.open = function(_, mode)
      H.eq(mode, operation == "read" and "rb" or "wb")
      return {
        read = function()
          if operation == "read" and failure_at == "operation" then
            return nil, message
          end
          return "content"
        end,
        write = function()
          if operation == "write" and failure_at == "operation" then
            return nil, message
          end
          return true
        end,
        close = function()
          closes = closes + 1
          if failure_at == "close" then
            return nil, message
          end
          return true
        end,
      }
    end

    local call = operation == "read"
        and function() return system.read_file(path) end
      or function() return system.write_file(path, "content") end
    local ok, err = pcall(call)
    H.eq(ok, false)
    assert(tostring(err):find(message, 1, true), tostring(err))
  end

  local ok, err = xpcall(function()
    expect_failure("read", "operation")
    expect_failure("write", "operation")
    expect_failure("read", "close")
    expect_failure("write", "close")
  end, debug.traceback)

  io.open = real_open
  assert(ok, err)
  H.eq(closes, 4, "every opened handle is closed even when its operation fails")
end

return T
