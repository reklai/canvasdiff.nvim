# Keybind Cheatsheet Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A centered floating window, toggled with `<leader>lh` from the canvas or sidebar, listing every keybind the plugin installs in three columns — `Global | Sidebar | Canvas` — always rendered from the user's resolved config.

**Architecture:** New `lua/canvasdiff/ui/cheatsheet.lua` owns a pure column model built from `input.keys` data, a pure line renderer, and the float lifecycle. It introduces no new source of keybind truth: `K.specs` gains a `help` action, `config` gains the `<leader>lh` defaults, and the existing `K.resolved`-driven install paths in `App.lua` / `sidebar.lua` gain a `help` handler. Spec: `docs/superpowers/specs/2026-07-28-cheatsheet-overlay-design.md`.

**Tech Stack:** Lua, Neovim floating windows / extmarks, the repo's own headless test runner (`make test`).

## Global Constraints

- Cross-domain requires must target the domain facade (`require("canvasdiff.input").keys`, `require("canvasdiff.config")`); ui-internal modules import each other directly (`require("canvasdiff.ui.cheatsheet")` from `sidebar.lua`). Enforced by `test/architecture`.
- The overlay renders from the resolved `config.keymaps` at open time — never from shipped defaults. Overrides replace lists; `false` / `{}` / `""` disables; disabled actions are omitted (spec R2).
- No binding on the jump-excursion file buffer (spec R1). No pagination/search inside the overlay (spec: out of scope).
- The overlay never survives the canvas: `App:close()` closes it (`App:toggle` closes through `App:close`, so one hook covers both).
- Tests must not rely on autocmd events firing headless; call module functions or stored keymap callbacks directly (see `reference-headless-test-constraints`).
- Test names are Lua-pattern-filterable: prefix cheatsheet tests `cheatsheet_`.
- Run a suite with `make test SUITE=unit FILTER='^cheatsheet_'` etc. Full suite: `make test` (all 138 existing tests must stay green).

---

### Task 1: Column model (pure) + ui facade export

**Files:**
- Create: `lua/canvasdiff/ui/cheatsheet.lua`
- Modify: `lua/canvasdiff/ui.lua` (add facade export)
- Test: `test/unit/test_cheatsheet.lua`

**Interfaces:**
- Consumes: `require("canvasdiff.input").keys` — `keys.grouped(ctxs, keymaps)` returns `{ name, items = { { keys, desc, action } } }[]` in `K.group_order`; `keys.resolved(ctx, keymaps)` returns `{ action, lhs, desc, group }[]`.
- Produces: `M.model(keymaps)` → `{ title: string, sections: { name: string|nil, rows: { keys: string[], desc: string, action: string }[] }[] }[]` — a list of up to three columns titled `"Global"`, `"Sidebar"`, `"Canvas"`, in that order, empty columns omitted. Task 2 renders exactly this shape.

- [ ] **Step 1: Write the failing tests**

`test/unit/test_cheatsheet.lua`:

```lua
local H = require("helpers")
local cheatsheet = require("canvasdiff.ui").cheatsheet
local config = require("canvasdiff.config")

local T = {}

local function defaults()
  return vim.deepcopy(config.defaults.keymaps)
end

--- { action = column_title } for every row in the model.
local function placement(model)
  local out = {}
  for _, col in ipairs(model) do
    for _, sec in ipairs(col.sections) do
      for _, row in ipairs(sec.rows) do
        out[row.action] = col.title
      end
    end
  end
  return out
end

T["cheatsheet_model puts identically-bound shared actions in Global"] = function()
  local model = cheatsheet.model(defaults())
  local where = placement(model)
  -- `close` is `q` on both canvas and sidebar; `back` is global by fiat.
  H.eq(where.close, "Global")
  H.eq(where.back, "Global")
  H.eq(where.select, "Sidebar")
  H.eq(where.jump, "Canvas")
  H.eq(where.refresh, "Canvas")
end

T["cheatsheet_model splits a diverged shared action into both context columns"] = function()
  local km = defaults()
  km.sidebar.close = "x" -- no longer identical to canvas `q`
  local model = cheatsheet.model(km)
  local seen = {}
  for _, col in ipairs(model) do
    for _, sec in ipairs(col.sections) do
      for _, row in ipairs(sec.rows) do
        if row.action == "close" then
          seen[col.title] = row.keys
        end
      end
    end
  end
  H.eq(seen["Global"], nil, "a diverged action must leave Global")
  H.eq(seen["Canvas"], { "q" })
  H.eq(seen["Sidebar"], { "x" })
end

T["cheatsheet_model column order is Global, Sidebar, Canvas"] = function()
  local titles = {}
  for _, col in ipairs(cheatsheet.model(defaults())) do
    titles[#titles + 1] = col.title
  end
  H.eq(titles, { "Global", "Sidebar", "Canvas" })
end

T["cheatsheet_model keeps group sub-headers only in the Canvas column"] = function()
  local model = cheatsheet.model(defaults())
  for _, col in ipairs(model) do
    if col.title == "Canvas" then
      local names = {}
      for _, sec in ipairs(col.sections) do names[#names + 1] = sec.name end
      -- Subset of K.group_order, in order; Navigate must be present.
      H.eq(names[1], "Navigate")
      for _, n in ipairs(names) do
        assert(type(n) == "string" and n ~= "", "canvas sections carry group names")
      end
    else
      H.eq(#col.sections, 1, col.title .. " is a flat list")
      H.eq(col.sections[1].name, nil, col.title .. " has no sub-header")
    end
  end
end

T["cheatsheet_model omits disabled actions and empty columns"] = function()
  local km = defaults()
  km.sidebar.select = false
  km.sidebar.close = "x" -- diverge close so Sidebar's only row would be select
  km.canvas.close = "x"  -- keep them diverged both ways
  local model = cheatsheet.model(km)
  local where = placement(model)
  H.eq(where.select, nil, "a disabled action must not appear at all")
  -- Sidebar now has close only (diverged): still present. Disable that too:
  km.sidebar.close = false
  where = placement(cheatsheet.model(km))
  for _, col in ipairs(cheatsheet.model(km)) do
    assert(col.title ~= "Sidebar", "a column with no rows is omitted")
  end
end

T["cheatsheet_model reflects overridden keys, not defaults"] = function()
  local km = defaults()
  km.canvas.refresh = "R"
  local model = cheatsheet.model(km)
  for _, col in ipairs(model) do
    for _, sec in ipairs(col.sections) do
      for _, row in ipairs(sec.rows) do
        if row.action == "refresh" then
          H.eq(row.keys, { "R" }, "the override replaces the default list")
          return
        end
      end
    end
  end
  error("refresh must be in the model")
end

return T
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test SUITE=unit FILTER='^cheatsheet_'`
Expected: FAIL — `canvasdiff.ui` has no `cheatsheet` field (attempt to index nil / attempt to call nil).

- [ ] **Step 3: Implement the model**

`lua/canvasdiff/ui/cheatsheet.lua`:

```lua
-- Centered floating cheatsheet listing every keybind the plugin installs.
--
-- A renderer over input.keys + config.keymaps -- this module introduces no
-- new source of keybind truth, so whatever the user overrode, disabled, or
-- multi-bound is exactly what appears. The column model is pure and separate
-- from rendering, so tests can assert placement without a UI.

local keys = require("canvasdiff.input").keys

local M = {}

--- Per-context view of grouped(): action -> row, plus display order.
local function ctx_actions(ctx, keymaps)
  local by_action, order = {}, {}
  for _, g in ipairs(keys.grouped({ ctx }, keymaps)) do
    for _, item in ipairs(g.items) do
      by_action[item.action] = { keys = item.keys, desc = item.desc, group = g.name }
      order[#order + 1] = item.action
    end
  end
  return by_action, order
end

--- One flat unnamed section, or nothing when there are no rows.
local function flat_column(title, rows)
  if #rows == 0 then
    return nil
  end
  return { title = title, sections = { { name = nil, rows = rows } } }
end

--- Canvas keeps its group sub-headers (it is the largest column); order of
--- appearance already follows K.group_order via grouped().
local function grouped_column(title, by_action, order, skip)
  local sections, index = {}, {}
  for _, action in ipairs(order) do
    if not skip[action] then
      local a = by_action[action]
      local sec = index[a.group]
      if not sec then
        sec = { name = a.group, rows = {} }
        index[a.group] = sec
        sections[#sections + 1] = sec
      end
      sec.rows[#sec.rows + 1] = { keys = a.keys, desc = a.desc, action = action }
    end
  end
  if #sections == 0 then
    return nil
  end
  return { title = title, sections = sections }
end

--- Column model for the overlay: `Global | Sidebar | Canvas`.
---
--- Global holds actions available in more than one context with identical
--- keys -- computed, not hardcoded, so a user who diverges e.g. the sidebar
--- close key sees it split honestly into the per-context columns. The
--- file-context `back` binding is global by fiat: it applies outside the
--- plugin's own windows. Empty columns are omitted.
function M.model(keymaps)
  local canvas, canvas_order = ctx_actions("canvas", keymaps)
  local side, side_order = ctx_actions("sidebar", keymaps)
  local file, file_order = ctx_actions("file", keymaps)

  local shared, global_rows = {}, {}
  for _, action in ipairs(canvas_order) do
    local c, s = canvas[action], side[action]
    if s and vim.deep_equal(c.keys, s.keys) then
      shared[action] = true
      global_rows[#global_rows + 1] = { keys = c.keys, desc = c.desc, action = action }
    end
  end
  for _, action in ipairs(file_order) do
    local f = file[action]
    global_rows[#global_rows + 1] = { keys = f.keys, desc = f.desc, action = action }
  end

  local side_rows = {}
  for _, action in ipairs(side_order) do
    if not shared[action] then
      local s = side[action]
      side_rows[#side_rows + 1] = { keys = s.keys, desc = s.desc, action = action }
    end
  end

  local out = {}
  out[#out + 1] = flat_column("Global", global_rows)
  out[#out + 1] = flat_column("Sidebar", side_rows)
  out[#out + 1] = grouped_column("Canvas", canvas, canvas_order, shared)
  return out
end

return M
```

Note: `out[#out + 1] = nil` is a no-op in Lua, which is exactly what "empty columns are omitted" needs — no branching.

In `lua/canvasdiff/ui.lua`, add the require alphabetically and the export:

```lua
local cheatsheet = require("canvasdiff.ui.cheatsheet")
```

and in the returned table (alphabetical, after `err`):

```lua
  cheatsheet = cheatsheet,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test SUITE=unit FILTER='^cheatsheet_'`
Expected: PASS (6 tests). Also run `make test SUITE=architecture` — the new module and facade export must satisfy the dependency rules, and `test_ui.lua` may enumerate the facade: run `make test SUITE=unit FILTER='^ui_'` and, if a facade-shape assertion fails, add `cheatsheet` to its expected export list.

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/ui/cheatsheet.lua lua/canvasdiff/ui.lua test/unit/test_cheatsheet.lua
git commit -m "feat(ui): cheatsheet column model over the keys registry"
```

---

### Task 2: Line renderer + float lifecycle

**Files:**
- Modify: `lua/canvasdiff/ui/cheatsheet.lua`
- Test: `test/unit/test_cheatsheet.lua` (renderer), `test/integration/test_cheatsheet.lua` (float lifecycle)

**Interfaces:**
- Consumes: `M.model(keymaps)` from Task 1; `require("canvasdiff.config").options.keymaps`.
- Produces:
  - `M.lines(model, max_width)` → `lines: string[]`, `spans: { line: integer (0-based), col_start: integer, col_end: integer, group: string }[]`, `width: integer` — pure.
  - `M.toggle()` — open the float over the editor, or close it if open.
  - `M.close()` — close if open; safe to call anytime.
  - `M.is_open()` → boolean.

- [ ] **Step 1: Write the failing renderer tests** (append to `test/unit/test_cheatsheet.lua`)

```lua
T["cheatsheet_lines lays columns side by side when width allows"] = function()
  local model = cheatsheet.model(defaults())
  local lines, spans, width = cheatsheet.lines(model, 200)
  assert(width <= 200)
  H.eq(lines[1]:match("Global") ~= nil, true, "first line carries the first column title")
  H.eq(lines[1]:match("Sidebar") ~= nil, true, "titles share the line when side by side")
  H.eq(lines[1]:match("Canvas") ~= nil, true)
  assert(#spans > 0, "titles and keys carry highlight spans")
  for _, s in ipairs(spans) do
    assert(lines[s.line + 1] ~= nil and s.col_end <= #lines[s.line + 1],
      "span must lie inside its line")
  end
end

T["cheatsheet_lines stacks columns on a narrow editor"] = function()
  local model = cheatsheet.model(defaults())
  local lines = cheatsheet.lines(model, 40)
  -- Stacking changes the layout, not the longest desc: width may still
  -- exceed 40 (toggle clamps the WINDOW; long lines scroll off, spec R5).
  H.eq(lines[1]:match("Sidebar"), nil, "titles no longer share a line")
  local joined = table.concat(lines, "\n")
  assert(joined:find("Global") and joined:find("Sidebar") and joined:find("Canvas"),
    "all columns still present, vertically")
end

T["cheatsheet_lines one row per action with keys joined by spaces"] = function()
  local model = cheatsheet.model(defaults())
  local joined = table.concat((cheatsheet.lines(model, 200)), "\n")
  assert(joined:find("za c", 1, true), "multi-key collapse renders on one row")
  assert(joined:find("Re-scan", 1, true), "descs render next to their keys")
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test SUITE=unit FILTER='^cheatsheet_lines'`
Expected: FAIL — `cheatsheet.lines` is nil.

- [ ] **Step 3: Implement the renderer and lifecycle**

Append to `lua/canvasdiff/ui/cheatsheet.lua` (before `return M`; add `local config = require("canvasdiff.config")` to the requires at the top):

```lua
local GUTTER = 3 -- spaces between columns
local KEY_DESC_GAP = 2

--- One column as its own block of lines plus block-relative highlight spans.
local function column_block(col)
  local lines = { col.title }
  local spans = { { line = 0, col_start = 0, col_end = #col.title, group = "Title" } }
  local key_width = 0
  for _, sec in ipairs(col.sections) do
    for _, row in ipairs(sec.rows) do
      key_width = math.max(key_width, #table.concat(row.keys, " "))
    end
  end
  for _, sec in ipairs(col.sections) do
    if sec.name then
      lines[#lines + 1] = ""
      lines[#lines + 1] = sec.name
      spans[#spans + 1] = { line = #lines - 1, col_start = 0, col_end = #sec.name, group = "Comment" }
    end
    for _, row in ipairs(sec.rows) do
      local ks = table.concat(row.keys, " ")
      lines[#lines + 1] = ks .. string.rep(" ", key_width - #ks + KEY_DESC_GAP) .. row.desc
      spans[#spans + 1] = { line = #lines - 1, col_start = 0, col_end = #ks, group = "Special" }
    end
  end
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  return { lines = lines, spans = spans, width = width }
end

--- Pure renderer over a model: lines, 0-based highlight spans, and the
--- resulting width. Columns sit side by side when they fit inside
--- `max_width`, otherwise they stack vertically in the same order (spec R5).
function M.lines(model, max_width)
  local blocks = {}
  local total = 0
  for i, col in ipairs(model) do
    blocks[i] = column_block(col)
    total = total + blocks[i].width + (i > 1 and GUTTER or 0)
  end

  local lines, spans = {}, {}
  if total <= max_width and #blocks > 1 then
    local height = 0
    for _, b in ipairs(blocks) do
      height = math.max(height, #b.lines)
    end
    local offset = 0
    for _, b in ipairs(blocks) do
      for li = 1, height do
        local prefix = lines[li] or ""
        -- Pad the merged line up to this block's start column.
        prefix = prefix .. string.rep(" ", offset - #prefix)
        lines[li] = prefix .. (b.lines[li] or "")
      end
      for _, s in ipairs(b.spans) do
        spans[#spans + 1] = {
          line = s.line, col_start = s.col_start + offset,
          col_end = s.col_end + offset, group = s.group,
        }
      end
      offset = offset + b.width + GUTTER
    end
  else
    for _, b in ipairs(blocks) do
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      local base = #lines
      for _, l in ipairs(b.lines) do
        lines[#lines + 1] = l
      end
      for _, s in ipairs(b.spans) do
        spans[#spans + 1] = {
          line = s.line + base, col_start = s.col_start,
          col_end = s.col_end, group = s.group,
        }
      end
    end
  end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  return lines, spans, width
end

-- --- float lifecycle ---------------------------------------------------

local ns = vim.api.nvim_create_namespace("canvasdiff_cheatsheet")

-- Singleton, like the canvas itself: two cheatsheets answer no question.
-- Validity is checked lazily so an externally-closed float (":q", tab
-- teardown) needs no autocmd bookkeeping -- events are also unreliable in
-- headless tests.
local state = { win = nil, buf = nil }

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win, state.buf = nil, nil
end

--- Every configured help key, from every context, plus the overlay's own
--- closers. All of them close the open overlay, so the key that summoned it
--- always dismisses it (spec R4).
local function close_keys(keymaps)
  local out, seen = { "q", "<Esc>" }, { q = true, ["<Esc>"] = true }
  for _, ctx in ipairs({ "canvas", "sidebar" }) do
    for _, m in ipairs(keys.resolved(ctx, keymaps)) do
      if m.action == "help" and not seen[m.lhs] then
        seen[m.lhs] = true
        out[#out + 1] = m.lhs
      end
    end
  end
  return out
end

function M.toggle()
  if M.is_open() then
    M.close()
    return
  end
  local km = config.options.keymaps
  local model = M.model(km)
  local max_width = math.max(20, vim.o.columns - 8)
  local lines, spans, width = M.lines(model, max_width)
  width = math.min(math.max(width, 1), max_width)
  local height = math.min(#lines, math.max(3, vim.o.lines - 6))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, s in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, ns, s.line, s.col_start, {
      end_col = s.col_end, hl_group = s.group,
    })
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " canvasdiff ",
    title_pos = "center",
  })

  for _, lhs in ipairs(close_keys(km)) do
    vim.keymap.set("n", lhs, M.close,
      { buffer = buf, silent = true, noremap = true, desc = "Close the cheatsheet" })
  end

  state.win, state.buf = win, buf
end
```

- [ ] **Step 4: Write the failing lifecycle test**

`test/integration/test_cheatsheet.lua`:

```lua
local H = require("helpers")
local cheatsheet = require("canvasdiff.ui").cheatsheet

local T = {}

T["cheatsheet_toggle opens a centered float and toggle closes it again"] = function()
  H.eq(cheatsheet.is_open(), false)
  cheatsheet.toggle()
  H.eq(cheatsheet.is_open(), true)
  local win = vim.api.nvim_get_current_win()
  local cfg = vim.api.nvim_win_get_config(win)
  H.eq(cfg.relative, "editor", "the overlay floats over the editor")
  local buf = vim.api.nvim_win_get_buf(win)
  local joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(joined:find("Canvas"), "overlay shows the Canvas column")
  assert(joined:find("q", 1, true), "overlay lists the close key")

  cheatsheet.toggle()
  H.eq(cheatsheet.is_open(), false)
  H.eq(vim.api.nvim_win_is_valid(win), false, "toggle closes the float window")
end

T["cheatsheet_q on the overlay closes it"] = function()
  cheatsheet.toggle()
  H.eq(cheatsheet.is_open(), true)
  local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == "q" then
      m.callback()
      H.eq(cheatsheet.is_open(), false)
      return
    end
  end
  error("the overlay must bind q")
end

T["cheatsheet_close is safe when nothing is open"] = function()
  cheatsheet.close()
  cheatsheet.close()
  H.eq(cheatsheet.is_open(), false)
end

return T
```

- [ ] **Step 5: Run both suites**

Run: `make test SUITE=unit FILTER='^cheatsheet_'` then `make test SUITE=integration FILTER='^cheatsheet_'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lua/canvasdiff/ui/cheatsheet.lua test/unit/test_cheatsheet.lua test/integration/test_cheatsheet.lua
git commit -m "feat(ui): cheatsheet renderer and floating-window lifecycle"
```

---

### Task 3: The `help` action end to end

**Files:**
- Modify: `lua/canvasdiff/input/keys.lua` (two spec entries)
- Modify: `lua/canvasdiff/config/settings.lua` (defaults)
- Modify: `lua/canvasdiff/App.lua` (canvas handler + close hook)
- Modify: `lua/canvasdiff/ui/sidebar.lua` (sidebar handler)
- Modify: `test/helpers.lua` (`H.norm_lhs` leader expansion)
- Modify: `doc/canvasdiff.txt` (mappings section + config sample), `README.md` (keymaps sample)
- Test: `test/unit/test_keys.lua`, `test/integration/test_cheatsheet.lua`

**Interfaces:**
- Consumes: `M.toggle()` / `M.close()` from Task 2, reached as `ui.cheatsheet` in `App.lua` (the `ui` facade is already imported there) and as `require("canvasdiff.ui.cheatsheet")` in `sidebar.lua` (ui-internal direct import, like `notifications`).
- Produces: the `help` action — `K.specs` entries for canvas and sidebar (group `"Canvas"` / `"Sidebar"`, desc `"Show keybind cheatsheet"`), defaults `help = "<leader>lh"` in both context sub-tables.

- [ ] **Step 1: Write the failing tests**

Append to `test/unit/test_keys.lua`:

```lua
T["keys_help resolves in both contexts and stays collision-free"] = function()
  H.eq(find(keys.resolved("canvas", defaults()), "help"), { "<leader>lh" })
  H.eq(find(keys.resolved("sidebar", defaults()), "help"), { "<leader>lh" })
  for _, ctx in ipairs({ "canvas", "sidebar", "file" }) do
    H.eq(keys.collisions(ctx, defaults()), {}, "help must not contest a key in " .. ctx)
  end
end
```

Append to `test/integration/test_cheatsheet.lua`:

```lua
T["cheatsheet_help key is installed on the canvas and closing the canvas closes the overlay"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a1\n" },
    worktree = { ["a.txt"] = "A1\n" },
  })
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.open()
  local buf = vim.api.nvim_get_current_buf()

  local help
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == H.norm_lhs("<leader>lh") then help = m end
  end
  assert(help, "<leader>lh must be installed on the canvas buffer")
  help.callback()
  H.eq(cheatsheet.is_open(), true, "the help key opens the overlay")

  fm.close()
  H.eq(cheatsheet.is_open(), false, "closing the canvas closes the overlay (spec R4)")
  vim.api.nvim_set_current_dir(old_cwd)
end

T["cheatsheet_overlay reflects an overridden help key and closes on it"] = function()
  local fm = require("canvasdiff")
  fm.setup({ keymaps = { canvas = { help = "g?" }, sidebar = { help = "g?" } } })
  cheatsheet.toggle()
  local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
  local joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(joined:find("g?", 1, true), "the overlay lists the user's key, not the default")
  assert(not joined:find("<leader>lh", 1, true), "the replaced default is gone")

  local closed
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == "g?" then
      m.callback()
      closed = true
    end
  end
  assert(closed, "the overridden help key must close the open overlay")
  H.eq(cheatsheet.is_open(), false)
  fm.setup({}) -- restore defaults for the rest of the suite
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test SUITE=unit FILTER='^keys_help'` and `make test SUITE=integration FILTER='^cheatsheet_'`
Expected: FAIL — `help` resolves to nothing (no spec entry, no default).

- [ ] **Step 3: Implement**

`lua/canvasdiff/input/keys.lua` — append to `K.specs` (after the sidebar entries):

```lua
  { ctx = "canvas",  action = "help", group = "Canvas",  desc = "Show keybind cheatsheet" },
  { ctx = "sidebar", action = "help", group = "Sidebar", desc = "Show keybind cheatsheet" },
```

`lua/canvasdiff/config/settings.lua` — in `M.defaults.keymaps.canvas`, after `close = "q",`:

```lua
      -- The one leader-key default in the plugin, accepted deliberately: a
      -- help binding exists for the user who does not know the other keys
      -- yet, so it must not shadow anything they might reach for (`?` is
      -- backward search, and search works fine in a read-only buffer).
      -- Like every default it is replaceable -- `help = "g?"` frees it.
      help       = "<leader>lh",
```

and in `M.defaults.keymaps.sidebar`, after `close  = "q",`:

```lua
      help   = "<leader>lh",
```

`lua/canvasdiff/App.lua` — in `canvas_actions` (App.lua:451), add to the returned table after `close`:

```lua
    help       = owned_action(surface, generation, function() ui.cheatsheet.toggle() end),
```

(`ui` is already imported at App.lua:13.) In `App:close()` (App.lua:1112), first line of the body:

```lua
  -- The overlay never survives the canvas (spec R4). toggle() closes through
  -- here too, so one hook covers both paths.
  ui.cheatsheet.close()
```

Note this sits BEFORE the early `return` for "no surface", which is correct: a stray overlay without a live surface should still die on an explicit close.

`lua/canvasdiff/ui/sidebar.lua` — add to the requires at the top:

```lua
local cheatsheet = require("canvasdiff.ui.cheatsheet")
```

and in `create_view`'s `actions` table (sidebar.lua:926), after `close`:

```lua
      help = function()
        if view_active(lease, view) then
          cheatsheet.toggle()
        end
      end,
```

`test/helpers.lua` — `H.norm_lhs` must now expand `<leader>`, because the mapping engine substitutes the leader at `vim.keymap.set` time while `nvim_replace_termcodes` does not; without this the existing "installed maps must be exactly what the registry resolves" test would compare `<leader>lh` against the literal `\lh` that `nvim_buf_get_keymap` reports. Replace the function body:

```lua
--- Canonical form of a keymap lhs, as nvim_buf_get_keymap reports it.
--- That API case-normalizes modifier notation (`<C-n>` comes back `<C-N>`)
--- while leaving `<CR>`, `<Tab>`, `]f`, `za` and friends untouched, so a
--- literal comparison passes or fails depending on which keys the test
--- happens to use. `<leader>` is expanded here for the same reason: the
--- mapping engine substitutes it at keymap.set time, replace_termcodes does
--- not. Put BOTH sides through this.
function H.norm_lhs(lhs)
  local leader = vim.g.mapleader or "\\"
  lhs = lhs:gsub("<[Ll]eader>", leader:gsub("%%", "%%%%"))
  return vim.fn.keytrans(vim.keycode(lhs))
end
```

`doc/canvasdiff.txt` — in section 7 MAPPINGS, add to the canvas list (after the `q` line, doc/canvasdiff.txt:171) and the sidebar list (after doc/canvasdiff.txt:176):

```
    <leader>lh              Show keybind cheatsheet
```

and add `help       = "<leader>lh",` to both context sub-tables in the config sample (doc/canvasdiff.txt:211-225). `README.md` — same one-line addition to both sub-tables of the keymaps sample (README.md:339-355).

- [ ] **Step 4: Run the full suite**

Run: `make test`
Expected: PASS, including the pre-existing "keys_install every canvas mapping is registered with a desc" test — it derives its expectation from `K.resolved`, so it now proves the `help` handler is actually wired (a spec entry without a handler installs nothing and fails it). If `test_config.lua`'s defaults assertions enumerate whole sub-tables, add the `help` key there too.

- [ ] **Step 5: Run the doc/architecture gates**

Run: `make test SUITE=architecture`
Expected: PASS — `sidebar.lua → ui.cheatsheet` is a ui-internal edge; `App.lua` reaches the module only through the `ui` facade.

- [ ] **Step 6: Commit**

```bash
git add lua/canvasdiff/input/keys.lua lua/canvasdiff/config/settings.lua \
  lua/canvasdiff/App.lua lua/canvasdiff/ui/sidebar.lua test/helpers.lua \
  test/unit/test_keys.lua test/integration/test_cheatsheet.lua \
  doc/canvasdiff.txt README.md
git commit -m "feat: <leader>lh keybind cheatsheet on the canvas and sidebar"
```
