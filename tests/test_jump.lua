local H = require("helpers")
local git = require("galley.git")
local model = require("galley.model")
local canvas = require("galley.canvas")
local jump = require("galley.jump")
local fold = require("galley.fold")

local function open_fixture(spec)
  local root = H.git_fixture(spec)
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

local function setup_repo()
  return open_fixture({
    committed = { ["a.txt"] = "a1\na2\na3\na4\na5\n", ["b.txt"] = "b1\nb2\n" },
    worktree = { ["a.txt"] = "a1\nA2\na3\na4\na5\n", ["b.txt"] = "b1\nB2\n" },
  })
end

--- N lines, `prefix1..prefixN`, newline-terminated.
local function lines(prefix, n)
  local out = {}
  for i = 1, n do
    out[i] = prefix .. i
  end
  return table.concat(out, "\n") .. "\n"
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
  -- A fold applied from the sidebar while the excursion is live reduces the
  -- excursed section to its single placeholder row. Its entries then no longer
  -- map to buffer rows, so resolving a view against them lands the cursor deep
  -- inside the FOLLOWING files. replace_section already gets this right; the
  -- regression was jump.back overwriting its answer with entry arithmetic.
  ["jump: back onto a section folded away mid-excursion lands on its placeholder"] = function()
    local _, st = open_fixture({
      committed = { ["sub/a.txt"] = lines("l", 40), ["z.txt"] = "z1\nz2\n" },
      worktree = { ["sub/a.txt"] = lines("L", 40), ["z.txt"] = "z1\nZ2\n" },
    })
    H.eq(st.sections[1].path, "sub/a.txt")
    -- Deep into sub/a.txt, so a bad resolve is unmistakably far from row 1.
    local deep = 40
    assert(#st.sections[1].entries > deep, "fixture must be taller than the bad offset")
    vim.api.nvim_win_set_cursor(st.win, { deep, 0 })
    jump.enter(st)

    -- Exactly what sidebar.select's dir branch does, with the canvas off screen.
    st.folded["sub/"] = true
    canvas.resync_visibility(st, fold.indices_under(st.sections, "sub/"))

    jump.back()

    local start0, end0 = canvas.section_rows(st, 1)
    H.eq(end0 - start0, 1, "the folded section must render as one placeholder row")
    local view = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    H.eq(view.lnum, start0 + 1, "cursor must land on the placeholder, not inside z.txt")
    H.eq(view.topline, start0 + 1, "topline must land on the placeholder too")
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
