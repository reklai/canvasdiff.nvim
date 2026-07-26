local highlight = require("canvasdiff.ui.highlight")
local notifications = require("canvasdiff.ui.notifications")
local scrollbar = require("canvasdiff.ui.scrollbar")
local sidebar = require("canvasdiff.ui.sidebar")
local status_column = require("canvasdiff.ui.status_column")

-- User-facing presentation enters the UI domain through this curated facade.
-- Owners inside the domain import each other directly (sidebar reaches
-- notifications, not this table) so that requiring the facade from an owner
-- can never form a cycle.
return {
  err = notifications.err,
  highlight = highlight,
  notify = notifications.notify,
  scrollbar = scrollbar,
  sidebar = sidebar,
  status_column = status_column,
  warn = notifications.warn,
}
