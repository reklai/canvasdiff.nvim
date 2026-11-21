local H = require("helpers")
local ui = require("canvasdiff.ui")

local T = {}

local function numbered(prefix, n, edits)
  local out = {}
  for i = 1, n do
    out[i] = edits and edits[i] or ("%s_%d"):format(prefix, i)
  end
  return table.concat(out, "\n") .. "\n"
end

local function in_review(root, setup, fn)
  local old_cwd = vim.fn.getcwd()
  local real_notify = vim.notify
  local notes = {}
  vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.setup(vim.tbl_deep_extend("force", {
    watch = { enabled = false }, sidebar = { enabled = false },
    scrollbar = { enabled = false }, statuscolumn = { enabled = false },
    highlight = { enabled = false }, virt = { enabled = false },
    session = { enabled = false },
  }, setup or {}))
  local ok, err = xpcall(function() fn(fm, notes) end, debug.traceback)
  pcall(fm.close)
  ui.hunk_peek.close()
  vim.notify = real_notify
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  require("canvasdiff.config").setup({})
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["escape_hatches gy yanks deleted ghost lines into the unnamed register"] = function()
  local root = H.git_fixture({
    committed = {
      ["a.lua"] = "local top = 1\nlocal old_one = 10\nlocal old_two = 20\nlocal bot = 2\n",
    },
    worktree = {
      ["a.lua"] = "local top = 1\nlocal new_one = 99\nlocal bot = 2\n",
    },
  })

  in_review(root, nil, function(fm)
    local st = assert(fm.open())
    local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
    local hdr_row, add_row, bot_row
    for idx, l in ipairs(lines) do
      if l:match("^@@") then hdr_row = idx end
      if l:find("local new_one = 99", 1, true) then add_row = idx end
      if l:find("local bot = 2", 1, true) then bot_row = idx end
    end
    assert(hdr_row and add_row and bot_row, "sanity: hunk rows present")

    -- On the added line carrying `old_one` as a ghost above it:
    vim.api.nvim_win_set_cursor(st.win, { add_row, 0 })
    vim.fn.setreg('"', "")
    vim.cmd("normal gy")
    H.eq(vim.fn.getreg('"'), "local old_one = 10\n",
      "gy on a ghost-carrying row yanks its attached deleted lines")

    -- On `bot` carrying `old_two` as a ghost above it:
    vim.api.nvim_win_set_cursor(st.win, { bot_row, 0 })
    vim.fn.setreg('"', "")
    vim.cmd("normal gy")
    H.eq(vim.fn.getreg('"'), "local old_two = 20\n",
      "gy on the next carrier row yanks its ghost")

    -- On the hunk header `@@`: yanks every deleted line in the hunk!
    vim.api.nvim_win_set_cursor(st.win, { hdr_row, 0 })
    vim.fn.setreg('"', "")
    vim.cmd("normal gy")
    H.eq(vim.fn.getreg('"'), "local old_one = 10\nlocal old_two = 20\n",
      "gy on the hunk header yanks every deleted line of the hunk")
  end)
end

T["escape_hatches K opens word-diff peek with real -/+ lines, closes on q and on canvas close"] = function()
  local root = H.git_fixture({
    committed = {
      ["cfg.lua"] = "local host = 'localhost'\nlocal port = 8080\nlocal tls = false\n",
    },
    worktree = {
      ["cfg.lua"] = "local host = 'localhost'\nlocal port = 9090\nlocal tls = false\n",
    },
  })

  in_review(root, nil, function(fm)
    local st = assert(fm.open())
    local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
    local add_row
    for idx, l in ipairs(lines) do
      if l:find("port = 9090", 1, true) then add_row = idx end
    end
    assert(add_row)
    vim.api.nvim_win_set_cursor(st.win, { add_row, 0 })

    -- Open hunk peek with K.
    vim.cmd("normal K")
    H.eq(ui.hunk_peek.is_open(), true, "K opened the word-diff peek float")
    local peek_buf = vim.api.nvim_get_current_buf()
    local peek_lines = vim.api.nvim_buf_get_lines(peek_buf, 0, -1, false)
    assert(vim.iter(peek_lines):any(function(l) return l == "-local port = 8080" end),
      "old deleted line is a real buffer row inside the peek: " .. vim.inspect(peek_lines))
    assert(vim.iter(peek_lines):any(function(l) return l == "+local port = 9090" end),
      "new added line is a real buffer row inside the peek")

    -- Verify word-diff extmarks exist in the peek buffer.
    local ns = vim.api.nvim_get_namespaces()["canvasdiff.hunk_peek"]
    assert(ns, "hunk_peek namespace exists")
    local marks = vim.api.nvim_buf_get_extmarks(peek_buf, ns, 0, -1, { details = true })
    local word_groups = {}
    for _, m in ipairs(marks) do
      local g = m[4] and m[4].hl_group
      if g == "CanvasDiffWordAdd" or g == "CanvasDiffWordDel" then
        word_groups[g] = true
      end
    end
    H.eq(word_groups.CanvasDiffWordDel, true, "old token highlighted")
    H.eq(word_groups.CanvasDiffWordAdd, true, "new token highlighted")

    -- Close via q.
    vim.cmd("normal q")
    H.eq(ui.hunk_peek.is_open(), false, "q closed the peek float")
    H.eq(vim.api.nvim_get_current_buf(), st.buf, "focus returned to canvas")

    -- Re-open and confirm closing the canvas closes the peek too.
    vim.cmd("normal K")
    H.eq(ui.hunk_peek.is_open(), true)
    fm.close()
    H.eq(ui.hunk_peek.is_open(), false, "closing canvas disposes hunk peek")
  end)
end

T["escape_hatches > and < expand and shrink per-file context inline without jumping"] = function()
  local root = H.git_fixture({
    committed = {
      ["long.lua"] = numbered("line", 30),
      ["other.lua"] = numbered("other", 30),
    },
    worktree = {
      ["long.lua"] = numbered("line", 30, { [15] = "line_15_EDITED" }),
      ["other.lua"] = numbered("other", 30, { [15] = "other_15_EDITED" }),
    },
  })

  in_review(root, nil, function(fm)
    local st = assert(fm.open())
    H.eq(st.sections[1].path, "long.lua")
    local initial_rows = #st.sections[1].entries
    local other_rows = #st.sections[2].entries

    -- Expand context on long.lua (`>`): adds +5 lines above and +5 below (+10 rows).
    vim.api.nvim_win_set_cursor(st.win, { 3, 0 })
    vim.cmd("normal >")
    H.eq(st.section_context["long.lua"], 8)
    H.eq(#st.sections[1].entries, initial_rows + 10, "long.lua gained 5 context lines on each side")
    H.eq(#st.sections[2].entries, other_rows, "other.lua context stayed untouched")

    -- Refresh preserves the per-file context override!
    assert(fm.refresh())
    H.eq(#st.sections[1].entries, initial_rows + 10, "refresh keeps per-file expanded context")

    -- Shrink context back (`<`): restores default context and clears override.
    vim.cmd("normal <")
    H.eq(st.section_context["long.lua"], nil, "returning to baseline clears override")
    H.eq(#st.sections[1].entries, initial_rows, "long.lua returned to baseline row count")
  end)
end

return T
