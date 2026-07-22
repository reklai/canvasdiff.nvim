local M = {}

M.defaults = {
  keymaps = {
    jump = "<CR>",
    back = "<M-CR>",
    close = "q",
    refresh = "R",
  },
  context = 3,
}

M.options = vim.deepcopy(M.defaults)

--- Merge `opts` into the current config (deep, `opts` wins). Never called ⇒
--- `M.options` stays at `M.defaults`.
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
