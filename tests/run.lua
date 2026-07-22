-- Run: nvim --headless --clean -l tests/run.lua [name-pattern]
-- Resolve to an absolute path up front: tests may change the process cwd
-- (e.g. via nvim_set_current_dir), and everything below -- runtimepath,
-- package.path, and the test-file glob -- must keep working after that.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local pattern = _G.arg and _G.arg[1] or nil
local files = vim.fn.glob(root .. "/tests/test_*.lua", false, true)
table.sort(files)

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
