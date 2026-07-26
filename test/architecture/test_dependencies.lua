local H = require("helpers")
local graph = require("architecture.graph")
local policy = require("architecture.policy")

local T = {}

local function inspect_repo()
  return graph.inspect(graph.root)
end

local function assert_no_errors(errors, heading)
  table.sort(errors)
  assert(#errors == 0, heading .. ":\n- " .. table.concat(errors, "\n- "))
end

T.architecture_dependencies_are_static_resolved_and_unambiguous = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
end

T.architecture_dependencies_cross_domains_only_through_allowed_facades = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  assert_no_errors(policy.edge_violations(inspection), "architecture dependency violations")
end

T.architecture_dependencies_new_domain_graph_is_acyclic = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  local cycle = policy.find_cycle(inspection)
  assert(not cycle, "architecture dependency cycle: " .. table.concat(cycle or {}, " -> "))
end

T.architecture_watch_is_a_producer_not_a_ui_fanout_hub = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")

  local forbidden = {
    ["galley.hl"] = true,
    ["galley.scrollbar"] = true,
    ["galley.sidebar"] = true,
    ["galley.virt"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "galley.watch" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "watch must report model changes through its owner")
end

T.architecture_virtualizer_is_not_a_peer_controller_fanout_hub = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")

  local forbidden = {
    ["galley.hl"] = true,
    ["galley.scrollbar"] = true,
    ["galley.sidebar"] = true,
    ["galley.watch"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "galley.virt" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "virtualizer must report shape changes through its owner")
end

T.architecture_status_column_has_no_peer_controller_edges = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")

  local forbidden = {
    ["galley.hl"] = true,
    ["galley.scrollbar"] = true,
    ["galley.sidebar"] = true,
    ["galley.virt"] = true,
    ["galley.watch"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "galley.statuscol" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "status column must be composed by its Surface owner")
end

T.architecture_highlighter_has_no_peer_controller_edges = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")

  local forbidden = {
    ["galley.scrollbar"] = true,
    ["galley.sidebar"] = true,
    ["galley.statuscol"] = true,
    ["galley.virt"] = true,
    ["galley.watch"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "galley.hl" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "highlighter must report through its Surface owner")
end

T.architecture_sidebar_has_no_peer_controller_edges = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")

  local forbidden = {
    ["galley.hl"] = true,
    ["galley.jump"] = true,
    ["galley.motions"] = true,
    ["galley.scrollbar"] = true,
    ["galley.statuscol"] = true,
    ["galley.virt"] = true,
    ["galley.watch"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "galley.sidebar" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "sidebar must be composed by its Surface owner")
end

T.architecture_jump_has_no_peer_controller_edges = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")

  local forbidden = {
    ["galley.hl"] = true,
    ["galley.scrollbar"] = true,
    ["galley.sidebar"] = true,
    ["galley.statuscol"] = true,
    ["galley.virt"] = true,
    ["galley.watch"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "galley.jump" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations,
    "jump must publish one shape change for its Surface owner to compose")
end

T.architecture_dependencies_policy_rejects_internal_and_reverse_edges = function()
  local nodes = {
    ["galley.canvas.Page"] = { rel = "lua/galley/canvas/Page.lua" },
    ["galley.input"] = { rel = "lua/galley/input.lua" },
    ["galley.ui"] = { rel = "lua/galley/ui.lua" },
    ["galley.ui.sidebar"] = { rel = "lua/galley/ui/sidebar.lua" },
    ["galley.util"] = { rel = "lua/galley/util.lua" },
  }

  local allowed = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "galley.ui.sidebar",
        from_path = nodes["galley.ui.sidebar"].rel,
        line = 1,
        to = "galley.input",
        to_path = nodes["galley.input"].rel,
      },
      {
        from = "galley.util",
        from_path = nodes["galley.util"].rel,
        line = 2,
        to = "galley.ui.sidebar",
        to_path = nodes["galley.ui.sidebar"].rel,
      },
    },
  })
  H.eq(allowed, {})

  local internal = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "galley.ui.sidebar",
        from_path = nodes["galley.ui.sidebar"].rel,
        line = 3,
        to = "galley.canvas.Page",
        to_path = nodes["galley.canvas.Page"].rel,
      },
    },
  })
  H.eq(#internal, 1)
  assert(internal[1]:find("must target facade galley.canvas", 1, true), internal[1])

  local reverse = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "galley.canvas.Page",
        from_path = nodes["galley.canvas.Page"].rel,
        line = 4,
        to = "galley.ui",
        to_path = nodes["galley.ui"].rel,
      },
    },
  })
  H.eq(#reverse, 1)
  assert(reverse[1]:find("forbidden dependency", 1, true), reverse[1])
end

T.architecture_dependencies_policy_finds_cycles_but_excludes_legacy = function()
  local nodes = {
    ["galley.input"] = { rel = "lua/galley/input.lua" },
    ["galley.ui"] = { rel = "lua/galley/ui.lua" },
    ["galley.util"] = { rel = "lua/galley/util.lua" },
  }
  local inspection = {
    nodes = nodes,
    edges = {
      { from = "galley.input", to = "galley.ui" },
      { from = "galley.ui", to = "galley.input" },
      { from = "galley.util", to = "galley.ui" },
      { from = "galley.ui", to = "galley.util" },
    },
  }

  H.eq(policy.find_cycle(inspection), {
    "galley.input",
    "galley.ui",
    "galley.input",
  })

  inspection.edges = {
    { from = "galley.util", to = "galley.ui" },
    { from = "galley.ui", to = "galley.util" },
  }
  H.eq(policy.find_cycle(inspection), nil)
end

return T
