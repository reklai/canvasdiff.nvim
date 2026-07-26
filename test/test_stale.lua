-- "This changed since you folded it."
--
-- Detection is a fingerprint COMPARISON (fold.stale), not a flag set from wherever
-- a section happens to be mutated -- because canvas.render_all re-renders a
-- folded section straight into placeholder form without going through resplice
-- or replace_section. So the tests below deliberately drive each distinct mutation
-- path separately: same-path replace (watch's merge-walk), whole-changeset
-- re-render (what App:open and reconcile's 0<->N fallback do), and a section born
-- under a live fold.
local H = require("helpers")
local canvas = require("galley.canvas")
local model = require("galley.model")
local collect = require("galley.collect")
local watch = require("galley.watch")
local virt = require("galley.virt")
local fold = require("galley.fold")

local T = {}

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

local function write_file(root, rel, content)
  local abs = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(vim.fs.dirname(abs), "p")
  local f = assert(io.open(abs, "w"))
  f:write(content)
  f:close()
end

--- Repo with src/a.txt and top.txt committed and both modified in the worktree.
local function open_fixture()
  virt.detach()
  local root = H.git_fixture({
    committed = { ["src/a.txt"] = bigtext(40, "a"), ["top.txt"] = bigtext(40, "t") },
    worktree = {
      ["src/a.txt"] = bigtext(40, "a"):gsub("a line 20", "a line 20 changed"),
      ["top.txt"] = bigtext(40, "t"):gsub("t line 20", "t line 20 changed"),
    },
  })
  local st = canvas.open(model.build(collect.files(root), 3), {})
  st.root = root
  return root, st
end

--- Like open_fixture, but with ~57-row sections (7 separated hunks) -- taller than
--- the ~22-row headless window, so virt's collapse pass actually has a fully
--- out-of-window section to evict.
local function open_tall_fixture()
  virt.detach()
  local function tall(tag)
    local lines = vim.split(bigtext(80, tag), "\n", { plain = true })
    for i = 10, 70, 10 do
      lines[i] = lines[i] .. " changed"
    end
    return table.concat(lines, "\n")
  end
  local root = H.git_fixture({
    committed = { ["src/a.txt"] = bigtext(80, "a"), ["top.txt"] = bigtext(80, "t") },
    worktree = { ["src/a.txt"] = tall("a"), ["top.txt"] = tall("t") },
  })
  local st = canvas.open(model.build(collect.files(root), 3), {})
  st.root = root
  return root, st
end

--- Is section `i` stale right now, asked exactly the way the renderers ask.
local function is_stale(st, i)
  local sec = st.sections[i]
  return fold.stale(st, sec.path, model.fingerprint(sec),
    require("galley.lens").of(st).id)
end

local function index_of(st, path)
  for i, s in ipairs(st.sections) do
    if s.path == path then return i end
  end
end

local function fold_src(st)
  st.folded = { ["src/"] = true }
  canvas.resync_visibility(st)
end

T["stale_ folding records what the file looked like, and nothing is stale yet"] = function()
  local _, st = open_fixture()
  H.eq(st.folded_seen, {}, "nothing folded, nothing remembered")

  fold_src(st)
  local i = index_of(st, "src/a.txt")
  H.eq(st.folded_seen["src/a.txt"],
    { lens = "all", fp = model.fingerprint(st.sections[i]) },
    "folding remembers the content as it went away, and which lens saw it")
  H.eq(st.folded_seen["top.txt"], nil, "and remembers nothing about what stayed visible")
  H.eq(is_stale(st, i), false, "unchanged since you folded it, so not stale")
end

T["stale_ a background edit to a folded-away file marks it"] = function()
  local root, st = open_fixture()
  fold_src(st)

  write_file(root, "src/a.txt",
    bigtext(40, "a"):gsub("a line 20", "a line 20 changed"):gsub("a line 30", "a line 30 too"))
  watch.reconcile(st)

  local i = index_of(st, "src/a.txt")
  H.eq(is_stale(st, i), true, "the file moved on while it was folded")
  H.eq(is_stale(st, index_of(st, "top.txt")), false, "the visible file is not 'stale', it is just there")
end

-- The path a flag-set-from-replace_section design would have missed entirely:
-- render_all rebuilds every section with no resplice and no replace_section.
T["stale_ a whole-changeset re-render marks it too"] = function()
  local root, st = open_fixture()
  fold_src(st)

  write_file(root, "src/a.txt",
    bigtext(40, "a"):gsub("a line 20", "a line 20 changed"):gsub("a line 30", "a line 30 too"))
  -- render_all is still reached by App:open and by reconcile_sections' 0<->N fallback,
  -- so this path is live even though no keymap invokes it directly any more.
  -- (App:refresh reconciles instead, which is why it keeps your place.)
  canvas.render_all(st, model.build(collect.files(root), 3))

  local i = index_of(st, "src/a.txt")
  H.eq((select(2, canvas.section_rows(st, i))) - (canvas.section_rows(st, i)), 1,
    "sanity: still rendered as its placeholder after the re-render")
  H.eq(is_stale(st, i), true, "a full re-render is a change like any other")
end

T["stale_ a file born under a live fold is stale, having never been seen"] = function()
  local root, st = open_fixture()
  fold_src(st)

  write_file(root, "src/new.txt", bigtext(40, "n"))
  watch.reconcile(st)

  local i = index_of(st, "src/new.txt")
  assert(i, "sanity: the new file joined the canvas")
  H.eq(st.folded_seen["src/new.txt"], { lens = "all", fp = false },
    "recorded as sight-unseen")
  H.eq(is_stale(st, i), true, "you have never seen it, so it is not what you reviewed")
end

T["stale_ bringing it back clears the mark for good"] = function()
  local root, st = open_fixture()
  fold_src(st)
  write_file(root, "src/a.txt",
    bigtext(40, "a"):gsub("a line 20", "a line 20 changed"):gsub("a line 30", "a line 30 too"))
  watch.reconcile(st)
  H.eq(is_stale(st, index_of(st, "src/a.txt")), true, "sanity: stale before we look at it")

  -- Unfold: the file is on screen, so it has been seen.
  st.folded = {}
  canvas.resync_visibility(st)
  H.eq(st.folded_seen["src/a.txt"], nil, "the fingerprint is dropped once it is visible")
  H.eq(is_stale(st, index_of(st, "src/a.txt")), false, "and it is not stale")

  -- Re-fold: it must not come back marked, because you did look at it.
  fold_src(st)
  H.eq(is_stale(st, index_of(st, "src/a.txt")), false,
    "re-folding something you have seen starts it clean")
end

T["stale_ resyncing an unrelated fold does not re-see a stale file"] = function()
  local root, st = open_fixture()
  fold_src(st)
  write_file(root, "src/a.txt",
    bigtext(40, "a"):gsub("a line 20", "a line 20 changed"):gsub("a line 30", "a line 30 too"))
  watch.reconcile(st)
  local before = st.folded_seen["src/a.txt"]

  -- A fold elsewhere resplices EVERY section; the stale one must keep the
  -- fingerprint it went away with rather than quietly adopting its new content.
  st.folded["nonexistent/"] = true
  canvas.resync_visibility(st)
  H.eq(st.folded_seen["src/a.txt"], before, "the remembered fingerprint is not refreshed")
  H.eq(is_stale(st, index_of(st, "src/a.txt")), true, "so it is still stale")
end

T["stale_ the canvas placeholder and the sidebar row both show it"] = function()
  local root, st = open_fixture()
  local sidebar = require("galley.sidebar")
  local render = require("galley.render")
  sidebar.close()
  sidebar.open(st, { width = 30 })
  fold_src(st)
  sidebar.refresh(st) -- fold_src only drives the canvas; the real path is S.select

  local function canvas_row(i)
    local s = (canvas.section_rows(st, i))
    return vim.api.nvim_buf_get_lines(st.buf, s, s + 1, false)[1]
  end
  local function tree()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b)
        and vim.api.nvim_buf_get_name(b):find("galley://sidebar", 1, true) then
        return vim.api.nvim_buf_get_lines(b, 0, -1, false)
      end
    end
  end

  local i = index_of(st, "src/a.txt")
  assert(not canvas_row(i):find(render.glyphs.stale, 1, true),
    "sanity: nothing stale yet: " .. canvas_row(i))
  H.eq(tree()[1], "▸ src/", "sanity: the folded dir row is unmarked")

  write_file(root, "src/a.txt",
    bigtext(40, "a"):gsub("a line 20", "a line 20 changed"):gsub("a line 30", "a line 30 too"))
  watch.reconcile(st, {
    on_change = function(state)
      sidebar.refresh(state)
    end,
  })

  i = index_of(st, "src/a.txt")
  local row = canvas_row(i)
  H.eq(row, render.placeholder(st.sections[i], true),
    "the placeholder carries the marker, after the counts")
  assert(row:match("^▸ src/a%.txt"), "and the ▸ gutter is untouched: " .. row)
  H.eq(tree()[1], "▸ src/ ●", "the folded dir row says something under it moved on")

  -- Bring it back: both markers must go.
  st.folded = {}
  canvas.resync_visibility(st)
  sidebar.refresh(st)
  i = index_of(st, "src/a.txt")
  assert(not canvas_row(i):find(render.glyphs.stale, 1, true), "expanded, so nothing to mark")
  for _, line in ipairs(tree()) do
    assert(not line:find(render.glyphs.stale, 1, true), "tree is clean too: " .. line)
  end
  sidebar.close()
end

-- The marker is a real character in the buffer, so it inherits whatever the row is
-- painted with unless something highlights just it. In the canvas that row is a
-- full-width GalleyFileHeader with hl_eol, so the marker's mark has to be
-- col-ranged and win on priority.
T["stale_ the marker is highlighted, in the canvas and in the tree"] = function()
  local root, st = open_fixture()
  local sidebar = require("galley.sidebar")
  local render = require("galley.render")
  sidebar.close()
  sidebar.open(st, { width = 30 })
  fold_src(st)

  write_file(root, "src/a.txt",
    bigtext(40, "a"):gsub("a line 20", "a line 20 changed"):gsub("a line 30", "a line 30 too"))
  watch.reconcile(st, {
    on_change = function(state)
      require("galley.hl").apply_now(state)
      sidebar.refresh(state)
    end,
  })

  --- The GalleyStale mark on `row0` of `buf` in `ns`, as {start_col, end_col}.
  local function stale_span(buf, ns, row0)
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[2] == row0 and m[4] and m[4].hl_group == "GalleyStale" then
        return { m[3], m[4].end_col }
      end
    end
  end

  local i = index_of(st, "src/a.txt")
  local srow = (canvas.section_rows(st, i))
  local line = vim.api.nvim_buf_get_lines(st.buf, srow, srow + 1, false)[1]
  local canvas_ns = vim.api.nvim_create_namespace("galley.canvas.hl")
  H.eq(stale_span(st.buf, canvas_ns, srow), { #line - #render.glyphs.stale, #line },
    "the canvas marker is highlighted, and only the marker")

  local sbuf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b)
      and vim.api.nvim_buf_get_name(b):find("galley://sidebar", 1, true) then sbuf = b end
  end
  local srows = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
  H.eq(srows[1], "▸ src/ ●", "sanity: the folded dir row is marked")
  local side_ns = vim.api.nvim_create_namespace("galley.sidebar")
  H.eq(stale_span(sbuf, side_ns, 0), { #srows[1] - #render.glyphs.stale, #srows[1] },
    "and so is the tree's")

  -- Once it comes back, the highlight must go with the text.
  st.folded = {}
  canvas.resync_visibility(st)
  sidebar.refresh(st)
  i = index_of(st, "src/a.txt")
  H.eq(stale_span(st.buf, canvas_ns, (canvas.section_rows(st, i))), nil,
    "no marker, no highlight")
  sidebar.close()
end

-- The fingerprint hashes new_text ONLY (deliberately, so changing the diff base
-- doesn't fake a change), which already immunises the all <-> unstaged pivot: those
-- differ only in their OLD side. The `staged` lens is the one that moves the NEW side
-- from the worktree to the index, so it is the only pivot that can misfire -- and
-- without scoping it reports every folded file as changed.
T["stale_ pivoting to the staged lens does not fake a change"] = function()
  local lens = require("galley.lens")
  local root = H.git_fixture({
    committed = { ["src/a.txt"] = bigtext(40, "a"), ["top.txt"] = bigtext(40, "t") },
  })
  local function write(rel, b)
    local abs = vim.fs.joinpath(root, rel)
    local f = assert(io.open(abs, "w")); f:write(b); f:close()
  end
  local function sh(c) assert(vim.system(c, { cwd = root }):wait().code == 0) end
  -- src/a.txt: staged one way, worktree another, so every lens sees it differently.
  write("src/a.txt", bigtext(40, "a"):gsub("a line 10", "a line 10 staged"))
  sh({ "git", "add", "src/a.txt" })
  write("src/a.txt", bigtext(40, "a"):gsub("a line 10", "a line 10 worktree"))
  write("top.txt", bigtext(40, "t"):gsub("t line 10", "t line 10 changed"))

  local function open_with(l)
    local st = canvas.open(model.build(collect.files(root, l), 3), {})
    st.root, st.lens, st.base = root, l, lens.to_base(l)
    return st
  end

  local st = open_with(lens.get("all"))
  fold_src(st)
  local i = index_of(st, "src/a.txt")
  H.eq(is_stale(st, i), false, "sanity: nothing stale yet")
  local seen_all = st.folded_seen["src/a.txt"]
  assert(seen_all, "sanity: the fold recorded a fingerprint")

  -- Pivot to the STAGED lens, carrying the review state across.
  local folded_seen, folded = st.folded_seen, st.folded
  local st2 = open_with(lens.get("staged"))
  st2.folded_seen, st2.folded = folded_seen, folded
  canvas.resync_visibility(st2)
  local j = index_of(st2, "src/a.txt")
  -- The NEW side is what the fingerprint keys on, so this is the assertion that
  -- makes the test actually exercise the hazard.
  assert(st2.sections[j].new_text ~= st.sections[i].new_text,
    "sanity: the staged lens really does show a different NEW side")
  H.eq(is_stale(st2, j), false,
    "a lens pivot is not an edit -- the marker must stay silent")

  -- A worktree edit is INVISIBLE in the staged lens, and correctly so: the new
  -- side is the index, which a worktree write does not touch.
  write("src/a.txt", bigtext(40, "a"):gsub("a line 20", "a line 20 worktree only"))
  watch.reconcile(st2)
  H.eq(is_stale(st2, index_of(st2, "src/a.txt")), false,
    "the staged lens does not see worktree edits, so nothing has changed in it")

  -- Within the staged lens, though, the marker still has to work. Capture a
  -- staged-lens fingerprint, then move the index underneath it.
  st2.folded_seen = {}
  canvas.resync_visibility(st2)
  local recorded = st2.folded_seen["src/a.txt"]
  H.eq(recorded.lens, "staged", "the fingerprint records the lens that took it")

  sh({ "git", "add", "src/a.txt" }) -- the index really does move now
  watch.reconcile(st2)
  H.eq(is_stale(st2, index_of(st2, "src/a.txt")), true,
    "a change to the index IS a change in the staged lens")

  vim.fn.delete(root, "rf")
end

T["stale_ the virtualizer's own collapses are never fingerprinted"] = function()
  local _, st = open_tall_fixture()
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  local lease = virt.attach(st, { enabled = false })
  virt.apply(lease, { enabled = true, max_files = 1, max_lines = 0, margin = 0, max_expanded = 1 })

  local auto = H.auto_set(st)
  assert(next(auto), "sanity: virt auto-collapsed something")
  for path in pairs(auto) do
    H.eq(st.folded_seen[path], nil,
      "virt's bookkeeping was never a decision the user made, so it cannot go stale: " .. path)
    H.eq(fold.stale(st, path, "ANYTHING"), false, "and fold.stale agrees")
  end
  virt.detach(lease)
end

return T
