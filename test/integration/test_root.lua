local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local source = require("canvasdiff.source")

local T = {}

--- Run `fn` in a throwaway tab with `cwd` as the working directory, capturing
--- notifications. Restores cwd, closes the tab, and drops the cached root
--- facade so the next test gets a fresh default App.
local function in_cwd(cwd, fn)
  local old_cwd = vim.fn.getcwd()
  local real = vim.notify
  local msgs = {}
  vim.notify = function(msg, level) msgs[#msgs + 1] = { msg = msg, level = level } end

  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(cwd)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")

  local ok, err = pcall(fn, fm, msgs)

  pcall(fm.close)
  vim.notify = real
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  assert(ok, err)
end

local function shown_files()
  local out = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local p = l:match("^▎ (%S+)")
    if p then out[#out + 1] = p end
  end
  return out
end

-- Deletion staging deliberately refuses when any modified named buffer could
-- still be a vanished hardlink. Tests exercising unrelated rename mechanics
-- must therefore start without modified buffers leaked by earlier async test
-- teardown in the shared Neovim process.
local function clear_modified_file_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
        and vim.api.nvim_buf_get_name(buf) ~= ""
        and vim.api.nvim_get_option_value("modified", { buf = buf }) then
      vim.api.nvim_set_option_value("modified", false, { buf = buf })
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

-- The root module is the entire supported Lua surface. Pin it before the
-- App/Surface extraction so moving ownership cannot accidentally expose an
-- implementation method or drop one of the command-facing compatibility
-- methods. Ordinary repeated require() calls must also resolve to the one
-- cached facade; manually evicting package.loaded is not a lifecycle API.
T["root_ facade is cached and exports exactly the supported API"] = function()
  local first = require("canvasdiff")
  local second = require("canvasdiff")
  assert(rawequal(first, second), "ordinary require() calls share one facade")
  H.eq(getmetatable(first), nil, "the public facade is a plain table")

  local names = vim.tbl_keys(first)
  table.sort(names)
  H.eq(names, {
    "close",
    "command",
    "command_complete",
    "compare",
    "cycle_lens",
    "jump_back",
    "open",
    "refresh",
    "set_base",
    "set_branch",
    "set_lens",
    "set_range",
    "setup",
    "toggle",
    "toggle_base",
    "toggle_stage",
  })
  for _, name in ipairs(names) do
    H.eq(type(first[name]), "function", name .. " is callable")
  end
end

T["root_ toggle_stage follows unstaged to staged and staged back to unstaged"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  in_cwd(root, function(fm)
    fm.setup({
      watch = { enabled = false },
      sidebar = { enabled = false },
      scrollbar = { enabled = false },
      statuscolumn = { enabled = false },
      highlight = { enabled = false },
      virt = { enabled = false },
      session = { enabled = false },
    })
    local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("unstaged") }))
    assert(fm.toggle_stage())
    local file = assert(source.changed_files(root)[1])
    assert(file.staged and not file.unstaged, vim.inspect(file))
    H.eq(st.lens.id, "staged")

    assert(fm.toggle_stage())
    file = assert(source.changed_files(root)[1])
    assert(file.unstaged and not file.staged, vim.inspect(file))
    H.eq(st.lens.id, "unstaged")
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage stages mixed disk state but refuses an unsaved target buffer"] = function()
  local root = H.git_fixture({ committed = { ["a.txt"] = "head\n" } })
  local path = vim.fs.joinpath(root, "a.txt")
  local f = assert(io.open(path, "w")); f:write("index\n"); f:close()
  assert(vim.system({ "git", "add", "--", "a.txt" }, { cwd = root }):wait().code == 0)
  f = assert(io.open(path, "w")); f:write("disk\n"); f:close()
  in_cwd(root, function(fm, msgs)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    assert(fm.open({ lens = require("canvasdiff.diff").lens.get("unstaged") }))
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
    local changed, err = fm.toggle_stage()
    H.eq(changed, nil)
    assert(err and err:find("unsaved", 1, true), tostring(err))
    H.eq(source.show(root, ":0", "a.txt"), "index\n",
      "the index must not move when the target has unsaved edits")
    assert(msgs[#msgs].msg:find("unsaved", 1, true), vim.inspect(msgs))
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })

    assert(fm.toggle_stage())
    H.eq(source.show(root, ":0", "a.txt"), "disk\n",
      "mixed means stage the complete current disk state")
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage uses fresh Git truth when cached XY direction is stale"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "index\n" },
  })
  assert(vim.system({ "git", "add", "--", "a.txt" }, { cwd = root }):wait().code == 0)
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("staged") }))
    local f = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
    f:write("disk after open\n"); f:close()
    assert(st.sections[1].staged and not st.sections[1].unstaged,
      "sanity: cached canvas still says staged-only")
    assert(fm.toggle_stage())
    local file = assert(source.changed_files(root)[1])
    assert(file.staged and not file.unstaged, vim.inspect(file))
    H.eq(source.show(root, ":0", "a.txt"), "disk after open\n",
      "fresh mixed state stages disk instead of resetting the prior snapshot")
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage declines when stale canvas identity is now clean"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    assert(fm.open())
    local f = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
    f:write("head\n"); f:close()
    local changed, err = fm.toggle_stage()
    H.eq(changed, nil)
    assert(err and err:find("no changes", 1, true), tostring(err))
    H.eq(source.changed_files(root), {})
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage permits unstage with a modified buffer and keeps lens policy"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  assert(vim.system({ "git", "add", "--", "a.txt" }, { cwd = root }):wait().code == 0)
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("staged") }))
    local buf = vim.fn.bufadd(vim.fs.joinpath(root, "a.txt"))
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
    assert(fm.toggle_stage(), "unstaging never writes disk, so a modified buffer is safe")
    local file = assert(source.changed_files(root)[1])
    assert(file.unstaged and not file.staged, vim.inspect(file))
    H.eq(st.lens.id, "unstaged")
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage declines committed ranges and missing XY without mutation"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  in_cwd(root, function(fm, msgs)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open())
    st.lens = require("canvasdiff.diff").lens.range("HEAD", "HEAD", "..")
    local changed, err = fm.toggle_stage()
    H.eq(changed, nil)
    assert(err and err:find("committed", 1, true), tostring(err))
    assert(source.changed_files(root)[1].unstaged)

    st.lens = require("canvasdiff.diff").lens.get("all")
    local real_changed_files = source.changed_files
    source.changed_files = function()
      return { { path = "a.txt", status = "M" } }
    end
    changed, err = fm.toggle_stage()
    source.changed_files = real_changed_files
    H.eq(changed, nil)
    assert(err and err:find("status", 1, true), tostring(err))
    assert(source.changed_files(root)[1].unstaged)
    assert(msgs[#msgs].level == vim.log.levels.WARN)
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage reports a clean result without pivoting to an empty lens"] = function()
  local root = H.git_fixture({ committed = { ["a.txt"] = "head\n" } })
  local path = vim.fs.joinpath(root, "a.txt")
  local f = assert(io.open(path, "w")); f:write("index\n"); f:close()
  assert(vim.system({ "git", "add", "--", "a.txt" }, { cwd = root }):wait().code == 0)
  f = assert(io.open(path, "w")); f:write("head\n"); f:close()
  in_cwd(root, function(fm, msgs)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("unstaged") }))
    assert(fm.toggle_stage())
    H.eq(source.changed_files(root), {})
    H.eq(st.lens.id, "unstaged", "a clean index has no staged lens to follow")
    H.eq(st.sections, {}, "clean reconciliation removes the obsolete XY section")
    H.eq(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), { "-- no changes --" })
    assert(msgs[#msgs].msg:find("clean", 1, true), vim.inspect(msgs))
  end)
  vim.fn.delete(root, "rf")
end

T["root_ newer lens intent supersedes an older post-Git stage continuation"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  in_cwd(root, function(fm, msgs)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local lens_mod = require("canvasdiff.diff").lens
    local st = assert(fm.open({ lens = lens_mod.get("unstaged") }))
    local real_changed_files = source.changed_files
    local reentered = false
    source.changed_files = function(...)
      local files, err = real_changed_files(...)
      local file = files and files[1]
      if not reentered and file and file.staged and not file.unstaged then
        reentered = true
        assert(fm.set_lens(lens_mod.get("all")))
      end
      return files, err
    end
    local changed, err = fm.toggle_stage()
    source.changed_files = real_changed_files
    H.eq(changed, nil)
    assert(err and err:find("index changed", 1, true), tostring(err))
    H.eq(st.lens.id, "all", "the newer user lens action remains published")
    assert(msgs[#msgs].msg:find("refresh failed", 1, true), vim.inspect(msgs))
  end)
  vim.fn.delete(root, "rf")
end

T["root_ modified symlink-alias buffer blocks staging its real target"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  local alias = vim.fs.joinpath(root, "alias.txt")
  assert(vim.uv.fs_symlink(vim.fs.joinpath(root, "a.txt"), alias))
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open())
    local buf = vim.fn.bufadd(alias)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved alias" })
    vim.api.nvim_set_current_win(st.win)
    local changed, err = fm.toggle_stage()
    H.eq(changed, nil)
    assert(err and err:find("unsaved", 1, true), tostring(err))
    H.eq(source.show(root, ":0", "a.txt"), "head\n")
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  vim.fn.delete(root, "rf")
end

T["root_ deleted target with a modified symlink-alias buffer refuses staging"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  local path = vim.fs.joinpath(root, "a.txt")
  local alias = vim.fs.joinpath(root, "alias.txt")
  assert(vim.uv.fs_symlink(path, alias))
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("unstaged") }))
    local buf = vim.fn.bufadd(alias)
    vim.fn.bufload(buf)
    assert(vim.uv.fs_unlink(path))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved alias" })
    vim.api.nvim_set_current_win(st.win)

    local changed, err = fm.toggle_stage()
    H.eq(changed, nil)
    assert(err and err:find("unsaved", 1, true), tostring(err))
    H.eq(source.show(root, ":0", "a.txt"), "head\n",
      "a dangling symlink alias must not permit staging the target deletion")
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  vim.fn.delete(root, "rf")
end

T["root_ deleted target with a modified hardlink-alias buffer refuses staging"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  local path = vim.fs.joinpath(root, "a.txt")
  local alias = vim.fs.joinpath(root, "alias.txt")
  local linked = vim.uv.fs_link(path, alias)
  if not linked then
    vim.fn.delete(root, "rf")
    return
  end
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("unstaged") }))
    local buf = vim.fn.bufadd(alias)
    vim.fn.bufload(buf)
    assert(vim.uv.fs_unlink(path))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved hardlink alias" })
    vim.api.nvim_set_current_win(st.win)

    local changed, err = fm.toggle_stage()
    H.eq(changed, nil)
    assert(err and err:find("unsaved", 1, true), tostring(err))
    H.eq(source.show(root, ":0", "a.txt"), "head\n",
      "an extant hardlink alias must not permit staging the target deletion")
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  vim.fn.delete(root, "rf")
end

T["root_ atomically replaced target keeps its modified hardlink alias protected"] = function()
  local root = H.git_fixture({ committed = { ["a.txt"] = "head\n" } })
  local path = vim.fs.joinpath(root, "a.txt")
  local replacement = vim.fs.joinpath(root, "replacement.tmp")
  local f = assert(io.open(replacement, "w"))
  f:write("replacement\n")
  f:close()
  assert(vim.uv.fs_rename(replacement, path))
  local alias = vim.fs.joinpath(root, "alias.txt")
  local linked = vim.uv.fs_link(path, alias)
  if not linked then
    vim.fn.delete(root, "rf")
    return
  end
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("unstaged") }))
    local buf = vim.fn.bufadd(alias)
    vim.fn.bufload(buf)
    assert(vim.uv.fs_unlink(path))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved replacement alias" })
    vim.api.nvim_set_current_win(st.win)

    local changed, err = fm.toggle_stage()
    H.eq(changed, nil)
    assert(err and err:find("unsaved", 1, true), tostring(err))
    H.eq(source.show(root, ":0", "a.txt"), "head\n")
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  vim.fn.delete(root, "rf")
end

T["root_ deleted hardlink alias path still protects its modified buffer"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  local path = vim.fs.joinpath(root, "a.txt")
  local alias = vim.fs.joinpath(root, "alias.txt")
  local linked = vim.uv.fs_link(path, alias)
  if not linked then
    vim.fn.delete(root, "rf")
    return
  end
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("unstaged") }))
    local buf = vim.fn.bufadd(alias)
    vim.fn.bufload(buf)
    assert(vim.uv.fs_unlink(path))
    assert(vim.uv.fs_unlink(alias))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved vanished alias" })
    vim.api.nvim_set_current_win(st.win)

    local changed, err = fm.toggle_stage()
    H.eq(changed, nil)
    assert(err and err:find("unsaved", 1, true), tostring(err))
    H.eq(source.show(root, ":0", "a.txt"), "head\n")
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  vim.fn.delete(root, "rf")
end

T["root_ dangling relative symlink components protect the deleted target"] = function()
  local root = H.git_fixture({
    committed = { ["sub/a.txt"] = "head\n" },
    worktree = { ["sub/a.txt"] = "disk\n" },
  })
  vim.fn.mkdir(vim.fs.joinpath(root, "sub", "nested"), "p")
  assert(vim.uv.fs_symlink("sub/nested", vim.fs.joinpath(root, "dir")))
  local alias = vim.fs.joinpath(root, "alias.txt")
  assert(vim.uv.fs_symlink("dir/../a.txt", alias))
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("unstaged") }))
    local buf = vim.fn.bufadd(alias)
    vim.fn.bufload(buf)
    assert(vim.uv.fs_unlink(vim.fs.joinpath(root, "sub", "a.txt")))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved nested alias" })
    vim.api.nvim_set_current_win(st.win)
    local target_i
    for i, section in ipairs(st.sections) do
      if section.path == "sub/a.txt" then target_i = i end
    end
    assert(target_i, "the tracked target is selectable beside alias entries")
    local start0 = canvas.section_rows(st, target_i)
    vim.api.nvim_win_set_cursor(st.win, { start0 + 1, 0 })

    local changed, err = fm.toggle_stage()
    H.eq(changed, nil)
    assert(err and err:find("unsaved", 1, true), tostring(err))
    H.eq(source.show(root, ":0", "sub/a.txt"), "head\n")
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  vim.fn.delete(root, "rf")
end

T["root_ retargeted cross-device symlink still protects its loaded buffer"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  local path = vim.fs.joinpath(root, "a.txt")
  local unrelated = "/proc/self/status"
  local root_stat = assert(vim.uv.fs_stat(root))
  local unrelated_stat = vim.uv.fs_stat(unrelated)
  if not unrelated_stat or unrelated_stat.dev == root_stat.dev then
    vim.fn.delete(root, "rf")
    return
  end
  local alias = vim.fs.joinpath(root, "alias.txt")
  assert(vim.uv.fs_symlink(path, alias))
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("unstaged") }))
    local buf = vim.fn.bufadd(alias)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved original target" })
    assert(vim.uv.fs_unlink(path))
    assert(vim.uv.fs_unlink(alias))
    assert(vim.uv.fs_symlink(unrelated, alias))
    vim.api.nvim_set_current_win(st.win)

    local changed, err = fm.toggle_stage()
    H.eq(changed, nil)
    assert(err and err:find("unsaved", 1, true), tostring(err))
    H.eq(source.show(root, ":0", "a.txt"), "head\n")
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage tells the truth when Git succeeds and refresh fails"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  in_cwd(root, function(fm, msgs)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    assert(fm.open())
    local real_sections = source.sections
    source.sections = function() return nil, "injected reconcile failure" end
    local changed, err = fm.toggle_stage()
    source.sections = real_sections
    H.eq(changed, nil)
    assert(err and err:find("refresh failed", 1, true), tostring(err))
    assert(source.changed_files(root)[1].staged,
      "Git success is never rolled back to make the UI transaction look atomic")
    assert(msgs[#msgs].msg:find("index changed", 1, true), vim.inspect(msgs))
    assert(msgs[#msgs].msg:find("refresh failed", 1, true), vim.inspect(msgs))
  end)
  vim.fn.delete(root, "rf")
end

T["root_ stage_cycle canvas key invokes the same public transaction"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open({ lens = require("canvasdiff.diff").lens.get("unstaged") }))
    vim.api.nvim_set_current_win(st.win)
    vim.api.nvim_feedkeys(vim.keycode("s"), "x", false)
    local file = assert(source.changed_files(root)[1])
    assert(file.staged and not file.unstaged, vim.inspect(file))
    H.eq(st.lens.id, "staged")
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage keeps all and bare-ref lenses in place"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  assert(vim.system({ "git", "branch", "older", "HEAD" }, { cwd = root }):wait().code == 0)
  assert(vim.system({ "git", "add", "--", "a.txt" }, { cwd = root }):wait().code == 0)
  assert(vim.system({ "git", "commit", "-m", "advance" }, { cwd = root }):wait().code == 0)
  local f = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  f:write("worktree after advance\n"); f:close()
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local lens_mod = require("canvasdiff.diff").lens
    local st = assert(fm.open({ lens = lens_mod.get("all") }))
    assert(fm.toggle_stage())
    H.eq(st.lens.id, "all")
    assert(fm.toggle_stage())
    H.eq(st.lens.id, "all")

    local branch_lens = lens_mod.branch("older")
    assert(fm.set_lens(branch_lens))
    assert(fm.toggle_stage())
    H.eq(st.lens.id, branch_lens.id)
    H.eq(st.lens.old, "older")
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage preserves nearest line through rename stage and unstage"] = function()
  local lines = {}
  for i = 1, 80 do lines[i] = "line " .. i end
  local body = table.concat(lines, "\n") .. "\n"
  local root = H.git_fixture({ committed = { ["old.txt"] = body } })
  assert(vim.system({ "git", "mv", "old.txt", "new.txt" }, { cwd = root }):wait().code == 0)
  local path = vim.fs.joinpath(root, "new.txt")
  local f = assert(io.open(path, "a")); f:write("worktree tail\n"); f:close()
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false }, virt = { enabled = false } })
    local lens_mod = require("canvasdiff.diff").lens
    local st = assert(fm.open({ lens = lens_mod.get("unstaged") }))
    local canvas_mod = require("canvasdiff.canvas")
    local start0 = canvas_mod.section_rows(st, 1)
    vim.api.nvim_win_set_cursor(st.win, { start0 + 5, 0 })
    local function cursor_identity()
      local row = vim.api.nvim_win_get_cursor(st.win)[1] - 1
      local i, offset = canvas_mod.locate(st, row)
      local section = i and st.sections[i]
      local entry = section and section.entries[offset]
      return section and section.path, entry and entry.content
    end
    H.eq({ cursor_identity() }, { "new.txt", "line 80" },
      "sanity: the cursor begins on a concrete semantic line")
    assert(fm.toggle_stage())
    local staged_i
    for i, section in ipairs(st.sections) do
      if section.path == "new.txt" then staged_i = i end
    end
    assert(staged_i, "rename destination survives into staged lens")
    H.eq({ cursor_identity() }, { "new.txt", "line 80" },
      "stage restores the same content even when the nearest row moved")

    assert(fm.toggle_stage())
    local new_i
    for i, section in ipairs(st.sections) do
      if section.path == "new.txt" then new_i = i end
    end
    assert(new_i, "rename destination fallback survives the reset split")
    H.eq({ cursor_identity() }, { "new.txt", "line 80" },
      "unstage prefers the rename destination and restores its nearest line")
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage follows a deleted rename destination to its reversible deletion"] = function()
  clear_modified_file_buffers()
  local root = H.git_fixture({ committed = { ["old.txt"] = "rename body\n" } })
  assert(vim.system({ "git", "mv", "old.txt", "new.txt" },
    { cwd = root }):wait().code == 0)
  assert(vim.uv.fs_unlink(vim.fs.joinpath(root, "new.txt")))
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local lens_mod = require("canvasdiff.diff").lens
    local st = assert(fm.open({ lens = lens_mod.get("unstaged") }))
    H.eq(st.sections[1].path, "new.txt",
      "sanity: the unstaged deletion is still the rename destination")

    assert(fm.toggle_stage())
    H.eq(st.lens.id, "staged")
    H.eq({ st.sections[1].path, st.sections[1].status },
      { "old.txt", "D" }, "the staged source deletion remains visible")
    local row = vim.api.nvim_win_get_cursor(st.win)[1] - 1
    local section_i = assert(canvas.locate(st, row))
    H.eq(st.sections[section_i].path, "old.txt",
      "the cursor follows the identity rewrite to the rename source")

    assert(fm.toggle_stage())
    local file = assert(source.changed_files(root)[1])
    assert(file.unstaged and not file.staged, vim.inspect(file))
    H.eq({ st.lens.id, st.sections[1].path, st.sections[1].status },
      { "unstaged", "old.txt", "D" },
      "a second press reverses the staged deletion")
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage reverses deletion when a rename source is recreated"] = function()
  clear_modified_file_buffers()
  local root = H.git_fixture({ committed = { ["old.txt"] = "rename body\n" } })
  assert(vim.system({ "git", "mv", "old.txt", "new.txt" },
    { cwd = root }):wait().code == 0)
  local old = assert(io.open(vim.fs.joinpath(root, "old.txt"), "w"))
  old:write("recreated source\n")
  old:close()
  assert(vim.uv.fs_unlink(vim.fs.joinpath(root, "new.txt")))
  in_cwd(root, function(fm)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local lens_mod = require("canvasdiff.diff").lens
    local st = assert(fm.open({ lens = lens_mod.get("unstaged") }))
    local new_i
    for i, section in ipairs(st.sections) do
      if section.path == "new.txt" then new_i = i end
    end
    assert(new_i, "the deleted rename destination is selectable")
    local start0 = canvas.section_rows(st, new_i)
    vim.api.nvim_win_set_cursor(st.win, { start0 + 1, 0 })

    assert(fm.toggle_stage())
    H.eq(st.lens.id, "staged")
    local deletion_i
    for i, section in ipairs(st.sections) do
      if section.path == "old.txt" and section.staged == "D" then
        deletion_i = i
        break
      end
    end
    assert(deletion_i, "the staged source deletion is visible")
    start0 = canvas.section_rows(st, deletion_i)
    vim.api.nvim_win_set_cursor(st.win, { start0 + 1, 0 })

    local real_changed_files = source.changed_files
    source.changed_files = function(...)
      local files, err = real_changed_files(...)
      if files then
        table.sort(files, function(a, b)
          if a.path == b.path then
            return a.unstaged == "?" and b.unstaged ~= "?"
          end
          return a.path < b.path
        end)
      end
      return files, err
    end
    local changed, err = fm.toggle_stage()
    source.changed_files = real_changed_files
    assert(changed, err)
    H.eq(source.show(root, ":0", "old.txt"), "rename body\n",
      "the second cycle unstages the deletion instead of staging recreated bytes")
    H.eq(st.lens.id, "unstaged")
  end)
  vim.fn.delete(root, "rf")
end

T["root_ toggle_stage lifecycle invalidation after Git never refreshes a dead owner"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "disk\n" },
  })
  in_cwd(root, function(fm, msgs)
    fm.setup({ watch = { enabled = false }, sidebar = { enabled = false },
      session = { enabled = false } })
    local st = assert(fm.open())
    local real_stage = source.stage
    source.stage = function(...)
      local ok, err = real_stage(...)
      st.surface:dispose("injected during Git")
      return ok, err
    end
    local changed, err = fm.toggle_stage()
    source.stage = real_stage
    H.eq(changed, nil)
    assert(err and err:find("index changed", 1, true), tostring(err))
    assert(source.changed_files(root)[1].staged)
    assert(msgs[#msgs].msg:find("refresh failed", 1, true), vim.inspect(msgs))
  end)
  vim.fn.delete(root, "rf")
end

local function git(root, args)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  return vim.trim(res.stdout or "")
end

local function picker_fixture()
  local root = H.git_fixture({ committed = { ["a.txt"] = "base\n" } })
  git(root, { "branch", "master" })
  git(root, { "branch", "zeta" })
  git(root, { "update-ref", "refs/remotes/origin/topic", "HEAD" })
  git(root, { "symbolic-ref", "refs/remotes/origin/HEAD",
    "refs/remotes/origin/topic" })
  git(root, { "update-ref", "refs/remotes/upstream/topic", "HEAD" })
  git(root, { "symbolic-ref", "refs/remotes/upstream/HEAD",
    "refs/remotes/upstream/topic" })
  git(root, { "switch", "zeta" })
  return root
end

local function names(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = item.name
  end
  return out
end

local function item_named(items, name)
  for _, item in ipairs(items) do
    if item.name == name then
      return item
    end
  end
  error("missing picker item " .. name .. " in " .. vim.inspect(names(items)))
end

T["root_ compare picker orders metadata choices and cancels silently"] = function()
  local root = picker_fixture()
  in_cwd(root, function(fm, msgs)
    H.eq(fm.command_complete("origin/"), { "origin/HEAD", "origin/topic" },
      "completion inspects the command window's repository")
    H.eq(fm.command_complete("main...up"), {
      "main...upstream/HEAD", "main...upstream/topic",
    }, "range completion preserves the typed left side and operator")
    local before = vim.api.nvim_get_current_buf()
    local real_select = vim.ui.select
    local calls = {}
    vim.ui.select = function(items, opts, callback)
      calls[#calls + 1] = { items = items, opts = opts }
      if #calls == 1 then
        callback(items[1], 1)
      else
        callback(nil, nil)
      end
    end
    local ok, err = xpcall(function()
      fm.compare()
    end, debug.traceback)
    vim.ui.select = real_select
    assert(ok, err)

    H.eq(#calls, 2, "choosing a base opens exactly one comparison prompt")
    H.eq(names(calls[1].items), {
      "origin/HEAD", "upstream/HEAD", "main", "master",
      "origin/topic", "upstream/topic", "zeta",
    }, "base choices prefer remote defaults and conventional local bases")
    H.eq(names(calls[2].items), {
      "zeta", "main", "master", "origin/topic", "upstream/topic",
    }, "comparison choices put the current branch first and exclude remote HEAD")
    H.eq(calls[1].items[1].ref, "refs/remotes/origin/HEAD",
      "picker execution identity is the unambiguous full ref")
    assert(calls[1].opts.format_item(calls[1].items[1]):find(
      "remote default", 1, true), "the symbolic default is labeled")
    assert(calls[2].opts.format_item(calls[2].items[1]):find(
      "current", 1, true), "the current branch is labeled")
    H.eq(vim.api.nvim_get_current_buf(), before,
      "cancelling the second prompt changes no window")
    H.eq(#msgs, 0, "cancellation is silent")

    calls = {}
    vim.ui.select = function(items, opts, callback)
      calls[#calls + 1] = { items = items, opts = opts }
      callback(nil, nil)
    end
    fm.compare()
    H.eq(#calls, 1, "cancelling the base prompt cannot open the second prompt")
    H.eq(vim.api.nvim_get_current_buf(), before)
    H.eq(#msgs, 0, "first-prompt cancellation is silent too")
    vim.ui.select = real_select
  end)
  vim.fn.delete(root, "rf")
end

T["root_ base priority uses full refs when a tag collides with main"] = function()
  local root = picker_fixture()
  git(root, { "tag", "main" })
  in_cwd(root, function(fm)
    local real_select = vim.ui.select
    local calls = {}
    vim.ui.select = function(items, opts, callback)
      calls[#calls + 1] = { items = items, opts = opts, callback = callback }
    end
    local ok, err = xpcall(function() fm.compare() end, debug.traceback)
    vim.ui.select = real_select
    assert(ok, err)
    H.eq(names(calls[1].items), {
      "origin/HEAD", "upstream/HEAD", "heads/main", "master",
      "origin/topic", "upstream/topic", "zeta",
    }, "local main stays ahead of master even when its safe display name changes")
    H.eq(calls[1].items[3].ref, "refs/heads/main")
  end)
  vim.fn.delete(root, "rf")
end

T["root_ detached compare picker synthesizes HEAD as the current choice"] = function()
  local root = picker_fixture()
  git(root, { "switch", "--detach" })
  in_cwd(root, function(fm)
    local real_select = vim.ui.select
    local calls = {}
    vim.ui.select = function(items, opts, callback)
      calls[#calls + 1] = { items = items, opts = opts }
      if #calls == 1 then
        callback(item_named(items, "main"))
      else
        callback(nil, nil)
      end
    end
    local ok, err = xpcall(function() fm.compare() end, debug.traceback)
    vim.ui.select = real_select
    assert(ok, err)
    H.eq(calls[2].items[1], {
      ref = "HEAD", name = "HEAD", kind = "detached", current = true,
    }, "detached HEAD remains selectable even though it has no local branch ref")
  end)
  vim.fn.delete(root, "rf")
end

T["root_ compare from fixed sidebar keeps it and publishes through its canvas host"] =
function()
  local root = picker_fixture()
  local changed = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  changed:write("zeta committed\n")
  changed:close()
  git(root, { "add", "a.txt" })
  git(root, { "commit", "-m", "zeta change" })
  local dirty = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  dirty:write("dirty worktree\n")
  dirty:close()
  local App = require("canvasdiff.App")
  local app = App.new()
  local sidebar = require("canvasdiff.ui").sidebar
  local old_cwd = vim.fn.getcwd()
  local real_select = vim.ui.select
  local real_notify = vim.notify
  local calls, messages = {}, {}
  vim.api.nvim_set_current_dir(root)
  require("canvasdiff.config").setup({
    watch = { enabled = false },
    sidebar = { enabled = true },
    scrollbar = { enabled = false },
    statuscolumn = { enabled = false },
    highlight = { enabled = false },
    virt = { enabled = false },
    session = { enabled = false },
  })
  local st = assert(app:open())
  local surface = assert(app.opened[#app.opened])
  local canvas_win = vim.api.nvim_get_current_win()
  local side_lease = assert(surface.controllers.sidebar)
  local side_win
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if sidebar.is_sidebar_win(side_lease, win) then
      side_win = win
      break
    end
  end
  assert(side_win, "the review opened its fixed sidebar")
  local side_buf = vim.api.nvim_win_get_buf(side_win)
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end

  local ok, err = xpcall(function()
    vim.api.nvim_set_current_win(side_win)
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    calls[2].callback(item_named(calls[2].items, "zeta"))

    H.eq(#app.opened, 1, "the exact originating Surface remains the owner")
    H.eq(app.opened[1], surface)
    H.eq(vim.api.nvim_win_get_buf(side_win), side_buf,
      "the fixed sidebar survives range publication")
    H.eq(vim.api.nvim_win_get_buf(canvas_win), st.buf,
      "the sidebar's existing canvas host displays the committed range")
    H.eq(require("canvasdiff.diff").lens.of(st),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."))
    H.eq(surface.model_epoch, 1,
      "one selection claims and commits the model exactly once")
    H.eq(#messages, 1, "only the committed range emits a diagnostic")
    assert(messages[1].message:find("showing ", 1, true), messages[1].message)
  end, debug.traceback)

  vim.ui.select = real_select
  vim.notify = real_notify
  if vim.api.nvim_win_is_valid(canvas_win) then
    vim.api.nvim_set_current_win(canvas_win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

local function two_surface_app(root)
  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local st_a = assert(app:open())
  local win_a = vim.api.nvim_get_current_win()
  vim.cmd("tabnew")
  local win_b = vim.api.nvim_get_current_win()
  local st_b = assert(app:open())
  return app, st_a, win_a, st_b, win_b, old_cwd
end

local function cleanup_two_surface_app(app, win_a, win_b, old_cwd)
  for _, win in ipairs({ win_b, win_a }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      pcall(function() app:close() end)
    end
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
  end
  vim.api.nvim_set_current_dir(old_cwd)
end

T["root_ delayed picker callbacks retain their exact originating Surface"] = function()
  local root = picker_fixture()
  local app, st_a, win_a, st_b, win_b, old_cwd = two_surface_app(root)
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    vim.api.nvim_set_current_win(win_a)
    app:compare()
    H.eq(#calls, 1)

    vim.api.nvim_set_current_win(win_b)
    calls[1].callback(item_named(calls[1].items, "main"))
    H.eq(#calls, 2)
    calls[2].callback(item_named(calls[2].items, "zeta"))

    H.eq(require("canvasdiff.diff").lens.of(st_a),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."),
      "the delayed choice must pivot the Surface that opened the picker")
    H.eq(require("canvasdiff.diff").lens.of(st_b).id, "all",
      "the currently focused Surface must remain untouched")
  end, debug.traceback)

  vim.ui.select = real_select
  cleanup_two_surface_app(app, win_a, win_b, old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ an unowned picker window cannot redirect into another Surface"] = function()
  local root = picker_fixture()
  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local existing = assert(app:open())
  local existing_win = vim.api.nvim_get_current_win()
  vim.cmd("tabnew")
  local origin_win = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_get_current_buf()
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    calls[2].callback(item_named(calls[2].items, "zeta"))

    H.eq(require("canvasdiff.diff").lens.of(existing).id, "all",
      "the unrelated live review cannot answer for an unowned origin window")
    assert(vim.api.nvim_win_get_buf(origin_win) ~= origin_buf,
      "a successful picker opens its committed review in the origin window")
    local opened = assert(app.opened[#app.opened])
    H.eq(opened.state.root, root)
    H.eq(require("canvasdiff.diff").lens.of(opened.state),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."))
  end, debug.traceback)

  vim.ui.select = real_select
  for _, win in ipairs({ origin_win, existing_win }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      pcall(function() app:close() end)
    end
  end
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ delayed unowned picker keeps its captured repository across cwd drift"] =
function()
  local root = picker_fixture()
  local other = H.git_fixture({
    committed = { ["other.txt"] = "other\n" },
    worktree = { ["other.txt"] = "dirty\n" },
  })
  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local win = vim.api.nvim_get_current_win()
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    vim.api.nvim_set_current_dir(other)
    calls[2].callback(item_named(calls[2].items, "zeta"))
    local opened = assert(app.opened[#app.opened])
    H.eq(opened.state.root, root,
      "async completion uses the repository captured when the picker opened")
    H.eq(require("canvasdiff.diff").lens.of(opened.state),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."))
  end, debug.traceback)

  vim.ui.select = real_select
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  vim.fn.delete(other, "rf")
  assert(ok, err)
end

T["root_ picker from a jump excursion reopens the exact Surface window"] =
function()
  local root = picker_fixture()
  local committed = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  committed:write("zeta committed\n")
  committed:close()
  git(root, { "add", "a.txt" })
  git(root, { "commit", "-m", "zeta change" })
  local file = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  file:write("dirty worktree\n")
  file:close()
  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local st = assert(app:open())
  local surface = assert(app.opened[#app.opened])
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local entered = require("canvasdiff.input").jump.enter(
    surface.excursion, st, { win = win })
  assert(entered.ok, vim.inspect(entered))
  assert(not surface:is_showing(), "the single canvas window is in its file excursion")

  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end
  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    calls[2].callback(item_named(calls[2].items, "zeta"))

    assert(require("canvasdiff.canvas").is_canvas_buf(
      vim.api.nvim_win_get_buf(win)),
      "a successful picker must visibly return the excursion window to a canvas")
    local replacement = assert(app.opened[#app.opened])
    H.eq(replacement.state.root, root)
    H.eq(require("canvasdiff.diff").lens.of(replacement.state),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."))

    local temporary = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(win, temporary)
    app:compare()
    calls[3].callback(item_named(calls[3].items, "main"))
    calls[4].callback(item_named(calls[4].items, "zeta"))
    assert(require("canvasdiff.canvas").is_canvas_buf(
      vim.api.nvim_win_get_buf(win)),
      "selecting the already-active range still republishes the excursion host")
  end, debug.traceback)

  vim.ui.select = real_select
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ failed compare publication restores the prior lens and excursion"] =
function()
  local root = picker_fixture()
  local changed = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  changed:write("zeta committed\n")
  changed:close()
  git(root, { "add", "a.txt" })
  git(root, { "commit", "-m", "zeta change" })
  local dirty = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  dirty:write("dirty worktree\n")
  dirty:close()
  local App = require("canvasdiff.App")
  local app = App.new()
  local canvas_module = require("canvasdiff.canvas")
  local real_show = canvas_module.show
  local real_select = vim.ui.select
  local real_notify = vim.notify
  local old_cwd = vim.fn.getcwd()
  local calls, messages = {}, {}
  vim.api.nvim_set_current_dir(root)
  require("canvasdiff.config").setup({
    watch = { enabled = false },
    sidebar = { enabled = false },
    scrollbar = { enabled = false },
    statuscolumn = { enabled = false },
    highlight = { enabled = false },
    virt = { enabled = false },
    session = { enabled = false },
  })
  local st = assert(app:open())
  local surface = assert(app.opened[#app.opened])
  local win = vim.api.nvim_get_current_win()
  vim.cmd("split")
  local peer_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win)
  local prior_lens = vim.deepcopy(require("canvasdiff.diff").lens.of(st))
  local prior_lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
  local prior_peer_winbar =
    vim.api.nvim_get_option_value("winbar", { win = peer_win })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local entered = require("canvasdiff.input").jump.enter(
    surface.excursion, st, { win = win })
  assert(entered.ok, vim.inspect(entered))
  local excursion_buf = vim.api.nvim_win_get_buf(win)
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    canvas_module.show = function()
      return false
    end
    calls[2].callback(item_named(calls[2].items, "zeta"))

    H.eq(require("canvasdiff.diff").lens.of(st), prior_lens,
      "an unpublishable comparison cannot retain model ownership")
    H.eq(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), prior_lines,
      "an unpublishable comparison restores the prior canvas content")
    H.eq(vim.api.nvim_get_option_value("winbar", { win = peer_win }),
      prior_peer_winbar,
      "a peer canvas host restores the label from before failed publication")
    H.eq(vim.api.nvim_win_get_buf(win), excursion_buf,
      "the originating excursion remains visibly unchanged")
    assert(surface.excursion.excursion,
      "the return path is consumed only after successful publication")
    for _, message in ipairs(messages) do
      assert(not message.message:find("showing ", 1, true),
        "failure cannot announce a committed lens: " .. message.message)
    end
  end, debug.traceback)

  canvas_module.show = real_show
  vim.ui.select = real_select
  vim.notify = real_notify
  if vim.api.nvim_win_is_valid(win) then
    pcall(canvas_module.show, st, win)
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  if vim.api.nvim_win_is_valid(peer_win) then
    pcall(vim.api.nvim_win_close, peer_win, true)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ a newer compare request invalidates every older callback"] = function()
  local root = picker_fixture()
  local app, st_a, win_a, st_b, win_b, old_cwd = two_surface_app(root)
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    vim.api.nvim_set_current_win(win_a)
    app:compare()
    vim.api.nvim_set_current_win(win_b)
    app:compare()
    H.eq(#calls, 2, "both first prompts were issued")

    calls[1].callback(item_named(calls[1].items, "main"))
    H.eq(#calls, 2, "the stale first callback cannot open another prompt")

    calls[2].callback(item_named(calls[2].items, "main"))
    H.eq(#calls, 3)
    calls[3].callback(item_named(calls[3].items, "zeta"))
    H.eq(require("canvasdiff.diff").lens.of(st_a).id, "all")
    H.eq(require("canvasdiff.diff").lens.of(st_b),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."))
  end, debug.traceback)

  vim.ui.select = real_select
  cleanup_two_surface_app(app, win_a, win_b, old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ compare invalidates its predecessor before repository inspection"] = function()
  local root = picker_fixture()
  local app, st_a, win_a, st_b, win_b, old_cwd = two_surface_app(root)
  local source = require("canvasdiff.source")
  local real_branches = source.branches
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    vim.api.nvim_set_current_win(win_a)
    app:compare()
    H.eq(#calls, 1)

    source.branches = function(repo)
      calls[1].callback(item_named(calls[1].items, "main"))
      return real_branches(repo)
    end
    vim.api.nvim_set_current_win(win_b)
    app:compare()
    H.eq(#calls, 2,
      "the old callback reentered during inspection but could not open a prompt")
    H.eq(require("canvasdiff.diff").lens.of(st_a).id, "all")
    H.eq(require("canvasdiff.diff").lens.of(st_b).id, "all")
  end, debug.traceback)

  source.branches = real_branches
  vim.ui.select = real_select
  cleanup_two_surface_app(app, win_a, win_b, old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ watcher collection cannot overwrite a reentrant staged lens"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "head\n" },
    worktree = { ["a.txt"] = "staged\n" },
  })
  git(root, { "add", "a.txt" })
  local file = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  file:write("unstaged\n")
  file:close()
  local App = require("canvasdiff.App")
  local app = App.new()
  local source_module = require("canvasdiff.source")
  local real_sections = source_module.sections
  local canvas_module = require("canvasdiff.canvas")
  local real_reconcile = canvas_module.reconcile_sections
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  require("canvasdiff.config").setup({
    watch = { enabled = true, debounce_ms = 1 },
    sidebar = { enabled = false },
    scrollbar = { enabled = false },
    statuscolumn = { enabled = false },
    highlight = { enabled = false },
    virt = { enabled = false },
    session = { enabled = false },
  })
  local st = assert(app:open())
  local win = vim.api.nvim_get_current_win()
  local collected, reentered, stale_published = false, false, false

  local ok, err = xpcall(function()
    canvas_module.reconcile_sections = function(state, desired)
      if state == st and require("canvasdiff.diff").lens.of(state).id == "staged"
          and desired[1] and desired[1].new_text == "unstaged\n" then
        stale_published = true
      end
      return real_reconcile(state, desired)
    end
    source_module.sections = function(...)
      local desired, collect_err = real_sections(...)
      if not reentered then
        reentered = true
        assert(app:set_lens(require("canvasdiff.diff").lens.get("staged")))
        collected = true
      end
      return desired, collect_err
    end
    vim.api.nvim_exec_autocmds("FocusGained", {})
    assert(vim.wait(1000, function() return collected end, 10),
      "the injected watcher collection reentered a newer staged publication")
    vim.wait(50, function() return false end, 10)

    H.eq(require("canvasdiff.diff").lens.of(st).id, "staged")
    H.eq(stale_published, false,
      "the stale all-lens snapshot never reaches the reconciliation boundary")
    H.eq(st.sections[1].new_text, "staged\n",
      "the model remains content-consistent with the newer staged lens")
    local rendered = table.concat(
      vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), "\n")
    assert(rendered:find("staged", 1, true), rendered)
    assert(not rendered:find("unstaged", 1, true),
      "the stale all-lens watcher snapshot never reaches the buffer")

    source_module.sections = real_sections
    canvas_module.reconcile_sections = real_reconcile
    assert(app:set_lens(require("canvasdiff.diff").lens.get("all")))
    local reconciled = false
    canvas_module.reconcile_sections = function(state, desired)
      if not reconciled and state == st
          and require("canvasdiff.diff").lens.of(state).id == "all"
          and desired[1] and desired[1].new_text == "unstaged\n" then
        reconciled = true
        assert(app:set_lens(require("canvasdiff.diff").lens.get("staged")))
      end
      return real_reconcile(state, desired)
    end
    vim.api.nvim_exec_autocmds("FocusGained", {})
    assert(vim.wait(1000, function() return reconciled end, 10),
      "the watcher reconciliation boundary reentered a newer staged publication")
    vim.wait(50, function() return false end, 10)
    H.eq(require("canvasdiff.diff").lens.of(st).id, "staged")
    H.eq(st.sections[1].new_text, "staged\n",
      "post-reconcile fencing rolls stale watcher content back transactionally")
  end, debug.traceback)

  source_module.sections = real_sections
  canvas_module.reconcile_sections = real_reconcile
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ branch enumeration reentry discards the stale picker list"] = function()
  local root = picker_fixture()
  local App = require("canvasdiff.App")
  local app = App.new()
  local source = require("canvasdiff.source")
  local real_branches = source.branches
  local real_select = vim.ui.select
  local old_cwd = vim.fn.getcwd()
  local calls = {}
  local enumerations = 0
  vim.api.nvim_set_current_dir(root)
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end
  source.branches = function(repo)
    enumerations = enumerations + 1
    if enumerations == 1 then
      app:compare()
    end
    return real_branches(repo)
  end

  local ok, err = xpcall(function()
    app:compare()
    H.eq(#calls, 1,
      "only the newer request may publish a picker after enumeration reentry")
  end, debug.traceback)

  source.branches = real_branches
  vim.ui.select = real_select
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ branch enumeration reentry discards the stale error"] = function()
  local root = picker_fixture()
  local App = require("canvasdiff.App")
  local app = App.new()
  local source = require("canvasdiff.source")
  local real_branches = source.branches
  local real_select = vim.ui.select
  local real_notify = vim.notify
  local old_cwd = vim.fn.getcwd()
  local calls = {}
  local messages = {}
  local enumerations = 0
  vim.api.nvim_set_current_dir(root)
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end
  source.branches = function(repo)
    enumerations = enumerations + 1
    if enumerations == 1 then
      app:compare()
      return nil, "obsolete branch error"
    end
    return real_branches(repo)
  end

  local ok, err = xpcall(function()
    app:compare()
    H.eq(#calls, 1, "the newer request still publishes its picker")
    H.eq(messages, {}, "the stale enumeration error is silent")
  end, debug.traceback)

  source.branches = real_branches
  vim.ui.select = real_select
  vim.notify = real_notify
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ reconcile callback reentry cannot publish the stale range lens"] = function()
  local root = picker_fixture()
  local changed = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  changed:write("zeta committed\n")
  changed:close()
  git(root, { "add", "a.txt" })
  git(root, { "commit", "-m", "zeta change" })
  local App = require("canvasdiff.App")
  local app = App.new()
  local st
  local canvas_module = require("canvasdiff.canvas")
  local real_reconcile = canvas_module.reconcile_sections
  local real_select = vim.ui.select
  local real_notify = vim.notify
  local old_cwd = vim.fn.getcwd()
  local calls = {}
  local messages = {}
  vim.api.nvim_set_current_dir(root)
  st = assert(app:open())
  local win = vim.api.nvim_get_current_win()
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end

  local ok, err = xpcall(function()
    H.eq(#st.sections, 0, "the clean current branch starts empty")
    local before_lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    canvas_module.reconcile_sections = function(state, desired)
      app:compare()
      return real_reconcile(state, desired)
    end
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(#calls, 3, "reconcile reentry starts the newer picker")
    H.eq(require("canvasdiff.diff").lens.of(st).id, "all",
      "the stale range lens is never published")
    H.eq(#st.sections, 0,
      "the real stale reconciliation is rolled back from the model")
    H.eq(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), before_lines,
      "the real stale reconciliation is rolled back from the buffer")
    H.eq(messages, {}, "the stale range emits no success notification")
  end, debug.traceback)

  canvas_module.reconcile_sections = real_reconcile
  vim.ui.select = real_select
  vim.notify = real_notify
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ synchronous newer reconciliation survives stale outer rollback"] =
function()
  local root = picker_fixture()
  local changed = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  changed:write("zeta committed\n")
  changed:close()
  git(root, { "add", "a.txt" })
  git(root, { "commit", "-m", "zeta change" })
  local App = require("canvasdiff.App")
  local app = App.new()
  local canvas_module = require("canvasdiff.canvas")
  local real_reconcile = canvas_module.reconcile_sections
  local real_select = vim.ui.select
  local old_cwd = vim.fn.getcwd()
  local calls = {}
  local auto_select = false
  vim.api.nvim_set_current_dir(root)
  local st = assert(app:open())
  local win = vim.api.nvim_get_current_win()
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
    if auto_select then
      if opts.kind == "canvasdiff_branch_base" then
        callback(item_named(items, "master"))
      else
        callback(item_named(items, "zeta"))
      end
    end
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    local reentered = false
    canvas_module.reconcile_sections = function(state, desired)
      if not reentered then
        reentered = true
        app:compare()
      end
      return real_reconcile(state, desired)
    end
    auto_select = true
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(require("canvasdiff.diff").lens.of(st),
      require("canvasdiff.diff").lens.range(
        "refs/heads/master", "refs/heads/zeta", "..."),
      "the synchronously committed newer picker survives outer rollback")
    local rendered = table.concat(
      vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), "\n")
    assert(rendered:find("zeta committed", 1, true),
      "the canvas retains the newer committed comparison")
  end, debug.traceback)

  canvas_module.reconcile_sections = real_reconcile
  vim.ui.select = real_select
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ synchronous newer same-lens selection survives stale outer rollback"] =
function()
  local root = picker_fixture()
  local changed = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  changed:write("zeta committed\n")
  changed:close()
  git(root, { "add", "a.txt" })
  git(root, { "commit", "-m", "zeta change" })
  local App = require("canvasdiff.App")
  local app = App.new()
  local canvas_module = require("canvasdiff.canvas")
  local real_reconcile = canvas_module.reconcile_sections
  local real_select = vim.ui.select
  local old_cwd = vim.fn.getcwd()
  local calls = {}
  local auto_select = false
  vim.api.nvim_set_current_dir(root)
  local st = assert(app:open())
  local win = vim.api.nvim_get_current_win()
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
    if auto_select then
      if opts.kind == "canvasdiff_branch_base" then
        callback(item_named(items, "main"))
      else
        callback(item_named(items, "zeta"))
      end
    end
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    local reentered = false
    canvas_module.reconcile_sections = function(state, desired)
      if not reentered then
        reentered = true
        app:compare()
      end
      return real_reconcile(state, desired)
    end
    auto_select = true
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(require("canvasdiff.diff").lens.of(st),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."),
      "the newer idempotent-looking selection still commits transactionally")
    H.eq(st.sections[1].new_text, "zeta committed\n",
      "the same-lens nested commit survives outer rollback")
  end, debug.traceback)

  canvas_module.reconcile_sections = real_reconcile
  vim.ui.select = real_select
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ synchronous newer commit during rollback survives obsolete restore"] =
function()
  local root = picker_fixture()
  local changed = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  changed:write("zeta committed\n")
  changed:close()
  git(root, { "add", "a.txt" })
  git(root, { "commit", "-m", "zeta change" })
  local App = require("canvasdiff.App")
  local app = App.new()
  local canvas_module = require("canvasdiff.canvas")
  local real_reconcile = canvas_module.reconcile_sections
  local real_render = canvas_module.render_all
  local real_select = vim.ui.select
  local old_cwd = vim.fn.getcwd()
  local calls = {}
  local pair
  vim.api.nvim_set_current_dir(root)
  local st = assert(app:open())
  local win = vim.api.nvim_get_current_win()
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
    if pair then
      local name = opts.kind == "canvasdiff_branch_base" and pair[1] or pair[2]
      callback(item_named(items, name))
    end
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    local reconciled = false
    canvas_module.reconcile_sections = function(state, desired)
      if not reconciled then
        reconciled = true
        pair = { "master", "zeta" }
        app:compare()
        pair = nil
      end
      return real_reconcile(state, desired)
    end
    local restored = false
    canvas_module.render_all = function(state, sections)
      if not restored then
        restored = true
        pair = { "zeta", "main" }
        app:compare()
        pair = nil
      end
      return real_render(state, sections)
    end
    calls[2].callback(item_named(calls[2].items, "zeta"))

    H.eq(require("canvasdiff.diff").lens.of(st),
      require("canvasdiff.diff").lens.range(
        "refs/heads/zeta", "refs/heads/main", "..."),
      "the request committed during rollback remains the active lens")
    H.eq(#st.sections, 0,
      "obsolete rollback cannot replace the newest empty committed model")
    H.eq(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false),
      { "-- no changes --" },
      "obsolete rollback cannot replace the newest committed buffer")
  end, debug.traceback)

  canvas_module.reconcile_sections = real_reconcile
  canvas_module.render_all = real_render
  vim.ui.select = real_select
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ folded range pivot records the candidate lens during reconciliation"] =
function()
  local root = H.git_fixture({ committed = { ["a.txt"] = "base\n" } })
  git(root, { "branch", "topic" })
  git(root, { "switch", "topic" })
  vim.fn.mkdir(vim.fs.joinpath(root, "nested"), "p")
  local added = assert(io.open(vim.fs.joinpath(root, "nested/new.txt"), "w"))
  added:write("topic\n")
  added:close()
  local topic_change = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  topic_change:write("topic change\n")
  topic_change:close()
  git(root, { "add", "a.txt", "nested/new.txt" })
  git(root, { "commit", "-m", "topic file" })
  git(root, { "switch", "main" })
  local dirty = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  dirty:write("dirty\n")
  dirty:close()

  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local st = assert(app:open())
  local win = vim.api.nvim_get_current_win()

  local ok, err = xpcall(function()
    st.folded["nested/"] = true
    assert(app:set_range("main...topic"))
    local active = require("canvasdiff.diff").lens.of(st)
    local seen = assert(st.folded_seen["nested/new.txt"],
      "the range-only file is born under the existing fold")
    H.eq(seen.lens, active.id,
      "fold staleness records the range being rendered, not the prior lens")
  end, debug.traceback)

  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ Surface construction reentry discards an unowned stale open"] = function()
  local root = picker_fixture()
  local App = require("canvasdiff.App")
  local app = App.new()
  local Surface = require("canvasdiff.Surface")
  local real_new = Surface.new
  local real_select = vim.ui.select
  local session = require("canvasdiff.session")
  local sentinel_lens = require("canvasdiff.diff").lens.get("unstaged")
  local old_cwd = vim.fn.getcwd()
  local calls = {}
  local reentered = false
  vim.api.nvim_set_current_dir(root)
  local win = vim.api.nvim_get_current_win()
  local before = vim.api.nvim_win_get_buf(win)
  session.save({
    root = root,
    lens = sentinel_lens,
    collapsed = {},
    folded = {},
    folded_seen = {},
  })
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end
  Surface.new = function(...)
    if not reentered then
      reentered = true
      app:compare()
    end
    return real_new(...)
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(#calls, 3,
      "Surface construction reentry starts the newer picker synchronously")
    H.eq(#app.opened, 0, "the invalidated open publishes no stale Surface")
    H.eq(vim.api.nvim_win_get_buf(win), before,
      "the invalidated open restores the exact unowned origin buffer")
    H.eq(session.load(root).lens, sentinel_lens,
      "aborting an unpublished Surface cannot persist its stale range")
  end, debug.traceback)

  Surface.new = real_new
  vim.ui.select = real_select
  if #app.opened > 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  os.remove(session.path_for(root))
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ open callback reentry cannot publish a stale Surface"] = function()
  local root = picker_fixture()
  local App = require("canvasdiff.App")
  local app = App.new()
  local canvas_module = require("canvasdiff.canvas")
  local real_open = canvas_module.open
  local real_select = vim.ui.select
  local old_cwd = vim.fn.getcwd()
  local calls = {}
  vim.api.nvim_set_current_dir(root)
  local win = vim.api.nvim_get_current_win()
  local before = vim.api.nvim_win_get_buf(win)
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    canvas_module.open = function(sections, opts)
      app:compare()
      return real_open(sections, opts)
    end
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(#calls, 3, "canvas construction reentry starts the newer picker")
    H.eq(#app.opened, 0, "the stale transaction publishes no Surface")
    H.eq(vim.api.nvim_win_get_buf(win), before,
      "the stale canvas construction restores the origin buffer")
  end, debug.traceback)

  canvas_module.open = real_open
  vim.ui.select = real_select
  if #app.opened > 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ multi-window excursion compare returns the exact origin host"] = function()
  local root = picker_fixture()
  local committed = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  committed:write("zeta committed\n")
  committed:close()
  git(root, { "add", "a.txt" })
  git(root, { "commit", "-m", "zeta committed change" })
  local file = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
  file:write("dirty worktree\n")
  file:close()
  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  local real_select = vim.ui.select
  local calls = {}
  vim.api.nvim_set_current_dir(root)
  local st = assert(app:open())
  local surface = assert(app.opened[#app.opened])
  local origin_win = vim.api.nvim_get_current_win()
  vim.cmd("split")
  local other_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(origin_win)
  vim.api.nvim_win_set_cursor(origin_win, { 1, 0 })
  local entered = require("canvasdiff.input").jump.enter(
    surface.excursion, st, { win = origin_win })
  assert(entered.ok, vim.inspect(entered))
  local excursion_buf = vim.api.nvim_win_get_buf(origin_win)
  assert(surface:is_showing(), "the second host still displays the canvas")
  assert(not canvas.is_canvas_buf(vim.api.nvim_win_get_buf(origin_win)),
    "the origin host is in its excursion")
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    calls[2].callback(item_named(calls[2].items, "zeta"))
    assert(canvas.is_canvas_buf(vim.api.nvim_win_get_buf(origin_win)),
      "selection returns the exact excursion host to its canvas")
    assert(canvas.is_canvas_buf(vim.api.nvim_win_get_buf(other_win)),
      "the other host remains on the shared canvas")
    H.eq(surface.excursion.excursion, nil,
      "presenting a committed range consumes the editable excursion")
    local mapping = vim.api.nvim_buf_call(excursion_buf, function()
      return vim.fn.maparg("<M-CR>", "n", false, true)
    end)
    H.eq(mapping, {}, "the stale return mapping is removed from the file buffer")

    local committed_lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
    vim.api.nvim_win_set_buf(origin_win, excursion_buf)
    H.eq(app:jump_back(surface, surface.generation, origin_win), false,
      "the consumed excursion cannot later rebuild worktree content")
    H.eq(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), committed_lines,
      "the committed range remains observationally unchanged")
    canvas.show(st, origin_win)
  end, debug.traceback)

  vim.ui.select = real_select
  if vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
    pcall(function() app:close() end)
  end
  if vim.api.nvim_win_is_valid(other_win) then
    pcall(vim.api.nvim_win_close, other_win, true)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ unowned picker cannot overwrite another App's replacement"] = function()
  local root = picker_fixture()
  local App = require("canvasdiff.App")
  local first = App.new()
  local second = App.new()
  local old_cwd = vim.fn.getcwd()
  local real_select = vim.ui.select
  local calls = {}
  vim.api.nvim_set_current_dir(root)
  local win = vim.api.nvim_get_current_win()
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local second_state
  local ok, err = xpcall(function()
    first:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    second_state = assert(second:open())
    local second_surface = assert(second.opened[#second.opened])
    local second_buf = second_state.buf
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(#first.opened, 0,
      "the stale unowned request publishes no Surface")
    H.eq(vim.api.nvim_win_get_buf(win), second_buf,
      "the replacement App keeps the exact window")
    assert(second_surface:is_showing(),
      "the replacement Surface remains live and visible")
  end, debug.traceback)

  vim.ui.select = real_select
  if second_state and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() second:close() end)
  end
  if #first.opened > 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() first:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ owned picker rechecks newest request after range collection"] = function()
  local root = picker_fixture()
  local app, st_a, win_a, st_b, win_b, old_cwd = two_surface_app(root)
  local source = require("canvasdiff.source")
  local real_sections = source.sections
  local real_select = vim.ui.select
  local real_notify = vim.notify
  local messages = {}
  local calls = {}
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    vim.api.nvim_set_current_win(win_a)
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    local reentered = false
    source.sections = function(...)
      if not reentered then
        reentered = true
        vim.api.nvim_set_current_win(win_b)
        app:compare()
      end
      return nil, "stale owned collection"
    end
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(#calls, 3, "collection reentry started the newer picker")
    H.eq(require("canvasdiff.diff").lens.of(st_a).id, "all",
      "the stale owned transaction cannot publish after collection")
    H.eq(require("canvasdiff.diff").lens.of(st_b).id, "all")
    H.eq(messages, {}, "a stale collection error is discarded silently")
  end, debug.traceback)

  source.sections = real_sections
  vim.ui.select = real_select
  vim.notify = real_notify
  cleanup_two_surface_app(app, win_a, win_b, old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ unowned picker rechecks newest request after open collection"] = function()
  local root = picker_fixture()
  local App = require("canvasdiff.App")
  local app = App.new()
  local source = require("canvasdiff.source")
  local real_sections = source.sections
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local win = vim.api.nvim_get_current_win()
  local before = vim.api.nvim_win_get_buf(win)
  local real_select = vim.ui.select
  local real_notify = vim.notify
  local messages = {}
  local calls = {}
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
  end

  local ok, err = xpcall(function()
    app:compare()
    calls[1].callback(item_named(calls[1].items, "main"))
    local reentered = false
    source.sections = function(...)
      if not reentered then
        reentered = true
        app:compare()
      end
      return nil, "stale unowned collection"
    end
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(#calls, 3, "open collection reentry started the newer picker")
    H.eq(#app.opened, 0,
      "the stale unowned transaction cannot create a Surface after collection")
    H.eq(vim.api.nvim_win_get_buf(win), before,
      "the stale open changes no window")
    H.eq(messages, {}, "a stale open error is discarded silently")
  end, debug.traceback)

  source.sections = real_sections
  vim.ui.select = real_select
  vim.notify = real_notify
  if #app.opened > 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ reentrant select invalidates the picker it interrupted"] = function()
  local root = picker_fixture()
  local App = require("canvasdiff.App")
  local app = App.new()
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local st = assert(app:open())
  local win = vim.api.nvim_get_current_win()
  local real_select = vim.ui.select
  local calls = {}
  vim.ui.select = function(items, opts, callback)
    calls[#calls + 1] = { items = items, opts = opts, callback = callback }
    if #calls == 1 then
      callback(item_named(items, "main"))
    elseif #calls == 2 then
      -- A UI implementation is allowed to run arbitrary code before returning.
      -- Starting another picker here must invalidate both callbacks above.
      app:compare()
    end
  end

  local ok, err = xpcall(function()
    app:compare()
    H.eq(#calls, 3, "the reentrant request issued its own first prompt")
    calls[2].callback(item_named(calls[2].items, "zeta"))
    H.eq(require("canvasdiff.diff").lens.of(st).id, "all",
      "the interrupted request cannot publish after re-entry")

    calls[3].callback(item_named(calls[3].items, "main"))
    H.eq(#calls, 4)
    calls[4].callback(item_named(calls[4].items, "zeta"))
    H.eq(require("canvasdiff.diff").lens.of(st),
      require("canvasdiff.diff").lens.range(
        "refs/heads/main", "refs/heads/zeta", "..."),
      "the newest request remains live")
  end, debug.traceback)

  vim.ui.select = real_select
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    pcall(function() app:close() end)
  end
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["root_ loader has no init shim and App instances own separate Surfaces"] = function()
  local cached = require("canvasdiff")
  package.loaded["canvasdiff"] = nil
  local reloaded = require("canvasdiff")
  assert(not rawequal(cached, reloaded),
    "manual root eviction reloads a fresh facade and default App")

  package.loaded["canvasdiff.init"] = nil
  local loaded = pcall(require, "canvasdiff.init")
  assert(not loaded, "canvasdiff.init must not remain as a second root loader")

  local App = require("canvasdiff.App")
  local first = App.new()
  local second = App.new()
  assert(not rawequal(first, second), "each App.new() returns a distinct owner")

  -- A review is filed under its own canvas buffer, so a synthetic state gets
  -- a synthetic key. What matters is that the index is per App instance.
  local state = { buf = -1 }
  local surface = require("canvasdiff.Surface").new(state)
  first.surfaces[state.buf] = surface
  first.opened[#first.opened + 1] = surface
  H.eq(first.surfaces[state.buf], surface,
    "a review is indexed by its own canvas buffer on its owning App")
  H.eq(next(second.surfaces), nil, "one App's review cannot leak into another App")
  H.eq(state.surface, surface, "the canvas state names its exact Surface owner")
  H.eq(type(surface.id), "number")
  H.eq(type(surface.generation), "number")
  H.eq(surface.phase, "active")
  H.eq(surface.saved, false)
  H.eq(surface.disposed, false)
  H.eq(type(surface.callbacks), "table")
  assert(surface:is_alive(), "a new Surface is alive")
  assert(not surface:is_showing(), "a Surface without a canvas buffer is hidden")
  assert(surface:guard(surface.generation), "the current generation passes its guard")

  local ui = require("canvasdiff.ui")
  local real_warn = ui.warn
  local warnings = {}
  ui.warn = function(msg)
    warnings[#warnings + 1] = msg
  end

  local ok, err = xpcall(function()
    local refreshed, refresh_err = first:refresh()
    H.eq(refreshed, nil)
    H.eq(refresh_err, "no valid diff canvas",
      "a method reads the Surface stored on its receiver")

    local untouched, untouched_err = second:refresh()
    H.eq(untouched, nil)
    H.eq(untouched_err, nil, "the other receiver still has no state")
    H.eq(warnings, { "no valid diff canvas" },
      "only the App carrying state attempted a refresh")
  end, debug.traceback)

  ui.warn = real_warn
  assert(ok, err)
end

T["root_ setup presents config diagnostics as errors"] = function()
  local fm = require("canvasdiff")
  local real_notify = vim.notify
  local messages = {}
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end

  local ok, err = xpcall(function()
    fm.setup({ glyphs = 42 })
  end, debug.traceback)
  local reset_ok, reset_err = pcall(fm.setup, {})

  vim.notify = real_notify
  assert(ok, err)
  assert(reset_ok, reset_err)
  H.eq(#messages, 1, "one invalid option produces one user-facing diagnostic")
  H.eq(messages[1].level, vim.log.levels.ERROR)
  assert(messages[1].message:find("CanvasDiff: ", 1, true) == 1,
    "the UI owns the plugin prefix: " .. messages[1].message)
  assert(messages[1].message:find("glyphs must be", 1, true),
    "the validation message reaches the user: " .. messages[1].message)
end

T["root_ Surface never issues unqualified controller teardown"] = function()
  local runtime = require("canvasdiff.runtime")
  local watch = runtime.watch
  local hl = require("canvasdiff.ui").highlight
  local sidebar = require("canvasdiff.ui").sidebar
  local scrollbar = require("canvasdiff.ui").scrollbar
  local virt = runtime.virtualizer
  local statuscol = require("canvasdiff.ui").status_column
  local real_stop = watch.stop
  local real_hl_detach = hl.detach
  local real_sidebar_close = sidebar.close
  local real_scrollbar_close = scrollbar.close
  local real_detach = virt.detach
  local real_statuscol_detach = statuscol.detach
  local stops, hl_detaches, sidebar_closes, scrollbar_closes, detaches, statuscol_detaches =
    0, 0, 0, 0, 0, 0
  watch.stop = function(...)
    stops = stops + 1
    return real_stop(...)
  end
  hl.detach = function(...)
    hl_detaches = hl_detaches + 1
    return real_hl_detach(...)
  end
  sidebar.close = function(...)
    sidebar_closes = sidebar_closes + 1
    return real_sidebar_close(...)
  end
  scrollbar.close = function(...)
    scrollbar_closes = scrollbar_closes + 1
    return real_scrollbar_close(...)
  end
  virt.detach = function(...)
    detaches = detaches + 1
    return real_detach(...)
  end
  statuscol.detach = function(...)
    statuscol_detaches = statuscol_detaches + 1
    return real_statuscol_detach(...)
  end

  local ok, err = xpcall(function()
    local state = {}
    local surface = require("canvasdiff.Surface").new(state)
    surface.saved = true
    H.eq(surface.controllers.watch, nil, "this Surface acquired no watch lease")
    H.eq(surface.controllers.hl, nil, "this Surface acquired no highlighter lease")
    H.eq(surface.controllers.sidebar, nil, "this Surface acquired no sidebar lease")
    H.eq(surface.controllers.scrollbar, nil, "this Surface acquired no scrollbar lease")
    H.eq(surface.controllers.virt, nil, "this Surface acquired no virtualizer lease")
    H.eq(surface.controllers.statuscol, nil,
      "this Surface acquired no status-column lease")
    H.eq(surface:dispose("test"), true)
    H.eq(stops, 0,
      "a lease-less owner must not attempt an unqualified watch teardown")
    H.eq(hl_detaches, 0,
      "a lease-less owner must not detach the current highlighter")
    H.eq(sidebar_closes, 0,
      "a lease-less owner must not close the current sidebar")
    H.eq(scrollbar_closes, 0,
      "a lease-less owner must not close any scrollbar")
    H.eq(detaches, 0,
      "a lease-less owner must not attempt an unqualified virtualizer teardown")
    H.eq(statuscol_detaches, 0,
      "a lease-less owner must not detach the current status-column controller")
  end, debug.traceback)

  watch.stop = real_stop
  hl.detach = real_hl_detach
  sidebar.close = real_sidebar_close
  scrollbar.close = real_scrollbar_close
  virt.detach = real_detach
  statuscol.detach = real_statuscol_detach
  assert(ok, err)
end

-- Regression: the root came only from getcwd(), so `nvim path/to/repo/file`
-- from a parent directory refused to open with "not inside a git
-- repository" -- while staring at a file that plainly was in one. It read as
-- the plugin being broken rather than looking in the wrong place.
T["root_ resolves from the current buffer when cwd is not a repo"] = function()
  local root = H.git_fixture({
    committed = { ["f.txt"] = "one\ntwo\n" },
    worktree = { ["f.txt"] = "one\nCHANGED\n" },
  })
  git(root, { "branch", "topic" })
  local parent = vim.fs.dirname(root)

  in_cwd(parent, function(fm)
    vim.cmd.edit(vim.fs.joinpath(root, "f.txt"))
    H.eq(fm.command_complete("topi"), { "topic" },
      "completion uses the same buffer-repository fallback as open")
    fm.open()
    assert(canvas.is_canvas_buf(vim.api.nvim_get_current_buf()),
      "the canvas must open from the buffer's own repo")
    H.eq(shown_files(), { "f.txt" })
  end)
end

-- cwd stays authoritative: in Neovim the cwd is the project, and putting the
-- buffer first would silently switch repos when you opened a file elsewhere.
T["root_ cwd wins over the buffer when both are repos"] = function()
  local a = H.git_fixture({
    committed = { ["in_a.txt"] = "a\n" },
    worktree = { ["in_a.txt"] = "A\n" },
  })
  local b = H.git_fixture({
    committed = { ["in_b.txt"] = "b\n" },
    worktree = { ["in_b.txt"] = "B\n" },
  })

  in_cwd(a, function(fm)
    vim.cmd.edit(vim.fs.joinpath(b, "in_b.txt"))
    fm.open()
    H.eq(shown_files(), { "in_a.txt" }, "the cwd's repo, not the buffer's")
  end)
end

T["root_ neither a repo still warns and opens nothing"] = function()
  local dir = H.tmpdir()
  in_cwd(dir, function(fm, msgs)
    fm.open()
    assert(not canvas.is_canvas_buf(vim.api.nvim_get_current_buf()),
      "nothing should open outside a repo")
    H.eq(#msgs, 1, "exactly one warning")
    H.eq(msgs[1].level, vim.log.levels.WARN)
    assert(msgs[1].msg:match("not inside a git repository"), "got: " .. msgs[1].msg)
    assert(msgs[1].msg:find(dir, 1, true),
      "should name where it looked so the user can see why, got: " .. msgs[1].msg)
  end)
end

-- A scratch/terminal/URI buffer has no meaningful path; it must not be
-- mistaken for one and must not throw.
T["root_ a nameless buffer contributes no path"] = function()
  local dir = H.tmpdir()
  in_cwd(dir, function(fm, msgs)
    vim.cmd("enew") -- no name, no file
    fm.open()
    H.eq(#msgs, 1, "still just the one warning, no error")
    assert(msgs[1].msg:match("not inside a git repository"), "got: " .. msgs[1].msg)
  end)
end

return T
