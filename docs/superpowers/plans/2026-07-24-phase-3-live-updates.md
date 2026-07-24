# Phase 3 — Live Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The canvas keeps itself in sync with the working tree — file saves, external writes, and git state changes flow into per-section splices (insert/replace/delete) within ~200ms, without ever moving what the user is reading (the niri invariant).

**Architecture:** A reconcile engine (`watch.lua`) diffs the canvas's current sections against a freshly collected desired list (one debounced `git status` + per-file text collection via a new shared `collect.lua`, extracted from init.lua) and applies the difference through canvas primitives: the existing `replace_section` plus a new `insert_section`. Triggers are `BufWritePost`/`FocusGained` autocmds and targeted `vim.uv.new_fs_event` watchers (repo root non-recursive, `.git` for index/HEAD, parent dirs of changed files — Linux inotify has no recursive watch), all funneling into one 200ms-debounced dirty flag.

**Tech Stack:** Lua, Neovim ≥0.10 (dev env 0.12.4), `vim.uv` (fs_event + timer), bespoke headless test runner (`make test`; `vim.wait` pumps the uv loop so timers/fs_events are testable headless).

## Global Constraints

- Neovim ≥0.10; no external runtime dependencies; tests via `make test` (= `nvim --headless --clean -l tests/run.lua`; `FILTER=pat` filters by test NAME).
- **Niri invariant is law:** splice + view correction happen in one synchronous tick (no `vim.schedule` between `set_lines` and `winrestview`); content changes outside the viewport never move what the user is reading.
- Section anchors: extmarks in namespace `galley.canvas.anchors`, `right_gravity = false, invalidate = false, undo_restore = false`, one per section start + EOF sentinel. **Known landmine:** a left-gravity mark at the exact boundary row of an edit stays/collapses at that row — boundary anchors must be explicitly deleted and recreated after every splice/insert (canvas.lua's `replace_boundary_extmark` exists for this).
- Position identity is ALWAYS a semantic anchor resolved through viewport.lua — never a stored canvas line number.
- Sections stay sorted alphabetically by path (byte order); reconcile must preserve this.
- Sections carry `old_text`/`new_text` (Phase 2); reconcile uses string equality on those to decide whether a section needs replacing.
- Never attach a treesitter parser/highlighter/syntax to the canvas buffer.
- Canvas buffer settings unchanged (`nofile`, `bufhidden=hide`, `modifiable=false` toggled only inside canvas.lua writes).
- Require graph must stay acyclic: `watch` → {canvas, model, collect, config, hl}; `collect` → {git}; `init` → {watch, collect, …}; canvas never requires watch/hl.
- Linux inotify has no recursive watch: fs_event watchers are root dir (non-recursive) + `.git` dir + parent dirs of currently-changed files, refreshed after each reconcile. Subdirectory changes not covered by a watcher are picked up by `BufWritePost`/`FocusGained` — documented behavior, not a bug.
- Default config addition: `watch = { enabled = true, debounce_ms = 200 }`.
- Pure modules stay pure; timers/uv handles live only in watch.lua (and hl.lua's existing debounce).
- Commit after each green test cycle; commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Current suite is 56/56 green and must stay green.

## File Structure

- `lua/galley/canvas.lua` — MODIFY: add `insert_section` (new primitive; mirrors `replace_section`'s view-correction discipline).
- `lua/galley/collect.lua` — NEW: worktree/HEAD content collection (`collect.files(root)`), extracted verbatim from init.lua's private helpers.
- `lua/galley/watch.lua` — NEW: reconcile engine + triggers (`start`/`stop`/`reconcile`, module-level `on_empty` callback).
- `lua/galley/hl.lua` — MODIFY: add `hl.detach(state)` (augroup + timer + live_state cleanup; approved follow-up from the Phase 2 final review).
- `lua/galley/init.lua` — MODIFY: use collect.lua; start/stop watch on open/close; detach hl on close.
- `lua/galley/config.lua` — MODIFY: `watch` defaults.
- `tests/test_canvas.lua` — MODIFY: insert_section cases.
- `tests/test_watch.lua` — NEW: reconcile + trigger cases.
- `README.md` — MODIFY: live-update behavior + `watch` config.

---

### Task 1: `canvas.insert_section`

**Files:**
- Modify: `lua/galley/canvas.lua`
- Test: `tests/test_canvas.lua`

**Interfaces:**
- Consumes (already in canvas.lua): `get_row(state, id)`, `replace_boundary_extmark(state, idx, row)`, `win_showing_canvas(state)`, `win_view_info(win)`, `apply_section_hl(buf, start_row, section)`, `set_modifiable`, `render.section_lines(section)`, `ANCHOR_NS`/`ANCHOR_OPTS`, state shape `{buf, win, sections, anchor_ids, hl_ids, hooks?}`.
- Produces: `canvas.insert_section(state, i, section)` — inserts `section` BEFORE current index `i` (`i = #state.sections + 1` appends at EOF). Preconditions: `1 <= i <= #state.sections + 1` and `#state.sections >= 1` (0→N transitions use `render_all`). View correction same tick: insertion row entirely below viewport ⇒ nothing; at-or-above viewport top (`row <= top0`) ⇒ `topline`/`lnum` shift by `#new_lines` (what the user reads stays pinned; new content scrolls in above, out of view); inside the viewport ⇒ captured view restored unchanged (nothing at or above the viewport top moved). Updates `state.sections/anchor_ids/hl_ids` consistently; the boundary anchor previously at the insertion row is delete+recreated at its shifted row (landmine rule), and the new section gets a fresh anchor at the insertion row.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_canvas.lua` (it already has helpers for building big sections and opening the canvas — reuse its existing local fixture helpers; if it lacks a multi-section text generator, add one local helper in the same style as the file's existing fixtures):

```lua
T["canvas_insert keeps order, anchors, and rows consistent"] = function()
  local a = model.build_section("a.lua", "x\n", "x\ny\n", "M")
  local c = model.build_section("c.lua", "x\n", "x\nz\n", "M")
  local b = model.build_section("b.lua", "x\n", "x\nw\n", "M")
  local st = canvas.open({ a, c }, {})

  canvas.insert_section(st, 2, b)

  H.eq(#st.sections, 3)
  H.eq({ st.sections[1].path, st.sections[2].path, st.sections[3].path },
    { "a.lua", "b.lua", "c.lua" })
  -- rows are contiguous and non-overlapping, resolved live from anchors
  local prev_end = 0
  for i = 1, 3 do
    local srow, erow = canvas.section_rows(st, i)
    H.eq(srow, prev_end, "section " .. i .. " starts where previous ended")
    assert(erow > srow, "non-empty section")
    prev_end = erow
  end
  -- the inserted section's rendered lines are actually at its rows
  local srow = (canvas.section_rows(st, 2))
  local first = vim.api.nvim_buf_get_lines(st.buf, srow, srow + 1, false)[1]
  assert(first:find("b.lua", 1, true), "b.lua header at inserted rows, got: " .. first)
  -- EOF sentinel intact: locate on the last row maps into section 3
  local last_row0 = vim.api.nvim_buf_line_count(st.buf) - 1
  local li = (canvas.locate(st, last_row0))
  H.eq(li, 3)
end

T["canvas_insert appends at EOF with i = n + 1"] = function()
  local a = model.build_section("a.lua", "x\n", "x\ny\n", "M")
  local d = model.build_section("d.lua", "x\n", "x\nq\n", "M")
  local st = canvas.open({ a }, {})
  canvas.insert_section(st, 2, d)
  H.eq(#st.sections, 2)
  H.eq(st.sections[2].path, "d.lua")
  local srow, erow = canvas.section_rows(st, 2)
  H.eq(erow, vim.api.nvim_buf_line_count(st.buf), "section 2 ends at EOF")
  assert(srow < erow)
end

T["canvas_insert above viewport keeps visible text pinned"] = function()
  -- two big sections; scroll into the second, insert before it
  local big = {}
  for i = 1, 120 do big[i] = ("line %d"):format(i) end
  local old = table.concat(big, "\n") .. "\n"
  local new = old:gsub("line 60", "line 60 changed")
  local a = model.build_section("a.txt", old, new, "M")
  local z = model.build_section("z.txt", old, new, "M")
  local m = model.build_section("m.txt", old, new, "M")
  local st = canvas.open({ a, z }, {})

  -- scroll so the viewport sits inside section 2 (z.txt)
  local z_start = (canvas.section_rows(st, 2))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = z_start + 2, lnum = z_start + 2 })
  end)
  local before_top = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)

  canvas.insert_section(st, 2, m) -- lands entirely above the viewport

  local after_top = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)
  H.eq(after_top, before_top, "topmost visible line must not change")
end

T["canvas_insert below viewport leaves the view untouched"] = function()
  local a = model.build_section("a.lua", "x\n", "x\ny\n", "M")
  local d = model.build_section("d.lua", "x\n", "x\nq\n", "M")
  local st = canvas.open({ a }, {})
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  local before = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
  canvas.insert_section(st, 2, d)
  local after = vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
  H.eq(after.topline, before.topline)
  H.eq(after.lnum, before.lnum)
end
```

(Adjust `local` requires at the top of test_canvas.lua only if `model` isn't already required there.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test FILTER=canvas_insert`
Expected: FAIL — `attempt to call field 'insert_section' (a nil value)`.

- [ ] **Step 3: Implement**

Add to `lua/galley/canvas.lua` (after `replace_section`, before `return M`):

```lua
--- Inserts `section` BEFORE current section index i (i = #sections + 1
--- appends at EOF), correcting the view in the same synchronous tick so the
--- niri invariant holds. Precondition: the canvas is non-empty
--- (#state.sections >= 1) -- the 0 -> N transition goes through render_all.
function M.insert_section(state, i, section)
  local row = get_row(state, state.anchor_ids[i])
  local new_lines = render.section_lines(section)

  local win_ok = win_showing_canvas(state)
  local branch, view
  if win_ok then
    local info = win_view_info(state.win)
    local top0, bot0 = info.top - 1, info.bot - 1
    view = info.view
    if row > bot0 then
      branch = "below"
    elseif row <= top0 then
      branch = "above"
    else
      branch = "intersect"
    end
  else
    branch = "none"
  end

  set_modifiable(state.buf, true)
  vim.api.nvim_buf_set_lines(state.buf, row, row, false, new_lines)
  -- The left-gravity boundary anchor sitting exactly at `row` stays put
  -- through the insert and would wrongly become the inserted section's
  -- start; recreate it at its shifted position first, then give the new
  -- section its own anchor at `row` (see the module-level gravity note).
  replace_boundary_extmark(state, i, row + #new_lines)
  table.insert(state.anchor_ids, i,
    vim.api.nvim_buf_set_extmark(state.buf, ANCHOR_NS, row, 0, ANCHOR_OPTS))
  table.insert(state.sections, i, section)
  table.insert(state.hl_ids, i, apply_section_hl(state.buf, row, section))
  set_modifiable(state.buf, false)

  -- View correction, same synchronous tick.
  if branch == "above" then
    -- Insertion at or above the viewport top: shift so what the user reads
    -- stays pinned; the new content scrolls in above, out of view.
    view.topline = view.topline + #new_lines
    view.lnum = view.lnum + #new_lines
    vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
  elseif branch == "intersect" then
    -- Insertion point is inside the viewport: nothing at or above the
    -- viewport top moved, so the captured view is still correct as-is.
    vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
  end
  -- "below"/"none": the edit cannot move rows the user is looking at.
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test FILTER=canvas_insert` then `make test` (full suite, 60/60 expected).

- [ ] **Step 5: Commit**

```bash
git add lua/galley/canvas.lua tests/test_canvas.lua
git commit -m "feat: canvas.insert_section with same-tick view correction"
```

---

### Task 2: `collect.lua` extraction + reconcile engine

**Files:**
- Create: `lua/galley/collect.lua`
- Create: `lua/galley/watch.lua` (reconcile half only — triggers are Task 3)
- Modify: `lua/galley/init.lua` (use collect.lua; drop the now-moved private helpers)
- Test: `tests/test_watch.lua`

**Interfaces:**
- Consumes: `git.changed_files(root)` → `{ {path, status}, ... }`; `git.show_head(root, path)` → string|nil; `model.build(files, context)` → sorted sections (each carrying `old_text`/`new_text`); `canvas.render_all/replace_section/insert_section/section_rows`; `hl.apply_now(state)`; `config.options.context`.
- Produces:
  - `collect.files(root)` → `{ {path, status, old_text, new_text}, ... }` — exact behavior of init.lua's current `collect_files` (loaded-buffer content preferred, `"D"` ⇒ `""`, unreadable ⇒ `""`).
  - `watch.reconcile(state)` — synchronous full reconcile: collects desired sections; 0↔N transitions go through `canvas.render_all` (and fire `watch.on_empty()` when the result is empty, if set); otherwise a sorted merge-walk by path applying `replace_section` (texts differ), `replace_section(state, i, nil)` (path gone), `insert_section` (new path); ends with `hl.apply_now(state)`. Sections whose `old_text` AND `new_text` are unchanged are not touched (no splice, anchors untouched).
  - `watch.on_empty` — assignable module field (callback), nil-safe.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_watch.lua`:

```lua
local H = require("helpers")
local model = require("galley.model")
local canvas = require("galley.canvas")
local collect = require("galley.collect")
local watch = require("galley.watch")

local T = {}

local function write_file(root, rel, content)
  local abs = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(vim.fs.dirname(abs), "p")
  local f = assert(io.open(abs, "w"))
  f:write(content)
  f:close()
end

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

--- Repo with three committed files; b.txt and d.txt modified in worktree.
local function fixture()
  local committed = {
    ["b.txt"] = bigtext(80, "b"),
    ["d.txt"] = bigtext(80, "d"),
    ["f.txt"] = bigtext(80, "f"),
  }
  local root = H.git_fixture({
    committed = committed,
    worktree = {
      ["b.txt"] = bigtext(80, "b"):gsub("b line 40", "b line 40 changed"),
      ["d.txt"] = bigtext(80, "d"):gsub("d line 40", "d line 40 changed"),
    },
  })
  return root
end

local function open_state(root)
  local sections = model.build(collect.files(root), 3)
  local st = canvas.open(sections, {})
  st.root = root
  return st
end

T["watch_collect files matches init behavior"] = function()
  local root = fixture()
  local files = collect.files(root)
  H.eq(#files, 2)
  table.sort(files, function(x, y) return x.path < y.path end)
  H.eq(files[1].path, "b.txt")
  H.eq(files[1].status, "M")
  assert(files[1].old_text:find("b line 40", 1, true))
  assert(files[1].new_text:find("b line 40 changed", 1, true))
end

T["watch_reconcile replaces a modified section in place"] = function()
  local root = fixture()
  local st = open_state(root)
  H.eq(#st.sections, 2)

  write_file(root, "b.txt", (bigtext(80, "b"):gsub("b line 20", "b line 20 EDITED")))
  watch.reconcile(st)

  H.eq(#st.sections, 2)
  H.eq(st.sections[1].path, "b.txt")
  assert(st.sections[1].new_text:find("b line 20 EDITED", 1, true), "section regenerated")
  -- buffer content actually spliced
  local srow, erow = canvas.section_rows(st, 1)
  local lines = table.concat(vim.api.nvim_buf_get_lines(st.buf, srow, erow, false), "\n")
  assert(lines:find("b line 20 EDITED", 1, true), "canvas shows the new diff")
end

T["watch_reconcile inserts a new file alphabetically"] = function()
  local root = fixture()
  local st = open_state(root)
  write_file(root, "c.txt", "brand new\n")
  watch.reconcile(st)
  H.eq(#st.sections, 3)
  H.eq({ st.sections[1].path, st.sections[2].path, st.sections[3].path },
    { "b.txt", "c.txt", "d.txt" })
  local prev_end = 0
  for i = 1, 3 do
    local srow, erow = canvas.section_rows(st, i)
    H.eq(srow, prev_end)
    prev_end = erow
  end
end

T["watch_reconcile deletes a reverted file's section"] = function()
  local root = fixture()
  local st = open_state(root)
  write_file(root, "b.txt", bigtext(80, "b")) -- back to HEAD content
  watch.reconcile(st)
  H.eq(#st.sections, 1)
  H.eq(st.sections[1].path, "d.txt")
end

T["watch_reconcile handles N to 0 and 0 to N via render_all"] = function()
  local root = fixture()
  local st = open_state(root)
  local empty_fired = false
  watch.on_empty = function() empty_fired = true end

  write_file(root, "b.txt", bigtext(80, "b"))
  write_file(root, "d.txt", bigtext(80, "d"))
  watch.reconcile(st)
  H.eq(#st.sections, 0)
  H.eq(empty_fired, true, "on_empty fired")

  write_file(root, "d.txt", (bigtext(80, "d"):gsub("d line 1\n", "d line 1 back\n")))
  watch.reconcile(st)
  H.eq(#st.sections, 1)
  H.eq(st.sections[1].path, "d.txt")
  watch.on_empty = nil
end

T["watch_reconcile replaces the only section with a different file cleanly"] = function()
  -- {b} -> {c}: a naive merge-walk would delete the last section (leaving
  -- the placeholder-line empty canvas) and then try to splice into it,
  -- stranding a stray blank line. Must route through render_all instead.
  local root = H.git_fixture({
    committed = { ["b.txt"] = bigtext(40, "b") },
    worktree = { ["b.txt"] = (bigtext(40, "b"):gsub("b line 5", "b line 5 X")) },
  })
  local st = open_state(root)
  H.eq(#st.sections, 1)

  write_file(root, "b.txt", bigtext(40, "b")) -- revert b
  write_file(root, "c.txt", "brand new\n")    -- add untracked c
  watch.reconcile(st)

  H.eq(#st.sections, 1)
  H.eq(st.sections[1].path, "c.txt")
  local srow, erow = canvas.section_rows(st, 1)
  H.eq(srow, 0)
  H.eq(erow, vim.api.nvim_buf_line_count(st.buf), "no stray trailing line")
end

T["watch_reconcile untouched sections keep their anchors and view (niri)"] = function()
  local root = fixture()
  local st = open_state(root)

  -- viewport inside section 2 (d.txt)
  local d_start = (canvas.section_rows(st, 2))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = d_start + 3, lnum = d_start + 3 })
  end)
  local before_top = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)

  -- grow b.txt's diff (above the viewport) by editing more lines
  write_file(root, "b.txt",
    (bigtext(80, "b"):gsub("b line 10", "b line 10 X"):gsub("b line 40", "b line 40 Y")))
  watch.reconcile(st)

  local after_top = vim.api.nvim_win_call(st.win, function()
    return vim.fn.getline(vim.fn.line("w0"))
  end)
  H.eq(after_top, before_top, "visible text pinned through above-viewport splice")
end

return T
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test FILTER=watch_`
Expected: FAIL — `module 'galley.collect' not found`.

- [ ] **Step 3: Implement `collect.lua`**

Create `lua/galley/collect.lua` — move (verbatim, including comments) `find_loaded_buf`, `read_worktree_content`, and `collect_files` out of init.lua:

```lua
local git = require("galley.git")

local M = {}

--- Find a currently-loaded buffer showing `abs_path`, if any.
local function find_loaded_buf(abs_path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs_path then
      return b
    end
  end
  return nil
end

--- Current worktree content for a changed file: prefer a loaded buffer's
--- (possibly unsaved) lines, else read the file fresh off disk, else ""
--- when the file has been deleted or is otherwise unreadable.
local function read_worktree_content(root, rel_path, status)
  if status == "D" then
    return ""
  end

  local abs_path = vim.fs.joinpath(root, rel_path)
  local buf = find_loaded_buf(abs_path)
  if buf then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines == 0 or (#lines == 1 and lines[1] == "") then
      return ""
    end
    return table.concat(lines, "\n") .. "\n"
  end

  local f = io.open(abs_path, "r")
  if not f then
    return ""
  end
  local content = f:read("*a") or ""
  f:close()
  return content
end

--- All changed files with their HEAD and worktree contents, ready for
--- model.build.
function M.files(root)
  local files = {}
  for _, f in ipairs(git.changed_files(root)) do
    files[#files + 1] = {
      path = f.path,
      status = f.status,
      old_text = git.show_head(root, f.path) or "",
      new_text = read_worktree_content(root, f.path, f.status),
    }
  end
  return files
end

return M
```

In `init.lua`: add `local collect = require("galley.collect")`, delete the three moved private functions, and change both call sites (`M.open`, `M.refresh`) from `collect_files(...)` to `collect.files(...)`.

- [ ] **Step 4: Implement the reconcile half of `watch.lua`**

Create `lua/galley/watch.lua`:

```lua
local canvas = require("galley.canvas")
local model = require("galley.model")
local collect = require("galley.collect")
local config = require("galley.config")
local hl = require("galley.hl")

local W = {}

--- Assignable callback: fired by reconcile when the canvas becomes empty
--- (all changes gone), so the owner can render its empty-state message.
W.on_empty = nil

--- Synchronous full reconcile of the live canvas against the working tree:
--- collect desired sections, then splice the difference section-by-section.
--- Sections whose old_text AND new_text are unchanged are never touched, so
--- their anchors, highlight marks, and rows stay exactly as they are -- the
--- niri invariant then rests entirely on the canvas splice primitives.
function W.reconcile(state)
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local desired = model.build(collect.files(state.root), config.options.context)

  -- 0 <-> N transitions: the empty canvas holds a placeholder line, not
  -- sections; splicing against it is meaningless. Full re-render instead.
  if #state.sections == 0 or #desired == 0 then
    if #state.sections ~= 0 or #desired ~= 0 then
      canvas.render_all(state, desired)
      if #desired == 0 and W.on_empty then
        W.on_empty()
      end
      hl.apply_now(state)
    end
    return
  end

  -- Both lists are sorted by path: sorted merge-walk.
  local i, j = 1, 1
  while i <= #state.sections or j <= #desired do
    local cur = state.sections[i]
    local des = desired[j]
    if cur and des and cur.path == des.path then
      if cur.old_text ~= des.old_text or cur.new_text ~= des.new_text then
        canvas.replace_section(state, i, des)
      end
      i, j = i + 1, j + 1
    elseif cur and (not des or cur.path < des.path) then
      if #state.sections == 1 then
        -- Deleting the last remaining section would leave the
        -- placeholder-line empty canvas, which splices can't target;
        -- finish with a full render of whatever is desired instead.
        canvas.render_all(state, desired)
        hl.apply_now(state)
        return
      end
      canvas.replace_section(state, i, nil) -- delete shrinks the list; keep i
    else
      canvas.insert_section(state, i, des)
      i, j = i + 1, j + 1
    end
  end

  hl.apply_now(state)
end

return W
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test FILTER=watch_` then `make test` (full suite — the init.lua refactor must leave every existing test green; expected 67/67).

- [ ] **Step 6: Commit**

```bash
git add lua/galley/collect.lua lua/galley/watch.lua lua/galley/init.lua tests/test_watch.lua
git commit -m "feat: reconcile engine splices working-tree changes into the canvas"
```

---

### Task 3: Triggers, lifecycle, and wiring

**Files:**
- Modify: `lua/galley/watch.lua` (triggers + start/stop)
- Modify: `lua/galley/hl.lua` (`hl.detach`)
- Modify: `lua/galley/config.lua` (`watch` defaults)
- Modify: `lua/galley/init.lua` (start/stop/detach wiring)
- Modify: `README.md`
- Test: `tests/test_watch.lua` (trigger cases appended)

**Interfaces:**
- Consumes: Task 2's `watch.reconcile`; hl.lua's module internals (augroup `galley.hl`, module-level `timer` and `live_state`); `config.options.watch`.
- Produces:
  - `watch.start(state, opts)` — `opts = { debounce_ms = 200 }` (enabled is checked by the caller). Stops any previous watch first (idempotent). Installs: augroup `galley.watch` with `BufWritePost` (only files under `state.root`) and `FocusGained`, both funneling into a single debounced dirty timer; fs_event watchers on the repo root (non-recursive), `<root>/.git` (filtering out `*.lock` churn), and the parent directories of currently-changed files; watcher set refreshed after each reconcile.
  - `watch.stop()` — stops the timer, closes all fs_event handles, deletes the augroup; safe to call repeatedly/when never started.
  - `hl.detach(state)` — clears augroup `galley.hl`, stops the module debounce timer, and resets `live_state` when it is `state`; nil-safe.
  - config: `defaults.watch = { enabled = true, debounce_ms = 200 }`.
  - init: `M.open` sets `watch.on_empty` (shows the empty message) and calls `watch.start(st, config.options.watch)` when `config.options.watch.enabled`; `M.close` (in the branch that actually restores the window) calls `watch.stop()` and `hl.detach(state)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_watch.lua` (before `return T`):

```lua
T["watch_trigger BufWritePost reconciles after debounce"] = function()
  local root = fixture()
  local st = open_state(root)
  watch.start(st, { debounce_ms = 20 })

  -- edit b.txt through a real buffer + :write, firing BufWritePost
  local abs = vim.fs.joinpath(root, "b.txt")
  vim.cmd.edit(abs)
  vim.api.nvim_buf_set_lines(0, 4, 5, false, { "b line 5 WRITTEN" })
  vim.cmd.write()
  vim.api.nvim_win_set_buf(0, st.buf) -- back to the canvas

  local ok = vim.wait(2000, function()
    return st.sections[1] and st.sections[1].new_text:find("b line 5 WRITTEN", 1, true) ~= nil
  end, 10)
  H.eq(ok, true, "debounced reconcile picked up the written change")
  watch.stop()
end

T["watch_trigger fs_event catches external writes at repo root"] = function()
  local root = fixture()
  local st = open_state(root)
  watch.start(st, { debounce_ms = 20 })

  -- external write: no nvim buffer involved
  write_file(root, "b.txt", (bigtext(80, "b"):gsub("b line 7", "b line 7 EXTERNAL")))

  local ok = vim.wait(4000, function()
    return st.sections[1] and st.sections[1].new_text:find("b line 7 EXTERNAL", 1, true) ~= nil
  end, 10)
  H.eq(ok, true, "fs_event triggered a reconcile")
  watch.stop()
end

T["watch_trigger stop() really stops"] = function()
  local root = fixture()
  local st = open_state(root)
  watch.start(st, { debounce_ms = 20 })
  watch.stop()

  write_file(root, "b.txt", (bigtext(80, "b"):gsub("b line 9", "b line 9 IGNORED")))
  vim.wait(300, function() return false end, 50) -- give any stray timer a chance
  H.eq(st.sections[1].new_text:find("b line 9 IGNORED", 1, true), nil,
    "no reconcile after stop")
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test FILTER=watch_trigger`
Expected: FAIL — `attempt to call field 'start' (a nil value)`.

- [ ] **Step 3: Implement triggers in `watch.lua`**

Add to `watch.lua` (module locals near the top, functions before `return W`):

```lua
local uv = vim.uv

-- Trigger state: one live watched canvas at a time (mirrors init's
-- singleton). All handles are torn down by stop().
local live = nil
local debounce_ms = 200
local timer = nil
local aug = nil
local fs_handles = {}

local function close_fs_handles()
  for _, h in ipairs(fs_handles) do
    pcall(function()
      h:stop()
      h:close()
    end)
  end
  fs_handles = {}
end

local function mark_dirty()
  if not live then
    return
  end
  if not timer then
    timer = uv.new_timer()
  end
  timer:stop()
  timer:start(debounce_ms, 0, vim.schedule_wrap(function()
    local state = live
    if state then
      W.reconcile(state)
      refresh_fs_watches(state) -- luacheck: ignore (forward-declared below)
    end
  end))
end

local function watch_dir(path, filter)
  local h = uv.new_fs_event()
  if not h then
    return
  end
  local ok = h:start(path, {}, function(_, filename, _)
    if filter and filename and not filter(filename) then
      return
    end
    mark_dirty()
  end)
  if not ok then
    pcall(function() h:close() end)
    return
  end
  fs_handles[#fs_handles + 1] = h
end

--- (Re)build the fs_event watcher set: repo root (non-recursive -- Linux
--- inotify has no recursive watch), .git (index/HEAD flips; *.lock churn
--- filtered), and the parent dirs of currently-changed files. Subdir
--- changes with no watcher are covered by BufWritePost/FocusGained.
function refresh_fs_watches(state)
  close_fs_handles()
  if not live then
    return
  end
  watch_dir(state.root)
  watch_dir(vim.fs.joinpath(state.root, ".git"), function(name)
    return not name:match("%.lock$")
  end)
  local seen = {}
  for _, sec in ipairs(state.sections) do
    local dir = vim.fs.dirname(vim.fs.joinpath(state.root, sec.path))
    if dir ~= state.root and not seen[dir] then
      seen[dir] = true
      watch_dir(dir)
    end
  end
end

--- Start live-watching for `state` (stopping any previous watch first).
function W.start(state, opts)
  W.stop()
  live = state
  debounce_ms = (opts and opts.debounce_ms) or 200

  aug = vim.api.nvim_create_augroup("galley.watch", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = aug,
    callback = function(ev)
      if not live then
        return
      end
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if name ~= "" and vim.startswith(name, live.root .. "/") then
        mark_dirty()
      end
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = aug,
    callback = mark_dirty,
  })

  refresh_fs_watches(state)
end

--- Tear everything down. Safe when never started.
function W.stop()
  if timer then
    timer:stop()
  end
  close_fs_handles()
  if aug then
    pcall(vim.api.nvim_del_augroup_by_id, aug)
    aug = nil
  end
  live = nil
end
```

Note on the forward reference: `mark_dirty` calls `refresh_fs_watches`, which is defined after it. Declare it as a local upvalue above `mark_dirty` (`local refresh_fs_watches` before `mark_dirty`, then `refresh_fs_watches = function(state) ... end`) — do NOT leave it a global. Adjust the snippet accordingly when writing the file.

- [ ] **Step 4: `hl.detach`, config, init wiring**

`lua/galley/hl.lua` — add after `M.attach`:

```lua
--- Undo attach: remove the scroll trigger, cancel any pending debounce, and
--- release the live-state guard so a stale callback can never fire against
--- this state. Nil-safe; safe to call when never attached.
function M.detach(state)
  pcall(vim.api.nvim_del_augroup_by_name, "galley.hl")
  if timer then
    timer:stop()
  end
  if live_state == state then
    live_state = nil
  end
end
```

(This requires `M.detach` to be defined AFTER the `local timer` / `local live_state` declarations so the upvalues bind — same ordering rule the stale-state fix established.)

`lua/galley/config.lua` — add to `M.defaults`:

```lua
  watch = {
    enabled = true,
    debounce_ms = 200,
  },
```

`lua/galley/init.lua`:
- add `local watch = require("galley.watch")` to the requires;
- in `M.open`, after the `hl.attach` block:

```lua
  if config.options.watch.enabled then
    watch.on_empty = function()
      show_empty_message(st)
    end
    watch.start(st, config.options.watch)
  end
```

- in `M.close`, immediately before the `prev_buf` restore logic (i.e. after the two early-return guards):

```lua
  watch.stop()
  hl.detach(state)
```

`README.md` — document: the canvas auto-refreshes on save, focus, and external file changes (200ms debounce); `watch` config table (`enabled`, `debounce_ms`); the non-recursive-watch caveat (changes in unwatched subdirectories are picked up on save or focus).

- [ ] **Step 5: Run the trigger tests, then the full suite**

Run: `make test FILTER=watch_trigger` (3/3), then `make test` — expected 70/70, zero warnings, no flakiness on a re-run (`make test` twice).

- [ ] **Step 6: Commit**

```bash
git add lua/galley/ tests/test_watch.lua README.md
git commit -m "feat: live watch triggers with debounced reconcile"
```

---

## Self-Review Notes

- Spec coverage vs concept plan §4: BufWritePost ✓, FocusGained rescan ✓, fs_event targeted set (root non-recursive + .git + changed-file dirs) ✓, debounced queue (single dirty flag → full reconcile — deliberately simpler than a per-file queue; one `git status` per flush is bounded by the 200ms debounce) ✓, splice-with-invariant reuses `replace_section` + new `insert_section` ✓. The async `vim.system` status pipeline is deferred: collection stays synchronous inside the scheduled flush (fast at MVP scale; Phase 6 revisits for huge repos) — documented deviation, keeps the splice+restore single-tick guarantee trivially.
- `hl.detach` is the Phase 2 final review's approved follow-up, landed here because `close()` now gains a teardown path anyway.
- Type consistency: `watch.reconcile(state)` used by both Task 2 tests and Task 3's debounce; `collect.files(root)` consumed by init and watch; `insert_section(state, i, section)` consumed by reconcile with the same `i` semantics tested in Task 1.
