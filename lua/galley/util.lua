local U = {}
function U.list_slice(t, s, e)
  local out = {}
  for i = s, math.min(e, #t) do out[#out + 1] = t[i] end
  return out
end
function U.clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end
return U
