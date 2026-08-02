local cheatsheet = require("canvasdiff.ui.cheatsheet")
local syntax = require("canvasdiff.ui.syntax")
local notifications = require("canvasdiff.ui.notifications")
local scrollbar = require("canvasdiff.ui.scrollbar")
local sidebar = require("canvasdiff.ui.sidebar")
local status_column = require("canvasdiff.ui.status_column")
local sticky_header = require("canvasdiff.ui.sticky_header")
local winbar = require("canvasdiff.ui.winbar")

-- User-facing presentation enters the UI domain through this curated facade.
-- Owners inside the domain import each other directly (sidebar reaches
-- notifications, not this table) so that requiring the facade from an owner
-- can never form a cycle.
return {
  cheatsheet = cheatsheet,
  err = notifications.err,
  notify = notifications.notify,
  scrollbar = scrollbar,
  sidebar = sidebar,
  status_column = status_column,
  sticky_header = sticky_header,
  syntax = syntax,
  warn = notifications.warn,
  winbar = winbar,
}
