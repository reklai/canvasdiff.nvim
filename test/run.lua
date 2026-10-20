-- Run: nvim --headless --clean -l test/run.lua [name-pattern] [suite]
--
-- Test files are grouped by INTENT rather than by owner, because that is what
-- decides how you read a failure: a unit failure is a logic bug, an
-- integration failure is a wiring bug, a fault failure is a lost invariant
-- under injected hostility. `suite` restricts discovery to one such directory;
-- `name-pattern` filters test names within whatever was discovered.
-- Resolve to an absolute path up front: tests may change the process cwd
-- (e.g. via nvim_set_current_dir), and everything below -- runtimepath,
-- package.path, and test-file discovery -- must keep working after that.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
local test_root = vim.fs.joinpath(root, "test")
vim.opt.runtimepath:prepend(root)
package.path = test_root .. "/?.lua;" .. test_root .. "/?/init.lua;" .. package.path

-- Session persistence writes under stdpath("state"); tests must never
-- touch the user's real state dir. Redirect it for this whole process.
local state_dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "canvasdiff_test_state_" .. vim.uv.hrtime())
vim.env.XDG_STATE_HOME = state_dir

-- Neovim 0.13 arms a core file watcher per edited file while 'autoread' is
-- on (runtime/lua/nvim/autoread.lua). This suite edits hundreds of fixture
-- files and then deletes their roots; the accumulated watchers starve the
-- main loop enough that a later test's 500ms vim.wait on a scheduled
-- callback times out (measured: root_ "post-switch collection failure"
-- fails after ~10 predecessor tests with autoread on, 44/44 with it off).
-- The plugin ships its own watch module; core autoread is not under test.
vim.o.autoread = false

local function argument(index)
  local value = _G.arg and _G.arg[index] or nil
  if value == nil or value == "" then
    return nil
  end
  return value
end

local pattern = argument(1)
local suite = argument(2)

local SUITES = {
  architecture = true,
  e2e = true,
  fault = true,
  integration = true,
  performance = true,
  unit = true,
}

if suite then
  assert(SUITES[suite],
    ("unknown suite '%s'; expected one of architecture, e2e, fault, integration, performance, unit")
      :format(suite))
  test_root = vim.fs.joinpath(test_root, suite)
end

local function discover_tests(dir)
  local files = {}

  local function walk(path)
    local scan = vim.uv.fs_scandir(path)
    if not scan then
      -- A declared suite with no directory yet is empty, not broken. An
      -- unknown suite NAME is already rejected above.
      return
    end

    while true do
      local name, kind = vim.uv.fs_scandir_next(scan)
      if not name then
        break
      end

      local child = vim.fs.joinpath(path, name)
      if kind == "directory" then
        walk(child)
      elseif kind == "file" and name:match("^test_.*%.lua$") then
        files[#files + 1] = child
      end
    end
  end

  walk(dir)
  table.sort(files)
  return files
end

local files = discover_tests(test_root)

-- Deprecation is drift that arrives before breakage: core announces a removal
-- through vim.deprecate one or more releases ahead, and for core features it
-- stays SILENT until the hard-deprecation release. Intercepting the call
-- itself turns a nightly run into the early warning -- the suite fails on the
-- first release that deprecates something this repository still calls,
-- rather than on the one that deletes it. Only callers inside this checkout
-- count; Neovim's own runtime deprecating its internals is not our drift.
local deprecations = {}
local real_deprecate = vim.deprecate
vim.deprecate = function(name, alternative, version, plugin, backtrace)
  for level = 2, 40 do
    local info = debug.getinfo(level, "Sl")
    if not info then
      break
    end
    local source = info.source or ""
    if source:sub(1, 1) == "@" and vim.startswith(source:sub(2), root .. "/") then
      local key = ("%s -> %s (removal %s) at %s:%d"):format(
        tostring(name), tostring(alternative), tostring(version),
        source:sub(#root + 3), info.currentline)
      deprecations[key] = true
      break
    end
  end
  return real_deprecate(name, alternative, version, plugin, backtrace)
end

-- A test opts out of a run by RETURNING "skip: <reason>". It is reported as
-- SKIP and counted apart, so a run never claims a pass for work it did not do.
local total, failed, skipped = 0, 0, 0
for _, file in ipairs(files) do
  local chunk = assert(loadfile(file))
  local cases = chunk()
  -- A discovered test_*.lua that registers nothing is a gutted file, not an
  -- empty suite -- fail loudly instead of letting the run shrink under a typo.
  assert(next(cases) ~= nil, file .. " registered no tests")
  local names = vim.tbl_keys(cases)
  table.sort(names)
  for _, name in ipairs(names) do
    if not pattern or name:find(pattern) then
      local ok, err = pcall(cases[name])
      if ok and type(err) == "string" and err:find("^skip: ") then
        skipped = skipped + 1
        print("SKIP " .. name .. " (" .. err:sub(7) .. ")")
      elseif ok then
        total = total + 1
        print("PASS " .. name)
      else
        total = total + 1
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
      end
    end
  end
end
vim.deprecate = real_deprecate
local deprecated = vim.tbl_keys(deprecations)
table.sort(deprecated)
for _, line in ipairs(deprecated) do
  print("DEPRECATED " .. line)
end
print(("%d/%d passed"):format(total - failed, total)
  .. (skipped > 0 and (", %d skipped"):format(skipped) or ""))
if #deprecated > 0 then
  print(("%d deprecated call site(s) on Neovim %s -- the run fails until they move")
    :format(#deprecated, tostring(vim.version())))
  failed = failed + 1
end
-- Sweep the fixtures and the redirected state dir: only what THIS process
-- created, never a glob over the temp dir, so concurrent runs stay apart.
for _, dir in ipairs(require("helpers").tmpdirs) do
  vim.fn.delete(dir, "rf")
end
vim.fn.delete(state_dir, "rf")
-- "0/0 passed" is how a typo'd FILTER or an empty discovery looks; a run that
-- verified nothing must never report green.
if total == 0 then
  print("no tests matched -- check the name-pattern and suite arguments")
  os.exit(1)
end
os.exit(failed == 0 and 0 or 1)
