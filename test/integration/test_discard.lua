local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local source = require("canvasdiff.source")
local lens = require("canvasdiff.diff").lens

-- The reject verb: `x` puts the index's lines back into the worktree. Every
-- test here is about one of two things -- that it writes exactly the hunk it
-- was pointed at, and that a destructive key leaves a way back.
local T = {}

local TWELVE = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\n"
local TWELVE_EDITED = TWELVE:gsub("two", "TWO"):gsub("ten", "TEN")

local function sh(root, cmd)
  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  return res.stdout
end

local function read(root, path)
  local f = assert(io.open(vim.fs.joinpath(root, path), "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local function write(root, path, text)
  local f = assert(io.open(vim.fs.joinpath(root, path), "wb"))
  f:write(text)
  f:close()
end

--- Run `fn(fm, root, messages, answers)` in a throwaway tab rooted at `root`.
--- `answers` records each whole-file prompt; set `answers.reply` to choose.
local function in_repo(root, fn)
  local old_cwd = vim.fn.getcwd()
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.setup({
    watch = { enabled = false },
    sidebar = { enabled = false },
    session = { enabled = false },
  })
  local App = require("canvasdiff.App")
  local real_confirm, real_notify = App.confirm_discard, vim.notify
  local messages, answers = {}, { reply = true }
  App.confirm_discard = function(message)
    answers[#answers + 1] = message
    return answers.reply
  end
  vim.notify = function(message) messages[#messages + 1] = tostring(message) end
  local ok, err = pcall(fn, fm, root, messages, answers)
  vim.notify = real_notify
  App.confirm_discard = real_confirm
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:sub(1, #root) == root then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  assert(ok, err)
end

local function rows()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function has_row(text)
  return vim.tbl_contains(rows(), text)
end

local function press(text, key)
  for i, l in ipairs(rows()) do
    if l == text or (text:sub(1, 1) == "~" and l:find(text:sub(2), 1, true)) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
      return
    end
  end
  error("canvas has no row " .. text)
end

local function said(messages, fragment)
  for _, message in ipairs(messages) do
    if message:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

local function two_hunks()
  return H.git_fixture({
    committed = { ["a.txt"] = TWELVE },
    worktree = { ["a.txt"] = TWELVE_EDITED },
  })
end

T["discard_ x puts one hunk's index lines back and leaves the other"] = function()
  local root = two_hunks()
  in_repo(root, function(fm)
    vim.fn.setreg('"', "untouched")
    assert(fm.open())
    press("+TWO", "x")
    H.eq(read(root, "a.txt"), (TWELVE:gsub("ten", "TEN")))
    assert(not has_row("+TWO"), "the discarded hunk is gone from the canvas")
    assert(has_row("+TEN"), "the hunk that was not pointed at is still there")
    H.eq(vim.fn.getreg('"'), "TWO\n", "what x removed is where x leaves things")
    H.eq(vim.fn.getregtype('"'), "V")
    H.eq(sh(root, { "git", "diff", "--cached", "--name-only" }), "",
      "the index is never touched")
  end)
end

-- The way back that makes a destructive key acceptable: through the file's
-- buffer the discard is one change in its undo history.
T["discard_ through a loaded buffer is saved and undoable there"] = function()
  local root = two_hunks()
  in_repo(root, function(fm)
    vim.cmd.edit(root .. "/a.txt")
    local file = vim.api.nvim_get_current_buf()
    assert(fm.open())
    press("+TEN", "x")
    H.eq(vim.api.nvim_buf_get_lines(file, 9, 10, false), { "ten" })
    H.eq(vim.bo[file].modified, false, "an unmodified buffer is written back")
    H.eq(read(root, "a.txt"), (TWELVE:gsub("two", "TWO")))
    vim.api.nvim_buf_call(file, function() vim.cmd("silent undo") end)
    H.eq(vim.api.nvim_buf_get_lines(file, 9, 10, false), { "TEN" },
      "one undo in the file brings the hunk back")
  end)
end

-- Unsaved text is never written behind the user's back, and never replaced
-- from disk: the discard lands in the buffer and the save stays theirs.
T["discard_ into a buffer with unsaved edits stays unsaved"] = function()
  local root = two_hunks()
  in_repo(root, function(fm, _, messages)
    vim.cmd.edit(root .. "/a.txt")
    local file = vim.api.nvim_get_current_buf()
    -- Far enough from line 2 that context cannot merge it into the hunk being
    -- discarded: a displayed hunk is discarded whole, merged neighbours and all.
    vim.api.nvim_buf_set_lines(file, 11, 12, false, { "TWELVE unsaved" })
    assert(fm.open())
    press("+TWO", "x")
    H.eq(vim.api.nvim_buf_get_lines(file, 1, 2, false), { "two" })
    H.eq(vim.api.nvim_buf_get_lines(file, 11, 12, false), { "TWELVE unsaved" },
      "the unsaved edit is still there")
    H.eq(vim.bo[file].modified, true)
    H.eq(read(root, "a.txt"), TWELVE_EDITED, "and nothing reached the disk")
    assert(said(messages, "unsaved buffer"), vim.inspect(messages))
    assert(has_row("+TWELVE unsaved"), "the canvas reads the buffer, as it always does")
  end)
end

T["discard_ a hunk that only deleted lines brings them back"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = TWELVE },
    worktree = { ["a.txt"] = (TWELVE:gsub("five\nsix\n", "")) },
  })
  in_repo(root, function(fm)
    vim.fn.setreg('"', "untouched")
    assert(fm.open())
    press(" four", "x")
    H.eq(read(root, "a.txt"), TWELVE)
    H.eq(vim.fn.getreg('"'), "untouched", "nothing was removed, so nothing is yanked")
    H.eq(#rows(), 1, "the review is empty")
  end)
end

T["discard_ X takes the whole file, and asks first"] = function()
  local root = two_hunks()
  in_repo(root, function(fm, _, _, answers)
    assert(fm.open())
    answers.reply = false
    press("+TEN", "X")
    H.eq(#answers, 1)
    assert(answers[1]:find("2 unstaged hunks in a.txt", 1, true), answers[1])
    H.eq(read(root, "a.txt"), TWELVE_EDITED, "declining the prompt changes nothing")

    answers.reply = true
    press("+TEN", "X")
    H.eq(read(root, "a.txt"), TWELVE)
  end)
end

T["discard_ x on a file header is the whole-file verb"] = function()
  local root = two_hunks()
  in_repo(root, function(fm, _, _, answers)
    assert(fm.open())
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys("x", "x", false)
    H.eq(#answers, 1, "the header names the file, so the file's prompt appears")
    H.eq(read(root, "a.txt"), TWELVE)
  end)
end

-- On a staged-and-modified file the all lens measures hunks against HEAD;
-- putting HEAD's lines back would leave the index holding a change the
-- worktree no longer has. It declines and names the lens whose pair it writes.
T["discard_ a staged and modified file is discarded from the unstaged lens only"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = TWELVE },
    worktree = { ["a.txt"] = (TWELVE:gsub("two", "TWO")) },
  })
  sh(root, { "git", "add", "a.txt" })
  write(root, "a.txt", TWELVE_EDITED)
  in_repo(root, function(fm, _, messages)
    assert(fm.open({ lens = lens.get("all") }))
    press("+TEN", "x")
    H.eq(read(root, "a.txt"), TWELVE_EDITED)
    assert(said(messages, "discard from the unstaged lens"), vim.inspect(messages))

    assert(fm.set_lens(lens.get("unstaged")))
    assert(not has_row("+TWO"), "sanity: the staged hunk is not in this lens")
    press("+TEN", "x")
    H.eq(read(root, "a.txt"), (TWELVE:gsub("two", "TWO")),
      "the worktree goes back to the INDEX, keeping what was staged")
    H.eq(sh(root, { "git", "status", "--porcelain" }), "M  a.txt\n")
  end)
end

T["discard_ declines where there is no worktree change to drop"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = TWELVE, ["gone.txt"] = "g1\ng2\n" },
    worktree = { ["a.txt"] = TWELVE_EDITED, ["new.txt"] = "n1\n" },
  })
  vim.fn.delete(vim.fs.joinpath(root, "gone.txt"))
  in_repo(root, function(fm, _, messages, answers)
    assert(fm.open({ lens = lens.get("all") }))
    press("+n1", "x")
    assert(said(messages, "new.txt is untracked"), vim.inspect(messages))
    H.eq(read(root, "new.txt"), "n1\n")

    press("~gone.txt", "x")
    assert(said(messages, "gone.txt was deleted"), vim.inspect(messages))
    assert(not vim.uv.fs_stat(vim.fs.joinpath(root, "gone.txt")))

    sh(root, { "git", "add", "a.txt" })
    assert(fm.set_lens(lens.get("staged")))
    press("+TWO", "x")
    assert(said(messages, "the staged view shows the index"), vim.inspect(messages))
    H.eq(read(root, "a.txt"), TWELVE_EDITED)
    H.eq(#answers, 0, "no declined press ever reached the prompt")
  end)
end

T["discard_ is refused on a READ-ONLY range and a branch comparison"] = function()
  local root = two_hunks()
  sh(root, { "git", "branch", "base" })
  in_repo(root, function(fm, _, messages)
    assert(fm.set_branch("base"))
    press("+TWO", "x")
    assert(said(messages, "use the all or unstaged lens"), vim.inspect(messages))
    H.eq(read(root, "a.txt"), TWELVE_EDITED)
  end)
end

-- write_worktree is `worktree_text` in reverse, so the bytes it reconstructs
-- have to survive the same two things the read does: 'fileformat' and a
-- missing final newline.
T["discard_ write_worktree keeps a dos buffer's line endings and a missing newline"] = function()
  local root = H.git_fixture({ committed = { ["d.txt"] = "x\n" } })
  write(root, "d.txt", "one\r\ntwo\r\nthree")
  in_repo(root, function()
    vim.cmd.edit(root .. "/d.txt")
    local buf = vim.api.nvim_get_current_buf()
    H.eq(vim.bo[buf].fileformat, "dos")
    -- A save follows the buffer's own 'fixendofline', as any :write does; off,
    -- the missing final newline this function reconstructs is what is written.
    vim.bo[buf].fixendofline = false
    H.eq(source.worktree_text(root, "d.txt"), "one\r\ntwo\r\nthree")
    H.eq(source.write_worktree(root, "d.txt", "one\r\nTWO\r\nthree"), "saved")
    H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "TWO", "three" })
    H.eq(read(root, "d.txt"), "one\r\nTWO\r\nthree")
    H.eq(source.write_worktree(root, "d.txt", "one\r\nTWO\r\nthree\r\n"), "saved")
    H.eq(read(root, "d.txt"), "one\r\nTWO\r\nthree\r\n")
  end)
end

T["discard_ write_worktree refuses a symlink and writes an unloaded file to disk"] = function()
  local root = H.git_fixture({ committed = { ["real.txt"] = "r\n" } })
  assert(vim.uv.fs_symlink("real.txt", vim.fs.joinpath(root, "link.txt")))
  local how, err = source.write_worktree(root, "link.txt", "x\n")
  H.eq(how, nil)
  assert(err:find("symlink", 1, true), err)
  H.eq(read(root, "real.txt"), "r\n")
  H.eq(source.write_worktree(root, "real.txt", "R\n"), "disk")
  H.eq(read(root, "real.txt"), "R\n")
end

return T
