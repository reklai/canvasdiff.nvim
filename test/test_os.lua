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
    H.eq(opts, { text = false })
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

return T
