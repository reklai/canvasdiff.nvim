local H = require("helpers")
local cheatsheet = require("canvasdiff.ui").cheatsheet
local config = require("canvasdiff.config")

local T = {}

local function defaults()
  return vim.deepcopy(config.defaults.keymaps)
end

--- { action = column_title } for every row in the model.
local function placement(model)
  local out = {}
  for _, col in ipairs(model) do
    for _, sec in ipairs(col.sections) do
      for _, row in ipairs(sec.rows) do
        out[row.action] = col.title
      end
    end
  end
  return out
end

T["cheatsheet_model puts identically-bound shared actions in Global"] = function()
  local model = cheatsheet.model(defaults())
  local where = placement(model)
  -- `close` is `q` on both canvas and sidebar; `back` is global by fiat.
  H.eq(where.close, "Global")
  H.eq(where.back, "Global")
  H.eq(where.select, "Sidebar")
  H.eq(where.jump, "Canvas")
  H.eq(where.refresh, "Canvas")
end

T["cheatsheet_model splits a diverged shared action into both context columns"] = function()
  local km = defaults()
  km.sidebar.close = "x" -- no longer identical to canvas `q`
  local model = cheatsheet.model(km)
  local seen = {}
  for _, col in ipairs(model) do
    for _, sec in ipairs(col.sections) do
      for _, row in ipairs(sec.rows) do
        if row.action == "close" then
          seen[col.title] = row.keys
        end
      end
    end
  end
  H.eq(seen["Global"], nil, "a diverged action must leave Global")
  H.eq(seen["Canvas"], { "q" })
  H.eq(seen["Sidebar"], { "x" })
end

T["cheatsheet_model column order is Global, Sidebar, Canvas"] = function()
  local titles = {}
  for _, col in ipairs(cheatsheet.model(defaults())) do
    titles[#titles + 1] = col.title
  end
  H.eq(titles, { "Global", "Sidebar", "Canvas" })
end

T["cheatsheet_model keeps group sub-headers only in the Canvas column"] = function()
  local model = cheatsheet.model(defaults())
  for _, col in ipairs(model) do
    if col.title == "Canvas" then
      local names = {}
      for _, sec in ipairs(col.sections) do names[#names + 1] = sec.name end
      -- Subset of K.group_order, in order; Navigate must be present.
      H.eq(names[1], "Navigate")
      for _, n in ipairs(names) do
        assert(type(n) == "string" and n ~= "", "canvas sections carry group names")
      end
    else
      H.eq(#col.sections, 1, col.title .. " is a flat list")
      H.eq(col.sections[1].name, nil, col.title .. " has no sub-header")
    end
  end
end

T["cheatsheet_model omits disabled actions and empty columns"] = function()
  local km = defaults()
  km.sidebar.select = false
  km.sidebar.close = "x" -- diverge close so Sidebar's only row would be close
  -- canvas.close stays at default "q", genuinely diverging close
  local model = cheatsheet.model(km)
  local where = placement(model)
  H.eq(where.select, nil, "a disabled action must not appear at all")
  -- Sidebar now has close only (diverged): column is present with exactly one row
  local sidebar_present = false
  for _, col in ipairs(model) do
    if col.title == "Sidebar" then
      sidebar_present = true
      H.eq(#col.sections[1].rows, 1, "Sidebar holds the diverged close row")
    end
  end
  H.eq(sidebar_present, true, "Sidebar column exists when holding a diverged row")
  -- Now disable that row:
  km.sidebar.close = false
  where = placement(cheatsheet.model(km))
  for _, col in ipairs(cheatsheet.model(km)) do
    assert(col.title ~= "Sidebar", "a column with no rows is omitted")
  end
end

T["cheatsheet_model reflects overridden keys, not defaults"] = function()
  local km = defaults()
  km.canvas.refresh = "R"
  local model = cheatsheet.model(km)
  for _, col in ipairs(model) do
    for _, sec in ipairs(col.sections) do
      for _, row in ipairs(sec.rows) do
        if row.action == "refresh" then
          H.eq(row.keys, { "R" }, "the override replaces the default list")
          return
        end
      end
    end
  end
  error("refresh must be in the model")
end

return T
