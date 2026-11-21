local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local diff = require("canvasdiff.diff")
local fold = diff.fold
local lens = diff.lens
local source = require("canvasdiff.source")

local T = {}

local function write_file(root, rel, content)
  local abs = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(vim.fs.dirname(abs), "p")
  local f = assert(io.open(abs, "wb"))
  f:write(content)
  f:close()
end

local function in_review(root, setup, fn)
  local old_cwd = vim.fn.getcwd()
  local real_notify = vim.notify
  local notes = {}
  vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.setup(vim.tbl_deep_extend("force", {
    watch = { enabled = false }, sidebar = { enabled = false },
    scrollbar = { enabled = false }, statuscolumn = { enabled = false },
    highlight = { enabled = false }, virt = { enabled = false },
    session = { enabled = false },
  }, setup or {}))
  local ok, err = xpcall(function() fn(fm, notes) end, debug.traceback)
  pcall(fm.close)
  vim.notify = real_notify
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  require("canvasdiff.config").setup({})
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["review_loop R marks file reviewed, updates winbar, and jumps to next unreviewed file"] = function()
  local root = H.git_fixture({
    committed = {
      ["a.lua"] = "local a = 1\n",
      ["b.lua"] = "local b = 1\n",
      ["c.lua"] = "local c = 1\n",
    },
    worktree = {
      ["a.lua"] = "local a = 2\n",
      ["b.lua"] = "local b = 2\n",
      ["c.lua"] = "local c = 2\n",
    },
  })

  in_review(root, nil, function(fm, notes)
    local st = assert(fm.open())
    local win = st.win
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    H.eq(vim.api.nvim_get_option_value("winbar", { win = win }),
      "%#CanvasDiffWinbar#HEAD → WORKTREE")

    -- First R: marks a.lua reviewed and jumps to b.lua.
    vim.cmd("normal R")
    H.eq(fold.user_folded(st, "a.lua"), true)
    local cur_i = canvas.locate(st, vim.api.nvim_win_get_cursor(win)[1] - 1)
    H.eq(st.sections[cur_i].path, "b.lua")
    H.eq(vim.api.nvim_get_option_value("winbar", { win = win }),
      "%#CanvasDiffWinbar#HEAD → WORKTREE  ·  1/3 reviewed")

    -- Second R: marks b.lua reviewed and jumps to c.lua.
    vim.cmd("normal R")
    H.eq(fold.user_folded(st, "b.lua"), true)
    cur_i = canvas.locate(st, vim.api.nvim_win_get_cursor(win)[1] - 1)
    H.eq(st.sections[cur_i].path, "c.lua")
    H.eq(vim.api.nvim_get_option_value("winbar", { win = win }),
      "%#CanvasDiffWinbar#HEAD → WORKTREE  ·  2/3 reviewed")

    -- Third R: marks c.lua reviewed and notifies all 3 reviewed.
    vim.cmd("normal R")
    H.eq(fold.user_folded(st, "c.lua"), true)
    H.eq(vim.api.nvim_get_option_value("winbar", { win = win }),
      "%#CanvasDiffWinbar#HEAD → WORKTREE  ·  3/3 reviewed")
    assert(vim.iter(notes):any(function(n) return n:find("all 3 files reviewed", 1, true) ~= nil end),
      vim.inspect(notes))
  end)
end

T["review_loop zf filters to unreviewed files and resurfaces stale files when edited"] = function()
  local root = H.git_fixture({
    committed = {
      ["a.lua"] = "local a = 1\n",
      ["b.lua"] = "local b = 1\n",
      ["c.lua"] = "local c = 1\n",
    },
    worktree = {
      ["a.lua"] = "local a = 2\n",
      ["b.lua"] = "local b = 2\n",
      ["c.lua"] = "local c = 2\n",
    },
  })

  in_review(root, nil, function(fm)
    local st = assert(fm.open())
    local win = st.win
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    -- Mark a.lua reviewed.
    vim.cmd("normal R")
    H.eq(fold.user_folded(st, "a.lua"), true)

    -- Toggle unreviewed filter on (`zf`): a.lua disappears, b.lua & c.lua stay.
    vim.cmd("normal zf")
    H.eq(st.filter_unreviewed, true)
    H.eq(#st.sections, 2)
    H.eq(st.sections[1].path, "b.lua")
    H.eq(st.sections[2].path, "c.lua")
    H.eq(vim.api.nvim_get_option_value("winbar", { win = win }),
      "%#CanvasDiffWinbar#HEAD → WORKTREE  ·  1/3 reviewed  ·  [unreviewed]")

    -- External edit to already-reviewed a.lua -> refresh makes it stale and
    -- resurfaces it in the unreviewed queue!
    write_file(root, "a.lua", "local a = 99\n")
    assert(fm.refresh())
    H.eq(#st.sections, 3, "stale reviewed file resurfaces in unreviewed view")
    H.eq(st.sections[1].path, "a.lua")
    H.eq(fold.stale(st, "a.lua", diff.fingerprint(st.sections[1]), "all"), true)
    H.eq(vim.api.nvim_get_option_value("winbar", { win = win }),
      "%#CanvasDiffWinbar#HEAD → WORKTREE  ·  0/3 reviewed  ·  1 stale  ·  [unreviewed]")

    -- Re-reviewing stale a.lua with R clears staleness and hides it again.
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd("normal R")
    H.eq(#st.sections, 2)
    H.eq(st.sections[1].path, "b.lua")

    -- Toggle filter off (`zf`): all 3 files return, with a.lua still folded.
    vim.cmd("normal zf")
    H.eq(st.filter_unreviewed, false)
    H.eq(#st.sections, 3)
    H.eq(fold.user_folded(st, "a.lua"), true)
  end)
end

T["review_loop visual mode s stages, u unstages, and x undoably discards only selected lines"] = function()
  local root = H.git_fixture({
    committed = {
      ["demo.lua"] = "local top = 0\nlocal bottom = 0\n",
    },
    worktree = {
      ["demo.lua"] = "local top = 0\nlocal a = 1\nlocal b = 2\nlocal c = 3\nlocal bottom = 0\n",
    },
  })

  in_review(root, nil, function(fm)
    local st = assert(fm.open())
    local win = st.win
    local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
    local row_b, row_c
    for idx, line in ipairs(lines) do
      if line:find("local b = 2", 1, true) then row_b = idx end
      if line:find("local c = 3", 1, true) then row_c = idx end
    end
    assert(row_b and row_c, "sanity: added lines exist on canvas")

    -- Visual-select ONLY `local b = 2` and press `s` to stage just that line!
    vim.api.nvim_win_set_cursor(win, { row_b, 0 })
    vim.api.nvim_feedkeys("Vs", "x", false)
    local staged_text = assert(source.show(root, ":0", "demo.lua"))
    H.eq(staged_text, "local top = 0\nlocal b = 2\nlocal bottom = 0\n",
      "only the visually selected line was staged")

    -- Switch to staged lens and visual-select `local b = 2` + `u` to unstage it!
    assert(fm.set_lens(lens.get("staged")))
    lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
    local staged_row_b
    for idx, line in ipairs(lines) do
      if line:find("local b = 2", 1, true) then staged_row_b = idx end
    end
    assert(staged_row_b, "b appears in staged lens")
    vim.api.nvim_win_set_cursor(win, { staged_row_b, 0 })
    vim.api.nvim_feedkeys("Vu", "x", false)
    H.eq(source.show(root, ":0", "demo.lua"), "local top = 0\nlocal bottom = 0\n",
      "only the visually selected line was unstaged")

    -- Switch to unstaged lens, load demo.lua in a hidden buffer so discard is
    -- undoable, then visual-select ONLY `local c = 3` and press `x`!
    assert(fm.set_lens(lens.get("unstaged")))
    local file_buf = vim.fn.bufadd(vim.fs.joinpath(root, "demo.lua"))
    vim.fn.bufload(file_buf)
    lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
    local unstaged_row_c
    for idx, line in ipairs(lines) do
      if line:find("local c = 3", 1, true) then unstaged_row_c = idx end
    end
    assert(unstaged_row_c, "c appears in unstaged lens")
    vim.api.nvim_win_set_cursor(win, { unstaged_row_c, 0 })
    vim.api.nvim_feedkeys("Vx", "x", false)

    H.eq(source.worktree_text(root, "demo.lua"),
      "local top = 0\nlocal a = 1\nlocal b = 2\nlocal bottom = 0\n",
      "visual x discarded ONLY the selected line")
    H.eq(vim.fn.getreg('"'), "local c = 3\n",
      "removed line landed in the unnamed register")

    -- Undo in the loaded file buffer restores the discarded line!
    vim.api.nvim_buf_call(file_buf, function() vim.cmd("silent undo") end)
    H.eq(source.worktree_text(root, "demo.lua"),
      "local top = 0\nlocal a = 1\nlocal b = 2\nlocal c = 3\nlocal bottom = 0\n",
      "undo in the real file buffer restores visually discarded lines")
    vim.api.nvim_buf_delete(file_buf, { force = true })
  end)
end

T["review_loop external disk edits show immediately even when an unmodified buffer stays loaded"] = function()
  local root = H.git_fixture({
    committed = { ["agent.lua"] = "local v = 1\n" },
    worktree = { ["agent.lua"] = "local v = 2\n" },
  })

  in_review(root, nil, function(fm)
    local st = assert(fm.open())
    -- Load agent.lua cleanly (unmodified) as happens after a <CR>/<C-Space> peek.
    local buf = vim.fn.bufadd(vim.fs.joinpath(root, "agent.lua"))
    vim.fn.bufload(buf)
    H.eq(vim.api.nvim_get_option_value("modified", { buf = buf }), false)

    -- External agent rewrites agent.lua on disk without Neovim running :checktime.
    write_file(root, "agent.lua", "local v = 3 -- external agent\n")
    assert(fm.refresh())
    local lines = table.concat(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), "\n")
    assert(lines:find("external agent", 1, true),
      "canvas must reflect external disk writes over stale unmodified buffers")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

return T
