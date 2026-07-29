if vim.g.loaded_canvasdiff then
  return
end
vim.g.loaded_canvasdiff = true

vim.api.nvim_create_user_command("CanvasDiff", function(opts)
  require("canvasdiff").command(opts.fargs)
end, {
  -- "*" rather than "?" so arity errors come from us with a real message,
  -- instead of Vim's generic trailing-characters complaint.
  nargs = "*",
  desc = "CanvasDiff review canvas: :CanvasDiff [open|close|toggle|refresh|compare|all|unstaged|staged|range]",
  complete = function(arglead)
    return require("canvasdiff").command_complete(arglead)
  end,
})

-- Instantiate the root owner now so its conservative default global mapping is
-- available before the first :CanvasDiff command. setup() can rebind/disable it.
require("canvasdiff")
