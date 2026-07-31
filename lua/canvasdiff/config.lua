local settings = require("canvasdiff.config.settings")

-- The config domain's exact public surface. Mutable state is owned by settings;
-- setup refreshes facade references for tables whose identity changes, while the
-- glyph table is deliberately stable and mutated in place.
local C = {
  ASCII_GLYPHS = settings.ASCII_GLYPHS,
  defaults = settings.defaults,
  diff_mode = settings.diff_mode,
  glyphs = settings.glyphs,
  options = settings.options,
  user_opts = settings.user_opts,
}

function C.setup(opts)
  local options, diagnostics = settings.setup(opts)
  C.options = settings.options
  C.user_opts = settings.user_opts
  return options, diagnostics
end

return C
