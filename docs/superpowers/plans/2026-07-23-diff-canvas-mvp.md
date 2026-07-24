# Diff Canvas MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MVP of `galley` — a Neovim plugin rendering ALL changed files' diffs (working tree vs HEAD, alphabetical) in one scrollable scratch canvas; `<CR>` on any diff line jumps into the real file buffer (full LSP/treesitter); `<M-CR>` returns to the canvas at the exact semantic position with that file's diff regenerated.

**Architecture:** Single scratch buffer + extmark section anchors (one per file section, left-gravity). A pure model layer (git → differ → model → render) builds sections; canvas.lua owns buffer/anchors/splice; viewport.lua owns semantic anchor capture/resolution (position identity = file + line content + approx new_lnum, fuzzy-matched — never raw line numbers); jump.lua owns the excursion. Diff-tier highlights only in MVP (DiffAdd/DiffDelete backgrounds); treesitter tier, watcher, sidebar, scrollbar are later phases.

**Tech Stack:** Lua, Neovim ≥0.10 (dev env: 0.12.4), `vim.system` for git, `vim.text.diff`/`vim.diff` shim, bespoke headless test runner (`nvim --headless --clean -l tests/run.lua`), no external plugin dependencies.

## Global Constraints

- Neovim ≥0.10; use `vim.text.diff` when present, else `vim.diff` (shim lives ONLY in `lua/galley/differ.lua`).
- No external runtime dependencies (no plenary, no nui). Tests use the bespoke runner in `tests/run.lua`.
- Canvas buffer: `buftype=nofile`, `bufhidden=hide` (NEVER wipe — extmark anchors must survive excursions), `swapfile=false`, `modifiable=false` toggled only inside canvas.lua writes, `undolevels=-1` buffer-local.
- Section anchors: extmarks in namespace `galley/anchors` with `right_gravity=false, invalidate=false, undo_restore=false`; one per section start + one EOF sentinel. Never `nvim_buf_set_lines` across a foreign section's anchor row.
- Position identity is ALWAYS a semantic anchor `{path, new_lnum, content}` resolved via the match chain in viewport.lua — never a stored canvas line number.
- Splices + viewport restore happen in one synchronous event-loop tick (no `vim.schedule` between `set_lines` and `winrestview`).
- Never attach a treesitter parser or syntax to the canvas buffer.
- Default keys: `<CR>` jump (canvas-local), `<M-CR>` return (excursion-buffer-local), `q` close canvas (canvas-local only — NEVER map `q` in real file buffers).
- Files sorted alphabetically by path (plain `table.sort` on repo-relative path, case-sensitive byte order).
- All Lua modules under `lua/galley/`; pure modules (`differ`, `model`, `render`, `viewport` resolution) must not touch `vim.api` window/buffer state except where stated.
- Commit after each green test cycle; commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Test commands must exit non-zero on failure: `make test` runs `nvim --headless --clean -l tests/run.lua`.

---

### Task 1: Scaffold + headless test runner

**Files:**
- Create: `.gitignore`, `Makefile`, `README.md`, `tests/run.lua`, `tests/helpers.lua`, `tests/test_smoke.lua`, `lua/galley/util.lua`

**Interfaces:**
- Consumes: nothing (first task)
- Produces:
  - `tests/run.lua`: discovers `tests/test_*.lua`; each test file returns `{ [test_name_string] = function() ... end }`; runner prepends repo root to `runtimepath`, runs each fn in `pcall`, prints `PASS name` / `FAIL name: err`, calls `os.exit(1)` if any failed, `os.exit(0)` otherwise. Supports optional CLI arg as Lua pattern filter on test names: `nvim --headless --clean -l tests/run.lua canvas`.
  - `tests/helpers.lua`: `H.tmpdir() -> path` (fresh dir under `vim.uv.os_tmpdir()`), `H.git_fixture(spec) -> root` where `spec = { committed = {[relpath]=content}, worktree = {[relpath]=content_or_false} }` — creates repo, commits `committed`, then applies `worktree` (write content, or delete file when `false`); `H.eq(a, b, msg)` deep-equality assert (use `vim.deep_equal`, error with `vim.inspect` of both on mismatch).
  - `lua/galley/util.lua`: `U.list_slice(t, s, e)`, `U.clamp(n, lo, hi)`.

- [ ] **Step 1: Write `.gitignore`, `Makefile`, `README.md` stub**

`.gitignore`:
```
.superpowers/
*.log
```

`Makefile`:
```make
.PHONY: test
test:
	nvim --headless --clean -l tests/run.lua $(FILTER)
```

`README.md`: one paragraph: working title, one-line concept ("Infinite-scroll git diff canvas for Neovim — review all your uncommitted changes in one scrollable view, jump into any hunk as a real buffer, jump back to the exact spot"), status: pre-alpha MVP.

- [ ] **Step 2: Write the test runner `tests/run.lua`**

```lua
-- Run: nvim --headless --clean -l tests/run.lua [name-pattern]
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local pattern = _G.arg and _G.arg[1] or nil
local files = vim.fn.glob(root .. "/tests/test_*.lua", false, true)
table.sort(files)

local total, failed = 0, 0
for _, file in ipairs(files) do
  local chunk = assert(loadfile(file))
  local cases = chunk()
  local names = vim.tbl_keys(cases)
  table.sort(names)
  for _, name in ipairs(names) do
    if not pattern or name:find(pattern) then
      total = total + 1
      local ok, err = pcall(cases[name])
      if ok then
        print("PASS " .. name)
      else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
      end
    end
  end
end
print(("%d/%d passed"):format(total - failed, total))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 3: Write `tests/helpers.lua`**

```lua
local H = {}

function H.tmpdir()
  local dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "galley_test_" .. vim.uv.hrtime())
  vim.fn.mkdir(dir, "p")
  return dir
end

local function sh(cwd, cmd)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
  return res.stdout
end

function H.git_fixture(spec)
  local root = H.tmpdir()
  sh(root, { "git", "init", "-b", "main" })
  sh(root, { "git", "config", "user.email", "t@t" })
  sh(root, { "git", "config", "user.name", "t" })
  for rel, content in pairs(spec.committed or {}) do
    local abs = vim.fs.joinpath(root, rel)
    vim.fn.mkdir(vim.fs.dirname(abs), "p")
    local f = assert(io.open(abs, "w")); f:write(content); f:close()
  end
  sh(root, { "git", "add", "-A" })
  sh(root, { "git", "commit", "-m", "fixture", "--allow-empty" })
  for rel, content in pairs(spec.worktree or {}) do
    local abs = vim.fs.joinpath(root, rel)
    if content == false then
      vim.fn.delete(abs)
    else
      vim.fn.mkdir(vim.fs.dirname(abs), "p")
      local f = assert(io.open(abs, "w")); f:write(content); f:close()
    end
  end
  return root
end

function H.eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error((msg or "not equal") .. "\nleft:  " .. vim.inspect(a) .. "\nright: " .. vim.inspect(b), 2)
  end
end

return H
```

- [ ] **Step 4: Write `lua/galley/util.lua` and `tests/test_smoke.lua`**

`util.lua`:
```lua
local U = {}
function U.list_slice(t, s, e)
  local out = {}
  for i = s, math.min(e, #t) do out[#out + 1] = t[i] end
  return out
end
function U.clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end
return U
```

`tests/test_smoke.lua`:
```lua
local H = require("helpers")
local U = require("galley.util")
return {
  ["smoke: util.clamp"] = function()
    H.eq(U.clamp(5, 1, 3), 3)
    H.eq(U.clamp(-1, 1, 3), 1)
    H.eq(U.clamp(2, 1, 3), 2)
  end,
  ["smoke: git fixture builds"] = function()
    local root = H.git_fixture({
      committed = { ["a.txt"] = "one\n" },
      worktree = { ["a.txt"] = "one\ntwo\n" },
    })
    local res = vim.system({ "git", "status", "--porcelain" }, { cwd = root, text = true }):wait()
    assert(res.stdout:find("a.txt"), "expected dirty a.txt, got: " .. res.stdout)
  end,
}
```

- [ ] **Step 5: Run `make test` — expect 2/2 PASS, exit 0. Also verify failure propagates: temporarily add a failing test, confirm exit 1, remove it.**

- [ ] **Step 6: Commit** — `feat: scaffold repo with headless test runner`

---

### Task 2: Spike — treesitter string-parser highlight extraction (throwaway, gates Phase 2)

**Files:**
- Create: `spikes/ts_string_parser.lua`, `spikes/README.md`

**Interfaces:**
- Consumes: nothing. Produces: a written GO/NO-GO verdict in `spikes/README.md`. Nothing later imports spike code.

- [ ] **Step 1: Write `spikes/ts_string_parser.lua`** (run: `nvim --headless --clean -l spikes/ts_string_parser.lua`)

```lua
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
```

- [ ] **Step 2: Run it.** Expected: `SPIKE PASS`, exit 0. If FAIL: record the numbers in `spikes/README.md` and report BLOCKED (the Phase 2 design needs revisiting — do not silently continue).

- [ ] **Step 3: Write `spikes/README.md`** — one section per spike: command, measured numbers, GO/NO-GO.

- [ ] **Step 4: Commit** — `chore(spike): treesitter string-parser highlight timing`

---

### Task 3: Spike — zero-motion splice above viewport (throwaway, gates splice design)

**Files:**
- Create: `spikes/splice_zero_motion.lua`
- Modify: `spikes/README.md` (append verdict)

**Interfaces:** Consumes/produces nothing importable; verdict in `spikes/README.md`.

- [ ] **Step 1: Write `spikes/splice_zero_motion.lua`** (run: `nvim --headless --clean -l spikes/splice_zero_motion.lua`)

```lua
-- Spike: replacing lines ABOVE the viewport, then correcting topline in the
-- same tick, leaves the visible text and relative cursor position identical.
-- Headless windows work: nvim_open_win + winsaveview are fully functional.
local buf = vim.api.nvim_create_buf(false, true)
local lines = {}
for i = 1, 1000 do lines[i] = "line " .. i end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local win = vim.api.nvim_open_win(buf, true, {
  relative = "editor", row = 0, col = 0, width = 40, height = 20,
})

-- Scroll to middle: topline 500, cursor on 510
vim.api.nvim_win_call(win, function()
  vim.fn.winrestview({ topline = 500, lnum = 510, col = 3 })
end)

local function visible()
  return vim.api.nvim_win_call(win, function()
    local v = vim.fn.winsaveview()
    local top = vim.fn.line("w0")
    return { view = v, first_visible_text = vim.fn.getline(top) }
  end)
end

local before = visible()

-- Splice: replace lines 100..200 (above viewport) with 150 new lines (delta +49)
local newchunk = {}
for i = 1, 150 do newchunk[i] = "NEW " .. i end
local delta = 150 - 101
vim.api.nvim_buf_set_lines(buf, 99, 200, false, newchunk)
vim.api.nvim_win_call(win, function()
  local v = vim.fn.winsaveview()
  v.topline = before.view.topline + delta
  v.lnum = before.view.lnum + delta
  vim.fn.winrestview(v)
end)

local after = visible()
print("before first visible: " .. before.first_visible_text)
print("after  first visible: " .. after.first_visible_text)
print("col before/after: " .. before.view.col .. "/" .. after.view.col)
local ok = before.first_visible_text == after.first_visible_text
  and before.view.col == after.view.col
  and (after.view.topline - before.view.topline) == delta
print(ok and "SPIKE PASS" or "SPIKE FAIL")
os.exit(ok and 0 or 1)
```

- [ ] **Step 2: Run it.** Expected `SPIKE PASS`. If headless floating windows misbehave, retry with a split (`vim.cmd.split` + `nvim_win_set_buf`); if still failing, report BLOCKED.

- [ ] **Step 3: Append verdict to `spikes/README.md`; commit** — `chore(spike): zero-motion splice above viewport`

---

### Task 4: viewport.lua — semantic anchor resolution (pure core) + fuzz test

**Files:**
- Create: `lua/galley/viewport.lua`, `tests/test_viewport.lua`

**Interfaces:**
- Consumes: nothing internal (pure Lua; no vim window APIs in this task).
- Produces (used by Tasks 7-9):
  - `V.resolve(anchor, entries) -> idx|nil` — `anchor = { new_lnum = int|nil, content = string|nil }`; `entries = list of { new_lnum = int|nil, content = string, kind = "add"|"del"|"ctx"|"file_hdr"|"hunk_hdr" }` (a section's line entries, 1-indexed). Returns the 1-based index of the best match via this exact chain, first hit wins:
    1. entry where `new_lnum == anchor.new_lnum and content == anchor.content`
    2. entry with `content == anchor.content` and `new_lnum` within ±20 of `anchor.new_lnum` (nil new_lnum on either side ⇒ skip distance check, allow match); if several, nearest by `|new_lnum - anchor.new_lnum|`
    3. entry with `new_lnum == anchor.new_lnum` (any content), prefer kind "ctx" over "add"
    4. entry with kind `hunk_hdr` nearest by hunk order to the anchor's `new_lnum` (compare against the following entry's `new_lnum`)
    5. `1` if `#entries > 0`, else `nil`
  - `V.capture_from_entries(entries, top_offset) -> anchor` — given a section's entries and the offset (1-based index into `entries`) of the topmost visible line, walk from `top_offset` DOWN towards the end looking for the first `ctx` entry within 5 entries, else walk up, else use the entry at `top_offset` itself; return `{ new_lnum = e.new_lnum, content = e.content, screen_offset = top_offset_delta }` where `screen_offset` = (chosen index − top_offset) so callers can re-derive topline as `resolved_row − screen_offset`.

- [ ] **Step 1: Write failing tests `tests/test_viewport.lua`** — exact-match, content-drift (edit shifted lines by 5), content-changed-same-lnum, hunk-vanished→hunk_hdr fallback, empty-entries→nil, plus a fuzz case:

```lua
local H = require("helpers")
local V = require("galley.viewport")

local function mkentries(n)
  local es = {}
  for i = 1, n do
    es[i] = { new_lnum = i, content = "line " .. i, kind = "ctx" }
  end
  return es
end

return {
  ["viewport: exact match wins"] = function()
    local es = mkentries(50)
    H.eq(V.resolve({ new_lnum = 10, content = "line 10" }, es), 10)
  end,
  ["viewport: content match survives line drift"] = function()
    local es = mkentries(50)
    table.insert(es, 5, { new_lnum = nil, content = "inserted", kind = "add" })
    -- entries after index 5 shifted; content "line 10" now at index 11
    H.eq(V.resolve({ new_lnum = 10, content = "line 10" }, es), 11)
  end,
  ["viewport: same lnum different content"] = function()
    local es = mkentries(50)
    es[10].content = "edited!"
    H.eq(V.resolve({ new_lnum = 10, content = "line 10 gone" }, es), 10)
  end,
  ["viewport: empty entries"] = function()
    H.eq(V.resolve({ new_lnum = 1, content = "x" }, {}), nil)
  end,
  ["viewport: capture prefers ctx below top"] = function()
    local es = {
      { new_lnum = nil, content = "+new", kind = "add" },
      { new_lnum = 8, content = "stable", kind = "ctx" },
    }
    local a = V.capture_from_entries(es, 1)
    H.eq(a.content, "stable")
    H.eq(a.screen_offset, 1)
  end,
  ["viewport: fuzz - resolution lands within 2 of true position"] = function()
    math.randomseed(42)
    for trial = 1, 200 do
      local es = mkentries(100)
      local target = math.random(20, 80)
      local anchor = { new_lnum = es[target].new_lnum, content = es[target].content }
      -- random edits: insert/delete up to 10 entries away from target
      for _ = 1, math.random(0, 10) do
        local pos = math.random(1, #es)
        if math.abs(pos - target) > 3 then
          if math.random() < 0.5 then
            table.insert(es, pos, { new_lnum = nil, content = "noise " .. math.random(1e6), kind = "add" })
            if pos <= target then target = target + 1 end
          elseif #es > 30 then
            table.remove(es, pos)
            if pos < target then target = target - 1 end
          end
        end
      end
      local got = V.resolve(anchor, es)
      assert(got and math.abs(got - target) <= 2,
        ("trial %d: resolved %s, true %d"):format(trial, tostring(got), target))
    end
  end,
}
```

- [ ] **Step 2: Run `make test FILTER=viewport` — expect FAIL (module missing).**

- [ ] **Step 3: Implement `lua/galley/viewport.lua`** exactly per the match chain above. Keep it pure (no `vim.api`). ~60 lines.

- [ ] **Step 4: Run `make test` — all green.**

- [ ] **Step 5: Commit** — `feat: semantic anchor resolution with fuzz-tested match chain`

---

### Task 5: git.lua + differ.lua

**Files:**
- Create: `lua/galley/git.lua`, `lua/galley/differ.lua`, `tests/test_git.lua`, `tests/test_differ.lua`

**Interfaces:**
- Consumes: `tests/helpers.lua` fixtures.
- Produces (used by Tasks 6-9):
  - `git.root(dir) -> string|nil` — `git -C dir rev-parse --show-toplevel`, nil on failure.
  - `git.changed_files(root) -> list of { path = rel_path, status = "M"|"A"|"D"|"R"|"?" }` — parse `git -C root status --porcelain=v2 -z --untracked-files=all`; map: `1 .M`/`1 M.`/`1 MM` etc → status from XY (worktree column preferred, else index column); `2` (rename) → status "R" with `path` = NEW path; `?` → "?". Sorted alphabetically by path. Skip submodule entries (`S...` in the sub field).
  - `git.show_head(root, path) -> string|nil` — `git -C root show HEAD:path` stdout; nil when path not in HEAD (untracked/added) or repo has no commits.
  - All git calls synchronous via `vim.system(...):wait()` (MVP decision; async comes with the watcher phase).
  - `differ.hunks(old_text, new_text) -> list of { old_start, old_count, new_start, new_count }` — the `vim.text.diff or vim.diff` shim, `{ result_type = "indices", linematch = 60, algorithm = "histogram" }`. Both args are full-file strings; must handle `""` (empty side).

- [ ] **Step 1: Write failing tests**

`tests/test_git.lua`:
```lua
local H = require("helpers")
local git = require("galley.git")
return {
  ["git: root finds toplevel, nil outside"] = function()
    local root = H.git_fixture({ committed = { ["a.txt"] = "x\n" } })
    H.eq(git.root(root), (vim.uv.fs_realpath(root)))
    H.eq(git.root(H.tmpdir()), nil)
  end,
  ["git: changed_files lists M, A(?), D sorted"] = function()
    local root = H.git_fixture({
      committed = { ["b.txt"] = "old\n", ["gone.txt"] = "bye\n" },
      worktree = { ["b.txt"] = "new\n", ["a_new.txt"] = "hi\n", ["gone.txt"] = false },
    })
    local files = git.changed_files(root)
    local got = {}
    for _, f in ipairs(files) do got[#got + 1] = f.path .. ":" .. f.status end
    H.eq(got, { "a_new.txt:?", "b.txt:M", "gone.txt:D" })
  end,
  ["git: show_head returns committed content, nil for untracked"] = function()
    local root = H.git_fixture({
      committed = { ["b.txt"] = "old\n" },
      worktree = { ["b.txt"] = "new\n", ["u.txt"] = "u\n" },
    })
    H.eq(git.show_head(root, "b.txt"), "old\n")
    H.eq(git.show_head(root, "u.txt"), nil)
  end,
}
```

`tests/test_differ.lua`:
```lua
local H = require("helpers")
local differ = require("galley.differ")
return {
  ["differ: simple change"] = function()
    local h = differ.hunks("a\nb\nc\n", "a\nX\nc\n")
    H.eq(h, { { 2, 1, 2, 1 } })
  end,
  ["differ: pure addition"] = function()
    local h = differ.hunks("a\nc\n", "a\nb\nc\n")
    H.eq(h, { { 1, 0, 2, 1 } })
  end,
  ["differ: empty old side (new file)"] = function()
    local h = differ.hunks("", "a\nb\n")
    H.eq(#h, 1)
    H.eq(h[1][4], 2) -- new_count covers whole file
  end,
}
```

- [ ] **Step 2: Run, expect FAIL. Implement `git.lua` and `differ.lua`.**

`differ.lua` (complete):
```lua
local D = {}
local difffn = (vim.text and vim.text.diff) or vim.diff

function D.hunks(old_text, new_text)
  local raw = difffn(old_text, new_text, {
    result_type = "indices", linematch = 60, algorithm = "histogram",
  })
  return raw or {}
end

return D
```

`git.lua`: implement per interface. Porcelain v2 `-z` parsing: records are NUL-separated; ordinary records look like `1 XY sub mH mI mW hH hI path`; rename records `2 XY sub mH mI mW hH hI X<score> path<TAB or NUL>origpath` — with `-z`, the rename record has path, then NUL, then origpath, then NUL (consume both). Untracked: `? path`. Take status letter: if XY's worktree char (2nd) ~= ".", use it, else use index char.

- [ ] **Step 3: Run `make test` — all green. Commit** — `feat: git plumbing and diff shim`

---

### Task 6: model.lua + render.lua (pure section building)

**Files:**
- Create: `lua/galley/model.lua`, `lua/galley/render.lua`, `tests/test_model.lua`

**Interfaces:**
- Consumes: `differ.hunks` (Task 5).
- Produces (used by Tasks 7-9):
  - `model.build_section(path, old_text, new_text, status) -> section|nil` — nil when no hunks AND status is "M" (unchanged). Otherwise:
    ```lua
    section = {
      path = path, status = status, adds = int, dels = int, nhunks = int,
      entries = {  -- 1-indexed, one per rendered canvas line
        { kind = "file_hdr",  content = path,          new_lnum = nil, old_lnum = nil, hunk_idx = nil },
        { kind = "hunk_hdr",  content = "@@ -l,c +l,c @@", new_lnum = nil, old_lnum = nil, hunk_idx = 1 },
        { kind = "ctx", content = "line text", new_lnum = N, old_lnum = M, hunk_idx = 1 },
        { kind = "del", content = "line text", new_lnum = nil, old_lnum = M, hunk_idx = 1 },
        { kind = "add", content = "line text", new_lnum = N, old_lnum = nil, hunk_idx = 1 },
        ...
      },
    }
    ```
    `content` for ctx/del/add is the RAW file line (no +/- prefix). Context = 3 lines around each hunk; hunks whose context regions touch or overlap merge into one displayed hunk (one `hunk_hdr`). Split texts with `vim.split(text, "\n", { plain = true })`; drop the trailing empty element iff the text ends with `\n`; `old_text == nil` ⇒ treat as `""` (new/untracked file).
  - `model.build(files) -> sections` — `files = list of { path, old_text, new_text, status }`; returns non-nil sections sorted alphabetically by path.
  - `render.section_lines(section) -> list of string` — same length as `section.entries`; `file_hdr` → `"▎ " .. path .. ("  (+%d −%d)"):format(adds, dels)`; `hunk_hdr` → its content; ctx → `" " .. content`; del → `"-" .. content`; add → `"+" .. content`.
  - `render.section_hl(section) -> list of { row = 0based_offset, group = "GalleyFileHeader"|"GalleyHunkHeader"|"DiffAdd"|"DiffDelete" }` — one per non-ctx line; ctx lines get no mark.
  - Highlight groups: define `GalleyFileHeader` (default link `Title`) and `GalleyHunkHeader` (default link `Comment`) — definition itself happens in Task 7's canvas setup, NOT here (render stays pure; it only names groups).

- [ ] **Step 1: Write failing tests `tests/test_model.lua`** — cover: modified file (entry kinds/lnums exact for a 2-hunk case), hunk merging when hunks are ≤6 lines apart, new file (all `add`, old_lnum nil), deleted file (all `del`), unchanged file → nil, `model.build` sorts alphabetically, render prefixes and header format exact:

```lua
local H = require("helpers")
local model = require("galley.model")
local render = require("galley.render")

return {
  ["model: modified file entries"] = function()
    local s = model.build_section("f.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n",
                                            "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\n", "M")
    H.eq(s.adds, 1); H.eq(s.dels, 1); H.eq(s.nhunks, 1)
    H.eq(s.entries[1].kind, "file_hdr")
    H.eq(s.entries[2].kind, "hunk_hdr")
    -- 3 ctx above, del e, add E, 3 ctx below
    H.eq(s.entries[3], { kind = "ctx", content = "b", new_lnum = 2, old_lnum = 2, hunk_idx = 1 })
    H.eq(s.entries[6], { kind = "del", content = "e", new_lnum = nil, old_lnum = 5, hunk_idx = 1 })
    H.eq(s.entries[7], { kind = "add", content = "E", new_lnum = 5, old_lnum = nil, hunk_idx = 1 })
    H.eq(s.entries[10].content, "h")
  end,
  ["model: new file all adds"] = function()
    local s = model.build_section("n.txt", nil, "x\ny\n", "?")
    H.eq(s.adds, 2); H.eq(s.dels, 0)
    H.eq(s.entries[3].kind, "add")
    H.eq(s.entries[3].old_lnum, nil)
  end,
  ["model: deleted file all dels"] = function()
    local s = model.build_section("d.txt", "x\ny\n", "", "D")
    H.eq(s.dels, 2); H.eq(s.adds, 0)
    H.eq(s.entries[3].kind, "del")
  end,
  ["model: unchanged is nil"] = function()
    H.eq(model.build_section("s.txt", "x\n", "x\n", "M"), nil)
  end,
  ["model: build sorts alphabetically"] = function()
    local ss = model.build({
      { path = "z.txt", old_text = "a\n", new_text = "b\n", status = "M" },
      { path = "a.txt", old_text = "a\n", new_text = "b\n", status = "M" },
    })
    H.eq({ ss[1].path, ss[2].path }, { "a.txt", "z.txt" })
  end,
  ["render: line text and highlights"] = function()
    local s = model.build_section("f.txt", "a\nb\n", "a\nB\n", "M")
    local lines = render.section_lines(s)
    H.eq(lines[1], "▎ f.txt  (+1 −1)")
    assert(lines[2]:match("^@@"))
    H.eq(lines[3], " a")
    H.eq(lines[4], "-b")
    H.eq(lines[5], "+B")
    local hl = render.section_hl(s)
    H.eq(hl[1], { row = 0, group = "GalleyFileHeader" })
    H.eq(hl[2], { row = 1, group = "GalleyHunkHeader" })
    H.eq(hl[3], { row = 3, group = "DiffDelete" })
    H.eq(hl[4], { row = 4, group = "DiffAdd" })
  end,
}
```

- [ ] **Step 2: Run, FAIL. Implement `model.lua`** — algorithm: get hunks from differ; expand each to `[max(1, start-3), end+3]` context windows on both sides; merge windows that touch/overlap (compare on old-side ranges; a pure-add hunk occupies zero old lines at a position — treat its old range as `[old_start+1, old_start]` empty range anchored after `old_start` for merging math); emit `hunk_hdr` with the standard `@@ -a,b +c,d @@` computed over the merged window; walk the merged window emitting ctx (lines equal on both sides), del (old lines inside a hunk), add (new lines inside a hunk) — iterate hunks inside the window in order, emitting interleaved ctx from the gap between them. Count adds/dels. Implement `render.lua` per interface (~30 lines).

- [ ] **Step 3: Run `make test` — green. Commit** — `feat: pure diff model and line renderer`

---

### Task 7: canvas.lua — buffer, anchors, render, locate, section replace

**Files:**
- Create: `lua/galley/canvas.lua`, `tests/test_canvas.lua`

**Interfaces:**
- Consumes: `render.section_lines/section_hl` (Task 6), section shape (Task 6), `viewport.resolve/capture_from_entries` (Task 4).
- Produces (used by Tasks 8-9): a `Canvas` object (module-level singleton is fine for MVP):
  - `canvas.open(sections, opts) -> canvas_state` — creates/reuses the scratch buffer (name `galley://canvas`, options per Global Constraints; define hl groups `GalleyFileHeader`→`Title`, `GalleyHunkHeader`→`Comment` with `default = true`), shows it in the current window (plain `nvim_win_set_buf` — the canvas takes over the current window; store `state.win`), renders all sections, places anchors.
  - `canvas.render_all(state, sections)` — with `modifiable` toggled: clear buffer, `nvim_buf_set_lines` with all sections' lines concatenated, place one left-gravity anchor extmark at each section's first row + EOF sentinel anchor, apply line-tier highlights via `nvim_buf_set_extmark` with `hl_group`, `end_row = row+1`, `hl_eol = true`, `priority = 100` (full-line: use `end_col = 0` of next row), store `state.sections` (list) and `state.anchor_ids` (parallel list).
  - `canvas.section_rows(state, i) -> start_row, end_row_exclusive` (0-based) — resolved LIVE from extmarks (`nvim_buf_get_extmark_by_id`), never cached rows.
  - `canvas.locate(state, row0) -> i, offset` — binary search anchors: section index and 1-based entry offset for a 0-based buffer row; nil when buffer empty.
  - `canvas.replace_section(state, i, new_section_or_nil)` — the splice: resolve rows live; if window `state.win` is valid and shows the canvas, classify (below viewport / above viewport / intersecting) using `line("w0")`/`line("w$")` via `nvim_win_call`; splice `set_lines` + reapply that section's highlights + update `state.sections[i]`; above-viewport ⇒ same-tick `winrestview` topline/lnum + delta; intersecting ⇒ `viewport.capture_from_entries` on old entries at current top offset, splice, `viewport.resolve` on new entries, restore `topline = section_start_row + resolved_idx - anchor.screen_offset` (clamped ≥1), same for cursor; `new_section_or_nil = nil` ⇒ delete the section's lines and remove its anchor + list entries.
  - `canvas.is_canvas_buf(buf) -> bool`.

- [ ] **Step 1: Write failing tests `tests/test_canvas.lua`** (headless: open a float or use the current window; the runner's single window is usable via `nvim_get_current_win`):

```lua
local H = require("helpers")
local model = require("galley.model")
local canvas = require("galley.canvas")

-- Big generated fixture: the headless window is ~24 rows tall, so sections
-- must be MUCH taller for "above/below viewport" cases to be real.
-- a.txt: 300 lines, every 10th line changed -> ~30 hunks, ~240 canvas rows.
local function bigtexts(edit_extra)
  local old, new = {}, {}
  for i = 1, 300 do
    old[i] = "a" .. i
    if i % 10 == 0 then
      new[#new + 1] = "A" .. i
      if edit_extra and i == 20 then
        new[#new + 1] = "EXTRA1"
        new[#new + 1] = "EXTRA2"
        new[#new + 1] = "EXTRA3"
      end
    else
      new[#new + 1] = "a" .. i
    end
  end
  return table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n"
end

local function two_sections(edit_extra)
  local aold, anew = bigtexts(edit_extra)
  return model.build({
    { path = "a.txt", old_text = aold, new_text = anew, status = "M" },
    { path = "b.txt", old_text = "9\n", new_text = "9\nplus\n", status = "M" },
  })
end

return {
  ["canvas: renders sections with anchors, locate works"] = function()
    local st = canvas.open(two_sections(), {})
    local s1, _ = canvas.section_rows(st, 1)
    local s2, e2 = canvas.section_rows(st, 2)
    H.eq(s1, 0)
    assert(s2 > 100 and e2 > s2, "a.txt section should be tall")
    local i, off = canvas.locate(st, s2)
    H.eq(i, 2); H.eq(off, 1)
    local i1, off1 = canvas.locate(st, 2)
    H.eq(i1, 1); H.eq(off1, 3)
  end,
  ["canvas: replace_section below viewport does not move view"] = function()
    local st = canvas.open(two_sections(), {})
    vim.api.nvim_win_call(st.win, function() vim.fn.winrestview({ topline = 1, lnum = 1 }) end)
    local before = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    local bigger = model.build_section("b.txt", "9\n", "9\nplus\nmore\nlines\n", "M")
    canvas.replace_section(st, 2, bigger)
    local after = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
    H.eq(after.topline, before.topline)
    H.eq(after.lnum, before.lnum)
    H.eq(st.sections[2].adds, 3)
    -- anchors still consistent
    local s2 = select(1, canvas.section_rows(st, 2))
    H.eq(canvas.locate(st, s2), 2)
  end,
  ["canvas: replace_section above viewport keeps visible text still"] = function()
    local st = canvas.open(two_sections(), {})
    -- scroll deep into a.txt so plenty of section content sits above the viewport
    local _, e1 = canvas.section_rows(st, 1)
    local deep = e1 - 10  -- near the end of a.txt's tall section
    vim.api.nvim_win_call(st.win, function()
      vim.fn.winrestview({ topline = deep, lnum = deep })
    end)
    local first_text_before = vim.api.nvim_win_call(st.win, function()
      return vim.fn.getline(vim.fn.line("w0"))
    end)
    -- regenerate a.txt with 3 extra added lines near its TOP (above viewport)
    local aold, anew = bigtexts(true)
    local bigger = model.build_section("a.txt", aold, anew, "M")
    canvas.replace_section(st, 1, bigger)
    local first_text_after = vim.api.nvim_win_call(st.win, function()
      return vim.fn.getline(vim.fn.line("w0"))
    end)
    H.eq(first_text_after, first_text_before)
  end,
  ["canvas: delete section"] = function()
    local st = canvas.open(two_sections(), {})
    canvas.replace_section(st, 1, nil)
    H.eq(#st.sections, 1)
    H.eq(st.sections[1].path, "b.txt")
    H.eq(canvas.locate(st, 0), 1)
  end,
}
```

Note for the implementer: the "above viewport" test regenerates the SAME section the viewport is inside (content changed above the visible part) — this exercises the *intersecting* branch's semantic-anchor path when the viewport is within the replaced section, which is the correct classification: the section range intersects the viewport. The invariant under test is only that the visible first line's text is unchanged.

- [ ] **Step 2: Run, FAIL. Implement `canvas.lua`** (~180 lines). Critical details: anchors created with `right_gravity = false, invalidate = false, undo_restore = false`; when replacing section i, `set_lines(start_row, end_row_excl)` where `end_row_excl` = next anchor's row — the next anchor sits at the first row NOT replaced, so it shifts correctly; when deleting the LAST section also trim any trailing blank line; after any structural change, section list and anchor list stay parallel (remove ids with `nvim_buf_del_extmark`). Section highlight reapply: clear namespace over the new range first (`nvim_buf_clear_namespace(buf, hl_ns, start, new_end)`).

- [ ] **Step 3: Run `make test` — green. Commit** — `feat: canvas buffer with anchored sections and stable splice`

---

### Task 8: jump.lua — excursion (jump into file, return with regeneration)

**Files:**
- Create: `lua/galley/jump.lua`, `tests/test_jump.lua`

**Interfaces:**
- Consumes: `canvas.locate/section_rows/replace_section/is_canvas_buf` (Task 7), `viewport` (Task 4), `model.build_section` (Task 6), `git.show_head` (Task 5).
- Produces (used by Task 9):
  - `jump.enter(state)` — from the canvas window: locate cursor row → `(section, entry)`; target line = `entry.new_lnum` or (for del/hdr entries) the first following entry with a `new_lnum`, else 1. Save excursion `{ path, view = winsaveview(), anchor = viewport.capture_from_entries(entries, top_offset_of_view), cursor = { new_lnum = target, content = entry.content } }` where `top_offset_of_view` = locate() offset of `line("w0")` clamped into this section (if w0 is in an earlier section, use offset 1). Then `vim.cmd.edit { vim.fs.joinpath(state.root, path), mods = { keepalt = true } }` in the canvas window, move cursor to target line col 0, and set buffer-local keymap `opts.keymaps.back` (default `<M-CR>`) → `require("galley.jump").back()`.
  - `jump.back()` — if no live excursion, no-op with `vim.notify` "no diff-canvas excursion". Else: read current content of the excursed file (loaded buffer via `nvim_buf_get_lines` if a buffer exists — unsaved edits count — else `io.open` read; file gone ⇒ `""`), `old = git.show_head(root, path)`, `new_section = model.build_section(path, old, content, status)`; switch the window back to the canvas buffer (`nvim_win_set_buf`); `canvas.replace_section(state, i, new_section)` (nil deletes when file reverted); restore viewport: resolve `excursion.anchor` against the new section's entries → topline; resolve `excursion.cursor` → cursor lnum (fall back to section start / nearest section when the section vanished); one `winrestview` call. Clear excursion.
  - Excursion state lives module-level; only one at a time (a second `enter` overwrites).

- [ ] **Step 1: Write failing tests `tests/test_jump.lua`** — use a real git fixture + real canvas in the runner's window:

```lua
local H = require("helpers")
local git = require("galley.git")
local model = require("galley.model")
local canvas = require("galley.canvas")
local jump = require("galley.jump")

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
```

- [ ] **Step 2: Run, FAIL. Implement `lua/galley/jump.lua`** (~120 lines) per interface. Detail: to compute `status` on back, reuse the section's stored `status`; content read must handle `nvim_buf_get_lines` needing `table.concat(lines, "\n") .. "\n"` (empty buffer ⇒ `""`).

- [ ] **Step 3: Run `make test` — green. Commit** — `feat: jump excursion with semantic position restore`

---

### Task 9: init.lua + config.lua + user command + E2E test + README

**Files:**
- Create: `lua/galley/init.lua`, `lua/galley/config.lua`, `plugin/galley.lua`, `tests/test_e2e.lua`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything prior.
- Produces (public API):
  - `require("galley").setup(opts)` — merge into defaults (`vim.tbl_deep_extend("force", ...)`); optional (plugin works with defaults without calling setup).
  - `config.defaults = { keymaps = { jump = "<CR>", back = "<M-CR>", close = "q", refresh = "R" }, context = 3 }`.
  - `require("galley").open()` — `git.root(vim.fn.getcwd())`; error notify when not a repo; collect changed files (worktree content read from loaded buffer if one exists, else disk; deleted ⇒ `""`), `model.build`, `canvas.open`, set canvas-local keymaps: jump→`jump.enter(state)`, close→`close()`, refresh→`refresh()`. Empty diff ⇒ canvas shows single line `-- no changes --`.
  - `.close()` — restore the window's previous buffer if still valid, else `enew`; keep canvas buffer hidden (state cached).
  - `.toggle()`, `.refresh()` (full re-collect + `render_all`).
  - `plugin/galley.lua`: `:Galley {open|close|toggle|refresh}` with completion, default subcommand `toggle`. Guard `vim.g.loaded_galley`.

- [ ] **Step 1: Write failing E2E test `tests/test_e2e.lua`**

```lua
local H = require("helpers")

return {
  ["e2e: open renders alphabetical, jump+edit+back round-trip"] = function()
    local root = H.git_fixture({
      committed = { ["src/z.lua"] = "return 1\n", ["src/a.lua"] = "return 2\n", ["top.txt"] = "t\n" },
      worktree = {
        ["src/z.lua"] = "return 10\n",
        ["src/a.lua"] = "return 20\n",
        ["top.txt"] = "T\n",
        ["new.txt"] = "brand new\n",
      },
    })
    vim.api.nvim_set_current_dir(root)
    local fm = require("galley")
    fm.open()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    -- alphabetical file order: new.txt, src/a.lua, src/z.lua, top.txt
    local order = {}
    for _, l in ipairs(lines) do
      local p = l:match("^▎ (%S+)")
      if p then order[#order + 1] = p end
    end
    H.eq(order, { "new.txt", "src/a.lua", "src/z.lua", "top.txt" })
    -- jump into src/a.lua's +return 20 line
    local target
    for i, l in ipairs(lines) do if l == "+return 20" then target = i end end
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert(vim.api.nvim_buf_get_name(0):find("src/a.lua", 1, true), "should be in a.lua")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return 99" })
    vim.api.nvim_feedkeys(vim.keycode("<M-CR>"), "x", false)
    local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local found = false
    for _, l in ipairs(after) do if l == "+return 99" then found = true end end
    assert(found, "canvas must show the edited content")
  end,
  ["e2e: toggle and no-repo error"] = function()
    local dir = H.tmpdir()
    vim.api.nvim_set_current_dir(dir)
    local fm = require("galley")
    local ok = pcall(fm.open)
    assert(ok, "open outside a repo must not throw (notify instead)")
  end,
}
```

Note: `nvim_feedkeys` with mode `"x"` executes pending keys synchronously — required headless.

- [ ] **Step 2: Run, FAIL. Implement `config.lua`, `init.lua`, `plugin/galley.lua`** per interface.

- [ ] **Step 3: Run FULL suite `make test` — all green.**

- [ ] **Step 4: Update README.md** — install (lazy.nvim spec), `:Galley`, default keymaps table, MVP scope + roadmap phases (treesitter tier, live watch, sidebar, scrollbar, virtualization, persistence).

- [ ] **Step 5: Commit** — `feat: public API, user command, e2e round-trip`

---

## Verification (whole-plan)

1. `make test` — every test green, exit 0.
2. Spike verdicts recorded in `spikes/README.md` (both GO).
3. Manual smoke (documented in README, executed by a human later): in any dirty repo `nvim`, `:Galley` → scroll, `<CR>` into a hunk (LSP attaches — it's a real `:edit`), edit, `<M-CR>` back → position and updated diff verified.
