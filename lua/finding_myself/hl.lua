local M = {}

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

return M
