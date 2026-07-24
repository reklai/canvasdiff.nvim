local canvas = require("finding_myself.canvas")
local viewport = require("finding_myself.viewport")
local sidebar = require("finding_myself.sidebar")
local virt = require("finding_myself.virt")

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
  return vim.fn.stdpath("state") .. "/finding_myself/" .. vim.fn.sha256(root) .. ".json"
end

--- Persist `state`'s base/collapsed/folds and (when the canvas is actually
--- showing) a semantic view/cursor anchor to disk. Entirely pcall-guarded --
--- session persistence must never break closing the canvas.
function M.save(state)
  pcall(function()
    if not state or not state.root then
      return
    end

    local data = { version = VERSION, base = state.base }

    -- Auto-collapsed (virt) paths are module intent, not user intent --
    -- never persist them as if the user had collapsed them.
    local auto = virt.auto_set()
    local collapsed = {}
    for path in pairs(state.collapsed or {}) do
      if not auto[path] then
        collapsed[#collapsed + 1] = path
      end
    end
    table.sort(collapsed)
    data.collapsed = collapsed

    data.folds = sidebar.get_folds()

    if win_showing_canvas(state) then
      local top0 = vim.api.nvim_win_call(state.win, function()
        return vim.fn.line("w0") - 1
      end)
      local i, top_offset = canvas.locate(state, top0)
      if i and not (state.collapsed and state.collapsed[state.sections[i].path]) then
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

  pcall(function()
    for _, path in ipairs(data.collapsed or {}) do
      local idx = index_of_path(state, path)
      if idx then
        canvas.set_collapsed(state, idx, true)
      end
      virt.unauto(path)
    end
  end)

  pcall(function()
    sidebar.set_folds(data.folds or {}, state)
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
    -- virt's immediate apply (attached before restore runs) may have
    -- auto-collapsed this very section already; a collapsed section's
    -- entries don't map to buffer rows, so there is nothing to resolve.
    if state.collapsed and state.collapsed[v.path] then
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
      if cidx and not (state.collapsed and state.collapsed[c.path]) then
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
