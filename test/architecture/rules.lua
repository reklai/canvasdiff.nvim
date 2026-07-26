local R = {}

R.package = "galley"

R.domains = {
  benchmark = true,
  canvas = true,
  config = true,
  diff = true,
  input = true,
  os = true,
  runtime = true,
  session = true,
  source = true,
  testing = true,
  ui = true,
}

-- Transitional debt ledger. Entries may only be removed. A module leaves this
-- list in the same commit that moves behind a domain facade; new flat modules
-- are never added here.
R.legacy_paths = {
  "lua/galley/canvas.lua",
  "lua/galley/cmd.lua",
  "lua/galley/collect.lua",
  "lua/galley/config.lua",
  "lua/galley/differ.lua",
  "lua/galley/fold.lua",
  "lua/galley/git.lua",
  "lua/galley/hl.lua",
  "lua/galley/jump.lua",
  "lua/galley/keys.lua",
  "lua/galley/lens.lua",
  "lua/galley/model.lua",
  "lua/galley/motions.lua",
  "lua/galley/render.lua",
  "lua/galley/scrollbar.lua",
  "lua/galley/session.lua",
  "lua/galley/sidebar.lua",
  "lua/galley/statuscol.lua",
  "lua/galley/util.lua",
  "lua/galley/viewport.lua",
  "lua/galley/virt.lua",
  "lua/galley/watch.lua",
  "lua/galley/worddiff.lua",
}

-- Immutable upper bound for the transition. Keeping this separate from the
-- active list makes "the ledger may only shrink" executable: migration
-- commits remove active entries but never broaden this ceiling.
R.legacy_ceiling = {
  ["lua/galley/canvas.lua"] = true,
  ["lua/galley/cmd.lua"] = true,
  ["lua/galley/collect.lua"] = true,
  ["lua/galley/config.lua"] = true,
  ["lua/galley/differ.lua"] = true,
  ["lua/galley/fold.lua"] = true,
  ["lua/galley/git.lua"] = true,
  ["lua/galley/hl.lua"] = true,
  ["lua/galley/init.lua"] = true,
  ["lua/galley/jump.lua"] = true,
  ["lua/galley/keys.lua"] = true,
  ["lua/galley/lens.lua"] = true,
  ["lua/galley/model.lua"] = true,
  ["lua/galley/motions.lua"] = true,
  ["lua/galley/render.lua"] = true,
  ["lua/galley/scrollbar.lua"] = true,
  ["lua/galley/session.lua"] = true,
  ["lua/galley/sidebar.lua"] = true,
  ["lua/galley/statuscol.lua"] = true,
  ["lua/galley/util.lua"] = true,
  ["lua/galley/viewport.lua"] = true,
  ["lua/galley/virt.lua"] = true,
  ["lua/galley/watch.lua"] = true,
  ["lua/galley/worddiff.lua"] = true,
}

R.legacy = {}
for _, path in ipairs(R.legacy_paths) do
  R.legacy[path] = true
end

-- PascalCase is reserved for concrete, stateful owners. This is deliberately
-- a path allowlist rather than a capitalization heuristic.
R.stateful_paths = {
  ["lua/galley/App.lua"] = true,
  ["lua/galley/Surface.lua"] = true,
  ["lua/galley/canvas/Canvas.lua"] = true,
  ["lua/galley/canvas/Page.lua"] = true,
  ["lua/galley/canvas/PageList.lua"] = true,
  ["lua/galley/canvas/Projection.lua"] = true,
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
  session = { config = true, diff = true, os = true },
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
  if path == "lua/galley.lua" then
    return "root"
  end
  if path == "lua/galley/App.lua" then
    return "app"
  end
  if path == "lua/galley/Surface.lua" then
    return "surface"
  end

  local flat = path:match("^lua/galley/([^/]+)%.lua$")
  if flat and R.domains[flat] then
    return flat
  end

  local domain = path:match("^lua/galley/([^/]+)/.+%.lua$")
  if domain and R.domains[domain] then
    return domain
  end
  return nil
end

function R.facade_module(group)
  if group == "root" then
    return "galley"
  elseif group == "app" then
    return "galley.App"
  elseif group == "surface" then
    return "galley.Surface"
  elseif R.domains[group] then
    return "galley." .. group
  end
  return nil
end

return R
