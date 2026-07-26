local T = {}

-- git's own heuristic: it only sniffs the head of a blob for NUL.
local BINARY_SNIFF_BYTES = 8000

--- Does `text` look like binary content?
---
--- A NUL byte is the tell, and it is also what makes binary actively
--- dangerous here rather than merely useless: Vim strings cannot hold NUL, so
--- passing one to a Vimscript function (vim.fn.split, in the word-diff tier)
--- silently converts it to a Blob and throws E976.
function T.is_binary(text)
  if not text or text == "" then
    return false
  end
  return text:sub(1, BINARY_SNIFF_BYTES):find("\0", 1, true) ~= nil
end

return T
