local H = require("helpers")
local config = require("galley.config")

local T = {}

--- setup() mutates module state shared by the whole suite; always restore.
local function with_setup(opts, fn)
  local real = vim.notify
  local msgs = {}
  vim.notify = function(msg, level) msgs[#msgs + 1] = { msg = msg, level = level } end
  local ok, err = pcall(function() fn(config.setup(opts), msgs) end)
  vim.notify = real
  config.setup({}) -- back to defaults for everyone else
  assert(ok, err)
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
  with_setup({ keymaps = { jump = "<C-j>", close = "x" } }, function(_, msgs)
    H.eq(#msgs, 1, "exactly one message")
    H.eq(msgs[1].level, vim.log.levels.ERROR)
    assert(msgs[1].msg:match("jump") and msgs[1].msg:match("close"),
      "must name the offending keys, got: " .. msgs[1].msg)
    assert(msgs[1].msg:match("canvas"), "and point at the new shape, got: " .. msgs[1].msg)
  end)
end

T["config_ the new nested shape is not mistaken for the old one"] = function()
  with_setup({ keymaps = { canvas = { jump = "<C-j>", close = "x" } } }, function(_, msgs)
    H.eq(#msgs, 0, "a valid config must be silent")
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
-- Glyphs live on `render`, not in config.options, because render must stay requirable
-- without config (it is pure, model and sidebar build lines with it, its tests call it
-- directly). config only pushes overrides in. These pin that wiring, and the reset --
-- without which two setup() calls layer their overrides on each other.

T["config_ glyphs default to the shipped unicode set"] = function()
  local render = require("galley.render")
  config.setup({})
  H.eq(render.glyphs.file, "▎")
  H.eq(render.glyphs.folded, "▸")
  H.eq(render.glyphs.scroll_bar, "❘")
end

T["config_ a glyph table overrides only the slots it names"] = function()
  local render = require("galley.render")
  config.setup({ glyphs = { file = "|", minus = "-" } })
  H.eq(render.glyphs.file, "|")
  H.eq(render.glyphs.minus, "-")
  H.eq(render.glyphs.folded, "▸", "untouched slots keep their default")
  config.setup({})
  H.eq(render.glyphs.file, "▎", "and setup resets, rather than layering")
end

T["config_ glyphs = 'ascii' selects the preset"] = function()
  local render = require("galley.render")
  config.setup({ glyphs = "ascii" })
  for name, want in pairs(config.ASCII_GLYPHS) do
    H.eq(render.glyphs[name], want, name .. " must come from the preset")
  end
  -- The preset covers EVERY slot: a partial preset would leave unicode glyphs behind
  -- on a font that cannot draw them, which is the whole reason to reach for it.
  for name in pairs(render.glyphs) do
    assert(config.ASCII_GLYPHS[name], "ASCII_GLYPHS is missing the '" .. name .. "' slot")
  end
  -- And every one is a single cell under BOTH ambiwidth settings, unlike the defaults.
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

T["config_ a typo'd glyph name is reported, not silently ignored"] = function()
  with_setup({ glyphs = { fyle = "|" } }, function(_, msgs)
    local said = false
    for _, m in ipairs(msgs) do
      if tostring(m.msg):find("unknown glyph", 1, true) then said = true end
    end
    assert(said, "a misspelled glyph slot must be reported: " .. vim.inspect(msgs))
  end)
  with_setup({ glyphs = 42 }, function(_, msgs)
    local said = false
    for _, m in ipairs(msgs) do
      if tostring(m.msg):find("glyphs must be", 1, true) then said = true end
    end
    assert(said, "a non-table, non-\"ascii\" value must be reported")
  end)
end

return T
