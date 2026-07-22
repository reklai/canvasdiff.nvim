local render = require("finding_myself.render")
local viewport = require("finding_myself.viewport")

local M = {}

local BUFNAME = "finding-myself://canvas"

local ANCHOR_NS = vim.api.nvim_create_namespace("finding_myself.canvas.anchors")
local HL_NS = vim.api.nvim_create_namespace("finding_myself.canvas.hl")

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
  vim.api.nvim_set_hl(0, "FmFileHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "FmHunkHeader", { link = "Comment", default = true })
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
--- why row-range clearing is not safe here).
local function apply_section_hl(buf, start_row, section)
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
  return ids
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

  local all_lines = {}
  local starts = {}
  for idx, sec in ipairs(sections) do
    starts[idx] = #all_lines
    for _, l in ipairs(render.section_lines(sec)) do
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
    hl_ids[idx] = apply_section_hl(buf, starts[idx], sec)
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
  local start_row, end_row_exclusive = M.section_rows(state, i)
  local new_lines = new_section and render.section_lines(new_section) or {}

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
  if branch == "intersect" and new_section ~= nil then
    if top0 < start_row then
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
    state.hl_ids[i] = apply_section_hl(state.buf, start_row, new_section)
    state.sections[i] = new_section
  else
    pcall(vim.api.nvim_buf_del_extmark, state.buf, ANCHOR_NS, state.anchor_ids[i])
    table.remove(state.anchor_ids, i)
    table.remove(state.sections, i)
    table.remove(state.hl_ids, i)
  end

  set_modifiable(state.buf, false)

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

return M
