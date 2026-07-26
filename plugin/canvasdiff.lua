if vim.g.loaded_canvasdiff then
  return
end
vim.g.loaded_canvasdiff = true

vim.api.nvim_create_user_command("CanvasDiff", function(opts)
  local cmd = require("canvasdiff.cmd")
  cmd.run(cmd.parse(opts.fargs))
end, {
  -- "*" rather than "?" so arity errors come from us with a real message,
  -- instead of Vim's generic trailing-characters complaint.
  nargs = "*",
  desc = "CanvasDiff review canvas: :CanvasDiff [open|close|toggle|refresh|all|unstaged|staged]",
  complete = function(arglead)
    return require("canvasdiff.cmd").complete(arglead)
  end,
})
