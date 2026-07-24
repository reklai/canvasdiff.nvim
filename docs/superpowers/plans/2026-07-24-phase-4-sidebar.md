# Phase 4 — Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A folding file-tree sidebar that tracks the canvas scroll position, lets `<CR>` scroll the canvas to any file (never opening anything), and gives the canvas `<C-n>/<C-p>` section cycling — focus never leaves the pane the user is in.

**Architecture:** `sidebar.lua` has a pure half (`build_entries(sections, folded)` flattens the alphabetical section list into an indented dir/file tree honoring folds; `render_lines(entries)` formats it) and a window half: one scratch buffer in a left vsplit (`winfixbuf` + `winfixwidth` — the canvas window must NOT get `winfixbuf` or jump's `:edit` breaks), a module-level singleton mirroring init.lua's state pattern. Scroll-sync reuses `WinScrolled` → `canvas.locate` on the canvas topline → active-entry highlight (falling back to the deepest visible ancestor dir when the file is folded away). Mutating paths (open/refresh/reconcile/jump-back) call `sidebar.refresh`.

**Tech Stack:** Lua, Neovim ≥0.10 (`nvim_open_win` with `split = "left"`, `winfixbuf`), bespoke headless test runner.

## Global Constraints

- Neovim ≥0.10; no external runtime dependencies; `make test` (FILTER by test NAME).
- **The canvas window must NEVER get `winfixbuf`** (jump's `:edit` reuses it). The sidebar window gets `winfixbuf` + `winfixwidth`.
- Sidebar `<CR>` scrolls the canvas — it never opens a file or changes any window's buffer. `<C-n>/<C-p>` are canvas-buffer-local and move only the canvas view + sidebar selection; focus stays where the user is.
- Sections are always sorted alphabetically by path; `entry.section_i` indexes into `state.sections` and is recomputed on every refresh (never cached across mutations).
- Sidebar sync/refresh must be nil-safe no-ops when the sidebar isn't open, and sync must no-op when the canvas window isn't currently showing the canvas buffer (jump excursion in progress).
- Require graph stays acyclic: `sidebar` → {canvas}; `init`/`watch`/`jump` → sidebar; canvas/hl never require sidebar.
- Pure half (`build_entries`, `render_lines`) must not touch windows/buffers.
- Highlight groups: `GalleySidebarDir` → `Directory` (default=true), `GalleySidebarActive` → `Visual` (default=true); active entry marked via `line_hl_group` extmark in namespace `galley.sidebar`.
- Config additions: `sidebar = { enabled = true, width = 32 }`; `keymaps.cycle_next = "<C-n>"`, `keymaps.cycle_prev = "<C-p>"`. Sidebar-buffer-local keys are fixed: `<CR>` select, `<Tab>` and `za` fold-toggle (dir rows), `q` closes the sidebar only.
- Commit after each green cycle; trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Current suite is 74/74 green and must stay green.

## File Structure

- `lua/galley/sidebar.lua` — NEW: pure tree building/rendering + window lifecycle/sync/select/cycle.
- `lua/galley/config.lua` — MODIFY: sidebar + cycle-key defaults.
- `lua/galley/init.lua` — MODIFY: open/close/refresh wiring + canvas cycle keymaps.
- `lua/galley/watch.lua` — MODIFY: `sidebar.refresh(state)` after reconcile mutations.
- `lua/galley/jump.lua` — MODIFY: `sidebar.refresh(state)` after back-splice.
- `tests/test_sidebar.lua` — NEW.
- `README.md` — MODIFY.

---

### Task 1: Pure tree — `build_entries` + `render_lines`

**Files:**
- Create: `lua/galley/sidebar.lua` (pure half only)
- Test: `tests/test_sidebar.lua`

**Interfaces:**
- Consumes: sections `{path, adds, dels, ...}` sorted alphabetically by path.
- Produces:
  - `sidebar.build_entries(sections, folded) -> entries` — flat list in display order. Dir entry: `{kind = "dir", path = "lua/sub/" (trailing slash, cumulative), name = "sub/", depth = <0-based>, folded = bool}`. File entry: `{kind = "file", path = section.path, name = <basename>, depth = <#dir components>, section_i = <index into sections>, adds, dels}`. `folded` is a set (`{["lua/"] = true}`); a folded dir appears itself but none of its descendants (dirs or files) do. Each dir appears exactly once, immediately before its first descendant.
  - `sidebar.render_lines(entries) -> lines` — dir: `indent .. ("▸ "|"▾ ") .. name` (▸ when folded); file: `indent .. name .. ("  +%d −%d"):format(adds, dels)` (U+2212 minus, matching render.lua); indent = two spaces per depth.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_sidebar.lua`:

```lua
local H = require("helpers")
local sidebar = require("galley.sidebar")

local T = {}

local function sec(path, adds, dels)
  return { path = path, adds = adds or 1, dels = dels or 0 }
end

T["sidebar_entries flat root files need no dir rows"] = function()
  local entries = sidebar.build_entries({ sec("a.txt"), sec("b.txt") }, {})
  H.eq(#entries, 2)
  H.eq(entries[1], { kind = "file", path = "a.txt", name = "a.txt", depth = 0,
    section_i = 1, adds = 1, dels = 0 })
  H.eq(entries[2].section_i, 2)
end

T["sidebar_entries nested dirs emitted once with correct depth"] = function()
  local entries = sidebar.build_entries({
    sec("lua/mod/a.lua"), sec("lua/mod/b.lua"), sec("lua/top.lua"), sec("root.md"),
  }, {})
  local shape = {}
  for i, e in ipairs(entries) do
    shape[i] = { e.kind, e.path, e.depth }
  end
  H.eq(shape, {
    { "dir", "lua/", 0 },
    { "dir", "lua/mod/", 1 },
    { "file", "lua/mod/a.lua", 2 },
    { "file", "lua/mod/b.lua", 2 },
    { "file", "lua/top.lua", 1 },
    { "file", "root.md", 0 },
  })
  H.eq(entries[3].section_i, 1)
  H.eq(entries[5].section_i, 3)
  H.eq(entries[6].section_i, 4)
end

T["sidebar_entries folded dir hides all descendants"] = function()
  local entries = sidebar.build_entries({
    sec("lua/mod/a.lua"), sec("lua/mod/deep/c.lua"), sec("lua/top.lua"), sec("root.md"),
  }, { ["lua/mod/"] = true })
  local shape = {}
  for i, e in ipairs(entries) do
    shape[i] = { e.kind, e.path }
  end
  H.eq(shape, {
    { "dir", "lua/" },
    { "dir", "lua/mod/" },
    { "file", "lua/top.lua" },
    { "file", "root.md" },
  })
  H.eq(entries[2].folded, true)
end

T["sidebar_render formats dirs, files, indent, and counts"] = function()
  local entries = sidebar.build_entries({
    sec("lua/mod/a.lua", 12, 3), sec("root.md", 0, 5),
  }, { ["lua/mod/"] = true })
  local lines = sidebar.render_lines(entries)
  H.eq(lines, {
    "▾ lua/",
    "  ▸ mod/",
    "root.md  +0 −5",
  })
end

return T
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test FILTER=sidebar_`
Expected: FAIL — `module 'galley.sidebar' not found`.

- [ ] **Step 3: Implement the pure half**

Create `lua/galley/sidebar.lua`:

```lua
local S = {}

--- Flatten alphabetical sections into display-ordered dir/file entries.
--- `folded` is a set of dir paths ("lua/mod/" -- cumulative, trailing
--- slash); a folded dir is shown itself but none of its descendants are.
--- Sections are sorted by path, so each dir is emitted exactly once,
--- immediately before its first descendant.
function S.build_entries(sections, folded)
  folded = folded or {}
  local entries = {}
  local prev_dirs = {}

  for i, section in ipairs(sections) do
    local parts = vim.split(section.path, "/", { plain = true })
    local fname = table.remove(parts)

    local shared = 0
    for d = 1, math.min(#prev_dirs, #parts) do
      if prev_dirs[d] == parts[d] then
        shared = d
      else
        break
      end
    end

    local hidden = false
    local prefix = ""
    for d = 1, #parts do
      prefix = prefix .. parts[d] .. "/"
      if not hidden then
        if d > shared then
          entries[#entries + 1] = {
            kind = "dir", path = prefix, name = parts[d] .. "/",
            depth = d - 1, folded = folded[prefix] or false,
          }
        end
        if folded[prefix] then
          hidden = true
        end
      end
    end

    if not hidden then
      entries[#entries + 1] = {
        kind = "file", path = section.path, name = fname, depth = #parts,
        section_i = i, adds = section.adds, dels = section.dels,
      }
    end
    prev_dirs = parts
  end

  return entries
end

--- Render entries to display lines (pure).
function S.render_lines(entries)
  local lines = {}
  for i, e in ipairs(entries) do
    local indent = ("  "):rep(e.depth)
    if e.kind == "dir" then
      lines[i] = indent .. (e.folded and "▸ " or "▾ ") .. e.name
    else
      lines[i] = indent .. e.name .. ("  +%d −%d"):format(e.adds, e.dels)
    end
  end
  return lines
end

return S
```

**Wait — check the fold/shared interaction before running:** in the third test, `lua/mod/` is folded and consecutive sections share the `lua/mod` prefix; the shared-prefix skip means the dir is not re-emitted for the second section, and the `hidden` flag must still be set for it. Note the loop sets `hidden` from `folded[prefix]` even when `d <= shared` (no emit) — that is what keeps `lua/mod/deep/c.lua` fully hidden. Keep that ordering exactly.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test FILTER=sidebar_` then `make test` (78/78 expected).

- [ ] **Step 5: Commit**

```bash
git add lua/galley/sidebar.lua tests/test_sidebar.lua
git commit -m "feat: sidebar tree building and rendering (pure)"
```

---

### Task 2: Sidebar window — lifecycle, sync, select, fold

**Files:**
- Modify: `lua/galley/sidebar.lua` (window half)
- Test: `tests/test_sidebar.lua` (window cases appended)

**Interfaces:**
- Consumes: `canvas.locate(state, row0) -> section_i, offset`; `canvas.section_rows(state, i) -> start0, end0_exclusive`; canvas state `{buf, win, sections}`.
- Produces (module-level singleton `side = {buf, win, entries, folded, active_row}`, mirroring init.lua's state pattern):
  - `sidebar.open(state, opts)` — `opts = { width = 32 }`. Creates a scratch buffer (`nofile`, `bufhidden=wipe`, `swapfile=false`, `modifiable=false` toggled around writes) in a NON-entered left vsplit of `state.win` (`nvim_open_win(buf, false, { split = "left", width = opts.width or 32, win = state.win })`), sets sidebar-window options (`winfixwidth`, `winfixbuf`, `wrap=false`, `cursorline=true`, `number=false`, `relativenumber=false`, `signcolumn="no"`, `foldenable=false`), defines the two highlight groups, installs buffer-local keymaps (`<CR>` → `sidebar.select(state)`, `<Tab>`/`za` → `sidebar.select(state)` restricted to dir rows — same function, see select semantics, `q` → `sidebar.close()`), installs autocmds in augroup `galley.sidebar` (cleared on re-open): `WinScrolled` (canvas-window match → `sidebar.sync(state)`) and `WinClosed` for the sidebar window (clears the singleton). Idempotent: open while open = refresh. Ends with `refresh` + `sync`.
  - `sidebar.close()` — closes the window if valid, clears the singleton + augroup; safe always.
  - `sidebar.is_open() -> bool`.
  - `sidebar.refresh(state)` — no-op when closed; rebuilds entries from `state.sections` + current folds, renders lines, re-applies `GalleySidebarDir` marks to dir rows, re-syncs.
  - `sidebar.sync(state)` — no-op when closed OR when `state.win` isn't showing `state.buf`. Finds the section under the canvas topline (`canvas.locate`), picks the entry to activate: the file entry with that `section_i`, else the deepest visible dir entry whose `path` prefixes the section's path; applies `line_hl_group = "GalleySidebarActive"` (namespace `galley.sidebar`, previous active mark cleared) and moves the sidebar cursor to that row.
  - `sidebar.select(state)` — acts on the sidebar-cursor row's entry: dir ⇒ toggle `folded[path]` + refresh; file ⇒ scroll the canvas (`winrestview{ topline = start0 + 1, lnum = start0 + 1 }` inside `state.win`) + sync. Never changes any window's buffer or the focused window.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_sidebar.lua` (add `local canvas = require("galley.canvas")` and `local model = require("galley.model")` at the top):

```lua
local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

-- ~55 rows per section (6 separated hunks): sections must be taller than
-- the ~22-row headless window or topline restores would clamp and the
-- scroll-targeting assertions below would silently test the wrong section.
local function big_section(path, tag)
  local old = bigtext(60, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 10, 60, 10 do
    lines[i] = lines[i] .. " changed"
  end
  local new = table.concat(lines, "\n")
  return model.build_section(path, old, new, "M")
end

local function open_with_sidebar()
  local secs = {
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
  }
  local st = canvas.open(secs, {})
  sidebar.close() -- reset singleton across tests
  sidebar.open(st, { width = 30 })
  return st
end

T["sidebar_win opens fixed non-focused split; canvas keeps winfixbuf off"] = function()
  local st = open_with_sidebar()
  assert(sidebar.is_open())
  local side_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= st.win and vim.api.nvim_win_get_buf(w) ~= st.buf then
      side_win = w
    end
  end
  assert(side_win, "sidebar window exists")
  H.eq(vim.api.nvim_get_current_win(), st.win, "focus stays in canvas")
  H.eq(vim.api.nvim_win_get_width(side_win), 30)
  H.eq(vim.api.nvim_get_option_value("winfixbuf", { win = side_win }), true)
  H.eq(vim.api.nvim_get_option_value("winfixwidth", { win = side_win }), true)
  H.eq(vim.api.nvim_get_option_value("winfixbuf", { win = st.win }), false,
    "canvas window must never get winfixbuf")
  sidebar.close()
  H.eq(sidebar.is_open(), false)
end

local SIDE_NS = vim.api.nvim_create_namespace("galley.sidebar")

local function active_row(side_buf)
  local marks = vim.api.nvim_buf_get_extmarks(side_buf, SIDE_NS, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    if m[4] and m[4].line_hl_group == "GalleySidebarActive" then
      return m[2]
    end
  end
  return nil
end

local function sidebar_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find("galley://sidebar") then
      return b
    end
  end
end

T["sidebar_win sync tracks the section under the canvas topline"] = function()
  local st = open_with_sidebar()
  local sbuf = sidebar_buf()
  sidebar.sync(st)
  -- entries: a/(0) one.txt(1) b/(2) two.txt(3) c/(4) three.txt(5) -> rows 0..5
  H.eq(active_row(sbuf), 1, "first file active at top")

  local b_start = (canvas.section_rows(st, 2))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = b_start + 2, lnum = b_start + 2 })
  end)
  sidebar.sync(st)
  H.eq(active_row(sbuf), 3, "second file active after scroll")
  sidebar.close()
end

T["sidebar_win select on a file scrolls the canvas, never refocuses"] = function()
  local st = open_with_sidebar()
  local sbuf = sidebar_buf()
  local side_win = vim.fn.bufwinid(sbuf)
  vim.api.nvim_win_set_cursor(side_win, { 6, 0 }) -- c/three.txt row (1-based 6)
  local focused_before = vim.api.nvim_get_current_win()
  sidebar.select(st)
  local c_start = (canvas.section_rows(st, 3))
  local top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, c_start + 1, "canvas scrolled to the selected section")
  H.eq(vim.api.nvim_win_get_buf(st.win), st.buf, "canvas window buffer untouched")
  H.eq(vim.api.nvim_get_current_win(), focused_before, "focus unchanged")
  sidebar.close()
end

T["sidebar_win select on a dir folds it and active falls back to the dir"] = function()
  local st = open_with_sidebar()
  local sbuf = sidebar_buf()
  local side_win = vim.fn.bufwinid(sbuf)
  vim.api.nvim_win_set_cursor(side_win, { 1, 0 }) -- a/ dir row
  sidebar.select(st)
  local lines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
  H.eq(lines[1], "▸ a/", "dir folded")
  H.eq(#lines, 5, "a/one.txt hidden")
  -- canvas still at top (section 1 = a/one.txt, now folded away): active
  -- falls back to the deepest visible ancestor dir
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  sidebar.sync(st)
  H.eq(active_row(sbuf), 0, "folded ancestor dir is the active entry")
  sidebar.close()
end

T["sidebar_win manual :close of the sidebar window clears the singleton"] = function()
  local st = open_with_sidebar()
  local sbuf = sidebar_buf()
  local side_win = vim.fn.bufwinid(sbuf)
  vim.api.nvim_win_close(side_win, true)
  H.eq(sidebar.is_open(), false, "WinClosed cleaned up")
  -- and everything stays nil-safe afterwards
  sidebar.refresh(st)
  sidebar.sync(st)
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test FILTER=sidebar_win`
Expected: FAIL — `attempt to call field 'open' (a nil value)`.

- [ ] **Step 3: Implement the window half**

Append to `lua/galley/sidebar.lua` (before `return S`; add `local canvas = require("galley.canvas")` at the top):

```lua
local NS = vim.api.nvim_create_namespace("galley.sidebar")
local BUFNAME = "galley://sidebar"

-- Module-level singleton, mirroring init.lua's state pattern: at most one
-- sidebar, always attached to the one live canvas.
local side = nil

local function ensure_hl_groups()
  vim.api.nvim_set_hl(0, "GalleySidebarDir", { link = "Directory", default = true })
  vim.api.nvim_set_hl(0, "GalleySidebarActive", { link = "Visual", default = true })
end

function S.is_open()
  return side ~= nil and side.win ~= nil and vim.api.nvim_win_is_valid(side.win)
end

local function set_modifiable(buf, val)
  vim.api.nvim_set_option_value("modifiable", val, { buf = buf })
end

--- Rebuild entries from the live sections + fold state and redraw.
function S.refresh(state)
  if not S.is_open() then
    return
  end
  side.entries = S.build_entries(state.sections, side.folded)
  local lines = S.render_lines(side.entries)
  if #lines == 0 then
    lines = { "" }
  end
  set_modifiable(side.buf, true)
  vim.api.nvim_buf_set_lines(side.buf, 0, -1, false, lines)
  set_modifiable(side.buf, false)
  vim.api.nvim_buf_clear_namespace(side.buf, NS, 0, -1)
  for row0, e in ipairs(side.entries) do
    if e.kind == "dir" then
      vim.api.nvim_buf_set_extmark(side.buf, NS, row0 - 1, 0, {
        line_hl_group = "GalleySidebarDir",
        priority = 90,
      })
    end
  end
  side.active_mark = nil
  S.sync(state)
end

--- Track the canvas topline: activate the file entry for the section under
--- it, or the deepest visible ancestor dir when folds hide the file.
function S.sync(state)
  if not S.is_open() then
    return
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_win_get_buf(state.win) == state.buf) then
    return -- excursion in progress or canvas hidden
  end
  local top0 = vim.api.nvim_win_call(state.win, function()
    return vim.fn.line("w0") - 1
  end)
  local section_i = (canvas.locate(state, top0))
  if not section_i then
    return
  end
  local path = state.sections[section_i].path

  local best
  for row0m1, e in ipairs(side.entries) do
    if (e.kind == "file" and e.section_i == section_i)
      or (e.kind == "dir" and path:sub(1, #e.path) == e.path) then
      best = row0m1 - 1
    end
  end
  if not best then
    return
  end

  if side.active_mark then
    pcall(vim.api.nvim_buf_del_extmark, side.buf, NS, side.active_mark)
  end
  side.active_mark = vim.api.nvim_buf_set_extmark(side.buf, NS, best, 0, {
    line_hl_group = "GalleySidebarActive",
    priority = 100,
  })
  pcall(vim.api.nvim_win_set_cursor, side.win, { best + 1, 0 })
end

--- Act on the entry under the sidebar cursor: dir toggles its fold; file
--- scrolls the canvas to its section. Never changes any window's buffer or
--- the focused window.
function S.select(state)
  if not S.is_open() then
    return
  end
  local row = vim.api.nvim_win_get_cursor(side.win)[1]
  local e = side.entries[row]
  if not e then
    return
  end
  if e.kind == "dir" then
    side.folded[e.path] = not side.folded[e.path] or nil
    S.refresh(state)
  else
    local start0 = (canvas.section_rows(state, e.section_i))
    vim.api.nvim_win_call(state.win, function()
      vim.fn.winrestview({ topline = start0 + 1, lnum = start0 + 1 })
    end)
    S.sync(state)
  end
end

function S.close()
  if side then
    local win = side.win
    side = nil
    pcall(vim.api.nvim_del_augroup_by_name, "galley.sidebar")
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- Open (or refresh) the sidebar as a non-focused fixed vsplit left of the
--- canvas window. The canvas window itself must never get winfixbuf.
function S.open(state, opts)
  opts = opts or {}
  if S.is_open() then
    S.refresh(state)
    return
  end
  ensure_hl_groups()

  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, BUFNAME)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  set_modifiable(buf, false)

  local win = vim.api.nvim_open_win(buf, false, {
    split = "left",
    width = opts.width or 32,
    win = state.win,
  })
  local wopts = {
    winfixwidth = true, winfixbuf = true, wrap = false, cursorline = true,
    number = false, relativenumber = false, signcolumn = "no", foldenable = false,
  }
  for name, val in pairs(wopts) do
    vim.api.nvim_set_option_value(name, val, { win = win, scope = "local" })
  end

  side = { buf = buf, win = win, entries = {}, folded = {}, active_mark = nil }

  local map_opts = { buffer = buf, silent = true, noremap = true }
  vim.keymap.set("n", "<CR>", function() S.select(state) end, map_opts)
  vim.keymap.set("n", "<Tab>", function() S.select(state) end, map_opts)
  vim.keymap.set("n", "za", function() S.select(state) end, map_opts)
  vim.keymap.set("n", "q", function() S.close() end, map_opts)

  local aug = vim.api.nvim_create_augroup("galley.sidebar", { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = aug,
    callback = function(ev)
      local w = tonumber(ev.match)
      if side and w == state.win
          and vim.api.nvim_win_get_buf(state.win) == state.buf then
        S.sync(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    pattern = tostring(win),
    callback = function()
      side = nil
      pcall(vim.api.nvim_del_augroup_by_name, "galley.sidebar")
    end,
  })

  S.refresh(state)
end
```

Note on select-for-`<Tab>`/`za`: on a file row they behave like `<CR>` (scroll) — acceptable and simpler than a separate fold-only function; the brief's semantics ("fold-toggle on dir rows") are satisfied because folding only applies to dir rows either way.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test FILTER=sidebar_win` then `make test` (83/83 expected).

- [ ] **Step 5: Commit**

```bash
git add lua/galley/sidebar.lua tests/test_sidebar.lua
git commit -m "feat: sidebar window with scroll-sync, select, and folding"
```

---

### Task 3: Cycling + wiring

**Files:**
- Modify: `lua/galley/sidebar.lua` (`S.cycle`)
- Modify: `lua/galley/config.lua`, `lua/galley/init.lua`, `lua/galley/watch.lua`, `lua/galley/jump.lua`
- Modify: `README.md`
- Test: `tests/test_sidebar.lua` (cycle + integration cases appended)

**Interfaces:**
- Produces:
  - `sidebar.cycle(state, delta)` — works with or without the sidebar open: finds the section under the canvas topline, moves to section `i + delta` (wrapping at both ends), scrolls the canvas to its start (same winrestview as select), then `sidebar.sync(state)`. No-op when the canvas window isn't showing the canvas or there are no sections.
  - config: `defaults.sidebar = { enabled = true, width = 32 }`; `defaults.keymaps.cycle_next = "<C-n>"`, `defaults.keymaps.cycle_prev = "<C-p>"`.
  - init: `M.open` opens the sidebar when `config.options.sidebar.enabled` (after hl/watch setup) and adds canvas-buffer-local cycle keymaps in `set_canvas_keymaps`; `M.close` calls `sidebar.close()` (alongside watch.stop/hl.detach); `M.refresh` calls `sidebar.refresh(state)`.
  - watch: `W.reconcile` calls `sidebar.refresh(state)` after every mutating path (both the 0↔N/render_all paths and the merge-walk path, after `hl.apply_now`).
  - jump: `M.back` calls `sidebar.refresh(state)` after its final `hl.apply_now`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_sidebar.lua`:

```lua
T["sidebar_cycle moves canvas by sections and wraps"] = function()
  local st = open_with_sidebar()
  local sbuf = sidebar_buf()
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)

  sidebar.cycle(st, 1)
  local top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 2)) + 1, "moved to section 2")
  H.eq(active_row(sbuf), 3, "sidebar followed")

  sidebar.cycle(st, 1)
  sidebar.cycle(st, 1) -- wraps past the last section
  top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 1)) + 1, "wrapped to section 1")

  sidebar.cycle(st, -1) -- wraps backwards
  top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 3)) + 1, "wrapped to last section")
  sidebar.close()
end

T["sidebar_cycle works without a sidebar open"] = function()
  local secs = { big_section("a/one.txt", "a"), big_section("b/two.txt", "b") }
  local st = canvas.open(secs, {})
  sidebar.close()
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  sidebar.cycle(st, 1)
  local top = vim.api.nvim_win_call(st.win, function() return vim.fn.line("w0") end)
  H.eq(top, (canvas.section_rows(st, 2)) + 1)
end

T["sidebar_integration reconcile refreshes the tree"] = function()
  local watch = require("galley.watch")
  local root = H.git_fixture({
    committed = { ["m/a.txt"] = bigtext(40, "a") },
    worktree = { ["m/a.txt"] = (bigtext(40, "a"):gsub("a line 5", "a line 5 X")) },
  })
  local st = canvas.open(require("galley.model").build(
    require("galley.collect").files(root), 3), {})
  st.root = root
  sidebar.close()
  sidebar.open(st, { width = 30 })
  local sbuf = sidebar_buf()
  H.eq(#vim.api.nvim_buf_get_lines(sbuf, 0, -1, false), 2, "dir + one file")

  local abs = vim.fs.joinpath(root, "m", "b.txt")
  local f = assert(io.open(abs, "w")); f:write("new\n"); f:close()
  watch.reconcile(st)

  local lines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
  H.eq(#lines, 3, "new file appears in the sidebar after reconcile")
  assert(lines[3]:find("b.txt", 1, true), "b.txt rendered: " .. lines[3])
  sidebar.close()
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test FILTER=sidebar_cycle` — FAIL (`cycle` nil); the integration test also fails (reconcile doesn't refresh).

- [ ] **Step 3: Implement**

`sidebar.lua` — append:

```lua
--- Cycle the canvas view to the next/previous section (wrapping), keeping
--- the sidebar selection in step. Usable with or without the sidebar open;
--- focus never moves.
function S.cycle(state, delta)
  local n = #state.sections
  if n == 0 then
    return
  end
  if not (state.win and vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_win_get_buf(state.win) == state.buf) then
    return
  end
  local top0 = vim.api.nvim_win_call(state.win, function()
    return vim.fn.line("w0") - 1
  end)
  local i = (canvas.locate(state, top0)) or 1
  local target = ((i - 1 + delta) % n) + 1
  local start0 = (canvas.section_rows(state, target))
  vim.api.nvim_win_call(state.win, function()
    vim.fn.winrestview({ topline = start0 + 1, lnum = start0 + 1 })
  end)
  S.sync(state)
end
```

`config.lua` — add to `M.defaults`: `sidebar = { enabled = true, width = 32 }` and inside `keymaps`: `cycle_next = "<C-n>", cycle_prev = "<C-p>"`.

`init.lua` — add `local sidebar = require("galley.sidebar")`; in `set_canvas_keymaps` add:

```lua
  vim.keymap.set("n", cfg.keymaps.cycle_next, function()
    sidebar.cycle(st, 1)
  end, map_opts)
  vim.keymap.set("n", cfg.keymaps.cycle_prev, function()
    sidebar.cycle(st, -1)
  end, map_opts)
```

in `M.open`, after the watch block:

```lua
  if config.options.sidebar.enabled then
    sidebar.open(st, config.options.sidebar)
  end
```

in `M.close`, next to `watch.stop()` / `hl.detach(state)`: `sidebar.close()`. In `M.refresh`, after `hl.apply_now(state)`: `sidebar.refresh(state)`.

`watch.lua` — add `local sidebar = require("galley.sidebar")`; in `W.reconcile`, add `sidebar.refresh(state)` immediately after BOTH `hl.apply_now(state)` call sites (the 0↔N/guard path and the merge-walk tail).

`jump.lua` — add `local sidebar = require("galley.sidebar")`; in `M.back`, after the final `hl.apply_now(state)`: `sidebar.refresh(state)`.

`README.md` — document the sidebar (auto-opens; `<CR>` scrolls the canvas, `<Tab>`/`za` fold dirs, `q` closes the sidebar), `<C-n>/<C-p>` cycling, and the `sidebar`/keymap config.

- [ ] **Step 4: Run tests, full suite twice**

Run: `make test FILTER=sidebar_` then `make test` twice (86/86 both runs).

- [ ] **Step 5: Commit**

```bash
git add lua/galley/ tests/test_sidebar.lua README.md
git commit -m "feat: section cycling and sidebar wiring"
```

---

## Self-Review Notes

- Concept plan §5 coverage: vsplit scratch + winfixbuf/winfixwidth ✓ (canvas explicitly excluded ✓); indented tree with dir folding ✓; scroll-sync via WinScrolled → binary-search (canvas.locate) ✓; `<CR>` scrolls, never opens ✓; `<C-n>/<C-p>` canvas-local, focus stays ✓. Hunk-level sidebar highlighting (beyond file-level) deferred — file-level tracking is the §5 baseline; hunk granularity can ride Phase 6 polish.
- Keymap collision check: `<CR>` is the canvas jump key but the sidebar's `<CR>` is buffer-local to the sidebar buffer — no conflict. `q` closes the sidebar from the sidebar and the canvas from the canvas — consistent.
- Type consistency: `entries` shape shared by build/render/sync/select; `section_i` recomputed each refresh, and every consumer resolves rows live via `canvas.section_rows` at use time.
