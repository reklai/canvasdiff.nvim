local H = require("helpers")
local git = require("finding_myself.git")
local model = require("finding_myself.model")
local canvas = require("finding_myself.canvas")
local jump = require("finding_myself.jump")

local function setup_repo()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a1\na2\na3\na4\na5\n", ["b.txt"] = "b1\nb2\n" },
    worktree = { ["a.txt"] = "a1\nA2\na3\na4\na5\n", ["b.txt"] = "b1\nB2\n" },
  })
  local files = {}
  for _, f in ipairs(git.changed_files(root)) do
    files[#files + 1] = {
      path = f.path, status = f.status,
      old_text = git.show_head(root, f.path) or "",
      new_text = table.concat(vim.fn.readfile(vim.fs.joinpath(root, f.path)), "\n") .. "\n",
    }
  end
  local st = canvas.open(model.build(files), {})
  st.root = root
  return root, st
end

return {
  ["jump: enter lands on the corresponding file line"] = function()
    local root, st = setup_repo()
    -- put cursor on the "+A2" line of a.txt (find it)
    local rows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local target
    for i, l in ipairs(rows) do if l == "+A2" then target = i end end
    assert(target, "canvas should contain +A2")
    vim.api.nvim_win_set_cursor(st.win, { target, 0 })
    jump.enter(st)
    H.eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), "a.txt")
    H.eq(vim.api.nvim_win_get_cursor(st.win)[1], 2) -- A2 is line 2
  end,
  ["jump: back after edit regenerates section and restores position"] = function()
    local root, st = setup_repo()
    local rows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local target
    for i, l in ipairs(rows) do if l == "+A2" then target = i end end
    vim.api.nvim_win_set_cursor(st.win, { target, 0 })
    jump.enter(st)
    -- edit the real buffer: add a line after A2 (unsaved)
    vim.api.nvim_buf_set_lines(0, 2, 2, false, { "A2b inserted" })
    jump.back()
    assert(canvas.is_canvas_buf(vim.api.nvim_get_current_buf()), "should be back on canvas")
    local newrows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local found = false
    for _, l in ipairs(newrows) do if l == "+A2b inserted" then found = true end end
    assert(found, "regenerated diff must show the unsaved edit")
    -- cursor is on/near the +A2 line still
    local cur = vim.api.nvim_win_get_cursor(st.win)[1]
    local a2row
    for i, l in ipairs(newrows) do if l == "+A2" then a2row = i end end
    assert(math.abs(cur - a2row) <= 2, ("cursor %d not near +A2 at %d"):format(cur, a2row))
  end,
  ["jump: back with all changes reverted deletes section"] = function()
    local root, st = setup_repo()
    vim.api.nvim_win_set_cursor(st.win, { 4, 0 }) -- somewhere in a.txt section
    jump.enter(st)
    -- revert buffer content to HEAD content
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a1", "a2", "a3", "a4", "a5" })
    jump.back()
    H.eq(#st.sections, 1)
    H.eq(st.sections[1].path, "b.txt")
  end,
}
