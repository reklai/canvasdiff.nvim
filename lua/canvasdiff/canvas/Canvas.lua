local paged = require("canvasdiff.canvas.paged")
local render = require("canvasdiff.canvas.format")
local glyphs = require("canvasdiff.config").glyphs
local diff = require("canvasdiff.diff")
local viewport = diff.anchor
local fold = diff.fold
local model = diff
local lens = diff.lens

local M = {}

-- One review, one buffer. The name carries a monotonic ordinal so two
-- concurrent reviews are distinguishable in `:ls` and can never collide -- a
-- single fixed name is exactly what made a second review impossible.
local BUFNAME_PREFIX = "canvasdiff://canvas/"
local next_canvas_id = 0

local ANCHOR_NS = vim.api.nvim_create_namespace("canvasdiff.canvas.anchors")
local HL_NS = vim.api.nvim_create_namespace("canvasdiff.canvas.hl")

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

local function ensure_hl_groups()
  vim.api.nvim_set_hl(0, "CanvasDiffFileHeader", { link = "Title", default = true })
  -- The background of the file-boundary bar. `Folded` because it is the most visible
  -- of the groups that always carry a background: measured under tokyonight-moon it is
  -- +30 luminance against Normal, where CursorLine manages +15 and ColorColumn is
  -- actually DARKER (-7) -- too subtle for something whose entire job is to be noticed
  -- in peripheral vision as you scroll past. `Visual` is comparable (+26) but is
  -- already the sidebar's active-row colour, and one colour should mean one thing.
  --
  -- Background only matters here: the filename's own colour comes from
  -- CanvasDiffFileHeader above, at a higher priority.
  vim.api.nvim_set_hl(0, "CanvasDiffFileBar", { link = "Folded", default = true })
  -- The diff row tints. Aliases so they are tunable without redefining the groups
  -- your ordinary vimdiff uses -- see the note in render.HL_GROUP.
  --
  -- To quieten them, which is the usual want once you notice how much of the screen
  -- they cover, point them at something with less contrast against Normal:
  --   vim.api.nvim_set_hl(0, "CanvasDiffAdd", { link = "CursorLine" })
  -- Measured under tokyonight-moon: DiffAdd is +27 luminance over Normal and
  -- DiffDelete +13, where CursorLine is +15 and ColorColumn is -7.
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffDel", { link = "DiffDelete", default = true })
  -- Deleted lines, which are virtual rather than buffer rows. Its own group rather
  -- than reusing CanvasDiffDel so you can dim the ghosts without touching anything else --
  -- the usual want, since the point of ghosting a deletion is that it is context for
  -- the line that replaced it rather than a thing to read on its own.
  vim.api.nvim_set_hl(0, "CanvasDiffGhost", { link = "CanvasDiffDel", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffHunkHeader", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffBinary", { link = "Comment", default = true })
  -- CanvasDiffStale and the sidebar's stage markers live in render, next to the glyphs.
  render.ensure_marker_hl()
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

--- Create this review's own canvas buffer.
---
--- Deliberately never reuses one: a review that shared its buffer with another
--- would share its model, its anchors and its extmark namespaces too, and
--- disposing either would rewrite what the other is showing.
local function create_buf()
  next_canvas_id = next_canvas_id + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, BUFNAME_PREFIX .. next_canvas_id)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("undolevels", -1, { buf = buf })
  set_modifiable(buf, false)
  return buf
end

--- The canvas's own text reader, expressed once.
---
--- Production highlighting asks this rather than the buffer, so that swapping
--- in a page-backed store changes one function instead of every caller. It
--- resolves `M.logical` at call time because that is defined below.
local function row_reader(state)
  return function(row0)
    return M.logical(state).row(row0)
  end
end

--- Full-line highlight extmarks for one section, starting at buffer row
--- `start_row` (0-based). Returns the created extmark ids so the caller can
--- track them and delete them precisely later (see replace_section notes on
--- why row-range clearing is not safe here). `collapsed` renders the section
--- as its single placeholder row instead, with one file-header-styled mark.
---
--- `read_row` is how this function learns what text is at a logical row.
---
--- It exists because a page-backed canvas has no text in its buffer at all:
--- the skeleton holds one blank line per logical row so that scrolling, marks
--- and extmark addressing stay exact, and the text is supplied by a decoration
--- provider. Reading through a supplied function rather than calling
--- `nvim_buf_get_lines` directly is what lets the same highlighting code serve
--- both, so the seam is here rather than in a future fork of this function.
local function apply_section_hl(buf, start_row, section, collapsed, read_row)
  read_row = read_row or function(row0)
    return vim.api.nvim_buf_get_lines(buf, row0, row0 + 1, false)[1]
  end
  if collapsed then
    local ids = { vim.api.nvim_buf_set_extmark(buf, HL_NS, start_row, 0, {
      end_row = start_row + 1,
      end_col = 0,
      hl_group = "CanvasDiffFileHeader",
      hl_eol = true,
      priority = 100,
    }) }
    -- Pick the stale marker out of the line that was just written, rather than
    -- taking it as a parameter: every caller here runs after the splice, so reading
    -- it back means the highlight cannot disagree with the text. Priority above the
    -- header mark, whose hl_eol fill covers this range too.
    local line = read_row(start_row) or ""
    if #line >= #glyphs.stale and line:sub(-#glyphs.stale) == glyphs.stale then
      -- Colour, then a bold layer over the same range. The bold is the part that does
      -- not depend on the colourscheme -- see R.marker_spans for why that matters on
      -- the sidebar, and this keeps the canvas placeholder's marker consistent with it.
      for group, prio in pairs({ CanvasDiffStale = 101, CanvasDiffStaleEmphasis = 102 }) do
        ids[#ids + 1] = vim.api.nvim_buf_set_extmark(buf, HL_NS, start_row, #line - #glyphs.stale, {
          end_row = start_row,
          end_col = #line,
          hl_group = group,
          priority = prio,
        })
      end
    end
    return ids
  end
  local marks = render.section_hl(section)
  local ids = {}

  -- A full-width tint across the file header row, so crossing from one file into the
  -- next is visible while you scroll instead of being one more line among diff lines.
  --
  -- `line_hl_group` fills the entire screen line, past the end of the text, so this
  -- needs no window width and survives a resize untouched. A `virt_lines` rule between
  -- sections was the other candidate and is equally safe for the row arithmetic
  -- (verified: buffer line count, header rows, line("w0"), winrestview and ]f are all
  -- unaffected by virtual lines) -- but it would need width management and re-application
  -- on resize to earn the same result.
  --
  -- Priority BELOW the header's own mark, deliberately: CanvasDiffFileHeader links to
  -- Title, which is foreground-only, so the two COMPOSE rather than fight -- Title's
  -- colour and boldness on the text, this group's background across the whole row.
  --
  -- Expanded sections only. A folded placeholder is already one visually distinct row
  -- (it opens with the ▸ glyph) and has no body below it to delimit; barring every one
  -- would turn an auto-virtualized canvas of 200 collapsed files into a solid block.
  ids[#ids + 1] = vim.api.nvim_buf_set_extmark(buf, HL_NS, start_row, 0, {
    line_hl_group = "CanvasDiffFileBar",
    priority = 99,
  })

  -- NO `hl_eol`, and this is the single biggest visual change in the canvas.
  --
  -- With it, an add/del tint filled the rest of the SCREEN LINE, so the coloured area
  -- was proportional to your window width rather than to the size of the change: a
  -- three-character edit painted green to the right edge of a 200-column window. That
  -- is a lot of the strongest visual channel spent on "this line is involved", which
  -- is the least interesting thing on screen once you have word-diff marks saying
  -- which TOKENS changed. Measured budget before this: the row tint stood 27 luminance
  -- clear of Normal while the word-diff mark stood only 9 clear of the row it sat on.
  --
  -- Dropping it costs nothing for the other kinds -- file_hdr, hunk_hdr and binary all
  -- resolve to foreground-only groups (Title, Comment), where hl_eol has nothing to
  -- fill with. The expanded header's full-width bar comes from the CanvasDiffFileBar
  -- line_hl_group above, which is unaffected.
  --
  -- Side effect worth having: syntax highlighting reads at full contrast again. On a
  -- tinted row, @comment sat at only 47 luminance delta against the fill where every
  -- other syntax group had 103-153, so comments inside a diff were measurably muddier
  -- than the code around them.
  for _, m in ipairs(marks) do
    local row = start_row + m.row
    ids[#ids + 1] = vim.api.nvim_buf_set_extmark(buf, HL_NS, row, 0, {
      end_row = row + 1,
      end_col = 0,
      hl_group = m.group,
      priority = 100,
    })
  end

  -- Deleted lines, drawn as virtual lines rather than buffer rows. They cost zero
  -- buffer lines, which is the whole reason the result view leaves every piece of row
  -- arithmetic in this file untouched -- see the note in diff.build_section's `push`.
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
--- it is folded -- the file itself, or an ancestor
--- directory -- else its full body.
---
--- The placeholder carries the stale marker when the file has moved on since the
--- user put it away. Asked here rather than passed in, for the same reason the
--- collapsed/expanded form is derived here: this is the one place a placeholder is
--- ever written to the buffer, so it is the one place that cannot disagree.
local function section_lines_for(state, sec)
  if fold.hidden(state, sec.path) then
    local l = lens.of(state)
    return { render.placeholder(sec,
      fold.stale(state, sec.path, model.fingerprint(sec), l.id)) }
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

--- Is this buffer a review canvas?
---
--- A name test rather than a registry lookup, so this stays a pure predicate
--- that no live ownership state can go stale against.
--- This canvas's logical text: the rows it is showing, addressed by logical
--- row index rather than by buffer line.
---
--- The seam a page-backed canvas plugs into. Eager rendering puts every
--- logical row in the buffer, so here the two are the same thing -- but every
--- caller that asks "what text is at rows N..M" must ask through this, or it
--- silently means "what buffer LINES are there", which a paged canvas does not
--- have. `export` matches Projection:export so the two are interchangeable.
--- @param state table
--- @return table logical
function M.logical(state)
  if state and state.paged then
    return paged.logical(state.paged)
  end
  local function buffer()
    local buf = state and state.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
      return buf
    end
    return nil
  end

  local logical = {}

  function logical.row_count()
    local buf = buffer()
    return buf and vim.api.nvim_buf_line_count(buf) or 0
  end

  function logical.rows(start0, count)
    local buf = buffer()
    if not buf then
      return nil, "canvas buffer is unavailable"
    end
    if type(start0) ~= "number" or start0 < 0 or start0 % 1 ~= 0 then
      return nil, "logical start row must be a non-negative integer"
    end
    if type(count) ~= "number" or count < 0 or count % 1 ~= 0 then
      return nil, "logical row count must be a non-negative integer"
    end
    local total = vim.api.nvim_buf_line_count(buf)
    if start0 + count > total then
      return nil, "logical row range exceeds the canvas"
    end
    if count == 0 then
      return {}
    end
    return vim.api.nvim_buf_get_lines(buf, start0, start0 + count, true)
  end

  function logical.row(row0)
    local rows, err = logical.rows(row0, 1)
    if not rows then
      return nil, err
    end
    return rows[1]
  end

  function logical.export(start0, count, opts)
    opts = opts or {}
    local separator = opts.separator
    if separator == nil then
      separator = "\n"
    elseif type(separator) ~= "string" then
      return nil, "export separator must be a string"
    end
    local terminal_eol = opts.terminal_eol
    if terminal_eol == nil then
      terminal_eol = false
    elseif type(terminal_eol) ~= "boolean" then
      return nil, "export terminal_eol must be a boolean"
    end
    local rows, err = logical.rows(start0, count)
    if not rows then
      return nil, err
    end
    local result = table.concat(rows, separator)
    if terminal_eol and count > 0 then
      result = result .. separator
    end
    return result
  end

  return logical
end

function M.is_canvas_buf(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name:sub(1, #BUFNAME_PREFIX) == BUFNAME_PREFIX
    and name:sub(#BUFNAME_PREFIX + 1):match("^%d+$") ~= nil
end

--- Clears the buffer and re-renders every section from scratch, placing one
--- left-gravity anchor per section start plus an EOF sentinel, and applying
--- line-tier highlights. Populates state.sections/anchor_ids/hl_ids.
--- The visibility predicates the paged renderer needs, expressed against the
--- same state the eager path reads, so both paths fold identically.
local function paged_opts(state)
  return {
    collapsed = function(path) return fold.hidden(state, path) end,
    stale = function(section)
      local l = lens.of(state)
      return fold.stale(state, section.path, model.fingerprint(section),
        l and l.id or nil)
    end,
  }
end

function M.render_all(state, sections)
  if state and state.paged then
    state.sections = sections
    assert(paged.render_all(state.paged, sections, paged_opts(state)))
    state.rendered_hidden = {}
    for _, section in ipairs(sections) do
      state.rendered_hidden[section.path] = fold.hidden(state, section.path)
    end
    return
  end
  return M.render_all_eager(state, sections)
end

function M.render_all_eager(state, sections)
  local buf = state.buf
  -- Before the line build, which reads fold.hidden: a fold key whose directory
  -- no longer has any changes must not fold a file that appears there
  -- later. Covers open, refresh and watch's full-render paths at once.
  state.folded = fold.prune(sections, state.folded)
  set_modifiable(buf, true)
  vim.api.nvim_buf_clear_namespace(buf, ANCHOR_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, HL_NS, 0, -1)

  if state.hooks and state.hooks.on_render_all then
    state.hooks.on_render_all()
  end

  local all_lines = {}
  local starts = {}
  state.rendered_hidden = {}
  for idx, sec in ipairs(sections) do
    starts[idx] = #all_lines
    state.rendered_hidden[sec.path] = fold.hidden(state, sec.path)
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
    hl_ids[idx] = apply_section_hl(
      buf, starts[idx], sec, fold.hidden(state, sec.path), row_reader(state))
  end
  local eof_row = #sections > 0 and #all_lines or 0
  anchor_ids[#sections + 1] = vim.api.nvim_buf_set_extmark(buf, ANCHOR_NS, eof_row, 0, ANCHOR_OPTS)

  state.sections = sections
  state.anchor_ids = anchor_ids
  state.hl_ids = hl_ids
  set_modifiable(buf, false)
end

--- Creates this review's own scratch canvas buffer, shows it in the current
--- window, and renders `sections`.
function M.open(sections, opts)
  opts = opts or {}
  ensure_hl_groups()
  local buf = create_buf()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  apply_win_opts(win)

  -- `collapsed` maps a path to "user" or "auto" (see M.set_collapsed); `folded`
  -- is a set of directory paths with a trailing slash, owned by the sidebar but
  -- living here because rendering, navigation and session all derive from it.
  --
  -- render_all never writes either field, so a refresh() on an already-open
  -- state keeps whatever the user has collapsed or folded away. It does NOT
  -- follow that a reopen keeps them: this hands back a fresh state every time,
  -- so surviving close/open is entirely session.restore putting them back.
  local state = {
    buf = buf,
    win = win,
    sections = {},
    anchor_ids = {},
    hl_ids = {},
    collapsed = {},
    folded = {},
    -- Actual form currently present in the buffer, independent of row count.
    -- Normally span == 1 implied "placeholder"; a pure rename's expanded form
    -- is also one header row, so resplice needs this explicit discriminator.
    rendered_hidden = {},
    -- `folded_seen[path]` is what a section's content looked like when the user put
    -- it away (diff.fingerprint), or `false` for one that arrived already hidden.
    -- fold.stale compares it against the section's content now.
    folded_seen = {},
  }
  M.render_all(state, sections)
  return state
end

--- Open a PAGE-BACKED review in the current window.
---
--- Same state shape as `M.open`, so every reader -- sidebar, status column,
--- scrollbar, motions, session -- keeps working: what changes is that the text
--- lives in a store and the buffer is a blank skeleton with one row per
--- logical row. `anchor_ids` and `hl_ids` stay empty because a paged canvas
--- has nothing to anchor: its starts array is authoritative.
function M.open_paged(sections, opts)
  opts = opts or {}
  ensure_hl_groups()

  local state = {
    buf = nil,
    win = vim.api.nvim_get_current_win(),
    sections = {},
    anchor_ids = {},
    hl_ids = {},
    collapsed = {},
    folded = {},
    rendered_hidden = {},
    folded_seen = {},
  }

  local built, err = paged.render(sections, paged_opts(state))
  if not built then
    return nil, err
  end
  state.paged = built
  state.buf = built.buffer
  state.sections = sections
  built.state = state
  for _, section in ipairs(sections) do
    state.rendered_hidden[section.path] = fold.hidden(state, section.path)
  end

  vim.api.nvim_win_set_buf(state.win, state.buf)
  apply_win_opts(state.win)
  return state
end

--- Note activity on a canvas, so a paged one can defer compaction.
---
--- Accepts either kind: an eager canvas has nothing to defer, and an activity
--- hook should not have to know which it is looking at.
function M.touch(state)
  if state and state.paged then
    return paged.touch(state.paged)
  end
  return true
end

--- Release a paged canvas's store and projection.
---
--- The eager canvas has nothing to dispose -- its buffer is the state. A paged
--- one owns a projection and a skeleton buffer, and leaving them behind is a
--- leak of exactly the kind the resume contract forbids.
function M.dispose(state)
  if state and state.paged then
    local built = state.paged
    state.paged = nil
    return paged.dispose(built)
  end
  return true
end

--- Show an existing canvas state in `win` without rebuilding its model or
--- anchors. This is a second view of one review, not a new review lifetime.
function M.show(state, win)
  win = win or vim.api.nvim_get_current_win()
  if not (state and state.buf and vim.api.nvim_buf_is_valid(state.buf)
      and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  vim.api.nvim_win_set_buf(win, state.buf)
  apply_win_opts(win)
  state.win = win
  return true
end

--- 0-based [start_row, end_row_exclusive) for section i, resolved live from
--- extmarks -- never cached.
function M.section_rows(state, i)
  if state and state.paged then
    return paged.section_rows(state.paged, i)
  end
  return get_row(state, state.anchor_ids[i]), get_row(state, state.anchor_ids[i + 1])
end

--- Binary search over section start anchors for the section containing
--- 0-based buffer row `row0`. Returns section index and 1-based offset into
--- that section's entries, or nil if there are no sections.
function M.locate(state, row0)
  if state and state.paged then
    return paged.locate(state.paged, row0)
  end
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

local function win_showing_canvas(state, win)
  win = win or state.win
  return win and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_buf(win) == state.buf
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
  if state.paged then
    local ok, err = paged.replace_section(
      state.paged, i, new_section, paged_opts(state))
    if ok then
      state.sections = state.paged.sections
      if new_section then
        state.rendered_hidden[new_section.path] =
          fold.hidden(state, new_section.path)
      end
    end
    return ok, err
  end

  local replaced_path = state.sections[i] and state.sections[i].path
  state.rendered_hidden = state.rendered_hidden or {}
  local was_collapsed = replaced_path ~= nil and state.rendered_hidden[replaced_path]
  if was_collapsed == nil and replaced_path ~= nil then
    was_collapsed = fold.hidden(state, replaced_path)
  end
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
  -- A section that was already folded needs no correction at all, whatever the
  -- viewport is doing. Both callers replace the SAME path (watch only when
  -- cur.path == des.path; jump.back rebuilds ex.path), so a placeholder is being
  -- replaced by a placeholder: one row for one row, nothing above or below it
  -- moves. Only the counts in its text change. Correcting anyway is how a
  -- background write -- `:w` from another split, a formatter -- used to yank the
  -- cursor to the top of the window whenever the placeholder was the top row.
  if branch == "intersect" and new_section ~= nil then
    if was_collapsed or top0 < start_row then
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
    local hidden = fold.hidden(state, new_section.path)
    state.hl_ids[i] = apply_section_hl(
      state.buf, start_row, new_section, hidden, row_reader(state))
    state.sections[i] = new_section
    if replaced_path and replaced_path ~= new_section.path then
      state.rendered_hidden[replaced_path] = nil
    end
    state.rendered_hidden[new_section.path] = hidden
  else
    pcall(vim.api.nvim_buf_del_extmark, state.buf, ANCHOR_NS, state.anchor_ids[i])
    table.remove(state.anchor_ids, i)
    table.remove(state.sections, i)
    table.remove(state.hl_ids, i)
    -- The path is gone from the canvas; drop its collapsed flag and its
    -- fold fingerprint too, so a different file that later reuses this path
    -- doesn't inherit either.
    if replaced_path and state.collapsed then
      state.collapsed[replaced_path] = nil
    end
    if replaced_path and state.folded_seen then
      state.folded_seen[replaced_path] = nil
    end
    if replaced_path then
      state.rendered_hidden[replaced_path] = nil
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
      -- Nothing at or above the viewport top moved: either the top sat above the
      -- replaced section, or the section was folded and the splice swapped one
      -- placeholder row for another. Either way the captured view is still
      -- correct. Only clamp lnum, in case the cursor itself was inside the
      -- replaced range and the buffer is now shorter than the cursor's old row.
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

--- Inserts `section` BEFORE current section index i (i = #sections + 1
--- appends at EOF), correcting the view in the same synchronous tick so the
--- niri invariant holds. Precondition: the canvas is non-empty
--- (#state.sections >= 1) -- the 0 -> N transition goes through render_all.
function M.insert_section(state, i, section)
  if state.paged then
    local ok, err = paged.insert_section(
      state.paged, i, section, paged_opts(state))
    if ok then
      state.sections = state.paged.sections
      state.rendered_hidden[section.path] = fold.hidden(state, section.path)
    end
    return ok, err
  end

  local row = get_row(state, state.anchor_ids[i])
  -- Born under a live fold: the user has never seen this file, so it cannot be
  -- what they reviewed. `false` compares unequal to every real fingerprint, so
  -- fold.stale reports it without needing a case of its own. Recorded BEFORE the
  -- line build, which is what puts the marker on the very first render.
  if fold.user_folded(state, section.path) then
    state.folded_seen[section.path] = { lens = lens.of(state).id, fp = false }
  end
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
  state.rendered_hidden = state.rendered_hidden or {}
  state.rendered_hidden[section.path] = fold.hidden(state, section.path)
  table.insert(state.hl_ids, i,
    apply_section_hl(state.buf, row, section, fold.hidden(state, section.path),
      row_reader(state)))
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
--- with the same same-tick view correction as replace_section (a folded
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
local function resplice(state, i, preferred_win)
  local sec = state.sections[i]
  if not sec then return end

  -- A paged canvas re-renders one section by splicing its store, and needs no
  -- view correction: rows above the splice keep their numbers, so the viewport
  -- is already where it was.
  if state.paged then
    local hidden = fold.hidden(state, sec.path)
    if state.paged.collapsed[i] ~= hidden then
      paged.set_collapsed(state.paged, i, hidden, paged_opts(state))
    else
      paged.replace_section(state.paged, i, sec, paged_opts(state))
    end
    state.rendered_hidden[sec.path] = hidden
    return
  end

  local start_row, end_row_exclusive = M.section_rows(state, i)
  if not (start_row and end_row_exclusive) then return end

  local collapsed = fold.hidden(state, sec.path)

  -- Remember what this looked like as it went away, so fold.stale can tell later
  -- that it moved on. BEFORE the early-out below, deliberately: a section the
  -- virtualizer had already reduced to one row flips no form when the user then
  -- folds its parent, but it has still just become something they put away and
  -- needs a fingerprint. Only for what the USER folded -- virt's own collapses
  -- were never a decision, so they cannot go stale.
  --
  -- The `== nil` guard is load-bearing. resync_visibility resplices every section
  -- on any fold change, so without it a still-folded file would be re-recorded
  -- at its current content and quietly count as seen again.
  if fold.user_folded(state, sec.path) then
    if state.folded_seen[sec.path] == nil then
      state.folded_seen[sec.path] = { lens = lens.of(state).id, fp = model.fingerprint(sec) }
    end
  else
    state.folded_seen[sec.path] = nil -- back on screen: you have seen it now
  end

  -- Already in the desired form -- answered WITHOUT building the lines, because
  -- the no-indices resync_visibility asks this of every section on every <Tab>
  -- over a placeholder and on every session.restore. Rendering a whole
  -- changeset's worth of strings just to compare would make a keypress that
  -- splices nothing cost a full re-render.
  --
  -- render.section_lines emits exactly one line per entry, so #entries is the
  -- expanded height (virt.natural_line_count relies on the same identity). Row
  -- span alone is no longer a form discriminator: a pure rename deliberately has
  -- one file-header entry, exactly the same height as its collapsed placeholder.
  -- rendered_hidden records which of those two one-row forms is actually in the
  -- buffer. The span check remains as an integrity guard for legacy/test states.
  local want_rows = collapsed and 1 or #sec.entries
  local have_rows = end_row_exclusive - start_row
  state.rendered_hidden = state.rendered_hidden or {}
  local rendered = state.rendered_hidden[sec.path]
  if have_rows == want_rows and rendered == collapsed then
    return
  end
  if have_rows == want_rows and rendered == nil and #sec.entries > 1 then
    -- A state created before rendered_hidden existed can still establish the
    -- unambiguous multi-row/placeholder form without a redundant splice.
    state.rendered_hidden[sec.path] = collapsed
    return
  end

  local new_lines = section_lines_for(state, sec)

  local view_win = preferred_win or state.win
  local win_ok = win_showing_canvas(state, view_win)
  local branch, top0, view
  if win_ok then
    local info = win_view_info(view_win)
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
  state.hl_ids[i] = apply_section_hl(
    state.buf, start_row, sec, collapsed, row_reader(state))
  state.rendered_hidden[sec.path] = collapsed
  set_modifiable(state.buf, false)

  if state.hooks and state.hooks.on_section_replaced then
    state.hooks.on_section_replaced(sec.path)
  end

  if branch == "above" then
    local delta = #new_lines - (end_row_exclusive - start_row)
    view.topline = math.max(1, view.topline + delta)
    view.lnum = math.max(1, view.lnum + delta)
    vim.api.nvim_win_call(view_win, function() vim.fn.winrestview(view) end)
  elseif branch == "intersect" then
    if top0 < start_row then
      view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(state.buf))
      vim.api.nvim_win_call(view_win, function() vim.fn.winrestview(view) end)
    else
      local topline = start_row + 1
      view.topline = topline
      view.lnum = topline
      vim.api.nvim_win_call(view_win, function() vim.fn.winrestview(view) end)
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
---
--- `preferred_win`, when supplied, is the one Canvas view whose viewport is
--- corrected; it does not re-elect `state.win`.
function M.set_collapsed(state, i, collapsed, intent, preferred_win)
  local sec = state.sections[i]
  if not sec then return end
  if state.paged then
    -- The paged canvas splices its own store and keeps its own starts, so it
    -- neither has anchors to repair nor a view to preserve by row arithmetic.
    state.collapsed[sec.path] = collapsed and (intent or "user") or nil
    paged.set_collapsed(state.paged, i, collapsed)
    return
  end
  local want = collapsed and (intent or "user") or nil
  if state.collapsed[sec.path] == want then return end

  state.collapsed[sec.path] = want
  resplice(state, i, preferred_win)
end

--- Bring the canvas to `desired` with the fewest possible splices.
---
--- Both lists are path-sorted, so this is a sorted merge-walk: a section whose
--- source identity, status and two texts all match is never touched at all, so
--- its anchors, its highlight marks and its rows survive untouched, and the
--- niri invariant rests entirely on the splice primitives below.
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
local RECONCILE_FIELDS = {
  "old_path",
  "old_rev",
  "status",
  "staged",
  "unstaged",
  "old_fingerprint",
  "new_fingerprint",
}

local function same_section(cur, desired)
  for _, field in ipairs(RECONCILE_FIELDS) do
    if cur[field] ~= desired[field] then
      return false
    end
  end
  return true
end

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
      if not same_section(cur, des) then
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
--- `preferred_win` selects the one Canvas view corrected by every splice and
--- leaves the historical scalar primary untouched.
function M.resync_visibility(state, indices, preferred_win)
  if indices then
    for _, i in ipairs(indices) do
      resplice(state, i, preferred_win)
    end
    return
  end
  for i = 1, #state.sections do
    resplice(state, i, preferred_win)
  end
end

return M
