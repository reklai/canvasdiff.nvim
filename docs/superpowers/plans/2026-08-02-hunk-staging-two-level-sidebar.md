# Hunk Staging + Two-Level Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage/unstage a single hunk from the canvas or sidebar, walk the review hunk-by-hunk with Ctrl+N/P, show hunk rows in the sidebar mirroring fold state, and extend the pinned header with a `→ hunk · n/total` breadcrumb.

**Architecture:** The cursor decides verb granularity (hunk inside a hunk, file on headers/placeholders/sidebar file rows); Shift+S/U act on the file from anywhere. Staging is a line splice on the index blob (no patches): stage maps the cursor onto the index→worktree pair, unstage onto HEAD→index. All new display (sidebar hunk rows, crumb) derives from a per-hunk metadata table published by the diff model — nothing about hunks is persisted.

**Tech Stack:** Lua, Neovim 0.12+, git plumbing (`show :0:`, `hash-object -w`, `update-index --cacheinfo`), the repo's own test runner (`nvim --headless --clean -l test/run.lua`).

**Spec:** `docs/superpowers/specs/2026-08-02-hunk-staging-two-level-sidebar-design.md` — decisions 1–8 there are binding.

## Global Constraints

- Neovim 0.12+ only; no new dependencies.
- No session schema change; nothing about hunks is persisted.
- No mode, no per-hunk stage/stale markers, no hunk staging on binaries/renames/read-only ranges, no word-level staging (spec non-goals).
- Every new keymap action goes through `input/keys.lua` `K.specs` (cheatsheet/help pick it up automatically); every new highlight group is `default = true`.
- All git access stays inside `source/repository.lua` (architecture rules are executable — `make architecture` must stay green).
- Comments follow the repo's voice: state the constraint the code can't show, never narrate the change.
- Test commands: `make test` (all), `make test SUITE=unit FILTER='^ctx_'` (subset). The runner fails a 0-test run — a FILTER that matches nothing exits 1.
- Commit style: lowercase `feat:`/`fix:`/`docs:` + narrative body; end body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

- `lua/canvasdiff/diff/model.lua` — **modify**: publish `section.hunks[gi]` metadata (new_lo/new_hi span, adds, dels, label, pure_del, header).
- `lua/canvasdiff/diff/context.lua` — **create**: cursor-context resolver (`scope`, `section`, `hunk`).
- `lua/canvasdiff/diff/stage.lua` — **create**: pure splice engine (pair hunks, overlap pick, index-content splice).
- `lua/canvasdiff/diff.lua` — **modify**: export `context` and `stage` on the diff facade.
- `lua/canvasdiff/source/repository.lua` — **modify**: blob plumbing (`index_blob`, `head_blob`, `set_index_blob`).
- `lua/canvasdiff/App.lua` — **modify**: `App:stage_hunk`, context-sensitive `stage`/`unstage` actions, `stage_file`/`unstage_file` capitals, hunk cycling wiring, sidebar `on_stage` hunk pass-through.
- `lua/canvasdiff/input/motions.lua` — **modify**: `M.hunk_stops`, `M.cycle_hunk`; `M.cycle` stays (file cycle, now unbound by default).
- `lua/canvasdiff/input/keys.lua` — **modify**: specs for `stage_file`, `unstage_file`, `cycle_file_next`, `cycle_file_prev`; reworded cycle descs.
- `lua/canvasdiff/config/settings.lua` — **modify**: default keys for the capitals; `crumb` glyph (`" → "`, ascii `" -> "`).
- `lua/canvasdiff/ui/sidebar.lua` — **modify**: hunk entries in `build_entries`/`render_lines`, fold summaries, hunk tracking/select/stage, read-only winbar group.
- `lua/canvasdiff/ui/sticky_header.lua` — **modify**: crumb + ordinal in `SH.content`.
- Tests: `test/unit/test_context.lua`, `test/unit/test_stage_splice.lua` (create); `test/unit/test_model.lua`, `test/unit/test_motions.lua`, `test/unit/test_ui.lua`, `test/unit/test_sticky_content.lua`, `test/unit/test_winbar.lua`, `test/integration/test_git.lua`, `test/integration/test_sidebar.lua`, `test/e2e/test_e2e.lua`, `test/fault/test_chaos.lua` (modify).
- Docs: `README.md`, `doc/canvasdiff.txt` (modify, Task 11).

---

### Task 1: Per-hunk metadata on the diff model

**Files:**
- Modify: `lua/canvasdiff/diff/model.lua` (the section builder that already tracks `new_span_lo`/`new_span_hi` per hunk group, around lines 163–290)
- Test: `test/unit/test_model.lua`

**Interfaces:**
- Produces: `section.hunks` — array indexed by hunk ordinal `gi` (same `gi` as `entry.hunk_idx`), each element `{ header = "@@ -a,b +c,d @@", new_lo = int|nil, new_hi = int|nil, adds = int, dels = int, label = "first changed line text", pure_del = bool }`. `new_lo/new_hi` are worktree (new-side) line numbers; nil for a pure-deletion hunk. `label` is the first `add` entry's content, or the first `del` entry's content when the hunk has no adds (`pure_del = true`).
- Consumed by Tasks 2, 4, 7, 8, 9.

- [ ] **Step 1: Write the failing tests** (append to `test/unit/test_model.lua`, following its existing `T["name"] = function()` style and `H.eq`):

```lua
T["model_ sections publish per-hunk metadata"] = function()
  local old = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n"
  local new = "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\neight\nnine\nten\nELEVEN\n"
  local section = model.build_section("a.lua", old, new, 3)
  H.eq(#section.hunks, section.nhunks, "one metadata row per hunk")
  local h1 = section.hunks[1]
  H.eq(h1.label, "THREE")
  H.eq(h1.pure_del, false)
  H.eq(h1.adds, 1)
  H.eq(h1.dels, 1)
  H.eq(h1.new_lo, 3)
  H.eq(h1.new_hi, 3)
end

T["model_ a pure-deletion hunk labels its removed line"] = function()
  local old = "one\ntwo\nGONE\nthree\nfour\nfive\nsix\nseven\n"
  local new = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n"
  local section = model.build_section("a.lua", old, new, 1)
  local h = section.hunks[1]
  H.eq(h.pure_del, true)
  H.eq(h.label, "GONE")
  H.eq(h.new_lo, nil)
  H.eq(h.adds, 0)
  H.eq(h.dels, 1)
end
```

Adapt the two constructor calls to the module's actual public builder (the same function the existing model tests call — reuse their fixture idiom verbatim; if the builder takes a table, mirror the neighboring test's call shape).

- [ ] **Step 2: Run to verify failure**

Run: `make test SUITE=unit FILTER='^model_ sections publish'`
Expected: FAIL — `section.hunks` is nil.

- [ ] **Step 3: Implement** — inside the group loop that already computes `new_span_lo`/`new_span_hi` and pushes `hunk_hdr` entries, accumulate per-group counters, then attach:

```lua
-- Alongside the existing per-group span bookkeeping:
local hunk_adds, hunk_dels, hunk_label, hunk_del_label = 0, 0, nil, nil
-- in push(): on kind == "add": hunk_adds = hunk_adds + 1; hunk_label = hunk_label or content
--            on kind == "del": hunk_dels = hunk_dels + 1; hunk_del_label = hunk_del_label or content
-- when the group closes (where the hunk_hdr entry is inserted):
hunks[gi] = {
  header = hunk_header(a, b, c, d),
  new_lo = new_span_lo, new_hi = new_span_hi,
  adds = hunk_adds, dels = hunk_dels,
  label = hunk_label or hunk_del_label or "",
  pure_del = hunk_adds == 0 and hunk_dels > 0,
}
```

and put `hunks = hunks` on the returned section next to `nhunks`. Binary and rename sections get `hunks = {}`.

- [ ] **Step 4: Run the unit suite**

Run: `make test SUITE=unit`
Expected: all PASS (existing model tests must not change — this is additive).

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/diff/model.lua test/unit/test_model.lua
git commit -m "feat: sections publish per-hunk metadata

Span, counts, label and pure_del per hunk ordinal, computed where the
group bookkeeping already lives -- the one authoritative answer the
resolver, sidebar rows, crumb and stage mapping all read."
```

---

### Task 2: The cursor-context resolver

**Files:**
- Create: `lua/canvasdiff/diff/context.lua`
- Modify: `lua/canvasdiff/diff.lua` (facade export)
- Test: `test/unit/test_context.lua`

**Interfaces:**
- Consumes: `canvas.locate(state, row0)` → `index, offset`; `entry.kind` (`"file_hdr" | "hunk_hdr" | "ctx" | "add" | "del" | "binary"`), `entry.hunk_idx`; `fold.hidden(state, path)`.
- Produces: `context.resolve(state, row0)` → `{ scope = "hunk", section = i, hunk = gi }` on hunk headers and hunk body rows; `{ scope = "file", section = i }` on file headers, binary rows, and folded placeholders; `nil` off the canvas (no section). This is the ONE home for verb granularity — Tasks 5 and 8 both call it.

- [ ] **Step 1: Failing tests** — `test/unit/test_context.lua`:

```lua
local H = require("helpers")
local context = require("canvasdiff.diff").context

local T = {}

-- A minimal state: locate() walks sections by row counts, so a hand-built
-- state with two sections exercises every row kind without git.
local function two_section_state()
  return {
    sections = {
      { path = "a.lua", nhunks = 2,
        hunks = { { new_lo = 3, new_hi = 3 }, { new_lo = 9, new_hi = 9 } },
        entries = {
          { kind = "file_hdr", content = "a.lua" },
          { kind = "hunk_hdr", content = "@@ -1,3 +1,3 @@", hunk_idx = 1 },
          { kind = "ctx", content = "one", new_lnum = 2, hunk_idx = 1 },
          { kind = "add", content = "THREE", new_lnum = 3, hunk_idx = 1 },
          { kind = "hunk_hdr", content = "@@ -8,2 +8,2 @@", hunk_idx = 2 },
          { kind = "add", content = "NINE", new_lnum = 9, hunk_idx = 2 },
        } },
      { path = "b.lua", nhunks = 0, hunks = {},
        entries = { { kind = "file_hdr", content = "b.lua" } } },
    },
    folded = {}, collapsed = {},
  }
end

T["ctx_ a hunk body row resolves to its hunk"] = function()
  local st = two_section_state()
  H.eq(context.resolve(st, 3), { scope = "hunk", section = 1, hunk = 1 })
end

T["ctx_ a hunk header resolves to its hunk"] = function()
  local st = two_section_state()
  H.eq(context.resolve(st, 4), { scope = "hunk", section = 1, hunk = 2 })
end

T["ctx_ the file header resolves to the file"] = function()
  local st = two_section_state()
  H.eq(context.resolve(st, 0), { scope = "file", section = 1 })
end

T["ctx_ a folded placeholder resolves to the file"] = function()
  local st = two_section_state()
  st.folded = { ["a.lua"] = true }
  -- With a.lua folded its placeholder is row 0 and b.lua's header is row 1.
  H.eq(context.resolve(st, 0), { scope = "file", section = 1 })
end

return T
```

The `resolve(st, 3)` row indices assume `canvas.locate`'s row model (0-based canvas rows, folded section = one row). If `locate` needs `state` fields this fixture lacks, copy the shape the existing `test/unit/test_viewport.lua` fixtures use for locate-driven tests.

- [ ] **Step 2: Run to verify failure**

Run: `make test SUITE=unit FILTER='^ctx_'`
Expected: FAIL — module `canvasdiff.diff.context` not found (the runner surfaces the require error as a test failure; if it aborts discovery instead, that is also a failure signal — proceed).

- [ ] **Step 3: Implement** `lua/canvasdiff/diff/context.lua`:

```lua
-- The one home for "what is the verb standing on": hunk inside a hunk's
-- rows, file on a file header, a binary notice, or a folded placeholder.
-- Both the canvas keymaps and the sidebar rows route through here, so a
-- verb can never mean different granularities in the two places.
local canvas = require("canvasdiff.canvas")
local fold = require("canvasdiff.diff.fold")

local C = {}

function C.resolve(state, row0)
  local index, offset = canvas.locate(state, row0)
  if not index then
    return nil
  end
  local section = state.sections[index]
  if not section or fold.hidden(state, section.path) then
    return { scope = "file", section = index }
  end
  local entry = section.entries[offset]
  if not entry or entry.hunk_idx == nil then
    return { scope = "file", section = index }
  end
  return { scope = "hunk", section = index, hunk = entry.hunk_idx }
end

return C
```

Export it from `lua/canvasdiff/diff.lua` the same way the facade exports `fold`/`lens`/`anchor` (one line, matching the neighboring exports).

- [ ] **Step 4: Run**: `make test SUITE=unit FILTER='^ctx_'` → PASS, then `make architecture` → PASS (the facade export keeps outside consumers on `canvasdiff.diff`; if the dependency test pins exact facade edge counts, update the expected count where that test documents it — the test file states which table to touch).

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/diff/context.lua lua/canvasdiff/diff.lua test/unit/test_context.lua
git commit -m "feat: one resolver decides what a verb is standing on"
```

---

### Task 3: Repository blob plumbing

**Files:**
- Modify: `lua/canvasdiff/source/repository.lua`
- Test: `test/integration/test_git.lua`

**Interfaces:**
- Consumes: the module-local `run(dir, args)` (raw bytes — deliberately not `text = true`) and `command_error(what, res)`.
- Produces:
  - `M.index_blob(root, path)` → `content|nil, err|nil` — stage-0 index content (`git show :0:<path>`).
  - `M.head_blob(root, path)` → `content|nil, err|nil` — `git show HEAD:<path>`.
  - `M.set_index_blob(root, path, content)` → `true|nil, err|nil` — `git hash-object -w --stdin --path <path>` then `git update-index --add --cacheinfo <mode>,<oid>,<path>`, mode read from `git ls-files --stage -- <path>` (fall back to `100644` for a path not yet in the index).

- [ ] **Step 1: Failing test** (append to `test/integration/test_git.lua`, using `H.git_fixture`):

```lua
T["git_ index blob round-trips byte-exact through set_index_blob"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "one\ntwo\nthree\n" },
    worktree  = { ["a.txt"] = "one\nTWO\nthree\n" },
  })
  H.eq(repository.index_blob(root, "a.txt"), "one\ntwo\nthree\n")
  H.eq(repository.head_blob(root, "a.txt"), "one\ntwo\nthree\n")
  assert(repository.set_index_blob(root, "a.txt", "one\nTWO\nthree\n"))
  H.eq(repository.index_blob(root, "a.txt"), "one\nTWO\nthree\n")
  -- The worktree is untouched and the file now reads fully staged.
  local files = repository.changed_files(root)
  H.eq(files[1].staged ~= nil, true)
  H.eq(files[1].unstaged, nil)
end
```

- [ ] **Step 2: Run**: `make test SUITE=integration FILTER='index blob round-trips'` → FAIL (`index_blob` is nil).

- [ ] **Step 3: Implement** in `repository.lua`, next to `M.stage`/`M.unstage`:

```lua
--- Stage-0 index content for one path. Raw bytes on purpose -- run() skips
--- text mode so CRLF blobs survive (see the note on run above).
function M.index_blob(root, path)
  local res = run(root, { "show", ":0:" .. path })
  if res.code ~= 0 then
    return nil, command_error("git show :0:" .. path, res)
  end
  return res.stdout
end

function M.head_blob(root, path)
  local res = run(root, { "show", "HEAD:" .. path })
  if res.code ~= 0 then
    return nil, command_error("git show HEAD:" .. path, res)
  end
  return res.stdout
end

--- Point the index at `content` for `path` without touching the worktree:
--- write the blob, then update the cache entry in place. The mode is read
--- from the existing index entry so an executable stays executable.
function M.set_index_blob(root, path, content)
  local mode = "100644"
  local ls = run(root, { "ls-files", "--stage", "--", path })
  if ls.code == 0 and ls.stdout ~= "" then
    mode = ls.stdout:match("^(%d+)") or mode
  end
  local hash = system.run(
    { "git", "-C", root, "hash-object", "-w", "--stdin", "--path", path },
    { stdin = content, text = false })
  if hash.code ~= 0 then
    return nil, command_error("git hash-object", hash)
  end
  local oid = hash.stdout:gsub("%s+$", "")
  local upd = run(root, { "update-index", "--add",
    "--cacheinfo", mode .. "," .. oid .. "," .. path })
  if upd.code ~= 0 then
    return nil, command_error("git update-index", upd)
  end
  return true
end
```

Check `lua/canvasdiff/os/process.lua` for how `system.run` takes stdin (the chaos suite injects through it; mirror its option name — if it has no stdin support, add a `stdin` pass-through there in this task, with a one-line unit test in `test/unit/test_os.lua`).

- [ ] **Step 4: Run**: `make test SUITE=integration FILTER='index blob'` → PASS; `make test SUITE=unit` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/source/repository.lua test/integration/test_git.lua
git commit -m "feat: index blob plumbing for hunk staging

show :0:, show HEAD:, and set_index_blob via hash-object +
update-index --cacheinfo -- raw bytes end to end, so CRLF files
round-trip exactly."
```

---

### Task 4: The pure splice engine

**Files:**
- Create: `lua/canvasdiff/diff/stage.lua`
- Modify: `lua/canvasdiff/diff.lua` (facade export)
- Test: `test/unit/test_stage_splice.lua`

**Interfaces:**
- Consumes: `require("canvasdiff.diff.algorithm").hunks(a_text, b_text)` → `{ {start_a, count_a, start_b, count_b}, ... }` (indices; a zero count means "insert after start").
- Produces (all pure — no git, no vim state beyond `vim.split`):
  - `stage.pair_hunks(a_text, b_text)` → the algorithm hunks (thin wrapper, one place to own the call).
  - `stage.pick(hunks, span)` → the single hunk whose **b-side** range `[start_b, start_b+count_b-1]` (or insertion point `start_b`..`start_b+1` when `count_b == 0`) overlaps `span = {lo, hi}`; nil when none. `span` values are b-side line numbers.
  - `stage.splice(a_text, b_text, hunk)` → new a-side text with exactly `hunk` applied: replace a-lines `[start_a, start_a+count_a-1]` with b-lines `[start_b, start_b+count_b-1]`; when `count_a == 0`, insert the b-lines after a-line `start_a`. Preserves trailing-newline shape of `a_text`.

- [ ] **Step 1: Failing tests** — `test/unit/test_stage_splice.lua`:

```lua
local H = require("helpers")
local stage = require("canvasdiff.diff").stage

local T = {}

local A = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n"
local B = "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nten\nELEVEN\n"

T["splice_ applying one hunk stages only that hunk"] = function()
  local hunks = stage.pair_hunks(A, B)
  H.eq(#hunks, 3, "sanity: three separate changes")
  local h = stage.pick(hunks, { lo = 2, hi = 2 })
  H.eq(stage.splice(A, B, h),
    "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
end

T["splice_ a trailing pure addition inserts, not replaces"] = function()
  local hunks = stage.pair_hunks(A, B)
  local h = stage.pick(hunks, { lo = 11, hi = 11 })
  H.eq(stage.splice(A, B, h),
    "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\nELEVEN\n")
end

T["splice_ a pure deletion removes exactly its lines"] = function()
  local a = "one\nGONE\ntwo\n"
  local b = "one\ntwo\n"
  local hunks = stage.pair_hunks(a, b)
  -- b-side count is 0: the overlap window is the insertion seam.
  local h = stage.pick(hunks, { lo = 1, hi = 2 })
  H.eq(stage.splice(a, b, h), "one\ntwo\n")
end

T["splice_ no overlapping hunk returns nil from pick"] = function()
  local hunks = stage.pair_hunks(A, B)
  H.eq(stage.pick(hunks, { lo = 5, hi = 5 }), nil)
end

T["splice_ adjacent hunks stay independent"] = function()
  local a = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n"
  local b = "one\nTWO\nthree\nfour\nfive\nsix\nSEVEN\neight\n"
  local hunks = stage.pair_hunks(a, b)
  H.eq(#hunks, 2)
  H.eq(stage.splice(a, b, stage.pick(hunks, { lo = 7, hi = 7 })),
    "one\ntwo\nthree\nfour\nfive\nsix\nSEVEN\neight\n")
end

return T
```

- [ ] **Step 2: Run**: `make test SUITE=unit FILTER='^splice_'` → FAIL.

- [ ] **Step 3: Implement** `lua/canvasdiff/diff/stage.lua`:

```lua
-- Staging is a line splice on blob content, never a patch: both sides are
-- in hand, so applying hunk N is arithmetic, immune to context drift.
-- Everything here is pure; the git writes live in source/repository.
local algorithm = require("canvasdiff.diff.algorithm")

local S = {}

local function lines_of(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

function S.pair_hunks(a_text, b_text)
  return algorithm.hunks(a_text, b_text)
end

--- The hunk whose b-side window overlaps `span` ({lo, hi}, b-side line
--- numbers). A zero-count b side is a deletion seam: its window is the two
--- lines around the cut, so a cursor near the deletion still finds it.
function S.pick(hunks, span)
  for _, h in ipairs(hunks) do
    local start_b, count_b = h[3], h[4]
    local lo = count_b > 0 and start_b or math.max(start_b, 1)
    local hi = count_b > 0 and (start_b + count_b - 1) or (start_b + 1)
    if span.lo <= hi and span.hi >= lo then
      return h
    end
  end
end

function S.splice(a_text, b_text, hunk)
  local a, b = lines_of(a_text), lines_of(b_text)
  local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
  local out = {}
  local upto = count_a > 0 and start_a - 1 or start_a
  for i = 1, upto do
    out[#out + 1] = a[i]
  end
  for i = start_b, start_b + count_b - 1 do
    out[#out + 1] = b[i]
  end
  for i = upto + count_a + 1, #a do
    out[#out + 1] = a[i]
  end
  local text = table.concat(out, "\n")
  if a_text == "" or a_text:sub(-1) == "\n" then
    return #out > 0 and text .. "\n" or text
  end
  return text
end

return S
```

Export `stage` from `lua/canvasdiff/diff.lua` like `context` in Task 2.

- [ ] **Step 4: Run**: `make test SUITE=unit FILTER='^splice_'` → PASS; `make architecture` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/diff/stage.lua lua/canvasdiff/diff.lua test/unit/test_stage_splice.lua
git commit -m "feat: pure hunk splice engine

pick() finds the pair hunk under a b-side span, splice() applies
exactly one hunk to the a side -- byte-exact, trailing newline
preserved, deletions treated as seams so a nearby cursor finds them."
```

---

### Task 5: Hunk stage/unstage verbs — context-sensitive `s`/`u`, capitals `S`/`U`

**Files:**
- Modify: `lua/canvasdiff/App.lua` (new `App:stage_hunk`; `canvas_actions` rewiring around line 950)
- Modify: `lua/canvasdiff/input/keys.lua` (two spec entries), `lua/canvasdiff/config/settings.lua` (two defaults)
- Test: `test/integration/test_git.lua` (behavioral), `test/unit/test_keys.lua` (spec presence)

**Interfaces:**
- Consumes: `diff.context.resolve` (Task 2), `diff.stage` (Task 4), `repository.index_blob/head_blob/set_index_blob` (Task 3), `section.hunks[gi].new_lo/new_hi` (Task 1), existing `App:stage_file(direction, path, owned_surface, generation)` and its preflights (buffer-alias refusal, range refusal, XY recheck — reuse, do not duplicate).
- Produces: `App:stage_hunk(direction, surface, generation, win)` → `true` when the index changed, `false` with a notification otherwise. Notifications (exact copy): `"hunk already staged"`, `"nothing staged here"`, `"hunk staging needs a text file — S stages the whole file"` (binary/rename decline).
- Keymap: `keys.specs` gains `{ ctx = "canvas", action = "stage_file", group = "Canvas", desc = "Stage this file's changes (from anywhere in it)" }` and the `unstage_file` twin; settings defaults `stage_file = "S"`, `unstage_file = "U"`. The existing `stage`/`unstage` handlers resolve scope through `context.resolve` at press time.

- [ ] **Step 1: Failing integration tests** (append to `test/integration/test_git.lua`; open a real canvas the way the file's existing tests do — reuse its open/close fixture helpers):

```lua
T["git_ s inside a hunk stages only that hunk"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n" },
    worktree  = { ["a.txt"] = "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nten\n" },
  })
  -- open canvas on root, put the cursor on the "TWO" row, invoke the
  -- stage action (drive App:stage_hunk("stage", ...) directly like the
  -- existing stage tests drive App:stage_file), then assert:
  H.eq(repository.index_blob(root, "a.txt"),
    "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
  local f = repository.changed_files(root)[1]
  H.eq(f.staged ~= nil, true, "index moved")
  H.eq(f.unstaged ~= nil, true, "second hunk still unstaged")
end

T["git_ s on an already-staged hunk declines and changes nothing"] = function()
  -- same fixture; stage the hunk once, snapshot `git show :0:a.txt`,
  -- invoke again on the same row, assert the blob is byte-identical and
  -- the action returned false.
end

T["git_ u inside a staged hunk unstages only it"] = function()
  -- stage both hunks via set_index_blob(worktree content), cursor on the
  -- NINE hunk, App:stage_hunk("unstage", ...), then:
  -- index_blob == "one\nTWO\n...nine\nten\n" (NINE reverted, TWO kept).
end

T["git_ S stages the whole file from inside a hunk"] = function()
  -- cursor mid-hunk, invoke the stage_file action, assert
  -- changed_files reports staged-only (the existing file-stage assertions).
end
```

Write the cursor placement with the same helper the existing canvas-cursor tests use (`vim.api.nvim_win_set_cursor` on the canvas window at the row whose entry content is "TWO" — find it by scanning `state.sections[1].entries`).

- [ ] **Step 2: Run**: `make test SUITE=integration FILTER='stages only that hunk'` → FAIL.

- [ ] **Step 3: Implement.**

`App:stage_hunk` (next to `App:stage_file`, reusing its preflight discipline — the epoch/transaction guard, `buffer.modified` alias refusal, `lens.is_range` refusal):

```lua
--- Stage or unstage ONE hunk. The mapping rule is fixed whatever lens is
--- showing: stage works on the index→worktree pair, unstage on
--- HEAD→index. The cursor's hunk contributes only its new-side span; the
--- pair is recomputed from blobs at press time, never from the screen.
function App:stage_hunk(direction, owned_surface, generation, win)
  -- 1. context.resolve on the cursor row; scope must be "hunk", else
  --    fall through to self:stage_file (the file header / placeholder case).
  -- 2. Same refusals as stage_file: read-only range -> notify + false;
  --    modified aliasing buffer -> notify + false; binary/rename section
  --    -> notify("hunk staging needs a text file — S stages the whole file").
  -- 3. span = { lo = hunks[gi].new_lo, hi = hunks[gi].new_hi }
  --    (pure-del hunk: lo/hi nil -> use the neighbouring context row's
  --    new_lnum ± 1, the seam pick() widens over).
  -- 4. direction == "stage":
  --      a = repository.index_blob(root, path)  (unborn/new file: "" )
  --      b = worktree bytes via source.buffer.read_worktree
  --      h = stage.pick(stage.pair_hunks(a, b), span)
  --      h == nil -> notify("hunk already staged"); return false
  --      repository.set_index_blob(root, path, stage.splice(a, b, h))
  --    direction == "unstage":
  --      a = repository.head_blob(root, path); b = repository.index_blob(...)
  --      pick against the same span; nil -> notify("nothing staged here")
  --      set_index_blob(root, path, spliced HEAD-ward: swap the roles —
  --      splice(b, a, reversed) — implement as stage.splice(b_text, a_text,
  --      { h[3], h[4], h[1], h[2] }): the reverse hunk exchanges sides.
  -- 5. On success: the same refresh path stage_file ends with (reuse its
  --    tail — the reconcile that re-reads git status and splices).
end
```

Rewire `canvas_actions`:

```lua
stage      = owned_action(surface, generation, function(_, win)
  local row0 = vim.api.nvim_win_get_cursor(win)[1] - 1
  local ctx = diff.context.resolve(st, row0)
  if ctx and ctx.scope == "hunk" then
    app:stage_hunk("stage", surface, generation, win)
  else
    app:stage(nil, surface, generation)
  end
end),
-- unstage: the twin, direction "unstage".
stage_file   = owned_action(surface, generation,
  function() app:stage(nil, surface, generation) end),
unstage_file = owned_action(surface, generation,
  function() app:unstage(nil, surface, generation) end),
```

`keys.specs` additions (after the existing stage/unstage entries):

```lua
{ ctx = "canvas", action = "stage_file",   group = "Canvas", desc = "Stage this file's changes (from anywhere in it)" },
{ ctx = "canvas", action = "unstage_file", group = "Canvas", desc = "Unstage this file (from anywhere in it)" },
```

`settings.lua` canvas defaults: `stage_file = "S"`, `unstage_file = "U"` (with a comment noting `S`/`U` are inert editing keys on a nomodifiable buffer, same measurement as `c`). Update the `stage`/`unstage` desc strings to say "this hunk — or this file on its header".

- [ ] **Step 4: Run**: `make test SUITE=integration FILTER='^git_'` → PASS; `make test SUITE=unit FILTER='^keys_'` → PASS (fix any exact-spec-list assertions in `test/unit/test_keys.lua`/`test_cheatsheet.lua` to include the two new actions — they exist to catch exactly this, update their expected tables); `make test` → all PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/App.lua lua/canvasdiff/input/keys.lua lua/canvasdiff/config/settings.lua test/integration/test_git.lua test/unit/test_keys.lua
git commit -m "feat: s stages the hunk you are on; S the file you are in

The cursor decides scope through one resolver; capitals are the
from-anywhere file verbs. Stage maps onto the index→worktree pair,
unstage onto HEAD→index, both as blob splices -- no patches, no
context drift, worktree never touched."
```

---

### Task 6: Hunk cycling — Ctrl+N/P walk hunk stops

**Files:**
- Modify: `lua/canvasdiff/input/motions.lua`, `lua/canvasdiff/App.lua` (cycle wiring), `lua/canvasdiff/input/keys.lua` + `lua/canvasdiff/config/settings.lua` (file-cycle actions, unbound)
- Test: `test/unit/test_motions.lua`, `test/integration/test_jump.lua` (or the file that holds today's cycle tests — put them beside those)

**Interfaces:**
- Consumes: the row-collection loop already inside `M.goto_hunk` (hunk_hdr rows per section; a folded section contributes its start row).
- Produces:
  - `motions.hunk_stops(state)` → sorted 0-based row list (extracted verbatim from `goto_hunk`, which then calls it — one home, like `M.step`).
  - `motions.cycle_hunk(state, win, dir, count)` → scrolls the window so the target stop is the topline (same `winrestview` idiom as `M.cycle`), wrapping with the `M.step` wrap arithmetic over the stop list; returns the landed row or nil.
- Keymap: `cycle_next`/`cycle_prev` handlers call `motions.cycle_hunk`; new spec entries `cycle_file_next`/`cycle_file_prev` (group "Navigate", descs "Scroll to the next/previous file (wraps)") with settings defaults `= {}` (unbound — `K.list` treats `{}` as disabled, so no map installs until a user binds one).

- [ ] **Step 1: Failing unit test** (`test/unit/test_motions.lua`, beside the existing step/clamp tests):

```lua
T["motions_ hunk stops treat a folded file as one stop"] = function()
  -- Build the same hand-rolled state the goto_hunk tests use: two files,
  -- the first with two hunks, the second folded. Expected stops: the two
  -- hunk_hdr rows of file one plus the folded placeholder row of file two.
  local stops = motions.hunk_stops(st)
  H.eq(#stops, 3)
end

T["motions_ cycle_hunk wraps at the last stop"] = function()
  -- st/win fixture as the existing cycle tests build it; topline on the
  -- last stop, cycle_hunk(st, win, 1) must land on stops[1].
end
```

- [ ] **Step 2: Run**: `make test SUITE=unit FILTER='^motions_ hunk stops'` → FAIL.

- [ ] **Step 3: Implement**: extract the row loop from `goto_hunk` into `M.hunk_stops(state)` (goto_hunk keeps its behavior byte-for-byte — it now calls the helper); add:

```lua
--- Scroll by hunk stops, wrapping -- Ctrl+N/P's semantics at ]h's
--- granularity. The stop list is goto_hunk's: every hunk header, and a
--- folded file as exactly one stop (its placeholder row).
function M.cycle_hunk(state, win, dir, count)
  win = win or state.win
  if not canvas_showing(state, win) then
    return
  end
  local stops = M.hunk_stops(state)
  if #stops == 0 then
    return
  end
  local top0 = vim.api.nvim_win_call(win, function()
    return vim.fn.line("w0") - 1
  end)
  -- Current position: the stop at or before the topline (wrap to the end
  -- when the topline sits before every stop, so dir=1 lands on stops[1]).
  local at = 0
  for i, r in ipairs(stops) do
    if r <= top0 then at = i else break end
  end
  count = math.max(1, count or 1)
  local target = ((at - 1 + dir * count) % #stops) + 1
  local row0 = stops[target]
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = row0 + 1, lnum = row0 + 1 })
  end)
  return row0
end
```

In `canvas_actions`: `cycle_next`/`cycle_prev` call `motions.cycle_hunk(st, win, ±1)` (keeping the `after_motion` sidebar/winbar sync); add `cycle_file_next`/`cycle_file_prev` handlers calling the old `motions.cycle(st, win, ±1)`. Update the two cycle descs in `keys.specs` to "Scroll to the next/previous hunk (wraps; a folded file is one stop)".

- [ ] **Step 4: Run**: `make test SUITE=unit` → PASS; `make test` → PASS (e2e tests that pressed Ctrl+N expecting file-level scrolling will fail — read each failure and update the *expectation* to hunk stops only where the test's intent was "cycle moves the view"; if a test's intent was specifically file cycling, rebind it to `cycle_file_next` via its setup's config).

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/input/motions.lua lua/canvasdiff/App.lua lua/canvasdiff/input/keys.lua lua/canvasdiff/config/settings.lua test/
git commit -m "feat: Ctrl+N/P cycle the review hunk by hunk

Stops are ]h's -- every hunk header, a folded file as one -- with
cycle's scroll-and-wrap semantics. File cycling moves to
cycle_file_next/prev, unbound by default; one config line restores it."
```

---

### Task 7: Sidebar model — hunk rows, fold-mirror visibility, fold summaries

**Files:**
- Modify: `lua/canvasdiff/ui/sidebar.lua` (`S.build_entries`, `S.render_lines`, `ensure_hl_groups`)
- Test: `test/unit/test_ui.lua` (the file already unit-tests sidebar row building — put these beside those tests; if they live elsewhere, follow where `S.build_entries` is tested today)

**Interfaces:**
- Consumes: `section.hunks` (Task 1), `section.nhunks`, existing `folded` set semantics.
- Produces, in `build_entries` output (all pure tables):
  - After each **unfolded** file entry: one `{ kind = "hunk", path = section.path, hunk = gi, name = "@@ <new_lo>  <label>", counts = "+a −d", pure_del = bool, depth = file_depth + 1 }` per hunk, in order. Folded files and files under a folded directory contribute none (fold-mirror; the existing `hidden` walk already skips children of folded dirs — hunk rows ride the same skip).
  - **Folded file** entries carry `summary = "(N hunks, +a −d)"`; **folded dir** entries carry `summary = "(N files, +a −d)"` (aggregate of hidden children). Unfolded entries have `summary = nil`.
- `render_lines` renders hunk rows indented under their file, `CanvasDiffSidebarHunk` spans for the row, `CanvasDiffSidebarHunkDel` (strikethrough via `CanvasDiffGhost` link) instead when `pure_del`.
- New groups in `ensure_hl_groups`:

```lua
vim.api.nvim_set_hl(0, "CanvasDiffSidebarHunk", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "CanvasDiffSidebarHunkDel", { link = "CanvasDiffGhost", default = true })
```

- [ ] **Step 1: Failing tests** (unit, pure — hand-built `sections` with `hunks` tables):

```lua
T["ui_sidebar unfolded files list their hunks, folded files summarize"] = function()
  local sections = {
    { path = "src/a.lua", adds = 3, dels = 1, nhunks = 2, hunks = {
        { new_lo = 3, adds = 2, dels = 1, label = "THREE", pure_del = false },
        { new_lo = 9, adds = 1, dels = 0, label = "NINE", pure_del = false } } },
    { path = "src/b.lua", adds = 0, dels = 4, nhunks = 1, hunks = {
        { new_lo = nil, adds = 0, dels = 4, label = "GONE", pure_del = true } } },
  }
  local entries = S.build_entries(sections, { ["src/b.lua"] = true }, {}, {})
  -- dir row, a.lua, its two hunk rows, folded b.lua with a summary:
  H.eq(entries[3].kind, "hunk")
  H.eq(entries[3].name, "@@ 3  THREE")
  H.eq(entries[3].counts, "+2 −1")
  H.eq(entries[5].kind, "file")
  H.eq(entries[5].summary, "(1 hunks, +0 −4)")
  H.eq(#entries, 5, "folded file contributes no hunk rows")
end

T["ui_sidebar a folded directory summarizes its hidden files"] = function()
  -- same sections, folded = { ["src/"] = true }: one dir row with
  -- summary "(2 files, +3 −5)" and nothing beneath it.
end

T["ui_sidebar a pure-deletion hunk row is marked for the ghost group"] = function()
  local entries = S.build_entries(sections, {}, {}, {})
  -- b.lua's hunk row: pure_del true, and render_lines emits a
  -- CanvasDiffSidebarHunkDel span covering the label.
end
```

(Use the real glyph table for `−` — build expected strings with `render.glyphs.minus` the way `sidebar_title`'s test does, so `glyphs = "ascii"` configs don't break the assertion.)

- [ ] **Step 2: Run**: `make test SUITE=unit FILTER='ui_sidebar unfolded'` → FAIL.

- [ ] **Step 3: Implement** in `build_entries`: after pushing an unfolded file entry, loop `section.hunks` pushing hunk entries; on the folded-file branch attach `summary` from `nhunks`/`adds`/`dels`; accumulate per-dir aggregates during the existing prefix walk for the folded-dir branch. In `render_lines`, render `entry.kind == "hunk"` with two extra indent spaces, name + counts, and emit the span table rows for `CanvasDiffSidebarHunk` / `CanvasDiffSidebarHunkDel` the same way existing rows emit their spans.

- [ ] **Step 4: Run**: `make test SUITE=unit` → PASS; `make test SUITE=integration FILTER='^sidebar'` → PASS (existing sidebar integration tests assert row text — update expectations where unfolded files now carry hunk rows; each such update is the feature, not a regression).

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/ui/sidebar.lua test/unit/test_ui.lua test/integration/test_sidebar.lua
git commit -m "feat: the sidebar mirrors the canvas at hunk depth

Unfolded files list their hunks; a fold summarizes what it hides --
(N hunks, +a −d) on files, (N files, +a −d) on directories. Pure
deletions render struck through the ghost group, same fact, same
channel as the canvas."
```

---

### Task 8: Sidebar interactivity — hunk tracking, select, stage from a hunk row

**Files:**
- Modify: `lua/canvasdiff/ui/sidebar.lua` (`set_active` neighborhood, select routing, `on_stage` call), `lua/canvasdiff/App.lua` (`on_stage` handler ~line 1091)
- Test: `test/integration/test_sidebar.lua`

**Interfaces:**
- Consumes: hunk entries (Task 7), `App:stage_hunk` (Task 5), `motions.cycle_hunk`/`goto_hunk` sync path (`sidebar.sync(side, win)` in `after_motion`).
- Produces:
  - Tracking: `sidebar.sync` resolves the canvas viewport row through `context.resolve`; when scope is "hunk" and that file's hunk rows are visible, the active highlight (`CanvasDiffSidebarActive`) lands on the hunk row, else on the file row (spec: fallback on headers and folded files; during a jump excursion, file row — today's behavior, unchanged code path).
  - Select on a hunk row (**Enter**/`za`/`c`/double-click): scroll the canvas so that hunk's header row is the topline (reuse the file-select scroll plumbing with the hunk's row offset). Never changes a fold.
  - `s`/`u` on a hunk row: `on_stage(lease, view, path, direction, hunk_gi)` — the App handler routes `hunk_gi ~= nil` to `app:stage_hunk` with a span from `section.hunks[hunk_gi]`, else to `app:stage_file` exactly as today.

- [ ] **Step 1: Failing integration tests** (beside the existing select/stage sidebar tests, reusing their fixture that opens a real canvas + sidebar):

```lua
T["sidebar_ select on a hunk row scrolls the canvas to that hunk"] = function()
  -- fixture: one file, two hunks far apart (pad with 60 context lines).
  -- Focus the sidebar window, cursor on the second hunk row, feed <CR>,
  -- assert the canvas topline == that hunk's header row + 1.
end

T["sidebar_ s on a hunk row stages exactly that hunk"] = function()
  -- cursor on hunk row 1, feed "s", then repository.index_blob shows
  -- hunk 1 applied and changed_files still reports an unstaged remainder.
end

T["sidebar_ tracking lands on the hunk row the canvas is in"] = function()
  -- scroll the canvas into hunk 2 (winrestview), fire the sync the way
  -- the existing tracking tests do (WinScrolled never fires headlessly --
  -- drive sidebar.sync directly), assert the active extmark row is the
  -- hunk-2 row, not the file row.
end
```

- [ ] **Step 2: Run**: `make test SUITE=integration FILTER='sidebar_ select on a hunk row'` → FAIL.

- [ ] **Step 3: Implement**: sidebar rows already map cursor row → entry; extend the select handler's `entry.kind` switch with `"hunk"` (scroll canvas to `section start + hunk header offset` — compute the offset by scanning `section.entries` for `hunk_hdr` with `hunk_idx == entry.hunk`, the same arithmetic `goto_hunk` uses); extend the stage handler to pass `entry.hunk` as the fifth `on_stage` argument; extend `set_active`'s row resolution with the hunk-row case. In App, the `on_stage` closure gains the `hunk` parameter and branches to `app:stage_hunk`.

- [ ] **Step 4: Run**: `make test SUITE=integration` → PASS; `make test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/ui/sidebar.lua lua/canvasdiff/App.lua test/integration/test_sidebar.lua
git commit -m "feat: the sidebar's hunk rows are live

Select scrolls to the hunk, s/u stage exactly it through the same
resolver as the canvas verbs, and tracking answers at hunk depth --
falling back to the file row on headers and folded files."
```

---

### Task 9: The pinned-header breadcrumb with ordinal

**Files:**
- Modify: `lua/canvasdiff/ui/sticky_header.lua` (`SH.content`), `lua/canvasdiff/config/settings.lua` (glyph `crumb`)
- Test: `test/unit/test_sticky_content.lua`

**Interfaces:**
- Consumes: `section.hunks` (Task 1), `canvas.locate`, existing `render.section_line`/`render.marker_spans`.
- Produces: `SH.content(st, top0)` return gains the crumb: `line = <file header line> .. glyphs.crumb .. "@@ " .. new_lo .. "  " .. label .. " · " .. gi .. "/" .. nhunks`, with spans extended by one `CanvasDiffHunkHeader` span over the crumb (or `CanvasDiffSidebarHunkDel` over the label when `pure_del`). File-only (no crumb) when no hunk header sits at/above `top0` within the section. The ordinal and file part are never truncated; the label is (SH.update already clamps to window width — truncate the label before concatenation to `win_width - #rest` when needed, mirroring the sidebar's truncation helper).
- Settings: `glyphs.crumb = " → "`; ASCII preset `" -> "`; the glyph-name validation list gains `crumb`.

- [ ] **Step 1: Failing tests** (append to `test/unit/test_sticky_content.lua`, reusing its state fixtures):

```lua
T["sticky_ mid-hunk content carries the crumb and ordinal"] = function()
  -- fixture: section with 2 hunks (the file's existing two-hunk state);
  -- top0 on a row inside hunk 2:
  local c = SH.content(st, row_inside_hunk2)
  assert(c.line:find("→ @@ ", 1, true), "crumb present")
  assert(c.line:find("· 2/2", 1, true), "ordinal present")
end

T["sticky_ the file lead-in is file-only"] = function()
  -- top0 on a ctx row before the first hunk header: content.line equals
  -- render.section_line(section, 1) exactly -- no crumb.
end

T["sticky_ a pure-deletion current hunk strikes its label"] = function()
  -- hunk with pure_del = true under top0: one span with group
  -- CanvasDiffSidebarHunkDel covering the label range.
end
```

- [ ] **Step 2: Run**: `make test SUITE=unit FILTER='^sticky_ mid-hunk'` → FAIL.

- [ ] **Step 3: Implement** in `SH.content`, after the existing `section_line` build: walk `section.entries` from `offset` upward to the nearest `hunk_hdr` (or track via `entries[offset].hunk_idx` — a body row already knows its hunk); when found, append crumb text and push the span; return unchanged shape otherwise. Add the glyph to `settings.lua` defaults + ascii preset + the validated-names list.

- [ ] **Step 4: Run**: `make test SUITE=unit FILTER='^sticky_'` → PASS; `make test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/ui/sticky_header.lua lua/canvasdiff/config/settings.lua test/unit/test_sticky_content.lua
git commit -m "feat: the pinned header grows a hunk breadcrumb

file header → @@ line  label · n/total -- the closed-sidebar answer
to which hunk and how far through, in the crumb (which tracks scroll
by design) and never in the file part (which stays a verbatim mirror)."
```

---

### Task 10: Read-only tint unifies across the band

**Files:**
- Modify: `lua/canvasdiff/ui/sidebar.lua` (`update_winbar` ~line 243, `sidebar_title` ~line 147)
- Test: `test/unit/test_winbar.lua`

**Interfaces:**
- Produces: `S.title_text(state)` — pure, returns the `%#group#`-prefixed sidebar winbar string where group is `CanvasDiffWinbarReadOnly` when `lens.is_range(lens.of(state))`, else `CanvasDiffWinbar` (exactly `winbar.text`'s group rule). `update_winbar` applies `S.title_text` instead of the raw title.

- [ ] **Step 1: Failing test** (`test/unit/test_winbar.lua` style — the existing test asserts the canvas half's string verbatim):

```lua
T["winbar_ the sidebar half tints read-only with the canvas half"] = function()
  local st = { lens = lens.range("main", "topic", ".."), sections = {} }
  local text = sidebar.title_text(st)
  H.eq(text:sub(1, #"%#CanvasDiffWinbarReadOnly#"), "%#CanvasDiffWinbarReadOnly#")
end

T["winbar_ the sidebar half stays plain on a working lens"] = function()
  local st = { sections = {} }
  H.eq(sidebar.title_text(st):sub(1, #"%#CanvasDiffWinbar#"), "%#CanvasDiffWinbar#")
end
```

- [ ] **Step 2: Run**: `make test SUITE=unit FILTER='sidebar half'` → FAIL.

- [ ] **Step 3: Implement**: expose `S.title_text(state)` wrapping `sidebar_title` with the group prefix chosen by `lens.is_range(lens.of(state))` (require the lens module the way `winbar.lua` does); `update_winbar` uses it. Check how the title is currently escaped/applied — route through `winbar.escape` for `%` safety, same as the canvas half.

- [ ] **Step 4: Run**: `make test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/ui/sidebar.lua test/unit/test_winbar.lua
git commit -m "feat: the read-only tint runs edge to edge

A range lens now tints the sidebar half of the band with the same
group as the canvas half -- one state, one band, no seam."
```

---

### Task 11: Chaos action, e2e sweep, docs, full verification

**Files:**
- Modify: `test/fault/test_chaos.lua` + `test/fault/chaos.lua` (stage-hunk action), `test/e2e/test_e2e.lua` (the sweep), `README.md`, `doc/canvasdiff.txt`
- Run: everything.

**Interfaces:** consumes all prior tasks; produces no new code surface.

- [ ] **Step 1: Chaos**: add a `stage_hunk` action to the chaos action table (pick a random visible hunk row, invoke the stage action; on injected git failure the existing byte-exact index invariant must hold — mirror how the file-stage chaos action is written). Run `make fault` → PASS.

- [ ] **Step 2: E2e sweep** (append to `test/e2e/test_e2e.lua`, real keys via `nvim_feedkeys(..., "x")`): fixture with one 3-hunk file; open in the unstaged lens; land on hunk 1 (`]h`), press `s`; assert the canvas re-rendered without that hunk (the vanish is the feedback — assert section `nhunks` dropped to 2 and the buffer no longer contains hunk 1's added line); press `<Tab>` to the staged lens and assert the staged hunk IS there; press Ctrl+N twice and assert the topline moved to hunk stops (wrap included). Run `make e2e` → PASS.

- [ ] **Step 3: Docs.** README: keymap table gains `stage_file`/`unstage_file` rows ("hold **Shift** + **s**/**u** — stage/unstage the whole file from anywhere") and rewords `stage`/`unstage` ("the hunk under the cursor; the file when on its header") and `cycle_next`/`cycle_prev` ("scroll to the next/previous **hunk**, wrapping — a folded file is one stop"); Configuration block gains the two capitals, the two unbound file-cycle actions, and `crumb` in glyphs; highlight-groups table gains `CanvasDiffSidebarHunk` / `CanvasDiffSidebarHunkDel`; the sidebar section describes hunk rows, fold summaries, and the fold-mirror rule; "Knowing where you are" describes the crumb + ordinal; the read-only band paragraph drops "tints the canvas half" for "tints the band"; a short **Changed behavior** note states the Ctrl+N/P change and the one-line restore. `doc/canvasdiff.txt`: mirror all of the above in sections 4/7/8; regenerate helptags (`nvim --headless --clean -c 'helptags doc' -c q` — `doc/tags` is gitignored).

- [ ] **Step 4: Full verification**: `make test` → 100% PASS; `make architecture` → PASS. Fix stragglers before committing.

- [ ] **Step 5: Commit**

```bash
git add test/fault test/e2e README.md doc/canvasdiff.txt
git commit -m "docs+tests: hunk staging ships whole

Chaos stages hunks under injected failure, the e2e sweep proves the
unstaged-lens vanish, and both docs tell the new keys, the crumb, the
fold-mirror sidebar, and the one deliberate behavior change on
Ctrl+N/P."
```

---

## Plan Self-Review (performed)

- **Spec coverage:** decisions 1–8 → Tasks: verbs/capitals (5), no-mode via resolver (2, 5), two-level fold-mirror tree + summaries + styling (7), staging pairs + splice (3, 4, 5), Ctrl+N/P hunk stops + unbound file cycle (6), band tint (10), breadcrumb + ordinal (9), sidebar interactivity/tracking (8), non-goals respected throughout (no persistence, no markers, declines in 5). Testing section of the spec maps onto each task's tests plus Task 11.
- **Placeholders:** none — every step names exact functions, strings, and assertions; where a fixture must copy an existing idiom, the source test file is named.
- **Type consistency:** `section.hunks[gi]` fields (`new_lo/new_hi/adds/dels/label/pure_del/header`) used identically in Tasks 1, 5, 7, 8, 9; `context.resolve` shape identical in 2, 5, 8; `stage.pick/splice` signatures identical in 4, 5; `on_stage(lease, view, path, direction, hunk_gi)` in 8 matches App's handler change.
