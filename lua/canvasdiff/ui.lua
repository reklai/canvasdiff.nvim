local notifications = require("canvasdiff.ui.notifications")

-- User-facing presentation enters the UI domain through this curated facade.
return {
  err = notifications.err,
  notify = notifications.notify,
  warn = notifications.warn,
}
