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
  H.eq(config.options.keymaps.sidebar.select, { "<CR>", "<Tab>", "za", "<2-LeftMouse>" })
  H.eq(config.options.keymaps.file.back, "<M-CR>")
end

-- The whole nested+list design rests on this: tbl_deep_extend REPLACES
-- list-like values rather than merging them index-wise. If it ever merged,
-- `collapse = "<Tab>"` would silently keep `za` and the override would be a
-- lie. Pin the behaviour we depend on.
T["config_ a list override replaces rather than merges"] = function()
  with_setup({ keymaps = { canvas = { collapse = "<Tab>" } } }, function(opts)
    H.eq(opts.keymaps.canvas.collapse, "<Tab>", "the alternate key must be gone")
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
    H.eq(opts.keymaps.sidebar.select, { "<CR>", "<Tab>", "za", "<2-LeftMouse>" })
    H.eq(opts.keymaps.file.back, "<M-CR>")
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

return T
