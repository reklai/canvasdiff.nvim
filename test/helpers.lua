local H = {}

--- Absolute path of the repository checkout.
---
--- Derived from this file rather than from each caller, because helpers.lua
--- stays at the test root while test files live in intent-named subdirectories:
--- a caller computing `dirname(dirname(self))` would silently resolve to
--- `test/` the moment it moved one level deeper.
H.project_root = vim.fs.dirname(vim.fs.dirname(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

--- Run `open` in a window of its own, returning its result and that window.
---
--- `canvas.open` shows a review in the CURRENT window, and a review now owns
--- one buffer of its own: a second open in the same window replaces what the
--- first is displaying, and the first review's controllers correctly stop
--- seeing it. A test that wants two LIVE reviews has to give each somewhere to
--- live -- which is exactly what a user does.
function H.in_new_window(open)
  vim.cmd("split")
  local win = vim.api.nvim_get_current_win()
  return open(), win
end

--- Close windows opened by H.in_new_window, newest first, keeping the last one.
function H.close_windows(...)
  for i = select("#", ...), 1, -1 do
    local win = select(i, ...)
    if win and vim.api.nvim_win_is_valid(win)
        and #vim.api.nvim_tabpage_list_wins(0) > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

function H.tmpdir()
  local dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "canvasdiff_test_" .. vim.uv.hrtime())
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

--- Canonical form of a keymap lhs, as nvim_buf_get_keymap reports it.
--- That API case-normalizes modifier notation (`<C-n>` comes back `<C-N>`)
--- while leaving `<CR>`, `<Tab>`, `]f`, `za` and friends untouched, so a
--- literal comparison passes or fails depending on which keys the test
--- happens to use. Put BOTH sides through this.
function H.norm_lhs(lhs)
  return vim.fn.keytrans(vim.keycode(lhs))
end

--- `{[path] = true}` for every collapse the VIRTUALIZER made on its own, read
--- straight off the state that records it (`state.collapsed[path] == "auto"`).
---
--- This is what virt.auto_set() used to return out of a private module table.
--- Intent lives on the state now, so there is nothing to snapshot -- but tests
--- still want to assert on "whose collapse is this", and going through one
--- helper keeps that phrased the same way everywhere.
function H.auto_set(state)
  local out = {}
  for path, intent in pairs(state.collapsed or {}) do
    if intent == "auto" then
      out[path] = true
    end
  end
  return out
end

function H.eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error((msg or "not equal") .. "\nleft:  " .. vim.inspect(a) .. "\nright: " .. vim.inspect(b), 2)
  end
end

return H
