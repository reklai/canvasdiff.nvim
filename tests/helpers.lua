local H = {}

function H.tmpdir()
  local dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "fm_test_" .. vim.uv.hrtime())
  vim.fn.mkdir(dir, "p")
  return dir
end

local function sh(cwd, cmd)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  return res.stdout
end

function H.git_fixture(spec)
  local root = H.tmpdir()
  sh(root, { "git", "init", "-b", "main" })
  sh(root, { "git", "config", "user.email", "t@t" })
  sh(root, { "git", "config", "user.name", "t" })
  for rel, content in pairs(spec.committed or {}) do
    local abs = vim.fs.joinpath(root, rel)
    vim.fn.mkdir(vim.fs.dirname(abs), "p")
    local f = assert(io.open(abs, "w")); f:write(content); f:close()
  end
  sh(root, { "git", "add", "-A" })
  sh(root, { "git", "commit", "-m", "fixture", "--allow-empty" })
  for rel, content in pairs(spec.worktree or {}) do
    local abs = vim.fs.joinpath(root, rel)
    if content == false then
      vim.fn.delete(abs)
    else
      vim.fn.mkdir(vim.fs.dirname(abs), "p")
      local f = assert(io.open(abs, "w")); f:write(content); f:close()
    end
  end
  return root
end

function H.eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error((msg or "not equal") .. "\nleft:  " .. vim.inspect(a) .. "\nright: " .. vim.inspect(b), 2)
  end
end

return H
