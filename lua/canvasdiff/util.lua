local U = {}

function U.list_slice(t, s, e)
  local out = {}
  for i = s, math.min(e, #t) do out[#out + 1] = t[i] end
  return out
end

function U.clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end

--- Byte-exact text of a loaded buffer, as it sits on disk.
---
--- `nvim_buf_get_lines` returns bare lines: Neovim strips `\r` on read and
--- records it in 'fileformat', and it records a missing final newline in
--- 'endofline'. So rejoining with a hardcoded "\n" and appending one silently
--- converts a CRLF file to LF and invents a trailing newline -- and since the
--- old side comes from git verbatim, EVERY line then mismatches and the file
--- renders as a whole-file rewrite. Reconstruct both from the buffer instead.
---
--- 'fixendofline' is deliberately ignored: it only takes effect at write time,
--- and after a write 'endofline' is true anyway.
function U.buf_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    return ""
  end
  local ff = vim.api.nvim_get_option_value("fileformat", { buf = buf })
  local sep = (ff == "dos" and "\r\n") or (ff == "mac" and "\r") or "\n"
  local eol = vim.api.nvim_get_option_value("endofline", { buf = buf })
  return table.concat(lines, sep) .. (eol and sep or "")
end

return U
