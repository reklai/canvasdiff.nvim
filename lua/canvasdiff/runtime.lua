local virtualizer = require("canvasdiff.runtime.virtualizer")
local watch = require("canvasdiff.runtime.watch")

-- Asynchronous review controllers enter through this exact facade. Nested
-- groups keep their overlapping lifecycle verbs explicit while the concrete
-- Surface-owned leases and event producers remain internal to the runtime
-- domain.
return {
  -- Tier-1 auto-virtualization: collapse far-off sections of a huge changeset,
  -- expand them again near the viewport. `attach` returns a lease after one
  -- immediate policy pass, or throws after exact self-cleanup when producer
  -- setup fails. `apply` returns true exactly when collapse state changed
  -- (false for an inactive/foreign lease); `detach` is idempotent -- true on
  -- teardown, false for a lease it does not recognize.
  virtualizer = {
    apply = virtualizer.apply,
    attach = virtualizer.attach,
    detach = virtualizer.detach,
  },
  -- Filesystem/autocmd truth producer. `start` mirrors attach's contract
  -- (lease, or throw after self-cleanup); `stop` mirrors detach's. `reconcile`
  -- collects and splices synchronously: `true, result` on success, `false`
  -- when superseded mid-flight, `nil, err` on transactional failure -- no
  -- half-refreshed canvas is ever published.
  watch = {
    reconcile = watch.reconcile,
    start = watch.start,
    stop = watch.stop,
  },
}
