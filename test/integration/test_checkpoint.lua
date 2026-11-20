local H = require("helpers")
local source = require("canvasdiff.source")
local lens = require("canvasdiff.diff").lens

-- "What changed since I last looked": a checkpoint records the worktree as
-- the review shows it, and the CHECKPOINT → WORKTREE lens shows only what
-- arrived afterwards. Two things are under test -- that the snapshot is exact
-- (untracked files, unsaved buffers), and that taking it writes nothing of
-- the user's.
local T = {}

local function sh(root, cmd)
  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  return res.stdout
end

local function write(root, path, text)
  local f = assert(io.open(vim.fs.joinpath(root, path), "wb"))
  f:write(text)
  f:close()
end

local function fixture()
  return H.git_fixture({
    committed = { ["a.txt"] = "a1\na2\na3\n", ["b.txt"] = "b1\nb2\n" },
    worktree = {
      ["a.txt"] = "a1\nA2\na3\n",
      ["b.txt"] = "b1\nb2\n",
      ["new.txt"] = "n1\n",
    },
  })
end

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
  local real_notify = vim.notify
  local messages = {}
  vim.notify = function(message) messages[#messages + 1] = tostring(message) end
  local ok, err = pcall(fn, fm, root, messages)
  vim.notify = real_notify
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):sub(1, #root) == root then
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

local function said(messages, fragment)
  for _, message in ipairs(messages) do
    if message:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

T["checkpoint_ empties the review and then shows only what arrives after"] = function()
  local root = fixture()
  in_repo(root, function(fm)
    local st = assert(fm.open())
    assert(has_row("+A2") and has_row("+n1"), "sanity: the full review")

    assert(fm.checkpoint())
    H.eq(st.lens.label, "CHECKPOINT → WORKTREE")
    H.eq(rows(), { "-- no changes --" }, "everything on screen was marked seen")

    -- Something else rewrites the worktree: one tracked file, one untracked.
    write(root, "b.txt", "b1\nB2 later\n")
    write(root, "new.txt", "n1\nn2 later\n")
    fm.refresh()
    assert(has_row("+B2 later"), vim.inspect(rows()))
    assert(has_row("+n2 later"), "an untracked file is in the checkpoint too")
    assert(not has_row("+A2"), "what was already seen stays out")
    assert(not has_row("+n1"), "including the untracked file's earlier text")

    -- Moving the checkpoint forward empties it again.
    assert(fm.checkpoint())
    H.eq(rows(), { "-- no changes --" })
  end)
end

T["checkpoint_ writes nothing of the user's: index, worktree and branches stay put"] = function()
  local root = fixture()
  sh(root, { "git", "add", "a.txt" })
  local function facts()
    return {
      status = sh(root, { "git", "status", "--porcelain=v2", "--untracked-files=all" }),
      staged = sh(root, { "git", "diff", "--cached" }),
      branches = sh(root, { "git", "for-each-ref", "refs/heads", "refs/tags", "refs/stash" }),
      head = sh(root, { "git", "rev-parse", "HEAD" }),
    }
  end
  local before = facts()
  in_repo(root, function(fm)
    local commit = assert(fm.checkpoint())
    H.eq(facts(), before)
    H.eq(sh(root, { "git", "rev-parse", lens.CHECKPOINT_REF }), commit .. "\n")
    H.eq(sh(root, { "git", "show", commit .. ":new.txt" }), "n1\n",
      "the snapshot holds the untracked file")
    H.eq(sh(root, { "git", "show", commit .. ":a.txt" }), "a1\nA2\na3\n")
    H.eq(sh(root, { "git", "rev-parse", commit .. "^" }), before.head,
      "and hangs off HEAD")
  end)
end

-- A review reads unsaved buffers. A checkpoint taken from disk alone would
-- report text the user was looking at when they took it as changed since.
T["checkpoint_ records unsaved buffer text, as the review shows it"] = function()
  local root = fixture()
  in_repo(root, function(fm)
    vim.cmd.edit(root .. "/a.txt")
    local file = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(file, 2, 3, false, { "A3 unsaved" })
    -- And a file git calls clean, changed only in its buffer.
    vim.cmd.edit(root .. "/b.txt")
    local clean = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(clean, 1, 2, false, { "B2 unsaved" })
    assert(fm.open())
    assert(has_row("+A3 unsaved"), "sanity: the review shows the unsaved line")

    local commit = assert(fm.checkpoint())
    H.eq(rows(), { "-- no changes --" })
    H.eq(sh(root, { "git", "show", commit .. ":a.txt" }), "a1\nA2\nA3 unsaved\n")
    H.eq(sh(root, { "git", "show", commit .. ":b.txt" }), "b1\nB2 unsaved\n")
    H.eq(sh(root, { "git", "show", "HEAD:b.txt" }), "b1\nb2\n")
    H.eq(vim.bo[file].modified, true, "the buffer is still the user's to save")
    H.eq(table.concat(vim.fn.readfile(root .. "/a.txt"), "\n"), "a1\nA2\na3",
      "and the disk file was not written")
  end)
end

T["checkpoint_ since shows the lens without moving the checkpoint"] = function()
  local root = fixture()
  in_repo(root, function(fm, _, messages)
    local st = assert(fm.open())
    H.eq(fm.since(), nil)
    assert(said(messages, "no checkpoint yet"), vim.inspect(messages))
    H.eq(st.lens.id, "all", "a refused since leaves the lens alone")

    local commit = assert(fm.checkpoint())
    write(root, "b.txt", "b1\nB2 later\n")
    assert(fm.set_lens(lens.get("all")))
    assert(has_row("+A2"))

    assert(fm.since())
    H.eq(st.lens.label, "CHECKPOINT → WORKTREE")
    assert(has_row("+B2 later") and not has_row("+A2"), vim.inspect(rows()))
    H.eq(source.resolve_commit(root, lens.CHECKPOINT_REF), commit)
  end)
end

T["checkpoint_ the key takes one, and the lens cycle leads back out"] = function()
  local root = fixture()
  in_repo(root, function(fm)
    local st = assert(fm.open())
    vim.api.nvim_feedkeys("C", "x", false)
    H.eq(st.lens.label, "CHECKPOINT → WORKTREE")
    vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
    H.eq(st.lens.id, "all")
    assert(has_row("+A2"))
  end)
end

T["checkpoint_ opens the review when none is showing, and the words run the verbs"] = function()
  local root = fixture()
  in_repo(root, function(fm)
    fm.command({ "checkpoint" })
    H.eq(rows(), { "-- no changes --" })
    write(root, "a.txt", "a1\nA2\nA3 later\n")
    fm.command({ "close" })
    fm.command({ "since" })
    assert(has_row("+A3 later"), vim.inspect(rows()))
  end)
end

-- The lens is an ordinary worktree-vs-ref lens: the jump loop works in it.
T["checkpoint_ the lens is editable"] = function()
  local root = fixture()
  in_repo(root, function(fm)
    assert(fm.open())
    assert(fm.checkpoint())
    write(root, "b.txt", "b1\nB2 later\n")
    fm.refresh()
    for i, l in ipairs(rows()) do
      if l == "+B2 later" then vim.api.nvim_win_set_cursor(0, { i, 0 }) end
    end
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    H.eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), "b.txt")
    H.eq(vim.api.nvim_win_get_cursor(0)[1], 2)
  end)
end

T["checkpoint_ lens identity is a branch lens with its own label"] = function()
  local l = lens.checkpoint()
  assert(lens.valid(l) and lens.is_branch(l) and lens.is_checkpoint(l))
  assert(lens.editable(l))
  H.eq(l.old, "refs/worktree/canvasdiff/checkpoint")
  H.eq(l.label, "CHECKPOINT → WORKTREE")
  assert(not lens.is_checkpoint(lens.branch("main")))
  H.eq(lens.step(l, 1).id, "all", "the cycle exits it at all")
end

T["checkpoint_ snapshot refuses a name that is not a full ref and moves nothing"] = function()
  local root = fixture()
  local commit, err = source.checkpoint(root, "main")
  H.eq(commit, nil)
  assert(err:find("full ref", 1, true), err)
  H.eq(sh(root, { "git", "for-each-ref" }):find("canvasdiff", 1, true), nil)
end

return T
