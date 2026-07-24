local D = {}
local difffn = (vim.text and vim.text.diff) or vim.diff

function D.hunks(old_text, new_text)
  local raw = difffn(old_text, new_text, {
    result_type = "indices", linematch = 60, algorithm = "histogram",
  })
  return raw or {}
end

return D
