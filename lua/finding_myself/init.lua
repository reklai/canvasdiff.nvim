local canvas = require("finding_myself.canvas")
local git = require("finding_myself.git")
local model = require("finding_myself.model")
local jump = require("finding_myself.jump")
local config = require("finding_myself.config")

local M = {}

local EMPTY_MSG = "-- no changes --"

-- The single live canvas excursion state, cached across close()/open() so
-- the canvas buffer content survives being hidden (canvas.lua itself keeps
-- the scratch buffer alive; this just remembers our bookkeeping around it:
-- the git root and the window's previous buffer).
local state = nil

--- Public setup: merge user options into the config module. Entirely
--- optional -- every code path below works fine against config.defaults
--- when setup() is never called.
function M.setup(opts)
  return config.setup(opts)
end

--- Find a currently-loaded buffer showing `abs_path`, if any.
local function find_loaded_buf(abs_path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs_path then
      return b
    end
  end
  return nil
end

--- Current worktree content for a changed file: prefer a loaded buffer's
--- (possibly unsaved) lines, else read the file fresh off disk, else ""
--- when the file has been deleted or is otherwise unreadable.
local function read_worktree_content(root, rel_path, status)
  if status == "D" then
    return ""
  end

  local abs_path = vim.fs.joinpath(root, rel_path)
  local buf = find_loaded_buf(abs_path)
  if buf then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines == 0 or (#lines == 1 and lines[1] == "") then
      return ""
    end
    return table.concat(lines, "\n") .. "\n"
  end

  local f = io.open(abs_path, "r")
  if not f then
    return ""
  end
  local content = f:read("*a") or ""
  f:close()
  return content
end

local function collect_files(root)
  local files = {}
  for _, f in ipairs(git.changed_files(root)) do
    files[#files + 1] = {
      path = f.path,
      status = f.status,
      old_text = git.show_head(root, f.path) or "",
      new_text = read_worktree_content(root, f.path, f.status),
    }
  end
  return files
end

local function show_empty_message(st)
  vim.api.nvim_set_option_value("modifiable", true, { buf = st.buf })
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { EMPTY_MSG })
  vim.api.nvim_set_option_value("modifiable", false, { buf = st.buf })
end

local function set_canvas_keymaps(st)
  local cfg = config.options
  local map_opts = { buffer = st.buf, silent = true, noremap = true }
  vim.keymap.set("n", cfg.keymaps.jump, function()
    jump.enter(st, { back_key = cfg.keymaps.back })
  end, map_opts)
  vim.keymap.set("n", cfg.keymaps.close, function()
    M.close()
  end, map_opts)
  vim.keymap.set("n", cfg.keymaps.refresh, function()
    M.refresh()
  end, map_opts)
end

--- Open the canvas in the current window for the current cwd's git repo.
--- Not a repo ⇒ notify and return (never throws).
function M.open()
  local root = git.root(vim.fn.getcwd())
  if not root then
    vim.notify("finding_myself: not inside a git repository", vim.log.levels.WARN)
    return
  end

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)

  local sections = model.build(collect_files(root))

  local st = canvas.open(sections, {})
  st.root = root
  st.prev_buf = prev_buf
  state = st

  if #sections == 0 then
    show_empty_message(st)
  end

  set_canvas_keymaps(st)
end

--- Restore the window's previous buffer (or `enew` if it's gone). The
--- canvas buffer itself is left alone -- canvas.lua keeps it cached/hidden.
function M.close()
  if not state then
    return
  end
  local win = state.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end

  local prev_buf = state.prev_buf
  if prev_buf and prev_buf ~= state.buf and vim.api.nvim_buf_is_valid(prev_buf) then
    vim.api.nvim_win_set_buf(win, prev_buf)
  else
    vim.api.nvim_win_call(win, function()
      vim.cmd("enew")
    end)
  end
end

--- Toggle: close if the canvas is showing in the current window, else open.
function M.toggle()
  if canvas.is_canvas_buf(vim.api.nvim_get_current_buf()) then
    M.close()
  else
    M.open()
  end
end

--- Full re-collect + re-render of the live canvas state, if any exists yet.
function M.refresh()
  if not state then
    return
  end
  local sections = model.build(collect_files(state.root))
  canvas.render_all(state, sections)
  state.sections = sections
  if #sections == 0 then
    show_empty_message(state)
  end
end

return M
