local M = {}

local canvas = require("finding_myself.canvas")
local worddiff = require("finding_myself.worddiff")

local TS_NS = vim.api.nvim_create_namespace("finding_myself.canvas.ts")

-- Whole-file parse cache, keyed by section path. Capacity-bounded LRU so a
-- huge changeset can't pin every file's syntax tree in memory at once.
local CACHE_CAP = 20
local cache = {}          -- path -> { tick, old_src, old_tree, new_src, new_tree }
local cache_n, tick = 0, 0

local function evict_lru()
  local worst, worst_tick
  for p, e in pairs(cache) do
    if not worst_tick or e.tick < worst_tick then
      worst, worst_tick = p, e.tick
    end
  end
  if worst then
    cache[worst] = nil
    cache_n = cache_n - 1
  end
end

local function cache_entry(path)
  local e = cache[path]
  if not e then
    if cache_n >= CACHE_CAP then
      evict_lru()
    end
    e = {}
    cache[path] = e
    cache_n = cache_n + 1
  end
  tick = tick + 1
  e.tick = tick
  return e
end

--- Drop the cached trees for `path` (its content changed).
function M.invalidate(path)
  if cache[path] then
    cache[path] = nil
    cache_n = cache_n - 1
  end
end

--- Test-only: current number of cached paths.
function M._cache_size()
  return cache_n
end

--- Treesitter language for a repo-relative path, or nil when the filetype is
--- unknown, no parser is installed, or the language has no highlights query.
function M.lang_for(path)
  local ft = vim.filetype.match({ filename = path })
  if not ft or ft == "" then
    return nil
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if not pcall(vim.treesitter.language.add, lang) then
    return nil
  end
  local ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not ok or not query then
    return nil
  end
  return lang
end

--- Parse (or reuse) the tree for one side of a cached path. `src` identity is
--- the invalidation check: a replaced section arrives with a fresh string.
local function side_tree(entry, side, src, lang)
  local src_key, tree_key = side .. "_src", side .. "_tree"
  if entry[src_key] ~= src then
    entry[src_key] = src
    if src == "" then
      entry[tree_key] = nil
    else
      local parser = vim.treesitter.get_string_parser(src, lang)
      entry[tree_key] = parser:parse(true)[1]
    end
  end
  return entry[tree_key]
end

--- Treesitter highlight marks for one section, as pure data:
--- { row = 0-based section-relative, col, end_col (byte, incl. the 1-byte
--- rendered prefix), group = "@<capture>.<lang>", priority = 110 }.
--- ctx/add rows are colored from new_text, del rows from old_text; header
--- rows get nothing. Multi-row captures are clipped per displayed row.
function M.section_ts_marks(section)
  local lang = M.lang_for(section.path)
  if not lang then
    return {}
  end
  local query = vim.treesitter.query.get(lang, "highlights")
  local entry = cache_entry(section.path)

  local marks = {}

  local function side_marks(side)
    local src = (side == "new") and (section.new_text or "") or (section.old_text or "")
    if src == "" then
      return
    end

    -- source lnum (1-based) -> section-relative 0-based row
    local rows, lo, hi = {}, nil, nil
    for i, e in ipairs(section.entries) do
      local lnum
      if side == "new" then
        lnum = (e.kind == "ctx" or e.kind == "add") and e.new_lnum or nil
      else
        lnum = (e.kind == "del") and e.old_lnum or nil
      end
      if lnum then
        rows[lnum] = i - 1
        lo = math.min(lo or lnum, lnum)
        hi = math.max(hi or lnum, lnum)
      end
    end
    if not lo then
      return
    end

    local tree = side_tree(entry, side, src, lang)
    if not tree then
      return
    end

    local src_lines
    for id, node in query:iter_captures(tree:root(), src, lo - 1, hi) do
      local sr, sc, er, ec = node:range()
      for r = math.max(sr, lo - 1), math.min(er, hi - 1) do
        local brow = rows[r + 1]
        if brow then
          local scol = (r == sr) and sc or 0
          local ecol
          if r == er then
            ecol = ec
          else
            src_lines = src_lines or vim.split(src, "\n", { plain = true })
            ecol = #(src_lines[r + 1] or "")
          end
          if ecol > scol then
            marks[#marks + 1] = {
              row = brow,
              col = scol + 1,
              end_col = ecol + 1,
              group = "@" .. query.captures[id] .. "." .. lang,
              priority = 110,
            }
          end
        end
      end
    end
  end

  side_marks("new")
  side_marks("old")
  return marks
end

local function ensure_hl_groups()
  vim.api.nvim_set_hl(0, "FmWordAdd", { link = "DiffText", default = true })
  vim.api.nvim_set_hl(0, "FmWordDel", { link = "DiffText", default = true })
end

local live_state

local function del_path_marks(state, path)
  local ids = state.ts.ids_by_path[path]
  if not ids then
    return
  end
  for _, id in ipairs(ids) do
    pcall(vim.api.nvim_buf_del_extmark, state.buf, TS_NS, id)
  end
  state.ts.ids_by_path[path] = nil
end

local function apply_section(state, i)
  local sec = state.sections[i]
  local srow = (canvas.section_rows(state, i))
  local ids = {}
  local function place(list)
    for _, m in ipairs(list) do
      ids[#ids + 1] = vim.api.nvim_buf_set_extmark(state.buf, TS_NS, srow + m.row, m.col, {
        end_row = srow + m.row,
        end_col = m.end_col,
        hl_group = m.group,
        priority = m.priority,
        strict = false,
      })
    end
  end
  place(M.section_ts_marks(sec))
  place(worddiff.section_marks(sec))
  state.ts.ids_by_path[sec.path] = ids
end

--- Synchronously apply marks for sections within viewport±margin and evict
--- applied sections fully outside 2x margin. Safe to call any time; no-ops
--- when highlighting isn't attached or the canvas isn't showing.
function M.apply_now(state)
  local ts = state.ts
  if not ts or state ~= live_state then
    return
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_win_get_buf(state.win) == state.buf) then
    return
  end
  local info = vim.api.nvim_win_call(state.win, function()
    return { top0 = vim.fn.line("w0") - 1, bot0 = vim.fn.line("w$") - 1 }
  end)
  local lo, hi = info.top0 - ts.margin, info.bot0 + ts.margin
  local evict_lo, evict_hi = info.top0 - 2 * ts.margin, info.bot0 + 2 * ts.margin

  for i, sec in ipairs(state.sections) do
    local srow, erow = canvas.section_rows(state, i)
    -- srow/erow are nil when this state's anchors don't resolve against its
    -- own buffer right now (e.g. a BufWinEnter fired for a buffer some
    -- other, unrelated state table has since re-rendered without going
    -- through this state's bookkeeping). Nothing safe to do; skip it.
    if srow and erow then
      local in_window = srow <= hi and erow > lo
      local has = ts.ids_by_path[sec.path] ~= nil
      if in_window and not has then
        apply_section(state, i)
      elseif has and (erow <= evict_lo or srow > evict_hi) then
        del_path_marks(state, sec.path)
      end
    end
  end
end

local timer

local function debounce(state, ms)
  if not timer then
    timer = vim.uv.new_timer()
  end
  timer:stop()
  timer:start(ms, 0, vim.schedule_wrap(function()
    M.apply_now(state)
  end))
end

--- Attach lazy treesitter+word highlighting to a live canvas state: install
--- invalidation hooks, a debounced WinScrolled trigger, and apply once now.
function M.attach(state, opts)
  if timer then
    timer:stop()
  end
  opts = opts or {}
  ensure_hl_groups()
  state.ts = {
    ids_by_path = {},
    margin = opts.margin or 100,
    debounce_ms = opts.debounce_ms or 30,
  }
  live_state = state

  -- A cached canvas buffer can carry a previous session's marks (render_all
  -- ran before this attach installed the clearing hook, collapsing them onto
  -- one row instead of deleting them). Start from a clean namespace.
  vim.api.nvim_buf_clear_namespace(state.buf, TS_NS, 0, -1)

  state.hooks = state.hooks or {}
  state.hooks.on_render_all = function()
    vim.api.nvim_buf_clear_namespace(state.buf, TS_NS, 0, -1)
    state.ts.ids_by_path = {}
  end
  state.hooks.on_section_replaced = function(path)
    del_path_marks(state, path)
    M.invalidate(path)
  end

  local aug = vim.api.nvim_create_augroup("finding_myself.hl", { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = aug,
    callback = function(ev)
      local win = tonumber(ev.match)
      if win and vim.api.nvim_win_is_valid(win)
          and vim.api.nvim_win_get_buf(win) == state.buf then
        debounce(state, state.ts.debounce_ms)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = aug,
    buffer = state.buf,
    callback = function()
      -- A window just started showing the canvas; sections spliced while it
      -- was hidden had their marks invalidated with nobody to re-apply.
      state.win = vim.api.nvim_get_current_win()
      M.apply_now(state)
    end,
  })

  M.apply_now(state)
end

--- Undo attach: remove the scroll trigger, cancel any pending debounce, and
--- release the live-state guard so a stale callback can never fire against
--- this state. Nil-safe; safe to call when never attached.
function M.detach(state)
  pcall(vim.api.nvim_del_augroup_by_name, "finding_myself.hl")
  if timer then
    timer:stop()
  end
  if live_state == state then
    live_state = nil
  end
end

return M
