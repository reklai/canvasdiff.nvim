local H = require("helpers")
local canvas = require("canvasdiff.canvas")

-- The reverse jump at the level a user meets it: `here` from a real file, and
-- the verbs that bring the canvas to the window you are in while an excursion
-- is out. The row arithmetic itself is test_jump's and test_viewport's.
local T = {}

local function lines(prefix, n, changed)
  local out = {}
  for i = 1, n do
    out[i] = (changed and changed[i]) or (prefix .. i)
  end
  return table.concat(out, "\n") .. "\n"
end

local function fixture()
  return H.git_fixture({
    committed = {
      ["a.txt"] = lines("a", 80),
      ["b.txt"] = "b1\nb2\n",
      ["same.txt"] = "s1\ns2\ns3\n",
    },
    worktree = {
      ["a.txt"] = lines("a", 80, { [10] = "A10", [60] = "A60 changed" }),
      ["b.txt"] = "b1\nB2\n",
      ["same.txt"] = "s1\ns2\ns3\n",
    },
  })
end

--- Run `fn` in a throwaway tab rooted at a fresh fixture repo.
local function in_repo(fn)
  local old_cwd = vim.fn.getcwd()
  local root = fixture()
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  local real_notify = vim.notify
  local messages = {}
  vim.notify = function(message) messages[#messages + 1] = message end
  local ok, err = pcall(fn, fm, root, messages)
  vim.notify = real_notify
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  assert(ok, err)
end

local function on_canvas()
  return canvas.is_canvas_buf(vim.api.nvim_get_current_buf())
end

local function cursor_row_text()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
end

local function cursor_to(text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l == text then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return i
    end
  end
  error("canvas has no row " .. text)
end

local function said(messages, fragment)
  for _, message in ipairs(messages) do
    if tostring(message):find(fragment, 1, true) then
      return true
    end
  end
  return false
end

T["here_ opens the review on the file line under the cursor"] = function()
  in_repo(function(fm, root)
    vim.cmd.edit(root .. "/a.txt")
    vim.api.nvim_win_set_cursor(0, { 60, 4 })
    assert(fm.here(), "here opens a review when none is live")
    assert(on_canvas(), "and shows it in this window")
    H.eq(cursor_row_text(), "+A60 changed")
    H.eq(vim.api.nvim_win_get_cursor(0)[2], 5, "column carried past the row prefix")
  end)
end

-- Enter and here are inverses: a line outside every hunk has no row, so the
-- nearest shown line of the same file stands in.
T["here_ lands on the nearest shown line for one outside every hunk"] = function()
  in_repo(function(fm, root)
    vim.cmd.edit(root .. "/a.txt")
    vim.api.nvim_win_set_cursor(0, { 30, 0 })
    assert(fm.here())
    H.eq(cursor_row_text(), " a13", "the bottom edge of the hunk above")
  end)
end

T["here_ shows a live review that is off screen, at the line"] = function()
  in_repo(function(fm, root)
    fm.open()
    local win = vim.api.nvim_get_current_win()
    cursor_to("+B2")
    -- Off screen without an excursion: the window simply went elsewhere.
    vim.cmd.edit(root .. "/a.txt")
    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    assert(fm.here())
    H.eq(vim.api.nvim_get_current_win(), win)
    assert(on_canvas())
    H.eq(cursor_row_text(), "+A10")
  end)
end

T["here_ focuses a review already on screen instead of showing a second view"] = function()
  in_repo(function(fm, root)
    fm.open()
    local host = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    vim.cmd.edit(root .. "/a.txt")
    vim.api.nvim_win_set_cursor(0, { 60, 0 })
    assert(fm.here())
    H.eq(vim.api.nvim_get_current_win(), host, "focus moves to the canvas")
    H.eq(cursor_row_text(), "+A60 changed")
    local views = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if canvas.is_canvas_buf(vim.api.nvim_win_get_buf(win)) then
        views = views + 1
      end
    end
    H.eq(views, 1)
  end)
end

-- A file with no changes has no row. The review still appears -- the verb is
-- "show me the review" before it is "at this line" -- and says why it did
-- not move.
T["here_ in an unchanged file shows the review unmoved and says so"] = function()
  in_repo(function(fm, root, messages)
    fm.open()
    local parked = cursor_to("+B2")
    vim.cmd.edit(root .. "/same.txt")
    assert(fm.here())
    assert(on_canvas())
    H.eq(vim.api.nvim_win_get_cursor(0)[1], parked)
    assert(said(messages, "same.txt has no changes in this review"),
      vim.inspect(messages))
  end)
end

T["here_ never changes a fold: a folded file answers with its placeholder"] = function()
  in_repo(function(fm, root)
    fm.open()
    cursor_to("+A10")
    vim.api.nvim_feedkeys("c", "x", false)
    local placeholder = vim.api.nvim_win_get_cursor(0)[1]
    cursor_to("+B2")
    vim.cmd.edit(root .. "/a.txt")
    vim.api.nvim_win_set_cursor(0, { 60, 0 })
    assert(fm.here())
    H.eq(vim.api.nvim_win_get_cursor(0)[1], placeholder)
    assert(cursor_row_text():find("a.txt", 1, true), cursor_row_text())
  end)
end

-- An excursion out of the review: here IS the return. It used to be possible
-- to put the canvas back on screen with its section stale against unsaved
-- edits and the return key still live on the file.
T["here_ during an excursion returns with the edits and lands on the line"] = function()
  in_repo(function(fm)
    fm.open()
    cursor_to("+A10")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    local file = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(file, 39, 40, false, { "fixed forty" })
    vim.api.nvim_win_set_cursor(0, { 40, 0 })
    assert(fm.here())
    assert(on_canvas())
    H.eq(cursor_row_text(), "+fixed forty")
    H.eq(vim.api.nvim_buf_call(file, function()
      return vim.fn.maparg("<C-Space>", "n", false, true).buffer
    end), nil, "the excursion was consumed, not left out")
  end)
end

T["here_ toggle from an excursion is the same return"] = function()
  in_repo(function(fm)
    fm.open()
    cursor_to("+A10")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    local file = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(file, 69, 70, false, { "fixed seventy" })
    vim.api.nvim_win_set_cursor(0, { 70, 0 })
    fm.toggle()
    assert(on_canvas(), "toggle brought the canvas back")
    H.eq(cursor_row_text(), "+fixed seventy")
    H.eq(vim.api.nvim_buf_call(file, function()
      return vim.fn.maparg("<C-Space>", "n", false, true).buffer
    end), nil)
    fm.toggle()
    assert(not on_canvas(), "and the next toggle closes, as it always did")
  end)
end

-- The key follows the user out of the jumped-to file; closing the review
-- must take it back off every buffer it reached, not only the first.
T["here_ closing a review takes its return key off every followed buffer"] = function()
  in_repo(function(fm, root)
    fm.open()
    cursor_to("+A10")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    local first = vim.api.nvim_get_current_buf()
    vim.cmd.edit(root .. "/same.txt")
    local second = vim.api.nvim_get_current_buf()
    H.eq(vim.fn.maparg("<C-Space>", "n", false, true).buffer, 1)
    fm.close()
    for _, buf in ipairs({ first, second }) do
      H.eq(vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg("<C-Space>", "n", false, true).buffer
      end), nil)
    end
  end)
end

T["here_ the command word runs the same verb"] = function()
  in_repo(function(fm, root)
    vim.cmd.edit(root .. "/a.txt")
    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    fm.command({ "here" })
    assert(on_canvas())
    H.eq(cursor_row_text(), "+A10")
  end)
end

return T
