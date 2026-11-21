local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")
local viewport = model.anchor
local source = require("canvasdiff.source")
local config = require("canvasdiff.config")
local fold = model.fold
local lens = model.lens

local M = {}

--- @class CanvasDiffExcursions
--- @field excursion table|nil
--- @field last_buf integer|nil

--- One review's excursion store.
---
--- The owning Surface holds exactly one, so two concurrent reviews keep
--- independent excursions and independent "last file" memory. A module-global
--- pair could not express that: a second review's `enter` would silently
--- overwrite the first review's way back.
--- @return CanvasDiffExcursions
function M.store()
  return { excursion = nil, last_buf = nil }
end

--- Most recent excursion target of this store that is still a live buffer.
function M.last_buf(store)
  local buf = store and store.last_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  return nil
end

-- Names the follow group of each excursion. Monotonic and process-wide on
-- purpose: two reviews hold two excursions at once, and a fixed name would let
-- one review's return delete the other's event source.
local next_follow = 0

--- An ordinary file buffer: the only kind the way back is ever mapped on.
--- Scratch buffers, terminals, pickers and our own canvas all carry a buftype,
--- and a key that brought the canvas into one of those would be answering a
--- question nobody asked there.
local function ordinary(buf)
  return vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_get_option_value("buftype", { buf = buf }) == ""
end

--- Repository-relative path of the file named `name` under `root`, or nil.
--- Tried lexically first because that is how a jump names the buffers it
--- opens; the realpath retry is for a buffer reached through a symlink, which
--- is still the same file the canvas is showing.
local function repo_path(root, name)
  if not root or type(name) ~= "string" or name == "" then
    return nil
  end
  local rel = vim.fs.relpath(root, name)
  if not rel then
    local real = vim.uv.fs_realpath(name)
    rel = real and vim.fs.relpath(root, real) or nil
  end
  if not rel or rel == "." or rel == "" then
    return nil
  end
  return rel
end

--- Map the way back on one buffer of a live excursion.
---
--- The buffer the jump opened always gets it. A buffer the user wandered into
--- afterwards gets it only where no buffer-local mapping already answers that
--- key: the return is removed with `keymap.del`, which cannot put back what it
--- replaced, so taking the key over would cost that buffer its own mapping for
--- good.
local function map_back(excursion, buf, on_return, yield)
  if excursion.mapped[buf] then
    return
  end
  local taken = {}
  for _, lhs in ipairs(excursion.back_keys) do
    local existing = yield and vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg(lhs, "n", false, true)
    end) or nil
    if not (existing and existing.buffer == 1) then
      vim.keymap.set("n", lhs, function()
        if on_return then
          on_return()
        end
      end, {
        buf = buf, silent = true, noremap = true,
        desc = "Return to the CanvasDiff canvas at this line",
      })
      taken[#taken + 1] = lhs
    end
  end
  excursion.mapped[buf] = taken
end

--- Give back everything an excursion installed: its return mappings on every
--- buffer that carries one, and the group that was adding them.
local function release(excursion)
  if excursion.follow_group then
    pcall(vim.api.nvim_del_augroup_by_id, excursion.follow_group)
    excursion.follow_group = nil
  end
  for buf, taken in pairs(excursion.mapped or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, lhs in ipairs(taken) do
        pcall(vim.keymap.del, "n", lhs, { buffer = buf })
      end
    end
  end
  excursion.mapped = {}
end

--- Consume an excursion without rebuilding its editable worktree side.
--- Used when the owner pivots to a read-only lens: retaining the old return
--- mapping would let a later keypress splice worktree content into that lens.
function M.cancel(store)
  local excursion = store and store.excursion
  if not excursion then
    return false
  end
  store.excursion = nil
  release(excursion)
  return true
end

--- @class CanvasDiffJump
--- @field ok boolean
--- @field diagnostic { level: "warn"|"info", message: string }|nil

--- Navigation refuses in the user's terms, but presenting is the owner's job:
--- input reaching for the UI facade would make the domain graph cyclic.
local function declined(level, message)
  return { ok = false, diagnostic = { level = level, message = message } }
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

--- Every build input a section carries besides its text, so a rebuild
--- produces the same section collection would -- modes included, or a
--- mode-only change would read as nothing after a round trip -- and can
--- recognise when nothing changed at all.
local function build_inputs(state, section)
  return {
    old_path = section.old_path or section.path,
    old_rev = section.old_rev or lens.of(state).old,
    new_rev = section.new_rev,
    staged = section.staged,
    unstaged = section.unstaged,
    old_mode = section.old_mode,
    new_mode = section.new_mode,
  }
end

--- Bytes the row prefix (`+`, ` `) occupies before a content row's text. The
--- one thing separating a canvas column from the file column it shows.
local function prefix_width(entry)
  if not (entry and entry.new_lnum) then
    return 0
  end
  return #(config.glyphs[entry.kind] or "")
end

local function section_index(state, path)
  for k, sec in ipairs(state.sections) do
    if sec.path == path then
      return k
    end
  end
  return nil
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
--- attach normally), on the line AND column the canvas cursor was on. Saves
--- an excursion so `back()` can regenerate the section from whatever the file
--- looks like now (including unsaved edits) and land the canvas on wherever
--- the user has got to.
function M.enter(store, state, opts)
  opts = opts or {}
  local back_keys = opts.back_keys or { "<C-Space>" }
  local win = opts.win or state.win
  if not (win and vim.api.nvim_win_is_valid(win))
      or vim.api.nvim_win_get_buf(win) ~= state.buf then
    return { ok = false }
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local row0 = cursor[1] - 1
  local i, entry_idx = canvas.locate(state, row0)
  if not i then
    return { ok = false }
  end

  -- Two different refusals for two different facts. The staged lens's new side
  -- is the index, which is not a file you can open -- editing the worktree copy
  -- instead would silently put you in a buffer whose content is NOT what the
  -- canvas is showing; unstaging moves that content back where it is editable.
  -- A committed range has no editable side at all. Both name the way out
  -- rather than just refusing, in the top band's own vocabulary.
  local l = lens.of(state)
  if not lens.editable(l) then
    if lens.is_range(l) then
      return declined("warn",
        "READ-ONLY comparison — press Tab to return to HEAD → WORKTREE and edit")
    end
    return declined("warn",
      "staged view is not editable — unstage it (s) to edit, or press Tab for the worktree")
  end

  local section = state.sections[i]
  -- We showed "no diff shown" for this file; dropping the user into a buffer
  -- of raw zip bytes would be a worse answer than declining. `:edit` it by
  -- hand if that really is what you want.
  if section.binary then
    return declined("warn",
      "binary file — nothing to jump into (" .. section.path .. ")")
  end
  local entries = section.entries
  local entry = entries[entry_idx]
  local target = target_lnum(entries, entry_idx, entry)

  local top_offset = top_offset_for_view(state, win, i)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)

  local excursion = {
    state = state,
    win = win,
    -- Destination identity stays the key for editing, sidebar selection and
    -- finding the live section again. A rename's old source is separate.
    path = section.path,
    status = section.status,
    metadata = build_inputs(state, section),
    view = view,
    anchor = viewport.capture_from_entries(entries, top_offset),
    cursor = { new_lnum = target, content = entry.content },
    back_keys = back_keys,
    mapped = {},
  }

  local abs_path = vim.fs.joinpath(state.root, section.path)
  vim.api.nvim_win_call(win, function()
    vim.cmd.edit({ abs_path, mods = { keepalt = true } })
  end)

  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local clamped = math.max(1, math.min(target, line_count))
  -- The column travels too, but only from a row that IS the line it opens: a
  -- header's column counts into the header's own text, not into the file's.
  -- Neovim clamps a column past the end of the line.
  local col = entry.new_lnum
    and math.max(0, cursor[2] - prefix_width(entry)) or 0
  vim.api.nvim_win_set_cursor(win, { clamped, col })

  excursion.buf = buf
  -- Where the jump put the cursor, and what was written there. A return from
  -- this exact line, unedited, means "I only looked" and goes back to the row
  -- that was pressed -- which need not be a row of this line at all (a hunk
  -- header opens the line below it).
  excursion.entered = {
    lnum = clamped,
    text = vim.api.nvim_buf_get_lines(buf, clamped - 1, clamped, false)[1] or "",
  }
  -- Replacing a live excursion: its mappings and follow group go with it, or
  -- the previous file would keep a return key that returns nowhere.
  if store.excursion then
    release(store.excursion)
  end
  store.excursion = excursion
  store.last_buf = buf

  -- Never map `q` in the real file buffer. The owner supplies the return
  -- action, so this mapping captures neither a module-global lookup nor the
  -- whole option table.
  local on_return = opts.on_return
  map_back(excursion, buf, on_return, false)

  -- The way back follows the user. `gd` out of the jumped-to file used to
  -- leave the return key behind on a buffer no longer on screen, so the one
  -- exit from the loop stopped working exactly when the excursion got
  -- interesting. While this excursion is live, every ordinary file buffer
  -- entered IN ITS WINDOW gains the same key; `release` takes them all back.
  --
  -- Its window, not any window: two reviews can each have an excursion out,
  -- and a buffer entered in one review's window must not answer with the
  -- other review's return. Once that window is gone there is no "its" left to
  -- respect, and the key follows wherever the user goes -- the same widening
  -- `back` applies when it picks a window to come back into.
  next_follow = next_follow + 1
  local group = vim.api.nvim_create_augroup(
    "canvasdiff_excursion_" .. next_follow, { clear = true })
  excursion.follow_group = group
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if store.excursion ~= excursion then
        return true
      end
      local here = vim.api.nvim_get_current_win()
      if (here == win or not vim.api.nvim_win_is_valid(win))
          and ordinary(args.buf) then
        map_back(excursion, args.buf, on_return, true)
      end
    end,
  })

  -- Consumers such as the sidebar can follow the excursion without making this
  -- generic navigation primitive depend on them. Publish only after the return
  -- mappings exist, so a callback fault cannot strand the excursion.
  if opts.on_path then
    opts.on_path(section.path, win)
  end
  return { ok = true }
end

--- The window to bring the canvas back into: the one the excursion left from when
--- it is still alive, else the one you are in now -- pressing the return key means
--- "take me back", and there is no reason that has to be the original window.
---
--- Rejects floating and winfixbuf windows: neither is a suitable host for the
--- canvas, and setting a fixed window's buffer throws E1513.
--- Returns nil when there is nothing usable, and the caller must then decline
--- WITHOUT consuming the excursion.
local function eligible_target(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  local ok_config, win_config = pcall(vim.api.nvim_win_get_config, win)
  if not ok_config or (win_config.relative and win_config.relative ~= "") then
    return false
  end
  local ok_fixed, fixed = pcall(
    vim.api.nvim_get_option_value, "winfixbuf", { win = win })
  return ok_fixed and not fixed
end

local function target_win(state, requested, source)
  if requested ~= nil then
    return eligible_target(requested) and requested or nil
  end

  local candidates = {}
  if source then candidates[#candidates + 1] = source end
  if state.win then candidates[#candidates + 1] = state.win end
  candidates[#candidates + 1] = vim.api.nvim_get_current_win()
  local seen = {}
  for _, win in ipairs(candidates) do
    if not seen[win] and eligible_target(win) then
      return win
    end
    seen[win] = true
  end
  return nil
end

--- Rebuild one shown section from the worktree as it is right now.
---
--- Answers { section, unchanged }: `section` is nil when the two sides no
--- longer differ, and is `shown` itself (with `unchanged`) when both sides hash
--- to what `shown` was built from. Answers nil and a message when the old side
--- cannot be read; nothing has been changed in either case.
local function rebuild(state, shown, path, status, metadata)
  -- Returning from a peek into an auto-collapsed deferred file that is still
  -- hidden must not force a full diff of a huge/generated file.
  if shown and shown.deferred and fold.hidden(state, path)
      and state.collapsed and state.collapsed[path] == "smart" then
    return { unchanged = true, section = shown }
  end
  -- A rename has two independent addresses. Read the old bytes from the source
  -- revision/path the metadata names, never from the live lens ref or the
  -- destination: a branch can move or disappear during an excursion, while its
  -- canonical commit object still names exactly what the user reviewed.
  local old_rev = metadata.old_rev or lens.of(state).old
  local old_path = metadata.old_path or path
  local old, old_err = source.show(state.root, old_rev, old_path)
  if old == nil and status ~= "A" and status ~= "?" then
    return nil, ("cannot rebuild excursion old side %s:%s: %s")
      :format(old_rev, old_path, old_err or "unknown git error")
  end

  -- Unsaved edits count, so this is deliberately the same worktree read the
  -- collector uses rather than a private io.open: one boundary owns "what does
  -- this file look like right now", buffer or disk.
  local content = source.worktree_text(state.root, path)
  -- Content-addressed reuse, as a refresh does: when both sides hash to what
  -- the shown section was built from, it IS the rebuild. A save during the
  -- excursion has usually refreshed the section already, and rebuilding the
  -- same text again cost a full re-diff and re-page -- measured ~690 ms of
  -- stall returning from a million-line file.
  local inputs = vim.tbl_extend("force", {}, metadata, {
    old_fingerprint = model.text_fingerprint(old or ""),
    new_fingerprint = model.text_fingerprint(content),
  })
  local unchanged = model.built_from(
    shown, path, status, config.options.context, inputs)
  return {
    unchanged = unchanged,
    section = unchanged and shown or model.build_section(
      path, old or "", content, status, config.options.context, inputs),
  }
end

--- Where a window is in a real file: the reverse jump's input.
---
--- Answers { buf, name, lnum, col, text, screen_row } for a window on an
--- ordinary file buffer -- `name` the buffer's own file name, `col` a 0-based
--- byte column, `screen_row` the 1-based window row the cursor is drawn on --
--- and nil for anything else (the canvas, the sidebar, a scratch buffer, an
--- unnamed buffer), none of which is a place a canvas row can stand for.
--- Never errors on a live window.
--- @param win integer|nil defaults to the current window
function M.whereabouts(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not ordinary(buf) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local pos = vim.api.nvim_win_get_cursor(win)
  return {
    buf = buf,
    name = name,
    lnum = pos[1],
    col = pos[2],
    text = vim.api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1] or "",
    screen_row = vim.api.nvim_win_call(win, vim.fn.winline),
  }
end

--- The canvas row standing for a file position: the reverse of `enter`.
---
--- `where` is what `whereabouts` answers (only `name`, `lnum` and `col` are
--- read). Answers { index, path, row, col, exact } -- `row` 1-based and `col`
--- a 0-based byte column, ready for nvim_win_set_cursor -- or nil when the
--- file is not under this review's root or has no section in it.
---
--- `exact` is false when the row is a stand-in: the nearest shown line for a
--- line outside every hunk's context, or the single placeholder row of a
--- folded section (a jump never changes a fold, and neither does its
--- reverse). The column is carried only onto an exact row.
---
--- Row numbers are the SHOWN section's, so the answer is exact only as far as
--- that section reflects the file: unsaved edits above the line shift it
--- until the next refresh. `back` rebuilds first for precisely that reason.
function M.locate(state, where)
  local path = where and repo_path(state.root, where.name)
  local index = path and section_index(state, path)
  if not index then
    return nil
  end
  local start_row = (canvas.section_rows(state, index))
  local spot = {
    index = index, path = path, row = start_row + 1, col = 0, exact = false,
  }
  if fold.hidden(state, path) then
    return spot
  end
  local entries = state.sections[index].entries
  local at, exact = viewport.nearest(entries, where.lnum)
  if at then
    spot.row = start_row + at
    spot.exact = exact
    if exact then
      spot.col = prefix_width(entries[at]) + (where.col or 0)
    end
  end
  return spot
end

--- Regenerate the excursed file's diff section from the CURRENT buffer
--- content (unsaved edits count), splice it back into the canvas, and put the
--- canvas on the line the user is on.
---
--- The return is the mirror of the jump. Enter opens the file line under the
--- canvas cursor; this lands the canvas cursor on the file line under the
--- cursor, column included -- so fixing something forty lines from where the
--- jump landed comes back to the fix, not to the place it was noticed from.
--- Three cases keep that honest:
---
--- * Pressed from the very line the jump landed on, unedited: nothing was
---   pointed at, so the canvas comes back exactly as it was left -- same row
---   (which may be a header, not a row of that line), same topline.
--- * Pressed on a line the canvas does not show (outside every hunk's
---   context): the nearest shown line of that file stands in.
--- * Pressed from another file of the review (the return key follows the
---   user, see `enter`): that file's section is rebuilt and landed on too. A
---   file the review does not show has no row to land on, and falls back to
---   where the excursion left.
function M.back(store, opts)
  if type(opts) == "number" then
    opts = { win = opts }
  else
    opts = opts or {}
  end
  local excursion = store and store.excursion
  if not excursion then
    return declined("info", "no active review excursion")
  end

  -- Resolved BEFORE anything is consumed. This used to run against state.win
  -- unchecked, so a `:q` in the excursion window made the keypress throw E5108 --
  -- and it threw after clearing the excursion and deleting its own keymap, so the
  -- edits never reached the canvas and there was no second try.
  local win = target_win(excursion.state, opts.win, excursion.win)
  if not win then
    return declined("warn",
      "no window to bring the canvas back into — try again from a normal window")
  end

  local ex = excursion
  local state = ex.state

  -- Resolve the destination section before consuming the excursion. A watch or
  -- another canvas operation may have removed it while the real file was open;
  -- declining here keeps the file, keymap and excursion retryable.
  local idx = section_index(state, ex.path)
  if not idx then
    return declined("warn",
      "excursion section for '" .. ex.path .. "' not found in canvas; return not applied")
  end

  local first, first_err = rebuild(
    state, state.sections[idx], ex.path, ex.status, ex.metadata or {})
  if not first then
    return declined("warn", first_err)
  end

  -- Read while the file window still shows the file: bringing the canvas back
  -- below replaces that window's buffer, and with it the cursor being asked
  -- about. A lens with no worktree side numbers its rows in another text, so
  -- a file line names nothing there.
  local here = lens.editable(lens.of(state)) and M.whereabouts() or nil
  if here then
    here.path = here.buf == ex.buf and ex.path or repo_path(state.root, here.name)
    if not here.path then
      here = nil
    end
  end
  local entered = ex.entered
  local looked_only = here ~= nil and entered ~= nil
    and here.buf == ex.buf
    and here.lnum == entered.lnum and here.text == entered.text

  -- The file the user is in now, when it is a different file of this review.
  -- Its section is rebuilt for the same reason the excursion's own is: the
  -- line being landed on is counted in the buffer's text, unsaved edits and
  -- all. A rebuild that cannot read its old side is not worth refusing the
  -- return over -- the section as shown is still the best row there is.
  local other
  if here and here.path ~= ex.path then
    local j = section_index(state, here.path)
    if j then
      local shown = state.sections[j]
      other = { path = here.path, index = j }
      if not shown.binary then
        other.rebuilt = rebuild(
          state, shown, shown.path, shown.status, build_inputs(state, shown))
      end
    else
      here = nil
    end
  end

  -- All fallible preflight work succeeded. Only now consume the excursion and
  -- remove its return mappings.
  store.excursion = nil
  release(ex)

  -- Returning establishes this host as the primary Canvas window for historical
  -- callers that do not yet carry an explicit window.
  state.win = win
  vim.api.nvim_win_set_buf(win, state.buf)

  if not first.unchanged then
    canvas.replace_section(state, idx, first.section)
  end
  local land_path, was_at = ex.path, idx
  if other then
    -- Looked up again by path: removing the excursion's own section (every
    -- change in it reverted) shifts the index captured above.
    local j = section_index(state, other.path)
    if j and other.rebuilt and not other.rebuilt.unchanged then
      canvas.replace_section(state, j, other.rebuilt.section)
    end
    land_path, was_at = other.path, j or other.index
  end

  local view = ex.view
  local land = section_index(state, land_path)
  if land then
    local entries = state.sections[land].entries
    local start_row = (canvas.section_rows(state, land))
    if fold.hidden(state, land_path) then
      -- Something set this section aside while we were away (folding a parent
      -- directory from the sidebar is the reachable route), so it now renders
      -- as its single placeholder row and its entries no longer map to buffer
      -- rows -- resolving against them would land us deep inside the FOLLOWING
      -- files. The placeholder itself is the only honest answer, and it's the
      -- same one replace_section's own collapsed_topline branch just gave.
      view.topline = start_row + 1
      view.lnum = start_row + 1
    else
      local at, exact
      if here and not looked_only then
        at, exact = viewport.nearest(entries, here.lnum)
      end
      local landed
      if at then
        local row = start_row + at
        local height = vim.api.nvim_win_get_height(win)
        -- The canvas as it was left, when that still shows the landing row:
        -- the less the screen moves, the less there is to re-read. Otherwise
        -- the line keeps the screen row it had in the file window, so the
        -- text under the eye stays under the eye across the swap.
        local top
        if land_path == ex.path then
          local resolved_top = viewport.resolve(ex.anchor, entries) or 1
          top = math.max(1, start_row + resolved_top - ex.anchor.screen_offset)
        end
        if not top or row < top or row >= top + height then
          top = math.max(1, row - math.min(here.screen_row, height) + 1)
        end
        view.topline = top
        view.lnum = row
        landed = exact and entries[at] or nil
      else
        local resolved_top = viewport.resolve(ex.anchor, entries) or 1
        local resolved_cursor = viewport.resolve(ex.cursor, entries) or 1
        view.topline = math.max(1, start_row + resolved_top - ex.anchor.screen_offset)
        view.lnum = math.max(1, start_row + resolved_cursor)
        local entry = entries[resolved_cursor]
        landed = here and entry and entry.new_lnum == here.lnum and entry or nil
      end
      -- The column comes back only onto the row that IS the file line it was
      -- counted in; anywhere else the canvas keeps the column it was left on.
      if landed then
        view.col = prefix_width(landed) + here.col
        view.coladd = 0
        view.curswant = view.col
      end
    end
  else
    local n = #state.sections
    if n > 0 then
      local nidx = math.min(was_at, n)
      local srow = (canvas.section_rows(state, nidx))
      view.topline = srow + 1
      view.lnum = srow + 1
    else
      view.topline = 1
      view.lnum = 1
    end
  end

  vim.api.nvim_win_call(win, function() vim.fn.winrestview(view) end)
  local on_shape_change = state.hooks and state.hooks.on_shape_change
  if on_shape_change then
    on_shape_change(state, win)
  end
  return { ok = true }
end

return M
