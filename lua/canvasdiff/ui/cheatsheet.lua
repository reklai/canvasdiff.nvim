-- Centered floating cheatsheet listing every keybind the plugin installs.
--
-- A renderer over input.keys + config.keymaps -- this module introduces no
-- new source of keybind truth, so whatever the user overrode, disabled, or
-- multi-bound is exactly what appears. The column model is pure and separate
-- from rendering, so tests can assert placement without a UI.

local keys = require("canvasdiff.input").keys
local config = require("canvasdiff.config")

local M = {}

--- Per-context view of grouped(): action -> row, plus display order.
local function ctx_actions(ctx, keymaps)
  local by_action, order = {}, {}
  for _, g in ipairs(keys.grouped({ ctx }, keymaps)) do
    for _, item in ipairs(g.items) do
      by_action[item.action] = { keys = item.keys, desc = item.desc, group = g.name }
      order[#order + 1] = item.action
    end
  end
  return by_action, order
end

--- One flat unnamed section, or nothing when there are no rows.
local function flat_column(title, rows)
  if #rows == 0 then
    return nil
  end
  return { title = title, sections = { { name = nil, rows = rows } } }
end

--- Canvas keeps its group sub-headers (it is the largest column); order of
--- appearance already follows K.group_order via grouped().
local function grouped_column(title, by_action, order, skip)
  local sections, index = {}, {}
  for _, action in ipairs(order) do
    if not skip[action] then
      local a = by_action[action]
      local sec = index[a.group]
      if not sec then
        sec = { name = a.group, rows = {} }
        index[a.group] = sec
        sections[#sections + 1] = sec
      end
      sec.rows[#sec.rows + 1] = { keys = a.keys, desc = a.desc, action = action }
    end
  end
  if #sections == 0 then
    return nil
  end
  return { title = title, sections = sections }
end

--- Column model for the overlay: `Global | Sidebar | Canvas`.
---
--- Global holds actions available in more than one context with identical
--- keys -- computed, not hardcoded, so a user who diverges e.g. the sidebar
--- close key sees it split honestly into the per-context columns. The
--- file-context `back` binding is global by fiat: it applies outside the
--- plugin's own windows. Empty columns are omitted.
function M.model(keymaps)
  local canvas, canvas_order = ctx_actions("canvas", keymaps)
  local side, side_order = ctx_actions("sidebar", keymaps)
  local file, file_order = ctx_actions("file", keymaps)

  local shared, global_rows = {}, {}
  for _, action in ipairs(canvas_order) do
    local c, s = canvas[action], side[action]
    if s and vim.deep_equal(c.keys, s.keys) then
      shared[action] = true
      global_rows[#global_rows + 1] = { keys = c.keys, desc = c.desc, action = action }
    end
  end
  for _, action in ipairs(file_order) do
    local f = file[action]
    global_rows[#global_rows + 1] = { keys = f.keys, desc = f.desc, action = action }
  end

  local side_rows = {}
  for _, action in ipairs(side_order) do
    if not shared[action] then
      local s = side[action]
      side_rows[#side_rows + 1] = { keys = s.keys, desc = s.desc, action = action }
    end
  end

  local out = {}
  out[#out + 1] = flat_column("Global", global_rows)
  out[#out + 1] = flat_column("Sidebar", side_rows)
  out[#out + 1] = grouped_column("Canvas", canvas, canvas_order, shared)
  return out
end

local GUTTER = 3 -- spaces between columns
local KEY_DESC_GAP = 2

--- One column as its own block of lines plus block-relative highlight spans.
local function column_block(col)
  local lines = { col.title }
  local spans = { { line = 0, col_start = 0, col_end = #col.title, group = "Title" } }
  local key_width = 0
  for _, sec in ipairs(col.sections) do
    for _, row in ipairs(sec.rows) do
      key_width = math.max(key_width, #table.concat(row.keys, " "))
    end
  end
  for _, sec in ipairs(col.sections) do
    if sec.name then
      lines[#lines + 1] = ""
      lines[#lines + 1] = sec.name
      spans[#spans + 1] = { line = #lines - 1, col_start = 0, col_end = #sec.name, group = "Comment" }
    end
    for _, row in ipairs(sec.rows) do
      local ks = table.concat(row.keys, " ")
      lines[#lines + 1] = ks .. string.rep(" ", key_width - #ks + KEY_DESC_GAP) .. row.desc
      spans[#spans + 1] = { line = #lines - 1, col_start = 0, col_end = #ks, group = "Special" }
    end
  end
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  return { lines = lines, spans = spans, width = width }
end

--- Pure renderer over a model: lines, 0-based highlight spans, and the
--- resulting width. Columns sit side by side when they fit inside
--- `max_width`, otherwise they stack vertically in the same order (spec R5).
function M.lines(model, max_width)
  local blocks = {}
  local total = 0
  for i, col in ipairs(model) do
    blocks[i] = column_block(col)
    total = total + blocks[i].width + (i > 1 and GUTTER or 0)
  end

  local lines, spans = {}, {}
  if total <= max_width and #blocks > 1 then
    local height = 0
    for _, b in ipairs(blocks) do
      height = math.max(height, #b.lines)
    end
    local offset = 0
    for _, b in ipairs(blocks) do
      for li = 1, height do
        local prefix = lines[li] or ""
        -- Pad the merged line up to this block's start column.
        prefix = prefix .. string.rep(" ", offset - #prefix)
        lines[li] = prefix .. (b.lines[li] or "")
      end
      for _, s in ipairs(b.spans) do
        spans[#spans + 1] = {
          line = s.line, col_start = s.col_start + offset,
          col_end = s.col_end + offset, group = s.group,
        }
      end
      offset = offset + b.width + GUTTER
    end
  else
    for _, b in ipairs(blocks) do
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      local base = #lines
      for _, l in ipairs(b.lines) do
        lines[#lines + 1] = l
      end
      for _, s in ipairs(b.spans) do
        spans[#spans + 1] = {
          line = s.line + base, col_start = s.col_start,
          col_end = s.col_end, group = s.group,
        }
      end
    end
  end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  return lines, spans, width
end

-- --- float lifecycle ---------------------------------------------------

local ns = vim.api.nvim_create_namespace("canvasdiff_cheatsheet")

-- Singleton, like the canvas itself: two cheatsheets answer no question.
-- Validity is checked lazily so an externally-closed float (":q", tab
-- teardown) needs no autocmd bookkeeping -- events are also unreliable in
-- headless tests.
local state = { win = nil, buf = nil }

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win, state.buf = nil, nil
end

--- Every configured help key, from every context, plus the overlay's own
--- closers. All of them close the open overlay, so the key that summoned it
--- always dismisses it (spec R4).
local function close_keys(keymaps)
  local out, seen = { "q", "<Esc>" }, { q = true, ["<Esc>"] = true }
  for _, ctx in ipairs({ "canvas", "sidebar" }) do
    for _, m in ipairs(keys.resolved(ctx, keymaps)) do
      if m.action == "help" and not seen[m.lhs] then
        seen[m.lhs] = true
        out[#out + 1] = m.lhs
      end
    end
  end
  return out
end

function M.toggle()
  if M.is_open() then
    M.close()
    return
  end
  local km = config.options.keymaps
  local model = M.model(km)
  local max_width = math.max(20, vim.o.columns - 8)
  local lines, spans, width = M.lines(model, max_width)

  -- Handle empty case: if no keybinds are configured, show a placeholder.
  -- `width` was computed by M.lines over the (empty) real lines above, so it
  -- must be recomputed from the placeholder actually being shown -- otherwise
  -- the float clamps to a 1-wide sliver (spec R4 finding).
  if #lines == 0 then
    lines = { "No keybinds configured -- q or <Esc> closes" }
    spans = {}
    width = #lines[1]
  end

  width = math.min(math.max(width, 1), max_width)
  local height = math.max(1, math.min(#lines, math.max(3, vim.o.lines - 6)))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, s in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, ns, s.line, s.col_start, {
      end_col = s.col_end, hl_group = s.group,
    })
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " canvasdiff ",
    title_pos = "center",
  })

  for _, lhs in ipairs(close_keys(km)) do
    vim.keymap.set("n", lhs, M.close,
      { buffer = buf, silent = true, noremap = true, desc = "Close the cheatsheet" })
  end

  state.win, state.buf = win, buf
end

return M
