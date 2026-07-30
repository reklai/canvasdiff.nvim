local H = require("helpers")
local cheatsheet = require("canvasdiff.ui").cheatsheet
local config = require("canvasdiff.config")

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
  assert(joined:find("q", 1, true), "overlay lists the close action's key")
  assert(joined:find("<leader>lb", 1, true),
    "overlay lists the process-wide compare picker without implying it is buffer-local")
  assert(joined:find("<leader>lc", 1, true),
    "overlay lists the process-wide checkout picker without implying it is buffer-local")
  assert(joined:find("Refresh the current diff", 1, true),
    "overlay shows the exact refresh description")

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

T["cheatsheet_toggle with all keybinds disabled opens showing placeholder message"] = function()
  -- Create keymaps with all actions disabled.
  local empty_km = {
    global = { compare = false, checkout = false },
    canvas = {
      jump = false, collapse = false, next_file = false, prev_file = false,
      next_hunk = false, prev_hunk = false, cycle_next = false, cycle_prev = false,
      refresh = false, lens_next = false, lens_prev = false, close = false,
    },
    sidebar = { select = false, close = false },
    file = { back = false },
  }

  -- Save and replace the keymaps.
  local original_km = config.options.keymaps
  config.options.keymaps = empty_km

  -- Verify the model is empty.
  local model = cheatsheet.model(empty_km)
  H.eq(model, {}, "model is empty when all actions are disabled")

  -- Toggle should still open with a placeholder message.
  cheatsheet.toggle()
  H.eq(cheatsheet.is_open(), true, "overlay opens even with no keybinds")

  -- Check that the placeholder message is present.
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local placeholder = "No keybinds configured -- q or <Esc> closes"
  assert(joined:find("No keybinds"), "placeholder message appears when no keybinds are configured")

  -- The float must be sized to fit the placeholder line, not the (zero)
  -- width the model would have produced before the placeholder swap-in.
  local width = vim.api.nvim_win_get_config(win).width
  assert(width >= #placeholder,
    ("placeholder float must be wide enough for its own text (got %d, need >= %d)")
      :format(width, #placeholder))

  -- Close and restore.
  cheatsheet.close()
  H.eq(cheatsheet.is_open(), false, "overlay closes normally")
  config.options.keymaps = original_km
end

T["cheatsheet_help key is installed on the canvas and closing the canvas closes the overlay"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a1\n" },
    worktree = { ["a.txt"] = "A1\n" },
  })
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.open()
  local buf = vim.api.nvim_get_current_buf()

  local help
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == H.norm_lhs("<leader>lh") then help = m end
  end
  assert(help, "<leader>lh must be installed on the canvas buffer")
  help.callback()
  H.eq(cheatsheet.is_open(), true, "the help key opens the overlay")

  fm.close()
  H.eq(cheatsheet.is_open(), false, "closing the canvas closes the overlay (spec R4)")
  vim.api.nvim_set_current_dir(old_cwd)
end

T["cheatsheet_overlay closes when the surface is disposed without going through App:close"] = function()
  -- A `:q` on the canvas window tears the review down through the WinClosed
  -- autocmd straight into Surface:dispose("last_window"), never reaching
  -- App:close. WinClosed is unreliable in headless tests, so exercise the
  -- disposal path directly instead of relying on the autocmd firing.
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a1\n" },
    worktree = { ["a.txt"] = "A1\n" },
  })
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  local st = fm.open()

  cheatsheet.toggle()
  H.eq(cheatsheet.is_open(), true, "the overlay is open before disposal")

  st.surface:dispose("last_window")
  H.eq(cheatsheet.is_open(), false,
    "the overlay must not survive a disposal path that bypasses App:close (spec R4)")

  vim.api.nvim_set_current_dir(old_cwd)
end

T["cheatsheet_overlay reflects an overridden help key and closes on it"] = function()
  local fm = require("canvasdiff")
  fm.setup({ keymaps = { canvas = { help = "g?" }, sidebar = { help = "g?" } } })
  cheatsheet.toggle()
  local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
  local joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(joined:find("g?", 1, true), "the overlay lists the user's key, not the default")
  assert(not joined:find("<leader>lh", 1, true), "the replaced default is gone")

  local closed
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == "g?" then
      m.callback()
      closed = true
    end
  end
  assert(closed, "the overridden help key must close the open overlay")
  H.eq(cheatsheet.is_open(), false)
  fm.setup({}) -- restore defaults for the rest of the suite
end

return T
