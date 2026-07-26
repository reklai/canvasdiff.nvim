local C = {}

--- Allocate one libuv timer. The caller owns its start/stop/close lifecycle.
function C.new_timer()
  return vim.uv.new_timer()
end

return C
