local H = require("helpers")
local config = require("canvasdiff.config")

local T = {}

--- setup() mutates module state shared by the whole suite; always restore.
local function with_setup(opts, fn)
  local ok, err = pcall(function()
    local options, diagnostics = config.setup(opts)
    fn(options, diagnostics)
  end)
  config.setup({}) -- back to defaults for everyone else
  assert(ok, err)
end

T["config_ facade exports exactly the supported domain API"] = function()
  local names = vim.tbl_keys(config)
  table.sort(names)
  H.eq(names, {
    "ASCII_GLYPHS",
    "defaults",
    "glyphs",
    "options",
    "setup",
    "user_opts",
  })
end

T["config_ setup is optional and defaults are live without it"] = function()
  H.eq(config.options.keymaps.canvas.close, "q")
  H.eq(config.options.keymaps.sidebar.select, { "<CR>", "za", "c", "<2-LeftMouse>" })
  H.eq(config.options.keymaps.file.back, "<C-Space>")
end

-- The whole nested+list design rests on this: tbl_deep_extend REPLACES
-- list-like values rather than merging them index-wise. If it ever merged,
-- `collapse = "za"` would silently keep `c` and the override would be a
-- lie. Pin the behaviour we depend on.
T["config_ a list override replaces rather than merges"] = function()
  with_setup({ keymaps = { canvas = { collapse = "za" } } }, function(opts)
    H.eq(opts.keymaps.canvas.collapse, "za", "the alternate key must be gone")
    H.eq(opts.keymaps.canvas.close, "q", "untouched actions keep their defaults")
  end)
  with_setup({ keymaps = { sidebar = { select = { "<CR>" } } } }, function(opts)
    H.eq(opts.keymaps.sidebar.select, { "<CR>" }, "3 defaults replaced by 1, not merged")
  end)
end

T["config_ disabling survives the merge"] = function()
  with_setup({ keymaps = { canvas = { close = false }, sidebar = { close = {} } } }, function(opts)
    H.eq(opts.keymaps.canvas.close, false)
    H.eq(opts.keymaps.sidebar.close, {})
  end)
end

T["config_ unrelated contexts are untouched by a partial override"] = function()
  with_setup({ keymaps = { canvas = { help = "g?" } } }, function(opts)
    H.eq(opts.keymaps.sidebar.select, { "<CR>", "za", "c", "<2-LeftMouse>" })
    H.eq(opts.keymaps.file.back, "<C-Space>")
  end)
end

-- Regression guard for the flat -> nested move. Without this the old shape
-- merges cleanly into an unused corner of the table, every binding silently
-- falls back to its default, and the user has no idea why.
T["config_ the old flat keymaps shape is reported, not ignored"] = function()
  with_setup({ keymaps = { jump = "<C-j>", close = "x" } }, function(_, diagnostics)
    H.eq(#diagnostics, 1, "exactly one diagnostic")
    assert(diagnostics[1]:match("jump") and diagnostics[1]:match("close"),
      "must name the offending keys, got: " .. diagnostics[1])
    assert(diagnostics[1]:match("canvas"),
      "and point at the new shape, got: " .. diagnostics[1])
  end)
end

T["config_ the new nested shape is not mistaken for the old one"] = function()
  with_setup({ keymaps = { canvas = { jump = "<C-j>", close = "x" } } },
    function(_, diagnostics)
      H.eq(#diagnostics, 0, "a valid config must have no diagnostics")
    end)
end

T["config_ user_opts keeps the raw table for health to diff"] = function()
  with_setup({ keymaps = { canvas = { colapse = "<Tab>" } } }, function()
    H.eq(config.user_opts.keymaps.canvas.colapse, "<Tab>",
      "the typo survives unmerged so :checkhealth can spot it")
    assert(config.options.keymaps.canvas.collapse ~= nil,
      "while the real default is still in place")
  end)
end

-- --- glyphs -----------------------------------------------------------------
--
-- Glyphs are live state owned by config rather than part of config.options. The
-- canvas formatting facade exposes the same table for readers. These pin that
-- ownership and the reset, without which two setup() calls layer overrides.

T["config_ glyphs default to the shipped unicode set"] = function()
  local render = require("canvasdiff.canvas").format
  config.setup({})
  H.eq(render.glyphs.file, "▎")
  H.eq(render.glyphs.folded, "▸")
  H.eq(render.glyphs.stale, " ●")
  H.eq(render.glyphs.scroll_bar, "❘")
end

T["config_ a glyph table overrides only the slots it names"] = function()
  local render = require("canvasdiff.canvas").format
  local glyphs = config.glyphs
  assert(rawequal(render.glyphs, glyphs), "canvas facade exposes the config-owned table")
  config.setup({ glyphs = { file = "|", stale = " !" } })
  assert(rawequal(config.glyphs, glyphs), "setup must preserve live glyph-table identity")
  assert(rawequal(render.glyphs, glyphs), "formatters retain that same live table")
  H.eq(render.glyphs.file, "|")
  H.eq(render.glyphs.stale, " !")
  H.eq(render.glyphs.folded, "▸", "untouched slots keep their default")
  config.setup({})
  H.eq(render.glyphs.file, "▎", "and setup resets, rather than layering")
end

T["config_ glyphs = 'ascii' selects the preset"] = function()
  local render = require("canvasdiff.canvas").format
  config.setup({ glyphs = "ascii" })
  for name, want in pairs(config.ASCII_GLYPHS) do
    H.eq(render.glyphs[name], want, name .. " must come from the preset")
  end
  -- The preset covers EVERY slot: a partial preset would leave unicode glyphs behind
  -- on a font that cannot draw them, which is the whole reason to reach for it.
  for name in pairs(render.glyphs) do
    assert(config.ASCII_GLYPHS[name], "ASCII_GLYPHS is missing the '" .. name .. "' slot")
  end
  -- And every one is a single cell under BOTH ambiwidth settings, unlike the defaults
  -- (`● ○ ▎ −` all double under `ambiwidth=double`, so the marker column and the
  -- file-header gutter change width for anyone with that set).
  --
  -- Trimmed before measuring: `stale` carries its own leading space so that
  -- `#glyphs.stale` stays a correct byte offset for its highlight span, and `ctx` IS a
  -- space. It is the glyph that has to be one cell, not the padding around it.
  local saved = vim.o.ambiwidth
  for _, aw in ipairs({ "single", "double" }) do
    vim.o.ambiwidth = aw
    for name, g in pairs(config.ASCII_GLYPHS) do
      local glyph = vim.trim(g)
      if glyph ~= "" then
        H.eq(vim.fn.strwidth(glyph), 1,
          ("%s = %q must be 1 cell at ambiwidth=%s"):format(name, g, aw))
      end
    end
  end
  vim.o.ambiwidth = saved
  config.setup({})
end

-- In the default set `staged` and `stale` are the SAME glyph and only the highlight
-- separates them -- which is colourscheme-dependent. The ASCII set is the one place
-- that distinction lives in the text, so it must not regress into sharing a glyph.
T["config_ the ascii preset separates staged from stale in the TEXT"] = function()
  assert(config.ASCII_GLYPHS.staged ~= vim.trim(config.ASCII_GLYPHS.stale),
    "ascii staged/stale must differ as characters, not just by highlight")
end

T["config_ a typo'd glyph name is reported, not silently ignored"] = function()
  with_setup({ glyphs = { fyle = "|" } }, function(_, diagnostics)
    local said = false
    for _, message in ipairs(diagnostics) do
      if tostring(message):find("unknown glyph", 1, true) then said = true end
    end
    assert(said,
      "a misspelled glyph slot must be reported: " .. vim.inspect(diagnostics))
  end)
  with_setup({ glyphs = 42 }, function(_, diagnostics)
    local said = false
    for _, message in ipairs(diagnostics) do
      if tostring(message):find("glyphs must be", 1, true) then said = true end
    end
    assert(said, "a non-table, non-\"ascii\" value must be reported")
  end)
end

return T
