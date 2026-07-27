local H = require("helpers")
local sidebar = require("canvasdiff.ui").sidebar

-- E2E cases deliberately change cwd and open real files from throwaway repos.
-- Restore a path that outlives every fixture before removing one: deleting the
-- process cwd makes later vim.fs calls order-dependent.
local PROJECT_ROOT = H.project_root

local cleanup_buf

local function sidebar_view(st, tab)
  local lease = assert(st.surface.controllers.sidebar, "Surface owns a sidebar lease")
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab or 0)) do
    if sidebar.is_sidebar_win(lease, win) then
      return win, lease
    end
  end
end

--- Is any group with this prefix armed? Every group a review installs is
--- per-Surface, so a fixed name would mean a second review's teardown deleting
--- the first review's event sources.
local function group_alive(prefix)
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    local group = autocmd.group_name
    if group and (group == prefix or group:sub(1, #prefix + 1) == prefix .. ".") then
      return true
    end
  end
  return false
end

local function wipe_buffer(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end

  -- Deleting the buffer currently displayed in a window makes Neovim choose a
  -- replacement. Move it to a known scratch buffer first, so a stale hidden
  -- file from another fixture can never be selected and checked on disk.
  local scratch
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      if not (cleanup_buf and vim.api.nvim_buf_is_valid(cleanup_buf)) then
        cleanup_buf = vim.api.nvim_create_buf(false, true)
      end
      scratch = cleanup_buf
      vim.api.nvim_win_set_buf(win, scratch)
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  H.eq(vim.api.nvim_buf_is_valid(buf), false, "fixture file buffer was wiped")
end

local function remove_fixture(root)
  H.eq(group_alive("canvasdiff.watch"), false,
    "the canvas watch is stopped before its fixture is removed")
  vim.api.nvim_set_current_dir(PROJECT_ROOT)
  H.eq(vim.fn.delete(root, "rf"), 0, "fixture directory was removed")
  H.eq(vim.uv.fs_stat(root), nil, "fixture directory no longer exists")
end

return {
  ["e2e: open renders alphabetical, jump+edit+back round-trip"] = function()
    local root = H.git_fixture({
      committed = { ["src/z.lua"] = "return 1\n", ["src/a.lua"] = "return 2\n", ["top.txt"] = "t\n" },
      worktree = {
        ["src/z.lua"] = "return 10\n",
        ["src/a.lua"] = "return 20\n",
        ["top.txt"] = "T\n",
        ["new.txt"] = "brand new\n",
      },
    })
    vim.api.nvim_set_current_dir(root)
    local fm = require("canvasdiff")
    fm.open()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    -- alphabetical file order: new.txt, src/a.lua, src/z.lua, top.txt
    local order = {}
    for _, l in ipairs(lines) do
      local p = l:match("^▎ (%S+)")
      if p then order[#order + 1] = p end
    end
    H.eq(order, { "new.txt", "src/a.lua", "src/z.lua", "top.txt" })
    -- jump into src/a.lua's +return 20 line
    local target
    for i, l in ipairs(lines) do if l == "+return 20" then target = i end end
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert(vim.api.nvim_buf_get_name(0):find("src/a.lua", 1, true), "should be in a.lua")
    local file_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return 99" })
    vim.api.nvim_feedkeys(vim.keycode("<C-Space>"), "x", false)
    local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local found = false
    for _, l in ipairs(after) do if l == "+return 99" then found = true end end
    assert(found, "canvas must show the edited content")

    fm.close()
    wipe_buffer(file_buf)
    remove_fixture(root)
  end,
  -- Enter (and double-click, which shares the handler) is fold-BLIND: on a folded
  -- file's placeholder it opens the file and leaves the fold alone. Two verbs with
  -- no exceptions -- this one goes to a file, Tab folds one. It used to expand the
  -- placeholder instead, which both duplicated Tab and made Enter's meaning depend
  -- on state you cannot see from the keypress.
  ["e2e: Enter on a folded placeholder opens the file, fold untouched"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "a1\na2\na3\n" },
      worktree = { ["a.txt"] = "A1\na2\na3\n" },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    fm.open()

    local canvas_mod = require("canvasdiff.canvas")
    local canvas_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("za"), "x", false)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(lines[1]:match("^▸ a%.txt"), "sanity: folded to its placeholder: " .. lines[1])

    -- Enter on that placeholder opens the real file.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert(vim.api.nvim_buf_get_name(0):find("a.txt", 1, true),
      "Enter must open the file, not unfold: in " .. vim.api.nvim_buf_get_name(0))
    local file_buf = vim.api.nvim_get_current_buf()

    -- And coming back lands on the placeholder, still folded.
    vim.api.nvim_feedkeys(vim.keycode("<C-Space>"), "x", false)
    H.eq(vim.api.nvim_get_current_buf(), canvas_buf, "back on the canvas")
    local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(after[1]:match("^▸ a%.txt"), "the fold survived the round trip: " .. after[1])
    H.eq(vim.api.nvim_win_get_cursor(0)[1], 1, "and we landed on it")

    -- Double-click shares the handler, so it behaves the same.
    local dblclick
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(canvas_buf, "n")) do
      if m.lhs == "<2-LeftMouse>" then dblclick = m.callback end
    end
    assert(dblclick, "sanity: <2-LeftMouse> is mapped")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    dblclick()
    assert(vim.api.nvim_buf_get_name(0):find("a.txt", 1, true),
      "double-click opens it too")

    fm.close()
    wipe_buffer(file_buf)
    remove_fixture(root)
  end,
  ["e2e: <Tab> and <CR> on a folded-away placeholder reveal the directory"] = function()
    local root = H.git_fixture({
      committed = { ["a/one.txt"] = "1\n", ["a/two.txt"] = "2\n", ["b/three.txt"] = "3\n" },
      worktree = { ["a/one.txt"] = "1x\n", ["a/two.txt"] = "2x\n", ["b/three.txt"] = "3x\n" },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    local st = assert(fm.open())
    local canvas_win = vim.api.nvim_get_current_win()

    -- Fold a/ the way a user does: drive the sidebar's own <CR> mapping.
    local side_win = assert(sidebar_view(st))
    local sbuf = vim.api.nvim_win_get_buf(side_win)
    assert(sbuf, "sanity: the sidebar is open")
    local select_cr
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(sbuf, "n")) do
      if m.lhs == "<CR>" then select_cr = m.callback end
    end
    assert(select_cr, "sanity: the sidebar binds <CR>")
    vim.api.nvim_win_set_cursor(side_win, { 1, 0 }) -- the a/ dir row
    select_cr()

    local function canvas_lines()
      return vim.api.nvim_win_call(canvas_win, function()
        return vim.api.nvim_buf_get_lines(0, 0, -1, false)
      end)
    end
    local folded = canvas_lines()
    assert(folded[1]:match("^▸ a/one%.txt"), "sanity: folded away: " .. folded[1])
    assert(folded[2]:match("^▸ a/two%.txt"), "sanity: folded away: " .. folded[2])

    -- <Tab> on one of those placeholders reveals the whole directory, and says
    -- so -- one keypress bringing back siblings needs to announce itself.
    local notified = {}
    local real_notify = vim.notify
    vim.notify = function(msg) notified[#notified + 1] = msg end
    local ok, err = pcall(function()
      vim.api.nvim_set_current_win(canvas_win)
      vim.api.nvim_win_set_cursor(canvas_win, { 1, 0 })
      vim.api.nvim_feedkeys(vim.keycode("za"), "x", false)
    end)
    vim.notify = real_notify
    assert(ok, err)

    local revealed = canvas_lines()
    assert(not revealed[1]:match("^▸"),
      "<Tab> must reveal the folded directory, not sit there dead: " .. revealed[1])
    assert(not revealed[2]:match("^▸ a/two%.txt"),
      "revealing clears the whole directory, not just the row under the cursor")
    assert(#notified > 0 and notified[1]:find("a/", 1, true),
      "the reveal is announced, naming the directory: " .. vim.inspect(notified))

    -- The tree agrees: a/ is expanded again and its files are back as rows.
    local slines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
    H.eq(slines[1], "▾ a/", "the sidebar shows it unfolded")

    -- And <CR> does the same, rather than jumping into a one-row section.
    -- Re-fold a/: the reveal's sidebar.sync moved the tree cursor onto the
    -- newly-visible file row, so put it back on the dir row first.
    vim.api.nvim_win_set_cursor(vim.fn.bufwinid(sbuf), { 1, 0 })
    select_cr()
    assert(canvas_lines()[1]:match("^▸ a/one%.txt"), "sanity: folded again")
    vim.api.nvim_set_current_win(canvas_win)
    vim.api.nvim_win_set_cursor(canvas_win, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    local selected_buf = vim.api.nvim_get_current_buf()
    local file_buf = not require("canvasdiff.canvas").is_canvas_buf(selected_buf)
      and selected_buf or nil
    H.eq(vim.api.nvim_get_current_win(), canvas_win, "<CR> must not jump out of the canvas")
    assert(not canvas_lines()[1]:match("^▸"), "<CR> reveals it too")

    fm.close()
    wipe_buffer(file_buf)
    remove_fixture(root)
  end,
  -- The test above presses <Tab> on the TOP placeholder, where the viewport
  -- top and the cursor are the same row and resplice's "above" branch happens
  -- to carry lnum along. One row down, resplice's viewport-anchored branch
  -- forced lnum to the first expanding section's start and the cursor came to
  -- rest on a file the user never pressed on -- after which <CR>, ]f and ]h all
  -- operated from the wrong section.
  ["e2e: <Tab> on the lower placeholder of a fold reveals under the cursor"] = function()
    local root = H.git_fixture({
      committed = { ["a/one.txt"] = "1\n", ["a/two.txt"] = "2\n" },
      worktree = { ["a/one.txt"] = "1x\n", ["a/two.txt"] = "2x\n" },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    local st = assert(fm.open())
    local canvas_win = vim.api.nvim_get_current_win()

    local side_win = assert(sidebar_view(st))
    local sbuf = vim.api.nvim_win_get_buf(side_win)
    assert(sbuf, "sanity: the sidebar is open")
    local select_cr
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(sbuf, "n")) do
      if m.lhs == "<CR>" then select_cr = m.callback end
    end
    vim.api.nvim_win_set_cursor(side_win, { 1, 0 }) -- the a/ dir row
    select_cr()

    local function canvas_lines()
      return vim.api.nvim_win_call(canvas_win, function()
        return vim.api.nvim_buf_get_lines(0, 0, -1, false)
      end)
    end
    local folded = canvas_lines()
    assert(folded[1]:match("^▸ a/one%.txt"), "sanity: row 1 is one.txt: " .. folded[1])
    assert(folded[2]:match("^▸ a/two%.txt"), "sanity: row 2 is two.txt: " .. folded[2])

    -- Row 2 -- a/two.txt -- with the viewport top still on row 1.
    vim.api.nvim_set_current_win(canvas_win)
    vim.api.nvim_win_call(canvas_win, function()
      vim.fn.winrestview({ topline = 1, lnum = 2 })
    end)
    local real_notify = vim.notify
    vim.notify = function() end
    local ok, err = pcall(function()
      vim.api.nvim_feedkeys(vim.keycode("za"), "x", false)
    end)
    vim.notify = real_notify
    assert(ok, err)

    local revealed = canvas_lines()
    assert(not revealed[1]:match("^▸"), "sanity: the directory did unfold")
    local cur = vim.api.nvim_win_get_cursor(canvas_win)[1]
    assert(revealed[cur]:match("^▎ a/two%.txt"),
      ("cursor must stay on the file that was pressed; landed on row %d: %s")
        :format(cur, revealed[cur]))

    fm.close()
    remove_fixture(root)
  end,
  ["e2e: toggle and no-repo error"] = function()
    local dir = H.tmpdir()
    vim.api.nvim_set_current_dir(dir)
    local fm = require("canvasdiff")
    local messages = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
      messages[#messages + 1] = { msg = msg, level = level }
    end
    local result, open_err
    local ok, call_err = pcall(function()
      result, open_err = fm.open()
    end)
    vim.notify = real_notify

    assert(ok, "open outside a repo must not throw: " .. tostring(call_err))
    H.eq(result, nil)
    assert(type(open_err) == "string"
      and open_err:find("not inside a git repository", 1, true),
      "open returns the no-repository error: " .. tostring(open_err))
    H.eq(#messages, 1, "the expected warning is captured instead of leaking to stdout")
    H.eq(messages[1].level, vim.log.levels.WARN)
    assert(messages[1].msg:find("not inside a git repository", 1, true),
      "the warning explains the failure: " .. messages[1].msg)
    assert(messages[1].msg:find(dir, 1, true),
      "the warning names the directory it inspected: " .. messages[1].msg)
    remove_fixture(dir)
  end,
  ["e2e: close() does not clobber a window that navigated away from the canvas"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "a\n" },
      worktree = { ["a.txt"] = "A\n" },
    })
    vim.api.nvim_set_current_dir(root)
    local other = vim.fs.joinpath(root, "other.txt")
    local f = assert(io.open(other, "w")); f:write("other content\n"); f:close()

    local fm = require("canvasdiff")
    fm.open()
    assert(
      require("canvasdiff.canvas").is_canvas_buf(vim.api.nvim_get_current_buf()),
      "canvas should be showing after open()"
    )

    -- Navigate the same window away from the canvas without calling close().
    vim.cmd.edit(other)
    local edited_buf = vim.api.nvim_get_current_buf()
    H.eq(vim.fs.basename(vim.api.nvim_buf_get_name(edited_buf)), "other.txt")

    fm.close()
    H.eq(vim.api.nvim_get_current_buf(), edited_buf, "close() must not swap away the window's current buffer")
    H.eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), "other.txt")
    wipe_buffer(edited_buf)
    remove_fixture(root)
  end,
  -- `:q` destroys the canvas window without going through App:close, whose teardown
  -- sat behind `#wins == 0` -- true forever once the window is gone. So watch kept
  -- its fs handles and its blocking git reconcile running for the rest of the
  -- session (its only lifecycle hook is BufWipeout, and the canvas buffer is
  -- bufhidden=hide, so `:q` hides it and the hook never fires), and the session was
  -- never saved -- which silently discarded the folds you had set.
  ["e2e: :q on the canvas saves the session and stops every subsystem"] = function()
    local root = H.git_fixture({
      committed = { ["src/a.txt"] = "a\n", ["src/b.txt"] = "b\n", ["top.txt"] = "t\n" },
      worktree = { ["src/a.txt"] = "ax\n", ["src/b.txt"] = "bx\n", ["top.txt"] = "tx\n" },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    local session = require("canvasdiff.session")
    os.remove(session.path_for(root))

    -- Own tab with a spare non-canvas window, so closing the canvas window neither
    -- quits Neovim nor leaves a second window showing the canvas.
    vim.cmd("tabnew")
    vim.cmd("split")
    vim.cmd("enew")
    local spare = vim.api.nvim_get_current_win()
    vim.cmd("wincmd j")
    local st = assert(fm.open())
    local canvas_win = vim.api.nvim_get_current_win()
    assert(canvas_win ~= spare, "sanity: the canvas took its own window")

    -- Fold src/ the way a user does, through the sidebar's own <CR>.
    local side_win = assert(sidebar_view(st))
    local sbuf = vim.api.nvim_win_get_buf(side_win)
    assert(sbuf, "sanity: the sidebar is open")
    local select_cr
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(sbuf, "n")) do
      if m.lhs == "<CR>" then select_cr = m.callback end
    end
    local srow
    for i, l in ipairs(vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)) do
      if l == "▾ src/" then srow = i break end
    end
    assert(srow, "sanity: found the src/ row")
    vim.api.nvim_win_set_cursor(side_win, { srow, 0 })
    select_cr()

    for _, g in ipairs({
      "canvasdiff.watch", "canvasdiff.virt", "canvasdiff.highlight", "canvasdiff.sidebar",
      "canvasdiff.scrollbar", "canvasdiff.session",
    }) do
      assert(group_alive(g), "sanity: " .. g .. " is armed before the close")
    end

    -- The `:q`. nvim_win_close fires WinClosed exactly as `:quit` does.
    vim.api.nvim_win_close(canvas_win, false)
    vim.wait(200, function() return not group_alive("canvasdiff.watch") end)

    for _, g in ipairs({
      "canvasdiff.watch", "canvasdiff.virt", "canvasdiff.highlight", "canvasdiff.status_column",
      "canvasdiff.sidebar", "canvasdiff.scrollbar", "canvasdiff.session",
    }) do
      assert(not group_alive(g), g .. " must be torn down by `:q`, not left running")
    end

    local data = session.load(root)
    assert(data, "`:q` must save the session, not leave it to a reopen to lose")
    H.eq(data.folds, { "src/" }, "the fold you set survives `:q`")

    os.remove(session.path_for(root))
    vim.cmd("tabonly!")
    remove_fixture(root)
  end,
  -- The teardown is deferred and re-checks, so closing one of two windows showing
  -- the canvas must not tear anything down.
  ["e2e: closing one of two canvas windows keeps the canvas alive"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "a\n" }, worktree = { ["a.txt"] = "ax\n" },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    local session = require("canvasdiff.session")

    vim.cmd("tabnew")
    fm.open()
    local first = vim.api.nvim_get_current_win()
    vim.cmd("split") -- a SECOND window on the same canvas buffer
    local second = vim.api.nvim_get_current_win()
    assert(first ~= second)

    vim.api.nvim_win_close(second, false)
    vim.wait(120, function() return false end)

    assert(group_alive("canvasdiff.watch"),
      "the canvas is still on screen in the other window, so nothing may tear down")
    fm.close()
    os.remove(session.path_for(root))
    vim.cmd("tabonly!")
    remove_fixture(root)
  end,
  -- `r` (refresh) is the manual version of watch's pass, and it must hold the niri
  -- invariant: content changing OUTSIDE the viewport never moves what you are
  -- reading. It used to call render_all, which recreated every anchor and restored
  -- no view -- so the key you pressed to make the canvas trustworthy was the key
  -- that lost your place in it.
  --
  -- Asserted on TEXT, not on line numbers, because the numbers are SUPPOSED to move
  -- here: three lines are added to a file that sorts above the cursor, so holding
  -- the same content under the cursor requires topline to advance by exactly three.
  -- A line-number assertion would fail on correct behaviour and pass on render_all,
  -- which leaves the number alone and slides different text underneath it. Verified:
  -- an earlier version of this check called `r` broken and `R` fine, exactly backwards.
  ["e2e: r refreshes without moving what you are reading"] = function()
    local function body(tag, marks)
      local o = {}
      for i = 1, 90 do
        o[i] = tag .. " line " .. i .. ((marks and i % 10 == 0) and " changed" or "")
      end
      return table.concat(o, "\n") .. "\n"
    end
    local root = H.git_fixture({
      committed = { ["a.txt"] = body("a"), ["z.txt"] = body("z") },
      worktree = { ["a.txt"] = body("a", true), ["z.txt"] = body("z", true) },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    fm.open()
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()

    -- Park deep in the canvas, well inside the second file (z.txt), which sorts
    -- AFTER the file that is about to change.
    local total = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = math.floor(total * 0.6), lnum = math.floor(total * 0.6) + 4 })
    end)
    local function snap()
      return vim.api.nvim_win_call(win, function()
        local top, cur = vim.fn.line("w0"), vim.api.nvim_win_get_cursor(win)[1]
        return {
          top = top,
          lnum = cur,
          top_text = vim.fn.getline(top),
          cur_text = vim.fn.getline(cur),
        }
      end)
    end
    local before = snap()
    assert(before.top > 1, "sanity: parked away from the top of the canvas")

    -- Grow a.txt, which sorts first, so its section grows strictly ABOVE us.
    local f = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
    f:write(body("a", true) .. "tail1\ntail2\ntail3\n")
    f:close()

    vim.api.nvim_set_current_win(win)
    vim.api.nvim_feedkeys(vim.keycode("r"), "x", false)

    local after = snap()
    local all = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert(all:find("tail3", 1, true), "`r` must actually pick the new content up")
    H.eq(after.cur_text, before.cur_text, "the same TEXT is still under the cursor")
    H.eq(after.top_text, before.top_text, "and the same text is still at the window top")
    -- Proves the test cannot pass by `r` having done nothing at all: three lines
    -- landed above us, so the row numbers must have advanced by three.
    H.eq(after.top - before.top, 3, "topline advanced by exactly the lines inserted above")
    H.eq(after.lnum - before.lnum, 3, "and so did the cursor row")

    fm.close()
    remove_fixture(root)
  end,
  -- The honest limit of `r`, and the reason there is no hard-rebuild key.
  --
  -- A reconcile compares state.sections against freshly-collected truth and skips
  -- what matches, so it assumes state.sections describes the BUFFER. If those ever
  -- diverge, no number of refreshes can fix it -- the comparison keeps saying
  -- "nothing to do". That is a real gap, and it argued for a hard-rebuild verb.
  --
  -- It argued wrong: close() + open() repairs the divergence too AND restores your
  -- position through the session file, which a bare render_all does not. Measured
  -- three ways on a corrupted buffer -- refresh: not repaired; rebuild: repaired,
  -- position lost; close+open: repaired, position kept. So this test pins both
  -- halves: that `r` does NOT claim to repair this, and that the documented
  -- recovery genuinely does.
  --
  -- Note the corruption has to unset 'modifiable' first: nomodifiable blocks
  -- nvim_buf_set_lines as well as typed keys, so only canvasdiff can corrupt canvasdiff's
  -- own buffer. That is itself part of why a user-facing rebuild key is not needed.
  ["e2e: refresh cannot repair a divergent buffer, close+open can"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "a1\na2\na3\na4\na5\na6\na7\na8\n" },
      worktree = { ["a.txt"] = "A1\na2\na3\na4\nA5\na6\na7\na8\n" },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    fm.open()
    local buf = vim.api.nvim_get_current_buf()

    -- Desynchronize the buffer from state.sections, the way an internal bug would.
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 2, 4, false, { "XXX DIVERGED XXX" })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    local function diverged(b)
      return (table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"))
        :find("DIVERGED", 1, true) ~= nil
    end
    assert(diverged(buf), "sanity: the buffer really is out of sync now")

    -- Refresh cannot see it: state.sections still matches what git reports, so the
    -- merge-walk finds nothing to splice. Pressing it twice makes the point.
    vim.api.nvim_feedkeys(vim.keycode("r"), "x", false)
    vim.api.nvim_feedkeys(vim.keycode("r"), "x", false)
    assert(diverged(buf),
      "refresh must NOT be expected to repair this -- it compares model to git, "
      .. "not model to buffer. If this ever starts passing, the reconcile learned "
      .. "to verify against the buffer and this whole test needs rethinking.")

    -- The documented recovery does repair it.
    fm.close()
    fm.open()
    local after = vim.api.nvim_get_current_buf()
    assert(not diverged(after), "close+open must rebuild the canvas cleanly")
    assert(vim.api.nvim_buf_line_count(after) > 1, "and leave a real canvas behind")

    fm.close()
    remove_fixture(root)
  end,
  -- Orientation: the sidebar and the canvas must never disagree about which file you
  -- are in, including while a jump excursion has the canvas out of its window.
  --
  -- Three defects this covers, all of which were live:
  --   1. sidebar.sync bails during an excursion, so the active row stayed on the file
  --      you left -- a locator pointing confidently at the WRONG file.
  --   2. Enter in the sidebar during an excursion was a silent no-op: the tree sat
  --      there, nothing happened, nothing said why.
  --   3. The winbar named only the lens, so once a file's header scrolled off there
  --      was nothing in the canvas saying which block you were reading.
  ["e2e: the sidebar and winbar agree about where you are, jumps included"] = function()
    local function body(tag, marks)
      local o = {}
      for i = 1, 60 do
        o[i] = tag .. " L" .. i .. ((marks and i % 5 == 0) and " ch" or "")
      end
      return table.concat(o, "\n") .. "\n"
    end
    local root = H.git_fixture({
      committed = { ["aaa.txt"] = body("aaa"), ["zzz.txt"] = body("zzz") },
      worktree = { ["aaa.txt"] = body("aaa", true), ["zzz.txt"] = body("zzz", true) },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    fm.open()
    local cwin, cbuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_height(cwin, 12)

    local function wb() return vim.api.nvim_get_option_value("winbar", { win = cwin }) end

    assert(wb():match("aaa%.txt"), "the winbar names the file under the topline: " .. wb())

    -- Scroll deep INSIDE zzz.txt, past its header, then drive the scroll hook by hand
    -- (WinScrolled never fires headlessly -- see the harness notes).
    local zrow
    for i, l in ipairs(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)) do
      if l:match("^▎ zzz%.txt") then zrow = i end
    end
    assert(zrow, "sanity: zzz.txt has a header")
    vim.api.nvim_win_call(cwin, function()
      vim.fn.winrestview({ topline = zrow + 20, lnum = zrow + 22 })
    end)
    vim.api.nvim_exec_autocmds("WinScrolled", {})
    assert(wb():match("zzz%.txt"),
      "the winbar follows the topline into the next file, which is the whole point -- "
      .. "its header has scrolled off by now. got: " .. wb())

    fm.close()
    -- Left armed, this resolves sections against a dead state on every scroll anywhere.
    assert(not pcall(vim.api.nvim_get_autocmds, { group = "canvasdiff.winbar" }),
      "the winbar augroup must be reaped by teardown")
    remove_fixture(root)
  end,
  -- The excursion half, deliberately on SMALL files so the whole canvas fits one
  -- window. That is load-bearing for the test, not incidental: with tall files the
  -- topline is already inside the file you jump into, so the pre-jump sync has already
  -- highlighted it and removing the follow-the-jump call changes nothing observable.
  -- Verified: the tall-file version passed with sidebar.mark_path deleted.
  --
  -- Here the topline sits in aaa.txt while the cursor is down in zzz.txt, so the two
  -- answers differ and only a real follow produces zzz.txt.
  ["e2e: the sidebar follows you into a jump, and Enter in it is not a dead end"] = function()
    local root = H.git_fixture({
      committed = { ["aaa.txt"] = "a1\na2\na3\n", ["zzz.txt"] = "z1\nz2\nz3\n" },
      worktree = { ["aaa.txt"] = "A1\na2\na3\n", ["zzz.txt"] = "Z1\nz2\nz3\n" },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    local st = assert(fm.open())
    local cwin, cbuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()

    local NS = vim.api.nvim_create_namespace("canvasdiff.sidebar")
    local function sbwin()
      return sidebar_view(st)
    end
    local function active()
      local w = sbwin()
      if not w then return nil end
      local b = vim.api.nvim_win_get_buf(w)
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, { details = true })) do
        if m[4] and m[4].line_hl_group == "CanvasDiffSidebarActive" then
          return vim.api.nvim_buf_get_lines(b, m[2], m[2] + 1, false)[1]
        end
      end
    end
    local function wb() return vim.api.nvim_get_option_value("winbar", { win = cwin }) end

    -- Topline at the very top, so the tree's active row resolves to aaa.txt.
    vim.api.nvim_win_call(cwin, function() vim.fn.winrestview({ topline = 1, lnum = 1 }) end)
    vim.api.nvim_exec_autocmds("WinScrolled", {})
    assert((active() or ""):match("aaa"),
      "sanity: the topline is in aaa.txt, so that is what the tree highlights. got: "
      .. tostring(active()))

    -- Cursor down into zzz.txt WITHOUT scrolling, then jump.
    local zline
    for i, l in ipairs(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)) do
      if l == "+Z1" then zline = i end
    end
    assert(zline, "sanity: zzz.txt's change is on the canvas")
    vim.api.nvim_win_set_cursor(cwin, { zline, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert(vim.api.nvim_buf_get_name(0):match("zzz%.txt"), "sanity: editing zzz.txt")
    local file_buf = vim.api.nvim_get_current_buf()
    assert((active() or ""):match("zzz"),
      "the tree must follow the jump. It used to keep pointing at the file the TOPLINE "
      .. "was in -- confidently naming the wrong file. got: " .. tostring(active()))

    -- Enter in the sidebar mid-excursion: ends the excursion and goes there, rather
    -- than silently doing nothing at all.
    local sw = sbwin()
    vim.api.nvim_set_current_win(sw)
    local arow
    for i, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sw), 0, -1, false)) do
      if l:match("aaa") then arow = i end
    end
    assert(arow, "sanity: aaa.txt has a sidebar row")
    vim.api.nvim_win_set_cursor(sw, { arow, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)

    local back = false
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == cbuf then back = true end
    end
    assert(back, "selecting a file mid-excursion must bring the canvas back, not no-op")
    assert(wb():match("aaa%.txt"),
      "and the winbar must name where it landed -- a programmatic scroll fires no "
      .. "WinScrolled, which is why sidebar.sync signals on_locate. got: " .. wb())
    assert((active() or ""):match("aaa"), "and the active row agrees: " .. tostring(active()))

    fm.close()
    wipe_buffer(file_buf)
    remove_fixture(root)
  end,
  -- The file-boundary bar: a full-width tint on each expanded file's header row, so
  -- crossing out of one file and into the next is visible while scrolling rather than
  -- being one more line among diff lines.
  --
  -- Two properties that are easy to break and would not look broken:
  --   * It must NOT land on folded placeholders. Each is already one visually distinct
  --     row and has no body to delimit; barring all of them turns an auto-virtualized
  --     canvas of 200 collapsed files into a solid block of colour.
  --   * It must survive a splice. Highlights are re-applied per section by
  --     apply_section_hl, so a bar added anywhere else would silently vanish on the
  --     first `r` or watch pass.
  ["e2e: a boundary bar marks each expanded file, and only those"] = function()
    local function body(tag, marks)
      local o = {}
      for i = 1, 20 do
        o[i] = tag .. " L" .. i .. ((marks and i % 5 == 0) and " ch" or "")
      end
      return table.concat(o, "\n") .. "\n"
    end
    local names = { "aaa.txt", "mmm.txt", "zzz.txt" }
    local committed, worktree = {}, {}
    for _, n in ipairs(names) do
      committed[n] = body(n)
      worktree[n] = body(n, true)
    end
    local root = H.git_fixture({ committed = committed, worktree = worktree })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    fm.open()
    local cwin, cbuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()

    local function bars()
      local rows = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(cbuf, -1, 0, -1, { details = true })) do
        if m[4] and m[4].line_hl_group == "CanvasDiffFileBar" then rows[#rows + 1] = m[2] + 1 end
      end
      table.sort(rows)
      return rows
    end
    local function rows_matching(pat)
      local r = {}
      for i, l in ipairs(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)) do
        if l:match(pat) then r[#r + 1] = i end
      end
      return r
    end

    H.eq(bars(), rows_matching("^▎"), "exactly one bar per expanded file header")
    H.eq(#bars(), 3, "sanity: three files")

    -- The composition claim the priorities rest on: the bar supplies a background and
    -- CanvasDiffFileHeader supplies only a foreground, so the filename keeps Title's colour
    -- ON the tinted row. If the header group ever gains a bg, it would paint over the
    -- bar for the width of the text and the row would look striped.
    local bar = vim.api.nvim_get_hl(0, { name = "CanvasDiffFileBar", link = false })
    local hdr = vim.api.nvim_get_hl(0, { name = "CanvasDiffFileHeader", link = false })
    assert(bar.bg, "the bar group must resolve to a real background to be visible")
    assert(hdr.bg == nil,
      "CanvasDiffFileHeader must stay foreground-only so it composes with the bar")

    -- Fold the middle file: its bar goes with its body.
    vim.api.nvim_win_set_cursor(cwin, { rows_matching("^▎")[2], 0 })
    vim.api.nvim_feedkeys(vim.keycode("c"), "x", false)
    local placeholders = rows_matching("^▸")
    H.eq(#placeholders, 1, "sanity: one folded placeholder")
    H.eq(bars(), rows_matching("^▎"), "still one bar per EXPANDED header")
    local ph = {}
    for _, r in ipairs(placeholders) do ph[r] = true end
    for _, r in ipairs(bars()) do
      assert(not ph[r], "no bar may sit on a folded placeholder row (row " .. r .. ")")
    end

    vim.api.nvim_feedkeys(vim.keycode("c"), "x", false)
    H.eq(bars(), rows_matching("^▎"), "unfolding brings its bar back")

    -- And through a splice, which re-applies section highlights.
    local f = assert(io.open(vim.fs.joinpath(root, "aaa.txt"), "w"))
    f:write(body("aaa.txt", true) .. "tail\n")
    f:close()
    vim.api.nvim_set_current_win(cwin)
    vim.api.nvim_feedkeys(vim.keycode("r"), "x", false)
    H.eq(bars(), rows_matching("^▎"), "bars survive a refresh's splice")

    fm.close()
    remove_fixture(root)
  end,
  -- The result view: the canvas shows the file as it WILL be. Deletions are drawn as
  -- virtual lines rather than buffer rows, so every remaining row maps 1:1 to a real
  -- file line.
  --
  -- The payoff assertion is the last one. jump.enter's target_lnum walks FORWARD off a
  -- row with no new_lnum to find a line it can use -- so with deletions as rows,
  -- pressing Enter on one silently landed you on a different line than the one under
  -- your cursor. Measured on this repo: 897 of 6999 rows behaved that way. Here Enter
  -- lands exactly where you pointed, and that is checked against the real file's
  -- content rather than just a line number.
  ["e2e: deletions are ghosts, and Enter lands on the row you pointed at"] = function()
    local root = H.git_fixture({
      committed = {
        ["a.lua"] = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n",
        ["gone.txt"] = "bye1\nbye2\n",
      },
      worktree = {
        ["a.lua"] = "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\n",
        ["gone.txt"] = false, -- deleted outright
      },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    fm.open()
    local cwin, cbuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local text = table.concat(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false), "\n")

    assert(not text:find("-three", 1, true),
      "the replaced line must not be a buffer row any more")
    assert(text:find("+THREE", 1, true), "its replacement is a real row")

    -- It is rendered, as a virt_lines ghost above the row that replaced it.
    local ghosts = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(cbuf, -1, 0, -1, { details = true })) do
      if m[4] and m[4].virt_lines then
        for _, vl in ipairs(m[4].virt_lines) do
          ghosts[#ghosts + 1] = { row = m[2] + 1, text = vl[1][1], hl = vl[1][2] }
        end
      end
    end
    H.eq(#ghosts, 1, "exactly one ghost, for the one replaced line")
    H.eq(ghosts[1].text, "-three", "carrying the old content, still prefixed")
    H.eq(ghosts[1].hl, "CanvasDiffGhost", "in its own group, so it can be dimmed alone")

    -- A file with no new side keeps deletions as REAL rows: a result view of it would
    -- be empty, and its whole content would become unyankable virtual text.
    assert(text:find("-bye1", 1, true) and text:find("-bye2", 1, true),
      "a wholly-deleted file still renders its lines as rows")

    -- The payoff.
    local trow
    for i, l in ipairs(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)) do
      if l == "+THREE" then trow = i end
    end
    assert(trow, "sanity: the replacement row is on the canvas")
    vim.api.nvim_win_set_cursor(cwin, { trow, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert(vim.api.nvim_buf_get_name(0):match("a%.lua"), "Enter opened the file")
    local file_buf = vim.api.nvim_get_current_buf()
    H.eq(vim.api.nvim_win_get_cursor(0)[1], 3, "on the line the cursor was on")
    H.eq(vim.api.nvim_buf_get_lines(0, 2, 3, false)[1], "THREE",
      "and that line really is the one we pointed at in the canvas")

    vim.api.nvim_feedkeys(vim.keycode("<C-Space>"), "x", false)
    H.eq(vim.api.nvim_get_current_buf(), cbuf, "and the round trip still works")
    fm.close()
    wipe_buffer(file_buf)
    remove_fixture(root)
  end,
  ["e2e: invalid ref on initial open leaves the file window untouched"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "before\n" },
      worktree = { ["a.txt"] = "after\n" },
    })
    -- Earlier e2e cases may have restored a file buffer and then removed its
    -- fixture directory. Detach from that dead path before this test records
    -- what its own real-file window looks like.
    vim.cmd("enew!")
    vim.api.nvim_set_current_dir(root)
    vim.cmd.edit(vim.fs.joinpath(root, "a.txt"))

    -- A fresh owner state, while retaining the same subordinate modules and
    -- cached canvas buffer a real close/reopen cycle would use.
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    local lens = require("canvasdiff.diff").lens
    local session = require("canvasdiff.session")

    local before = {
      win = vim.api.nvim_get_current_win(),
      buf = vim.api.nvim_get_current_buf(),
      wins = vim.api.nvim_list_wins(),
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
      view = vim.fn.winsaveview(),
      winbar = vim.api.nvim_get_option_value("winbar", { win = 0 }),
    }
    local messages = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
      messages[#messages + 1] = { msg = msg, level = level }
    end
    local result, open_err
    local called, call_err = pcall(function()
      result, open_err = fm.open({ lens = lens.branch("definitely-missing") })
    end)
    vim.notify = real_notify

    assert(called, "invalid initial open must report, not throw: " .. tostring(call_err))
    H.eq(result, nil)
    assert(type(open_err) == "string" and open_err:find("does not resolve", 1, true),
      "open returns the collection error: " .. tostring(open_err))
    H.eq(vim.api.nvim_get_current_win(), before.win, "the current window is untouched")
    H.eq(vim.api.nvim_get_current_buf(), before.buf, "the real file remains displayed")
    H.eq(vim.api.nvim_list_wins(), before.wins, "no sidebar or scrollbar window opened")
    H.eq(vim.api.nvim_buf_get_lines(before.buf, 0, -1, false), before.lines)
    H.eq(vim.fn.winsaveview(), before.view)
    H.eq(vim.api.nvim_get_option_value("winbar", { win = before.win }), before.winbar)
    assert(#messages == 1 and messages[1].msg:find("does not resolve", 1, true),
      "exactly the failure is reported: " .. vim.inspect(messages))
    H.eq(vim.uv.fs_stat(session.path_for(root)), nil,
      "no owner state was created that close/session persistence could observe")

    wipe_buffer(before.buf)
    remove_fixture(root)
  end,
  ["e2e: invalid live lens pivot is an observational no-op"] = function()
    local function body(tag, changed)
      local lines = {}
      for i = 1, 70 do
        lines[i] = ("%s line %d%s"):format(tag, i,
          changed and i % 10 == 0 and " changed" or "")
      end
      return table.concat(lines, "\n") .. "\n"
    end
    local root = H.git_fixture({
      committed = { ["a.txt"] = body("a"), ["b.txt"] = body("b") },
      worktree = { ["a.txt"] = body("a", true), ["b.txt"] = body("b", true) },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    local session = require("canvasdiff.session")
    local st = assert(fm.open())

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = 12, lnum = 18 })
    end)

    local side_win = assert(sidebar_view(st))
    local sidebar_buf = vim.api.nvim_win_get_buf(side_win)
    assert(sidebar_buf, "sanity: default UI opened the sidebar")
    local anchor_ns = vim.api.nvim_get_namespaces()["canvasdiff.canvas.anchors"]
    local before = {
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      tick = vim.api.nvim_buf_get_changedtick(buf),
      anchors = vim.api.nvim_buf_get_extmarks(buf, anchor_ns, 0, -1, { details = true }),
      view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
      winbar = vim.api.nvim_get_option_value("winbar", { win = win }),
      statuscolumn = vim.api.nvim_get_option_value("statuscolumn", { win = win }),
      sidebar_lines = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false),
      sidebar_tick = vim.api.nvim_buf_get_changedtick(sidebar_buf),
      windows = vim.api.nvim_list_wins(),
    }

    local messages = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
      messages[#messages + 1] = { msg = msg, level = level }
    end
    local result, pivot_err
    local called, call_err = pcall(function()
      result, pivot_err = fm.set_branch("definitely-missing")
    end)
    vim.notify = real_notify

    assert(called, "invalid pivot must report, not throw: " .. tostring(call_err))
    H.eq(result, nil)
    assert(type(pivot_err) == "string" and pivot_err:find("does not resolve", 1, true),
      "set_branch returns the collection error: " .. tostring(pivot_err))
    H.eq(vim.api.nvim_get_current_win(), win)
    H.eq(vim.api.nvim_get_current_buf(), buf)
    H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before.lines,
      "no section was reconciled")
    H.eq(vim.api.nvim_buf_get_changedtick(buf), before.tick,
      "the canvas buffer was not written at all")
    H.eq(vim.api.nvim_buf_get_extmarks(buf, anchor_ns, 0, -1, { details = true }),
      before.anchors, "anchors were not recreated or moved")
    H.eq(vim.api.nvim_win_call(win, vim.fn.winsaveview), before.view,
      "cursor and viewport are identical")
    H.eq(vim.api.nvim_get_option_value("winbar", { win = win }), before.winbar,
      "the visible lens label did not change")
    H.eq(vim.api.nvim_get_option_value("statuscolumn", { win = win }), before.statuscolumn)
    H.eq(vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false), before.sidebar_lines)
    H.eq(vim.api.nvim_buf_get_changedtick(sidebar_buf), before.sidebar_tick,
      "no sidebar refresh ran")
    H.eq(vim.api.nvim_list_wins(), before.windows, "no UI window was replaced")
    assert(#messages == 1 and messages[1].msg:find("does not resolve", 1, true),
      "only the error is reported, never a showing-success message: " .. vim.inspect(messages))

    -- The winbar is observable evidence; the saved payload pins the private
    -- owner fields too. A failed candidate may not leak into lens or base.
    fm.close()
    local saved = assert(session.load(root))
    H.eq(saved.lens.id, "all")
    H.eq(saved.base, "HEAD")
    os.remove(session.path_for(root))
    vim.cmd("enew!")
    remove_fixture(root)
  end,
  ["e2e: refresh retains a branch canvas after its ref disappears"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "before\n" },
      worktree = { ["a.txt"] = "after\n" },
    })
    local branch = vim.system(
      { "git", "branch", "comparison-base", "HEAD" },
      { cwd = root, text = true }):wait()
    assert(branch.code == 0, branch.stderr)

    vim.api.nvim_set_current_dir(root)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    local lens = require("canvasdiff.diff").lens
    local session = require("canvasdiff.session")
    assert(fm.open({ lens = lens.branch("comparison-base") }))

    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local before = {
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      tick = vim.api.nvim_buf_get_changedtick(buf),
      view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
      winbar = vim.api.nvim_get_option_value("winbar", { win = win }),
    }
    local deleted = vim.system(
      { "git", "branch", "-D", "comparison-base" },
      { cwd = root, text = true }):wait()
    assert(deleted.code == 0, deleted.stderr)

    local messages = {}
    local real_notify = vim.notify
    vim.notify = function(msg) messages[#messages + 1] = msg end
    local refreshed, refresh_err = fm.refresh()
    vim.notify = real_notify

    H.eq(refreshed, nil)
    assert(type(refresh_err) == "string" and refresh_err:find("does not resolve", 1, true))
    H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before.lines)
    H.eq(vim.api.nvim_buf_get_changedtick(buf), before.tick)
    H.eq(vim.api.nvim_win_call(win, vim.fn.winsaveview), before.view)
    H.eq(vim.api.nvim_get_option_value("winbar", { win = win }), before.winbar)
    assert(#messages == 1 and messages[1]:find("does not resolve", 1, true),
      "refresh reports the failure exactly once: " .. vim.inspect(messages))

    fm.close()
    local saved = assert(session.load(root))
    H.eq(saved.lens.id, "branch:comparison-base",
      "the private active lens remains the last valid branch comparison")
    os.remove(session.path_for(root))
    vim.cmd("enew!")
    remove_fixture(root)
  end,
  ["e2e: close() before any open() is a safe no-op"] = function()
    -- Force a fresh root facade so its default App has no state,
    -- regardless of what earlier test cases in this process did.
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")

    local buf_before = vim.api.nvim_get_current_buf()
    local ok = pcall(fm.close)
    assert(ok, "close() with no prior open() must not throw")
    H.eq(vim.api.nvim_get_current_buf(), buf_before, "close() must not touch the current buffer when nothing was ever opened")
  end,

  ["e2e: a large review opens paged, and a small one does not"] = function()
    -- The switchover, through the real command. A review below the threshold
    -- must stay eager, because the eager canvas is simpler and every plugin
    -- that reads buffer lines works on it unaided; a review above it must go
    -- paged, because the eager canvas is not viable there at all.
    local function body(tag, edited)
      local out = {}
      for index = 1, 12000 do
        out[index] = ("%s line %d"):format(tag, index)
        if edited and index % 3 == 0 then
          out[index] = out[index] .. " changed"
        end
      end
      return table.concat(out, "\n") .. "\n"
    end

    local dir = H.git_fixture({
      committed = { ["big.txt"] = body("b"), ["small.txt"] = "s1\ns2\n" },
      worktree = { ["big.txt"] = body("b", true), ["small.txt"] = "s1\nS2\n" },
    })
    vim.api.nvim_set_current_dir(dir)
    package.loaded["canvasdiff"] = nil
    local fm = require("canvasdiff")
    local canvas = require("canvasdiff.canvas")
    -- Configure the threshold rather than build a fixture large enough to
    -- cross the default one: the switchover is what is under test, not how
    -- many rows the default happens to be.
    fm.setup({ paged = { enabled = true, min_rows = 5000 } })

    local state = assert(fm.open())
    local ok, failure = xpcall(function()
      assert(state.paged, "a review of this size must open paged")
      assert(canvas.is_canvas_buf(state.buf) == false,
        "a paged canvas uses the projection's skeleton buffer")

      -- It behaves like a canvas: sections resolve, rows resolve, and the text
      -- is really there even though the buffer lines are blank.
      assert(#state.sections >= 2, "both changed files are in the review")
      local logical = canvas.logical(state)
      assert(logical.row_count() > 5000,
        "the paged canvas is smaller than the threshold that selected it")
      local first = assert(logical.row(0))
      assert(first:find("big.txt", 1, true),
        "the first row is not the first file's header: " .. first)
      H.eq(vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1], "",
        "the skeleton is not blank, so nothing is being paged")

      -- And it holds no persistent extmark, which is the whole point.
      local marks = 0
      for _, namespace in pairs(vim.api.nvim_get_namespaces()) do
        local read, found = pcall(
          vim.api.nvim_buf_get_extmarks, state.buf, namespace, 0, -1, {})
        if read then marks = marks + #found end
      end
      H.eq(marks, 0, "the paged canvas persisted an extmark")
    end, debug.traceback)
    fm.close()
    assert(ok, failure)

    -- The same repository with only the small file changed stays eager.
    local small_dir = H.git_fixture({
      committed = { ["small.txt"] = "s1\ns2\n" },
      worktree = { ["small.txt"] = "s1\nS2\n" },
    })
    vim.api.nvim_set_current_dir(small_dir)
    local small = assert(fm.open())
    local small_ok, small_failure = xpcall(function()
      H.eq(small.paged, nil, "a small review must not be paged")
      assert(canvas.is_canvas_buf(small.buf),
        "a small review still uses the eager canvas buffer")
    end, debug.traceback)
    fm.close()
    fm.setup({ paged = { enabled = true, min_rows = 20000 } })
    assert(small_ok, small_failure)
  end,

}
