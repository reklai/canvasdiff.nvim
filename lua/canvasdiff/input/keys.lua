-- The single source of truth for every keymap the plugin installs.
--
-- Consumed by App's canvas keymaps and sidebar.open (to install the maps,
-- with a desc), and later by the `?` cheatsheet and the generated helpfile
-- section. Requires nothing, so tests and the doc generator can load it
-- standalone.
--
-- Handlers deliberately live with the code they drive, not here: this module
-- describes bindings, it does not perform them.

local K = {}

--- One entry per ACTION -- an action may resolve to several keys.
---
--- ctx    which buffer it lives on; also the sub-table of config.keymaps
--- action key into that sub-table, and into the caller's handler table
--- group  section header in the cheatsheet and the helpfile
--- desc   `desc=` on vim.keymap.set, and the cheatsheet text
K.specs = {
  { ctx = "global", action = "compare", group = "Global",
    desc = "Compare two branches or revisions" },
  { ctx = "global", action = "checkout", group = "Global",
    desc = "Checkout a local branch" },

  { ctx = "canvas", action = "next_file",  group = "Navigate", desc = "Next file (lands on folded ones too)" },
  { ctx = "canvas", action = "prev_file",  group = "Navigate", desc = "Previous file (lands on folded ones too)" },
  { ctx = "canvas", action = "next_hunk",  group = "Navigate", desc = "Next hunk (a folded file counts as one)" },
  { ctx = "canvas", action = "prev_hunk",  group = "Navigate", desc = "Previous hunk (a folded file counts as one)" },
  { ctx = "canvas", action = "cycle_next", group = "Navigate", desc = "Scroll to the next hunk (wraps; a folded file is one stop)" },
  { ctx = "canvas", action = "cycle_prev", group = "Navigate", desc = "Scroll to the previous hunk (wraps; a folded file is one stop)" },
  -- The file axis the two above used to walk. Shipped unbound, so restoring
  -- the previous behaviour is one config line on whatever key you prefer.
  { ctx = "canvas", action = "cycle_file_next", group = "Navigate", desc = "Scroll to the next file (wraps)" },
  { ctx = "canvas", action = "cycle_file_prev", group = "Navigate", desc = "Scroll to the previous file (wraps)" },

  { ctx = "canvas", action = "jump",       group = "Jump",     desc = "Open the file under the cursor (never changes its fold)" },
  { ctx = "file",   action = "back",       group = "Jump",     desc = "Return to the canvas at the same spot" },

  { ctx = "canvas", action = "collapse",   group = "View",     desc = "Fold or unfold this file (unfolds the directory when that is what hides it)" },
  { ctx = "canvas", action = "lens_next",  group = "View",     desc = "Next lens: all / unstaged / staged (exits a READ-ONLY range)" },
  { ctx = "canvas", action = "lens_prev",  group = "View",     desc = "Previous lens (exits a READ-ONLY range)" },
  { ctx = "canvas", action = "sidebar",    group = "View",     desc = "Toggle the sidebar" },

  { ctx = "canvas", action = "refresh", group = "Canvas",
    desc = "Refresh the current diff" },
  { ctx = "canvas", action = "stage",   group = "Canvas",  desc = "Stage this hunk — or this file on its header" },
  { ctx = "canvas", action = "unstage", group = "Canvas",  desc = "Unstage this hunk — or this file on its header" },
  { ctx = "canvas", action = "stage_file",   group = "Canvas", desc = "Stage this file's changes (from anywhere in it)" },
  { ctx = "canvas", action = "unstage_file", group = "Canvas", desc = "Unstage this file (from anywhere in it)" },
  { ctx = "canvas", action = "close",      group = "Canvas",   desc = "Back out: leave a stacked comparison, else close the canvas" },

  { ctx = "sidebar", action = "select",    group = "Sidebar",  desc = "Scroll the canvas here / fold a directory (folds its files on the canvas too)" },
  { ctx = "sidebar", action = "stage",   group = "Sidebar", desc = "Stage this file's changes" },
  { ctx = "sidebar", action = "unstage", group = "Sidebar", desc = "Unstage this file" },
  { ctx = "sidebar", action = "close",     group = "Sidebar",  desc = "Close the sidebar (canvas stays open)" },

  { ctx = "canvas",  action = "help", group = "Canvas",  desc = "Show keybind cheatsheet" },
  { ctx = "sidebar", action = "help", group = "Sidebar", desc = "Show keybind cheatsheet" },
}

--- Display order of the cheatsheet / helpfile sections.
K.group_order = { "Global", "Navigate", "Jump", "View", "Canvas", "Sidebar" }

--- Normalize a config value to a list of lhs strings.
--- nil / false / "" / {} all mean "disabled" and yield {}.
--- Returns a copy, so callers can never mutate live config.
function K.list(v)
  if v == nil or v == false or v == "" then
    return {}
  end
  if type(v) == "string" then
    return { v }
  end
  if type(v) ~= "table" then
    return {}
  end
  local out = {}
  for i, s in ipairs(v) do
    out[i] = s
  end
  return out
end

--- Every binding for `ctx`, one entry PER KEY -- the form needed to install
--- maps, since each key is its own vim.keymap.set call.
--- @return { action: string, lhs: string, desc: string, group: string }[]
function K.resolved(ctx, keymaps)
  local sub = (keymaps or {})[ctx] or {}
  local out = {}
  for _, spec in ipairs(K.specs) do
    if spec.ctx == ctx then
      for _, lhs in ipairs(K.list(sub[spec.action])) do
        out[#out + 1] = {
          action = spec.action, lhs = lhs, desc = spec.desc, group = spec.group,
        }
      end
    end
  end
  return out
end

--- Every binding across `ctxs`, one row PER ACTION with its keys collected --
--- the form needed for display, where a two-key action should read as one row
--- ("<Tab> za   Collapse or expand") rather than two.
--- Disabled actions are omitted entirely.
--- @return { name: string, items: { keys: string[], desc: string, action: string }[] }[]
function K.grouped(ctxs, keymaps)
  local by_group = {}
  for _, ctx in ipairs(ctxs) do
    local sub = (keymaps or {})[ctx] or {}
    for _, spec in ipairs(K.specs) do
      if spec.ctx == ctx then
        local lhs = K.list(sub[spec.action])
        if #lhs > 0 then
          by_group[spec.group] = by_group[spec.group] or {}
          table.insert(by_group[spec.group], {
            keys = lhs, desc = spec.desc, action = spec.action,
          })
        end
      end
    end
  end

  local out = {}
  for _, name in ipairs(K.group_order) do
    if by_group[name] then
      out[#out + 1] = { name = name, items = by_group[name] }
    end
  end
  return out
end

--- Keys claimed by more than one action within `ctx`. Whichever map is
--- installed last silently wins, so without this a user who reassigns a key
--- onto an existing one just sees the other action stop working.
--- @return { lhs: string, actions: string[] }[]
function K.collisions(ctx, keymaps)
  local order, by_lhs = {}, {}
  for _, m in ipairs(K.resolved(ctx, keymaps)) do
    if not by_lhs[m.lhs] then
      by_lhs[m.lhs] = {}
      order[#order + 1] = m.lhs
    end
    table.insert(by_lhs[m.lhs], m.action)
  end

  local out = {}
  for _, lhs in ipairs(order) do
    if #by_lhs[lhs] > 1 then
      out[#out + 1] = { lhs = lhs, actions = by_lhs[lhs] }
    end
  end
  return out
end

return K
