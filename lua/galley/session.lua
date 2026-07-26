local canvas = require("galley.canvas")
local viewport = require("galley.viewport")
local fold = require("galley.fold")
local lens = require("galley.lens")

local M = {}

local VERSION = 1

local function win_showing_canvas(state)
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

local function index_of_path(state, path)
  for i, sec in ipairs(state.sections) do
    if sec.path == path then
      return i
    end
  end
end

--- Where a root's session file lives on disk.
function M.path_for(root)
  return vim.fn.stdpath("state") .. "/galley/" .. vim.fn.sha256(root) .. ".json"
end

--- Persist `state`'s base/collapsed/folds and (when the canvas is actually
--- showing) a semantic view/cursor anchor to disk. Entirely pcall-guarded --
--- session persistence must never break closing the canvas.
function M.save(state)
  pcall(function()
    if not state or not state.root then
      return
    end

    -- `lens` is the truth; `base` is written alongside as a courtesy to readers
    -- that only know the older two-value vocabulary, and is nil for the `staged`
    -- and branch lenses it cannot express. VERSION deliberately stays 1: M.load
    -- rejects a mismatch outright, so bumping it would silently discard every
    -- session saved before lenses existed, and `lens` is purely additive.
    local l = lens.of(state)
    local data = { version = VERSION, base = lens.to_base(l), lens = l }

    -- Auto-collapsed (virt) paths are module intent, not user intent -- never
    -- persist them as if the user had collapsed them. state.collapsed records
    -- which is which, so this is a straight filter.
    local collapsed = {}
    for path, intent in pairs(state.collapsed or {}) do
      if intent == "user" then
        collapsed[#collapsed + 1] = path
      end
    end
    table.sort(collapsed)
    data.collapsed = collapsed

    -- Read straight off `state`, so folds persist whether or not the sidebar
    -- happens to be open at quit time.
    local folds = {}
    for dir in pairs(state.folded or {}) do
      folds[#folds + 1] = dir
    end
    table.sort(folds)
    data.folds = folds

    if win_showing_canvas(state) then
      local top0 = vim.api.nvim_win_call(state.win, function()
        return vim.fn.line("w0") - 1
      end)
      local i, top_offset = canvas.locate(state, top0)
      if i and not fold.hidden(state, state.sections[i].path) then
        local sec = state.sections[i]
        local view = viewport.capture_from_entries(sec.entries, top_offset)
        view.path = sec.path
        data.view = view

        local cursor_row0 = vim.api.nvim_win_get_cursor(state.win)[1] - 1
        local ci, cursor_offset = canvas.locate(state, cursor_row0)
        if ci then
          local centry = state.sections[ci].entries[cursor_offset]
          data.cursor = {
            path = state.sections[ci].path,
            new_lnum = centry and centry.new_lnum or nil,
            content = centry and centry.content or nil,
          }
        end
      end
    end

    local path = M.path_for(state.root)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode(data))
    f:close()
  end)
end

--- Load a previously saved session for `root`, or nil when there is none /
--- it can't be decoded / it's from an incompatible version.
function M.load(root)
  local path = M.path_for(root)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then
    return nil
  end

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" or data.version ~= VERSION then
    return nil
  end
  return data
end

--- Reapply a loaded session onto a freshly-opened `state`. Each of the three
--- sub-steps (collapse, folds, view) is independently pcall-guarded, so a
--- failure resolving one never prevents the others from applying.
function M.restore(state, data)
  if not state or not data then
    return
  end

  -- Folds FIRST: everything below derives visibility from state.folded, and
  -- the collapse loop's own splices resolve their rendered form through it.
  pcall(function()
    local set = {}
    for _, dir in ipairs(data.folds or {}) do
      set[dir] = true
    end
    state.folded = set
  end)

  pcall(function()
    for _, path in ipairs(data.collapsed or {}) do
      local idx = index_of_path(state, path)
      if idx then
        canvas.set_collapsed(state, idx, true)
      end
    end
  end)

  -- One pass over every section, because assigning state.folded above changed
  -- what they should render as without splicing anything. The caller
  -- (init.M.open) owns the single follow-up sync of the other UI pieces.
  pcall(function()
    canvas.resync_visibility(state)
  end)

  pcall(function()
    local v = data.view
    if not v or not v.path then
      return
    end
    local idx = index_of_path(state, v.path)
    if not idx then
      return
    end
    -- A set-aside section is just its placeholder row -- its entries don't
    -- map to buffer rows, so there is nothing to resolve. save() never
    -- records a view onto one, so this only fires on a stale or hand-written
    -- payload whose collapse/fold set covers its own view path.
    -- (init.M.open runs this restore BEFORE attaching the auto-virtualizer,
    -- precisely so virt can't collapse the target first.)
    if fold.hidden(state, v.path) then
      return
    end

    local sec = state.sections[idx]
    local resolved = viewport.resolve(v, sec.entries)
    if not resolved then
      return
    end
    local start_row = (canvas.section_rows(state, idx))
    local topline = math.max(1, start_row + resolved - (v.screen_offset or 0))
    local lnum = topline

    local c = data.cursor
    if c and c.path then
      local cidx = index_of_path(state, c.path)
      if cidx and not fold.hidden(state, c.path) then
        local csec = state.sections[cidx]
        local cresolved = viewport.resolve(c, csec.entries)
        if cresolved then
          local cstart = (canvas.section_rows(state, cidx))
          lnum = math.max(1, cstart + cresolved)
        end
      end
    end

    if win_showing_canvas(state) then
      vim.api.nvim_win_call(state.win, function()
        vim.fn.winrestview({ topline = topline, lnum = lnum })
      end)
    end
  end)
end

return M
