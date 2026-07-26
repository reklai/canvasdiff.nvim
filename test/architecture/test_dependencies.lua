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

local function assert_inspected_module(inspection, module)
  assert(
    inspection.nodes[module],
    ("architecture contract source %s is missing; update the contract with its move"):format(module)
  )
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
  assert_inspected_module(inspection, "canvasdiff.watch")

  local forbidden = {
    ["canvasdiff.hl"] = true,
    ["canvasdiff.scrollbar"] = true,
    ["canvasdiff.sidebar"] = true,
    ["canvasdiff.virt"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "canvasdiff.watch" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "watch must report model changes through its owner")
end

T.architecture_virtualizer_is_not_a_peer_controller_fanout_hub = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  assert_inspected_module(inspection, "canvasdiff.virt")

  local forbidden = {
    ["canvasdiff.hl"] = true,
    ["canvasdiff.scrollbar"] = true,
    ["canvasdiff.sidebar"] = true,
    ["canvasdiff.watch"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "canvasdiff.virt" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "virtualizer must report shape changes through its owner")
end

T.architecture_status_column_has_no_peer_controller_edges = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  assert_inspected_module(inspection, "canvasdiff.statuscol")

  local forbidden = {
    ["canvasdiff.hl"] = true,
    ["canvasdiff.scrollbar"] = true,
    ["canvasdiff.sidebar"] = true,
    ["canvasdiff.virt"] = true,
    ["canvasdiff.watch"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "canvasdiff.statuscol" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "status column must be composed by its Surface owner")
end

T.architecture_highlighter_has_no_peer_controller_edges = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  assert_inspected_module(inspection, "canvasdiff.hl")

  local forbidden = {
    ["canvasdiff.scrollbar"] = true,
    ["canvasdiff.sidebar"] = true,
    ["canvasdiff.statuscol"] = true,
    ["canvasdiff.virt"] = true,
    ["canvasdiff.watch"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "canvasdiff.hl" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "highlighter must report through its Surface owner")
end

T.architecture_sidebar_has_no_peer_controller_edges = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  assert_inspected_module(inspection, "canvasdiff.sidebar")

  local forbidden = {
    ["canvasdiff.hl"] = true,
    ["canvasdiff.jump"] = true,
    ["canvasdiff.motions"] = true,
    ["canvasdiff.scrollbar"] = true,
    ["canvasdiff.statuscol"] = true,
    ["canvasdiff.virt"] = true,
    ["canvasdiff.watch"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "canvasdiff.sidebar" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "sidebar must be composed by its Surface owner")
end

T.architecture_jump_has_no_peer_controller_edges = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  assert_inspected_module(inspection, "canvasdiff.jump")

  local forbidden = {
    ["canvasdiff.hl"] = true,
    ["canvasdiff.scrollbar"] = true,
    ["canvasdiff.sidebar"] = true,
    ["canvasdiff.statuscol"] = true,
    ["canvasdiff.virt"] = true,
    ["canvasdiff.watch"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == "canvasdiff.jump" and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations,
    "jump must publish one shape change for its Surface owner to compose")
end

T.architecture_dependencies_policy_rejects_internal_and_reverse_edges = function()
  local nodes = {
    ["canvasdiff.canvas.Page"] = { rel = "lua/canvasdiff/canvas/Page.lua" },
    ["canvasdiff.diff"] = { rel = "lua/canvasdiff/diff.lua" },
    ["canvasdiff.diff.model"] = { rel = "lua/canvasdiff/diff/model.lua" },
    ["canvasdiff.input"] = { rel = "lua/canvasdiff/input.lua" },
    ["canvasdiff.ui"] = { rel = "lua/canvasdiff/ui.lua" },
    ["canvasdiff.ui.sidebar"] = { rel = "lua/canvasdiff/ui/sidebar.lua" },
    ["canvasdiff.util"] = { rel = "lua/canvasdiff/util.lua" },
  }

  local allowed = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.ui.sidebar",
        from_path = nodes["canvasdiff.ui.sidebar"].rel,
        line = 1,
        to = "canvasdiff.input",
        to_path = nodes["canvasdiff.input"].rel,
      },
      {
        from = "canvasdiff.util",
        from_path = nodes["canvasdiff.util"].rel,
        line = 2,
        to = "canvasdiff.ui.sidebar",
        to_path = nodes["canvasdiff.ui.sidebar"].rel,
      },
    },
  })
  H.eq(allowed, {})

  local internal = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.ui.sidebar",
        from_path = nodes["canvasdiff.ui.sidebar"].rel,
        line = 3,
        to = "canvasdiff.canvas.Page",
        to_path = nodes["canvasdiff.canvas.Page"].rel,
      },
    },
  })
  H.eq(#internal, 1)
  assert(internal[1]:find("must target facade canvasdiff.canvas", 1, true), internal[1])

  local diff_internal = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.canvas.Page",
        from_path = nodes["canvasdiff.canvas.Page"].rel,
        line = 4,
        to = "canvasdiff.diff.model",
        to_path = nodes["canvasdiff.diff.model"].rel,
      },
    },
  })
  H.eq(#diff_internal, 1)
  assert(
    diff_internal[1]:find("must target facade canvasdiff.diff", 1, true),
    diff_internal[1]
  )

  local input_presentation = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.input",
        from_path = nodes["canvasdiff.input"].rel,
        line = 5,
        to = "canvasdiff.ui",
        to_path = nodes["canvasdiff.ui"].rel,
      },
    },
  })
  H.eq(#input_presentation, 1)
  assert(
    input_presentation[1]:find("forbidden dependency", 1, true),
    input_presentation[1]
  )

  local reverse = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.canvas.Page",
        from_path = nodes["canvasdiff.canvas.Page"].rel,
        line = 6,
        to = "canvasdiff.ui",
        to_path = nodes["canvasdiff.ui"].rel,
      },
    },
  })
  H.eq(#reverse, 1)
  assert(reverse[1]:find("forbidden dependency", 1, true), reverse[1])
end

T.architecture_dependencies_policy_finds_cycles_but_excludes_legacy = function()
  local nodes = {
    ["canvasdiff.input"] = { rel = "lua/canvasdiff/input.lua" },
    ["canvasdiff.ui"] = { rel = "lua/canvasdiff/ui.lua" },
    ["canvasdiff.util"] = { rel = "lua/canvasdiff/util.lua" },
  }
  local inspection = {
    nodes = nodes,
    edges = {
      { from = "canvasdiff.input", to = "canvasdiff.ui" },
      { from = "canvasdiff.ui", to = "canvasdiff.input" },
      { from = "canvasdiff.util", to = "canvasdiff.ui" },
      { from = "canvasdiff.ui", to = "canvasdiff.util" },
    },
  }

  H.eq(policy.find_cycle(inspection), {
    "canvasdiff.input",
    "canvasdiff.ui",
    "canvasdiff.input",
  })

  inspection.edges = {
    { from = "canvasdiff.util", to = "canvasdiff.ui" },
    { from = "canvasdiff.ui", to = "canvasdiff.util" },
  }
  H.eq(policy.find_cycle(inspection), nil)
end

return T
