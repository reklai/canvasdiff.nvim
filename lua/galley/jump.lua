local canvas = require("galley.canvas")
local viewport = require("galley.viewport")
local model = require("galley.model")
local git = require("galley.git")
local config = require("galley.config")
local hl = require("galley.hl")
local sidebar = require("galley.sidebar")
local scrollbar = require("galley.scrollbar")
local util = require("galley.util")
local fold = require("galley.fold")
local lens = require("galley.lens")

local M = {}

-- Module-level excursion: at most one live at a time. A second `enter`
-- overwrites it wholesale (its stale buffer-local keymap, if any, is simply
-- left behind in the abandoned file buffer -- harmless, since `back()` only
-- ever acts on the current excursion).
local excursion = nil

-- The last real file buffer an excursion landed in, remembered past the
-- excursion itself so close() can fall back to it when the buffer the canvas
-- was opened over has since been deleted.
local last_buf = nil

--- Most recent excursion target that is still a live buffer, or nil.
function M.last_buf()
  if last_buf and vim.api.nvim_buf_is_valid(last_buf) then
    return last_buf
  end
  return nil
end

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

  -- The staged lens's new side is the index, which is not a file you can open --
  -- editing the worktree copy instead would silently put you in a buffer whose
  -- content is NOT what the canvas is showing. Name the way out rather than just
  -- refusing: unstaging moves that content back into the worktree, where it is
  -- editable again.
  if not lens.editable(lens.of(state)) then
    util.warn("staged view is not editable — unstage it to edit, or press B for the worktree")
    return
  end

  local section = state.sections[i]
  -- We showed "no diff shown" for this file; dropping the user into a buffer
  -- of raw zip bytes would be a worse answer than declining. `:edit` it by
  -- hand if that really is what you want.
  if section.binary then
    util.warn("binary file — nothing to jump into (" .. section.path .. ")")
    return
  end
  local entries = section.entries
  local entry = entries[entry_idx]
  local target = target_lnum(entries, entry_idx, entry)

  local top_offset = top_offset_for_view(state, state.win, i)
  local view = vim.api.nvim_win_call(state.win, vim.fn.winsaveview)

  excursion = {
    state = state,
    -- Destination identity stays the key for editing, sidebar selection and
    -- finding the live section again. A rename's old source is separate.
    path = section.path,
    status = section.status,
    metadata = {
      old_path = section.old_path or section.path,
      old_rev = section.old_rev or lens.of(state).old,
      staged = section.staged,
      unstaged = section.unstaged,
    },
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
  last_buf = buf

  -- Follow the jump in the tree. sync() cannot do this -- the canvas is no longer in
  -- its window, so it has no topline to resolve and bails, leaving the highlight on
  -- the file you were reading BEFORE the jump. The sidebar answers "where am I in the
  -- changeset", and during an excursion the answer is this file.
  sidebar.mark_path(state, section.path)

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
--- The window to bring the canvas back into: the one the excursion left from when
--- it is still alive, else the one you are in now -- pressing the return key means
--- "take me back", and there is no reason that has to be the original window.
---
--- Rejects the sidebar, which is 'winfixbuf': setting its buffer throws E1513.
--- Returns nil when there is nothing usable, and the caller must then decline
--- WITHOUT consuming the excursion.
local function target_win(state)
  if state.win and vim.api.nvim_win_is_valid(state.win)
    and not sidebar.is_sidebar_win(state.win) then
    return state.win
  end
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(cur) and not sidebar.is_sidebar_win(cur) then
    return cur
  end
  return nil
end

function M.back()
  if not excursion then
    util.notify("no diff-canvas excursion")
    return
  end

  -- Resolved BEFORE anything is consumed. This used to run against state.win
  -- unchecked, so a `:q` in the excursion window made the keypress throw E5108 --
  -- and it threw after clearing the excursion and deleting its own keymap, so the
  -- edits never reached the canvas and there was no second try.
  local win = target_win(excursion.state)
  if not win then
    util.warn("no window to bring the canvas back into — try again from a normal window")
    return
  end

  local ex = excursion
  local state = ex.state

  -- Resolve the destination section before consuming the excursion. A watch or
  -- another canvas operation may have removed it while the real file was open;
  -- declining here keeps the file, keymap and excursion retryable.
  local idx
  for k, sec in ipairs(state.sections) do
    if sec.path == ex.path then
      idx = k
      break
    end
  end
  if not idx then
    util.warn(
      "excursion section for '" .. ex.path .. "' not found in canvas; return not applied"
    )
    return
  end

  -- A rename has two independent addresses. Read the old bytes from the source
  -- revision/path captured on Enter, never from the live lens ref or destination:
  -- a branch can move or disappear during the excursion, while its canonical
  -- commit object still names exactly what the user reviewed.
  local metadata = ex.metadata or {}
  local old_rev = metadata.old_rev or lens.of(state).old
  local old_path = metadata.old_path or ex.path
  local old, old_err = git.show(state.root, old_rev, old_path)
  if old == nil and ex.status ~= "A" and ex.status ~= "?" then
    util.warn(("cannot rebuild excursion old side %s:%s: %s")
      :format(old_rev, old_path, old_err or "unknown git error"))
    return
  end

  local abs_path = vim.fs.joinpath(state.root, ex.path)
  local content = read_current_content(ex.buf, abs_path)
  local new_section = model.build_section(
    ex.path, old or "", content, ex.status, config.options.context, metadata)

  -- All fallible preflight work succeeded. Only now consume the excursion and
  -- remove its return mappings.
  excursion = nil
  if ex.back_keys and ex.buf then
    for _, lhs in ipairs(ex.back_keys) do
      pcall(vim.keymap.del, "n", lhs, { buffer = ex.buf })
    end
  end

  -- The canvas may be landing in a different window than it left from; everything
  -- below, and every consumer we notify at the end, reads state.win.
  state.win = win
  vim.api.nvim_win_set_buf(win, state.buf)

  canvas.replace_section(state, idx, new_section)

  local view = ex.view
  if new_section ~= nil then
    local start_row = (canvas.section_rows(state, idx))
    if fold.hidden(state, ex.path) then
      -- Something set this section aside while we were away (folding a parent
      -- directory from the sidebar is the reachable route), so it now renders
      -- as its single placeholder row and its entries no longer map to buffer
      -- rows -- resolving against them would land us deep inside the FOLLOWING
      -- files. The placeholder itself is the only honest answer, and it's the
      -- same one replace_section's own collapsed_topline branch just gave.
      view.topline = start_row + 1
      view.lnum = start_row + 1
    else
      local resolved_top = viewport.resolve(ex.anchor, new_section.entries) or 1
      local resolved_cursor = viewport.resolve(ex.cursor, new_section.entries) or 1
      view.topline = math.max(1, start_row + resolved_top - ex.anchor.screen_offset)
      view.lnum = math.max(1, start_row + resolved_cursor)
    end
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
