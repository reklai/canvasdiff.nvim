local P = {}

--- Run one argv-vector process synchronously and return its completed result.
function P.run(command, opts)
  return vim.system(command, opts):wait()
end

return P
