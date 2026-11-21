-- The tested floor, asserted rather than assumed: float, winbar and
-- statuscolumn geometry are measured against 0.12 (see :checkhealth
-- canvasdiff), and those exact facts have differed across Neovim versions.
if vim.fn.has("nvim-0.12") == 0 then
  vim.notify(
    "canvasdiff.nvim requires Neovim 0.12+ (:checkhealth canvasdiff)",
    vim.log.levels.ERROR)
  return
end

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
  desc = "CanvasDiff review canvas: :CanvasDiff [open|close|toggle|here|refresh|sidebar|quickfix|compare|all|unstaged|staged|checkpoint|since|unreviewed|range]",
  complete = function(arglead)
    return require("canvasdiff").command_complete(arglead)
  end,
})
