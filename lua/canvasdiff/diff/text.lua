local T = {}

-- git's own heuristic: it only sniffs the head of a blob for NUL.
local BINARY_SNIFF_BYTES = 8000

--- Does `text` look like binary content?
---
--- A NUL byte is the tell. Nothing on the current path passes this content to
--- a Vimscript function, but Vim strings cannot hold NUL -- one that reached
--- such a call would silently become a Blob and throw E976 -- so the sniff also
--- keeps that whole class of failure out of reach.
function T.is_binary(text)
  if not text or text == "" then
    return false
  end
  return text:sub(1, BINARY_SNIFF_BYTES):find("\0", 1, true) ~= nil
end

return T
