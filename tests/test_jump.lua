local H = require("helpers")
local git = require("galley.git")
local model = require("galley.model")
local canvas = require("galley.canvas")
local jump = require("galley.jump")
local fold = require("galley.fold")

local function open_fixture(spec)
  local root = H.git_fixture(spec)
  local files = {}
  for _, f in ipairs(git.changed_files(root)) do
    files[#files + 1] = {
      path = f.path, status = f.status,
      old_text = git.show_head(root, f.path) or "",
      new_text = table.concat(vim.fn.readfile(vim.fs.joinpath(root, f.path)), "\n") .. "\n",
    }
  end
  local st = canvas.open(model.build(files), {})
  st.root = root
  return root, st
end

local function setup_repo()
  return open_fixture({
    committed = { ["a.txt"] = "a1\na2\na3\na4\na5\n", ["b.txt"] = "b1\nb2\n" },
    worktree = { ["a.txt"] = "a1\nA2\na3\na4\na5\n", ["b.txt"] = "b1\nB2\n" },
  })
end

--- N lines, `prefix1..prefixN`, newline-terminated.
local function lines(prefix, n)
  local out = {}
  for i = 1, n do
    out[i] = prefix .. i
  end
  return table.concat(out, "\n") .. "\n"
end

return {
  ["jump: enter lands on the corresponding file line"] = function()
    local root, st = setup_repo()
    -- put cursor on the "+A2" line of a.txt (find it)
    local rows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local target
    for i, l in ipairs(rows) do if l == "+A2" then target = i end end
    assert(target, "canvas should contain +A2")
    vim.api.nvim_win_set_cursor(st.win, { target, 0 })
    jump.enter(st)
    H.eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), "a.txt")
    H.eq(vim.api.nvim_win_get_cursor(st.win)[1], 2) -- A2 is line 2
  end,
  ["jump: back after edit regenerates section and restores position"] = function()
    local root, st = setup_repo()
    local rows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local target
    for i, l in ipairs(rows) do if l == "+A2" then target = i end end
    vim.api.nvim_win_set_cursor(st.win, { target, 0 })
    jump.enter(st)
    -- edit the real buffer: add a line after A2 (unsaved)
    vim.api.nvim_buf_set_lines(0, 2, 2, false, { "A2b inserted" })
    jump.back()
    assert(canvas.is_canvas_buf(vim.api.nvim_get_current_buf()), "should be back on canvas")
    local newrows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local found = false
    for _, l in ipairs(newrows) do if l == "+A2b inserted" then found = true end end
    assert(found, "regenerated diff must show the unsaved edit")
    -- cursor is on/near the +A2 line still
    local cur = vim.api.nvim_win_get_cursor(st.win)[1]
    local a2row
    for i, l in ipairs(newrows) do if l == "+A2" then a2row = i end end
    assert(math.abs(cur - a2row) <= 2, ("cursor %d not near +A2 at %d"):format(cur, a2row))
  end,
  -- A fold applied from the sidebar while the excursion is live reduces the
  -- excursed section to its single placeholder row. Its entries then no longer
  -- map to buffer rows, so resolving a view against them lands the cursor deep
  -- inside the FOLLOWING files. replace_section already gets this right; the
  -- regression was jump.back overwriting its answer with entry arithmetic.
  ["jump: back onto a section folded away mid-excursion lands on its placeholder"] = function()
    local _, st = open_fixture({
      committed = { ["sub/a.txt"] = lines("l", 40), ["z.txt"] = "z1\nz2\n" },
      worktree = { ["sub/a.txt"] = lines("L", 40), ["z.txt"] = "z1\nZ2\n" },
    })
    H.eq(st.sections[1].path, "sub/a.txt")
    -- Deep into sub/a.txt, so a bad resolve is unmistakably far from row 1.
    local deep = 40
    assert(#st.sections[1].entries > deep, "fixture must be taller than the bad offset")
    vim.api.nvim_win_set_cursor(st.win, { deep, 0 })
    jump.enter(st)

    -- Exactly what sidebar.select's dir branch does, with the canvas off screen.
    st.folded["sub/"] = true
    canvas.resync_visibility(st, fold.indices_under(st.sections, "sub/"))

    jump.back()

    local start0, end0 = canvas.section_rows(st, 1)
    H.eq(end0 - start0, 1, "the folded section must render as one placeholder row")
    local view = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    H.eq(view.lnum, start0 + 1, "cursor must land on the placeholder, not inside z.txt")
    H.eq(view.topline, start0 + 1, "topline must land on the placeholder too")
  end,
  -- `:q` in the excursion window leaves the excursion live with its buffer-local
  -- the return key still on the file, pointing at a window that no longer exists. back()
  -- used to reach nvim_win_set_buf(state.win, ...) with no validity check and throw
  -- E5108 -- after it had already cleared `excursion` and deleted its own keymap, so
  -- the edits never made it back and there was no retry.
  ["jump: back after the excursion window is gone uses the current window"] = function()
    local _, st = open_fixture({
      committed = { ["a.txt"] = lines("l", 20), ["b.txt"] = "b1\nb2\n" },
      worktree = { ["a.txt"] = lines("L", 20), ["b.txt"] = "b1\nB2\n" },
    })
    -- A spare window, so closing the canvas window doesn't take the last one.
    vim.cmd("split")
    vim.cmd("enew")
    local spare = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(st.win)

    vim.api.nvim_win_set_cursor(st.win, { 4, 0 })
    jump.enter(st)
    -- An unsaved edit, so we can prove the splice still ran.
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "inserted before the quit" })

    local gone = st.win
    vim.api.nvim_win_close(gone, true) -- the `:q`
    assert(not vim.api.nvim_win_is_valid(gone), "sanity: the window really is gone")

    vim.api.nvim_set_current_win(spare)
    local ok, err = pcall(jump.back)
    assert(ok, "back() must not throw when its window is gone: " .. tostring(err))

    H.eq(vim.api.nvim_win_get_buf(spare), st.buf, "the canvas came back in the window we were in")
    H.eq(st.win, spare, "and the state follows it")
    local found = false
    for _, l in ipairs(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)) do
      if l == "+inserted before the quit" then found = true end
    end
    assert(found, "the edit made before the quit must still be spliced into the canvas")
  end,
  -- Declining must happen BEFORE the excursion is discarded, or the keypress is
  -- unrecoverable: the map deletes itself and a retry only says "no excursion".
  ["jump: back with only the sidebar focusable declines but stays retryable"] = function()
    local _, st = open_fixture({
      committed = { ["a.txt"] = lines("l", 20) },
      worktree = { ["a.txt"] = lines("L", 20) },
    })
    local sidebar = require("galley.sidebar")
    sidebar.close()
    sidebar.open(st, { width = 30 })

    vim.api.nvim_win_set_cursor(st.win, { 4, 0 })
    jump.enter(st)

    local gone = st.win
    vim.api.nvim_win_close(gone, true)
    -- Focus the sidebar: winfixbuf, so setting its buffer would throw.
    local side_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_get_option_value("winfixbuf", { win = w }) then side_win = w end
    end
    assert(side_win, "sanity: the sidebar window is winfixbuf")
    vim.api.nvim_set_current_win(side_win)

    -- Guarded, because a failure here would otherwise leave the winfixbuf sidebar
    -- focused and every later canvas.open would die on E1513.
    local notified = {}
    local ok, err = pcall(function()
      local real = vim.notify
      vim.notify = function(m) notified[#notified + 1] = m end
      local declined = pcall(jump.back)
      vim.notify = real
      assert(declined, "declining must not throw")
      assert(#notified > 0, "and must say why")
      H.eq(vim.api.nvim_win_get_buf(side_win) == st.buf, false,
        "the sidebar keeps its own buffer")

      -- Retryable: a usable window appears, and the same call now works.
      vim.cmd("split")
      vim.cmd("enew")
      local usable = vim.api.nvim_get_current_win()
      assert(pcall(jump.back), "the excursion must have survived the decline")
      H.eq(vim.api.nvim_win_get_buf(usable), st.buf, "second press lands the canvas")
    end)
    sidebar.close()
    if vim.api.nvim_win_is_valid(side_win) then
      pcall(vim.api.nvim_win_close, side_win, true)
    end
    -- Never hand the next test a winfixbuf window to open the canvas into.
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if not vim.api.nvim_get_option_value("winfixbuf", { win = w }) then
        vim.api.nvim_set_current_win(w)
        break
      end
    end
    assert(ok, err)
  end,
  ["jump: back with all changes reverted deletes section"] = function()
    local root, st = setup_repo()
    vim.api.nvim_win_set_cursor(st.win, { 4, 0 }) -- somewhere in a.txt section
    jump.enter(st)
    -- revert buffer content to HEAD content
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a1", "a2", "a3", "a4", "a5" })
    jump.back()
    H.eq(#st.sections, 1)
    H.eq(st.sections[1].path, "b.txt")
  end,
}
