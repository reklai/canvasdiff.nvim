local M = {}

M.defaults = {
  keymaps = {
    jump = "<CR>",
    back = "<M-CR>",
    close = "q",
    refresh = "R",
    cycle_next = "<C-n>",
    cycle_prev = "<C-p>",
  },
  context = 3,
  sidebar = {
    enabled = true,
    width = 32,
  },
  highlight = {
    enabled = true,
    margin = 100,
    debounce_ms = 30,
  },
  watch = {
    enabled = true,
    debounce_ms = 200,
  },
  scrollbar = {
    enabled = true,
  },
}

M.options = vim.deepcopy(M.defaults)

--- Merge `opts` into the current config (deep, `opts` wins). Never called ⇒
--- `M.options` stays at `M.defaults`.
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
