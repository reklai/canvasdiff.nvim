local virtualizer = require("canvasdiff.runtime.virtualizer")
local watch = require("canvasdiff.runtime.watch")

-- Asynchronous review controllers enter through this exact facade. Nested
-- groups keep their overlapping lifecycle verbs explicit while the concrete
-- Surface-owned leases and event producers remain internal to the runtime
-- domain.
return {
  virtualizer = {
    apply = virtualizer.apply,
    attach = virtualizer.attach,
    detach = virtualizer.detach,
  },
  watch = {
    reconcile = watch.reconcile,
    start = watch.start,
    stop = watch.stop,
  },
}
