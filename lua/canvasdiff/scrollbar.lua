local fold = require("canvasdiff.diff").fold
local render = require("canvasdiff.render")

local S = {}

--- The minimap's two glyphs: a file boundary and a stretch of changed lines.
---
--- ‒ (U+2012 FIGURE DASH) and ❘ (U+2758 LIGHT VERTICAL BAR) rather than the
--- box-drawing ─ and │ they replace, and the reason is WIDTH, not looks.
---
--- This float is ONE column wide. Every box-drawing and block-element glyph is East
--- Asian Ambiguous, so under `ambiwidth=double` -- which CJK users set, and which is a
--- legitimate setting rather than a misconfiguration -- ─ and │ become two cells and
--- cannot fit the window they are drawn in. Measured: 13 of 21 rows held a two-cell
--- glyph in a width-1 float. These two are the most solid-looking glyphs that stay one
--- cell in BOTH modes, so the minimap is correct either way with no detection needed.
---
--- Named rather than inlined so the tests assert against these instead of their own
--- copies of the literals -- they did, and both drifted the moment these changed.
---
--- Keep any replacement width-stable: check `vim.fn.strwidth` under both `ambiwidth`
--- values before swapping one in. ─ ━ │ ┃ ▏ ▎ ▕ ┆ – — ‾ all fail that test.

--- One kind per canvas line, sections in render order. hunk_hdr counts as
--- "ctx" (structural, uncolored); file_hdr becomes "hdr" (boundary rows). A
--- folded section (`hidden[section.path]` truthy) renders as its single
--- placeholder row -- exactly one "hdr" entry. Callers build the set with
--- fold.hidden_set, which keeps this function pure over plain tables;
--- `hidden` is optional so pre-Tier-2 callers keep working unchanged.
function S.line_kinds(sections, hidden)
  hidden = hidden or {}
  local kinds = {}
  for _, section in ipairs(sections) do
    if hidden[section.path] then
      kinds[#kinds + 1] = "hdr"
    else
      for _, e in ipairs(section.entries) do
        if e.kind == "file_hdr" then
          kinds[#kinds + 1] = "hdr"
        elseif e.ghosts or e.ghosts_after then
          -- Deletions are not rows any more -- they ride on the row that follows them
          -- as virtual lines. Without this branch the minimap would lose every trace
          -- of deletion density, because there is no "del" row left to count. "mod"
          -- means this row carries both: a replaced line reads as add AND del, which
          -- is what it actually is.
          kinds[#kinds + 1] = "mod"
        elseif e.kind == "add" or e.kind == "del" then
          kinds[#kinds + 1] = e.kind
        else
          kinds[#kinds + 1] = "ctx"
        end
      end
    end
  end
  return kinds
end

--- Bucket per-line kinds into `height` display cells. Row r (1-based)
--- covers 0-based canvas lines [floor((r-1)*n/H), floor(r*n/H)).
--- cell = { char, hl (nil = blank), thumb } per the phase contract.
function S.column(kinds, height, top0, bot0)
  local cells = {}
  if height <= 0 then
    return cells
  end
  local n = #kinds

  for r = 1, height do
    local lo = math.floor((r - 1) * n / height)
    local hi = math.floor(r * n / height) -- exclusive

    local has_hdr, has_add, has_del = false, false, false
    for i = lo + 1, hi do
      local k = kinds[i]
      if k == "hdr" then
        has_hdr = true
      elseif k == "add" then
        has_add = true
      elseif k == "del" then
        has_del = true
      elseif k == "mod" then
        -- One row carrying both facts: an added line with deleted lines ghosted above
        -- it. Counting it as add-only would make every modification look like pure
        -- growth on the minimap.
        has_add, has_del = true, true
      end
    end

    local char, hl = " ", nil
    if has_hdr then
      char, hl = render.glyphs.scroll_file, "CanvasDiffScrollFile"
    elseif has_add and has_del then
      char, hl = render.glyphs.scroll_bar, "CanvasDiffScrollChanged"
    elseif has_add then
      char, hl = render.glyphs.scroll_bar, "CanvasDiffScrollAdd"
    elseif has_del then
      char, hl = render.glyphs.scroll_bar, "CanvasDiffScrollDel"
    end

    -- Thumb: this row's non-empty bucket intersects the viewport line
    -- range. Empty buckets (lo == hi, when n < height) are blank and never
    -- claim the thumb.
    local thumb = hi > lo and lo <= bot0 and hi > top0

    cells[r] = { char = char, hl = hl, thumb = thumb }
  end

  return cells
end

local NS = vim.api.nvim_create_namespace("canvasdiff.scrollbar")

-- Module singleton (Phase 4 discipline): callbacks resolve bar.state at
-- call time; every window op liveness-guarded; close() safe always.
local bar = nil

local function ensure_hl_groups()
  vim.api.nvim_set_hl(0, "CanvasDiffScrollFile", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffScrollAdd", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffScrollDel", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffScrollChanged", { link = "DiffChange", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffScrollThumb", { link = "PmenuThumb", default = true })
end

function S.is_open()
  return bar ~= nil and bar.win ~= nil and vim.api.nvim_win_is_valid(bar.win)
end

local function canvas_showing(state)
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

--- The canvas window's TEXT geometry: how many rows actually hold buffer lines, and
--- how far down the first of them starts.
---
--- Verified empirically: `nvim_win_get_height` INCLUDES the winbar row, while
--- `getwininfo().height` excludes it -- and a float opened `relative = "win", row = 0`
--- lands at the window's origin, i.e. on top of the winbar. So a full-height
--- right-edge float sized from nvim_win_get_height is one row too tall AND one row
--- too high the moment a winbar exists, which it now does (App sets one to show the
--- current lens). Both numbers have to come from getwininfo.
local function text_geometry(win)
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return { height = 0, row = 0 }
  end
  return { height = info.height, row = info.winbar or 0 }
end

local function float_config(state)
  local geo = text_geometry(state.win)
  return {
    relative = "win",
    win = state.win,
    row = geo.row,
    col = vim.api.nvim_win_get_width(state.win) - 1,
    width = 1,
    height = geo.height,
    focusable = false,
    style = "minimal",
    zindex = 40,
  }
end

local function hide()
  if bar and bar.win and vim.api.nvim_win_is_valid(bar.win) then
    pcall(vim.api.nvim_win_close, bar.win, true)
  end
  if bar then
    bar.win = nil
  end
end

--- Redraw (and re-show/reposition if needed) the bar for the live canvas.
--- Never opened yet or canvas hidden => hide/no-op; the singleton survives
--- hiding so BufWinEnter can re-show it.
function S.update(state)
  if not bar then
    return
  end
  state = state or bar.state
  if not canvas_showing(state) then
    hide()
    return
  end

  -- A squashed window (winminheight=0) reports height 0; a zero-height
  -- float is invalid. Hide and let WinResized/BufWinEnter re-show later.
  if text_geometry(state.win).height < 1 then
    hide()
    return
  end

  if not (bar.buf and vim.api.nvim_buf_is_valid(bar.buf)) then
    bar.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = bar.buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bar.buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = bar.buf })
  end
  if not (bar.win and vim.api.nvim_win_is_valid(bar.win)) then
    bar.win = vim.api.nvim_open_win(bar.buf, false, float_config(state))
  else
    vim.api.nvim_win_set_config(bar.win, float_config(state))
  end

  local info = vim.api.nvim_win_call(state.win, function()
    return { top0 = vim.fn.line("w0") - 1, bot0 = vim.fn.line("w$") - 1 }
  end)
  local height = text_geometry(state.win).height
  local hidden = fold.hidden_set(state.sections, state.collapsed, state.folded)
  local cells = S.column(S.line_kinds(state.sections, hidden), height, info.top0, info.bot0)

  local lines = {}
  for r = 1, #cells do
    lines[r] = cells[r].char
  end
  vim.api.nvim_buf_set_lines(bar.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bar.buf, NS, 0, -1)
  for r, cell in ipairs(cells) do
    if cell.hl then
      vim.api.nvim_buf_set_extmark(bar.buf, NS, r - 1, 0, {
        line_hl_group = cell.hl,
        priority = 100,
      })
    end
    if cell.thumb then
      vim.api.nvim_buf_set_extmark(bar.buf, NS, r - 1, 0, {
        line_hl_group = "CanvasDiffScrollThumb",
        priority = 200,
      })
    end
  end
end

function S.close()
  if bar then
    local b = bar
    bar = nil
    pcall(vim.api.nvim_del_augroup_by_name, "canvasdiff.scrollbar")
    if b.win and vim.api.nvim_win_is_valid(b.win) then
      pcall(vim.api.nvim_win_close, b.win, true)
    end
    if b.buf and vim.api.nvim_buf_is_valid(b.buf) then
      pcall(vim.api.nvim_buf_delete, b.buf, { force = true })
    end
  end
end

local function install_autocmds(state)
  local aug = vim.api.nvim_create_augroup("canvasdiff.scrollbar", { clear = true })
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
    group = aug,
    callback = function(ev)
      local b = bar
      if not b then
        return
      end
      local w = tonumber(ev.match)
      if ev.event == "WinResized" or w == b.state.win then
        S.update(b.state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = aug,
    buffer = state.buf,
    callback = function()
      local b = bar
      if b then
        b.state.win = vim.api.nvim_get_current_win()
        S.update(b.state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = aug,
    buffer = state.buf,
    callback = function()
      -- The canvas buffer just left a window (jump excursion's :edit, or
      -- any buffer switch); if it no longer shows in state.win, hide the
      -- float instead of letting it sit over the real file. At this point
      -- in the event the window still transiently reports the OLD buffer
      -- (the canvas), so canvas_showing would wrongly read "still
      -- showing" if checked synchronously; defer to let the switch land.
      local b = bar
      if b then
        vim.schedule(function()
          if bar == b then
            S.update(b.state)
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    pattern = tostring(state.win),
    callback = function()
      local owner = bar
      vim.schedule(function()
        if bar == owner then
          S.close()
        end
      end)
    end,
  })
end

--- Open (or rebind) the scrollbar for the live canvas state.
function S.open(state, opts)
  opts = opts or {}
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  ensure_hl_groups()
  if bar then
    bar.state = state
    install_autocmds(state)
    S.update(state)
    return
  end
  bar = { buf = nil, win = nil, state = state }
  install_autocmds(state)
  S.update(state)
end

return S
