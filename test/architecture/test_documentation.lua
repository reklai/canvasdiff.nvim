local appearance = require("canvasdiff.appearance")
local graph = require("architecture.graph")
local T = {}
local HIGHLIGHT_PRECEDENCE =
  "CanvasDiff defaults -> colorscheme/direct definition -> setup().highlights"

local function read(path)
  local file = assert(io.open(vim.fs.joinpath(graph.root, path), "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

T.architecture_documentation_names_every_public_highlight = function()
  local readme, help = read("README.md"), read("doc/canvasdiff.txt")
  for _, name in ipairs(appearance.names()) do
    assert(readme:find(name, 1, true), "README omits " .. name)
    assert(help:find(name, 1, true), "Vim help omits " .. name)
  end
end

T.architecture_documentation_has_install_config_and_health_paths = function()
  local readme = read("README.md")
  for _, needle in ipairs({
    '"reklai/canvasdiff.nvim"', "opts =", 'cmd = "CanvasDiff"',
    "CanvasDiffFileBar", ":checkhealth canvasdiff", "CONTRIBUTING.md",
  }) do
    assert(readme:find(needle, 1, true), "README omits " .. needle)
  end
  assert(not readme:find("TODO: demo", 1, true), "demo placeholder remains")
end

T.architecture_documentation_states_highlight_ownership_low_to_high = function()
  local readme, help = read("README.md"), read("doc/canvasdiff.txt")
  assert(readme:find(HIGHLIGHT_PRECEDENCE, 1, true),
    "README reverses highlight ownership precedence")
  assert(help:find(HIGHLIGHT_PRECEDENCE, 1, true),
    "Vim help reverses highlight ownership precedence")
end

return T
