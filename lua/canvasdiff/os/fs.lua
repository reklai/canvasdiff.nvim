local F = {}

--- Read a complete file, or nil when it cannot be opened.
function F.read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local content, read_err = file:read("*a")
  local closed, close_err = file:close()
  assert(content, read_err)
  assert(closed, close_err)
  return content
end

--- Write a complete file, creating its parent directory first.
---
--- Errors intentionally remain exceptions so the owning domain chooses
--- whether persistence failure is fatal or best-effort.
function F.write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  local written, write_err = file:write(content)
  local closed, close_err = file:close()
  assert(written, write_err)
  assert(closed, close_err)
end

--- Allocate one libuv filesystem event handle. Its caller owns the lifecycle.
function F.new_event()
  return vim.uv.new_fs_event()
end

return F
