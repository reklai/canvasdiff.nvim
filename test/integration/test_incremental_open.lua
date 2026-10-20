local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local lens = require("canvasdiff.diff").lens

local T = {}

-- An interactive open of a large review builds in time slices (os.sliced)
-- so the editor keeps reading keys and redrawing while a million rows are
-- collected and paged. These tests force slicing on small fixtures through
-- the internal knobs: `_incremental_rows = 1` makes any review "large",
-- `_slice_ms = 0` makes every checkpoint yield.
local FORCE = { async = true, _incremental_rows = 1, _slice_ms = 0 }

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
      ["b.txt"] = "b1\n",
      ["c.txt"] = numbered("c-old", rows),
    },
    worktree = {
      ["a.txt"] = numbered("a-new", rows),
      ["b.txt"] = "b2\n",
      ["c.txt"] = numbered("c-new", rows),
    },
  })
  vim.system({ "git", "add", "b.txt" }, { cwd = root }):wait()
  return root
end

--- Run `fn(fm, notes)` in a fresh tab and App with ambient controllers off.
local function in_review(root, setup, fn)
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
    session = { enabled = false },
  }, setup or {}))
  local ok, err = xpcall(function() fn(fm, notes) end, debug.traceback)
  pcall(fm.close)
  vim.notify = real_notify
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  require("canvasdiff.config").setup({})
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

local function showing_canvas()
  local buf = vim.api.nvim_get_current_buf()
  return vim.b[buf].canvasdiff_canvas ~= nil or canvas.is_canvas_buf(buf)
    or vim.api.nvim_buf_get_name(buf):find("^canvasdiff://") ~= nil
end

local function logical_text(st)
  local text = canvas.logical(st)
  return text.rows(0, text.row_count())
end

local function wait_shown()
  assert(vim.wait(5000, showing_canvas, 5), "the building review never appeared")
end

--- Buffers left once deferred reclamation has run.
local function settled_buffers()
  vim.wait(50)
  return #vim.api.nvim_list_bufs()
end

T["incremental_open a small review opens inside the call"] = function()
  in_review(fixture(5), nil, function(fm)
    local st = fm.open({ async = true })
    assert(st, "below the row threshold an async open is an ordinary open")
    assert(showing_canvas())
  end)
end

for _, case in ipairs({
  { name = "paged", setup = { paged = { min_rows = 1 } } },
  { name = "eager", setup = { paged = { enabled = false } } },
}) do
  T["incremental_open a sliced " .. case.name .. " build shows exactly what a plain open shows"] = function()
    in_review(fixture(1500), case.setup, function(fm)
      local plain = assert(fm.open())
      local expected = logical_text(plain)
      fm.close()

      -- The sliced open returns before it has a state, so capture the one
      -- it publishes where it publishes it: canvas.show for the prepared
      -- paged canvas, canvas.open for the eager one.
      local published
      local real_show, real_open = canvas.show, canvas.open
      canvas.show = function(state, ...)
        published = state
        return real_show(state, ...)
      end
      canvas.open = function(...)
        published = real_open(...)
        return published
      end
      local before = vim.api.nvim_get_current_buf()
      local st, err = fm.open(FORCE)
      canvas.show, canvas.open = real_show, real_open
      H.eq(st, nil, "a large build answers before it is done")
      assert(type(err) == "string" and err:find("still being built", 1, true), tostring(err))
      H.eq(vim.api.nvim_get_current_buf(), before,
        "nothing is published while the review builds")
      canvas.show, canvas.open = function(state, ...)
        published = state
        return real_show(state, ...)
      end, function(...)
        published = real_open(...)
        return published
      end
      local shown = pcall(wait_shown)
      canvas.show, canvas.open = real_show, real_open
      assert(shown, "the building review never appeared")
      assert(published, "the sliced open published through neither canvas path")
      H.eq(published.buf, vim.api.nvim_get_current_buf())
      H.eq(published.paged ~= nil, case.name == "paged")
      H.eq(logical_text(published), expected)
    end)
  end
end

T["incremental_open toggling again cancels a building review and leaks nothing"] = function()
  in_review(fixture(1500), { paged = { min_rows = 1 } }, function(fm, notes)
    local buffers = settled_buffers()
    local before = vim.api.nvim_get_current_buf()
    H.eq(fm.open(FORCE), nil)
    fm.toggle()
    vim.wait(200)
    H.eq(vim.api.nvim_get_current_buf(), before, "a cancelled review never appears")
    H.eq(settled_buffers(), buffers, "a cancelled build leaves no buffer behind")
    assert(vim.tbl_contains(notes, "CanvasDiff: open cancelled")
      or vim.iter(notes):any(function(n) return n:find("open cancelled", 1, true) ~= nil end),
      vim.inspect(notes))
  end)
end

T["incremental_open close cancels a building review"] = function()
  in_review(fixture(1500), { paged = { min_rows = 1 } }, function(fm)
    local buffers = settled_buffers()
    local before = vim.api.nvim_get_current_buf()
    H.eq(fm.open(FORCE), nil)
    fm.close()
    vim.wait(200)
    H.eq(vim.api.nvim_get_current_buf(), before)
    H.eq(settled_buffers(), buffers)
  end)
end

T["incremental_open a newer open supersedes a building one"] = function()
  in_review(fixture(1500), { paged = { min_rows = 1 } }, function(fm)
    H.eq(fm.open(FORCE), nil)
    local st = assert(fm.open({ lens = lens.get("staged") }))
    vim.wait(200)
    H.eq(vim.api.nvim_get_current_buf(), st.buf,
      "the superseded build must not publish over the newer review")
    H.eq(lens.of(st).id, "staged")
    H.eq(#st.sections, 1, "staged shows only b.txt")
  end)
end

T["incremental_open leaving the window cancels the publish"] = function()
  in_review(fixture(1500), { paged = { min_rows = 1 } }, function(fm, notes)
    local origin = vim.api.nvim_get_current_win()
    local origin_buf = vim.api.nvim_get_current_buf()
    H.eq(fm.open(FORCE), nil)
    vim.cmd("split")
    local elsewhere = vim.api.nvim_get_current_win()
    vim.wait(300)
    H.eq(vim.api.nvim_win_get_buf(origin), origin_buf,
      "the window the user left is not taken over behind their back")
    H.eq(vim.api.nvim_get_current_win(), elsewhere, "focus is never moved")
    assert(vim.iter(notes):any(function(n) return n:find("focus left", 1, true) ~= nil end),
      vim.inspect(notes))
    vim.cmd("close")
  end)
end

-- The command is the interactive entry point, so it must take the sliced
-- path without any internal knob: a review past the real threshold.
T["incremental_open :CanvasDiff builds a large review in slices"] = function()
  in_review(fixture(11000), nil, function(fm)
    local before = vim.api.nvim_get_current_buf()
    -- The user command's own route (plugin/ is not sourced by the runner).
    fm.command({ "open" })
    H.eq(vim.api.nvim_get_current_buf(), before,
      "the command returns before a 22,000-row review is published")
    wait_shown()
  end)
end

return T
