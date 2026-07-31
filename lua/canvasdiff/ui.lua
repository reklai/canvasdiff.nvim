local cheatsheet = require("canvasdiff.ui.cheatsheet")
local highlight = require("canvasdiff.ui.highlight")
local notifications = require("canvasdiff.ui.notifications")
local scrollbar = require("canvasdiff.ui.scrollbar")
local sidebar = require("canvasdiff.ui.sidebar")
local status_column = require("canvasdiff.ui.status_column")
local winbar = require("canvasdiff.ui.winbar")

-- User-facing presentation enters the UI domain through this curated facade.
-- Owners inside the domain import each other directly (sidebar reaches
-- notifications, not this table) so that requiring the facade from an owner
-- can never form a cycle.
return {
  cheatsheet = cheatsheet,
  err = notifications.err,
  highlight = highlight,
  notify = notifications.notify,
  scrollbar = scrollbar,
  sidebar = sidebar,
  status_column = status_column,
  warn = notifications.warn,
  winbar = winbar,
}
