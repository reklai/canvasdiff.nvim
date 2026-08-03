local command = require("canvasdiff.input.command")
local jump = require("canvasdiff.input.jump")
local keys = require("canvasdiff.input.keys")
local motions = require("canvasdiff.input.motions")

-- Key resolution and canvas navigation enter the input domain through this
-- exact surface. Binding metadata and motion arithmetic remain internal.
return {
  -- The pure `:CanvasDiff` grammar. `parse` never throws -- bad input becomes
  -- an action = "error" parse -- and `plan` turns a parse into
  -- { call, argument, diagnostic } without executing or presenting anything;
  -- the owner does both. `complete` is pure over caller-supplied refs.
  command = {
    candidate_order = command.candidate_order,
    complete = command.complete,
    parse = command.parse,
    plan = command.plan,
    words = command.words,
  },
  -- Canvas <-> real-file excursions over a per-review `store` (one per
  -- Surface, so concurrent reviews never share a way back). `enter` and
  -- `back` answer { ok, diagnostic? } -- refusals are data for the owner to
  -- present, never thrown -- and `back` declines WITHOUT consuming the
  -- excursion, so the keypress stays retryable. `cancel` answers false when
  -- there was nothing to consume; `last_buf` a still-valid buffer or nil.
  jump = {
    back = jump.back,
    cancel = jump.cancel,
    enter = jump.enter,
    last_buf = jump.last_buf,
    store = jump.store,
  },
  -- Pure lookups over the binding specs and a config keymaps table; every
  -- function returns fresh tables and never errors. `list` normalizes one
  -- config value to a key list -- nil/false/""/{} all mean disabled.
  keys = {
    collisions = keys.collisions,
    grouped = keys.grouped,
    list = keys.list,
    resolved = keys.resolved,
  },
  -- Cursor and scroll movers over an open canvas. Each returns its landing
  -- target (section index, stop index, or 0-based row) and nil when it did
  -- nothing -- no sections, no stops, or the window isn't showing the canvas.
  motions = {
    cycle = motions.cycle,
    cycle_hunk = motions.cycle_hunk,
    goto_file = motions.goto_file,
    goto_hunk = motions.goto_hunk,
    hunk_stops = motions.hunk_stops,
  },
}
