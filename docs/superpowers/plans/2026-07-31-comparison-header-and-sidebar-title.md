# Comparison Header and Sidebar Title Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the product-prefixed canvas winbar with a directional breadcrumb and add a count-bearing `Files changed (N)` winbar to every sidebar view.

**Architecture:** Keep comparison identity in the existing normalized lens model and change only its window presentation. The canvas owns a breadcrumb formatter with a deliberate `%<` truncation point before the path; each sidebar view owns a dynamic title derived from `#state.sections`, updates it only while the live option is still CanvasDiff-owned, and participates in the sidebar's existing conditional window-option restoration.

**Tech Stack:** Lua, Neovim window-local `winbar`, MiniTest-style repository harness in `test/run.lua`, Git.

## Global Constraints

- Canvas format: `source → destination · current/file`.
- Sidebar format: `Files changed (N)`.
- `N` counts changed file sections, never rendered directory/tree rows.
- Preserve normalized lens direction, including three-dot merge-base labels.
- Insert Neovim's `%<` truncation marker immediately before the current path; it is formatting syntax, not visible copy.
- Do not add badges, icons, key hints, read-only labels, or selectable header rows.
- Preserve foreign window-local winbar replacements and restore inherited values only while CanvasDiff still owns the installed value.
- Keep existing sidebar row indices, folding, cursor tracking, and virtualization unchanged.
- Use focused RED/GREEN runs during implementation and one fresh authoritative `make test` after review repairs.

---

## File map

- `lua/canvasdiff/App.lua` — formats and owns the canvas breadcrumb.
- `lua/canvasdiff/ui/sidebar.lua` — formats, updates, and conditionally restores each sidebar title.
- `test/e2e/test_e2e.lua` — proves the canvas breadcrumb tracks the visible file and safely represents unusual names.
- `test/integration/test_root.lua` — proves three-dot range breadcrumbs preserve merge-base direction.
- `test/integration/test_session.lua` — proves committed-range direction remains derived from normalized lens identity.
- `test/integration/test_sidebar.lua` — proves sidebar counts, refreshes, row stability, and window-option ownership.
- `README.md` — user-facing examples of both persistent headers.
- `doc/canvasdiff.txt` — Vim help description of both persistent headers.

### Task 1: Canvas comparison breadcrumb

**Files:**
- Modify: `lua/canvasdiff/App.lua:741-803`
- Modify: `test/e2e/test_e2e.lua:617-669`
- Modify: `test/integration/test_root.lua:2572-2615`
- Modify: `test/integration/test_session.lua:875-949`

**Interfaces:**
- Consumes: `lens.of(state).label -> string`, `path_under_top(state, win) -> string?`, and `render.escape_path(path) -> string`.
- Produces: a window-local winbar whose stored expression is `<escaped-label> · %<<escaped-path>` or `<escaped-label>` when no section is visible.

- [ ] **Step 1: Tighten the existing canvas winbar test**

Update the existing E2E case to assert the exact stored expression before and
after scrolling:

```lua
local function wb()
  return vim.api.nvim_get_option_value("winbar", { win = cwin })
end

H.eq(wb(), "HEAD → WORKTREE · %<aaa.txt",
  "the breadcrumb names the comparison and visible file")
assert(not wb():find("CanvasDiff:", 1, true))
assert(not wb():find("│", 1, true))

-- after moving the topline into zzz.txt and firing WinScrolled:
H.eq(wb(), "HEAD → WORKTREE · %<zzz.txt",
  "only the trailing file breadcrumb changes while scrolling")
```

Extend the same fixture with a changed path containing a literal percent sign:

```lua
committed = {
  ["aaa.txt"] = body("aaa"),
  ["pct%name.txt"] = body("pct"),
  ["zzz.txt"] = body("zzz"),
},
worktree = {
  ["aaa.txt"] = body("aaa", true),
  ["pct%name.txt"] = body("pct", true),
  ["zzz.txt"] = body("zzz", true),
},
```

Scroll to that section, fire `WinScrolled`, and assert that the stored winbar
doubles the literal percent without escaping the intentional `%<` marker:

```lua
local pct_row
for i, line in ipairs(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)) do
  if line:find("pct%name.txt", 1, true) then
    pct_row = i
    break
  end
end
assert(pct_row, "the percent-bearing section is rendered")
vim.api.nvim_win_call(cwin, function()
  vim.fn.winrestview({ topline = pct_row + 20, lnum = pct_row + 22 })
end)
vim.api.nvim_exec_autocmds("WinScrolled", {})
assert(wb():find("%%name.txt", 1, true),
  "a literal percent is escaped in the stored statusline expression")
assert(wb():find(" · %<", 1, true),
  "the truncation marker remains active formatting")
```

- [ ] **Step 2: Run the focused E2E test and observe RED**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-header-red.log \
  make test SUITE=e2e FILTER='sidebar and winbar agree'
```

Expected: FAIL because the current option still begins with
`CanvasDiff: HEAD → WORKTREE │`.

- [ ] **Step 3: Implement the breadcrumb formatter**

In `set_winbar`, escape user/ref text separately from the `%<` formatting
token:

```lua
local function winbar_escape(text)
  return tostring(text or ""):gsub("%%", "%%%%")
end

local function comparison_breadcrumb(st, path)
  local label = winbar_escape(lens.of(st).label)
  if not path then
    return label
  end
  return label .. " · %<" .. winbar_escape(render.escape_path(path))
end
```

Replace the product prefix and heavy separator:

```lua
local here = path or path_under_top(st, win)
text = comparison_breadcrumb(st, here)
```

Do not apply a final `gsub("%%", "%%%%")` to the assembled expression, because
that would turn the intentional `%<` marker into visible text.

- [ ] **Step 4: Preserve committed-range semantics in integration coverage**

Change the range assertions to require the new expression without weakening
the existing normalized-direction check:

```lua
assert(winbar:find("topic → HEAD · %<a.txt", 1, true),
  "two-dot comparison uses the normalized directional breadcrumb")
assert(not winbar:find("CanvasDiff:", 1, true))

assert(restored:find("topic → HEAD · %<a.txt", 1, true),
  "reopen restores the same comparison breadcrumb")
```

Add the corresponding assertion to the restored legacy-payload test:

```lua
assert(winbar:find("main → WORKTREE · %<a.txt", 1, true),
  "the breadcrumb is derived from normalized identity, not persisted copy")
```

Extend `root_ folded range pivot records the candidate lens during
reconciliation` after `app:set_range("main...topic")`:

```lua
local range_winbar = vim.api.nvim_get_option_value("winbar", { win = win })
assert(range_winbar:find(
  "merge-base(main, topic) → topic · %<a.txt", 1, true),
  "three-dot comparisons retain their merge-base source")
```

- [ ] **Step 5: Run the canvas-focused tests and observe GREEN**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-header-green.log \
  make test SUITE=e2e FILTER='sidebar and winbar agree'
NVIM_LOG_FILE=/tmp/canvasdiff-header-session.log \
  make test SUITE=integration FILTER='committed range API|restored lens derives'
NVIM_LOG_FILE=/tmp/canvasdiff-header-range.log \
  make test SUITE=integration FILTER='folded range pivot'
```

Expected: all selected tests PASS.

- [ ] **Step 6: Commit the canvas breadcrumb**

```bash
git add lua/canvasdiff/App.lua test/e2e/test_e2e.lua \
  test/integration/test_root.lua test/integration/test_session.lua
git commit -m "feat: simplify comparison breadcrumb"
```

### Task 2: Sidebar changed-file title and ownership

**Files:**
- Modify: `lua/canvasdiff/ui/sidebar.lua:126-140,500-699,701-742,865-925`
- Modify: `test/integration/test_sidebar.lua:248-325,463-491,632-654`

**Interfaces:**
- Consumes: `lease.state.sections -> CanvasDiffSection[]` and the view's existing `prior_options` / `applied_options` ownership records.
- Produces: `sidebar_title(state) -> string`, plus a view-local winbar updated by `refresh_view` only when absent or still equal to the previously installed value.

- [ ] **Step 1: Add RED coverage for the title and stable tree rows**

Extend `sidebar_win opens fixed non-focused split`:

```lua
H.eq(vim.api.nvim_get_option_value("winbar", { win = side_win }),
  "Files changed (3)")
local side_buf = vim.api.nvim_win_get_buf(side_win)
H.eq(#vim.api.nvim_buf_get_lines(side_buf, 0, -1, false), 6,
  "the title is a winbar, not a selectable tree row")
```

In the folding test, record the title before and after folding a directory and
assert it remains based on sections:

```lua
H.eq(sidebar_winbar(lease), "Files changed (3)")
sidebar.select(lease) -- fold the chosen directory
H.eq(sidebar_winbar(lease), "Files changed (3)",
  "folding tree rows does not change the file count")
```

Add a helper local to the test file:

```lua
local function sidebar_winbar(lease, tab)
  return vim.api.nvim_get_option_value(
    "winbar", { win = assert(sidebar_win(lease, tab)) })
end
```

- [ ] **Step 2: Add RED coverage for refresh and foreign ownership**

Extend `sidebar_integration reconcile refreshes the tree`:

```lua
H.eq(sidebar_winbar(lease), "Files changed (1)")
-- create b.txt and reconcile
H.eq(sidebar_winbar(lease), "Files changed (2)",
  "the title follows the refreshed section count")
```

Add a real lens-pivot case with one staged-only file and one unstaged-only
file:

```lua
T["sidebar_integration title follows lens section counts"] = function()
  local orig_cwd = vim.fn.getcwd()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a0\n", ["b.txt"] = "b0\n" },
    worktree = { ["a.txt"] = "a1\n", ["b.txt"] = "b1\n" },
  })
  assert(require("canvasdiff.source").stage(root, {
    path = "b.txt", unstaged = "M",
  }))
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.setup({ watch = { enabled = false }, session = { enabled = false } })
  local ok, err = xpcall(function()
    local lenses = require("canvasdiff.diff").lens
    local st = assert(fm.open({ lens = lenses.get("unstaged") }))
    local lease = assert(st.surface.controllers.sidebar)

    H.eq(sidebar_winbar(lease), "Files changed (1)")
    assert(fm.set_lens(lenses.get("all")))
    H.eq(sidebar_winbar(lease), "Files changed (2)",
      "the title follows the newly published lens sections")
  end, debug.traceback)
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(orig_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end
```

Add a dedicated ownership case:

```lua
T["sidebar_win refresh preserves a foreign winbar replacement"] = function()
  local st, lease = open_with_sidebar()
  local win = assert(sidebar_win(lease))
  vim.api.nvim_set_option_value("winbar", "Foreign title", {
    win = win, scope = "local",
  })

  sidebar.refresh(lease)
  H.eq(vim.api.nvim_get_option_value("winbar", { win = win }), "Foreign title")
  sidebar.close(lease)
end
```

Extend the stranded-last-window case to begin with an inherited
`"Host title"`, then verify it is restored when CanvasDiff still owns the
sidebar title:

```lua
vim.api.nvim_set_option_value("winbar", "Host title", {
  win = st.win, scope = "local",
})
local lease = assert(sidebar.open(st, { width = 30 }))
-- strand and close the sidebar
H.eq(vim.api.nvim_get_option_value("winbar", { win = win }), "Host title")
```

- [ ] **Step 3: Run sidebar title tests and observe RED**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-sidebar-title-red.log \
  make test SUITE=integration FILTER='sidebar_win|sidebar_integration'
```

Expected: the new title assertions FAIL because sidebar windows currently
inherit their host winbar and never install `Files changed (N)`.

- [ ] **Step 4: Implement dynamic sidebar title ownership**

Add pure formatting:

```lua
local function sidebar_title(state)
  return ("Files changed (%d)"):format(#((state and state.sections) or {}))
end
```

Add a setter that distinguishes initial ownership from later refresh:

```lua
local function update_winbar(lease, view)
  if not (view_active(lease, view) and owned_pair(view)) then
    return false
  end
  local title = sidebar_title(lease.state)
  local previous = view.applied_options.winbar
  local actual = vim.api.nvim_get_option_value("winbar", { win = view.win })
  if previous ~= nil and actual ~= previous then
    return false
  end
  if previous == nil then
    view.prior_options.winbar = actual
  end
  vim.api.nvim_set_option_value("winbar", title, {
    win = view.win, scope = "local",
  })
  view.applied_options.winbar = title
  return true
end
```

Call `update_winbar(lease, view)` after applying the static window options in
`create_view`, and during `refresh_view` before publishing the refreshed entry
set. Recheck `view_active` after any window API call, following the surrounding
lifecycle pattern.

Factor conditional restoration so the dynamic winbar uses the same
compare-before-restore rule as static options:

```lua
local function restore_owned_option(view, win, name)
  local prior = view.prior_options[name]
  local applied = view.applied_options[name]
  local ok, actual = pcall(
    vim.api.nvim_get_option_value, name, { win = win })
  if ok and actual == applied then
    pcall(vim.api.nvim_set_option_value, name, prior, {
      win = win, scope = "local",
    })
  end
end
```

Invoke it for `"winbar"` from `restore_surviving_window` after the static
option loop. Do not add a header line to `render_lines`.

- [ ] **Step 5: Run sidebar tests and observe GREEN**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-sidebar-title-green.log \
  make test SUITE=integration FILTER='sidebar_'
```

Expected: all sidebar integration tests PASS, including unchanged row and
active-mark expectations.

- [ ] **Step 6: Commit the sidebar title**

```bash
git add lua/canvasdiff/ui/sidebar.lua test/integration/test_sidebar.lua
git commit -m "feat: title changed-files sidebar"
```

### Task 3: User documentation and verification

**Files:**
- Modify: `README.md:95-102,305-308`
- Modify: `doc/canvasdiff.txt:120-129`

**Interfaces:**
- Consumes: the exact presentation delivered by Tasks 1 and 2.
- Produces: user documentation naming the canvas breadcrumb and sidebar title without introducing new behavior.

- [ ] **Step 1: Update the README examples**

Replace the old product-prefixed example with:

```markdown
- **The canvas winbar** is a breadcrumb:
  `HEAD → WORKTREE · src/canvas.lua`. The comparison stays on the left and the
  file under the topline follows after it as you scroll.
- **The sidebar winbar** is a collection title such as `Files changed (12)`.
  Its count is the number of changed files, even when directories are folded.
- **The sidebar's highlighted row** tracks the same file as the canvas.
```

Keep the lens section concise:

```markdown
The current comparison is always named on the left side of the canvas
breadcrumb.
```

- [ ] **Step 2: Update Vim help**

After the range/lens explanation, add:

```text
The canvas winbar uses `source → destination · current/file`. The sidebar
winbar uses `Files changed (N)`, where N counts changed files rather than
visible directory rows.
```

- [ ] **Step 3: Run documentation and focused behavior checks**

Run:

```bash
git diff --check
rg -n 'CanvasDiff: HEAD|Files changed|→.*·' README.md doc/canvasdiff.txt
NVIM_LOG_FILE=/tmp/canvasdiff-header-focused.log \
  make test SUITE=e2e FILTER='sidebar and winbar agree'
NVIM_LOG_FILE=/tmp/canvasdiff-sidebar-focused.log \
  make test SUITE=integration FILTER='sidebar_|committed range API|restored lens derives'
```

Expected: no old `CanvasDiff: HEAD` example, both new conventions documented,
and all selected tests PASS.

- [ ] **Step 4: Commit documentation**

```bash
git add README.md doc/canvasdiff.txt
git commit -m "docs: explain comparison breadcrumbs"
```

- [ ] **Step 5: Run the scoped lifecycle review**

Review the complete change from the design commit through current `HEAD`.
Accept the review when no Critical or Important issue remains. Repair only
concrete supported-behavior regressions, cap repair/re-review at five rounds,
and do not expand into unrelated platform or trust-boundary scenarios.

- [ ] **Step 6: Run one fresh authoritative suite**

Run exactly once after the final repair:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-comparison-header-full.log make test
```

Expected: the complete suite passes with zero failures.

- [ ] **Step 7: Record final state**

Run:

```bash
git diff --check
git status --short --branch
git log -6 --oneline
```

Expected: clean `main`, implementation commits present, and no uncommitted
files.
