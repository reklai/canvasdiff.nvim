local H = require("helpers")
local diff = require("canvasdiff.diff")
local lens = diff.lens

-- The review's hunks as a quickfix list: `:cnext` walks them across files
-- without a trip back to the canvas between each.
local T = {}

local TWELVE = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\n"

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
  vim.fn.setqflist({}, "f")
  assert(ok, err)
end

local function fixture()
  local root = H.git_fixture({
    committed = { ["a.txt"] = TWELVE, ["b.txt"] = "b1\nb2\nb3\n", ["gone.txt"] = "g\n" },
    worktree = {
      ["a.txt"] = (TWELVE:gsub("two", "TWO"):gsub("ten\n", "")),
      ["b.txt"] = "b1\nb2\nB3\n",
    },
  })
  vim.fn.delete(vim.fs.joinpath(root, "gone.txt"))
  return root
end

T["quickfix_ lists one entry per hunk at its line in the real file"] = function()
  local root = fixture()
  in_repo(root, function(fm, _, messages)
    assert(fm.open())
    H.eq(fm.quickfix(), 3)
    local list = vim.fn.getqflist({ items = 0, title = 0 })
    H.eq(list.title, "CanvasDiff HEAD → WORKTREE")
    local got = {}
    for _, item in ipairs(list.items) do
      got[#got + 1] = {
        vim.fs.basename(vim.api.nvim_buf_get_name(item.bufnr)), item.lnum, item.text,
      }
    end
    H.eq(got, {
      { "a.txt", 2, "(+1 -1) TWO" },
      -- A hunk that only deleted: the surviving line its ghost hangs on.
      { "a.txt", 10, "(+0 -1) ten" },
      { "b.txt", 3, "(+1 -1) B3" },
    })
    assert(messages[#messages]:find("3 hunks in the quickfix list", 1, true),
      vim.inspect(messages))
    H.eq(vim.fn.getqflist({ winid = 0 }).winid, 0, "the window is the user's to open")
  end)
end

T["quickfix_ cnext walks hunks across files without the canvas"] = function()
  local root = fixture()
  in_repo(root, function(fm)
    assert(fm.open())
    assert(fm.quickfix())
    vim.cmd("silent cfirst")
    H.eq({ vim.fn.expand("%:t"), vim.fn.line(".") }, { "a.txt", 2 })
    vim.cmd("silent cnext")
    vim.cmd("silent cnext")
    H.eq({ vim.fn.expand("%:t"), vim.fn.line(".") }, { "b.txt", 3 })
  end)
end

-- A fold sets a file aside on the canvas; it does not say its hunks are done.
T["quickfix_ includes folded files"] = function()
  local root = fixture()
  in_repo(root, function(fm)
    assert(fm.open())
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys("c", "x", false)
    H.eq(fm.quickfix(), 3)
  end)
end

T["quickfix_ declines a lens whose lines are not the worktree's"] = function()
  local root = fixture()
  in_repo(root, function(fm, _, messages)
    vim.fn.setqflist({ { text = "mine" } }, " ")
    H.eq(fm.quickfix(), nil)
    assert(messages[#messages]:find("no live diff canvas", 1, true))

    assert(fm.open({ lens = lens.get("staged") }))
    H.eq(fm.quickfix(), nil)
    assert(messages[#messages]:find("staged view numbers lines in the index", 1, true),
      vim.inspect(messages))
    H.eq(vim.fn.getqflist()[1].text, "mine", "a refusal leaves the user's list alone")
  end)
end

T["quickfix_ hunk_targets names a line that exists for every shape of hunk"] = function()
  local function targets(old, new, context)
    local section = diff.build_section("f.txt", old, new, "M", context or 3, {})
    local out = {}
    for _, t in ipairs(diff.hunk_targets(section)) do
      out[#out + 1] = { t.lnum, t.adds, t.dels }
    end
    return out
  end
  H.eq(targets("a\nb\nc\n", "a\nB\nc\n"), { { 2, 1, 1 } })
  H.eq(targets("a\nb\nc\n", "b\nc\n"), { { 1, 0, 1 } }, "a cut at the top names line 1")
  H.eq(targets("a\nb\nc\n", "a\nb\n"), { { 2, 0, 1 } }, "a cut at the end hangs on the last line")
  H.eq(targets("a\nb\nc\n", "b\nc\n", 0), { { 1, 0, 1 } }, "with no context the seam, never 0")
  H.eq(targets("a\n", "a\n"), {})
  H.eq(diff.hunk_targets({ binary = true, hunks = { {} } }), {})
  H.eq(diff.hunk_targets(nil), {})
end

return T
