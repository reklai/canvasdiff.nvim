local settings = require("canvasdiff.config.settings")

-- The config domain's exact public surface. Mutable state is owned by settings;
-- setup refreshes facade references for tables whose identity changes, including
-- the native highlight map consumed by appearance, while the glyph table is
-- deliberately stable and mutated in place.
local C = {
  ASCII_GLYPHS = settings.ASCII_GLYPHS,
  defaults = settings.defaults,
  glyphs = settings.glyphs,
  -- The :checkhealth audit of the captured user_opts: returns
  -- { unknown = dotted-path[], removed = message[] }, both possibly empty.
  health = settings.health,
  options = settings.options,
  user_opts = settings.user_opts,
}

-- Merge `opts` over the defaults (deep, `opts` wins), reset and reapply the
-- glyph overrides, and return (options, diagnostics). Never errors: legacy
-- shapes, removed options and bad glyph values become diagnostic strings.
function C.setup(opts)
  local options, diagnostics = settings.setup(opts)
  C.options = settings.options
  C.user_opts = settings.user_opts
  return options, diagnostics
end

return C
