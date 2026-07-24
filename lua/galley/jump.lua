local canvas = require("galley.canvas")
local viewport = require("galley.viewport")
local model = require("galley.model")
local git = require("galley.git")
local config = require("galley.config")
local hl = require("galley.hl")
local sidebar = require("galley.sidebar")
local scrollbar = require("galley.scrollbar")
local util = require("galley.util")

local M = {}

-- Module-level excursion: at most one live at a time. A second `enter`
-- overwrites it wholesale (its stale buffer-local keymap, if any, is simply
-- left behind in the abandoned file buffer -- harmless, since `back()` only
-- ever acts on the current excursion).
local excursion = nil

--- Read the "current" content of an excursed file: unsaved buffer content
--- when the buffer is still loaded (edits count even if not written), else
--- a fresh disk read, else "" when the file is gone entirely.
local function read_current_content(buf, abs_path)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return util.buf_text(buf)
  end

  local f = io.open(abs_path, "r")
  if not f then
    return ""
  end
  local content = f:read("*a") or ""
  f:close()
  return content
end

--- From the section/entry the cursor is on, find the file line number to
--- land on: the entry's own new_lnum, or (for del/hdr entries, which have no
--- new_lnum) the first FOLLOWING entry in this section that has one, else 1.
local function target_lnum(entries, entry_idx, entry)
  if entry.new_lnum then
    return entry.new_lnum
  end
  for k = entry_idx + 1, #entries do
    if entries[k].new_lnum then
      return entries[k].new_lnum
    end
  end
  return 1
end

--- 1-based offset-into-this-section of the window's current topline
--- (line("w0")), clamped to 1 when w0 falls in an earlier section.
local function top_offset_for_view(state, win, section_i)
  local w0_1based = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
  local wi, woff = canvas.locate(state, w0_1based - 1)
  if wi == section_i then
    return woff
  end
  return 1
end

--- Jump into the real file backing the section/entry under the cursor in
--- the canvas window, as a genuine `:edit` (so LSP/treesitter/autocmds
--- attach normally). Saves an excursion so `back()` can regenerate the
--- section from whatever the file looks like now (including unsaved edits)
--- and restore the canvas viewport semantically.
function M.enter(state, opts)
  opts = opts or {}
  local back_keys = opts.back_keys or { "<M-CR>" }

  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local row0 = cursor[1] - 1
  local i, entry_idx = canvas.locate(state, row0)
  if not i then
    return
  end

  local section = state.sections[i]
  local entries = section.entries
  local entry = entries[entry_idx]
  local target = target_lnum(entries, entry_idx, entry)

  local top_offset = top_offset_for_view(state, state.win, i)
  local view = vim.api.nvim_win_call(state.win, vim.fn.winsaveview)

  excursion = {
    state = state,
    path = section.path,
    status = section.status,
    view = view,
    anchor = viewport.capture_from_entries(entries, top_offset),
    cursor = { new_lnum = target, content = entry.content },
    back_keys = back_keys,
  }

  local abs_path = vim.fs.joinpath(state.root, section.path)
  vim.api.nvim_win_call(state.win, function()
    vim.cmd.edit({ abs_path, mods = { keepalt = true } })
  end)

  local buf = vim.api.nvim_win_get_buf(state.win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local clamped = math.max(1, math.min(target, line_count))
  vim.api.nvim_win_set_cursor(state.win, { clamped, 0 })

  excursion.buf = buf
  -- Never map `q` in the real file buffer.
  for _, lhs in ipairs(back_keys) do
    vim.keymap.set("n", lhs, function()
      require("galley.jump").back()
    end, {
      buffer = buf, silent = true, noremap = true,
      desc = "Return to the galley canvas at the same spot",
    })
  end
end

--- Regenerate the excursed file's diff section from the CURRENT buffer
--- content (unsaved edits count), splice it back into the canvas, and
--- restore the canvas viewport to the semantic position the user left.
function M.back()
  if not excursion then
    util.notify("no diff-canvas excursion")
    return
  end
  local ex = excursion
  excursion = nil

  if ex.back_keys and ex.buf then
    for _, lhs in ipairs(ex.back_keys) do
      pcall(vim.keymap.del, "n", lhs, { buffer = ex.buf })
    end
  end

  local state = ex.state
  local abs_path = vim.fs.joinpath(state.root, ex.path)
  local content = read_current_content(ex.buf, abs_path)
  local old = git.show(state.root, state.base == "index" and ":0" or "HEAD", ex.path)
  local new_section = model.build_section(ex.path, old or "", content, ex.status, config.options.context)

  local idx
  for k, sec in ipairs(state.sections) do
    if sec.path == ex.path then
      idx = k
      break
    end
  end

  vim.api.nvim_win_set_buf(state.win, state.buf)

  if not idx then
    -- Edge case (MVP): the section for this path is no longer in the
    -- canvas at all (e.g. some other operation removed it out from under
    -- us). Nothing to splice; just warn and leave the canvas viewport as
    -- `nvim_win_set_buf` left it.
    util.warn(
      "excursion section for '" .. ex.path .. "' not found in canvas; view not updated"
    )
    return
  end

  canvas.replace_section(state, idx, new_section)

  local view = ex.view
  if new_section ~= nil then
    local start_row = (canvas.section_rows(state, idx))
    local resolved_top = viewport.resolve(ex.anchor, new_section.entries) or 1
    local resolved_cursor = viewport.resolve(ex.cursor, new_section.entries) or 1
    view.topline = math.max(1, start_row + resolved_top - ex.anchor.screen_offset)
    view.lnum = math.max(1, start_row + resolved_cursor)
  else
    local n = #state.sections
    if n > 0 then
      local nidx = math.min(idx, n)
      local srow = (canvas.section_rows(state, nidx))
      view.topline = srow + 1
      view.lnum = srow + 1
    else
      view.topline = 1
      view.lnum = 1
    end
  end

  vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
  hl.apply_now(state)
  sidebar.refresh(state)
  scrollbar.update(state)
end

return M
