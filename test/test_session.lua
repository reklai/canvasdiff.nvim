local H = require("helpers")
local canvas = require("galley.canvas")
local model = require("galley.model")
local virt = require("galley.virt")
local session = require("galley.session")
local config = require("galley.config")
local scrollbar = require("galley.scrollbar")
local fold = require("galley.fold")

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

-- A real three-file repo whose sections are each ~65 rows -- taller than the
-- ~22-row headless window, so virt's collapse pass actually has fully
-- out-of-window sections to evict. Paired with VIRT_FORCED below this is the
-- smallest fixture that makes auto-virtualization kick in for real.
local function big_repo()
  local committed, worktree = {}, {}
  for _, tag in ipairs({ "a", "b", "c" }) do
    local old = bigtext(60, tag)
    local lines = vim.split(old, "\n", { plain = true })
    for i = 10, 60, 10 do
      lines[i] = lines[i] .. " changed"
    end
    committed[tag .. ".txt"] = old
    worktree[tag .. ".txt"] = table.concat(lines, "\n")
  end
  return H.git_fixture({ committed = committed, worktree = worktree })
end

-- Thresholds that force virtualization on big_repo(): 3 files > max_files,
-- and only the section under the viewport stays expanded. At open that
-- leaves a.txt rendered (rows 1-65) with b.txt and c.txt as placeholders on
-- rows 66 and 67.
local VIRT_FORCED = { virt = { max_files = 1, max_expanded = 1, margin = 0 } }

-- Run `fn(fm)` against a freshly-required plugin, cwd'd into `root` in its
-- own tab, restoring tab/cwd/config/virt state and deleting the session file
-- afterwards however it exits. fm.setup mutates the process-global
-- config.options (config.lua:50-57), so the config.setup({}) reset is
-- load-bearing -- without it these tiny virt thresholds leak into every
-- later test in the run.
local function in_repo(root, opts, fn)
  local orig_cwd = vim.fn.getcwd()
  local orig_tab = vim.api.nvim_get_current_tabpage()
  local ok, err = pcall(function()
    vim.cmd("tabnew") -- isolate from whatever windows earlier tests left behind
    vim.api.nvim_set_current_dir(root)
    package.loaded["galley"] = nil
    local fm = require("galley")
    fm.setup(opts)
    fn(fm)
  end)
  -- tabonly, not tabclose: a test may open more than one tab (a reopen needs
  -- a window with no remembered view for the canvas buffer -- see below).
  pcall(function()
    if vim.api.nvim_tabpage_is_valid(orig_tab) then
      vim.api.nvim_set_current_tabpage(orig_tab)
    end
    vim.cmd("tabonly!")
  end)
  vim.api.nvim_set_current_dir(orig_cwd)
  config.setup({})
  virt.detach()
  cleanup(root)
  assert(ok, err)
end

-- --- folds ---------------------------------------------------------------

local function open_ab(root)
  virt.detach()
  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("a/two.txt", "b"),
    big_section("b/three.txt", "c"),
  }, {})
  st.root = root
  st.base = "HEAD"
  return st
end

local function span(st, i)
  local s, e = canvas.section_rows(st, i)
  return e - s
end

T["session_folds persist with the sidebar closed"] = function()
  local root = H.tmpdir()
  local st = open_ab(root)
  require("galley.sidebar").close() -- folds are state's, not the sidebar's
  st.folded = { ["a/"] = true }

  session.save(st)
  H.eq(session.load(root).folds, { "a/" },
    "quitting with the sidebar shut must not erase the fold set")
  cleanup(root)
end

T["session_folds restore onto the canvas, not just the tree"] = function()
  local root = H.tmpdir()
  local st = open_ab(root)
  st.folded = { ["a/"] = true }
  session.save(st)

  -- A fresh state, as a reopen produces: nothing folded, nothing collapsed.
  local fresh = open_ab(root)
  H.eq(span(fresh, 1) > 1, true, "starts expanded")
  session.restore(fresh, session.load(root))

  H.eq(fresh.folded, { ["a/"] = true }, "fold set came back")
  H.eq(span(fresh, 1), 1, "and a/one.txt is a placeholder again")
  H.eq(span(fresh, 2), 1, "and so is a/two.txt")
  assert(span(fresh, 3) > 1, "b/three.txt untouched")
  cleanup(root)
end

-- Guard. Passes before and after; exists to fail loudly if folding ever
-- starts writing into state.collapsed. If it did, unfolding after a restore
-- would leave the files collapsed forever with nothing to explain why.
T["session_folds a fold is never persisted as a collapse"] = function()
  local root = H.tmpdir()
  local st = open_ab(root)
  st.folded = { ["a/"] = true }
  canvas.resync_visibility(st)
  H.eq(span(st, 1), 1, "the fold really did take effect")

  session.save(st)
  local data = session.load(root)
  H.eq(data.collapsed, {}, "collapsed records user intent only")
  H.eq(data.folds, { "a/" }, "the fold is recorded as a fold")
  cleanup(root)
end

-- save() refuses to record a VIEW anchored on a section that renders as one
-- row, because a placeholder's entries don't map to buffer rows. The cursor
-- anchor needs the same refusal and didn't have it: cursor_offset is always 1
-- on a one-row section, so the anchor came out as that section's file_hdr
-- (new_lnum = nil, content = the header text) and restore put the cursor on a
-- file header the user was never reading. `]f` deliberately still stops on an
-- auto-collapsed placeholder, so this is a reachable resting place.
T["session_cursor is not recorded when it sits on a placeholder"] = function()
  local root = H.tmpdir()
  local st = open_ab(root)
  canvas.set_collapsed(st, 2, true)

  local ph0 = (canvas.section_rows(st, 2)) -- 0-based placeholder row
  H.eq(span(st, 2), 1, "a/two.txt is a placeholder")
  -- Topline inside the still-expanded section 1, cursor on the placeholder --
  -- the only arrangement where save() reaches the cursor branch at all.
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = ph0 - 9, lnum = ph0 + 1 })
  end)
  local top0 = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") - 1 end)
  H.eq((canvas.locate(st, top0)), 1, "precondition: topline section is expanded")
  H.eq((canvas.locate(st, ph0)), 2, "precondition: cursor is on section 2")

  session.save(st)
  local data = session.load(root)
  H.eq(data.view.path, "a/one.txt", "the view half is still recorded")
  H.eq(data.cursor, nil, "but a cursor on a placeholder resolves to nothing honest")
  cleanup(root)
end

T["session_folds restore skips a view anchored on a folded-away file"] = function()
  local root = H.tmpdir()
  local st = open_ab(root)
  -- Hand-written payload: a saved view pointing into a file that the saved
  -- fold set hides. save() never produces this, but a stale file can.
  session.restore(st, {
    version = 1,
    base = "HEAD",
    collapsed = {},
    folds = { "a/" },
    view = { path = "a/one.txt", new_lnum = 30, content = "a line 30" },
  })
  H.eq(span(st, 1), 1, "the fold applied")
  local top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, 1, "and the unresolvable view was skipped rather than guessed at")
  cleanup(root)
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
  H.eq(data.folded_seen,
    { { path = "a/one.txt", lens = "all", fp = model.fingerprint(st.sections[1]) } },
    "the collapsed file's fingerprint rides along, scoped to the lens that took it")

  cleanup(root)
end

-- Staleness has to outlive the process, because a shut editor is exactly when files
-- change behind your back. The trap is ordering: restoring the collapse re-splices
-- the section, which records a fingerprint of the file AS IT IS NOW -- so if the
-- saved fingerprints don't land afterwards and overwrite that, the change is
-- silently absorbed and nothing is ever reported.
T["session_ a file that changed while shut comes back marked stale"] = function()
  local root = H.tmpdir()
  local st = open_ab(root)
  canvas.set_collapsed(st, 1, true) -- the user sets a/one.txt aside
  local seen_then = st.folded_seen["a/one.txt"]
  assert(seen_then, "sanity: setting it aside recorded a fingerprint")
  session.save(st)

  -- A fresh canvas whose a/one.txt has DIFFERENT content, as if it were edited
  -- while Neovim was closed.
  local edited = big_section("a/one.txt", "a")
  edited.new_text = edited.new_text .. "edited while you were away\n"
  local fresh = canvas.open({
    edited,
    big_section("a/two.txt", "b"),
    big_section("b/three.txt", "c"),
  }, {})
  fresh.root = root
  fresh.base = "HEAD"

  session.restore(fresh, session.load(root))

  H.eq(fresh.folded_seen["a/one.txt"], seen_then,
    "the SAVED fingerprint wins over the one the restore's own resplice recorded")
  H.eq(fold.stale(fresh, "a/one.txt", model.fingerprint(edited), "all"), true,
    "so the file reports as changed since you set it aside")
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

  assert(next(H.auto_set(st)) ~= nil, "sanity: virt auto-collapsed something")
  H.eq(H.auto_set(st)["a/one.txt"], nil, "sanity: the user-collapsed path is never claimed by the auto-set")

  session.save(st)
  local data = session.load(root)
  H.eq(data.collapsed, { "a/one.txt" }, "only the user-collapsed path is persisted")

  virt.detach()
  cleanup(root)
end

T["session_ restored user collapse survives virt's auto-set and persists"] = function()
  local root = H.tmpdir()
  virt.detach()

  local st = canvas.open({
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
  }, {})
  st.root = root
  st.base = "HEAD"
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)

  local opts = { enabled = true, max_files = 1, max_lines = 0, margin = 0, max_expanded = 0 }
  virt.attach(st, opts)

  assert(st.collapsed["c/three.txt"], "sanity: virt already auto-collapsed the far section")
  assert(H.auto_set(st)["c/three.txt"], "sanity: it's virt's own auto-set claim")

  -- A previously-saved USER collapse of that same path, restored onto this
  -- virt-active canvas (mirrors App:open's restore-LAST ordering).
  session.restore(st, { version = 1, base = "HEAD", collapsed = { "c/three.txt" } })

  local c_row = (canvas.section_rows(st, 3))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = c_row + 1, lnum = c_row + 1 })
  end)

  virt.apply(st, opts)

  assert(st.collapsed["c/three.txt"],
    "restored user collapse must survive a virt.apply pass near the section")

  session.save(st)
  local data = session.load(root)
  local found = false
  for _, p in ipairs(data.collapsed or {}) do
    if p == "c/three.txt" then found = true end
  end
  assert(found, "restored user collapse must still be persisted after session.save")

  virt.detach()
  cleanup(root)
end

-- A <Tab> is an EXPLICIT user action, so the collapse it leaves behind has to
-- be recorded as the user's -- not as the virtualizer's own bookkeeping, which
-- session.save discards and the next in-window apply expands straight back.
--
-- Driven end to end through the public API, so there is no handle on the state
-- to inspect intent directly. The persisted payload is the observable that
-- matters here, and it is exactly what regressed.
T["session_ explicit collapse of an auto-collapsed section is persisted"] = function()
  local root = big_repo()
  in_repo(root, VIRT_FORCED, function(fm)
    fm.open()
    -- c.txt sorts last, so the buffer's last line is its row either way.
    local function collapsed_c()
      return vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]:match("^▸ c%.txt") ~= nil
    end
    assert(collapsed_c(), "sanity: virt auto-collapsed c.txt at open")

    -- G lands on the last row, which is c.txt's placeholder. WinScrolled is
    -- emitted from the redraw path and never fires without an attached UI,
    -- so this scroll cannot arm virt's debounce headlessly -- the collapse is
    -- still virt's own when the toggle below runs.
    vim.cmd("normal! G")
    assert(collapsed_c(), "sanity: still a placeholder after scrolling onto it")

    vim.api.nvim_feedkeys(vim.keycode("za"), "x", false) -- user expands
    assert(not collapsed_c(), "<Tab> brings it back")

    vim.api.nvim_feedkeys(vim.keycode("za"), "x", false) -- user re-collapses
    assert(collapsed_c(), "c.txt is collapsed back to its placeholder")

    fm.close()

    local data = session.load(root)
    local found = false
    for _, p in ipairs(data.collapsed or {}) do
      if p == "c.txt" then found = true end
    end
    assert(found, "the user's explicit collapse must be persisted, not discarded as virt's")
  end)
end

-- virt.attach applies immediately, and on a freshly-opened canvas the
-- viewport is still at the top -- so it auto-collapses exactly the far
-- section a saved view wants to scroll to, and restore's view step then
-- bails on it. Reopening a large changeset has to land where the user left
-- off, not back at section one.
T["session_ saved view survives virt's immediate auto-collapse"] = function()
  local root = big_repo()
  in_repo(root, VIRT_FORCED, function(fm)
    fm.open()

    -- G lands on c.txt's placeholder (the last row); <Tab> expands it, and a
    -- second G parks the viewport deep inside it so the saved view names
    -- c.txt rather than whatever is above it.
    vim.cmd("normal! G")
    vim.api.nvim_feedkeys(vim.keycode("za"), "x", false)
    vim.cmd("normal! G")
    assert(vim.fn.getline(vim.fn.line("w0")):match("c line"),
      "sanity: parked inside c.txt before saving, got: " .. vim.fn.getline(vim.fn.line("w0")))

    fm.close()
    H.eq(session.load(root).view.path, "c.txt", "sanity: the saved view names c.txt")

    -- Wipe the singleton canvas buffer and reopen in a fresh window. Both
    -- halves matter: a surviving buffer carries a remembered cursor that
    -- Neovim restores on load, which would park the reopened viewport near
    -- the saved section by accident and hide the defect. This is the real
    -- scenario -- a new Neovim process, where the canvas starts at row 1.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if canvas.is_canvas_buf(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    vim.cmd("tabnew")
    fm.open()

    local top = vim.fn.getline(vim.fn.line("w0"))
    assert(top:match("c line"),
      "reopened inside the saved section, not back at the top; got: " .. top)
  end)
end

-- Saved collapses are reapplied after scrollbar.open has already drawn the
-- bar from the fully-expanded canvas. When the restored view doesn't itself
-- scroll -- here it isn't saved at all, because the top section is the
-- collapsed one -- nothing redraws the minimap and it keeps depicting a
-- canvas that no longer exists. virt is disabled so its own resync can't
-- stand in for the missing one.
T["session_ restored collapses reach the scrollbar"] = function()
  local root = big_repo()
  in_repo(root, { virt = { enabled = false } }, function(fm)
    fm.open()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("za"), "x", false) -- user collapses a.txt
    fm.close()
    H.eq(session.load(root).collapsed, { "a.txt" }, "sanity: the collapse was persisted")
    H.eq(session.load(root).view, nil, "sanity: no saved view, so the restore won't scroll")

    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if canvas.is_canvas_buf(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    vim.cmd("tabnew")

    -- Record what the bar was drawn from on each redraw. state.collapsed is
    -- mutated in place, so it has to be copied per call or every snapshot
    -- ends up being the same final table.
    local real_update = scrollbar.update
    local seen = {}
    scrollbar.update = function(state, ...)
      seen[#seen + 1] = vim.deepcopy((state and state.collapsed) or {})
      return real_update(state, ...)
    end
    local ok_open, open_err = pcall(fm.open)
    scrollbar.update = real_update
    assert(ok_open, open_err)

    assert(#seen > 0, "sanity: the scrollbar was drawn at all")
    H.eq(seen[#seen], { ["a.txt"] = "user" },
      "the last redraw saw the restored collapse, not the fully-expanded canvas")
  end)
end

-- The stranding case, end to end. Folds restore onto state.folded whether or
-- not the sidebar is enabled, so a user who saved a fold and then turned the
-- sidebar off has no tree to unfold from -- <Tab> on the placeholder is the
-- only way back, and without it those files are permanently invisible.
T["session_folds reveal works after reopening with the sidebar disabled"] = function()
  local root = H.git_fixture({
    committed = { ["a/one.txt"] = "1\n", ["a/two.txt"] = "2\n", ["b/three.txt"] = "3\n" },
    worktree = { ["a/one.txt"] = "1x\n", ["a/two.txt"] = "2x\n", ["b/three.txt"] = "3x\n" },
  })
  in_repo(root, {}, function(fm)
    fm.open()

    -- Fold a/ by driving the sidebar's own <CR>.
    local sbuf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b)
        and vim.api.nvim_buf_get_name(b):find("galley://sidebar", 1, true) then
        sbuf = b
      end
    end
    assert(sbuf, "sanity: the sidebar is open")
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(sbuf, "n")) do
      if m.lhs == "<CR>" then
        vim.api.nvim_win_set_cursor(vim.fn.bufwinid(sbuf), { 1, 0 })
        m.callback()
      end
    end
    fm.close()
    H.eq(session.load(root).folds, { "a/" }, "sanity: the fold was persisted")

    -- Reopen with no sidebar, in a window that has no remembered view.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if canvas.is_canvas_buf(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    vim.cmd("tabnew")
    fm.setup({ sidebar = { enabled = false } })
    fm.open()
    H.eq(require("galley.sidebar").is_open(), false, "sanity: no sidebar this time")

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(lines[1]:match("^▸ a/one%.txt"),
      "sanity: the fold restored with no tree to undo it: " .. lines[1])

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("za"), "x", false)
    local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(not after[1]:match("^▸"),
      "<Tab> is the only escape when the sidebar is off: " .. after[1])

    fm.close()
  end)
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
    package.loaded["galley"] = nil
    local fm = require("galley")
    fm.open()

    -- alphabetical order: a.txt's file_hdr is row 1; collapse it the same
    -- way the <Tab> keymap would.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("za"), "x", false)

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
