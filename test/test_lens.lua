local H = require("helpers")
local lens = require("canvasdiff.diff").lens
local source = require("canvasdiff.source")

local T = {}

--- A repo where a.txt is PARTLY staged: HEAD has "one", the index has "two",
--- the worktree has "three". Each lens must see a different pair.
local function partly_staged()
  local root = H.git_fixture({ committed = { ["a.txt"] = "one\n" } })
  local function sh(c) assert(vim.system(c, { cwd = root }):wait().code == 0) end
  local function write(body)
    local f = assert(io.open(vim.fs.joinpath(root, "a.txt"), "w"))
    f:write(body); f:close()
  end
  write("two\n")
  sh({ "git", "add", "a.txt" })  -- index now holds "two"
  write("three\n")               -- worktree now holds "three"
  return root
end

local function only(root, spec)
  local files = source.files(root, spec)
  H.eq(#files, 1, "fixture has exactly one changed file")
  return files[1]
end

-- The assertion Step 1 exists for: three lenses, three genuinely different diffs
-- over the same file. Before this, "staged" could not be expressed at all -- the
-- new side was hardwired to the worktree.
T["lens_collect each lens reads its own pair of sides"] = function()
  local root = partly_staged()

  local all = only(root, lens.get("all"))
  H.eq(all.old_text, "one\n", "all: old side is HEAD")
  H.eq(all.new_text, "three\n", "all: new side is the worktree")

  local unstaged = only(root, lens.get("unstaged"))
  H.eq(unstaged.old_text, "two\n", "unstaged: old side is the index")
  H.eq(unstaged.new_text, "three\n", "unstaged: new side is the worktree")

  local staged = only(root, lens.get("staged"))
  H.eq(staged.old_text, "one\n", "staged: old side is HEAD")
  H.eq(staged.new_text, "two\n", "staged: new side is the INDEX, not the worktree")

  vim.fn.delete(root, "rf")
end

T["lens_collect still accepts the legacy base string"] = function()
  local root = partly_staged()
  H.eq(only(root, "index").old_text, "two\n", "\"index\" means the unstaged lens")
  H.eq(only(root, "HEAD").old_text, "one\n", "\"HEAD\" means the all lens")
  H.eq(only(root, nil).old_text, "one\n", "nil defaults to everything")
  vim.fn.delete(root, "rf")
end

-- Unsaved buffer content is the thing no other whole-changeset tool can see, and
-- it must survive the lens refactor.
T["lens_collect a worktree new side still prefers unsaved buffer content"] = function()
  local root = partly_staged()
  local abs = vim.fs.joinpath(root, "a.txt")
  vim.cmd("edit " .. vim.fn.fnameescape(abs))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })

  H.eq(only(root, lens.get("all")).new_text, "unsaved\n",
    "the worktree side reads the live buffer, not the disk")
  H.eq(only(root, lens.get("staged")).new_text, "two\n",
    "but the index side is git's, and an unsaved buffer cannot change it")

  vim.cmd("bwipeout!")
  vim.fn.delete(root, "rf")
end

T["lens_collect a staged rename has distinct all staged and unstaged identities"] = function()
  local root = H.git_fixture({ committed = { ["old.txt"] = "same\n" } })
  local res = vim.system({ "git", "mv", "old.txt", "new.txt" },
    { cwd = root, text = true }):wait()
  assert(res.code == 0, res.stderr)
  local f = assert(io.open(vim.fs.joinpath(root, "new.txt"), "w"))
  f:write("worktree edit\n")
  f:close()

  local all = only(root, lens.get("all"))
  H.eq({
    all.path, all.old_path, all.old_rev, all.status,
    all.old_text, all.new_text,
  }, {
    "new.txt", "old.txt", "HEAD", "R",
    "same\n", "worktree edit\n",
  }, "all sees the complete HEAD-to-worktree rename and edit")

  local staged = only(root, lens.get("staged"))
  H.eq({
    staged.path, staged.old_path, staged.old_rev, staged.status,
    staged.old_text, staged.new_text,
  }, {
    "new.txt", "old.txt", "HEAD", "R",
    "same\n", "same\n",
  }, "staged sees the source-to-index-destination pure rename")

  local unstaged = only(root, lens.get("unstaged"))
  H.eq({
    unstaged.path, unstaged.old_path, unstaged.old_rev, unstaged.status,
    unstaged.old_text, unstaged.new_text,
  }, {
    "new.txt", "new.txt", ":0", "M",
    "same\n", "worktree edit\n",
  }, "unstaged addresses both sides at the destination and sees only the later edit")

  local all_section = assert(source.sections(root, lens.get("all"), 3)[1])
  local staged_section = assert(source.sections(root, lens.get("staged"), 3)[1])
  local unstaged_section = assert(source.sections(root, lens.get("unstaged"), 3)[1])
  H.eq({ all_section.renamed, all_section.rename_only }, { true, nil })
  H.eq({ staged_section.renamed, staged_section.rename_only }, { true, true })
  H.eq({ unstaged_section.renamed, unstaged_section.rename_only }, { false, nil })

  vim.fn.delete(root, "rf")
end

T["lens_named the three fixed lenses point at the right pair of sides"] = function()
  H.eq(lens.get("all"), { id = "all", old = "HEAD", new = "worktree",
    label = "worktree vs HEAD" })
  H.eq(lens.get("unstaged"), { id = "unstaged", old = ":0", new = "worktree",
    label = "worktree vs index (unstaged)" })
  -- The one the plugin could not express at all before: staged is index vs HEAD,
  -- so the NEW side is the index rather than the worktree.
  H.eq(lens.get("staged"), { id = "staged", old = "HEAD", new = ":0",
    label = "index vs HEAD (staged)" })
  H.eq(lens.get("nonsense"), nil)
end

T["lens_named get returns a copy, so state cannot corrupt the table"] = function()
  local a = lens.get("all")
  a.old = "MANGLED"
  H.eq(lens.get("all").old, "HEAD", "the next open must still get a clean lens")
end

T["lens_branch compares the worktree against a ref"] = function()
  H.eq(lens.branch("main"),
    { id = "branch:main", old = "main", new = "worktree", label = "worktree vs main" })
  H.eq(lens.branch("origin/main").id, "branch:origin/main", "the ref is part of the id")
  H.eq(lens.branch(""), nil, "no ref, no lens")
  H.eq(lens.branch(nil), nil)
end

T["lens_branch is_branch distinguishes arbitrary refs from fixed lenses"] = function()
  H.eq(lens.is_branch(lens.branch("main")), true)
  H.eq(lens.is_branch({ id = "branch:main", old = "main", new = "worktree" }), true,
    "the identity survives a session round trip without metatables")
  H.eq(lens.is_branch(lens.get("all")), false, "all has the same new side but is fixed")
  H.eq(lens.is_branch(lens.get("unstaged")), false)
  H.eq(lens.is_branch({ id = "branch:other", old = "main", new = "worktree" }), false,
    "a malformed id/ref pair must not enter ref-specific collection")
  H.eq(lens.is_branch(nil), false)
end

T["lens_branch collect sees clean committed A D M R plus untracked against the ref"] = function()
  local root = H.git_fixture({
    committed = {
      ["deleted.txt"] = "deleted at head\n",
      ["modified.txt"] = "before\n",
      ["old-name.txt"] = "rename-only body\n",
    },
  })
  local function sh(cmd)
    local res = vim.system(cmd, { cwd = root, text = true }):wait()
    assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
    return res.stdout
  end
  local function write(rel, body)
    local abs = vim.fs.joinpath(root, rel)
    vim.fn.mkdir(vim.fs.dirname(abs), "p")
    local f = assert(io.open(abs, "w"))
    f:write(body)
    f:close()
  end

  sh({ "git", "branch", "comparison-base", "HEAD" })
  local base_oid = assert(source.resolve_commit(root, "comparison-base"))
  write("added.txt", "added after base\n")
  write("modified.txt", "after\n")
  assert(vim.fn.delete(vim.fs.joinpath(root, "deleted.txt")) == 0)
  sh({ "git", "mv", "old-name.txt", "renamed.txt" })
  sh({ "git", "add", "-A" })
  sh({ "git", "commit", "-m", "advance from comparison base" })
  write("untracked.txt", "not in the index\n")

  local files, err = source.files(root, lens.branch("comparison-base"))
  assert(files, err)
  local by = {}
  local paths = {}
  for _, f in ipairs(files) do
    paths[#paths + 1] = f.path
    by[f.path] = f
    H.eq(f.old_rev, base_oid, "every old-side read is pinned to the resolved commit")
  end
  H.eq(paths, {
    "added.txt",
    "deleted.txt",
    "modified.txt",
    "renamed.txt",
    "untracked.txt",
  })

  H.eq({ by["added.txt"].status, by["added.txt"].old_path,
    by["added.txt"].old_text, by["added.txt"].new_text },
    { "A", "added.txt", "", "added after base\n" })
  H.eq({ by["deleted.txt"].status, by["deleted.txt"].old_path,
    by["deleted.txt"].old_text, by["deleted.txt"].new_text },
    { "D", "deleted.txt", "deleted at head\n", "" })
  H.eq({ by["modified.txt"].status, by["modified.txt"].old_path,
    by["modified.txt"].old_text, by["modified.txt"].new_text },
    { "M", "modified.txt", "before\n", "after\n" })
  H.eq({ by["renamed.txt"].status, by["renamed.txt"].old_path,
    by["renamed.txt"].old_text, by["renamed.txt"].new_text },
    { "R", "old-name.txt", "rename-only body\n", "rename-only body\n" })
  H.eq({ by["untracked.txt"].status, by["untracked.txt"].old_path,
    by["untracked.txt"].old_text, by["untracked.txt"].new_text,
    by["untracked.txt"].staged, by["untracked.txt"].unstaged },
    { "?", "untracked.txt", "", "not in the index\n", nil, "?" })

  local sections, section_err = source.sections(root, lens.branch("comparison-base"), 3)
  assert(sections, section_err)
  local section_by = {}
  for _, section in ipairs(sections) do
    section_by[section.path] = section
  end
  H.eq(#sections, 5, "the text-identical committed rename is not dropped")
  H.eq({
    section_by["renamed.txt"].old_path,
    section_by["renamed.txt"].old_rev,
    section_by["renamed.txt"].status,
    section_by["renamed.txt"].renamed,
    section_by["renamed.txt"].rename_only,
    #section_by["renamed.txt"].entries,
  }, {
    "old-name.txt", base_oid, "R", true, true, 1,
  }, "collection identity reaches a header-only branch-rename section")

  vim.fn.delete(root, "rf")
end

T["lens_branch invalid ref returns an error instead of fabricating an addition"] = function()
  local root = H.git_fixture({
    committed = { ["dirty.txt"] = "before\n" },
    worktree = { ["dirty.txt"] = "after\n" },
  })

  local files, err = source.files(root, lens.branch("definitely-missing"))
  H.eq(files, nil, "an invalid old side is not an empty blob")
  assert(type(err) == "string" and err:find("does not resolve", 1, true),
    "the caller needs to distinguish invalid from an empty valid diff: " .. tostring(err))

  vim.fn.delete(root, "rf")
end

T["lens_branch recreated untracked path replaces the ref-relative deletion"] = function()
  local root = H.git_fixture({ committed = { ["same.txt"] = "old tracked body\n" } })
  local function sh(cmd)
    local res = vim.system(cmd, { cwd = root, text = true }):wait()
    assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  end
  sh({ "git", "branch", "comparison-base", "HEAD" })

  assert(vim.fn.delete(vim.fs.joinpath(root, "same.txt")) == 0)
  sh({ "git", "add", "-A" })
  sh({ "git", "commit", "-m", "delete tracked path" })

  local f = assert(io.open(vim.fs.joinpath(root, "same.txt"), "w"))
  f:write("new untracked body\n")
  f:close()

  local files, err = source.files(root, lens.branch("comparison-base"))
  assert(files, err)
  H.eq(#files, 1, "the same current path must not appear once as D and again as ?")
  H.eq({
    files[1].path,
    files[1].old_path,
    files[1].status,
    files[1].old_text,
    files[1].new_text,
    files[1].unstaged,
  }, {
    "same.txt",
    "same.txt",
    "M",
    "old tracked body\n",
    "new untracked body\n",
    "?",
  })

  vim.fn.delete(root, "rf")
end

-- The distinction the whole product rests on: a lens whose new side is the
-- worktree maps onto files you can open and edit.
T["lens_editable only a worktree new-side is editable"] = function()
  H.eq(lens.editable(lens.get("all")), true)
  H.eq(lens.editable(lens.get("unstaged")), true)
  H.eq(lens.editable(lens.branch("main")), true)
  H.eq(lens.editable(lens.get("staged")), false,
    "the index is not a file you can edit -- unstage it first")
  H.eq(lens.editable(nil), false)
end

T["lens_base round-trips the legacy two-value vocabulary"] = function()
  H.eq(lens.from_base("HEAD").id, "all")
  H.eq(lens.from_base("index").id, "unstaged")
  H.eq(lens.from_base(nil).id, "all", "no saved base means everything")
  H.eq(lens.from_base("garbage").id, "all", "unknown values fall back, never error")

  H.eq(lens.to_base(lens.get("all")), "HEAD")
  H.eq(lens.to_base(lens.get("unstaged")), "index")
  -- These two are why the session has to persist the lens itself.
  H.eq(lens.to_base(lens.get("staged")), nil, "staged is inexpressible as a base")
  H.eq(lens.to_base(lens.branch("main")), nil, "so is a branch comparison")
  H.eq(lens.to_base(nil), nil)
end

T["lens_valid refuses a nonsense new side from a hand-edited payload"] = function()
  H.eq(lens.valid(lens.get("all")), true)
  H.eq(lens.valid(lens.get("staged")), true)
  H.eq(lens.valid({ old = "HEAD", new = "somewhere-else" }), false,
    "an unknown new side would be trusted by every reader -- refuse it")
  H.eq(lens.valid({ old = "", new = "worktree" }), false, "empty rev")
  H.eq(lens.valid({ new = "worktree" }), false, "no old side")
  H.eq(lens.valid(nil), false)
  H.eq(lens.valid("HEAD"), false, "a bare string is not a lens")
end

-- Every hand-built test state in the suite sets only `base`; they must keep working.
T["lens_of falls back to the legacy base on a state without a lens"] = function()
  H.eq(lens.of({ lens = lens.get("staged") }).id, "staged", "a real lens wins")
  H.eq(lens.of({ base = "index" }).id, "unstaged", "no lens: translate the base")
  H.eq(lens.of({ base = "HEAD" }).id, "all")
  H.eq(lens.of({}).id, "all", "neither: everything")
  H.eq(lens.of(nil).id, "all")
  H.eq(lens.of({ lens = { old = "HEAD", new = "nonsense" }, base = "index" }).id,
    "unstaged", "an invalid lens is ignored rather than trusted")
end

T["lens_step cycles the three named lenses"] = function()
  H.eq(lens.step(lens.get("all"), 1).id, "unstaged")
  H.eq(lens.step(lens.get("unstaged"), 1).id, "staged")
  H.eq(lens.step(lens.get("staged"), 1).id, "all", "wraps")
  H.eq(lens.step(lens.get("all"), -1).id, "staged", "and backwards")
  H.eq(lens.step(lens.branch("main"), 1).id, "all",
    "a branch lens is outside the cycle, so stepping enters it at the start")
  H.eq(lens.step(nil, 1).id, "all")
end

T["lens_same compares the sides, not the label or id"] = function()
  H.eq(lens.same(lens.get("all"), lens.get("all")), true)
  H.eq(lens.same(lens.get("all"), lens.get("unstaged")), false)
  H.eq(lens.same(lens.get("all"), { old = "HEAD", new = "worktree" }), true,
    "a hand-built equivalent counts as the same comparison")
  H.eq(lens.same(lens.get("all"), lens.get("staged")), false,
    "same old side, different new side -- not the same lens")
  H.eq(lens.same(nil, nil), true)
  H.eq(lens.same(lens.get("all"), nil), false)
end

-- --- through the plugin ---------------------------------------------------

local canvas = require("canvasdiff.canvas")
local model = require("canvasdiff.diff")
local jump = require("canvasdiff.input").jump
local session = require("canvasdiff.session")

local function open_lens(root, l)
  local st = canvas.open(model.build(source.files(root, l), 3), {})
  st.root = root
  st.lens = l
  st.base = lens.to_base(l)
  return st
end

T["lens_branch control-path pure rename renders as one safe canvas row"] = function()
  local old_path = "old\tline\n.txt"
  local new_path = "new\tline\n.txt"
  local root = H.git_fixture({ committed = { [old_path] = "same\n" } })
  local function sh(cmd)
    local res = vim.system(cmd, { cwd = root, text = true }):wait()
    assert(res.code == 0, (res.stderr or "git command failed"))
  end
  sh({ "git", "branch", "comparison-base", "HEAD" })
  sh({ "git", "mv", "--", old_path, new_path })

  local sections, err = source.sections(root, lens.branch("comparison-base"), 3)
  assert(sections, err)
  H.eq(#sections, 1)
  H.eq({
    sections[1].path,
    sections[1].old_path,
    sections[1].rename_only,
    #sections[1].entries,
  }, {
    new_path, old_path, true, 1,
  }, "raw NUL-delimited rename identity reaches the model intact")

  local st = canvas.open(sections, {})
  H.eq(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), {
    "▎ old\\tline\\n.txt → new\\tline\\n.txt  (renamed)",
  }, "literal tabs/newlines cannot split the one-row canvas section")

  vim.fn.delete(root, "rf")
end

T["lens_staged the canvas renders index vs HEAD, which it never could before"] = function()
  local root = partly_staged()
  local st = open_lens(root, lens.get("staged"))
  H.eq(#st.sections, 1)
  H.eq(st.sections[1].old_text, "one\n")
  H.eq(st.sections[1].new_text, "two\n")
  local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
  local body = table.concat(lines, "\n")
  assert(body:find("+two", 1, true), "the staged line arrives as a real row: " .. body)
  -- HEAD's line going away is a GHOST now, not a buffer row, so it is not in the text.
  -- Assert it on the model instead, which is where it lives.
  local ghosted = {}
  for _, e in ipairs(st.sections[1].entries) do
    for _, g in ipairs(e.ghosts or {}) do ghosted[#ghosted + 1] = g.content end
    for _, g in ipairs(e.ghosts_after or {}) do ghosted[#ghosted + 1] = g.content end
  end
  H.eq(ghosted, { "one" }, "and HEAD's line is carried as a ghost")
  vim.fn.delete(root, "rf")
end

-- The index is not a file, so <CR> must decline rather than drop you into a buffer
-- whose content is NOT what the canvas is showing.
T["lens_staged jump declines and names the way out"] = function()
  local root = partly_staged()
  local st = open_lens(root, lens.get("staged"))
  local before = vim.api.nvim_win_get_buf(st.win)

  -- Land on a real diff row, so the decline is the only thing that can stop it.
  local target
  for i, l in ipairs(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)) do
    if l:match("^%+two") then target = i break end
  end
  assert(target, "found the staged add row")
  vim.api.nvim_win_set_cursor(st.win, { target, 0 })

  local outcome = jump.enter(jump.store(), st)

  H.eq(outcome.ok, false, "an uneditable lens declines")
  H.eq(vim.api.nvim_win_get_buf(st.win), before, "and must not open anything")
  assert(outcome.diagnostic and outcome.diagnostic.message:match("unstage"),
    "the message has to name the way out, got: "
    .. vim.inspect(outcome.diagnostic))
  vim.fn.delete(root, "rf")
end

-- `staged` has no legacy `base` equivalent, so the session must carry the lens
-- itself or reopening would silently drop you back to worktree-vs-HEAD.
T["lens_session round-trips a lens that base cannot express"] = function()
  local root = partly_staged()
  local st = open_lens(root, lens.get("staged"))
  session.save(st)

  local data = session.load(root)
  H.eq(data.base, nil, "staged is inexpressible as a base, so none is written")
  H.eq(data.lens.id, "staged", "but the lens itself is persisted")
  H.eq(data.lens.new, ":0", "including its new side")

  os.remove(session.path_for(root))
  vim.fn.delete(root, "rf")
end

T["lens_session an older payload with only a base still restores"] = function()
  local root = partly_staged()
  local st = open_lens(root, lens.get("unstaged"))
  session.save(st)
  local data = session.load(root)
  H.eq(data.base, "index", "the courtesy field is written for lenses that have one")
  H.eq(data.lens.id, "unstaged")

  -- Simulate a payload saved before lenses existed: base only, no lens.
  data.lens = nil
  local f = assert(io.open(session.path_for(root), "w"))
  f:write(vim.json.encode(data)); f:close()
  local older = session.load(root)
  H.eq(older.lens, nil, "sanity: no lens in the payload")
  H.eq(lens.from_base(older.base).id, "unstaged", "and the base still resolves")

  os.remove(session.path_for(root))
  vim.fn.delete(root, "rf")
end

-- --- which kind of change is this? ---------------------------------------

local render = require("canvasdiff.canvas").format
local sidebar = require("canvasdiff.ui").sidebar

-- `git status --porcelain=v2` yields an XY pair per file -- X is what the index did,
-- Y is what the worktree did -- and the plugin used to collapse it to one character
-- and throw the rest away. Keeping both is what lets the canvas say which kind of
-- change each file is, and it gives staged-then-changed for free.
T["lens_xy git.changed_files keeps both halves of the status"] = function()
  local root = H.git_fixture({
    committed = { ["staged.txt"] = "s\n", ["both.txt"] = "b\n", ["dirty.txt"] = "d\n" },
  })
  local function sh(c) assert(vim.system(c, { cwd = root }):wait().code == 0) end
  local function write(rel, b)
    local f = assert(io.open(vim.fs.joinpath(root, rel), "w")); f:write(b); f:close()
  end
  write("staged.txt", "s2\n"); write("both.txt", "b2\n")
  sh({ "git", "add", "staged.txt", "both.txt" })
  write("both.txt", "b3\n")            -- staged AND then changed again
  write("dirty.txt", "d2\n")           -- never staged
  write("new.txt", "n\n")              -- untracked

  local by = {}
  for _, f in ipairs(source.changed_files(root)) do by[f.path] = f end

  assert(by["staged.txt"].staged, "staged.txt has an index change")
  H.eq(by["staged.txt"].unstaged, nil, "and nothing outstanding in the worktree")

  H.eq(by["dirty.txt"].staged, nil, "dirty.txt was never staged")
  assert(by["dirty.txt"].unstaged, "but the worktree differs")

  -- The one that matters: git already knows "you staged this, then changed it".
  assert(by["both.txt"].staged and by["both.txt"].unstaged,
    "both.txt is staged AND changed again -- staged-then-changed, straight from git")

  H.eq(by["new.txt"].staged, nil, "an untracked file cannot have staged content")
  assert(by["new.txt"].unstaged, "and the whole file is the unstaged change")

  vim.fn.delete(root, "rf")
end

T["lens_xy staged_then_changed reads it off the section"] = function()
  local model_ = require("canvasdiff.diff")
  H.eq(model_.staged_then_changed({ staged = "M", unstaged = "M" }), true)
  H.eq(model_.staged_then_changed({ staged = "M" }), false, "staged only")
  H.eq(model_.staged_then_changed({ unstaged = "M" }), false, "unstaged only")
  H.eq(model_.staged_then_changed({}), false)
  H.eq(model_.staged_then_changed(nil), false)
end

T["lens_xy stage_mark gives each state its own glyph"] = function()
  H.eq(render.stage_mark("M", nil), render.glyphs.staged)
  H.eq(render.stage_mark(nil, "M"), render.glyphs.unstaged)
  H.eq(render.stage_mark("M", "M"), render.glyphs.staged .. render.glyphs.unstaged,
    "two independent facts, so two glyphs -- not one tri-state symbol")
  H.eq(render.stage_mark(nil, nil), "",
    "no status information means render nothing, never 'clean'")
end

T["lens_xy the sidebar row says which kind of change it is"] = function()
  local secs = {
    { path = "a.txt", adds = 1, dels = 0, staged = "M" },
    { path = "b.txt", adds = 2, dels = 1, staged = "M", unstaged = "M" },
    { path = "c.txt", adds = 3, dels = 2, unstaged = "M" },
  }
  local lines = sidebar.render_lines(sidebar.build_entries(secs, {}, {}, {}))
  H.eq(lines, {
    "  a.txt  +1 −0 ●",
    "  b.txt  +2 −1 ●○",
    "  c.txt  +3 −2 ○",
  }, "staged, staged-then-changed, and unstaged are each distinguishable at a glance")
end

T["lens_xy the stage mark sits before the stale marker"] = function()
  local secs = { { path = "a.txt", adds = 1, dels = 0, staged = "M", unstaged = "M" } }
  local lines = sidebar.render_lines(
    sidebar.build_entries(secs, {}, { ["a.txt"] = true }, { ["a.txt"] = true }))
  H.eq(lines, { "▸ a.txt  +1 −0 ●○" .. render.glyphs.stale },
    "so the trailing ● keeps meaning exactly one thing in both windows")
end

-- --- the pivot is non-destructive ----------------------------------------

--- A repo where `keep.txt` is IDENTICAL through the all and unstaged lenses (it has
--- no staged content, so index == HEAD for it), while `moved.txt` differs. Tall, so
--- the buffer is taller than the ~22-row headless window and a topline partway down
--- actually holds.
local function pivot_fixture()
  local function body(tag, marks)
    local o = {}
    for i = 1, 90 do
      o[i] = tag .. " line " .. i .. ((marks and i % 10 == 0) and " changed" or "")
    end
    return table.concat(o, "\n") .. "\n"
  end
  local root = H.git_fixture({
    committed = { ["keep.txt"] = body("k"), ["moved.txt"] = body("m") },
  })
  local function sh(c) assert(vim.system(c, { cwd = root }):wait().code == 0) end
  local function write(rel, b)
    local f = assert(io.open(vim.fs.joinpath(root, rel), "w")); f:write(b); f:close()
  end
  -- moved.txt gets staged content, so index ~= HEAD for it and the two lenses
  -- disagree. keep.txt is only ever modified in the worktree.
  write("moved.txt", body("m", true))
  sh({ "git", "add", "moved.txt" })
  write("moved.txt", body("m", true) .. "and more\n")
  write("keep.txt", body("k", true))
  return root
end

--- Record which sections the canvas actually re-spliced, and whether it gave up and
--- re-rendered wholesale, by listening on the hooks canvas already fires for this
--- (the same ones hl.attach uses to invalidate its marks).
---
--- Comparing extmark ids instead does NOT work, and the failure is silent:
--- nvim_buf_clear_namespace RECYCLES ids, so a full render_all hands back 1, 2, 3
--- again and the ids look untouched even though every anchor was destroyed and
--- rebuilt. Verified empirically -- an id-comparison version of this test passed
--- against a pivot deliberately routed through render_all.
local function watch_splices(st)
  local rec = { replaced = {}, rendered_all = false }
  st.hooks = st.hooks or {}
  st.hooks.on_render_all = function() rec.rendered_all = true end
  st.hooks.on_section_replaced = function(path) rec.replaced[path] = true end
  return rec
end

-- THE test for "dynamic". The whole canvas must not be torn down, but a section
-- whose text is identical through two lenses still needs replacement when its
-- old_rev changes: jump/back must later rebuild it from the exact source that
-- produced the visible comparison.
T["lens_pivot replaces source metadata in place and preserves the viewport"] = function()
  local root = pivot_fixture()
  local st = open_lens(root, lens.get("all"))
  H.eq(st.sections[1].path, "keep.txt", "sanity: keep.txt sorts first")

  -- Park mid-file inside keep.txt, cursor away from the topline.
  local start0, end0 = canvas.section_rows(st, 1)
  assert(end0 - start0 > 30, "sanity: keep.txt is tall enough to sit inside")
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = start0 + 12, lnum = start0 + 18 })
  end)
  local before_view = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
  local before_text = vim.api.nvim_buf_get_lines(st.buf, start0, end0, false)
  local spliced = watch_splices(st)

  -- Pivot to the unstaged lens. keep.txt's text is identical through both,
  -- while its old source changes from HEAD to the index.
  st.lens = lens.get("unstaged")
  st.base = lens.to_base(st.lens)
  local desired = model.build(source.files(root, st.lens), 3)
  local full = canvas.reconcile_sections(st, desired)

  H.eq(full, false, "a pivot between two populated lenses must not fall back to render_all")
  H.eq(spliced.rendered_all, false,
    "the whole buffer must not be re-rendered -- this is what fails the moment a "
    .. "pivot is routed back through render_all")
  H.eq(spliced.replaced["keep.txt"], true,
    "text equality cannot hide its navigation-relevant old_rev change")
  H.eq(spliced.replaced["moved.txt"], true,
    "the section whose text differs is re-spliced too")

  local after_view = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
  H.eq(after_view.topline, before_view.topline, "the viewport did not move")

  local s2, e2 = canvas.section_rows(st, 1)
  H.eq({ s2, e2 }, { start0, end0 }, "keep.txt occupies exactly the same rows")
  H.eq(vim.api.nvim_buf_get_lines(st.buf, s2, e2, false), before_text,
    "with exactly the same text")
  H.eq(st.sections[1].old_rev, ":0", "the replacement publishes the new source revision")

  -- And the pivot really did do something: moved.txt differs between the lenses.
  local j
  for k, s in ipairs(st.sections) do if s.path == "moved.txt" then j = k end end
  H.eq(st.sections[j].old_text, desired[j].old_text,
    "the section that DOES differ was updated to the new lens")

  vim.fn.delete(root, "rf")
end

-- Pivoting away from a lens while reading a file that only exists there must land
-- somewhere real rather than clamping to EOF.
T["lens_pivot away from a file that only the old lens had lands somewhere real"] = function()
  local root = pivot_fixture()
  -- keep.txt has no staged content, so it is absent from the staged lens entirely.
  local st = open_lens(root, lens.get("all"))
  local start0 = (canvas.section_rows(st, 1))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = start0 + 12, lnum = start0 + 18 })
  end)

  st.lens = lens.get("staged")
  st.base = lens.to_base(st.lens)
  local desired = model.build(source.files(root, st.lens), 3)
  canvas.reconcile_sections(st, desired)

  local paths = {}
  for _, s in ipairs(st.sections) do paths[#paths + 1] = s.path end
  H.eq(paths, { "moved.txt" }, "sanity: keep.txt is not in the staged lens")

  local view = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
  local count = vim.api.nvim_buf_line_count(st.buf)
  assert(view.lnum >= 1 and view.lnum <= count,
    ("cursor %d must be inside the buffer (1..%d)"):format(view.lnum, count))
  assert(view.topline >= 1 and view.topline <= count,
    ("topline %d must be inside the buffer (1..%d)"):format(view.topline, count))
  H.eq((canvas.locate(st, view.lnum - 1)), 1, "and it is on the surviving section")

  vim.fn.delete(root, "rf")
end

return T
