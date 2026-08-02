local H = require("helpers")
local config = require("canvasdiff.config")
local winbar = require("canvasdiff.ui").winbar
local sidebar = require("canvasdiff.ui").sidebar
local lens = require("canvasdiff.diff").lens

local T = {}

T["winbar_ text is the comparison label alone, band-tinted"] = function()
  local st = { lens = lens.get("all") }
  H.eq(winbar.text(st), "%#CanvasDiffWinbar#HEAD → WORKTREE")
end

T["winbar_ text escapes percent signs in refs"] = function()
  local st = { lens = lens.range("a%b", "topic", "..") }
  H.eq(winbar.text(st), "%#CanvasDiffWinbarReadOnly#READ-ONLY  a%%b → topic")
end

T["winbar_ a range lens tints the whole bar read-only"] = function()
  local st = { lens = lens.range("main", "topic", "...") }
  H.eq(winbar.text(st, nil),
    "%#CanvasDiffWinbarReadOnly#READ-ONLY  main → topic")
end

T["winbar_ the sidebar half tints read-only with the canvas half"] = function()
  local st = { lens = lens.range("main", "topic", ".."), sections = {} }
  H.eq(sidebar.title_text(st), "%#CanvasDiffWinbarReadOnly#Files changed (0)")
end

T["winbar_ the sidebar half stays plain on a working lens"] = function()
  local st = { sections = {} }
  H.eq(sidebar.title_text(st), "%#CanvasDiffWinbar#Files changed (0)")
end

T["winbar_ the sidebar half takes the canvas half's own group"] = function()
  local st = { lens = lens.range("main", "topic", "..."), sections = {} }
  local canvas_group = winbar.text(st):match("^%%#(.-)#")
  local side_group = sidebar.title_text(st):match("^%%#(.-)#")
  H.eq(side_group, canvas_group)
  H.eq(side_group, "CanvasDiffWinbarReadOnly")
end

T["winbar_ the sidebar half escapes a percent in the title"] = function()
  -- Glyphs are validated as strings and nothing more, so a `%` reaches the
  -- title through the supported override -- and a winbar is a statusline
  -- expression, where an unescaped one is a format specifier.
  config.setup({ glyphs = { minus = "%" } })
  local st = { sections = { { path = "a.lua", adds = 1, dels = 2 } } }
  local ok, text = pcall(sidebar.title_text, st)
  config.setup({})
  assert(ok, text)
  H.eq(text, "%#CanvasDiffWinbar#Files changed (1)  +1 %%2")

  -- The escaped string alone does not say what the escape is FOR. This does:
  -- an unescaped `%` is not a bar that draws wrongly, it is a value 'winbar'
  -- rejects outright -- and sidebar's update_winbar sets the option
  -- unprotected, so the throw would escape into whatever asked for a refresh.
  local win = vim.api.nvim_get_current_win()
  local prior = vim.api.nvim_get_option_value("winbar", { win = win })
  local set_escaped = pcall(vim.api.nvim_set_option_value, "winbar", text,
    { win = win, scope = "local" })
  local set_raw, raw_err = pcall(vim.api.nvim_set_option_value, "winbar",
    (text:gsub("%%%%", "%%")), { win = win, scope = "local" })
  pcall(vim.api.nvim_set_option_value, "winbar", prior,
    { win = win, scope = "local" })
  assert(set_escaped, "the escaped title must be settable as a real winbar")
  assert(not set_raw,
    "an unescaped % must be REFUSED by the option, not merely drawn wrong")
  assert(tostring(raw_err):find("E539", 1, true),
    "and refused as an illegal character: " .. tostring(raw_err))
end

T["winbar_ ensure_hl_groups defines both groups as defaults"] = function()
  winbar.ensure_hl_groups()
  local base = vim.api.nvim_get_hl(0, { name = "CanvasDiffWinbar" })
  local ro = vim.api.nvim_get_hl(0, { name = "CanvasDiffWinbarReadOnly" })
  H.eq(base.link, "WinBar")
  H.eq(type(ro.link), "string")
end

return T
