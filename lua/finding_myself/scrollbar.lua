local S = {}

--- One kind per canvas line, sections in render order. hunk_hdr counts as
--- "ctx" (structural, uncolored); file_hdr becomes "hdr" (boundary rows).
function S.line_kinds(sections)
  local kinds = {}
  for _, section in ipairs(sections) do
    for _, e in ipairs(section.entries) do
      if e.kind == "file_hdr" then
        kinds[#kinds + 1] = "hdr"
      elseif e.kind == "add" or e.kind == "del" then
        kinds[#kinds + 1] = e.kind
      else
        kinds[#kinds + 1] = "ctx"
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
      end
    end

    local char, hl = " ", nil
    if has_hdr then
      char, hl = "─", "FmScrollFile"
    elseif has_add and has_del then
      char, hl = "│", "FmScrollChanged"
    elseif has_add then
      char, hl = "│", "FmScrollAdd"
    elseif has_del then
      char, hl = "│", "FmScrollDel"
    end

    -- Thumb: this row's non-empty bucket intersects the viewport line
    -- range. Empty buckets (lo == hi, when n < height) are blank and never
    -- claim the thumb.
    local thumb = hi > lo and lo <= bot0 and hi > top0

    cells[r] = { char = char, hl = hl, thumb = thumb }
  end

  return cells
end

local NS = vim.api.nvim_create_namespace("finding_myself.scrollbar")

-- Module singleton (Phase 4 discipline): callbacks resolve bar.state at
-- call time; every window op liveness-guarded; close() safe always.
local bar = nil

local function ensure_hl_groups()
  vim.api.nvim_set_hl(0, "FmScrollFile", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "FmScrollAdd", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "FmScrollDel", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "FmScrollChanged", { link = "DiffChange", default = true })
  vim.api.nvim_set_hl(0, "FmScrollThumb", { link = "PmenuThumb", default = true })
end

function S.is_open()
  return bar ~= nil and bar.win ~= nil and vim.api.nvim_win_is_valid(bar.win)
end

local function canvas_showing(state)
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

local function float_config(state)
  return {
    relative = "win",
    win = state.win,
    row = 0,
    col = vim.api.nvim_win_get_width(state.win) - 1,
    width = 1,
    height = vim.api.nvim_win_get_height(state.win),
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
  local height = vim.api.nvim_win_get_height(state.win)
  local cells = S.column(S.line_kinds(state.sections), height, info.top0, info.bot0)

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
        line_hl_group = "FmScrollThumb",
        priority = 200,
      })
    end
  end
end

function S.close()
  if bar then
    local b = bar
    bar = nil
    pcall(vim.api.nvim_del_augroup_by_name, "finding_myself.scrollbar")
    if b.win and vim.api.nvim_win_is_valid(b.win) then
      pcall(vim.api.nvim_win_close, b.win, true)
    end
    if b.buf and vim.api.nvim_buf_is_valid(b.buf) then
      pcall(vim.api.nvim_buf_delete, b.buf, { force = true })
    end
  end
end

local function install_autocmds(state)
  local aug = vim.api.nvim_create_augroup("finding_myself.scrollbar", { clear = true })
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
      vim.schedule(S.close)
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
