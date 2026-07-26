-- Run: nvim --headless --clean -l test/run.lua [name-pattern]
-- Resolve to an absolute path up front: tests may change the process cwd
-- (e.g. via nvim_set_current_dir), and everything below -- runtimepath,
-- package.path, and test-file discovery -- must keep working after that.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
local test_root = vim.fs.joinpath(root, "test")
vim.opt.runtimepath:prepend(root)
package.path = test_root .. "/?.lua;" .. test_root .. "/?/init.lua;" .. package.path

-- Session persistence writes under stdpath("state"); tests must never
-- touch the user's real state dir. Redirect it for this whole process.
local state_dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "galley_test_state_" .. vim.uv.hrtime())
vim.env.XDG_STATE_HOME = state_dir

local pattern = _G.arg and _G.arg[1] or nil

local function discover_tests(dir)
  local files = {}

  local function walk(path)
    local scan, err = vim.uv.fs_scandir(path)
    assert(scan, err)

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
