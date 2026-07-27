local H = require("helpers")
local cheatsheet = require("canvasdiff.ui").cheatsheet

local T = {}

T["cheatsheet_toggle opens a centered float and toggle closes it again"] = function()
  H.eq(cheatsheet.is_open(), false)
  cheatsheet.toggle()
  H.eq(cheatsheet.is_open(), true)
  local win = vim.api.nvim_get_current_win()
  local cfg = vim.api.nvim_win_get_config(win)
  H.eq(cfg.relative, "editor", "the overlay floats over the editor")
  local buf = vim.api.nvim_win_get_buf(win)
  local joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(joined:find("Canvas"), "overlay shows the Canvas column")
  assert(joined:find("q", 1, true), "overlay lists the close key")

  cheatsheet.toggle()
  H.eq(cheatsheet.is_open(), false)
  H.eq(vim.api.nvim_win_is_valid(win), false, "toggle closes the float window")
end

T["cheatsheet_q on the overlay closes it"] = function()
  cheatsheet.toggle()
  H.eq(cheatsheet.is_open(), true)
  local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == "q" then
      m.callback()
      H.eq(cheatsheet.is_open(), false)
      return
    end
  end
  error("the overlay must bind q")
end

T["cheatsheet_close is safe when nothing is open"] = function()
  cheatsheet.close()
  cheatsheet.close()
  H.eq(cheatsheet.is_open(), false)
end

return T
