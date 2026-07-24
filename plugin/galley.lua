if vim.g.loaded_galley then
  return
end
vim.g.loaded_galley = true

vim.api.nvim_create_user_command("Galley", function(opts)
  local cmd = require("galley.cmd")
  cmd.run(cmd.parse(opts.fargs))
end, {
  -- "*" rather than "?" so arity errors come from us with a real message,
  -- instead of Vim's generic trailing-characters complaint.
  nargs = "*",
  desc = "galley diff canvas: :Galley [open|close|toggle|refresh|unstaged|all]",
  complete = function(arglead)
    return require("galley.cmd").complete(arglead)
  end,
})
