local H = require("helpers")
local graph = require("architecture.graph")
local policy = require("architecture.policy")

local T = {}

local RUNTIME_FACADE = "canvasdiff.runtime"
local VIRTUALIZER_OWNER = "canvasdiff.runtime.virtualizer"
local WATCH_OWNER = "canvasdiff.runtime.watch"
local SESSION_FACADE = "canvasdiff.session"
local SESSION_CODEC_OWNER = "canvasdiff.session.codec"
local UI_FACADE = "canvasdiff.ui"
local SCROLLBAR_OWNER = "canvasdiff.ui.scrollbar"
local HIGHLIGHT_OWNER = "canvasdiff.ui.highlight"

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

local function literal_requires_in(file)
  local handle, err = io.open(file.abs, "rb")
  assert(handle, ("%s: could not read source: %s"):format(file.rel, err or ""))
  local source = handle:read("*a")
  handle:close()

  -- Tests intentionally contain a few computed require calls that exercise the
  -- graph parser's rejection path. For this cross-tree consumer audit, retain
  -- only statically spelled require targets and leave those negative fixtures
  -- alone.
  local tokens = graph.lex(source, file.rel)
  local dependencies = {}
  for index, token in ipairs(tokens) do
    if token.kind == "identifier" and token.value == "require" then
      local previous = tokens[index - 1]
      local is_member = previous
        and previous.kind == "symbol"
        and (previous.value == "." or previous.value == ":")
      if not is_member then
        local following = tokens[index + 1]
        local argument
        if following and following.kind == "symbol" and following.value == "(" then
          local candidate = tokens[index + 2]
          local closing = tokens[index + 3]
          if candidate and candidate.kind == "string"
              and closing and closing.kind == "symbol" and closing.value == ")" then
            argument = candidate
          end
        elseif following and following.kind == "string" then
          argument = following
        end
        if argument then
          dependencies[#dependencies + 1] = {
            line = token.line,
            module = argument.value,
          }
        end
      end
    end
  end
  return dependencies
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
  assert_inspected_module(inspection, WATCH_OWNER)

  local forbidden = {
    [HIGHLIGHT_OWNER] = true,
    [SCROLLBAR_OWNER] = true,
    ["canvasdiff.sidebar"] = true,
    [RUNTIME_FACADE] = true,
    [VIRTUALIZER_OWNER] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == WATCH_OWNER and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "watch must report model changes through its owner")
end

T.architecture_virtualizer_is_not_a_peer_controller_fanout_hub = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  assert_inspected_module(inspection, VIRTUALIZER_OWNER)

  local forbidden = {
    [HIGHLIGHT_OWNER] = true,
    [SCROLLBAR_OWNER] = true,
    ["canvasdiff.sidebar"] = true,
    [RUNTIME_FACADE] = true,
    [WATCH_OWNER] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == VIRTUALIZER_OWNER and forbidden[edge.to] then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "virtualizer must report shape changes through its owner")
end

T.architecture_runtime_internals_are_reached_only_through_the_facade = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  assert_inspected_module(inspection, RUNTIME_FACADE)
  assert_inspected_module(inspection, WATCH_OWNER)
  assert_inspected_module(inspection, VIRTUALIZER_OWNER)

  local internal = {
    [WATCH_OWNER] = true,
    [VIRTUALIZER_OWNER] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if internal[edge.to] and edge.from ~= RUNTIME_FACADE then
      violations[#violations + 1] = edge.from .. " -> " .. edge.to
    end
  end

  assert_no_errors(violations, "runtime consumers must enter through canvasdiff.runtime")
end

T.architecture_session_internal_is_reached_only_through_the_facade = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  assert_inspected_module(inspection, SESSION_FACADE)
  assert_inspected_module(inspection, SESSION_CODEC_OWNER)

  local facade_edges = 0
  local violations = {}
  for _, file in ipairs(inspection.files) do
    for _, dependency in ipairs(literal_requires_in(file)) do
      if dependency.module:match("^canvasdiff%.session%.") then
        if file.rel == "lua/canvasdiff/session.lua" then
          facade_edges = facade_edges + 1
        else
          violations[#violations + 1] = (
            "%s:%d -> %s"
          ):format(file.rel, dependency.line, dependency.module)
        end
      end
    end
  end

  H.eq(facade_edges, 1, "the session facade must own the one internal codec edge")
  assert_no_errors(violations,
    "session production and test consumers must enter through canvasdiff.session")
end

T.architecture_ui_internals_are_reached_only_through_the_ui_facade = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  assert_inspected_module(inspection, UI_FACADE)
  assert_inspected_module(inspection, SCROLLBAR_OWNER)
  assert_inspected_module(inspection, HIGHLIGHT_OWNER)

  local facade_edges = {}
  local violations = {}
  for _, file in ipairs(inspection.files) do
    for _, dependency in ipairs(literal_requires_in(file)) do
      if dependency.module:match("^canvasdiff%.ui%.") then
        if file.rel == "lua/canvasdiff/ui.lua" then
          facade_edges[dependency.module] = (facade_edges[dependency.module] or 0) + 1
        else
          violations[#violations + 1] = (
            "%s:%d -> %s"
          ):format(file.rel, dependency.line, dependency.module)
        end
      end
    end
  end

  H.eq(facade_edges[SCROLLBAR_OWNER], 1, "the UI facade owns the one scrollbar edge")
  H.eq(facade_edges[HIGHLIGHT_OWNER], 1, "the UI facade owns the one highlighter edge")
  assert_no_errors(violations,
    "UI production and test consumers must enter through canvasdiff.ui")
end

T.architecture_status_column_has_no_peer_controller_edges = function()
  local inspection = inspect_repo()
  assert_no_errors(inspection.errors, "architecture dependency scan failed")
  assert_inspected_module(inspection, "canvasdiff.statuscol")

  local forbidden = {
    [HIGHLIGHT_OWNER] = true,
    [RUNTIME_FACADE] = true,
    [VIRTUALIZER_OWNER] = true,
    [WATCH_OWNER] = true,
    [SCROLLBAR_OWNER] = true,
    ["canvasdiff.sidebar"] = true,
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
  assert_inspected_module(inspection, HIGHLIGHT_OWNER)

  local forbidden = {
    [RUNTIME_FACADE] = true,
    [VIRTUALIZER_OWNER] = true,
    [WATCH_OWNER] = true,
    [SCROLLBAR_OWNER] = true,
    ["canvasdiff.sidebar"] = true,
    ["canvasdiff.statuscol"] = true,
  }
  local violations = {}
  for _, edge in ipairs(inspection.edges) do
    if edge.from == HIGHLIGHT_OWNER and forbidden[edge.to] then
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
    [HIGHLIGHT_OWNER] = true,
    ["canvasdiff.jump"] = true,
    ["canvasdiff.input.motions"] = true,
    [RUNTIME_FACADE] = true,
    [VIRTUALIZER_OWNER] = true,
    [WATCH_OWNER] = true,
    [SCROLLBAR_OWNER] = true,
    ["canvasdiff.statuscol"] = true,
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
    [HIGHLIGHT_OWNER] = true,
    [RUNTIME_FACADE] = true,
    [VIRTUALIZER_OWNER] = true,
    [WATCH_OWNER] = true,
    [SCROLLBAR_OWNER] = true,
    ["canvasdiff.sidebar"] = true,
    ["canvasdiff.statuscol"] = true,
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
    ["@benchmark/worker.lua"] = { rel = "benchmark/worker.lua" },
    ["canvasdiff.canvas"] = { rel = "lua/canvasdiff/canvas.lua" },
    ["canvasdiff.canvas.format"] = { rel = "lua/canvasdiff/canvas/format.lua" },
    ["canvasdiff.canvas.Page"] = { rel = "lua/canvasdiff/canvas/Page.lua" },
    ["canvasdiff.config"] = { rel = "lua/canvasdiff/config.lua" },
    ["canvasdiff.config.settings"] = { rel = "lua/canvasdiff/config/settings.lua" },
    ["canvasdiff.diff"] = { rel = "lua/canvasdiff/diff.lua" },
    ["canvasdiff.diff.model"] = { rel = "lua/canvasdiff/diff/model.lua" },
    ["canvasdiff.input"] = { rel = "lua/canvasdiff/input.lua" },
    ["canvasdiff.os"] = { rel = "lua/canvasdiff/os.lua" },
    ["canvasdiff.os.process"] = { rel = "lua/canvasdiff/os/process.lua" },
    ["canvasdiff.source"] = { rel = "lua/canvasdiff/source.lua" },
    ["canvasdiff.source.repository"] = {
      rel = "lua/canvasdiff/source/repository.lua",
    },
    ["canvasdiff.ui"] = { rel = "lua/canvasdiff/ui.lua" },
    ["canvasdiff.ui.sidebar"] = { rel = "lua/canvasdiff/ui/sidebar.lua" },
    ["canvasdiff.util"] = { rel = "lua/canvasdiff/util.lua" },
  }

  local allowed = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "@benchmark/worker.lua",
        from_path = nodes["@benchmark/worker.lua"].rel,
        line = 1,
        to = "canvasdiff.canvas",
        to_path = nodes["canvasdiff.canvas"].rel,
      },
      {
        from = "canvasdiff.ui.sidebar",
        from_path = nodes["canvasdiff.ui.sidebar"].rel,
        line = 2,
        to = "canvasdiff.input",
        to_path = nodes["canvasdiff.input"].rel,
      },
      {
        from = "canvasdiff.util",
        from_path = nodes["canvasdiff.util"].rel,
        line = 3,
        to = "canvasdiff.ui.sidebar",
        to_path = nodes["canvasdiff.ui.sidebar"].rel,
      },
      {
        from = "canvasdiff.source",
        from_path = nodes["canvasdiff.source"].rel,
        line = 4,
        to = "canvasdiff.os",
        to_path = nodes["canvasdiff.os"].rel,
      },
    },
  })
  H.eq(allowed, {})

  local benchmark_internal = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "@benchmark/worker.lua",
        from_path = nodes["@benchmark/worker.lua"].rel,
        line = 5,
        to = "canvasdiff.canvas.format",
        to_path = nodes["canvasdiff.canvas.format"].rel,
      },
    },
  })
  H.eq(#benchmark_internal, 1)
  assert(
    benchmark_internal[1]:find("must target facade canvasdiff.canvas", 1, true),
    benchmark_internal[1]
  )

  local internal = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.ui.sidebar",
        from_path = nodes["canvasdiff.ui.sidebar"].rel,
        line = 6,
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
        line = 7,
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

  local config_internal = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.canvas",
        from_path = nodes["canvasdiff.canvas"].rel,
        line = 8,
        to = "canvasdiff.config.settings",
        to_path = nodes["canvasdiff.config.settings"].rel,
      },
    },
  })
  H.eq(#config_internal, 1)
  assert(
    config_internal[1]:find("must target facade canvasdiff.config", 1, true),
    config_internal[1]
  )

  local config_presentation = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.config",
        from_path = nodes["canvasdiff.config"].rel,
        line = 9,
        to = "canvasdiff.ui",
        to_path = nodes["canvasdiff.ui"].rel,
      },
    },
  })
  H.eq(#config_presentation, 1)
  assert(
    config_presentation[1]:find("forbidden dependency", 1, true),
    config_presentation[1]
  )

  local os_internal = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.source",
        from_path = nodes["canvasdiff.source"].rel,
        line = 10,
        to = "canvasdiff.os.process",
        to_path = nodes["canvasdiff.os.process"].rel,
      },
    },
  })
  H.eq(#os_internal, 1)
  assert(
    os_internal[1]:find("must target facade canvasdiff.os", 1, true),
    os_internal[1]
  )

  local os_reverse = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.os",
        from_path = nodes["canvasdiff.os"].rel,
        line = 11,
        to = "canvasdiff.source",
        to_path = nodes["canvasdiff.source"].rel,
      },
    },
  })
  H.eq(#os_reverse, 1)
  assert(os_reverse[1]:find("forbidden dependency", 1, true), os_reverse[1])

  local source_internal = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.input",
        from_path = nodes["canvasdiff.input"].rel,
        line = 12,
        to = "canvasdiff.source.repository",
        to_path = nodes["canvasdiff.source.repository"].rel,
      },
    },
  })
  H.eq(#source_internal, 1)
  assert(
    source_internal[1]:find("must target facade canvasdiff.source", 1, true),
    source_internal[1]
  )

  local input_presentation = policy.edge_violations({
    nodes = nodes,
    edges = {
      {
        from = "canvasdiff.input",
        from_path = nodes["canvasdiff.input"].rel,
        line = 13,
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
        line = 14,
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
