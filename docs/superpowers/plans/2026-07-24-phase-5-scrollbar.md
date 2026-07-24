# Phase 5 — Scrollbar + Mouse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A built-in 1-column scrollbar/minimap floating at the canvas's right edge — thumb tracking the viewport, per-row marks showing file boundaries and add/del density — plus double-click-to-jump; native wheel scrolling already works and third-party scrollbars (satellite.nvim, nvim-scrollbar) remain compatible.

**Architecture:** `scrollbar.lua` mirrors sidebar.lua's proven shape: a pure half (`line_kinds(sections)` flattens sections to per-canvas-line kinds; `column(kinds, height, top0, bot0)` buckets them into per-row cells `{char, hl, thumb}`) and a window half (module singleton `bar = {buf, win, state}`; non-focusable `relative="win"` float, width 1, overlaying the canvas's rightmost column — the standard satellite.nvim placement; callbacks resolve `bar.state` at call time with liveness guards — the Phase 4 lessons). It hides itself whenever the canvas window stops showing the canvas buffer (jump excursion) and reappears on `BufWinEnter`. Mutating paths (refresh/reconcile/jump-back) call `scrollbar.update`.

**Tech Stack:** Lua, Neovim ≥0.10 (`nvim_open_win` float `relative="win"`, `line_hl_group` extmarks), bespoke headless runner.

## Global Constraints

- Neovim ≥0.10; no external runtime deps; `make test` (FILTER by test NAME).
- The scrollbar float is `focusable = false`, `style = "minimal"`, width 1, `zindex = 40`, anchored `relative = "win"` to the canvas window at its right edge (`col = win_width - 1`, `row = 0`, `height = win_height`). It must never steal focus, never receive keymaps, and never affect the canvas window's options or the niri invariant (it renders state; it never mutates the canvas).
- The float must be hidden (closed) whenever `state.win` is not showing `state.buf` (jump excursion, canvas hidden) and reappear on re-show — a leftover float over a real file buffer is a defect.
- Singleton + callback discipline from Phase 4: module-level `bar` holds `state`; autocmd callbacks resolve `bar.state` at call time; every window op is liveness-guarded; `close()` safe always; augroup `galley.scrollbar` cleared on re-open; `WinClosed` on the canvas window tears the bar down (scheduled). The bar window needs no WinClosed backstop — liveness guards recreate it on the next update; `close()` tears down.
- Pure half must not touch windows/buffers.
- Highlight groups (default=true links): `GalleyScrollFile` → `Title`, `GalleyScrollAdd` → `DiffAdd`, `GalleyScrollDel` → `DiffDelete`, `GalleyScrollChanged` → `DiffChange`, `GalleyScrollThumb` → `PmenuThumb`. Cell hl via `line_hl_group` extmarks in namespace `galley.scrollbar`; thumb overlays at higher priority (200 vs 100).
- Cell contract: file-boundary bucket → char `"─"` hl `GalleyScrollFile`; else adds+dels both present → `"│"` `GalleyScrollChanged`; only adds → `"│"` `GalleyScrollAdd`; only dels → `"│"` `GalleyScrollDel`; else `" "` with no hl. `cell.thumb = true` for rows whose bucket intersects the viewport `[top0, bot0]`.
- Bucket math: display row r (1-based, height H, total lines n) covers canvas lines `[floor((r-1)*n/H), floor(r*n/H))` (0-based, empty buckets possible when n < H — then the cell is blank and thumb mapping still works).
- `<2-LeftMouse>` is canvas-buffer-local and triggers the existing jump (mouse click moves the cursor before the mapping fires, so `jump.enter` picks up the clicked row).
- Config: `scrollbar = { enabled = true }`.
- Require graph: `scrollbar` → nothing internal (window half reads only the state table; no canvas require needed — kinds come from `state.sections` entries directly). init/watch/jump → scrollbar allowed.
- Commit per green cycle; trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Current suite 92/92 green and must stay green.

## File Structure

- `lua/galley/scrollbar.lua` — NEW: pure column model + float lifecycle.
- `lua/galley/config.lua` — MODIFY: `scrollbar` defaults.
- `lua/galley/init.lua` — MODIFY: open/close/refresh wiring + `<2-LeftMouse>` keymap.
- `lua/galley/watch.lua` — MODIFY: `scrollbar.update(state)` after reconcile mutations.
- `lua/galley/jump.lua` — MODIFY: `scrollbar.update(state)` after back.
- `tests/test_scrollbar.lua` — NEW.
- `README.md` — MODIFY.

---

### Task 1: Pure column model

**Files:**
- Create: `lua/galley/scrollbar.lua` (pure half)
- Test: `tests/test_scrollbar.lua`

**Interfaces:**
- Consumes: sections with `entries` (`kind ∈ {file_hdr, hunk_hdr, ctx, del, add}`), in render order (entry i of section s renders at one canvas line; sections concatenated).
- Produces:
  - `scrollbar.line_kinds(sections) -> kinds` — flat array, one element per canvas line, values `"hdr"` (file_hdr), `"add"`, `"del"`, `"ctx"` (ctx AND hunk_hdr).
  - `scrollbar.column(kinds, height, top0, bot0) -> cells` — array of exactly `height` cells `{char, hl (nil for blank), thumb (bool)}` per the Global Constraints contract. `height <= 0` or empty kinds ⇒ all-blank cells (still `height` of them, when height > 0, with thumb=false).

- [ ] **Step 1: Write the failing tests**

Create `tests/test_scrollbar.lua`:

```lua
local H = require("helpers")
local model = require("galley.model")
local scrollbar = require("galley.scrollbar")

local T = {}

T["scroll_kinds flattens sections in render order"] = function()
  -- one modified line, context 3: file_hdr, hunk_hdr, ctx, del, add, ctx, ctx, ctx
  local s = model.build_section("a.txt",
    "l1\nl2\nl3\nl4\nl5\n", "l1\nl2x\nl3\nl4\nl5\n", "M")
  local kinds = scrollbar.line_kinds({ s, s })
  H.eq(#kinds, 16)
  H.eq(vim.list_slice(kinds, 1, 8),
    { "hdr", "ctx", "ctx", "del", "add", "ctx", "ctx", "ctx" })
  H.eq(kinds[9], "hdr")
end

T["scroll_column buckets density and file boundaries"] = function()
  -- 40 lines, height 4: buckets of 10
  local kinds = {}
  for i = 1, 40 do kinds[i] = "ctx" end
  kinds[1] = "hdr"        -- bucket 1: file boundary wins
  kinds[15] = "add"       -- bucket 2: adds only
  kinds[25] = "del"       -- bucket 3: dels only
  kinds[35] = "add"
  kinds[36] = "del"       -- bucket 4: mixed
  local cells = scrollbar.column(kinds, 4, 100, 100) -- viewport far away: no thumb
  H.eq(#cells, 4)
  H.eq({ cells[1].char, cells[1].hl }, { "─", "GalleyScrollFile" })
  H.eq({ cells[2].char, cells[2].hl }, { "│", "GalleyScrollAdd" })
  H.eq({ cells[3].char, cells[3].hl }, { "│", "GalleyScrollDel" })
  H.eq({ cells[4].char, cells[4].hl }, { "│", "GalleyScrollChanged" })
  for r = 1, 4 do H.eq(cells[r].thumb, false) end
end

T["scroll_column blank buckets render empty"] = function()
  local kinds = {}
  for i = 1, 20 do kinds[i] = "ctx" end
  local cells = scrollbar.column(kinds, 2, 100, 100)
  H.eq(cells[1], { char = " ", hl = nil, thumb = false })
  H.eq(cells[2], { char = " ", hl = nil, thumb = false })
end

T["scroll_column thumb covers viewport-intersecting rows only"] = function()
  local kinds = {}
  for i = 1, 100 do kinds[i] = "ctx" end
  -- height 10: row r covers lines [(r-1)*10, r*10); viewport lines 35..54
  local cells = scrollbar.column(kinds, 10, 35, 54)
  local thumbs = {}
  for r = 1, 10 do thumbs[r] = cells[r].thumb end
  H.eq(thumbs, { false, false, false, true, true, true, false, false, false, false })
end

T["scroll_column degenerate inputs are safe"] = function()
  H.eq(scrollbar.column({}, 0, 0, 0), {})
  local cells = scrollbar.column({}, 3, 0, 10)
  H.eq(#cells, 3)
  for r = 1, 3 do
    H.eq(cells[r], { char = " ", hl = nil, thumb = false })
  end
  -- fewer lines than rows: line 1 lands in a well-defined bucket, no crash
  local one = scrollbar.column({ "add" }, 4, 0, 0)
  H.eq(#one, 4)
end

return T
```

**Check the thumb expectation before coding:** with n=100, H=10, row 4 covers [30,40), row 5 [40,50), row 6 [50,60); viewport [35,54] intersects exactly rows 4-6. Rows 1-3 cover [0,30), row 7 starts at 60 — no intersection. The expected `{f,f,f,t,t,t,f,f,f,f}` is right.

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test FILTER=scroll_`
Expected: FAIL — `module 'galley.scrollbar' not found`.

- [ ] **Step 3: Implement**

Create `lua/galley/scrollbar.lua`:

```lua
local S = {}

--- One kind per canvas line, sections in render order. hunk_hdr counts as
--- "ctx" (structural, uncolored); file_hdr becomes "hdr" (boundary rows).
function S.line_kinds(sections)
  local kinds = {}
  for _, section in ipairs(sections) do
    for _, e in ipairs(section.entries) do
      if e.kind == "file_hdr" then
        kinds[#kinds + 1] = "hdr"
      elseif e.kind == "add" or e.kind == "del" then
        kinds[#kinds + 1] = e.kind
      else
        kinds[#kinds + 1] = "ctx"
      end
    end
  end
  return kinds
end

--- Bucket per-line kinds into `height` display cells. Row r (1-based)
--- covers 0-based canvas lines [floor((r-1)*n/H), floor(r*n/H)).
--- cell = { char, hl (nil = blank), thumb } per the phase contract.
function S.column(kinds, height, top0, bot0)
  local cells = {}
  if height <= 0 then
    return cells
  end
  local n = #kinds

  for r = 1, height do
    local lo = math.floor((r - 1) * n / height)
    local hi = math.floor(r * n / height) -- exclusive

    local has_hdr, has_add, has_del = false, false, false
    for i = lo + 1, hi do
      local k = kinds[i]
      if k == "hdr" then
        has_hdr = true
      elseif k == "add" then
        has_add = true
      elseif k == "del" then
        has_del = true
      end
    end

    local char, hl = " ", nil
    if has_hdr then
      char, hl = "─", "GalleyScrollFile"
    elseif has_add and has_del then
      char, hl = "│", "GalleyScrollChanged"
    elseif has_add then
      char, hl = "│", "GalleyScrollAdd"
    elseif has_del then
      char, hl = "│", "GalleyScrollDel"
    end

    -- Thumb: this row's bucket intersects the viewport line range. For the
    -- degenerate n == 0 canvas every bucket is empty -> no thumb.
    local thumb = n > 0 and lo <= bot0 and hi > top0

    cells[r] = { char = char, hl = hl, thumb = thumb }
  end

  return cells
end

return S
```

**Check the blank-bucket thumb edge:** when n < H some buckets are empty (`lo == hi`); `hi > top0` is then false whenever `lo <= top0`, so empty buckets never claim the thumb — matches the "no crash, well-defined" test.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test FILTER=scroll_` then `make test` (97/97 expected).

- [ ] **Step 5: Commit**

```bash
git add lua/galley/scrollbar.lua tests/test_scrollbar.lua
git commit -m "feat: scrollbar column model (pure)"
```

---

### Task 2: Float lifecycle + wiring + mouse

**Files:**
- Modify: `lua/galley/scrollbar.lua` (window half)
- Modify: `lua/galley/config.lua`, `lua/galley/init.lua`, `lua/galley/watch.lua`, `lua/galley/jump.lua`
- Modify: `README.md`
- Test: `tests/test_scrollbar.lua` (window cases appended)

**Interfaces:**
- Consumes: Task 1's pure half; canvas state `{buf, win, sections}`.
- Produces (module singleton `bar = {buf, win, state}`):
  - `scrollbar.open(state, opts)` — creates the scratch buffer (`nofile`/`hide`/noswap) + float per Global Constraints, installs autocmds (augroup `galley.scrollbar`, cleared): `WinScrolled` (canvas win → update), `WinResized` (update), `BufWinEnter` on the canvas buffer (re-show + update), `WinClosed` on the canvas window (scheduled `close`). Idempotent (open-while-open rebinds `bar.state` + autocmds, updates). No-op when `state.win` invalid.
  - `scrollbar.close()` — closes the float, clears singleton + augroup; safe always.
  - `scrollbar.is_open() -> bool` — float window valid.
  - `scrollbar.update(state)` — nil-safe no-op when the bar was never opened. When the canvas window isn't showing the canvas buffer: hide the float (close the window, KEEP the singleton so `BufWinEnter` can re-show). When showing: ensure the float exists (recreate if hidden), reposition/resize to the canvas window, render `column(line_kinds(state.sections), height, top0, bot0)` — chars as buffer lines, hl via `line_hl_group` extmarks (priority 100), thumb rows an additional `GalleyScrollThumb` mark (priority 200).
  - init: `<2-LeftMouse>` canvas-buffer-local → same handler as the jump key; `scrollbar.open` when `config.options.scrollbar.enabled`; `scrollbar.close()` in `M.close`; `scrollbar.update(state)` in `M.refresh`.
  - watch: `scrollbar.update(state)` after each of the three `sidebar.refresh(state)` sites. jump: `scrollbar.update(state)` after back's `sidebar.refresh(state)`.
  - config: `defaults.scrollbar = { enabled = true }`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_scrollbar.lua` (add `local canvas = require("galley.canvas")` at top):

```lua
local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

local function big_section(path, tag)
  local old = bigtext(60, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 10, 60, 10 do lines[i] = lines[i] .. " changed" end
  return model.build_section(path, old, table.concat(lines, "\n"), "M")
end

local function open_with_bar()
  local st = canvas.open({ big_section("a.txt", "a"), big_section("b.txt", "b") }, {})
  scrollbar.close()
  scrollbar.open(st, {})
  return st
end

local function bar_win(st)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative == "win" and cfg.width == 1 then
      return w
    end
  end
end

local SCROLL_NS = vim.api.nvim_create_namespace("galley.scrollbar")

local function thumb_rows(bbuf)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bbuf, SCROLL_NS, 0, -1, { details = true })) do
    if m[4] and m[4].line_hl_group == "GalleyScrollThumb" then
      rows[#rows + 1] = m[2]
    end
  end
  return rows
end

T["scroll_win opens a 1-col non-focusable float on the canvas"] = function()
  local st = open_with_bar()
  assert(scrollbar.is_open())
  local w = bar_win(st)
  assert(w, "float exists")
  local cfg = vim.api.nvim_win_get_config(w)
  H.eq(cfg.relative, "win")
  H.eq(cfg.width, 1)
  H.eq(cfg.focusable, false)
  H.eq(vim.api.nvim_win_get_height(w), vim.api.nvim_win_get_height(st.win))
  H.eq(vim.api.nvim_get_current_win(), st.win, "focus stays in canvas")
  scrollbar.close()
  H.eq(scrollbar.is_open(), false)
end

T["scroll_win thumb tracks the viewport"] = function()
  local st = open_with_bar()
  local w = bar_win(st)
  local bbuf = vim.api.nvim_win_get_buf(w)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  scrollbar.update(st)
  local top_thumbs = thumb_rows(bbuf)
  assert(#top_thumbs > 0, "thumb present")
  H.eq(top_thumbs[1], 0, "thumb starts at the top row when scrolled to top")

  vim.api.nvim_win_call(st.win, function() vim.cmd("normal! G") end)
  scrollbar.update(st)
  local bot_thumbs = thumb_rows(bbuf)
  assert(#bot_thumbs > 0)
  local h = vim.api.nvim_win_get_height(w)
  H.eq(bot_thumbs[#bot_thumbs], h - 1, "thumb ends at the bottom row when scrolled to bottom")
  assert(bot_thumbs[1] > top_thumbs[1], "thumb moved down")
  scrollbar.close()
end

T["scroll_win hides during an excursion and re-shows after"] = function()
  local st = open_with_bar()
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(st.win, scratch) -- simulate jump.enter
  scrollbar.update(st)
  H.eq(scrollbar.is_open(), false, "float hidden while canvas not showing")

  vim.api.nvim_win_set_buf(st.win, st.buf) -- BufWinEnter fires
  vim.wait(200, function() return scrollbar.is_open() end, 10)
  H.eq(scrollbar.is_open(), true, "float re-shown on canvas re-show")
  scrollbar.close()
end

T["scroll_win canvas WinClosed tears the bar down"] = function()
  local st = open_with_bar()
  vim.cmd("vsplit") -- ensure the canvas window isn't the last one
  local cur = vim.api.nvim_get_current_win()
  if cur == st.win then
    -- vsplit focused the new window in most configs; make sure we don't
    -- close the wrong one
    cur = nil
  end
  vim.api.nvim_win_close(st.win, true)
  vim.wait(300, function() return not scrollbar.is_open() end, 10)
  H.eq(scrollbar.is_open(), false, "bar cleaned up after canvas window closed")
end

T["scroll_win file boundary rows are drawn"] = function()
  local st = open_with_bar()
  local w = bar_win(st)
  local bbuf = vim.api.nvim_win_get_buf(w)
  local lines = vim.api.nvim_buf_get_lines(bbuf, 0, -1, false)
  local dashes = 0
  for _, l in ipairs(lines) do
    if l == "─" then dashes = dashes + 1 end
  end
  H.eq(dashes, 2, "two file-boundary rows for two sections")
  scrollbar.close()
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test FILTER=scroll_win`
Expected: FAIL — `attempt to call field 'open' (a nil value)` (close/open missing).

- [ ] **Step 3: Implement the window half**

Append to `lua/galley/scrollbar.lua` (before `return S`):

```lua
local NS = vim.api.nvim_create_namespace("galley.scrollbar")

-- Module singleton (Phase 4 discipline): callbacks resolve bar.state at
-- call time; every window op liveness-guarded; close() safe always.
local bar = nil

local function ensure_hl_groups()
  vim.api.nvim_set_hl(0, "GalleyScrollFile", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "GalleyScrollAdd", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "GalleyScrollDel", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "GalleyScrollChanged", { link = "DiffChange", default = true })
  vim.api.nvim_set_hl(0, "GalleyScrollThumb", { link = "PmenuThumb", default = true })
end

function S.is_open()
  return bar ~= nil and bar.win ~= nil and vim.api.nvim_win_is_valid(bar.win)
end

local function canvas_showing(state)
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

local function float_config(state)
  return {
    relative = "win",
    win = state.win,
    row = 0,
    col = vim.api.nvim_win_get_width(state.win) - 1,
    width = 1,
    height = vim.api.nvim_win_get_height(state.win),
    focusable = false,
    style = "minimal",
    zindex = 40,
  }
end

local function hide()
  if bar and bar.win and vim.api.nvim_win_is_valid(bar.win) then
    pcall(vim.api.nvim_win_close, bar.win, true)
  end
  if bar then
    bar.win = nil
  end
end

--- Redraw (and re-show/reposition if needed) the bar for the live canvas.
--- Never opened yet or canvas hidden => hide/no-op; the singleton survives
--- hiding so BufWinEnter can re-show it.
function S.update(state)
  if not bar then
    return
  end
  state = state or bar.state
  if not canvas_showing(state) then
    hide()
    return
  end

  if not (bar.buf and vim.api.nvim_buf_is_valid(bar.buf)) then
    bar.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = bar.buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bar.buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = bar.buf })
  end
  if not (bar.win and vim.api.nvim_win_is_valid(bar.win)) then
    bar.win = vim.api.nvim_open_win(bar.buf, false, float_config(state))
  else
    vim.api.nvim_win_set_config(bar.win, float_config(state))
  end

  local info = vim.api.nvim_win_call(state.win, function()
    return { top0 = vim.fn.line("w0") - 1, bot0 = vim.fn.line("w$") - 1 }
  end)
  local height = vim.api.nvim_win_get_height(state.win)
  local cells = S.column(S.line_kinds(state.sections), height, info.top0, info.bot0)

  local lines = {}
  for r = 1, #cells do
    lines[r] = cells[r].char
  end
  vim.api.nvim_buf_set_lines(bar.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bar.buf, NS, 0, -1)
  for r, cell in ipairs(cells) do
    if cell.hl then
      vim.api.nvim_buf_set_extmark(bar.buf, NS, r - 1, 0, {
        line_hl_group = cell.hl,
        priority = 100,
      })
    end
    if cell.thumb then
      vim.api.nvim_buf_set_extmark(bar.buf, NS, r - 1, 0, {
        line_hl_group = "GalleyScrollThumb",
        priority = 200,
      })
    end
  end
end

function S.close()
  if bar then
    local b = bar
    bar = nil
    pcall(vim.api.nvim_del_augroup_by_name, "galley.scrollbar")
    if b.win and vim.api.nvim_win_is_valid(b.win) then
      pcall(vim.api.nvim_win_close, b.win, true)
    end
    if b.buf and vim.api.nvim_buf_is_valid(b.buf) then
      pcall(vim.api.nvim_buf_delete, b.buf, { force = true })
    end
  end
end

local function install_autocmds(state)
  local aug = vim.api.nvim_create_augroup("galley.scrollbar", { clear = true })
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
    group = aug,
    callback = function(ev)
      local b = bar
      if not b then
        return
      end
      local w = tonumber(ev.match)
      if ev.event == "WinResized" or w == b.state.win then
        S.update(b.state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = aug,
    buffer = state.buf,
    callback = function()
      local b = bar
      if b then
        b.state.win = vim.api.nvim_get_current_win()
        S.update(b.state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    pattern = tostring(state.win),
    callback = function()
      vim.schedule(S.close)
    end,
  })
end

--- Open (or rebind) the scrollbar for the live canvas state.
function S.open(state, opts)
  opts = opts or {}
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  ensure_hl_groups()
  if bar then
    bar.state = state
    install_autocmds(state)
    S.update(state)
    return
  end
  bar = { buf = nil, win = nil, state = state }
  install_autocmds(state)
  S.update(state)
end
```

**Note on BufWinEnter mutating `state.win`:** this mirrors hl.lua's approved BufWinEnter pattern (a window that just started showing the canvas IS the canvas window now). Since hl and scrollbar both do it, the assignments agree.

- [ ] **Step 4: Wire config / init / watch / jump / README**

`config.lua` — add to `M.defaults`: `scrollbar = { enabled = true }`.

`init.lua` — add `local scrollbar = require("galley.scrollbar")`; in `set_canvas_keymaps` add:

```lua
  vim.keymap.set("n", "<2-LeftMouse>", function()
    jump.enter(st, { back_key = cfg.keymaps.back })
  end, map_opts)
```

in `M.open`, after the sidebar block:

```lua
  if config.options.scrollbar.enabled then
    scrollbar.open(st, config.options.scrollbar)
  end
```

in `M.close`, next to `sidebar.close()`: `scrollbar.close()`. In `M.refresh`, after `sidebar.refresh(state)`: `scrollbar.update(state)`.

`watch.lua` — add `local scrollbar = require("galley.scrollbar")`; add `scrollbar.update(state)` after each of the three `sidebar.refresh(state)` sites.

`jump.lua` — add `local scrollbar = require("galley.scrollbar")`; in `M.back`, after `sidebar.refresh(state)`: `scrollbar.update(state)`.

`README.md` — document the scrollbar/minimap (file boundaries + add/del density + viewport thumb; disable with `scrollbar = { enabled = false }` for satellite.nvim/nvim-scrollbar users — both work fine on the canvas window), and double-click-to-jump.

- [ ] **Step 5: Run tests, full suite twice**

Run: `make test FILTER=scroll_` then `make test` twice (102/102 both runs, zero warnings).

- [ ] **Step 6: Commit**

```bash
git add lua/galley/ tests/test_scrollbar.lua README.md
git commit -m "feat: scrollbar minimap float and double-click jump"
```

---

## Self-Review Notes

- Concept plan §6 coverage: wheel native ✓ (nothing to do); `<2-LeftMouse>` jump ✓; 1-col non-focusable win-relative float ✓; thumb from topline/total ✓; per-row file-boundary + density marks (minimap) ✓; satellite/nvim-scrollbar compatibility ✓ (ours is additive + disable-able; canvas window untouched). Click-drag on the bar explicitly deferred by the concept plan ("later").
- The float overlays the canvas's rightmost text column — standard scrollbar placement (satellite.nvim does the same); the canvas has `nowrap` so no reflow, and the niri invariant is untouched (the bar never mutates canvas content or view).
- Type consistency: `cells` shape shared between `column` (producer) and `update` (consumer); `line_kinds` consumes the same entry kinds render.lua does.
