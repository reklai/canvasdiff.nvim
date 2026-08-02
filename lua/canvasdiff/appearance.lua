local groups = require("canvasdiff.appearance.groups")
local manager = require("canvasdiff.appearance.manager")

return {
  audit = manager.audit,
  ensure = manager.ensure,
  names = groups.names,
  setup = manager.setup,
}
