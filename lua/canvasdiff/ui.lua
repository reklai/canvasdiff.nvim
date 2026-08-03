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
  -- The floating keybind cheatsheet, rendered from input.keys + config.
  cheatsheet = cheatsheet,
  -- err/notify/warn: prefixed vim.notify wrappers (notify defaults to INFO).
  err = notifications.err,
  notify = notifications.notify,
  -- The right-edge minimap of file boundaries and changed stretches.
  scrollbar = scrollbar,
  -- The file/hunk tree window beside the canvas.
  sidebar = sidebar,
  -- The per-row gutter bar and line numbers for canvas windows.
  status_column = status_column,
  -- The pinned file-header float and its hunk breadcrumb.
  sticky_header = sticky_header,
  -- Lease-scoped Tree-sitter highlighting of canvas rows.
  syntax = syntax,
  warn = notifications.warn,
  -- The comparison band and its window-option bookkeeping.
  winbar = winbar,
}
