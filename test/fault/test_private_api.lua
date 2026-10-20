local H = require("helpers")
local PageList = require("canvasdiff.canvas.PageList")

local T = {}

local MODULE = "canvasdiff.canvas.Projection"

-- The paged canvas repaints through nvim__redraw, which is private API: no
-- deprecation cycle protects it, so the release that renames or reshapes it
-- is the first anyone hears of it. Every row's text lives in decorations, so
-- a repaint that fails leaves stale rows on screen. Projection captures the
-- function at load, which is why each case loads a fresh module.
--
-- The fresh instance must not register a decoration provider: providers are
-- keyed by namespace, which both instances share, so its registration would
-- replace the live module's for the rest of the run. It captures a no-op
-- registrar instead; the repaint under test does not depend on decorations.
local function with_redraw(replacement, callback)
  local real_redraw = vim.api.nvim__redraw
  local real_set_provider = vim.api.nvim_set_decoration_provider
  local real_module = package.loaded[MODULE]
  vim.api.nvim__redraw = replacement
  vim.api.nvim_set_decoration_provider = function() end
  package.loaded[MODULE] = nil
  local loaded, fresh = pcall(require, MODULE)
  vim.api.nvim_set_decoration_provider = real_set_provider
  local ok, err = xpcall(function()
    assert(loaded, fresh)
    callback(fresh)
  end, debug.traceback)
  vim.api.nvim__redraw = real_redraw
  package.loaded[MODULE] = real_module
  assert(ok, err)
end

local function repaint_succeeds(Projection)
  local list = assert(PageList.create({ "first row", "second row" }))
  local projection = assert(Projection.create(list, {
    decorate = function() return nil end,
  }))
  local previous = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(assert(projection:buffer()))
  local redrawn, err = projection:redraw()
  vim.api.nvim_set_current_buf(previous)
  projection:dispose(true)
  H.eq(err, nil, "the public fallback must repaint without an error")
  H.eq(redrawn, true)
end

T["private_api projection repaints when nvim__redraw is gone"] = function()
  with_redraw(nil, repaint_succeeds)
end

T["private_api projection repaints when nvim__redraw rejects its arguments"] = function()
  with_redraw(function()
    error("Invalid key: 'valid'")
  end, repaint_succeeds)
end

return T
