local H = require("helpers")
local git = require("galley.git")
local model = require("galley.model")
local canvas = require("galley.canvas")
local jump = require("galley.jump")
local fold = require("galley.fold")
local collect = require("galley.collect")
local lens = require("galley.lens")

local function sh(root, cmd)
  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  return res.stdout
end

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
    local shape_changes = 0
    local shaped_state
    st.hooks = {
      on_shape_change = function(changed_state)
        shape_changes = shape_changes + 1
        shaped_state = changed_state
      end,
    }
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
    H.eq(shape_changes, 1,
      "a successful return reports its one canvas shape change through the owner hook")
    assert(rawequal(shaped_state, st),
      "the shape event identifies the exact canvas state that changed")
  end,
  ["jump: branch rename round-trip survives ref deletion and keeps identity"] = function()
    local old_path = "old-name.txt"
    local new_path = "new-name.txt"
    local original = lines("base line ", 16)
    local root = H.git_fixture({ committed = { [old_path] = original } })
    sh(root, { "git", "branch", "comparison-base", "HEAD" })
    local base_oid = assert(git.resolve_commit(root, "comparison-base"))
    sh(root, { "git", "mv", "--", old_path, new_path })

    local l = lens.branch("comparison-base")
    local sections, collect_err = collect.sections(root, l, 3)
    assert(sections, collect_err)
    H.eq(#sections, 1)
    H.eq({
      sections[1].path,
      sections[1].old_path,
      sections[1].old_rev,
      sections[1].rename_only,
    }, {
      new_path, old_path, base_oid, true,
    }, "sanity: the branch lens starts as one pure-rename header")

    local st = canvas.open(sections, {})
    st.root = root
    st.lens = l
    local before_view = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    jump.enter(st)

    local file_buf = vim.api.nvim_get_current_buf()
    H.eq(vim.api.nvim_buf_get_name(file_buf), vim.fs.joinpath(root, new_path),
      "Enter edits the rename destination, never the historical source")
    vim.api.nvim_buf_set_lines(file_buf, 7, 7, false, { "unsaved through rename" })

    sh(root, { "git", "branch", "-D", "comparison-base" })
    H.eq(git.resolve_commit(root, "comparison-base"), nil,
      "sanity: the symbolic lens ref no longer resolves")

    local ok, back_err = pcall(jump.back)
    assert(ok, "Back must use the captured canonical source: " .. tostring(back_err))
    assert(canvas.is_canvas_buf(vim.api.nvim_get_current_buf()), "Back restores the canvas")

    H.eq(#st.sections, 1)
    local rebuilt = st.sections[1]
    H.eq({
      rebuilt.path,
      rebuilt.old_path,
      rebuilt.old_rev,
      rebuilt.status,
      rebuilt.staged,
      rebuilt.unstaged,
      rebuilt.renamed,
      rebuilt.rename_only,
    }, {
      new_path,
      old_path,
      base_oid,
      "R",
      "R",
      nil,
      true,
      nil,
    }, "the rebuilt section retains destination and captured rename metadata")
    H.eq(rebuilt.old_text, original,
      "old bytes came from canonical-oid:old-path after the branch was deleted")
    assert(rebuilt.new_text:find("unsaved through rename", 1, true),
      "the destination's unsaved buffer bytes become the new side")

    local rendered = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
    assert(rendered[1]:find("old%-name%.txt → new%-name%.txt"),
      "the rename header survives the round trip: " .. tostring(rendered[1]))
    local saw_edit = false
    for _, line in ipairs(rendered) do
      if line == "+unsaved through rename" then saw_edit = true end
    end
    assert(saw_edit, "the unsaved destination edit is visible in the canvas")

    local after_view = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    H.eq(after_view.topline, before_view.topline, "the rename header keeps its viewport")
    H.eq(after_view.lnum, before_view.lnum, "and restores the cursor to that header")

    vim.api.nvim_buf_delete(file_buf, { force = true })
    vim.fn.delete(root, "rf")
  end,
  ["jump: failed destination or source lookup keeps the excursion retryable"] = function()
    local root, st = open_fixture({
      committed = { ["a.txt"] = "old\n" },
      worktree = { ["a.txt"] = "new\n" },
    })
    local section = st.sections[1]
    section.old_rev = "recoverable-base"
    local shape_changes = 0
    st.hooks = {
      on_shape_change = function()
        shape_changes = shape_changes + 1
      end,
    }
    vim.api.nvim_win_set_cursor(st.win, { 1, 0 })
    jump.enter(st)
    local file_buf = vim.api.nvim_get_current_buf()

    local messages = {}
    local real_notify = vim.notify
    vim.notify = function(message) messages[#messages + 1] = message end

    -- Simulate a hidden-canvas refresh removing the destination identity while
    -- the real file is open. The first Back must decline before consuming.
    canvas.render_all(st, {})
    local section_ok, section_err = pcall(jump.back)
    assert(section_ok, "a missing destination must report, not throw: " .. tostring(section_err))
    H.eq(vim.api.nvim_get_current_buf(), file_buf,
      "a failed destination lookup leaves the file on screen")
    assert(#messages == 1 and messages[1]:find("not found in canvas", 1, true),
      "the missing destination identity is explicit: " .. vim.inspect(messages))
    H.eq(shape_changes, 0,
      "a declined return cannot publish a shape change")

    canvas.render_all(st, { section })
    messages = {}
    local source_ok, source_err = pcall(jump.back)
    vim.notify = real_notify

    assert(source_ok, "a missing captured source must report, not throw: " .. tostring(source_err))
    H.eq(vim.api.nvim_get_current_buf(), file_buf,
      "a failed source lookup also leaves the destination file on screen")
    assert(#messages == 1 and messages[1]:find("cannot rebuild excursion old side", 1, true),
      "the source lookup failure is explicit: " .. vim.inspect(messages))
    H.eq(shape_changes, 0,
      "a failed source preflight cannot publish a shape change")

    sh(root, { "git", "branch", "recoverable-base", "HEAD" })
    assert(pcall(jump.back), "the same excursion remains retryable after its source appears")
    assert(canvas.is_canvas_buf(vim.api.nvim_get_current_buf()),
      "the successful retry restores the canvas")
    H.eq(shape_changes, 1,
      "the eventual successful retry publishes exactly one shape change")
    H.eq(st.sections[1].old_rev, "recoverable-base",
      "the retry still uses the source captured on Enter")

    vim.api.nvim_buf_delete(file_buf, { force = true })
    vim.fn.delete(root, "rf")
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
    local lease = assert(sidebar.open(st, { width = 30 }))

    vim.api.nvim_win_set_cursor(st.win, { 4, 0 })
    jump.enter(st)

    local gone = st.win
    vim.api.nvim_win_close(gone, true)
    -- Focus the sidebar: winfixbuf, so setting its buffer would throw.
    local side_win
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if sidebar.is_sidebar_win(lease, w) then side_win = w end
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
    sidebar.close(lease)
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
