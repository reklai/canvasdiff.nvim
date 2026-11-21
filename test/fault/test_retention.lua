local H = require("helpers")

local T = {}

-- A closed review must leave nothing of its model reachable. The hostile
-- party here is not user code but LuaJIT: a loop hot enough to compile keeps
-- every closure it calls as a trace constant for the trace's lifetime, which
-- is unrelated to whether anything still references the canvas. Before this
-- was fixed, the paged ingest iterator, PageList's batch flush and the model's
-- per-group `push` each pinned a closed review's rows until the next trace
-- flush -- measured at roughly 300 MB per review at a million rows -- while
-- every Lua-visible root (registry, _G, package.loaded) showed nothing.
--
-- The rows are sized so each of those loops runs thousands of iterations and
-- compiles; a ten-line fixture would never reach a trace and prove nothing.
local ROWS = 3000

local function numbered(prefix, count)
  local lines = {}
  for i = 1, count do
    lines[i] = ("%s %d"):format(prefix, i)
  end
  return table.concat(lines, "\n") .. "\n"
end

local function live(tracked)
  local count = 0
  for _ in pairs(tracked) do
    count = count + 1
  end
  return count
end

--- Opens, re-lenses and closes one review, tracking its model weakly. Kept a
--- separate function so no test local still holds the state once it returns.
local function review_once(fm, diff, tracked, sliced)
  local real_build = diff.build_section
  diff.build_section = function(...)
    local section = real_build(...)
    if section then
      tracked[section] = "section " .. section.path
      tracked[section.entries] = "entries " .. section.path
      local middle = section.entries[math.floor(#section.entries / 2) + 1]
      if middle then
        tracked[middle] = "entry " .. section.path
      end
    end
    return section
  end
  local ok, err = pcall(function()
    local state
    if sliced then
      -- A sliced open adds the slicer's coroutine, pacer and step closures
      -- to the hot paths; none of them may hold the model either.
      local canvas = require("canvasdiff.canvas")
      local real_open = canvas.open
      canvas.open = function(...)
        state = real_open(...)
        return state
      end
      local returned = fm.open({
        lens = diff.lens.get("all"), async = true,
        _incremental_rows = 1, _slice_ms = 0,
      })
      local done = vim.wait(5000, function() return state ~= nil end, 1)
      canvas.open = real_open
      assert(returned == nil and done, "the open must have been sliced")
    else
      state = fm.open({ lens = diff.lens.get("all") })
    end
    assert(state, "the fixture must open")
    fm.set_lens(diff.lens.get("unstaged"))
    fm.set_lens(diff.lens.get("all"))
    fm.close()
  end)
  diff.build_section = real_build
  assert(ok, err)
end

local function retention_case(sliced)
  local root = H.git_fixture({
    committed = {
      ["big.txt"] = numbered("old", ROWS),
      ["small.txt"] = "one\n",
    },
    worktree = {
      ["big.txt"] = numbered("new", ROWS),
      ["small.txt"] = "two\n",
    },
  })
  -- Stage one file so the unstaged lens is a genuinely different model and
  -- each lens switch retires the previous one.
  vim.system({ "git", "add", "small.txt" }, { cwd = root }):wait()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local jit_was_on = jit.status()
  jit.on()

  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  local diff = require("canvasdiff.diff")
  local tracked = setmetatable({}, { __mode = "k" })
  local ok, err = xpcall(function()
    fm.setup({ virt = { enabled = false }, auto_collapse = { enabled = false } })
    -- Twice: the second pass runs over loops the first already compiled,
    -- which is exactly when a trace holds the previous review's closures.
    review_once(fm, diff, tracked, sliced)
    review_once(fm, diff, tracked, sliced)
    -- The canvas buffer is reclaimed on the next event-loop turn.
    vim.wait(50)
    collectgarbage()
    collectgarbage()
    local survivors = {}
    for _, label in pairs(tracked) do
      survivors[#survivors + 1] = label
    end
    table.sort(survivors)
    H.eq(live(tracked), 0,
      "closed reviews must not stay reachable: " .. table.concat(survivors, ", "))
  end, debug.traceback)

  pcall(function() fm.close() end)
  fm.setup({})
  if not jit_was_on then
    jit.off()
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["retention a closed review leaves no model pinned by compiled traces"] = function()
  retention_case(false)
end

T["retention a sliced open leaves no model pinned once closed"] = function()
  retention_case(true)
end

return T
