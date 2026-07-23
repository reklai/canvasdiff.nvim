local H = require("helpers")
local model = require("finding_myself.model")
local canvas = require("finding_myself.canvas")
local collect = require("finding_myself.collect")
local watch = require("finding_myself.watch")

local T = {}

local function write_file(root, rel, content)
  local abs = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(vim.fs.dirname(abs), "p")
  local f = assert(io.open(abs, "w"))
  f:write(content)
  f:close()
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

T["watch_collect files matches init behavior"] = function()
  local root = fixture()
  local files = collect.files(root)
  H.eq(#files, 2)
  table.sort(files, function(x, y) return x.path < y.path end)
  H.eq(files[1].path, "b.txt")
  H.eq(files[1].status, "M")
  assert(files[1].old_text:find("b line 40", 1, true))
  assert(files[1].new_text:find("b line 40 changed", 1, true))
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
end

T["watch_reconcile deletes a reverted file's section"] = function()
  local root = fixture()
  local st = open_state(root)
  write_file(root, "b.txt", bigtext(80, "b")) -- back to HEAD content
  watch.reconcile(st)
  H.eq(#st.sections, 1)
  H.eq(st.sections[1].path, "d.txt")
end

T["watch_reconcile handles N to 0 and 0 to N via render_all"] = function()
  local root = fixture()
  local st = open_state(root)
  local empty_fired = false
  watch.on_empty = function() empty_fired = true end

  write_file(root, "b.txt", bigtext(80, "b"))
  write_file(root, "d.txt", bigtext(80, "d"))
  watch.reconcile(st)
  H.eq(#st.sections, 0)
  H.eq(empty_fired, true, "on_empty fired")

  write_file(root, "d.txt", (bigtext(80, "d"):gsub("d line 1\n", "d line 1 back\n")))
  watch.reconcile(st)
  H.eq(#st.sections, 1)
  H.eq(st.sections[1].path, "d.txt")
  watch.on_empty = nil
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

return T
