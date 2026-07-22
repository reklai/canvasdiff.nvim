if vim.g.loaded_finding_myself then
  return
end
vim.g.loaded_finding_myself = true

local SUBCOMMANDS = { "open", "close", "toggle", "refresh" }

vim.api.nvim_create_user_command("FindingMyself", function(opts)
  local sub = opts.fargs[1] or "toggle"
  local fm = require("finding_myself")
  local fn = fm[sub]
  if type(fn) ~= "function" then
    vim.notify("finding_myself: unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
    return
  end
  fn()
end, {
  nargs = "?",
  desc = "Open/close/toggle/refresh the finding_myself diff canvas",
  complete = function(arglead)
    return vim.tbl_filter(function(c)
      return c:sub(1, #arglead) == arglead
    end, SUBCOMMANDS)
  end,
})
