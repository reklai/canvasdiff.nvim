-- :checkhealth canvasdiff. Discovery is by path (lua/canvasdiff/health.lua),
-- so this module sits at the top level rather than inside a domain; it is a
-- thin renderer over probes that live where the knowledge lives
-- (config.health owns the configuration audit).
local M = {}

function M.check()
  local health = vim.health
  health.start("canvasdiff")

  -- 0.12 is the TESTED floor, not a guess: the float, winbar and
  -- statuscolumn geometry are measured against it (relative-window float
  -- rows and getmousepos().winrow both start at the first text row -- the
  -- same facts differed in an earlier Neovim, which is exactly why the
  -- floor is asserted rather than assumed).
  if vim.fn.has("nvim-0.12") == 1 then
    health.ok(("Neovim %s (tested floor: 0.12)"):format(tostring(vim.version())))
  else
    health.error(
      ("canvasdiff requires Neovim 0.12+; this is %s"):format(tostring(vim.version())),
      "float and statuscolumn geometry are measured against 0.12")
  end

  if vim.fn.executable("git") == 1 then
    local version = vim.fn.system({ "git", "--version" }):gsub("%s+$", "")
    health.ok(version)
  else
    health.error("git is not executable; canvasdiff cannot collect a diff")
  end

  local report = require("canvasdiff.config").health()
  for _, message in ipairs(report.removed) do
    health.warn(message)
  end
  for _, path in ipairs(report.unknown) do
    health.warn(("unknown option `%s` -- a typo? It merges without complaint"
      .. " and does nothing"):format(path))
  end
  if #report.removed == 0 and #report.unknown == 0 then
    health.ok("configuration has no unknown or removed options")
  end
end

return M
