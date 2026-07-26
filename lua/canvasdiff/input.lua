local command = require("canvasdiff.input.command")
local keys = require("canvasdiff.input.keys")
local motions = require("canvasdiff.input.motions")

-- Key resolution and canvas navigation enter the input domain through this
-- exact surface. Binding metadata and motion arithmetic remain internal.
return {
  command = {
    candidate_order = command.candidate_order,
    complete = command.complete,
    parse = command.parse,
    plan = command.plan,
    words = command.words,
  },
  keys = {
    collisions = keys.collisions,
    grouped = keys.grouped,
    list = keys.list,
    resolved = keys.resolved,
  },
  motions = {
    cycle = motions.cycle,
    goto_file = motions.goto_file,
    goto_hunk = motions.goto_hunk,
  },
}
