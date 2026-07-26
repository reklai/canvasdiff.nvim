local H = require("helpers")
local graph = require("architecture.graph")

local T = {}

T.architecture_graph_lexer_ignores_require_text_in_every_comment_and_string_form = function()
  local source = [==[
-- require("fake.line")
--[=[ require("fake.long_comment") ]=]
local quoted = "require('fake.quoted')"
local escaped = "escaped quote: \" require('fake.escaped')"
local long = [=[require("fake.long_string")]=]
local first = require("galley.diff")
local second = require 'galley.canvas'
local third = require [=[galley.source]=]
object.require("fake.member")
object:require("fake.method")
]==]

  local dependencies = graph.requires(source, "lexer_fixture.lua")
  H.eq(vim.tbl_map(function(item)
    return item.module
  end, dependencies), {
    "galley.diff",
    "galley.canvas",
    "galley.source",
  })
end

T.architecture_graph_lexer_handles_arbitrary_long_bracket_delimiters = function()
  local source = [====[
--[===[
require("fake.comment")
]===]
local text = [===[require("fake.string") ]=] ]===]
local real = require [===[galley.diff]===]
]====]

  local dependencies = graph.requires(source, "long_brackets.lua")
  H.eq(#dependencies, 1)
  H.eq(dependencies[1].module, "galley.diff")
end

T.architecture_graph_rejects_noncanonical_and_computed_requires = function()
  for _, source in ipairs({
    "local name = 'galley.diff'; require(name)",
    "local name = 'diff'; require('galley.' .. name)",
    "pcall(require, 'galley.diff')",
  }) do
    local ok, err = pcall(graph.requires, source, "dynamic.lua")
    H.eq(ok, false)
    assert(tostring(err):match("dynamic%.lua:1:"), tostring(err))
    assert(tostring(err):match("static string"), tostring(err))
  end
end

T.architecture_graph_reports_unterminated_literals_with_locations = function()
  local cases = {
    { "--[==[ never closed", "unterminated long comment" },
    { "local value = 'never closed", "unterminated quoted string" },
  }
  for _, case in ipairs(cases) do
    local ok, err = pcall(graph.requires, case[1], "broken.lua")
    H.eq(ok, false)
    assert(tostring(err):match("broken%.lua:1:"), tostring(err))
    assert(tostring(err):find(case[2], 1, true), tostring(err))
  end
end

T.architecture_graph_source_listing_includes_tracked_and_untracked_not_ignored = function()
  local root = H.git_fixture({
    committed = {
      [".gitignore"] = "lua/ignored.lua\n",
      ["lua/tracked.lua"] = "return {}\n",
      ["plugin/tracked.lua"] = "return\n",
    },
    worktree = {
      ["lua/ignored.lua"] = "return {}\n",
      ["lua/untracked.lua"] = "return {}\n",
      ["outside.lua"] = "return {}\n",
    },
  })

  local files = graph.source_files(root)
  H.eq(vim.tbl_map(function(file)
    return file.rel
  end, files), {
    "lua/tracked.lua",
    "lua/untracked.lua",
    "plugin/tracked.lua",
  })
end

T.architecture_graph_inspection_reports_duplicate_and_unresolved_modules = function()
  local root = H.git_fixture({
    committed = {
      ["lua/galley.lua"] = 'require("galley.missing")\nreturn {}\n',
      ["lua/galley/init.lua"] = "return {}\n",
    },
  })

  local inspection = graph.inspect(root)
  H.eq(#inspection.errors, 2)
  local message = table.concat(inspection.errors, "\n")
  assert(message:find('duplicate module "galley"', 1, true), message)
  assert(message:find('unresolved internal require "galley.missing"', 1, true), message)
end

T.architecture_graph_module_ids_and_cycles_are_deterministic = function()
  H.eq(graph.module_id("lua/galley.lua"), "galley")
  H.eq(graph.module_id("lua/galley/init.lua"), "galley")
  H.eq(graph.module_id("lua/galley/canvas/Page.lua"), "galley.canvas.Page")
  H.eq(graph.module_id("plugin/galley.lua"), nil)

  local nodes = {
    a = { rel = "a.lua" },
    b = { rel = "b.lua" },
    c = { rel = "c.lua" },
  }
  local edges = {
    { from = "a", to = "b" },
    { from = "b", to = "c" },
    { from = "c", to = "a" },
  }
  H.eq(graph.find_cycle(nodes, edges, function()
    return true
  end), { "a", "b", "c", "a" })
  H.eq(graph.find_cycle(nodes, edges, function(node)
    return node ~= "b"
  end), nil)
end

return T
