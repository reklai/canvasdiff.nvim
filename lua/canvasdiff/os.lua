local clock = require("canvasdiff.os.clock")
local fs = require("canvasdiff.os.fs")
local process = require("canvasdiff.os.process")

-- Raw operating-system effects enter through this exact surface. Higher-level
-- Git, session, and watch semantics stay with their owning domains.
return {
  new_fs_event = fs.new_event,
  new_timer = clock.new_timer,
  read_file = fs.read_file,
  run = process.run,
  write_file = fs.write_file,
}
