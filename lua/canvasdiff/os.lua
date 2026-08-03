local clock = require("canvasdiff.os.clock")
local fs = require("canvasdiff.os.fs")
local process = require("canvasdiff.os.process")

-- Raw operating-system effects enter through this exact surface. Higher-level
-- Git, session, and watch semantics stay with their owning domains.
return {
  -- One libuv handle each, or nil when libuv refuses; the caller owns the
  -- entire start/stop/close lifecycle.
  new_fs_event = fs.new_event,
  new_timer = clock.new_timer,
  -- The whole file's bytes, or nil when it cannot be opened.
  read_file = fs.read_file,
  -- Synchronous argv-vector process; returns vim.system's completed result
  -- table { code, stdout, stderr, ... }.
  run = process.run,
  -- Creates the parent directory, then writes. Failures stay EXCEPTIONS so
  -- the owning domain decides whether persistence failure is fatal.
  write_file = fs.write_file,
}
