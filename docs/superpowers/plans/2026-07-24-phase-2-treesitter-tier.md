# Phase 2 — Treesitter Highlight Tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Syntax-highlight the diff content on the canvas using the user's own treesitter highlight queries (plus a char-level word-diff tier), applied lazily to the viewport + margin and evicted when sections scroll far away — without ever attaching a parser to the canvas buffer.

**Architecture:** `model.build_section` starts carrying the whole-file `old_text`/`new_text` on each section. A new pure-computation layer turns a section into position-mapped highlight marks: `hl.section_ts_marks(section)` parses each side with `vim.treesitter.get_string_parser` (LRU-cached per path) and maps captures onto section rows (`ctx`/`add` lines from the new text, `del` lines from the old text); `worddiff.section_marks(section)` pairs del/add runs and char-diffs each pair. An apply/evict engine in `hl.lua` places those marks as extmarks in a dedicated namespace for sections within viewport±margin (debounced `WinScrolled`), evicts at 2×margin, and invalidates via two new optional hooks canvas.lua calls on `render_all`/`replace_section`.

**Tech Stack:** Lua, Neovim ≥0.10 (dev env 0.12.4), `vim.treesitter.get_string_parser` + `vim.treesitter.query.get(lang, "highlights")` (validated by `spikes/ts_string_parser.lua`: parse 45.2ms/5k lines, extract 8.72ms/200 lines), bespoke headless test runner (`make test`).

## Global Constraints

- Neovim ≥0.10; `vim.text.diff`/`vim.diff` shim lives ONLY in `lua/canvasdiff/differ.lua` (`differ.hunks(old, new)` → list of `{old_start, old_count, new_start, new_count}`, `result_type="indices"`).
- No external runtime dependencies. Tests use the bespoke runner: `make test` = `nvim --headless --clean -l tests/run.lua`; `make test FILTER=pat` filters by test NAME pattern.
- **Never attach a treesitter parser, highlighter, or syntax to the canvas buffer.** All treesitter color arrives as plain extmarks computed from `get_string_parser` runs over whole-file text strings.
- Highlight priorities (fixed contract): line tier **100** (existing `canvasdiff.canvas.hl` namespace), word-diff tier **105**, treesitter tier **110**. Word+TS marks live in namespace `canvasdiff.canvas.ts`.
- Rendered diff content lines have a **1-byte prefix** (`" "`/`"-"`/`"+"`), so buffer col = source byte col + 1. `file_hdr`/`hunk_hdr` lines never get TS or word marks.
- Side mapping: `ctx` and `add` entries are highlighted from `new_text` at `entry.new_lnum`; `del` entries from `old_text` at `entry.old_lnum`. Never highlight a `ctx` line from the old side (no double marks).
- Parse cache: module-level in hl.lua, keyed by section path, LRU capacity **20**, invalidated per-path via hook when a section is replaced.
- Range-based `nvim_buf_clear_namespace` per-section is UNSAFE on splices (known landmine) — per-section mark ids are tracked and deleted by id; whole-buffer clear (0, -1) is fine on full re-render.
- Canvas buffer settings unchanged: `buftype=nofile`, `bufhidden=hide`, `modifiable=false` toggled only inside canvas.lua writes.
- Position identity stays semantic anchors; this phase must not change viewport/splice behavior — all 38 existing tests stay green.
- Pure modules (`model`, `worddiff` mark computation) must not touch window/buffer state.
- Commit after each green test cycle; commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

- `lua/canvasdiff/hl.lua` — NEW: lang detection, parse cache (LRU 20), `section_ts_marks`, apply/evict engine (`attach`/`apply_now`/`invalidate`).
- `lua/canvasdiff/worddiff.lua` — NEW: pure char-level word-diff marks per section.
- `lua/canvasdiff/model.lua` — MODIFY: sections carry `old_text`/`new_text`.
- `lua/canvasdiff/canvas.lua` — MODIFY: two optional hooks (`state.hooks.on_render_all`, `state.hooks.on_section_replaced(path)`).
- `lua/canvasdiff/config.lua` — MODIFY: `highlight = { enabled, margin, debounce_ms }` defaults.
- `lua/canvasdiff/init.lua` — MODIFY: attach on open, re-apply on refresh.
- `lua/canvasdiff/jump.lua` — MODIFY: re-apply after back-splice.
- `tests/test_hl.lua`, `tests/test_worddiff.lua` — NEW.
- `README.md` — MODIFY: document highlighting + config.

---

### Task 1: Section texts + treesitter mark computation (`hl.lua` core)

**Files:**
- Modify: `lua/canvasdiff/model.lua` (build_section return table)
- Create: `lua/canvasdiff/hl.lua`
- Test: `tests/test_hl.lua`
- Modify: `tests/test_model.lua` (one added case)

**Interfaces:**
- Consumes: `model.build_section(path, old_text, new_text, status, context)` → section `{path, status, adds, dels, nhunks, entries}` where entry = `{kind = "file_hdr"|"hunk_hdr"|"ctx"|"del"|"add", content = raw line, new_lnum, old_lnum, hunk_idx}`; entry i renders at section-relative 0-based row `i - 1`.
- Produces:
  - Sections additionally carry `old_text` (string, `""` when absent) and `new_text`.
  - `hl.lang_for(path) -> lang|nil` — nil when no filetype match, no parser, or no highlights query.
  - `hl.section_ts_marks(section) -> marks` where mark = `{row = 0-based section-relative, col, end_col (byte cols incl. +1 prefix), group = "@<capture>.<lang>", priority = 110}`. Returns `{}` for unknown languages.
  - `hl.invalidate(path)` — drops the parse cache entry for path.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_hl.lua`:

```lua
local H = require("helpers")
local model = require("canvasdiff.model")
local hl = require("canvasdiff.hl")

local T = {}

local OLD = table.concat({
  "local a = 1",
  "local b = 2",
  "local c = 3",
  "local d = 4",
  "local e = 5",
}, "\n") .. "\n"

local NEW = table.concat({
  "local a = 1",
  "local b = 20 -- changed",
  "local c = 3",
  "local d = 4",
  "local e = 5",
}, "\n") .. "\n"

T["hl_lang_for maps lua files"] = function()
  H.eq(hl.lang_for("foo/bar.lua"), "lua")
end

T["hl_lang_for unknown extension is nil"] = function()
  H.eq(hl.lang_for("foo/bar.qqqzzz"), nil)
end

T["hl_section carries whole-file texts"] = function()
  local s = model.build_section("a.lua", OLD, NEW, "M")
  H.eq(s.old_text, OLD)
  H.eq(s.new_text, NEW)
end

T["hl_ts_marks land on content rows with +1 col offset"] = function()
  -- entries: file_hdr(1) hunk_hdr(2) ctx(3) del(4) add(5) ctx(6) ctx(7) ctx(8)
  local s = model.build_section("a.lua", OLD, NEW, "M")
  local marks = hl.section_ts_marks(s)
  assert(#marks > 0, "expected some marks")
  local by_row = {}
  for _, m in ipairs(marks) do
    by_row[m.row] = by_row[m.row] or {}
    table.insert(by_row[m.row], m)
    H.eq(m.priority, 110)
    assert(m.col >= 1, "col must include the 1-byte prefix offset")
    assert(m.end_col > m.col, "non-empty span")
    assert(m.group:sub(1, 1) == "@", "treesitter group: " .. m.group)
    assert(m.group:sub(-4) == ".lua", "lang-suffixed group: " .. m.group)
  end
  assert(by_row[2], "ctx row (entry 3) highlighted from new side")
  assert(by_row[3], "del row (entry 4) highlighted from old side")
  assert(by_row[4], "add row (entry 5) highlighted from new side")
  H.eq(by_row[0], nil, "file_hdr row never highlighted")
  H.eq(by_row[1], nil, "hunk_hdr row never highlighted")

  -- Known-capture correctness: "local a = 1" has a number capture on the "1"
  -- (source byte col 10) -> buffer cols [11, 12) after the prefix shift.
  local found_number = false
  for _, m in ipairs(by_row[2]) do
    if m.group:find("number", 1, true) then
      found_number = true
      H.eq(m.col, 11, "number starts after 'local a = ' plus prefix")
      H.eq(m.end_col, 12)
    end
  end
  assert(found_number, "expected a @number capture on the ctx line")
end

T["hl_ts_marks unknown language returns empty"] = function()
  local s = model.build_section("a.qqqzzz", OLD, NEW, "M")
  H.eq(hl.section_ts_marks(s), {})
end

T["hl_ts_marks clip multiline captures per displayed row"] = function()
  local old = "local x = 1\n"
  local new = "local x = 1\nlocal s = [[\nhello\nworld\n]]\n"
  -- entries: file_hdr(1) hunk_hdr(2) ctx(3, lnum 1) add(4..7, lnums 2..5)
  local s = model.build_section("ml.lua", old, new, "M")
  local marks = hl.section_ts_marks(s)
  local function full_row_string_mark(row, text)
    for _, m in ipairs(marks) do
      if m.row == row and m.group:find("string", 1, true)
        and m.col == 1 and m.end_col == #text + 1 then
        return true
      end
    end
    return false
  end
  -- middle lines of the [[...]] string ("hello" row 4, "world" row 5) must be
  -- fully covered by per-row clipped @string marks
  assert(full_row_string_mark(4, "hello"), "hello row covered")
  assert(full_row_string_mark(5, "world"), "world row covered")
end

return T
```

Add to `tests/test_model.lua` (inside the returned table, matching its existing style):

```lua
T["model_section carries old_text and new_text"] = function()
  local s = model.build_section("t.lua", "a\n", "b\n", "M")
  H.eq(s.old_text, "a\n")
  H.eq(s.new_text, "b\n")
  local s2 = model.build_section("n.lua", nil, "b\n", "?")
  H.eq(s2.old_text, "")
end
```

(If `test_model.lua` names its table differently, match the file's existing local names.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test FILTER=hl_`
Expected: FAIL — `module 'canvasdiff.hl' not found`. Also run `make test FILTER=model_section` → FAIL on missing `old_text`.

- [ ] **Step 3: Implement**

In `lua/canvasdiff/model.lua`, extend the return table of `build_section`:

```lua
  return {
    path = path, status = status, adds = adds, dels = dels, nhunks = #groups,
    entries = entries,
    old_text = old_text or "", new_text = new_text or "",
  }
```

Create `lua/canvasdiff/hl.lua`:

```lua
local M = {}

-- Whole-file parse cache, keyed by section path. Capacity-bounded LRU so a
-- huge changeset can't pin every file's syntax tree in memory at once.
local CACHE_CAP = 20
local cache = {}          -- path -> { tick, old_src, old_tree, new_src, new_tree }
local cache_n, tick = 0, 0

local function evict_lru()
  local worst, worst_tick
  for p, e in pairs(cache) do
    if not worst_tick or e.tick < worst_tick then
      worst, worst_tick = p, e.tick
    end
  end
  if worst then
    cache[worst] = nil
    cache_n = cache_n - 1
  end
end

local function cache_entry(path)
  local e = cache[path]
  if not e then
    if cache_n >= CACHE_CAP then
      evict_lru()
    end
    e = {}
    cache[path] = e
    cache_n = cache_n + 1
  end
  tick = tick + 1
  e.tick = tick
  return e
end

--- Drop the cached trees for `path` (its content changed).
function M.invalidate(path)
  if cache[path] then
    cache[path] = nil
    cache_n = cache_n - 1
  end
end

--- Treesitter language for a repo-relative path, or nil when the filetype is
--- unknown, no parser is installed, or the language has no highlights query.
function M.lang_for(path)
  local ft = vim.filetype.match({ filename = path })
  if not ft or ft == "" then
    return nil
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if not pcall(vim.treesitter.language.add, lang) then
    return nil
  end
  local ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not ok or not query then
    return nil
  end
  return lang
end

--- Parse (or reuse) the tree for one side of a cached path. `src` identity is
--- the invalidation check: a replaced section arrives with a fresh string.
local function side_tree(entry, side, src, lang)
  local src_key, tree_key = side .. "_src", side .. "_tree"
  if entry[src_key] ~= src then
    entry[src_key] = src
    if src == "" then
      entry[tree_key] = nil
    else
      local parser = vim.treesitter.get_string_parser(src, lang)
      entry[tree_key] = parser:parse(true)[1]
    end
  end
  return entry[tree_key]
end

--- Treesitter highlight marks for one section, as pure data:
--- { row = 0-based section-relative, col, end_col (byte, incl. the 1-byte
--- rendered prefix), group = "@<capture>.<lang>", priority = 110 }.
--- ctx/add rows are colored from new_text, del rows from old_text; header
--- rows get nothing. Multi-row captures are clipped per displayed row.
function M.section_ts_marks(section)
  local lang = M.lang_for(section.path)
  if not lang then
    return {}
  end
  local query = vim.treesitter.query.get(lang, "highlights")
  local entry = cache_entry(section.path)

  local marks = {}

  local function side_marks(side)
    local src = (side == "new") and (section.new_text or "") or (section.old_text or "")
    if src == "" then
      return
    end

    -- source lnum (1-based) -> section-relative 0-based row
    local rows, lo, hi = {}, nil, nil
    for i, e in ipairs(section.entries) do
      local lnum
      if side == "new" then
        lnum = (e.kind == "ctx" or e.kind == "add") and e.new_lnum or nil
      else
        lnum = (e.kind == "del") and e.old_lnum or nil
      end
      if lnum then
        rows[lnum] = i - 1
        lo = math.min(lo or lnum, lnum)
        hi = math.max(hi or lnum, lnum)
      end
    end
    if not lo then
      return
    end

    local tree = side_tree(entry, side, src, lang)
    if not tree then
      return
    end

    local src_lines
    for id, node in query:iter_captures(tree:root(), src, lo - 1, hi) do
      local sr, sc, er, ec = node:range()
      for r = math.max(sr, lo - 1), math.min(er, hi - 1) do
        local brow = rows[r + 1]
        if brow then
          local scol = (r == sr) and sc or 0
          local ecol
          if r == er then
            ecol = ec
          else
            src_lines = src_lines or vim.split(src, "\n", { plain = true })
            ecol = #(src_lines[r + 1] or "")
          end
          if ecol > scol then
            marks[#marks + 1] = {
              row = brow,
              col = scol + 1,
              end_col = ecol + 1,
              group = "@" .. query.captures[id] .. "." .. lang,
              priority = 110,
            }
          end
        end
      end
    end
  end

  side_marks("new")
  side_marks("old")
  return marks
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test FILTER=hl_` then `make test` (full suite — all 38 existing + new must pass).
Expected: PASS everywhere.

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/hl.lua lua/canvasdiff/model.lua tests/test_hl.lua tests/test_model.lua
git commit -m "feat: treesitter mark computation from whole-file string parses"
```

---

### Task 2: Word-diff tier (`worddiff.lua`)

**Files:**
- Create: `lua/canvasdiff/worddiff.lua`
- Test: `tests/test_worddiff.lua`

**Interfaces:**
- Consumes: section entries (same shape as Task 1); `differ.hunks(old, new)` → `{ {old_start, old_count, new_start, new_count}, ... }` (1-based starts; count 0 = pure insert/delete anchored after start).
- Produces: `worddiff.section_marks(section) -> marks` — same mark shape as Task 1 but `priority = 105` and `group = "CanvasDiffWordDel"|"CanvasDiffWordAdd"`. Pairing rule: within each consecutive del-run followed by add-run, pair del k with add k; unpaired lines get no marks. Pairs where either side is empty, identical, or > 500 bytes are skipped. Cols are byte cols (UTF-8 safe) + 1 prefix.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_worddiff.lua`:

```lua
local H = require("helpers")
local model = require("canvasdiff.model")
local worddiff = require("canvasdiff.worddiff")

local T = {}

local function section(old_lines, new_lines)
  local old = table.concat(old_lines, "\n") .. "\n"
  local new = table.concat(new_lines, "\n") .. "\n"
  return model.build_section("w.txt", old, new, "M")
end

T["word_marks highlight only the changed span of a paired line"] = function()
  -- entries: file_hdr(1) hunk_hdr(2) ctx(3) del(4) add(5) ctx(6..8)
  local s = section(
    { "local a = 1", "local b = 2", "local c = 3", "local d = 4", "local e = 5" },
    { "local a = 1", "local b = 20 -- changed", "local c = 3", "local d = 4", "local e = 5" }
  )
  local marks = worddiff.section_marks(s)
  -- "local b = 2" -> "local b = 20 -- changed": pure insertion of 12 chars
  -- after byte 11. Buffer col = 11 + 1 prefix + 1 (1-based) = 12.
  H.eq(marks, {
    { row = 4, col = 12, end_col = 24, group = "CanvasDiffWordAdd", priority = 105 },
  })
end

T["word_marks are byte-correct on multibyte lines"] = function()
  local s = section({ "x = 'héllo'" }, { "x = 'hállo'" })
  local marks = worddiff.section_marks(s)
  -- chars: x,' ',=,' ',',h,é,l,l,o,' — the change is char 7 (é -> á), whose
  -- 0-based source byte offset is 6. Mark contract: col = source byte + 1
  -- (the rendered prefix), so col = 7; é/á are 2 UTF-8 bytes, so end_col = 9.
  H.eq(#marks, 2)
  local del, add = marks[1], marks[2]
  if del.group == "CanvasDiffWordAdd" then del, add = add, del end
  H.eq(del.group, "CanvasDiffWordDel")
  H.eq(add.group, "CanvasDiffWordAdd")
  H.eq(del.col, 7)
  H.eq(del.end_col, 9)  -- é is 2 bytes
  H.eq(add.col, 7)
  H.eq(add.end_col, 9)  -- á is 2 bytes
end

T["word_marks skip unpaired and blank lines"] = function()
  -- two dels collapse to one add: only the first del is paired.
  -- entries: file_hdr(1) hunk_hdr(2) del(3, row 2) del(4, row 3) add(5, row 4)
  local s = section({ "aaa bbb", "ccc ddd" }, { "aaa xxx" })
  local marks = worddiff.section_marks(s)
  for _, m in ipairs(marks) do
    assert(m.row ~= 3, "second (unpaired) del row must have no marks")
  end
  -- blank-vs-content pair is skipped entirely
  local s2 = section({ "" }, { "hello" })
  -- an empty committed side means model may classify differently; guard:
  if s2 then
    for _, m in ipairs(worddiff.section_marks(s2)) do
      error("no marks expected for blank pairing, got " .. vim.inspect(m))
    end
  end
end

return T
```

**Note on the multibyte test:** the mark `col`/`end_col` contract is the same as Task 1: source byte col + 1 (the rendered prefix), used directly as 0-based extmark cols. For `"x = 'héllo'"` the change starts at source byte 6 → `col = 7`; `é`/`á` are 2 UTF-8 bytes → `end_col = 9`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test FILTER=word_`
Expected: FAIL — `module 'canvasdiff.worddiff' not found`.

- [ ] **Step 3: Implement**

Create `lua/canvasdiff/worddiff.lua`:

```lua
local differ = require("canvasdiff.differ")

local W = {}

-- Guard against quadratic char-diff blowups on minified/generated lines.
local MAX_LINE_BYTES = 500

-- offs[i] = 0-based byte offset where char i starts; offs[#chars + 1] = #line.
local function byte_offsets(chars)
  local offs = { 0 }
  for i, c in ipairs(chars) do
    offs[i + 1] = offs[i] + #c
  end
  return offs
end

local function pair_marks(out, del_row, del_content, add_row, add_content)
  if del_content == add_content or del_content == "" or add_content == "" then
    return
  end
  if #del_content > MAX_LINE_BYTES or #add_content > MAX_LINE_BYTES then
    return
  end

  -- Char-level diff: one character per "line", then map char indices back to
  -- byte columns (multibyte safe -- \zs splits between characters).
  local dc = vim.fn.split(del_content, "\\zs")
  local ac = vim.fn.split(add_content, "\\zs")
  local hunks = differ.hunks(table.concat(dc, "\n"), table.concat(ac, "\n"))
  local doff, aoff = byte_offsets(dc), byte_offsets(ac)

  for _, h in ipairs(hunks) do
    local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]
    if old_count > 0 then
      out[#out + 1] = {
        row = del_row,
        col = doff[old_start] + 1,
        end_col = doff[old_start + old_count] + 1,
        group = "CanvasDiffWordDel",
        priority = 105,
      }
    end
    if new_count > 0 then
      out[#out + 1] = {
        row = add_row,
        col = aoff[new_start] + 1,
        end_col = aoff[new_start + new_count] + 1,
        group = "CanvasDiffWordAdd",
        priority = 105,
      }
    end
  end
end

--- Char-level word-diff marks for one section (pure data, same shape as
--- hl.section_ts_marks but priority 105). Within each consecutive del-run
--- followed by an add-run, del k pairs with add k; leftovers are unpaired.
function W.section_marks(section)
  local marks = {}
  local entries = section.entries
  local i = 1
  while i <= #entries do
    if entries[i].kind == "del" then
      local dstart = i
      while i <= #entries and entries[i].kind == "del" do
        i = i + 1
      end
      local astart = i
      while i <= #entries and entries[i].kind == "add" do
        i = i + 1
      end
      local npairs = math.min(astart - dstart, i - astart)
      for k = 0, npairs - 1 do
        pair_marks(
          marks,
          dstart + k - 1, entries[dstart + k].content,
          astart + k - 1, entries[astart + k].content
        )
      end
    else
      i = i + 1
    end
  end
  return marks
end

return W
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test FILTER=word_` then `make test`.
Expected: PASS. If the first test's exact hunk boundaries differ (diff may split the insertion differently), inspect the actual marks with `vim.inspect` and correct the EXPECTED values only if the actual marks still cover exactly the changed spans — the assertion "marks only on rows 4 and 5, nothing outside the changed bytes" is the real requirement.

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/worddiff.lua tests/test_worddiff.lua
git commit -m "feat: char-level word-diff tier marks"
```

---

### Task 3: Apply/evict engine + canvas hooks + wiring

**Files:**
- Modify: `lua/canvasdiff/hl.lua` (append engine)
- Modify: `lua/canvasdiff/canvas.lua` (hooks in `render_all` + `replace_section`)
- Modify: `lua/canvasdiff/config.lua` (highlight defaults)
- Modify: `lua/canvasdiff/init.lua` (attach/apply wiring)
- Modify: `lua/canvasdiff/jump.lua` (apply after back)
- Modify: `README.md`
- Test: `tests/test_hl.lua` (engine cases appended)

**Interfaces:**
- Consumes: `canvas.open(sections, opts) -> state {buf, win, sections, anchor_ids, hl_ids}`; `canvas.section_rows(state, i) -> start_row0, end_row0_exclusive`; `canvas.render_all(state, sections)`; `canvas.replace_section(state, i, new_section|nil)`; `hl.section_ts_marks`, `worddiff.section_marks`, `hl.invalidate` from Tasks 1–2.
- Produces:
  - `hl.attach(state, opts)` — `opts = { margin = rows beyond viewport (default 100), debounce_ms = 30 }`; sets `state.ts = { ids_by_path = {}, margin, debounce_ms }`, installs `state.hooks`, a `WinScrolled` autocmd (augroup `canvasdiff.hl`, cleared on re-attach), defines `CanvasDiffWordAdd`/`CanvasDiffWordDel` (→ `DiffText`, `default = true`), and runs one immediate `apply_now`.
  - `hl.apply_now(state)` — synchronous; no-op when `state.ts` is nil or the state window isn't showing the canvas. Applies marks for sections intersecting `[top - margin, bot + margin]`, evicts applied sections fully outside `[top - 2*margin, bot + 2*margin]`.
  - canvas.lua calls `state.hooks.on_render_all()` at the start of `render_all` and `state.hooks.on_section_replaced(path)` after every `replace_section` splice (both optional, nil-safe).
  - `config.defaults.highlight = { enabled = true, margin = 100, debounce_ms = 30 }`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_hl.lua` (before `return T`; add `local canvas = require("canvasdiff.canvas")` at the top):

```lua
-- ~90-row sections: 100 lines with a change every 10th line = 10 separated
-- hunks (context 3), each ~9 rows, plus headers.
local function big_lua(n, seed)
  local t = {}
  for i = 1, n do
    t[i] = ("local v%d_%d = %d"):format(seed, i, i)
  end
  return table.concat(t, "\n") .. "\n"
end

local function changed_every(text, step)
  local lines = vim.split(text, "\n", { plain = true })
  for i = step, #lines, step do
    if lines[i] ~= "" then
      lines[i] = lines[i] .. " + 1"
    end
  end
  return table.concat(lines, "\n")
end

local function big_sections()
  local secs = {}
  for k = 1, 3 do
    local old = big_lua(100, k)
    secs[k] = model.build_section(("f%d.lua"):format(k), old, changed_every(old, 10), "M")
  end
  return secs
end

T["hl_engine marks visible sections and skips far ones"] = function()
  local st = canvas.open(big_sections(), {})
  hl.attach(st, { margin = 5 })
  assert(st.ts.ids_by_path["f1.lua"] and #st.ts.ids_by_path["f1.lua"] > 0,
    "section under viewport highlighted on attach")
  H.eq(st.ts.ids_by_path["f3.lua"], nil, "far section untouched")
end

T["hl_engine applies on scroll and evicts at 2x margin"] = function()
  local st = canvas.open(big_sections(), {})
  hl.attach(st, { margin = 5 })
  vim.api.nvim_win_call(st.win, function()
    vim.cmd("normal! G")
  end)
  hl.apply_now(st)
  assert(st.ts.ids_by_path["f3.lua"] and #st.ts.ids_by_path["f3.lua"] > 0,
    "bottom section highlighted after scroll")
  H.eq(st.ts.ids_by_path["f1.lua"], nil, "top section evicted beyond 2x margin")
end

T["hl_engine replace_section invalidates and reapplies inside new rows"] = function()
  local old = big_lua(30, 9)
  local sec = model.build_section("r.lua", old, changed_every(old, 5), "M")
  local st = canvas.open({ sec }, {})
  hl.attach(st, { margin = 200 })
  assert(st.ts.ids_by_path["r.lua"] and #st.ts.ids_by_path["r.lua"] > 0)

  local sec2 = model.build_section("r.lua", old, changed_every(old, 7), "M")
  canvas.replace_section(st, 1, sec2)
  H.eq(st.ts.ids_by_path["r.lua"], nil, "hook cleared marks on splice")

  hl.apply_now(st)
  assert(st.ts.ids_by_path["r.lua"] and #st.ts.ids_by_path["r.lua"] > 0, "reapplied")

  local srow, erow = canvas.section_rows(st, 1)
  local ns = vim.api.nvim_create_namespace("canvasdiff.canvas.ts")
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, ns, 0, -1, {})) do
    assert(m[2] >= srow and m[2] < erow,
      ("stale mark at row %d outside [%d, %d)"):format(m[2], srow, erow))
  end
end

T["hl_engine render_all clears the ts namespace via hook"] = function()
  local st = canvas.open(big_sections(), {})
  hl.attach(st, { margin = 5 })
  canvas.render_all(st, big_sections())
  local ns = vim.api.nvim_create_namespace("canvasdiff.canvas.ts")
  H.eq(vim.api.nvim_buf_get_extmarks(st.buf, ns, 0, -1, {}), {}, "namespace cleared")
  H.eq(next(st.ts.ids_by_path), nil, "bookkeeping reset")
  hl.apply_now(st)
  assert(st.ts.ids_by_path["f1.lua"], "reapplies after re-render")
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test FILTER=hl_engine`
Expected: FAIL — `attempt to call field 'attach' (a nil value)`.

- [ ] **Step 3: Implement the engine in `hl.lua`**

Add at the top of `hl.lua` (after `local M = {}` — NOT before; canvas does not require hl, so this cannot cycle):

```lua
local canvas = require("canvasdiff.canvas")
local worddiff = require("canvasdiff.worddiff")

local TS_NS = vim.api.nvim_create_namespace("canvasdiff.canvas.ts")
```

Append before `return M`:

```lua
local function ensure_hl_groups()
  vim.api.nvim_set_hl(0, "CanvasDiffWordAdd", { link = "DiffText", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffWordDel", { link = "DiffText", default = true })
end

local function del_path_marks(state, path)
  local ids = state.ts.ids_by_path[path]
  if not ids then
    return
  end
  for _, id in ipairs(ids) do
    pcall(vim.api.nvim_buf_del_extmark, state.buf, TS_NS, id)
  end
  state.ts.ids_by_path[path] = nil
end

local function apply_section(state, i)
  local sec = state.sections[i]
  local srow = (canvas.section_rows(state, i))
  local ids = {}
  local function place(list)
    for _, m in ipairs(list) do
      ids[#ids + 1] = vim.api.nvim_buf_set_extmark(state.buf, TS_NS, srow + m.row, m.col, {
        end_row = srow + m.row,
        end_col = m.end_col,
        hl_group = m.group,
        priority = m.priority,
        strict = false,
      })
    end
  end
  place(M.section_ts_marks(sec))
  place(worddiff.section_marks(sec))
  state.ts.ids_by_path[sec.path] = ids
end

--- Synchronously apply marks for sections within viewport±margin and evict
--- applied sections fully outside 2x margin. Safe to call any time; no-ops
--- when highlighting isn't attached or the canvas isn't showing.
function M.apply_now(state)
  local ts = state.ts
  if not ts then
    return
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_win_get_buf(state.win) == state.buf) then
    return
  end
  local info = vim.api.nvim_win_call(state.win, function()
    return { top0 = vim.fn.line("w0") - 1, bot0 = vim.fn.line("w$") - 1 }
  end)
  local lo, hi = info.top0 - ts.margin, info.bot0 + ts.margin
  local evict_lo, evict_hi = info.top0 - 2 * ts.margin, info.bot0 + 2 * ts.margin

  for i, sec in ipairs(state.sections) do
    local srow, erow = canvas.section_rows(state, i)
    local in_window = srow <= hi and erow > lo
    local has = ts.ids_by_path[sec.path] ~= nil
    if in_window and not has then
      apply_section(state, i)
    elseif has and (erow <= evict_lo or srow > evict_hi) then
      del_path_marks(state, sec.path)
    end
  end
end

local timer

local function debounce(state, ms)
  if not timer then
    timer = vim.uv.new_timer()
  end
  timer:stop()
  timer:start(ms, 0, vim.schedule_wrap(function()
    M.apply_now(state)
  end))
end

--- Attach lazy treesitter+word highlighting to a live canvas state: install
--- invalidation hooks, a debounced WinScrolled trigger, and apply once now.
function M.attach(state, opts)
  opts = opts or {}
  ensure_hl_groups()
  state.ts = {
    ids_by_path = {},
    margin = opts.margin or 100,
    debounce_ms = opts.debounce_ms or 30,
  }

  state.hooks = state.hooks or {}
  state.hooks.on_render_all = function()
    vim.api.nvim_buf_clear_namespace(state.buf, TS_NS, 0, -1)
    state.ts.ids_by_path = {}
  end
  state.hooks.on_section_replaced = function(path)
    del_path_marks(state, path)
    M.invalidate(path)
  end

  local aug = vim.api.nvim_create_augroup("canvasdiff.hl", { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = aug,
    callback = function(ev)
      local win = tonumber(ev.match)
      if win and vim.api.nvim_win_is_valid(win)
          and vim.api.nvim_win_get_buf(win) == state.buf then
        debounce(state, state.ts.debounce_ms)
      end
    end,
  })

  M.apply_now(state)
end
```

- [ ] **Step 4: Add the hooks to `canvas.lua`**

In `M.render_all`, right after the two `nvim_buf_clear_namespace` calls:

```lua
  if state.hooks and state.hooks.on_render_all then
    state.hooks.on_render_all()
  end
```

In `M.replace_section`, first line of the function body:

```lua
  local replaced_path = state.sections[i] and state.sections[i].path
```

and immediately after `set_modifiable(state.buf, false)` (before the view-correction block):

```lua
  -- Extmarks inside a replaced range collapse rather than die, so the
  -- treesitter/word tier must delete its marks by id NOW, in the same tick.
  if replaced_path and state.hooks and state.hooks.on_section_replaced then
    state.hooks.on_section_replaced(replaced_path)
  end
```

- [ ] **Step 5: Run the engine tests**

Run: `make test FILTER=hl_engine`
Expected: PASS (all four). Then `make test` — full suite green.

- [ ] **Step 6: Wire config / init / jump / README**

`lua/canvasdiff/config.lua` — add to `M.defaults`:

```lua
  highlight = {
    enabled = true,
    margin = 100,
    debounce_ms = 30,
  },
```

`lua/canvasdiff/init.lua` — add `local hl = require("canvasdiff.hl")` to the requires; at the end of `M.open()` (after `set_canvas_keymaps(st)`):

```lua
  if config.options.highlight.enabled then
    hl.attach(st, config.options.highlight)
  end
```

and at the end of `M.refresh()`:

```lua
  hl.apply_now(state)
```

`lua/canvasdiff/jump.lua` — add `local hl = require("canvasdiff.hl")` to the requires; in `M.back()`, after the final `winrestview` call:

```lua
  hl.apply_now(state)
```

`README.md` — in the features/config sections: note that diff content is syntax-highlighted with the user's own treesitter setup plus intra-line word-diff emphasis, and document the `highlight` config table (`enabled`, `margin` = rows beyond the viewport kept highlighted, `debounce_ms` = scroll debounce) and the `CanvasDiffWordAdd`/`CanvasDiffWordDel` groups (default: `DiffText`).

- [ ] **Step 7: Full suite + smoke**

Run: `make test`
Expected: all tests pass, zero warnings.

Headless smoke (from the repo root — repo must have at least one uncommitted change; if clean, `echo "-- smoke" >> README.md` first, then `git checkout -- README.md` after):

```bash
nvim --headless --clean -c "set rtp+=." -c "lua require('canvasdiff').open()" \
  -c "lua local ns = vim.api.nvim_create_namespace('canvasdiff.canvas.ts'); print('ts marks: ' .. #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}))" \
  -c "qa!"
```

Expected: `ts marks: N` with N > 0 when a lua/known-language file is dirty.

- [ ] **Step 8: Commit**

```bash
git add lua/canvasdiff/ tests/test_hl.lua README.md
git commit -m "feat: lazy treesitter + word-diff highlighting on the canvas"
```

---

## Self-Review Notes

- Spec coverage: §2 of the concept plan — whole-file string parses ✓ (Task 1), capture copy with lang-suffixed groups ✓ (Task 1), two-tier priorities 100/105/110 ✓ (Tasks 2–3), lazy margin application + eviction ✓ (Task 3), parser cache ✓ (Task 1, LRU 20), word tier ✓ (Task 2), never attach to canvas ✓ (constraint, no `vim.treesitter.start` anywhere). Injections inside string parses are parsed (`parse(true)`) but only the root-language tree is queried — documented MVP limitation, fine for Phase 2.
- The coroutine render pump from the concept plan is deliberately deferred to Phase 6 (virtualization/scale): synchronous parse on first visibility is within spike-verified budgets for MVP-scale changesets.
- Type consistency: mark shape `{row, col, end_col, group, priority}` identical across `hl.section_ts_marks` and `worddiff.section_marks`; both consumed only by `apply_section`.
