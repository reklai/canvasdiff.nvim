local N = {}

-- Prefix on every user-facing message. Rename touchpoint.
local PREFIX = "CanvasDiff: "

--- Notify with the plugin's prefix. `level` defaults to INFO.
---
--- Argument order deliberately mirrors `vim.notify(msg, level)` rather than
--- (level, msg): every call site here reads like the stdlib call it wraps, and
--- the warn/err sugar below means `level` is rarely passed at all.
function N.notify(msg, level)
  vim.notify(PREFIX .. msg, level or vim.log.levels.INFO)
end

function N.warn(msg) N.notify(msg, vim.log.levels.WARN) end

function N.err(msg) N.notify(msg, vim.log.levels.ERROR) end

return N
