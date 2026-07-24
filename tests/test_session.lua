local H = require("helpers")
local canvas = require("finding_myself.canvas")
local model = require("finding_myself.model")
local virt = require("finding_myself.virt")
local session = require("finding_myself.session")

local T = {}

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

-- ~55 rows per section (6 separated hunks): same idiom as test_virt.lua/
-- test_collapse.lua's big_section, tall enough that scroll-targeting
-- assertions can't clamp to the wrong section against the ~22-row headless
-- window.
local function big_section(path, tag)
  local old = bigtext(60, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 10, 60, 10 do
    lines[i] = lines[i] .. " changed"
  end
  return model.build_section(path, old, table.concat(lines, "\n"), "M")
end

-- Cleans up whatever state file a test wrote, so the real stdpath("state")
-- directory doesn't accumulate fixture debris across runs.
local function cleanup(root)
  os.remove(session.path_for(root))
end

T["session_ save and load round-trip the payload"] = function()
  local root = H.tmpdir()
  virt.detach() -- reset module-level auto-set/tick bookkeeping across tests

  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
  }, {})
  st.root = root
  st.base = "HEAD"

  canvas.set_collapsed(st, 1, true) -- user-collapsed

  local target_start = (canvas.section_rows(st, 3))
  local raw_row0 = target_start + 4
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = raw_row0 + 1, lnum = raw_row0 + 3 })
  end)

  session.save(st)
  local data = session.load(root)

  H.eq(data.version, 1)
  H.eq(data.base, "HEAD")
  H.eq(data.collapsed, { "a/one.txt" })
  H.eq(data.view.path, "c/three.txt")
  H.eq(type(data.view.new_lnum), "number")
  assert(data.view.new_lnum ~= raw_row0,
    "view.new_lnum must be the file's own line number, never the raw canvas buffer row")
  H.eq(data.cursor.path, "c/three.txt")
  H.eq(type(data.folds), "table")

  cleanup(root)
end

T["session_ restore reapplies collapse and view semantically"] = function()
  local root = H.tmpdir()
  virt.detach()

  local function three_sections()
    return {
      big_section("a/one.txt", "a"),
      big_section("b/two.txt", "b"),
      big_section("c/three.txt", "c"),
    }
  end

  local st1 = canvas.open(three_sections(), {})
  st1.root = root
  st1.base = "HEAD"

  canvas.set_collapsed(st1, 1, true)
  local b_start = (canvas.section_rows(st1, 2))
  vim.api.nvim_win_call(st1.win, function()
    vim.fn.winrestview({ topline = b_start + 4, lnum = b_start + 6 })
  end)
  local pre_save_top_content = vim.api.nvim_win_call(st1.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)

  session.save(st1)
  local data = session.load(root)

  -- Simulate a fresh reopen of the SAME sections in a new canvas state.
  local st2 = canvas.open(three_sections(), {})
  st2.root = root
  st2.base = "HEAD"

  session.restore(st2, data)

  local s1, e1 = canvas.section_rows(st2, 1)
  H.eq(e1 - s1, 1, "section 1 restored collapsed")

  local top_content = vim.api.nvim_win_call(st2.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)
  H.eq(top_content, pre_save_top_content, "topline content matches the pre-save view semantically")

  cleanup(root)
end

T["session_ restore survives a changed diff"] = function()
  local root = H.tmpdir()
  virt.detach()

  local old = bigtext(60, "z")
  local function new_text(prefix_count)
    local lines = vim.split(old, "\n", { plain = true })
    for i = 10, 60, 10 do
      lines[i] = lines[i] .. " changed"
    end
    local body = table.concat(lines, "\n")
    if prefix_count and prefix_count > 0 then
      local extra = {}
      for i = 1, prefix_count do extra[i] = "extra line " .. i end
      body = table.concat(extra, "\n") .. "\n" .. body
    end
    return body
  end

  local sec_v1 = model.build_section("z.txt", old, new_text(0), "M")
  local sec_v2 = model.build_section("z.txt", old, new_text(5), "M")

  local st1 = canvas.open({ sec_v1 }, {})
  st1.root = root
  st1.base = "HEAD"

  local lines1 = vim.api.nvim_buf_get_lines(st1.buf, 0, -1, false)
  local mid_row = math.floor(#lines1 / 2)
  vim.api.nvim_win_call(st1.win, function()
    vim.fn.winrestview({ topline = mid_row, lnum = mid_row })
  end)

  session.save(st1)
  local data = session.load(root)
  assert(data.view and data.view.content, "sanity: captured a view anchor")

  -- Regenerate the section from an edited worktree: the diff has genuinely
  -- shifted (extra lines inserted before the anchor), simulating the file
  -- having changed further while the canvas was closed.
  local st2 = canvas.open({ sec_v2 }, {})
  st2.root = root
  st2.base = "HEAD"

  local ok, err = pcall(session.restore, st2, data)
  assert(ok, "restore must not error on a changed diff: " .. tostring(err))

  local lines2 = vim.api.nvim_buf_get_lines(st2.buf, 0, -1, false)
  local anchor_row2
  for i, l in ipairs(lines2) do
    if l:sub(2) == data.view.content then
      anchor_row2 = i
      break
    end
  end
  assert(anchor_row2, "anchor content should still exist in the changed diff")

  local top2 = vim.api.nvim_win_call(st2.win, function() return vim.fn.line("w0") end)
  assert(math.abs(top2 - anchor_row2) <= 3,
    ("topline %d not within 3 rows of the anchor content's new location %d"):format(top2, anchor_row2))

  cleanup(root)
end

T["session_ auto-collapsed sections are not persisted"] = function()
  local root = H.tmpdir()
  virt.detach()

  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
  }, {})
  st.root = root
  st.base = "HEAD"

  canvas.set_collapsed(st, 1, true) -- user-collapsed
  -- Neovim remembers the last view for a given win+buf pair across
  -- canvas.open() calls (same pitfall test_sidebar.lua's open_with_sidebar
  -- callers work around) -- pin the view explicitly so the in/out-of-window
  -- classification below is deterministic regardless of test order.
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  virt.apply(st, { enabled = true, max_files = 1, max_lines = 0, margin = 0, max_expanded = 0 })

  assert(next(virt.auto_set()) ~= nil, "sanity: virt auto-collapsed something")
  H.eq(virt.auto_set()["a/one.txt"], nil, "sanity: the user-collapsed path is never claimed by the auto-set")

  session.save(st)
  local data = session.load(root)
  H.eq(data.collapsed, { "a/one.txt" }, "only the user-collapsed path is persisted")

  virt.detach()
  cleanup(root)
end

T["session_ init round trip"] = function()
  local orig_cwd = vim.fn.getcwd()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a1\na2\na3\n", ["b.txt"] = "b1\nb2\nb3\n" },
    worktree = { ["a.txt"] = "A1\na2\na3\n", ["b.txt"] = "b1\nB2\nb3\n" },
  })

  local ok, err = pcall(function()
    vim.cmd("tabnew") -- isolate from whatever windows earlier tests left behind
    vim.api.nvim_set_current_dir(root)
    package.loaded["finding_myself"] = nil
    local fm = require("finding_myself")
    fm.open()

    -- alphabetical order: a.txt's file_hdr is row 1; collapse it the same
    -- way the <Tab> keymap would.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(lines[1]:match("^▸ a%.txt"), "a.txt collapsed to its placeholder: " .. lines[1])

    fm.close()
    fm.open()

    local lines2 = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(lines2[1]:match("^▸ a%.txt"), "a.txt still collapsed after reopen: " .. lines2[1])

    fm.close()
  end)

  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(orig_cwd)
  cleanup(root)
  assert(ok, err)
end

return T
