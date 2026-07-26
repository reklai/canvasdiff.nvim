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

local total, failed = 0, 0
for _, file in ipairs(files) do
  local chunk = assert(loadfile(file))
  local cases = chunk()
  local names = vim.tbl_keys(cases)
  table.sort(names)
  for _, name in ipairs(names) do
    if not pattern or name:find(pattern) then
      total = total + 1
      local ok, err = pcall(cases[name])
      if ok then
        print("PASS " .. name)
      else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
      end
    end
  end
end
print(("%d/%d passed"):format(total - failed, total))
os.exit(failed == 0 and 0 or 1)
