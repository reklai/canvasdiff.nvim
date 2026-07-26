local render = require("galley.render")
local viewport = require("galley.viewport")
local fold = require("galley.fold")

local M = {}

local BUFNAME = "galley://canvas"

local ANCHOR_NS = vim.api.nvim_create_namespace("galley.canvas.anchors")
local HL_NS = vim.api.nvim_create_namespace("galley.canvas.hl")

-- Anchors are placed with right_gravity = false. Empirically (verified via a
-- headless probe, not just the docs) a left-gravity mark sitting at the exact
-- START of a set_lines([start, end)) edit stays fixed at that row -- exactly
-- what we want for a section's own start anchor. But a left-gravity mark
-- sitting at the exact END boundary of that same edit collapses BACKWARD to
-- the edit's start row, regardless of how many lines were inserted -- the
-- opposite of what we want for the "next anchor" that defines end_row of the
-- section being replaced. So the boundary anchor (the following section's
-- start, or the EOF sentinel) is never left to drift on its own: it is always
-- explicitly deleted and recreated at the correct row after every splice via
-- replace_boundary_extmark below.
local ANCHOR_OPTS = { right_gravity = false, invalidate = false, undo_restore = false }

local canvas_buf = nil

local function ensure_hl_groups()
  vim.api.nvim_set_hl(0, "GalleyFileHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "GalleyGhost", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "GalleyHunkHeader", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "GalleyBinary", { link = "Comment", default = true })
end

local function set_modifiable(buf, val)
  vim.api.nvim_set_option_value("modifiable", val, { buf = buf })
end

local function apply_win_opts(win)
  local opts = {
    wrap = false,
    cursorline = true,
    signcolumn = "no",
    foldenable = false,
    -- The user's global 'scrolloff'/'sidescrolloff' would otherwise perturb
    -- a restored topline (e.g. when view.lnum lands exactly at the window's
    -- top row, a nonzero scrolloff pushes the actual topline up further).
    scrolloff = 0,
    sidescrolloff = 0,
  }
  for name, val in pairs(opts) do
    vim.api.nvim_set_option_value(name, val, { win = win, scope = "local" })
  end
end

local function find_canvas_buf()
  if canvas_buf and vim.api.nvim_buf_is_valid(canvas_buf) then
    return canvas_buf
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == BUFNAME then
      canvas_buf = b
      return b
    end
  end
  return nil
end

local function get_or_create_buf()
  local existing = find_canvas_buf()
  if existing then return existing end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, BUFNAME)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("undolevels", -1, { buf = buf })
  set_modifiable(buf, false)
  canvas_buf = buf
  return buf
end

--- Full-line highlight extmarks for one section, starting at buffer row
--- `start_row` (0-based). Returns the created extmark ids so the caller can
--- track them and delete them precisely later (see replace_section notes on
--- why row-range clearing is not safe here). `collapsed` renders the section
--- as its single placeholder row instead, with one file-header-styled mark.
local function apply_section_hl(buf, start_row, section, collapsed)
  if collapsed then
    return { vim.api.nvim_buf_set_extmark(buf, HL_NS, start_row, 0, {
      end_row = start_row + 1,
      end_col = 0,
      hl_group = "GalleyFileHeader",
      hl_eol = true,
      priority = 100,
    }) }
  end
  local marks = render.section_hl(section)
  local ids = {}
  for _, m in ipairs(marks) do
    local row = start_row + m.row
    ids[#ids + 1] = vim.api.nvim_buf_set_extmark(buf, HL_NS, row, 0, {
      end_row = row + 1,
      end_col = 0,
      hl_group = m.group,
      hl_eol = true,
      priority = 100,
    })
  end

  -- Deleted lines, drawn as virtual lines rather than buffer rows. They cost zero
  -- buffer lines, which is the whole reason the result view leaves every piece of row
  -- arithmetic in this file untouched -- see the note in model.build_section's `push`.
  --
  -- Attached here rather than at splice time because this function already runs per
  -- section on every render_all AND every replace_section, and returns its ids for
  -- precise deletion. A ghost created anywhere else would survive the section it
  -- belongs to and end up floating over the next file's diff.
  for idx, e in ipairs(section.entries) do
    local row = start_row + idx - 1
    local above = render.ghost_lines(e, "ghosts")
    if above then
      ids[#ids + 1] = vim.api.nvim_buf_set_extmark(buf, HL_NS, row, 0, {
        virt_lines = above,
        virt_lines_above = true,
        priority = 100,
      })
    end
    local below = render.ghost_lines(e, "ghosts_after")
    if below then
      ids[#ids + 1] = vim.api.nvim_buf_set_extmark(buf, HL_NS, row, 0, {
        virt_lines = below,
        priority = 100,
      })
    end
  end
  return ids
end

--- The lines a section renders as right now: its single placeholder line when
--- it is set aside -- collapsed outright, or hidden by a folded ancestor
--- directory -- else its full body.
local function section_lines_for(state, sec)
  if fold.hidden(state, sec.path) then
    return { render.placeholder(sec) }
  end
  return render.section_lines(sec)
end

local function get_row(state, id)
  local pos = vim.api.nvim_buf_get_extmark_by_id(state.buf, ANCHOR_NS, id, {})
  return pos[1]
end

--- Delete the old boundary anchor at state.anchor_ids[idx] (if any) and
--- create a fresh one at `row`, storing it back into state.anchor_ids[idx].
--- `idx` is either the next section's start-anchor slot, or the EOF
--- sentinel slot when the replaced section is the last one.
local function replace_boundary_extmark(state, idx, row)
  local old_id = state.anchor_ids[idx]
  if old_id then
    pcall(vim.api.nvim_buf_del_extmark, state.buf, ANCHOR_NS, old_id)
  end
  local new_id = vim.api.nvim_buf_set_extmark(state.buf, ANCHOR_NS, row, 0, ANCHOR_OPTS)
  state.anchor_ids[idx] = new_id
  return new_id
end

function M.is_canvas_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_buf_get_name(buf) == BUFNAME
end

--- Clears the buffer and re-renders every section from scratch, placing one
--- left-gravity anchor per section start plus an EOF sentinel, and applying
--- line-tier highlights. Populates state.sections/anchor_ids/hl_ids.
function M.render_all(state, sections)
  local buf = state.buf
  set_modifiable(buf, true)
  vim.api.nvim_buf_clear_namespace(buf, ANCHOR_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, HL_NS, 0, -1)

  if state.hooks and state.hooks.on_render_all then
    state.hooks.on_render_all()
  end

  local all_lines = {}
  local starts = {}
  for idx, sec in ipairs(sections) do
    starts[idx] = #all_lines
    for _, l in ipairs(section_lines_for(state, sec)) do
      all_lines[#all_lines + 1] = l
    end
  end
  if #all_lines == 0 then
    all_lines = { "" } -- Neovim buffers always have >=1 line; nothing to anchor to.
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)

  local anchor_ids, hl_ids = {}, {}
  for idx, sec in ipairs(sections) do
    anchor_ids[idx] = vim.api.nvim_buf_set_extmark(buf, ANCHOR_NS, starts[idx], 0, ANCHOR_OPTS)
    hl_ids[idx] = apply_section_hl(buf, starts[idx], sec, fold.hidden(state, sec.path))
  end
  local eof_row = #sections > 0 and #all_lines or 0
  anchor_ids[#sections + 1] = vim.api.nvim_buf_set_extmark(buf, ANCHOR_NS, eof_row, 0, ANCHOR_OPTS)

  state.sections = sections
  state.anchor_ids = anchor_ids
  state.hl_ids = hl_ids
  set_modifiable(buf, false)
end

--- Creates/reuses the scratch canvas buffer, shows it in the current window,
--- and renders `sections`.
function M.open(sections, opts)
  opts = opts or {}
  ensure_hl_groups()
  local buf = get_or_create_buf()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  apply_win_opts(win)

  local state = { buf = buf, win = win, sections = {}, anchor_ids = {}, hl_ids = {} }
  -- Never reset on a later render_all -- only initialized here, once, so a
  -- refresh() on an already-open state (which calls render_all directly)
  -- keeps whatever the user has collapsed or folded away. `folded` is a set of
  -- directory paths with a trailing slash, owned by the sidebar but living
  -- here because rendering, navigation and session all derive from it.
  state.collapsed = state.collapsed or {}
  state.folded = state.folded or {}
  M.render_all(state, sections)
  return state
end

--- 0-based [start_row, end_row_exclusive) for section i, resolved live from
--- extmarks -- never cached.
function M.section_rows(state, i)
  return get_row(state, state.anchor_ids[i]), get_row(state, state.anchor_ids[i + 1])
end

--- Binary search over section start anchors for the section containing
--- 0-based buffer row `row0`. Returns section index and 1-based offset into
--- that section's entries, or nil if there are no sections.
function M.locate(state, row0)
  local n = #state.sections
  if n == 0 then return nil end

  local starts = {}
  for i = 1, n do
    starts[i] = get_row(state, state.anchor_ids[i])
  end

  local lo, hi, ans = 1, n, 1
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if starts[mid] <= row0 then
      ans = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end

  return ans, row0 - starts[ans] + 1
end

local function win_showing_canvas(state)
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

local function win_view_info(win)
  return vim.api.nvim_win_call(win, function()
    return { top = vim.fn.line("w0"), bot = vim.fn.line("w$"), view = vim.fn.winsaveview() }
  end)
end

--- Splices section i's content in place: resolves its rows live, classifies
--- the edit against the live viewport (below / above / intersecting), and
--- corrects the view in the same synchronous tick so the niri invariant
--- holds (content changes outside the viewport never move what the user is
--- reading). `new_section == nil` deletes the section.
function M.replace_section(state, i, new_section)
  local replaced_path = state.sections[i] and state.sections[i].path
  local was_collapsed = replaced_path ~= nil and fold.hidden(state, replaced_path)
  local start_row, end_row_exclusive = M.section_rows(state, i)
  local new_lines = new_section and section_lines_for(state, new_section) or {}

  local win_ok = win_showing_canvas(state)
  local branch, top0, bot0, view
  if win_ok then
    local info = win_view_info(state.win)
    top0, bot0, view = info.top - 1, info.bot - 1, info.view
    if start_row > bot0 then
      branch = "below"
    elseif end_row_exclusive <= top0 then
      branch = "above"
    else
      branch = "intersect"
    end
  else
    branch = "none"
  end

  -- Intersecting + replace (not delete): capture a semantic anchor from the
  -- OLD entries at the viewport's current top-of-section offset, before the
  -- buffer changes underneath it. When the viewport top sits ABOVE the
  -- replaced section (top0 < start_row -- the section only pokes into the
  -- BOTTOM of the viewport), the content at and above the viewport top is
  -- entirely untouched by this splice: there is nothing to anchor, and
  -- anchoring off the section's first entry would wrongly imply the
  -- viewport top itself sits at start_row, scrolling the user down by
  -- (start_row - top0) rows. `preserve_view` short-circuits to "leave the
  -- captured view exactly as it was" instead (see below).
  local anchor
  local preserve_view = false
  -- A collapsed section's entries don't map to buffer rows (only its one
  -- placeholder line does), so capture_from_entries can't run against it.
  -- Mirror the plain preserve_view split on whether the viewport top sits
  -- above the section instead: above it, nothing moved, so preserve as-is;
  -- otherwise there is nothing sensible to resolve down to but the
  -- section's own new start row.
  local collapsed_topline = false
  if branch == "intersect" and new_section ~= nil then
    if was_collapsed then
      if top0 < start_row then
        preserve_view = true
      else
        collapsed_topline = true
      end
    elseif top0 < start_row then
      preserve_view = true
    else
      local top_offset = top0 - start_row + 1
      anchor = viewport.capture_from_entries(state.sections[i].entries, top_offset)
    end
  end

  -- --- splice (buffer-mutating section; modifiable toggled around it) ---
  set_modifiable(state.buf, true)

  vim.api.nvim_buf_set_lines(state.buf, start_row, end_row_exclusive, false, new_lines)
  replace_boundary_extmark(state, i + 1, start_row + #new_lines)

  -- Delete this section's old highlight marks by id (precise -- see the
  -- module-level note: a row-range nvim_buf_clear_namespace is NOT safe
  -- here, because a fully-replaced range's old marks and the following
  -- section's legitimately-shifted marks can land on the exact same row).
  for _, id in ipairs(state.hl_ids[i] or {}) do
    pcall(vim.api.nvim_buf_del_extmark, state.buf, HL_NS, id)
  end

  if new_section ~= nil then
    state.hl_ids[i] = apply_section_hl(state.buf, start_row, new_section,
      fold.hidden(state, new_section.path))
    state.sections[i] = new_section
  else
    pcall(vim.api.nvim_buf_del_extmark, state.buf, ANCHOR_NS, state.anchor_ids[i])
    table.remove(state.anchor_ids, i)
    table.remove(state.sections, i)
    table.remove(state.hl_ids, i)
    -- The path is gone from the canvas; drop its collapsed flag too, so a
    -- different file that later reuses this path doesn't inherit it.
    if replaced_path and state.collapsed then
      state.collapsed[replaced_path] = nil
    end
  end

  set_modifiable(state.buf, false)

  -- Extmarks inside a replaced range collapse rather than die, so the
  -- treesitter/word tier must delete its marks by id NOW, in the same tick.
  if replaced_path and state.hooks and state.hooks.on_section_replaced then
    state.hooks.on_section_replaced(replaced_path)
  end

  -- --- view correction (same synchronous tick, no vim.schedule) ---
  if branch == "above" then
    local delta = #new_lines - (end_row_exclusive - start_row)
    view.topline = math.max(1, view.topline + delta)
    view.lnum = math.max(1, view.lnum + delta)
    vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
  elseif branch == "intersect" then
    if new_section ~= nil and preserve_view then
      -- Viewport top was above the replaced section: nothing above
      -- start_row moved, so the captured view is still correct as-is.
      -- Only clamp lnum, in case the cursor itself was inside the replaced
      -- range and the buffer is now shorter than the cursor's old row.
      view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(state.buf))
      vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
    elseif new_section ~= nil and collapsed_topline then
      -- The replaced section was collapsed and the viewport top sat at or
      -- below its start row: with no entries to resolve a semantic anchor
      -- from, scroll to the (still 1-row) section's own start.
      local topline = start_row + 1
      view.topline = topline
      view.lnum = topline
      vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
    elseif new_section ~= nil then
      local resolved = viewport.resolve(anchor, new_section.entries) or 1
      -- resolved is a 1-based index into new_section.entries; the 0-based
      -- row of that entry in the buffer is start_row + (resolved - 1); the
      -- 1-based topline that keeps it anchor.screen_offset rows below the
      -- top is that row minus screen_offset, plus 1 to go 0-based -> 1-based
      -- (the -1 and +1 cancel, leaving start_row + resolved - screen_offset).
      local topline = math.max(1, start_row + resolved - anchor.screen_offset)
      view.topline = topline
      view.lnum = topline
      vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
    else
      -- Section deleted and the viewport was inside it: scroll to the
      -- nearest surviving section's start. After removal, whatever used to
      -- be section i+1 is now at index i (or, if i was the last section,
      -- the new last section is at index n).
      local n = #state.sections
      if n > 0 then
        local idx = math.min(i, n)
        local srow = (M.section_rows(state, idx))
        local topline = srow + 1
        view.topline = topline
        view.lnum = topline
        vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
      end
    end
  end
  -- "below" and "none": nothing to do -- the edit cannot move rows the user
  -- is currently looking at, and the window either doesn't exist or isn't
  -- showing the canvas.
end

--- Inserts `section` BEFORE current section index i (i = #sections + 1
--- appends at EOF), correcting the view in the same synchronous tick so the
--- niri invariant holds. Precondition: the canvas is non-empty
--- (#state.sections >= 1) -- the 0 -> N transition goes through render_all.
function M.insert_section(state, i, section)
  local row = get_row(state, state.anchor_ids[i])
  local new_lines = section_lines_for(state, section)

  local win_ok = win_showing_canvas(state)
  local branch, view
  if win_ok then
    local info = win_view_info(state.win)
    local top0, bot0 = info.top - 1, info.bot - 1
    view = info.view
    if row > bot0 then
      branch = "below"
    elseif row <= top0 then
      branch = "above"
    else
      branch = "intersect"
    end
  else
    branch = "none"
  end

  set_modifiable(state.buf, true)
  vim.api.nvim_buf_set_lines(state.buf, row, row, false, new_lines)
  -- The left-gravity boundary anchor sitting exactly at `row` stays put
  -- through the insert and would wrongly become the inserted section's
  -- start; recreate it at its shifted position first, then give the new
  -- section its own anchor at `row` (see the module-level gravity note).
  replace_boundary_extmark(state, i, row + #new_lines)
  table.insert(state.anchor_ids, i,
    vim.api.nvim_buf_set_extmark(state.buf, ANCHOR_NS, row, 0, ANCHOR_OPTS))
  table.insert(state.sections, i, section)
  table.insert(state.hl_ids, i,
    apply_section_hl(state.buf, row, section, fold.hidden(state, section.path)))
  set_modifiable(state.buf, false)

  -- View correction, same synchronous tick.
  if branch == "above" then
    -- Insertion at or above the viewport top: shift so what the user reads
    -- stays pinned; the new content scrolls in above, out of view.
    view.topline = view.topline + #new_lines
    view.lnum = view.lnum + #new_lines
    vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
  elseif branch == "intersect" then
    -- Insertion point is inside the viewport: nothing at or above the
    -- viewport top moved, so the captured view is still correct as-is.
    -- (the absolute cursor line may now sit on inserted content -- the
    -- invariant protects the viewport top, not cursor identity).
    vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
  end
  -- "below"/"none": the edit cannot move rows the user is looking at.
end

--- Re-splice section i so the buffer shows what it should render as right now,
--- with the same same-tick view correction as replace_section (a set-aside
--- section is just a 1-row section for viewport-classification purposes).
---
--- The target form is DERIVED here rather than passed in: a caller handing
--- over a form that contradicts fold.hidden would replace a placeholder with
--- an identical placeholder, destroy and rebuild its highlight marks, fire
--- on_section_replaced, and -- classified as "intersect" -- scroll the user to
--- start_row + 1 for no reason.
---
--- No-op when the section is missing, when its anchors don't resolve against
--- this buffer (same staleness case hl.apply_now guards), or when the buffer
--- already shows the right form.
local function resplice(state, i)
  local sec = state.sections[i]
  if not sec then return end

  local start_row, end_row_exclusive = M.section_rows(state, i)
  if not (start_row and end_row_exclusive) then return end

  local collapsed = fold.hidden(state, sec.path)
  local new_lines = section_lines_for(state, sec)
  -- Already in the desired form. Comparing row spans is exact: build_section
  -- always emits a file_hdr plus at least one hunk_hdr/binary entry, so an
  -- expanded section is never one row and can never be mistaken for a
  -- placeholder.
  if end_row_exclusive - start_row == #new_lines then return end

  local win_ok = win_showing_canvas(state)
  local branch, top0, view
  if win_ok then
    local info = win_view_info(state.win)
    top0 = info.top - 1
    view = info.view
    local bot0 = info.bot - 1
    if start_row > bot0 then branch = "below"
    elseif end_row_exclusive <= top0 then branch = "above"
    else branch = "intersect" end
  else
    branch = "none"
  end

  set_modifiable(state.buf, true)
  vim.api.nvim_buf_set_lines(state.buf, start_row, end_row_exclusive, false, new_lines)
  replace_boundary_extmark(state, i + 1, start_row + #new_lines)
  for _, id in ipairs(state.hl_ids[i] or {}) do
    pcall(vim.api.nvim_buf_del_extmark, state.buf, HL_NS, id)
  end
  state.hl_ids[i] = apply_section_hl(state.buf, start_row, sec, collapsed)
  set_modifiable(state.buf, false)

  if state.hooks and state.hooks.on_section_replaced then
    state.hooks.on_section_replaced(sec.path)
  end

  if branch == "above" then
    local delta = #new_lines - (end_row_exclusive - start_row)
    view.topline = math.max(1, view.topline + delta)
    view.lnum = math.max(1, view.lnum + delta)
    vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
  elseif branch == "intersect" then
    if top0 < start_row then
      view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(state.buf))
      vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
    else
      local topline = start_row + 1
      view.topline = topline
      view.lnum = topline
      vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
    end
  end
  -- "below"/"none": nothing to do.
end

--- Collapse or expand section i outright, recording WHOSE decision it was:
--- `intent` is "user" (the default -- a <Tab>/za/<CR>, a sidebar selection, a
--- restored session) or "auto" (the virtualizer's own pass). fold.user_folded
--- reads that back, so navigation steps over what you put away while still
--- landing on what virt merely tidied. Keeping it in this one table is what
--- makes the distinction structural rather than a convention every caller has
--- to remember.
---
--- The guard is on `state.collapsed` rather than on the rendered form, because
--- this records the path's OWN collapse state independently of whether a folded
--- ancestor also happens to be hiding it -- resplice then no-ops when nothing
--- visible changes. An intent-only change (the user taking over a path virt had
--- claimed) is recorded and falls through to a resplice whose span check makes
--- it a no-op, so it needs no special case.
function M.set_collapsed(state, i, collapsed, intent)
  local sec = state.sections[i]
  if not sec then return end
  local want = collapsed and (intent or "user") or nil
  if state.collapsed[sec.path] == want then return end

  state.collapsed[sec.path] = want
  resplice(state, i)
end

--- Bring the canvas to `desired` with the fewest possible splices.
---
--- Both lists are path-sorted, so this is a sorted merge-walk: a section whose
--- old_text AND new_text both match is never touched at all, so its anchors, its
--- highlight marks and its rows survive untouched, and the niri invariant rests
--- entirely on the splice primitives below.
---
--- That "never touched" property is the whole reason this is separate from
--- render_all. It is what makes a live file-watch update cheap, and it is what makes
--- swapping the LENS non-destructive -- most files look identical through two
--- lenses, so pivoting mostly splices nothing and moves nothing.
---
--- Returns true when it had to fall back to a full render_all, which the caller
--- needs to know because that is the case where the canvas may now be the
--- empty-state placeholder rather than sections.
---
--- The caller owns the follow-up sync of the other UI pieces (highlighting,
--- sidebar, scrollbar, virtualizer), mirroring resync_visibility's contract.
function M.reconcile_sections(state, desired)
  -- 0 <-> N transitions: the empty canvas holds a placeholder line, not sections,
  -- so there is nothing for a splice to target. Full re-render instead.
  if #state.sections == 0 or #desired == 0 then
    if #state.sections ~= 0 or #desired ~= 0 then
      M.render_all(state, desired)
      return true
    end
    return false
  end

  local i, j = 1, 1
  while i <= #state.sections or j <= #desired do
    local cur = state.sections[i]
    local des = desired[j]
    if cur and des and cur.path == des.path then
      if cur.old_text ~= des.old_text or cur.new_text ~= des.new_text then
        M.replace_section(state, i, des)
      end
      i, j = i + 1, j + 1
    elseif cur and (not des or cur.path < des.path) then
      if #state.sections == 1 then
        -- Deleting the last remaining section would leave the placeholder-line
        -- empty canvas, which splices can't target; finish with a full render of
        -- whatever is desired instead.
        M.render_all(state, desired)
        return true
      end
      M.replace_section(state, i, nil) -- delete shrinks the list; keep i
    else
      M.insert_section(state, i, des)
      i, j = i + 1, j + 1
    end
  end

  -- Once, at the END of the walk -- never per-delete inside it. This pass deletes
  -- and inserts in one merge, so dropping "src/" the moment its last OLD section
  -- went would un-fold a sibling inserted a step later. Pruning a key that hides
  -- nothing changes no section's rendered form, so there is nothing to re-splice.
  state.folded = fold.prune(state.sections, state.folded)
  return false
end

--- Re-splice sections so the buffer matches the current visibility predicate,
--- for when `state.folded` changed rather than `state.collapsed`. `indices`
--- defaults to every section, which is what revealing a directory needs (it
--- un-hides siblings, not just one file).
---
--- Iterate ASCENDING. Every correction leaves the viewport top sitting exactly
--- at a section boundary, so once the first intersecting section collapses,
--- each later one satisfies `top0 < start_row` and its correction is a no-op.
--- It also makes the behaviour fall out: fold a directory while reading one of
--- its files and you land on that file's placeholder, with the rest collapsing
--- below you. Same N-splices-with-correction shape virt.apply already runs.
---
--- The caller owns the single follow-up sync of the other UI pieces
--- (highlighting / sidebar / scrollbar), mirroring session.restore.
function M.resync_visibility(state, indices)
  if indices then
    for _, i in ipairs(indices) do
      resplice(state, i)
    end
    return
  end
  for i = 1, #state.sections do
    resplice(state, i)
  end
end

return M
