local H = require("helpers")
local git = require("canvasdiff.git")
local collect = require("canvasdiff.collect")
local model = require("canvasdiff.model")
local canvas = require("canvasdiff.canvas")

--- Stage the current worktree content of `rel` (via `git add -A`), leaving
--- the index holding whatever's on disk right now.
local function git_add_all(root)
  local res = vim.system({ "git", "add", "-A" }, { cwd = root, text = true }):wait()
  assert(res.code == 0, "git add -A failed: " .. (res.stderr or ""))
end

local function write_file(root, rel, content)
  local abs = vim.fs.joinpath(root, rel)
  local f = assert(io.open(abs, "w"))
  f:write(content)
  f:close()
end

--- Fixture with one file that has BOTH a staged edit and a further, still
--- unstaged edit: HEAD content ≠ index content ≠ worktree content.
local function staged_and_unstaged_fixture()
  local root = H.git_fixture({ committed = { ["f.txt"] = "head\n" } })
  write_file(root, "f.txt", "staged\n")
  git_add_all(root)
  write_file(root, "f.txt", "worktree\n")
  return root
end

--- Fixture with one file that's fully staged (index == worktree, both
--- differ from HEAD) and nothing else changed.
local function fully_staged_fixture()
  local root = H.git_fixture({ committed = { ["g.txt"] = "head\n" } })
  write_file(root, "g.txt", "staged\n")
  git_add_all(root)
  return root
end

return {
  ["base_ git.show reads HEAD and index objects"] = function()
    local root = staged_and_unstaged_fixture()
    H.eq(git.show(root, "HEAD", "f.txt"), "head\n")
    H.eq(git.show(root, ":0", "f.txt"), "staged\n")
  end,

  ["base_ index mode diffs worktree against the index"] = function()
    local root = staged_and_unstaged_fixture()

    local function old_text_for(files)
      for _, f in ipairs(files) do
        if f.path == "f.txt" then
          return f.old_text
        end
      end
    end

    H.eq(old_text_for(collect.files(root, "index")), "staged\n")
    H.eq(old_text_for(collect.files(root, "HEAD")), "head\n")
    H.eq(old_text_for(collect.files(root, nil)), "head\n")
  end,

  ["base_ fully-staged file disappears in index mode"] = function()
    local root = fully_staged_fixture()

    local function has_section(base)
      local sections = model.build(collect.files(root, base), 3)
      for _, s in ipairs(sections) do
        if s.path == "g.txt" then
          return true
        end
      end
      return false
    end

    H.eq(has_section("HEAD"), true, "HEAD mode: worktree differs from HEAD")
    H.eq(has_section("index"), false, "index mode: worktree == index, no diff")
  end,

  ["base_ toggle_base refreshes sections"] = function()
    local root = fully_staged_fixture()
    local old_cwd = vim.fn.getcwd()

    local ok, err = pcall(function()
      vim.api.nvim_set_current_dir(root)
      package.loaded["canvasdiff"] = nil
      local fm = require("canvasdiff")
      fm.open()

      local function headers()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local order = {}
        for _, l in ipairs(lines) do
          local p = l:match("^▎ (%S+)")
          if p then
            order[#order + 1] = p
          end
        end
        return order
      end

      H.eq(headers(), { "g.txt" }, "HEAD mode: g.txt's diff is showing")

      fm.toggle_base()
      H.eq(headers(), {}, "index mode: g.txt fully staged, no diff to show")

      fm.toggle_base()
      H.eq(headers(), { "g.txt" }, "back to HEAD mode: g.txt reappears")

      fm.close() -- don't leak an open canvas into the tests that follow
    end)

    vim.api.nvim_set_current_dir(old_cwd)
    assert(ok, err)
  end,

  -- App state deliberately outlives close() (the canvas buffer is cached), so
  -- a bare `if not state` guard still passes once the canvas is gone. The
  -- command would then flip the base of a hidden canvas and re-render it
  -- against a possibly stale root -- announcing a base the next open()
  -- discards, potentially for an entirely different repository.
  ["base_ toggle is a no-op on a closed canvas"] = function()
    local root = fully_staged_fixture()
    local old_cwd = vim.fn.getcwd()
    local real_notify = vim.notify

    local function canvas_lines()
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if canvas.is_canvas_buf(b) then
          return vim.api.nvim_buf_get_lines(b, 0, -1, false)
        end
      end
    end

    local ok, err = pcall(function()
      vim.cmd("tabnew")
      vim.api.nvim_set_current_dir(root)
      package.loaded["canvasdiff"] = nil
      local fm = require("canvasdiff")
      fm.open()
      fm.close()

      local before = canvas_lines()
      assert(before, "sanity: the canvas buffer survives close")

      local msgs = {}
      vim.notify = function(msg, level)
        msgs[#msgs + 1] = { msg = msg, level = level }
      end
      fm.toggle_base()
      vim.notify = real_notify

      -- g.txt is fully staged, so a base flip to "index" would re-render the
      -- hidden canvas to its empty-state message.
      H.eq(canvas_lines(), before, "the hidden canvas was not re-rendered")
      H.eq(#msgs, 1, "exactly one notification")
      assert(msgs[1].msg:match("no live diff canvas"),
        "warns instead of toggling, got: " .. msgs[1].msg)
      H.eq(msgs[1].level, vim.log.levels.WARN, "and it's a warning")
    end)

    vim.notify = real_notify
    vim.cmd("tabclose")
    vim.api.nvim_set_current_dir(old_cwd)
    assert(ok, err)
  end,

  ["base_ staged deletion produces no phantom section in index mode"] = function()
    local root = H.git_fixture({ committed = { ["gone.txt"] = "a\nb\nc\n" } })
    vim.system({ "git", "rm", "-q", "gone.txt" }, { cwd = root }):wait()
    local files = collect.files(root, "index")
    local sections = model.build(files, 3)
    H.eq(sections, {}, "staged-deleted file must not render a section in index mode")
    -- and in HEAD mode the deletion IS visible (all lines deleted)
    local head_sections = model.build(collect.files(root, "HEAD"), 3)
    H.eq(#head_sections, 1, "HEAD mode: one section for the deleted file")
    assert(head_sections[1].dels > 0, "HEAD mode: deletion section must have dels > 0")
  end,
}
