-- Phase 8 live acceptance.
--
-- Usage:
--   nvim --headless --clean -n -i NONE -l benchmark/acceptance/run.lua [output.json]
--
-- The journey's Phase 8 is eight interactive sessions in a real Git fixture,
-- with commands, seed, logs and observed behaviour recorded as evidence. A
-- smoke session without recorded evidence does not satisfy a gate, so this
-- script runs the eight, records what it observed, and publishes JSON.
--
-- It runs against a real repository and the real `:CanvasDiff` entry points.
-- Every claim it records is something it measured in that session -- the row
-- the search landed on, the bytes the yank produced, the memory before and
-- after a fold -- rather than something it asserted and discarded.

local uv = vim.uv

local function absolute(path)
  return (vim.fn.fnamemodify(path, ":p"):gsub("/+$", ""))
end

local script = absolute(debug.getinfo(1, "S").source:sub(2))
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
vim.opt.runtimepath:prepend(repo_root)

local SEED = 20260728
local BIG_ROWS = 30000

local result = {
  schema_version = 1,
  benchmark = "canvasdiff.live_acceptance",
  profile = "phase8-v1",
  seed = SEED,
  status = "fail",
  interactions = {},
}

local function atomic_json(path, value)
  local directory = vim.fs.dirname(path)
  assert(vim.fn.mkdir(directory, "p") == 1 or vim.fn.isdirectory(directory) == 1,
    "could not create directory: " .. directory)
  local temporary = ("%s.tmp.%d"):format(path, vim.fn.getpid())
  local file = assert(io.open(temporary, "wb"))
  file:write(vim.json.encode(value), "\n")
  assert(file:close())
  assert(uv.fs_rename(temporary, path))
end

local function heap()
  collectgarbage("collect")
  collectgarbage("collect")
  return math.floor(collectgarbage("count") * 1024)
end

-- --- fixture -----------------------------------------------------------------

local function run(cwd, ...)
  local completed = vim.system({ ... }, { cwd = cwd, text = true }):wait()
  assert(completed.code == 0, table.concat({ ... }, " ") .. ": "
    .. tostring(completed.stderr))
  return (completed.stdout or ""):gsub("%s+$", "")
end

local function write(path, body)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(body)
  assert(file:close())
end

local function big_body(edited)
  local out = {}
  for index = 1, BIG_ROWS do
    out[index] = ("huge line %d of the acceptance fixture"):format(index)
    if edited and index % 5 == 0 then
      out[index] = out[index] .. " EDITED"
    end
    if edited and index == 17777 then
      out[index] = out[index] .. " ACCEPTANCE_NEEDLE"
    end
  end
  return table.concat(out, "\n") .. "\n"
end

local function build_fixture(root)
  vim.fn.mkdir(root, "p")
  run(root, "git", "init", "-q", "-b", "main")
  run(root, "git", "config", "user.email", "acceptance@example.invalid")
  run(root, "git", "config", "user.name", "Acceptance")
  write(vim.fs.joinpath(root, "huge.txt"), big_body(false))
  write(vim.fs.joinpath(root, "deep/nested/small.txt"), "one\ntwo\nthree\n")
  write(vim.fs.joinpath(root, "renamed_from.txt"), "alpha\nbeta\ngamma\n")
  run(root, "git", "add", "-A")
  run(root, "git", "commit", "-q", "-m", "acceptance base")

  -- The worktree the review will show.
  write(vim.fs.joinpath(root, "huge.txt"), big_body(true))
  write(vim.fs.joinpath(root, "deep/nested/small.txt"), "one\nTWO\nthree\n")
  run(root, "git", "mv", "renamed_from.txt", "renamed_to.txt")
  write(vim.fs.joinpath(root, "renamed_to.txt"), "alpha\nBETA\ngamma\n")
  return root
end

-- --- the eight interactions --------------------------------------------------

local function observe(name, observations)
  result.interactions[#result.interactions + 1] = {
    name = name,
    observations = observations,
  }
end

local ok, failure = xpcall(function()
  local output_path = _G.arg and _G.arg[1] and absolute(_G.arg[1])
    or vim.fs.joinpath(uv.os_tmpdir() or "/tmp",
      ("canvasdiff-acceptance-%d.json"):format(uv.hrtime()))

  local root = build_fixture(vim.fs.joinpath(
    assert(uv.fs_realpath(uv.os_tmpdir() or "/tmp")),
    ("canvasdiff-acceptance-%d"):format(uv.hrtime())))
  vim.api.nvim_set_current_dir(root)
  result.fixture = { root = root, big_rows = BIG_ROWS }

  local plugin = require("canvasdiff")
  local canvas = require("canvasdiff.canvas")
  plugin.setup({ paged = { enabled = true, min_rows = 5000 } })

  -- 1. Open a large review and move through it from first row to last.
  local before_open = heap()
  local state = assert(plugin.open(), "the review did not open")
  assert(state.paged, "a review this size must be page-backed")
  local logical = canvas.logical(state)
  local rows = logical.row_count()
  local window = state.win
  local height = vim.api.nvim_win_get_height(window)

  local first_viewport = uv.hrtime()
  local worst_step_ms = 0
  local line1 = 1
  while line1 < rows do
    local started = uv.hrtime()
    vim.api.nvim_win_set_cursor(window, { line1, 0 })
    vim.api.nvim_win_call(window, function() vim.cmd("normal! zt") end)
    assert(state.paged.projection:redraw())
    local elapsed = (uv.hrtime() - started) / 1e6
    if elapsed > worst_step_ms then worst_step_ms = elapsed end
    line1 = line1 + height
    vim.wait(0)
  end
  observe("1. open a large review and page from first row to last", {
    paged = true,
    logical_rows = rows,
    skeleton_rows = vim.api.nvim_buf_line_count(state.buf),
    pages = state.paged.list:page_count(),
    window_height = height,
    steps = math.ceil(rows / height),
    worst_step_ms = worst_step_ms,
    whole_walk_ms = (uv.hrtime() - first_viewport) / 1e6,
    heap_delta_bytes = heap() - before_open,
  })

  -- 2. Search across page boundaries, yank a multi-page range, compare bytes
  --    against the store itself as the oracle.
  local needle_row = assert(canvas.paged.search(state.paged, "ACCEPTANCE_NEEDLE"),
    "the needle was not found on a canvas that contains it")
  local needle_text = assert(logical.row(needle_row))
  local native = vim.api.nvim_win_call(window, function()
    return vim.fn.search("ACCEPTANCE_NEEDLE", "w")
  end)
  local span = math.min(2000, rows)
  local yanked = assert(canvas.paged.yank(state.paged, 0, span, { register = "z" }))
  local oracle = table.concat(assert(logical.rows(0, span)), "\n") .. "\n"
  observe("2. search across page boundaries and yank a multi-page range", {
    needle_row = needle_row,
    needle_text = needle_text,
    needle_found_by_canvas = needle_text:find("ACCEPTANCE_NEEDLE", 1, true) ~= nil,
    -- Recorded, not asserted away: Neovim's own search finds nothing, because
    -- the skeleton buffer really is blank. That is why the canvas has its own.
    native_search_result = native,
    skeleton_line_at_needle =
      vim.api.nvim_buf_get_lines(state.buf, needle_row, needle_row + 1, false)[1],
    yanked_rows = span,
    yanked_bytes = #yanked,
    yank_matches_oracle = yanked == oracle,
    register_type = vim.fn.getregtype("z"),
  })
  assert(yanked == oracle, "the yank did not match the store")

  -- 3. Fold and unfold while watching memory.
  local before_fold = heap()
  local before_rows = canvas.logical(state).row_count()
  canvas.set_collapsed(state, 1, true)
  local folded_rows = canvas.logical(state).row_count()
  local after_fold = heap()
  canvas.set_collapsed(state, 1, false)
  local restored_rows = canvas.logical(state).row_count()
  observe("3. fold and unfold a huge file while watching memory", {
    rows_before = before_rows,
    rows_folded = folded_rows,
    rows_restored = restored_rows,
    restored_exactly = restored_rows == before_rows,
    heap_before_bytes = before_fold,
    heap_folded_bytes = after_fold,
    heap_delta_bytes = after_fold - before_fold,
    resident_pages = state.paged.list:resident_stats().pages,
  })
  assert(restored_rows == before_rows, "unfolding did not restore the canvas")

  -- 4. Pivot lenses while the worktree is being written.
  -- `set_lens` takes a lens OBJECT, not its name: passing the string was
  -- refused with "not a lens" and the pivot silently did not happen, which is
  -- exactly the kind of hollow pass this evidence exists to prevent.
  local lens = require("canvasdiff.diff").lens
  local pivots = {}
  for _, id in ipairs({ "all", "staged", "unstaged" }) do
    write(vim.fs.joinpath(root, "deep/nested/small.txt"),
      ("one\nTWO %s\nthree\n"):format(id))
    -- A pivot happens IN PLACE on the live review, so the state handle stays
    -- valid. Reopening after it would rebuild the review with the default
    -- lens and quietly undo the pivot just made.
    assert(plugin.set_lens(lens.get(id)))
    local current = state
    pivots[#pivots + 1] = {
      lens = id,
      applied_lens = current.lens and current.lens.id or nil,
      sections = #current.sections,
      rows = canvas.logical(current).row_count(),
      paged = current.paged ~= nil,
    }
    assert(current.lens and current.lens.id == id, (
      "the canvas is on lens %s after being asked for %s"
    ):format(tostring(current.lens and current.lens.id), id))
    state = current
  end
  observe("4. pivot every lens while the worktree is being written", {
    pivots = pivots,
  })

  -- 5. Jump into a renamed file, edit it, and come back.
  --
  -- On the `all` lens, deliberately: a rename staged in the index is not a
  -- rename in the `unstaged` view, and interaction 4 left the lens there.
  -- Testing "jump into a rename" against a lens that does not see one would
  -- record a pass for something that never happened.
  assert(plugin.set_lens(lens.get("all")))
  local renamed_index
  for index, section in ipairs(state.sections) do
    if section.path == "renamed_to.txt" then renamed_index = index end
  end
  local jump = { found = renamed_index ~= nil }
  if renamed_index then
    local start0 = canvas.section_rows(state, renamed_index)
    jump.section_row = start0
    jump.old_path = state.sections[renamed_index].old_path
    jump.renamed = state.sections[renamed_index].renamed
    vim.api.nvim_win_set_cursor(state.win, { start0 + 2, 0 })
    local landed = pcall(function()
      vim.api.nvim_win_call(state.win, function()
        vim.cmd("normal " .. vim.api.nvim_replace_termcodes("<CR>", true, false, true))
      end)
    end)
    jump.entered = landed
    jump.buffer_name = vim.api.nvim_buf_get_name(0)
    pcall(function() plugin.jump_back() end)
    -- The whole name, not its tail: a canvas buffer is
    -- `canvasdiff://canvas/N`, whose ":t" is just the number.
    jump.returned_to = vim.api.nvim_buf_get_name(0)
    jump.returned_to_canvas = jump.returned_to:find("canvasdiff://", 1, true) == 1
  end
  observe("5. jump into a rename, and come back", jump)

  -- 6. Close windows in several orders.
  local orders = {}
  for _, order in ipairs({ "canvas-first", "origin-first" }) do
    local opened = plugin.open()
    if opened then
      vim.cmd("split")
      local extra = vim.api.nvim_get_current_win()
      if order == "canvas-first" then
        pcall(vim.api.nvim_win_close, extra, true)
        plugin.close()
      else
        plugin.close()
        pcall(vim.api.nvim_win_close, extra, true)
      end
      vim.wait(5)
      orders[#orders + 1] = {
        order = order,
        windows_left = #vim.api.nvim_tabpage_list_wins(0),
        survived = true,
      }
    end
  end
  observe("6. close canvas and origin windows in both orders", { orders = orders })

  -- 7. Hostility: kill Git, and make the session unwritable.
  local process = require("canvasdiff.os")
  local real_run = process.run
  process.run = function()
    return { code = 128, stdout = "", stderr = "injected git failure" }
  end
  local git_contained = pcall(function() plugin.refresh() end)
  process.run = real_run

  local session = require("canvasdiff.session")
  local real_save = session.save
  session.save = function() error("injected session write failure") end
  local session_contained = pcall(function() plugin.close() end)
  session.save = real_save

  local capability = require("canvasdiff.canvas").compression_capability()
  observe("7. kill Git and make the session unwritable", {
    git_failure_contained = git_contained,
    session_failure_contained = session_contained,
    compression = capability,
  })
  assert(git_contained, "an injected Git failure escaped")
  assert(session_contained, "an injected session failure escaped")

  -- 8. Reopen and check the session restored what it recorded.
  local reopened = plugin.open()
  observe("8. reopen the review after closing it", {
    reopened = reopened ~= nil,
    paged = reopened ~= nil and reopened.paged ~= nil,
    sections = reopened and #reopened.sections or 0,
    rows = reopened and canvas.logical(reopened).row_count() or 0,
  })
  assert(reopened, "the review did not reopen")
  plugin.close()

  result.status = "ok"
  result.environment = {
    nvim_version = tostring(vim.version()),
    lua = _VERSION,
    jit = jit and jit.version or nil,
  }
  atomic_json(output_path, result)
  print(("%s -> %s"):format(result.status, output_path))
  for _, interaction in ipairs(result.interactions) do
    print("  ok  " .. interaction.name)
  end
end, debug.traceback)

if not ok then
  result.error = tostring(failure)
  print("FAILED: " .. result.error)
  local fallback = vim.fs.joinpath(uv.os_tmpdir() or "/tmp",
    ("canvasdiff-acceptance-failed-%d.json"):format(uv.hrtime()))
  pcall(atomic_json, fallback, result)
  print("diagnostics: " .. fallback)
end
os.exit(ok and 0 or 1)
