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
    vim.api.nvim_feedkeys(vim.keycode("<M-CR>"), "x", false)
    local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local found = false
    for _, l in ipairs(after) do if l == "+return 99" then found = true end end
    assert(found, "canvas must show the edited content")
  end,
  ["e2e: double-click on a collapsed placeholder expands instead of jumping"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "a1\na2\na3\n" },
      worktree = { ["a.txt"] = "A1\na2\na3\n" },
    })
    vim.api.nvim_set_current_dir(root)
    package.loaded["galley"] = nil
    local fm = require("galley")
    fm.open()

    local canvas_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(lines[1]:match("^▸ a%.txt"), "sanity: a.txt collapsed to its placeholder: " .. lines[1])

    local dblclick
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(canvas_buf, "n")) do
      if m.lhs == "<2-LeftMouse>" then
        dblclick = m.callback
      end
    end
    assert(dblclick, "sanity: <2-LeftMouse> mapping exists on the canvas buffer")

    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on the collapsed placeholder row
    dblclick()

    local lines2 = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(not lines2[1]:match("^▸"),
      "double-click on the placeholder must expand it instead of jumping: " .. lines2[1])
    H.eq(vim.api.nvim_get_current_buf(), canvas_buf, "double-click must not jump out of the canvas")

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
