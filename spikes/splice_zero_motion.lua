-- Spike: replacing lines ABOVE the viewport, then correcting topline in the
-- same tick, leaves the visible text and relative cursor position identical.
-- Headless windows work: nvim_open_win + winsaveview are fully functional.
local buf = vim.api.nvim_create_buf(false, true)
local lines = {}
for i = 1, 1000 do lines[i] = "line " .. i end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local win = vim.api.nvim_open_win(buf, true, {
  relative = "editor", row = 0, col = 0, width = 40, height = 20,
})

-- Scroll to middle: topline 500, cursor on 510
vim.api.nvim_win_call(win, function()
  vim.fn.winrestview({ topline = 500, lnum = 510, col = 3 })
end)

local function visible()
  return vim.api.nvim_win_call(win, function()
    local v = vim.fn.winsaveview()
    local top = vim.fn.line("w0")
    return { view = v, first_visible_text = vim.fn.getline(top) }
  end)
end

local before = visible()

-- Splice: replace lines 100..200 (above viewport) with 150 new lines (delta +49)
local newchunk = {}
for i = 1, 150 do newchunk[i] = "NEW " .. i end
local delta = 150 - 101
vim.api.nvim_buf_set_lines(buf, 99, 200, false, newchunk)
vim.api.nvim_win_call(win, function()
  local v = vim.fn.winsaveview()
  v.topline = before.view.topline + delta
  v.lnum = before.view.lnum + delta
  vim.fn.winrestview(v)
end)

local after = visible()
print("before first visible: " .. before.first_visible_text)
print("after  first visible: " .. after.first_visible_text)
print("col before/after: " .. before.view.col .. "/" .. after.view.col)
local ok = before.first_visible_text == after.first_visible_text
  and before.view.col == after.view.col
  and (after.view.topline - before.view.topline) == delta
print(ok and "SPIKE PASS" or "SPIKE FAIL")
os.exit(ok and 0 or 1)
