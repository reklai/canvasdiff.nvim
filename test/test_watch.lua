local H = require("helpers")
local model = require("canvasdiff.diff")
local canvas = require("canvasdiff.canvas")
local collect = require("canvasdiff.collect")
local watch = require("canvasdiff.watch")
local system = require("canvasdiff.os")
local lens = model.lens

local T = {}

local function write_file(root, rel, content)
  local abs = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(vim.fs.dirname(abs), "p")
  local f = assert(io.open(abs, "w"))
  f:write(content)
  f:close()
end

local function sh(root, cmd)
  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  return res.stdout
end

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

--- Repo with three committed files; b.txt and d.txt modified in worktree.
local function fixture()
  local committed = {
    ["b.txt"] = bigtext(80, "b"),
    ["d.txt"] = bigtext(80, "d"),
    ["f.txt"] = bigtext(80, "f"),
  }
  local root = H.git_fixture({
    committed = committed,
    worktree = {
      ["b.txt"] = bigtext(80, "b"):gsub("b line 40", "b line 40 changed"),
      ["d.txt"] = bigtext(80, "d"):gsub("d line 40", "d line 40 changed"),
    },
  })
  return root
end

local function open_state(root)
  local sections = model.build(collect.files(root), 3)
  local st = canvas.open(sections, {})
  st.root = root
  return st
end

T["watch_collect files matches App behavior"] = function()
  local root = fixture()
  local files = collect.files(root)
  H.eq(#files, 2)
  table.sort(files, function(x, y) return x.path < y.path end)
  H.eq(files[1].path, "b.txt")
  H.eq(files[1].status, "M")
  assert(files[1].old_text:find("b line 40", 1, true))
  assert(files[1].new_text:find("b line 40 changed", 1, true))
end

T["watch_reconcile deleted branch ref retains everything and recovers"] = function()
  local root = H.git_fixture({ committed = { ["a.txt"] = bigtext(50, "old") } })
  sh(root, { "git", "branch", "comparison-base", "HEAD" })
  local base_oid = vim.trim(sh(root, { "git", "rev-parse", "comparison-base" }))
  write_file(root, "a.txt", bigtext(50, "new"))
  sh(root, { "git", "add", "-A" })
  sh(root, { "git", "commit", "-m", "advance past comparison base" })

  local l = lens.branch("comparison-base")
  local sections, build_err = collect.sections(root, l, 3)
  assert(sections, build_err)
  local st = canvas.open(sections, {})
  st.root, st.lens, st.base = root, l, nil
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 3, lnum = 5 })
  end)
  st.collapsed["sentinel"] = "user"
  st.folded["sentinel/"] = true
  st.folded_seen["sentinel"] = { lens = l.id, fp = "unchanged" }

  local before = {
    sections = vim.deepcopy(st.sections),
    lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false),
    tick = vim.api.nvim_buf_get_changedtick(st.buf),
    anchors = vim.deepcopy(st.anchor_ids),
    anchor_marks = vim.api.nvim_buf_get_extmarks(
      st.buf, vim.api.nvim_get_namespaces()["canvasdiff.canvas.anchors"],
      0, -1, { details = true }),
    hl_ids = vim.deepcopy(st.hl_ids),
    view = vim.api.nvim_win_call(st.win, vim.fn.winsaveview),
    collapsed = vim.deepcopy(st.collapsed),
    folded = vim.deepcopy(st.folded),
    folded_seen = vim.deepcopy(st.folded_seen),
    lens = vim.deepcopy(st.lens),
    base = st.base,
  }

  sh(root, { "git", "branch", "-D", "comparison-base" })
  local reported
  local ok, err = watch.reconcile(st, {
    on_error = function(value)
      reported = value
    end,
  })
  H.eq(ok, nil)
  assert(type(err) == "string" and err:find("does not resolve", 1, true),
    "a deleted ref is an error, not an empty desired canvas: " .. tostring(err))
  H.eq(reported, err, "direct reconciliation reports failures only through its explicit callback")
  H.eq(st.sections, before.sections)
  H.eq(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), before.lines)
  H.eq(vim.api.nvim_buf_get_changedtick(st.buf), before.tick,
    "no canvas write happened on failed preflight")
  H.eq(st.anchor_ids, before.anchors)
  H.eq(vim.api.nvim_buf_get_extmarks(
    st.buf, vim.api.nvim_get_namespaces()["canvasdiff.canvas.anchors"],
    0, -1, { details = true }), before.anchor_marks)
  H.eq(st.hl_ids, before.hl_ids)
  H.eq(vim.api.nvim_win_call(st.win, vim.fn.winsaveview), before.view)
  H.eq(st.collapsed, before.collapsed)
  H.eq(st.folded, before.folded)
  H.eq(st.folded_seen, before.folded_seen)
  H.eq(st.lens, before.lens)
  H.eq(st.base, before.base)

  -- Recreating the symbolic ref makes the same state usable again; then a
  -- worktree edit proves this is a real reconcile rather than a truthy no-op.
  sh(root, { "git", "branch", "comparison-base", base_oid })
  local newest = bigtext(50, "new"):gsub("new line 20", "new line 20 recovered")
  write_file(root, "a.txt", newest)
  local recovered, recover_err = watch.reconcile(st)
  H.eq(recovered, true, recover_err)
  assert(st.sections[1].new_text:find("new line 20 recovered", 1, true),
    "the retained canvas reconciles normally after the ref returns")

  vim.fn.delete(root, "rf")
end

T["watch_trigger deduplicates identical ref errors and resets after recovery"] = function()
  local root = H.git_fixture({ committed = { ["a.txt"] = "old\n" } })
  sh(root, { "git", "branch", "comparison-base", "HEAD" })
  local base_oid = vim.trim(sh(root, { "git", "rev-parse", "comparison-base" }))
  write_file(root, "a.txt", "new\n")
  sh(root, { "git", "add", "-A" })
  sh(root, { "git", "commit", "-m", "advance" })

  local l = lens.branch("comparison-base")
  local sections, build_err = collect.sections(root, l, 3)
  assert(sections, build_err)
  local st = canvas.open(sections, {})
  st.root, st.lens, st.base = root, l, nil

  local errors = {}
  local lease = watch.start(st, { debounce_ms = 10 }, {
    on_error = function(err) errors[#errors + 1] = err end,
  })
  sh(root, { "git", "branch", "-D", "comparison-base" })

  vim.api.nvim_exec_autocmds("FocusGained", {})
  assert(vim.wait(1000, function() return #errors == 1 end, 10),
    "the scheduled failure reached the error seam")
  vim.api.nvim_exec_autocmds("FocusGained", {})
  vim.wait(100, function() return false end, 10)
  H.eq(#errors, 1, "an identical consecutive failure is reported only once")

  sh(root, { "git", "branch", "comparison-base", base_oid })
  write_file(root, "a.txt", "recovered\n")
  vim.api.nvim_exec_autocmds("FocusGained", {})
  assert(vim.wait(1000, function()
    return st.sections[1] and st.sections[1].new_text == "recovered\n"
  end, 10), "a successful scheduled pass clears the error state and reconciles")

  sh(root, { "git", "branch", "-D", "comparison-base" })
  vim.api.nvim_exec_autocmds("FocusGained", {})
  assert(vim.wait(1000, function() return #errors == 2 end, 10),
    "after a success, the same later error is reportable again")

  H.eq(watch.stop(lease), true)
  H.eq(watch.stop(lease), false, "stopping an already-disposed lease is a no-op")
  vim.fn.delete(root, "rf")
end

T["watch_reconcile replaces a modified section in place"] = function()
  local root = fixture()
  local st = open_state(root)
  H.eq(#st.sections, 2)

  write_file(root, "b.txt", (bigtext(80, "b"):gsub("b line 20", "b line 20 EDITED")))
  watch.reconcile(st)

  H.eq(#st.sections, 2)
  H.eq(st.sections[1].path, "b.txt")
  assert(st.sections[1].new_text:find("b line 20 EDITED", 1, true), "section regenerated")
  -- buffer content actually spliced
  local srow, erow = canvas.section_rows(st, 1)
  local lines = table.concat(vim.api.nvim_buf_get_lines(st.buf, srow, erow, false), "\n")
  assert(lines:find("b line 20 EDITED", 1, true), "canvas shows the new diff")
end

T["watch_reconcile inserts a new file alphabetically"] = function()
  local root = fixture()
  local st = open_state(root)
  write_file(root, "c.txt", "brand new\n")
  watch.reconcile(st)
  H.eq(#st.sections, 3)
  H.eq({ st.sections[1].path, st.sections[2].path, st.sections[3].path },
    { "b.txt", "c.txt", "d.txt" })
  local prev_end = 0
  for i = 1, 3 do
    local srow, erow = canvas.section_rows(st, i)
    H.eq(srow, prev_end)
    prev_end = erow
  end
  -- inserted section's rendered content is actually spliced into the buffer
  local srow, erow = canvas.section_rows(st, 2)
  local lines = table.concat(vim.api.nvim_buf_get_lines(st.buf, srow, erow, false), "\n")
  assert(lines:find("c.txt", 1, true), "inserted section header present")
  assert(lines:find("brand new", 1, true), "inserted section content present")
end

T["watch_reconcile deletes a reverted file's section"] = function()
  local root = fixture()
  local st = open_state(root)
  write_file(root, "b.txt", bigtext(80, "b")) -- back to HEAD content
  watch.reconcile(st)
  H.eq(#st.sections, 1)
  H.eq(st.sections[1].path, "d.txt")
  -- the deleted section's header line is really gone from the buffer, not
  -- just dropped from state.sections
  local all = table.concat(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), "\n")
  H.eq(all:find("b.txt", 1, true), nil, "no leftover b.txt header line in the buffer")
end

T["watch_reconcile handles N to 0 and 0 to N via render_all"] = function()
  local root = fixture()
  local st = open_state(root)
  local empty_fired = false
  local changed_state, changed_result
  local callbacks = {
    on_empty = function() empty_fired = true end,
    on_change = function(state, result)
      changed_state, changed_result = state, result
    end,
  }

  write_file(root, "b.txt", bigtext(80, "b"))
  write_file(root, "d.txt", bigtext(80, "d"))
  local ok, result = watch.reconcile(st, callbacks)
  H.eq(ok, true)
  H.eq(#st.sections, 0)
  H.eq(empty_fired, true, "on_empty fired")
  H.eq(changed_state, st, "on_change receives the reconciled state")
  H.eq(changed_result, result, "on_change receives the published result")
  H.eq(result.full, true)
  H.eq(result.empty, true)
  H.eq(result.desired, {})

  write_file(root, "d.txt", (bigtext(80, "d"):gsub("d line 1\n", "d line 1 back\n")))
  ok, result = watch.reconcile(st, callbacks)
  H.eq(ok, true)
  H.eq(#st.sections, 1)
  H.eq(st.sections[1].path, "d.txt")
  H.eq(result.full, true)
  H.eq(result.empty, false)
  H.eq(result.desired, st.sections)
end

T["watch_reconcile replaces the only section with a different file cleanly"] = function()
  -- {b} -> {c}: a naive merge-walk would delete the last section (leaving
  -- the placeholder-line empty canvas) and then try to splice into it,
  -- stranding a stray blank line. Must route through render_all instead.
  local root = H.git_fixture({
    committed = { ["b.txt"] = bigtext(40, "b") },
    worktree = { ["b.txt"] = (bigtext(40, "b"):gsub("b line 5", "b line 5 X")) },
  })
  local st = open_state(root)
  H.eq(#st.sections, 1)

  write_file(root, "b.txt", bigtext(40, "b")) -- revert b
  write_file(root, "c.txt", "brand new\n")    -- add untracked c
  watch.reconcile(st)

  H.eq(#st.sections, 1)
  H.eq(st.sections[1].path, "c.txt")
  local srow, erow = canvas.section_rows(st, 1)
  H.eq(srow, 0)
  H.eq(erow, vim.api.nvim_buf_line_count(st.buf), "no stray trailing line")
end

T["watch_reconcile untouched sections keep their anchors and view (niri)"] = function()
  local root = fixture()
  local st = open_state(root)

  -- viewport inside section 2 (d.txt)
  local d_start = (canvas.section_rows(st, 2))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = d_start + 3, lnum = d_start + 3 })
  end)
  local before_top = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)

  -- grow b.txt's diff (above the viewport) by editing more lines
  write_file(root, "b.txt",
    (bigtext(80, "b"):gsub("b line 10", "b line 10 X"):gsub("b line 40", "b line 40 Y")))
  watch.reconcile(st)

  local after_top = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)
  H.eq(after_top, before_top, "visible text pinned through above-viewport splice")
end

T["watch_trigger BufWritePost reconciles after debounce"] = function()
  local root = fixture()
  local st = open_state(root)
  watch.start(st, { debounce_ms = 20 })

  -- edit b.txt through a real buffer + :write, firing BufWritePost
  local abs = vim.fs.joinpath(root, "b.txt")
  vim.cmd.edit(abs)
  vim.api.nvim_buf_set_lines(0, 4, 5, false, { "b line 5 WRITTEN" })
  vim.cmd.write()
  vim.api.nvim_win_set_buf(0, st.buf) -- back to the canvas

  local ok = vim.wait(2000, function()
    return st.sections[1] and st.sections[1].new_text:find("b line 5 WRITTEN", 1, true) ~= nil
  end, 10)
  H.eq(ok, true, "debounced reconcile picked up the written change")
  watch.stop()
end

T["watch_trigger fs_event catches external writes at repo root"] = function()
  local root = fixture()
  local st = open_state(root)
  watch.start(st, { debounce_ms = 20 })

  -- external write: no nvim buffer involved
  write_file(root, "b.txt", (bigtext(80, "b"):gsub("b line 7", "b line 7 EXTERNAL")))

  local ok = vim.wait(4000, function()
    return st.sections[1] and st.sections[1].new_text:find("b line 7 EXTERNAL", 1, true) ~= nil
  end, 10)
  H.eq(ok, true, "fs_event triggered a reconcile")
  watch.stop()
end

T["watch_reconcile composite ops above viewport keep visible text pinned"] = function()
  -- delete + replace above the viewport in ONE reconcile pass; the
  -- viewport (pinned inside the LAST section) must not move at all.
  local root = H.git_fixture({
    committed = { ["a.txt"] = bigtext(60, "a"), ["d.txt"] = bigtext(60, "d"), ["z.txt"] = bigtext(60, "z") },
    worktree = {
      ["a.txt"] = (bigtext(60, "a"):gsub("a line 30", "a line 30 X")),
      ["d.txt"] = (bigtext(60, "d"):gsub("d line 30", "d line 30 X")),
      ["z.txt"] = (bigtext(60, "z"):gsub("z line 30", "z line 30 X")),
    },
  })
  local st = open_state(root)
  H.eq(#st.sections, 3)
  local z_start = (canvas.section_rows(st, 3))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = z_start + 3, lnum = z_start + 3 })
  end)
  local before_top = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)

  write_file(root, "a.txt", bigtext(60, "a")) -- revert -> delete section
  write_file(root, "d.txt", (bigtext(60, "d"):gsub("d line 10", "d line 10 GROWN"):gsub("d line 50", "d line 50 GROWN"))) -- replace section
  watch.reconcile(st)

  H.eq(#st.sections, 2)
  local after_top = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)
  H.eq(after_top, before_top, "visible text pinned through composite reconcile")
end

T["watch_reconcile while hidden then jump.back stays coherent"] = function()
  -- reconcile against a HIDDEN canvas (window showing another buffer), then
  -- re-show: content must be the reconciled version, rows contiguous.
  local root = fixture()
  local st = open_state(root)
  -- hide the canvas: show a scratch buffer in its window
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(st.win, scratch)

  write_file(root, "b.txt", (bigtext(80, "b"):gsub("b line 15", "b line 15 HIDDEN")))
  watch.reconcile(st)

  vim.api.nvim_win_set_buf(st.win, st.buf)
  H.eq(#st.sections, 2)
  local srow, erow = canvas.section_rows(st, 1)
  local text = table.concat(vim.api.nvim_buf_get_lines(st.buf, srow, erow, false), "\n")
  assert(text:find("b line 15 HIDDEN", 1, true), "hidden reconcile spliced the canvas")
  local prev_end = 0
  for i = 1, 2 do
    local s, e = canvas.section_rows(st, i)
    H.eq(s, prev_end)
    prev_end = e
  end
end

-- state.collapsed is pruned when a section leaves the canvas; state.folded was
-- not, so a fold outlived the directory it described. Commit (or revert)
-- everything under src/ and the key survived -- invisibly, since the sidebar
-- only draws a dir row for a directory that still has sections -- and the next
-- edit to any file under src/ came back as a placeholder that ]f steps over.
T["watch_reconcile a fold dies with the last change under it"] = function()
  local root = H.git_fixture({
    committed = {
      ["src/a.txt"] = bigtext(80, "a"),
      ["src/b.txt"] = bigtext(80, "b"),
      ["top.txt"] = bigtext(80, "t"),
    },
    worktree = {
      ["src/a.txt"] = bigtext(80, "a"):gsub("a line 40", "a line 40 changed"),
      ["src/b.txt"] = bigtext(80, "b"):gsub("b line 40", "b line 40 changed"),
      ["top.txt"] = bigtext(80, "t"):gsub("t line 40", "t line 40 changed"),
    },
  })
  local st = open_state(root)
  H.eq(#st.sections, 3, "sanity: src/a.txt, src/b.txt, top.txt")

  st.folded = { ["src/"] = true }
  canvas.resync_visibility(st)
  local s, e = canvas.section_rows(st, 1)
  H.eq(e - s, 1, "sanity: the fold took effect")

  -- Revert both src/ files, the way committing them would: their sections go
  -- away through the incremental merge-walk, not a full render_all.
  write_file(root, "src/a.txt", bigtext(80, "a"))
  write_file(root, "src/b.txt", bigtext(80, "b"))
  watch.reconcile(st)
  H.eq(#st.sections, 1, "sanity: only top.txt is left")
  H.eq(st.folded, {}, "the fold went with the changes it described")

  -- And a brand-new change under src/ arrives readable, not folded.
  write_file(root, "src/a.txt", bigtext(80, "a"):gsub("a line 7", "a line 7 changed"))
  watch.reconcile(st)
  H.eq(#st.sections, 2, "sanity: src/a.txt is back")
  H.eq(st.sections[1].path, "src/a.txt")
  local s2, e2 = canvas.section_rows(st, 1)
  assert(e2 - s2 > 1, "the file you just changed must be readable, not a placeholder")
end

-- The fold pruning is deliberately ONE pass at the end of the merge-walk, not
-- per-delete inside it. This is the case that pins that down: a reconcile where
-- every old section under src/ goes away AND a new one arrives. Pruning as the
-- last old section was deleted would drop the key mid-walk and un-fold the file
-- inserted a step later -- so the directory the user is looking at as `▸ src/`
-- would suddenly show an expanded file under it.
T["watch_reconcile a fold survives a pass that replaces its whole subtree"] = function()
  local root = H.git_fixture({
    committed = {
      ["src/a.txt"] = bigtext(80, "a"),
      ["top.txt"] = bigtext(80, "t"),
    },
    worktree = {
      ["src/a.txt"] = bigtext(80, "a"):gsub("a line 40", "a line 40 changed"),
      ["top.txt"] = bigtext(80, "t"):gsub("t line 40", "t line 40 changed"),
    },
  })
  local st = open_state(root)
  st.folded = { ["src/"] = true }
  canvas.resync_visibility(st)

  -- Revert the only old src/ file and introduce a different one, so a single
  -- reconcile both empties and refills the folded directory.
  write_file(root, "src/a.txt", bigtext(80, "a"))
  write_file(root, "src/b.txt", bigtext(80, "b"))
  watch.reconcile(st)

  H.eq(st.folded, { ["src/"] = true }, "src/ still has a change, so the fold stands")
  H.eq(st.sections[1].path, "src/b.txt")
  local s, e = canvas.section_rows(st, 1)
  H.eq(e - s, 1, "and the file that replaced it obeys the fold that is still on screen")
end

--- `bigtext(80, tag)` with every 10th line changed: 7 separated hunks, ~57 canvas
--- rows. Two of these make the buffer far taller than the ~22-row headless window,
--- which is what lets a section partway down actually BE the topline.
local function many_hunks(tag)
  local lines = vim.split(bigtext(80, tag), "\n", { plain = true })
  for i = 10, 70, 10 do
    lines[i] = lines[i] .. " changed"
  end
  return table.concat(lines, "\n")
end

-- A folded section re-spliced in place moves no rows -- a placeholder is
-- replaced by a placeholder -- so nothing about the view needs correcting. The
-- `collapsed_topline` branch corrected it anyway, forcing lnum to the section's
-- start row, which stole the cursor whenever the placeholder happened to be the
-- top visible row. Reachable from any background write: `:w` in another split, a
-- formatter, FocusGained.
--
-- Two things make this discriminating where the existing jump.back test is not:
-- the placeholder is NOT section one (so start_row + 1 can't be confused with a
-- clamp to 1), and the cursor sits well below the topline (so "forces lnum" can't
-- be confused with "forces topline"). Nothing else in the suite sets
-- lnum ~= topline before a replace_section, which is why this went unnoticed.
T["watch_reconcile a background edit to a placeholder leaves the cursor alone"] = function()
  local root = H.git_fixture({
    committed = {
      ["aaa.txt"] = bigtext(80, "a"),
      ["src/a.txt"] = bigtext(80, "s"),
      ["zzz.txt"] = bigtext(80, "z"),
    },
    worktree = {
      ["aaa.txt"] = many_hunks("a"),
      ["src/a.txt"] = many_hunks("s"),
      ["zzz.txt"] = many_hunks("z"),
    },
  })
  local st = open_state(root)
  H.eq(st.sections[2].path, "src/a.txt", "sanity: the middle section is the folded one")

  st.folded = { ["src/"] = true }
  canvas.resync_visibility(st)
  local start_row, end_row = canvas.section_rows(st, 2)
  H.eq(end_row - start_row, 1, "sanity: src/a.txt is a one-row placeholder")
  assert(start_row > 0, "sanity: it is not section one, so start_row + 1 ~= 1")

  -- Viewport top exactly on the placeholder, cursor five rows below it (inside
  -- zzz.txt) -- the only geometry in which the branch fires.
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = start_row + 1, lnum = start_row + 6 })
  end)
  local before = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
  H.eq(before.topline, start_row + 1, "sanity: the placeholder really is the top row")
  H.eq(before.lnum, start_row + 6, "sanity: the cursor really is below it")

  -- A background write to the folded-away file.
  write_file(root, "src/a.txt", many_hunks("s"):gsub("s line 25", "s line 25 also"))
  watch.reconcile(st)

  local after = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
  H.eq(after.lnum, before.lnum, "a background edit must not move the cursor")
  H.eq(after.topline, before.topline, "nor the viewport")
  local s2, e2 = canvas.section_rows(st, 2)
  H.eq(e2 - s2, 1, "and the section is still its placeholder")
end

T["watch_start stops itself when the canvas buffer is wiped"] = function()
  local root = fixture()
  local st = open_state(root)
  watch.start(st, { debounce_ms = 20 })
  assert(pcall(vim.api.nvim_get_autocmds, { group = "canvasdiff.watch" }),
    "augroup exists while watching")

  vim.api.nvim_buf_delete(st.buf, { force = true })

  local group_gone = not pcall(vim.api.nvim_get_autocmds, { group = "canvasdiff.watch" })
  H.eq(group_gone, true, "BufWipeout stopped the watch (augroup torn down)")
end

T["watch_trigger stop() really stops"] = function()
  local root = fixture()
  local st = open_state(root)
  watch.start(st, { debounce_ms = 20 })
  watch.stop()

  write_file(root, "b.txt", (bigtext(80, "b"):gsub("b line 9", "b line 9 IGNORED")))
  vim.wait(300, function() return false end, 50) -- give any stray timer a chance
  H.eq(st.sections[1].new_text:find("b line 9 IGNORED", 1, true), nil,
    "no reconcile after stop")
end

T["watch_lease stale callbacks and stale stop cannot reach the replacement"] = function()
  local real_new_timer = system.new_timer
  local real_new_fs_event = system.new_fs_event
  local real_schedule_wrap = vim.schedule_wrap
  local timers, events, scheduled = {}, {}, {}
  local roots, states = {}, {}

  local function fake_handle(bucket)
    local handle = {
      started = 0,
      stopped = 0,
      closed = 0,
    }
    function handle:start(_, _, callback)
      self.started = self.started + 1
      self.callback = callback
      return true
    end
    function handle:stop()
      self.stopped = self.stopped + 1
      local callback = self.on_stop
      self.on_stop = nil
      if callback then
        callback()
      end
      return true
    end
    function handle:close()
      self.closed = self.closed + 1
      return true
    end
    function handle:is_closing()
      return self.closed > 0
    end
    bucket[#bucket + 1] = handle
    return handle
  end

  system.new_timer = function()
    return fake_handle(timers)
  end
  system.new_fs_event = function()
    return fake_handle(events)
  end
  vim.schedule_wrap = function(callback)
    return function()
      scheduled[#scheduled + 1] = callback
    end
  end

  local ok, err = xpcall(function()
    roots[1], roots[2] = fixture(), fixture()
    states[1], states[2] = open_state(roots[1]), open_state(roots[2])

    local lease_a = watch.start(states[1], { debounce_ms = 1 }, {
      alive = function() return true end,
    })
    local a_events = vim.list_slice(events)

    -- Cross both asynchronous boundaries while A is current, but hold the
    -- scheduled reconcile until after B replaces it.
    vim.api.nvim_exec_autocmds("FocusGained", {})
    H.eq(#timers, 1, "A owns one debounce timer")
    local timer_a = timers[1]
    timer_a.callback()
    H.eq(#scheduled, 1, "A's main-loop reconcile is queued")

    local b_changes = 0
    local lease_b = watch.start(states[2], { debounce_ms = 1 }, {
      alive = function() return true end,
      on_change = function(state, result)
        H.eq(state, states[2])
        H.eq(result.desired, states[2].sections)
        b_changes = b_changes + 1
      end,
    })

    H.eq(timer_a.stopped, 1, "replacement stops A's timer exactly once")
    H.eq(timer_a.closed, 1, "replacement closes A's timer exactly once")
    for _, handle in ipairs(a_events) do
      H.eq(handle.stopped, 1, "replacement stops every A fs handle")
      H.eq(handle.closed, 1, "replacement closes every A fs handle")
    end

    H.eq(watch.stop(lease_a), false, "a stale owner cannot stop current lease B")
    assert(pcall(vim.api.nvim_get_autocmds, { group = "canvasdiff.watch" }),
      "B's autocmd group survives stop(A)")

    local timers_before_stale_fs = #timers
    a_events[1].callback(nil, "b.txt", {})
    H.eq(#timers, timers_before_stale_fs,
      "a stale fs callback cannot arm B's timer")

    scheduled[1]()
    H.eq(b_changes, 0, "A's queued timer callback cannot reconcile B")

    -- B remains fully functional after both stale attacks.
    vim.api.nvim_exec_autocmds("FocusGained", {})
    H.eq(#timers, 2, "the live B autocmd still arms its own timer")
    local timer_b = timers[2]
    timer_b.callback()
    H.eq(#scheduled, 2)
    scheduled[2]()
    H.eq(b_changes, 1, "B's own queued callback reconciles B")

    H.eq(watch.stop(lease_b), true)
    H.eq(watch.stop(lease_b), false, "stop(B) is idempotent")

    -- Break teardown deliberately: A handle method starts D while C is only
    -- part-way through stop(). C must already have detached its augroup, or D
    -- can reuse C's shared-name group ID and then lose it when C resumes.
    local lease_c = watch.start(states[1], { debounce_ms = 1 }, {
      alive = function() return true end,
    })
    vim.api.nvim_exec_autocmds("FocusGained", {})
    local timer_c = timers[#timers]
    local lease_d
    timer_c.on_stop = function()
      lease_d = watch.start(states[2], { debounce_ms = 1 }, {
        alive = function() return true end,
      })
    end

    H.eq(watch.stop(lease_c), true)
    assert(lease_d, "the injected timer stop started replacement D")
    assert(pcall(vim.api.nvim_get_autocmds, { group = "canvasdiff.watch" }),
      "C's resumed teardown cannot delete reentrant replacement D's group")

    local timers_before_d = #timers
    vim.api.nvim_exec_autocmds("FocusGained", {})
    H.eq(#timers, timers_before_d + 1,
      "replacement D's surviving autocmd can arm its own timer")
    H.eq(watch.stop(lease_d), true)
    H.eq(watch.stop(lease_d), false, "reentrant replacement teardown is idempotent")

    for _, handle in ipairs(timers) do
      H.eq(handle.stopped, 1, "each timer is stopped exactly once")
      H.eq(handle.closed, 1, "each timer is closed exactly once")
    end
    for _, handle in ipairs(events) do
      H.eq(handle.stopped, 1, "each fs handle is stopped exactly once")
      H.eq(handle.closed, 1, "each fs handle is closed exactly once")
    end
  end, debug.traceback)

  watch.stop()
  system.new_timer = real_new_timer
  system.new_fs_event = real_new_fs_event
  vim.schedule_wrap = real_schedule_wrap
  for _, state in ipairs(states) do
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
    end
  end
  for _, root in ipairs(roots) do
    vim.fn.delete(root, "rf")
  end
  assert(ok, err)
end

T["watch_reconcile owner callback faults remain observable"] = function()
  local root = fixture()
  local st = open_state(root)
  local ok, err = pcall(watch.reconcile, st, {
    on_change = function()
      error("injected owner refresh fault")
    end,
  })

  H.eq(ok, false, "a broken owner callback cannot look like a successful refresh")
  assert(tostring(err):find("injected owner refresh fault", 1, true), tostring(err))
  vim.fn.delete(root, "rf")
end

return T
