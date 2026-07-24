local U = {}

-- Prefix on every user-facing message. Rename touchpoint.
U.PREFIX = "galley: "

function U.list_slice(t, s, e)
  local out = {}
  for i = s, math.min(e, #t) do out[#out + 1] = t[i] end
  return out
end

function U.clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end

--- Notify with the plugin's prefix. `level` defaults to INFO.
---
--- Argument order deliberately mirrors `vim.notify(msg, level)` rather than
--- (level, msg): every call site here reads like the stdlib call it wraps, and
--- the warn/err sugar below means `level` is rarely passed at all.
function U.notify(msg, level)
  vim.notify(U.PREFIX .. msg, level or vim.log.levels.INFO)
end

function U.warn(msg) U.notify(msg, vim.log.levels.WARN) end

function U.err(msg) U.notify(msg, vim.log.levels.ERROR) end

return U
