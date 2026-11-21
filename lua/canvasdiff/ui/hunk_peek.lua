-- On-demand floating hunk inspector with real interleaved `-` / `+` lines and
-- symmetric intra-line word-diff emphasis.
--
-- Keeps the main canvas clean as a result-view workspace while providing an
-- instant escape hatch (`K`) when inspecting subtle edits or yanking/searching
-- deleted lines directly from a real buffer.
local appearance = require("canvasdiff.appearance")
local config = require("canvasdiff.config")
local diff = require("canvasdiff.diff")
local keys = require("canvasdiff.input").keys
local format = require("canvasdiff.canvas").format

local M = {}

local NS = vim.api.nvim_create_namespace("canvasdiff.hunk_peek")
local state = { win = nil, buf = nil }

--- Build the pure rendered buffer content and extmark specs for one hunk.
--- Returns `{ title, lines, row_hl, word_hl, width }` or nil if unavailable.
function M.build(section, hunk_idx)
  local data = diff.word_diff.hunk_rows(section, hunk_idx)
  if not data or #data.rows == 0 then
    return nil
  end
  local glyphs = config.glyphs
  local lines = {}
  local row_hl = {}
  local word_hl = {}
  local width = 0

  lines[1] = data.header
  row_hl[#row_hl + 1] = { row = 0, group = "CanvasDiffHunkHeader" }
  width = math.max(width, vim.fn.strdisplaywidth(lines[1]))

  for _, r in ipairs(data.rows) do
    local prefix = glyphs[r.kind] or " "
    local text = prefix .. (r.content or "")
    local row0 = #lines
    lines[row0 + 1] = text
    width = math.max(width, vim.fn.strdisplaywidth(text))

    if r.kind == "add" then
      row_hl[#row_hl + 1] = { row = row0, group = "CanvasDiffAdd" }
      row_hl[#row_hl + 1] = { row = row0, group = "CanvasDiffPrefixAdd", end_col = #prefix }
      for _, sp in ipairs(r.word_spans or {}) do
        word_hl[#word_hl + 1] = {
          row = row0,
          col_start = #prefix + sp[1],
          col_end = #prefix + sp[2],
          group = "CanvasDiffWordAdd",
        }
      end
    elseif r.kind == "del" then
      row_hl[#row_hl + 1] = { row = row0, group = "CanvasDiffDel" }
      row_hl[#row_hl + 1] = { row = row0, group = "CanvasDiffPrefixDel", end_col = #prefix }
      for _, sp in ipairs(r.word_spans or {}) do
        word_hl[#word_hl + 1] = {
          row = row0,
          col_start = #prefix + sp[1],
          col_end = #prefix + sp[2],
          group = "CanvasDiffWordDel",
        }
      end
    end
  end

  local title = " " .. format.section_path(section) .. " "
  width = math.max(width, vim.fn.strdisplaywidth(title) + 2)
  return {
    title = title,
    lines = lines,
    row_hl = row_hl,
    word_hl = word_hl,
    width = width,
  }
end

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.close()
  if M.is_open() then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win, state.buf = nil, nil
end

local function close_keys(keymaps)
  local out, seen = { "q", "<Esc>" }, { q = true, ["<Esc>"] = true }
  for _, m in ipairs(keys.resolved("canvas", keymaps)) do
    if m.action == "peek_hunk" and not seen[m.lhs] then
      seen[m.lhs] = true
      out[#out + 1] = m.lhs
    end
  end
  return out
end

--- Open (or replace) the floating hunk peek for `(section, hunk_idx)`.
--- Returns `true` when opened, `false` when the hunk has no rows to inspect.
function M.open(section, hunk_idx)
  M.close()
  local built = M.build(section, hunk_idx)
  if not built then
    return false
  end
  appearance.ensure()

  local max_width = math.max(24, vim.o.columns - 8)
  local max_height = math.max(4, vim.o.lines - 6)
  local width = math.min(math.max(built.width, 24), max_width)
  local height = math.min(math.max(#built.lines, 1), max_height)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, built.lines)

  for _, m in ipairs(built.row_hl) do
    if m.end_col then
      vim.api.nvim_buf_set_extmark(buf, NS, m.row, 0, {
        end_row = m.row,
        end_col = m.end_col,
        hl_group = m.group,
        priority = 110,
      })
    else
      vim.api.nvim_buf_set_extmark(buf, NS, m.row, 0, {
        end_row = m.row + 1,
        end_col = 0,
        hl_group = m.group,
        priority = 100,
      })
    end
  end
  for _, s in ipairs(built.word_hl) do
    vim.api.nvim_buf_set_extmark(buf, NS, s.row, s.col_start, {
      end_row = s.row,
      end_col = s.col_end,
      hl_group = s.group,
      priority = 120,
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
    title = built.title,
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("wrap", false, { win = win, scope = "local" })
  vim.api.nvim_set_option_value("cursorline", true, { win = win, scope = "local" })

  for _, lhs in ipairs(close_keys(config.options.keymaps)) do
    vim.keymap.set("n", lhs, M.close,
      { buf = buf, silent = true, noremap = true, desc = "Close hunk word-diff peek" })
  end

  state.win, state.buf = win, buf
  return true
end

function M.toggle(section, hunk_idx)
  if M.is_open() then
    M.close()
    return false
  end
  return M.open(section, hunk_idx)
end

return M
