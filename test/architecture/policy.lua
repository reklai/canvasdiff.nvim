local graph = require("architecture.graph")
local rules = require("architecture.rules")

local P = {}

local function group_for(inspection, node)
  local metadata = inspection.nodes[node]
  return metadata and rules.classify(metadata.rel) or nil
end

function P.edge_violations(inspection)
  local errors = {}

  for _, edge in ipairs(inspection.edges) do
    local from_group = group_for(inspection, edge.from)
    local to_group = group_for(inspection, edge.to)

    if not from_group then
      errors[#errors + 1] = ("%s:%d: source module has no architectural owner"):format(
        edge.from_path,
        edge.line
      )
    elseif not to_group then
      errors[#errors + 1] = ("%s:%d: target module %q has no architectural owner"):format(
        edge.from_path,
        edge.line,
        edge.to
      )
    elseif from_group ~= "legacy" and to_group ~= "legacy" and from_group ~= to_group then
      local allowed = rules.allowed_edges[from_group]
        and rules.allowed_edges[from_group][to_group]
      if not allowed then
        errors[#errors + 1] = (
          "%s:%d: forbidden dependency %s -> %s (%s -> %s)"
        ):format(
          edge.from_path,
          edge.line,
          edge.from,
          edge.to,
          from_group,
          to_group
        )
      end

      local facade = rules.facade_module(to_group)
      if not facade or edge.to ~= facade then
        errors[#errors + 1] = (
          "%s:%d: cross-domain dependency on %s must target facade %s"
        ):format(edge.from_path, edge.line, edge.to, facade or "<none>")
      end
    end
  end

  table.sort(errors)
  return errors
end

function P.find_cycle(inspection)
  return graph.find_cycle(inspection.nodes, inspection.edges, function(node)
    local group = group_for(inspection, node)
    return group ~= nil and group ~= "legacy"
  end)
end

return P
