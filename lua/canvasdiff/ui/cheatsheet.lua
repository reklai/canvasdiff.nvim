-- Centered floating cheatsheet listing every keybind the plugin installs.
--
-- A renderer over input.keys + config.keymaps -- this module introduces no
-- new source of keybind truth, so whatever the user overrode, disabled, or
-- multi-bound is exactly what appears. The column model is pure and separate
-- from rendering, so tests can assert placement without a UI.

local keys = require("canvasdiff.input").keys

local M = {}

--- Per-context view of grouped(): action -> row, plus display order.
local function ctx_actions(ctx, keymaps)
  local by_action, order = {}, {}
  for _, g in ipairs(keys.grouped({ ctx }, keymaps)) do
    for _, item in ipairs(g.items) do
      by_action[item.action] = { keys = item.keys, desc = item.desc, group = g.name }
      order[#order + 1] = item.action
    end
  end
  return by_action, order
end

--- One flat unnamed section, or nothing when there are no rows.
local function flat_column(title, rows)
  if #rows == 0 then
    return nil
  end
  return { title = title, sections = { { name = nil, rows = rows } } }
end

--- Canvas keeps its group sub-headers (it is the largest column); order of
--- appearance already follows K.group_order via grouped().
local function grouped_column(title, by_action, order, skip)
  local sections, index = {}, {}
  for _, action in ipairs(order) do
    if not skip[action] then
      local a = by_action[action]
      local sec = index[a.group]
      if not sec then
        sec = { name = a.group, rows = {} }
        index[a.group] = sec
        sections[#sections + 1] = sec
      end
      sec.rows[#sec.rows + 1] = { keys = a.keys, desc = a.desc, action = action }
    end
  end
  if #sections == 0 then
    return nil
  end
  return { title = title, sections = sections }
end

--- Column model for the overlay: `Global | Sidebar | Canvas`.
---
--- Global holds actions available in more than one context with identical
--- keys -- computed, not hardcoded, so a user who diverges e.g. the sidebar
--- close key sees it split honestly into the per-context columns. The
--- file-context `back` binding is global by fiat: it applies outside the
--- plugin's own windows. Empty columns are omitted.
function M.model(keymaps)
  local canvas, canvas_order = ctx_actions("canvas", keymaps)
  local side, side_order = ctx_actions("sidebar", keymaps)
  local file, file_order = ctx_actions("file", keymaps)

  local shared, global_rows = {}, {}
  for _, action in ipairs(canvas_order) do
    local c, s = canvas[action], side[action]
    if s and vim.deep_equal(c.keys, s.keys) then
      shared[action] = true
      global_rows[#global_rows + 1] = { keys = c.keys, desc = c.desc, action = action }
    end
  end
  for _, action in ipairs(file_order) do
    local f = file[action]
    global_rows[#global_rows + 1] = { keys = f.keys, desc = f.desc, action = action }
  end

  local side_rows = {}
  for _, action in ipairs(side_order) do
    if not shared[action] then
      local s = side[action]
      side_rows[#side_rows + 1] = { keys = s.keys, desc = s.desc, action = action }
    end
  end

  local out = {}
  out[#out + 1] = flat_column("Global", global_rows)
  out[#out + 1] = flat_column("Sidebar", side_rows)
  out[#out + 1] = grouped_column("Canvas", canvas, canvas_order, shared)
  return out
end

return M
