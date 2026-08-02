-- The appearance domain's only cross-domain entry point. It exposes canonical
-- highlight names and the manager's setup/repair contract; definitions and
-- process-wide authorship remain internal, and this domain imports no peer.
local groups = require("canvasdiff.appearance.groups")
local manager = require("canvasdiff.appearance.manager")

return {
  audit = manager.audit,
  ensure = manager.ensure,
  names = groups.names,
  setup = manager.setup,
}
