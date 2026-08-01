local R = {}

R.package = "canvasdiff"

R.domains = {
  benchmark = true,
  canvas = true,
  config = true,
  diff = true,
  -- One file, no subdirectory: :checkhealth discovers by the fixed path
  -- lua/canvasdiff/health.lua, so the module cannot live inside a domain
  -- directory. It is a renderer over config.health -- hence its single edge.
  health = true,
  input = true,
  os = true,
  runtime = true,
  session = true,
  source = true,
  testing = true,
  ui = true,
}

-- Domains that are deliberately one file: the facade IS the owner, and no
-- subdirectory may accrete under them without revisiting this declaration.
-- health earns the exemption because :checkhealth discovers by the fixed
-- path lua/canvasdiff/health.lua.
R.single_file = {
  health = true,
}

-- Transitional debt ledger, now empty. Every module reached its owning domain,
-- and nothing may ever be added back: the ceiling below is what makes that
-- executable rather than a promise.
R.legacy_paths = {}

-- Immutable upper bound for the transition. Keeping this separate from the
-- active list makes "the ledger may only shrink" executable: migration
-- commits remove active entries but never broaden this ceiling.
R.legacy_ceiling = {
  ["lua/canvasdiff/canvas.lua"] = true,
  ["lua/canvasdiff/cmd.lua"] = true,
  ["lua/canvasdiff/collect.lua"] = true,
  ["lua/canvasdiff/config.lua"] = true,
  ["lua/canvasdiff/differ.lua"] = true,
  ["lua/canvasdiff/fold.lua"] = true,
  ["lua/canvasdiff/git.lua"] = true,
  ["lua/canvasdiff/hl.lua"] = true,
  ["lua/canvasdiff/init.lua"] = true,
  ["lua/canvasdiff/jump.lua"] = true,
  ["lua/canvasdiff/keys.lua"] = true,
  ["lua/canvasdiff/lens.lua"] = true,
  ["lua/canvasdiff/model.lua"] = true,
  ["lua/canvasdiff/motions.lua"] = true,
  ["lua/canvasdiff/render.lua"] = true,
  ["lua/canvasdiff/scrollbar.lua"] = true,
  ["lua/canvasdiff/session.lua"] = true,
  ["lua/canvasdiff/sidebar.lua"] = true,
  ["lua/canvasdiff/statuscol.lua"] = true,
  ["lua/canvasdiff/util.lua"] = true,
  ["lua/canvasdiff/viewport.lua"] = true,
  ["lua/canvasdiff/virt.lua"] = true,
  ["lua/canvasdiff/watch.lua"] = true,
  ["lua/canvasdiff/worddiff.lua"] = true,
}

R.legacy = {}
for _, path in ipairs(R.legacy_paths) do
  R.legacy[path] = true
end

-- PascalCase is reserved for concrete, stateful owners. This is deliberately
-- a path allowlist rather than a capitalization heuristic.
R.stateful_paths = {
  ["lua/canvasdiff/App.lua"] = true,
  ["lua/canvasdiff/Surface.lua"] = true,
  ["lua/canvasdiff/canvas/Canvas.lua"] = true,
  ["lua/canvasdiff/canvas/Page.lua"] = true,
  ["lua/canvasdiff/canvas/PageList.lua"] = true,
  ["lua/canvasdiff/canvas/Projection.lua"] = true,
  ["lua/canvasdiff/canvas/Scheduler.lua"] = true,
}

-- Direct edges only. Transitive reachability does not grant permission to
-- bypass a facade.
R.allowed_edges = {
  plugin = { root = true },
  root = { app = true },
  app = {
    surface = true,
    canvas = true,
    config = true,
    diff = true,
    input = true,
    os = true,
    runtime = true,
    session = true,
    source = true,
    ui = true,
  },
  surface = {
    canvas = true,
    config = true,
    diff = true,
    input = true,
    os = true,
    runtime = true,
    session = true,
    source = true,
    ui = true,
  },
  config = {},
  diff = {},
  health = { config = true },
  os = {},
  source = { config = true, diff = true, os = true },
  canvas = { config = true, diff = true, os = true },
  input = {
    canvas = true,
    config = true,
    diff = true,
    os = true,
    source = true,
  },
  ui = {
    canvas = true,
    config = true,
    diff = true,
    input = true,
    os = true,
  },
  runtime = {
    canvas = true,
    config = true,
    diff = true,
    os = true,
    source = true,
  },
  session = { canvas = true, config = true, diff = true, os = true },
  benchmark = {
    canvas = true,
    config = true,
    diff = true,
    input = true,
    os = true,
    root = true,
    runtime = true,
    session = true,
    source = true,
    ui = true,
  },
  testing = {
    canvas = true,
    config = true,
    diff = true,
    input = true,
    os = true,
    root = true,
    runtime = true,
    session = true,
    source = true,
    ui = true,
  },
}

function R.classify(path)
  if R.legacy[path] then
    return "legacy"
  end
  if path:match("^plugin/[^/]+%.lua$") then
    return "plugin"
  end
  if path:match("^benchmark/.+%.lua$") then
    return "benchmark"
  end
  if path == "lua/canvasdiff.lua" then
    return "root"
  end
  if path == "lua/canvasdiff/App.lua" then
    return "app"
  end
  if path == "lua/canvasdiff/Surface.lua" then
    return "surface"
  end

  local flat = path:match("^lua/canvasdiff/([^/]+)%.lua$")
  if flat and R.domains[flat] then
    return flat
  end

  local domain = path:match("^lua/canvasdiff/([^/]+)/.+%.lua$")
  if domain and R.domains[domain] then
    return domain
  end
  return nil
end

function R.facade_module(group)
  if group == "root" then
    return "canvasdiff"
  elseif group == "app" then
    return "canvasdiff.App"
  elseif group == "surface" then
    return "canvasdiff.Surface"
  elseif R.domains[group] then
    return "canvasdiff." .. group
  end
  return nil
end

return R
