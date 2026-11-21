local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local lens = require("canvasdiff.diff").lens

local T = {}

-- Interactive re-collections -- a lens key or word, a refresh, a stage key --
-- collect a large review in time slices (App's pivot_sliced) and reconcile
-- when the collection lands, so the review stays usable meanwhile. Small
-- reviews pivot inside the call, exactly as before. These fixtures sit just
-- past the real 20,000-line threshold (both sides of two 6,000-line files
-- are split and built), so no internal knob is involved: the routes under
-- test are the ones a user's keypress takes.
local ROWS = 6000

local function numbered(prefix, count)
  local lines = {}
  for i = 1, count do
    lines[i] = ("%s %d"):format(prefix, i)
  end
  return table.concat(lines, "\n") .. "\n"
end

local function fixture(rows)
  local root = H.git_fixture({
    committed = {
      ["a.txt"] = numbered("a-old", rows),
      ["b.txt"] = numbered("b-old", rows),
      ["s.txt"] = "s1\n",
    },
    worktree = {
      ["a.txt"] = numbered("a-new", rows),
      ["b.txt"] = numbered("b-new", rows),
      ["s.txt"] = "s2\n",
    },
  })
  -- a.txt staged in full: the staged lens shows only it, unstaged only b/s.
  vim.system({ "git", "add", "a.txt" }, { cwd = root }):wait()
  return root
end

local function in_review(rows, fn, setup)
  local root = fixture(rows)
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
    auto_collapse = { enabled = false },
    session = { enabled = false },
  }, setup or {}))
  local ok, err = xpcall(function()
    local st = assert(fm.open())
    fn(fm, st, notes, root)
  end, debug.traceback)
  pcall(fm.close)
  vim.notify = real_notify
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  require("canvasdiff.config").setup({})
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

local function paths(st)
  local out = {}
  for _, section in ipairs(st.sections) do
    out[#out + 1] = section.path
  end
  return out
end

local function logical_text(st)
  local text = canvas.logical(st)
  return text.rows(0, text.row_count())
end

local function settle(predicate, message)
  assert(vim.wait(5000, predicate, 5), message)
end

T["sliced_pivot a small review switches lens inside the call"] = function()
  in_review(5, function(fm, st)
    fm.command({ "unstaged" })
    H.eq(lens.of(st).id, "unstaged", "below the threshold a typed lens word is immediate")
  end)
end

T["sliced_pivot a typed lens word collects in slices and lands the same model"] = function()
  in_review(ROWS, function(fm, st, notes)
    fm.command({ "unstaged" })
    H.eq(lens.of(st).id, "all", "the canvas keeps its lens until the collection lands")
    H.eq(paths(st), { "a.txt", "b.txt", "s.txt" })
    settle(function() return lens.of(st).id == "unstaged" end, "the pivot never landed")
    H.eq(paths(st), { "b.txt", "s.txt" })
    assert(vim.tbl_contains(notes, "CanvasDiff: showing INDEX → WORKTREE (unstaged)")
      or vim.iter(notes):any(function(n) return n:find("unstaged", 1, true) ~= nil end),
      vim.inspect(notes))
    -- What landed is exactly what a plain pivot builds.
    local sliced = logical_text(st)
    fm.set_lens(lens.get("all"))
    fm.set_lens(lens.get("unstaged"))
    H.eq(logical_text(st), sliced)
  end)
end

T["sliced_pivot a newer lens word supersedes a pending one"] = function()
  in_review(ROWS, function(fm, st)
    fm.command({ "unstaged" })
    fm.command({ "staged" })
    settle(function() return lens.of(st).id == "staged" end, "the newer pivot never landed")
    vim.wait(100)
    H.eq(lens.of(st).id, "staged", "the superseded collection must not land afterwards")
    H.eq(paths(st), { "a.txt" })
  end)
end

T["sliced_pivot closing the review cancels a pending pivot"] = function()
  in_review(ROWS, function(fm, st, notes)
    fm.command({ "unstaged" })
    fm.close()
    vim.wait(200)
    for _, note in ipairs(notes) do
      assert(not note:find("unstaged", 1, true), "a closed review must not pivot: " .. note)
      assert(not note:lower():find("fail", 1, true), "no failure is reported: " .. note)
    end
    H.eq(st.sections, {}, "the disposed review keeps no model")
  end)
end

-- A refresh re-diffs only files whose sides changed (content-addressed
-- reuse), so an edit to a SMALL file stays a small, immediate refresh; it
-- takes a large edit for the collection to be worth slicing.
T["sliced_pivot a typed refresh after a large edit collects in slices"] = function()
  in_review(ROWS, function(fm, st, _, root)
    local f = assert(io.open(vim.fs.joinpath(root, "b.txt"), "w"))
    f:write(numbered("b-newer", ROWS))
    f:close()
    local function b_last()
      for _, section in ipairs(st.sections) do
        if section.path == "b.txt" then
          return section.entries[#section.entries].content
        end
      end
    end
    fm.command({ "refresh" })
    H.eq(b_last(), "b-new " .. ROWS, "unchanged until the collection lands")
    settle(function() return b_last() == "b-newer " .. ROWS end, "the refresh never landed")
  end)
end

T["sliced_pivot a refresh after a small edit stays immediate"] = function()
  in_review(ROWS, function(fm, st, _, root)
    local f = assert(io.open(vim.fs.joinpath(root, "s.txt"), "w"))
    f:write("s3\n")
    f:close()
    fm.command({ "refresh" })
    local last = st.sections[#st.sections]
    H.eq(last.entries[#last.entries].content, "s3",
      "the unchanged large files are reused, so this is not large work")
  end)
end

-- The canvas key itself, not an API stand-in: Git runs at the press, the
-- canvas catches up when the re-collection lands, and the file the key
-- staged is reported.
T["sliced_pivot the stage-file key re-collects in slices after Git runs"] = function()
  in_review(ROWS, function(_, st, notes, root)
    -- s.txt is the last section; put the cursor on its header.
    local start0 = canvas.section_rows(st, #st.sections)
    vim.api.nvim_win_set_cursor(st.win, { start0 + 1, 0 })
    local callback
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(st.buf, "n")) do
      if map.lhs == "S" then callback = map.callback end
    end
    assert(callback, "the stage-file key is mapped")
    callback()
    local cached = vim.system({ "git", "diff", "--cached", "--name-only" },
      { cwd = root, text = true }):wait().stdout
    assert(cached:find("s.txt", 1, true), "Git ran at the press: " .. cached)
    settle(function() return st.sections[#st.sections].staged ~= nil end,
      "the stage never reached the canvas")
    assert(vim.iter(notes):any(function(n) return n:find("s.txt", 1, true) ~= nil end),
      vim.inspect(notes))
  end)
end

-- The watch pass runs on every save and focus change -- while the user is
-- typing. On a large review it collects in slices too, and a change that
-- arrives while one pass is collecting is folded into one more pass rather
-- than restarting it, so a stream of saves cannot starve the refresh.
local WATCH = { watch = { enabled = true, debounce_ms = 1, poll_ms = false } }

local function b_last(st)
  for _, section in ipairs(st.sections) do
    if section.path == "b.txt" then
      return section.entries[#section.entries].content
    end
  end
end

local function rewrite_b(root, prefix)
  local f = assert(io.open(vim.fs.joinpath(root, "b.txt"), "w"))
  f:write(numbered(prefix, ROWS))
  f:close()
end

--- Record each collection the watch makes: whether it was handed a pacer
--- and ran inside a coroutine (the sliced path -- test_slice proves such a
--- pacer yields once past the threshold), and how many overlapped.
local function spy_collections()
  local source = require("canvasdiff.source")
  local real = source.sections
  local spy = { calls = {}, active = 0, max_active = 0 }
  source.sections = function(...)
    local pace = select(5, ...)
    local _, main = coroutine.running()
    spy.calls[#spy.calls + 1] = { paced = type(pace) == "function" and not main }
    spy.active = spy.active + 1
    spy.max_active = math.max(spy.max_active, spy.active)
    local function done(...)
      spy.active = spy.active - 1
      return ...
    end
    return done(real(...))
  end
  function spy.restore() source.sections = real end
  return spy
end

T["sliced_pivot a watch pass over a large edit collects in slices"] = function()
  in_review(ROWS, function(_, st, _, root)
    local spy = spy_collections()
    local ok, err = pcall(function()
      rewrite_b(root, "b-watched")
      vim.api.nvim_exec_autocmds("FocusGained", {})
      settle(function() return b_last(st) == "b-watched " .. ROWS end,
        "the watch pass never landed")
    end)
    spy.restore()
    assert(ok, err)
    assert(#spy.calls >= 1, "the watch collected")
    for _, call in ipairs(spy.calls) do
      assert(call.paced, "a watch pass must collect on the sliced path")
    end
  end, WATCH)
end

T["sliced_pivot a change during a watch pass is coalesced into one more pass"] = function()
  in_review(ROWS, function(_, st, _, root)
    local spy = spy_collections()
    local ok, err = pcall(function()
      rewrite_b(root, "b-first")
      vim.api.nvim_exec_autocmds("FocusGained", {})
      -- Change the file again only once the first pass is mid-collection.
      settle(function() return spy.active > 0 end, "the first pass never started")
      rewrite_b(root, "b-second")
      vim.api.nvim_exec_autocmds("FocusGained", {})
      settle(function() return b_last(st) == "b-second " .. ROWS end,
        "the change made during a pass was lost")
      vim.wait(100)
    end)
    spy.restore()
    assert(ok, err)
    H.eq(b_last(st), "b-second " .. ROWS, "nothing older lands after it")
    H.eq(spy.max_active, 1, "passes never overlap: the second waits for the first")
    -- Two edits, so two passes; a little slack for fs-event timing. What
    -- this bound really guards is the review re-triggering ITSELF: this
    -- fixture writes inside git's racy-clean window, where `git status`
    -- used to rewrite .git/index on every pass and the .git watcher fed
    -- that back as a change -- 39 to 138 passes before GIT_OPTIONAL_LOCKS.
    assert(#spy.calls <= 3,
      ("a watch pass must not re-trigger itself: %d passes for two edits")
        :format(#spy.calls))
  end, WATCH)
end

T["sliced_pivot closing during a watch pass is clean"] = function()
  in_review(ROWS, function(fm, _, notes, root)
    rewrite_b(root, "b-closing")
    vim.api.nvim_exec_autocmds("FocusGained", {})
    vim.wait(10)
    fm.close()
    vim.wait(200)
    for _, note in ipairs(notes) do
      assert(not note:lower():find("fail", 1, true), "no failure is reported: " .. note)
    end
  end, WATCH)
end

return T
