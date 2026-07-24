if vim.g.loaded_galley then
  return
end
vim.g.loaded_galley = true

local SUBCOMMANDS = { "open", "close", "toggle", "refresh", "base" }

vim.api.nvim_create_user_command("Galley", function(opts)
  local sub = opts.fargs[1] or "toggle"
  if not vim.tbl_contains(SUBCOMMANDS, sub) then
    require("galley.util").err(
      "unknown subcommand '" .. sub .. "' (valid: " .. table.concat(SUBCOMMANDS, ", ") .. ")"
    )
    return
  end
  local fm = require("galley")
  if sub == "base" then
    fm.toggle_base()
  else
    fm[sub]()
  end
end, {
  nargs = "?",
  desc = "Open/close/toggle/refresh/base the galley diff canvas",
  complete = function(arglead)
    return vim.tbl_filter(function(c)
      return c:sub(1, #arglead) == arglead
    end, SUBCOMMANDS)
  end,
})
