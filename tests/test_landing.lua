local H = require("helpers")
local canvas = require("galley.canvas")

local T = {}

local function fixture()
  return H.git_fixture({
    committed = { ["a.txt"] = "a1\n", ["b.txt"] = "b1\n", ["origin.txt"] = "o\n" },
    worktree = { ["a.txt"] = "A1\n", ["b.txt"] = "B1\n", ["origin.txt"] = "o\n" },
  })
end

--- Run `fn` in a throwaway tab rooted at a fresh fixture repo.
local function in_repo(fn)
  local old_cwd = vim.fn.getcwd()
  local root = fixture()
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["galley"] = nil
  local fm = require("galley")
  local ok, err = pcall(fn, fm, root)
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  assert(ok, err)
end

local function tail(win)
  local n = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  return n == "" and "[No Name]" or vim.fn.fnamemodify(n, ":t")
end

local function n_canvas_wins()
  local c = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if canvas.is_canvas_buf(vim.api.nvim_win_get_buf(w)) then c = c + 1 end
  end
  return c
end

local function jump_round_trip()
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l == "+A1" then vim.api.nvim_win_set_cursor(0, { i, 0 }) end
  end
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  vim.api.nvim_feedkeys(vim.keycode("<M-CR>"), "x", false)
end

-- The contract: closing is non-destructive. Reviewing interrupts whatever you
-- were doing, so the exit has to undo itself.
T["landing_ close returns to the buffer it opened over"] = function()
  in_repo(function(fm, root)
    vim.cmd.edit(root .. "/origin.txt")
    fm.open()
    fm.close()
    H.eq(tail(vim.api.nvim_get_current_win()), "origin.txt")
  end)
end

T["landing_ close restores the cursor, not just the buffer"] = function()
  in_repo(function(fm, root)
    local abs = root .. "/big.txt"
    local lines = {}
    for i = 1, 200 do lines[i] = "line " .. i end
    local f = assert(io.open(abs, "w")); f:write(table.concat(lines, "\n") .. "\n"); f:close()
    vim.cmd.edit(abs)
    vim.api.nvim_win_set_cursor(0, { 150, 3 })
    fm.open()
    fm.close()
    H.eq(vim.api.nvim_win_get_cursor(0), { 150, 3 }, "column included")
  end)
end

-- A jump is the OTHER exit ("I want to work on this"); it must not hijack the
-- meaning of close ("I'm done reading").
T["landing_ a jump round-trip does not change where close lands"] = function()
  in_repo(function(fm, root)
    vim.cmd.edit(root .. "/origin.txt")
    fm.open()
    jump_round_trip()
    fm.close()
    H.eq(tail(vim.api.nvim_get_current_win()), "origin.txt",
      "the origin, not the file the jump visited")
  end)
end

-- Regression: landing on [No Name] read as something having broken, when all
-- that happened was the buffer we came from got deleted meanwhile.
T["landing_ falls back to the last jumped file when the origin is gone"] = function()
  in_repo(function(fm, root)
    vim.cmd.edit(root .. "/origin.txt")
    local victim = vim.api.nvim_get_current_buf()
    fm.open()
    jump_round_trip()
    vim.api.nvim_buf_delete(victim, { force = true })
    fm.close()
    local landed = tail(vim.api.nvim_get_current_win())
    assert(landed ~= "[No Name]", "must not dump the user on a blank buffer")
    H.eq(landed, "a.txt", "the file the review last touched")
  end)
end

-- Regression: close() only acted on the CURRENT window, so `:Galley close`
-- from a neighbouring split was a silent no-op that read as the plugin being
-- broken.
T["landing_ close works from a neighbouring split"] = function()
  in_repo(function(fm, root)
    vim.cmd.edit(root .. "/origin.txt")
    fm.open()
    vim.cmd("vsplit")
    vim.cmd.edit(root .. "/b.txt")
    local other = vim.api.nvim_get_current_win()
    H.eq(n_canvas_wins(), 1, "sanity: one canvas on screen")

    fm.close()

    H.eq(n_canvas_wins(), 0, "closing from elsewhere must still close it")
    H.eq(tail(other), "b.txt", "and must not disturb the window we were in")
  end)
end

-- Regression: toggle keyed on "showing in THIS window", so from a split it
-- fell through to open() and put a SECOND view of the same canvas on screen --
-- the dismiss key adding another one.
T["landing_ toggle from a split closes instead of opening a second canvas"] = function()
  in_repo(function(fm, root)
    vim.cmd.edit(root .. "/origin.txt")
    fm.open()
    vim.cmd("vsplit")
    vim.cmd.edit(root .. "/b.txt")
    H.eq(n_canvas_wins(), 1, "sanity")

    fm.toggle()
    H.eq(n_canvas_wins(), 0, "toggle dismisses it")

    fm.toggle()
    H.eq(n_canvas_wins(), 1, "and brings back exactly one")
  end)
end

T["landing_ close is a silent no-op when nothing is showing"] = function()
  in_repo(function(fm, root)
    vim.cmd.edit(root .. "/origin.txt")
    local before = vim.api.nvim_get_current_buf()
    local real = vim.notify
    local msgs = {}
    vim.notify = function(m) msgs[#msgs + 1] = m end
    local ok = pcall(fm.close)
    vim.notify = real
    assert(ok, "closing what isn't open must not error")
    H.eq(#msgs, 0, "and must not nag: closing nothing is not a failure")
    H.eq(vim.api.nvim_get_current_buf(), before, "and must not move the user")
  end)
end

return T
