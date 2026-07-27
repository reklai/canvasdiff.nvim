-- Centered floating cheatsheet listing every keybind the plugin installs.
--
-- A renderer over input.keys + config.keymaps -- this module introduces no
-- new source of keybind truth, so whatever the user overrode, disabled, or
-- multi-bound is exactly what appears. The column model is pure and separate
-- from rendering, so tests can assert placement without a UI.

local keys = require("canvasdiff.input").keys
local config = require("canvasdiff.config")

local M = {}

--- Rows of one grouped() section, in the shape the renderer consumes.
local function section_rows(items)
  local rows = {}
  for _, item in ipairs(items) do
    rows[#rows + 1] = { keys = item.keys, desc = item.desc, action = item.action }
  end
  return rows
end

--- Column model for the overlay: `Sidebar | Canvas`.
---
--- Each column is self-contained: everything you can press in that window,
--- nothing you can't. A key living in both contexts (`q`, the help key)
--- appears in both columns, each row carrying its own context's description
--- -- `q` closes the whole review on the canvas but only the sidebar when
--- pressed there, and a merged "Global" row could only blur that. The
--- file-context `back` binding rides in the Canvas column's Jump section,
--- beside the jump that created the excursion (grouped() already folds it
--- there). The Sidebar column is a flat list; Canvas, the largest column,
--- keeps its group sub-headers. Empty columns are omitted.
function M.model(keymaps)
  local out = {}

  local side_rows = {}
  for _, g in ipairs(keys.grouped({ "sidebar" }, keymaps)) do
    for _, row in ipairs(section_rows(g.items)) do
      side_rows[#side_rows + 1] = row
    end
  end
  if #side_rows > 0 then
    out[#out + 1] = { title = "Sidebar", sections = { { name = nil, rows = side_rows } } }
  end

  local sections = {}
  for _, g in ipairs(keys.grouped({ "canvas", "file" }, keymaps)) do
    sections[#sections + 1] = { name = g.name, rows = section_rows(g.items) }
  end
  if #sections > 0 then
    out[#out + 1] = { title = "Canvas", sections = sections }
  end

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
