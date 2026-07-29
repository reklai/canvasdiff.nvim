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

--- The close row of every column, keyed by column title.
local function close_rows(model)
  local seen = {}
  for _, col in ipairs(model) do
    for _, sec in ipairs(col.sections) do
      for _, row in ipairs(sec.rows) do
        if row.action == "close" then
          seen[col.title] = row
        end
      end
    end
  end
  return seen
end

T["cheatsheet_model promotes to Global only on identical keys AND desc"] = function()
  local model = cheatsheet.model(defaults())
  local where = placement(model)
  -- `help` reads identically in both contexts; `back` is global by fiat.
  H.eq(where.help, "Global")
  H.eq(where.back, "Global")
  H.eq(where.select, "Sidebar")
  H.eq(where.jump, "Canvas")
  H.eq(where.refresh, "Canvas")
  H.eq(where.compare, "Global")
end

T["cheatsheet_model labels the process-wide compare mapping as Global"] = function()
  local model = cheatsheet.model(defaults())
  for _, col in ipairs(model) do
    if col.title == "Global" then
      for _, row in ipairs(col.sections[1].rows) do
        if row.action == "compare" then
          H.eq(row.keys, { "<leader>lb" })
          assert(row.desc:find("Compare", 1, true))
          return
        end
      end
    end
  end
  error("the global compare action must be discoverable in cheatsheet metadata")
end

T["cheatsheet_model close stays per column with its own meaning"] = function()
  -- `q` closes the whole review on the canvas but only the sidebar when
  -- pressed there. Same key, different meaning: no Global row -- each
  -- column says what the key does THERE.
  local seen = close_rows(cheatsheet.model(defaults()))
  H.eq(seen["Global"], nil, "differing descs must keep close out of Global")
  H.eq(seen["Canvas"].keys, { "q" })
  H.eq(seen["Sidebar"].keys, { "q" })
  assert(seen["Canvas"].desc:find("Close the canvas", 1, true),
    "canvas close describes the canvas: " .. seen["Canvas"].desc)
  assert(seen["Sidebar"].desc:find("Close the sidebar", 1, true),
    "sidebar close describes the sidebar: " .. seen["Sidebar"].desc)
end

T["cheatsheet_model a diverged key demotes a Global action to both columns"] = function()
  local km = defaults()
  km.sidebar.help = "g?" -- no longer identical to the canvas binding
  local seen = {}
  for _, col in ipairs(cheatsheet.model(km)) do
    for _, sec in ipairs(col.sections) do
      for _, row in ipairs(sec.rows) do
        if row.action == "help" then
          seen[col.title] = row.keys
        end
      end
    end
  end
  H.eq(seen["Global"], nil, "a diverged action must leave Global")
  H.eq(seen["Canvas"], { "<leader>lh" })
  H.eq(seen["Sidebar"], { "g?" })
end

T["cheatsheet_model a per-context override changes only its own column"] = function()
  local km = defaults()
  km.sidebar.close = "x"
  local seen = close_rows(cheatsheet.model(km))
  H.eq(seen["Canvas"].keys, { "q" })
  H.eq(seen["Sidebar"].keys, { "x" })
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
  local model = cheatsheet.model(km)
  local where = placement(model)
  H.eq(where.select, nil, "a disabled action must not appear at all")
  local sidebar_rows
  for _, col in ipairs(model) do
    if col.title == "Sidebar" then
      sidebar_rows = #col.sections[1].rows
    end
  end
  H.eq(sidebar_rows, 1, "Sidebar keeps its remaining row (close; help sits in Global)")
  -- Disable that too and the whole column goes:
  km.sidebar.close = false
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

T["cheatsheet_lines lays columns side by side when width allows"] = function()
  -- Hand-built small model that actually fits in 80 chars (real defaults are too wide for 200).
  local tiny = {
    { title = "Global", sections = { { name = nil, rows = { { keys = { "q" }, desc = "Close", action = "close" } } } } },
    { title = "Canvas", sections = { { name = "Nav", rows = { { keys = { "]f" }, desc = "Next", action = "next_file" } } } } },
  }
  local lines, spans, width = cheatsheet.lines(tiny, 80)
  assert(width <= 80)
  H.eq(lines[1]:match("Global") ~= nil, true, "first line carries the first column title")
  H.eq(lines[1]:match("Canvas") ~= nil, true, "titles share the line when side by side")
  assert(#spans > 0, "titles and keys carry highlight spans")
  for _, s in ipairs(spans) do
    assert(lines[s.line + 1] ~= nil and s.col_end <= #lines[s.line + 1],
      "span must lie inside its line")
  end
  -- Section name "Nav" appears on its own line in the Canvas block.
  local joined = table.concat(lines, "\n")
  assert(joined:find("Nav"), "section names appear in output")
end

T["cheatsheet_lines stacks columns on a narrow editor"] = function()
  -- Same small model, but max_width too small for side-by-side.
  local tiny = {
    { title = "Global", sections = { { name = nil, rows = { { keys = { "q" }, desc = "Close", action = "close" } } } } },
    { title = "Canvas", sections = { { name = "Nav", rows = { { keys = { "]f" }, desc = "Next", action = "next_file" } } } } },
  }
  local lines = cheatsheet.lines(tiny, 15)
  -- Stacking changes the layout, not the longest desc: width may still
  -- exceed 15 (toggle clamps the WINDOW; long lines scroll off, spec R5).
  H.eq(lines[1]:match("Global") ~= nil, true, "first line carries Global title")
  H.eq(lines[1]:match("Canvas"), nil, "Canvas title is not on the first line when stacked")
  local joined = table.concat(lines, "\n")
  assert(joined:find("Global") and joined:find("Canvas"),
    "all columns still present, vertically")
end

T["cheatsheet_lines one row per action with keys joined by spaces"] = function()
  local model = cheatsheet.model(defaults())
  local joined = table.concat((cheatsheet.lines(model, 200)), "\n")
  assert(joined:find("za c", 1, true), "multi-key collapse renders on one row")
  assert(joined:find("Re-scan", 1, true), "descs render next to their keys")
end

return T
