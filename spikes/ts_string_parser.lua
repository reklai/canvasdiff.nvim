-- Spike: can we highlight diff content via get_string_parser + capture copy, fast?
-- PASS: whole-file parse < 100ms; capture extraction for 200 lines + extmark
-- placement into a scratch buffer < 16ms; captures non-empty and plausible.
local N = 5000
local lines = {}
for i = 1, N do
  lines[i] = ("local var_%d = { field = %d, s = 'str_%d' } -- comment %d"):format(i, i, i, i)
end
local content = table.concat(lines, "\n")

local t0 = vim.uv.hrtime()
local parser = vim.treesitter.get_string_parser(content, "lua")
local tree = parser:parse(true)[1]
local parse_ms = (vim.uv.hrtime() - t0) / 1e6

local query = vim.treesitter.query.get("lua", "highlights")
assert(query, "no highlights query for lua")

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_slice(lines, 2000, 2199))
local ns = vim.api.nvim_create_namespace("spike")

local t1 = vim.uv.hrtime()
local nmarks = 0
-- extract captures for source lines 2000-2199 (0-indexed 1999..2199)
for id, node in query:iter_captures(tree:root(), content, 1999, 2199) do
  local sr, sc, er, ec = node:range()
  if er >= 1999 and sr <= 2198 then
    local row = sr - 1999
    if row >= 0 and row < 200 then
      vim.api.nvim_buf_set_extmark(buf, ns, row, sc, {
        end_row = math.min(er - 1999, 199), end_col = ec,
        hl_group = "@" .. query.captures[id] .. ".lua",
        priority = 110, strict = false,
      })
      nmarks = nmarks + 1
    end
  end
end
local extract_ms = (vim.uv.hrtime() - t1) / 1e6

print(("parse: %.1fms (limit 100)  extract+mark 200 lines: %.2fms (limit 16)  marks: %d"):format(
  parse_ms, extract_ms, nmarks))
local ok = parse_ms < 100 and extract_ms < 16 and nmarks > 200
print(ok and "SPIKE PASS" or "SPIKE FAIL")
os.exit(ok and 0 or 1)
