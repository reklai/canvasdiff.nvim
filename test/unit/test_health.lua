local config = require("canvasdiff.config")

local T = {}

-- End to end through the real :checkhealth machinery: runtime discovery of
-- lua/canvasdiff/health.lua, the version and git probes, and the config
-- audit all render into the health buffer a user would actually read.
T["health_ checkhealth surfaces the floor, git, and swallowed config typos"] = function()
  config.setup({
    keymaps = { canvas = { colapse = "x" } },
    highlight = { diff = "gutter" },
  })
  vim.cmd("checkhealth canvasdiff")
  local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  vim.cmd("bwipeout!")
  config.setup({})

  assert(lines:find("canvasdiff"), "our section rendered:\n" .. lines)
  assert(lines:find("Neovim"), "the version probe reported:\n" .. lines)
  assert(lines:find("git version"), "the git probe reported:\n" .. lines)
  assert(lines:find("colapse"), "the swallowed typo is surfaced:\n" .. lines)
  assert(lines:find("highlight%.diff"),
    "the removed option is surfaced:\n" .. lines)
end

return T
