local highlight = require("canvasdiff.ui.highlight")
local notifications = require("canvasdiff.ui.notifications")
local scrollbar = require("canvasdiff.ui.scrollbar")

-- User-facing presentation enters the UI domain through this curated facade.
return {
  err = notifications.err,
  highlight = highlight,
  notify = notifications.notify,
  scrollbar = scrollbar,
  warn = notifications.warn,
}
