local P = {}

-- Every child process is bounded. All of the plugin's Git calls are local,
-- but local is not the same as prompt: an LFS smudge filter, an fsmonitor,
-- or a post-checkout hook can stall on the network, and a bare
-- `vim.system():wait()` freezes the whole UI until the child exits --
-- potentially never. 60s sits far above any healthy local call, so the
-- bound only ever fires on a genuine hang; a caller with a longer-running
-- legitimate job passes its own `timeout`.
local DEFAULT_TIMEOUT_MS = 60000

--- Run one argv-vector process synchronously and return its completed
--- result. On timeout vim.system TERMs the child and reports code 124 (the
--- GNU timeout convention); the reason is appended to stderr so every
--- caller's existing "nonzero exit, show stderr" path reads as "timed out
--- after Nms" instead of an empty mystery.
function P.run(command, opts)
  local bounded = vim.tbl_extend(
    "keep", opts or {}, { timeout = DEFAULT_TIMEOUT_MS })
  local result = vim.system(command, bounded):wait()
  if result and result.code == 124 and result.signal == 15 then
    local reason = ("timed out after %dms"):format(bounded.timeout)
    local stderr = result.stderr
    result.stderr = (stderr and stderr ~= "")
      and (stderr .. "\n" .. reason) or reason
  end
  return result
end

return P
