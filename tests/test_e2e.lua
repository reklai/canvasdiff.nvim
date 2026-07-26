local H = require("helpers")

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
    local fm = require("galley")
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
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return 99" })
    vim.api.nvim_feedkeys(vim.keycode("<C-Space>"), "x", false)
    local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local found = false
    for _, l in ipairs(after) do if l == "+return 99" then found = true end end
    assert(found, "canvas must show the edited content")
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
    package.loaded["galley"] = nil
    local fm = require("galley")
    fm.open()

    local canvas_mod = require("galley.canvas")
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
  end,
  ["e2e: <Tab> and <CR> on a folded-away placeholder reveal the directory"] = function()
    local root = H.git_fixture({
      committed = { ["a/one.txt"] = "1\n", ["a/two.txt"] = "2\n", ["b/three.txt"] = "3\n" },
      worktree = { ["a/one.txt"] = "1x\n", ["a/two.txt"] = "2x\n", ["b/three.txt"] = "3x\n" },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["galley"] = nil
    local fm = require("galley")
    fm.open()
    local canvas_win = vim.api.nvim_get_current_win()

    -- Fold a/ the way a user does: drive the sidebar's own <CR> mapping.
    local sbuf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b)
        and vim.api.nvim_buf_get_name(b):find("galley://sidebar", 1, true) then
        sbuf = b
      end
    end
    assert(sbuf, "sanity: the sidebar is open")
    local select_cr
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(sbuf, "n")) do
      if m.lhs == "<CR>" then select_cr = m.callback end
    end
    assert(select_cr, "sanity: the sidebar binds <CR>")
    vim.api.nvim_win_set_cursor(vim.fn.bufwinid(sbuf), { 1, 0 }) -- the a/ dir row
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
    H.eq(vim.api.nvim_get_current_win(), canvas_win, "<CR> must not jump out of the canvas")
    assert(not canvas_lines()[1]:match("^▸"), "<CR> reveals it too")

    fm.close()
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
    package.loaded["galley"] = nil
    local fm = require("galley")
    fm.open()
    local canvas_win = vim.api.nvim_get_current_win()

    local sbuf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b)
        and vim.api.nvim_buf_get_name(b):find("galley://sidebar", 1, true) then
        sbuf = b
      end
    end
    assert(sbuf, "sanity: the sidebar is open")
    local select_cr
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(sbuf, "n")) do
      if m.lhs == "<CR>" then select_cr = m.callback end
    end
    vim.api.nvim_win_set_cursor(vim.fn.bufwinid(sbuf), { 1, 0 }) -- the a/ dir row
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
  end,
  ["e2e: toggle and no-repo error"] = function()
    local dir = H.tmpdir()
    vim.api.nvim_set_current_dir(dir)
    local fm = require("galley")
    local ok = pcall(fm.open)
    assert(ok, "open outside a repo must not throw (notify instead)")
  end,
  ["e2e: close() does not clobber a window that navigated away from the canvas"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "a\n" },
      worktree = { ["a.txt"] = "A\n" },
    })
    vim.api.nvim_set_current_dir(root)
    local other = vim.fs.joinpath(root, "other.txt")
    local f = assert(io.open(other, "w")); f:write("other content\n"); f:close()

    local fm = require("galley")
    fm.open()
    assert(
      require("galley.canvas").is_canvas_buf(vim.api.nvim_get_current_buf()),
      "canvas should be showing after open()"
    )

    -- Navigate the same window away from the canvas without calling close().
    vim.cmd.edit(other)
    local edited_buf = vim.api.nvim_get_current_buf()
    H.eq(vim.fs.basename(vim.api.nvim_buf_get_name(edited_buf)), "other.txt")

    fm.close()
    H.eq(vim.api.nvim_get_current_buf(), edited_buf, "close() must not swap away the window's current buffer")
    H.eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), "other.txt")
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
    package.loaded["galley"] = nil
    local fm = require("galley")
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
    vim.fn.delete(root, "rf")
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
  -- nvim_buf_set_lines as well as typed keys, so only galley can corrupt galley's
  -- own buffer. That is itself part of why a user-facing rebuild key is not needed.
  ["e2e: refresh cannot repair a divergent buffer, close+open can"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "a1\na2\na3\na4\na5\na6\na7\na8\n" },
      worktree = { ["a.txt"] = "A1\na2\na3\na4\nA5\na6\na7\na8\n" },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["galley"] = nil
    local fm = require("galley")
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

    vim.fn.delete(root, "rf")
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
    package.loaded["galley"] = nil
    local fm = require("galley")
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
    H.eq(ghosts[1].hl, "GalleyGhost", "in its own group, so it can be dimmed alone")

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
    H.eq(vim.api.nvim_win_get_cursor(0)[1], 3, "on the line the cursor was on")
    H.eq(vim.api.nvim_buf_get_lines(0, 2, 3, false)[1], "THREE",
      "and that line really is the one we pointed at in the canvas")

    vim.api.nvim_feedkeys(vim.keycode("<C-Space>"), "x", false)
    H.eq(vim.api.nvim_get_current_buf(), cbuf, "and the round trip still works")
    fm.close()
    vim.fn.delete(root, "rf")
  end,
  ["e2e: close() before any open() is a safe no-op"] = function()
    -- Force a fresh module instance so its module-level `state` is nil,
    -- regardless of what earlier test cases in this process did.
    package.loaded["galley"] = nil
    local fm = require("galley")

    local buf_before = vim.api.nvim_get_current_buf()
    local ok = pcall(fm.close)
    assert(ok, "close() with no prior open() must not throw")
    H.eq(vim.api.nvim_get_current_buf(), buf_before, "close() must not touch the current buffer when nothing was ever opened")
  end,
}
