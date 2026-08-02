local appearance = require("canvasdiff.appearance")
local command = require("canvasdiff.input").command
local graph = require("architecture.graph")
local T = {}
local HIGHLIGHT_PRECEDENCE =
  "CanvasDiff defaults -> colorscheme/direct definition -> setup().highlights"

local function read_help()
  local path = vim.fs.joinpath(graph.root, "doc/canvasdiff.txt")
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

T.architecture_help_names_every_public_highlight = function()
  local help = read_help()
  for _, name in ipairs(appearance.names()) do
    assert(help:find(name, 1, true), "Vim help omits " .. name)
  end
end

T.architecture_help_names_every_public_command = function()
  local help = read_help()
  for _, word in ipairs(command.candidate_order) do
    local invocation = ":CanvasDiff " .. word
    assert(help:find(invocation, 1, true), "Vim help omits " .. invocation)
  end
end

T.architecture_help_states_highlight_ownership_low_to_high = function()
  local help = read_help()
  assert(help:find(HIGHLIGHT_PRECEDENCE, 1, true),
    "Vim help reverses highlight ownership precedence")
end

return T
