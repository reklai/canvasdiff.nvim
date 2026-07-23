if vim.g.loaded_finding_myself then
  return
end
vim.g.loaded_finding_myself = true

local SUBCOMMANDS = { "open", "close", "toggle", "refresh", "base" }

vim.api.nvim_create_user_command("FindingMyself", function(opts)
  local sub = opts.fargs[1] or "toggle"
  if not vim.tbl_contains(SUBCOMMANDS, sub) then
    vim.notify(
      "finding_myself: unknown subcommand '" .. sub .. "' (valid: " .. table.concat(SUBCOMMANDS, ", ") .. ")",
      vim.log.levels.ERROR
    )
    return
  end
  local fm = require("finding_myself")
  if sub == "base" then
    fm.toggle_base()
  else
    fm[sub]()
  end
end, {
  nargs = "?",
  desc = "Open/close/toggle/refresh/base the finding_myself diff canvas",
  complete = function(arglead)
    return vim.tbl_filter(function(c)
      return c:sub(1, #arglead) == arglead
    end, SUBCOMMANDS)
  end,
})
