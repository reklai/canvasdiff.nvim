# Read-only UX, Hints Audit, and Targeted Architecture Audit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Range comparisons announce themselves as READ-ONLY (label + tinted winbar), every hint speaks that same vocabulary, the winbar gains a help tail and the sidebar a diffstat, and the winbar presentation moves behind the `ui` facade with a written ghostty-pattern audit.

**Architecture:** Winbar presentation (text building, hl groups, option bookkeeping) is extracted from `App.lua` into a new `ui/winbar.lua` owner behind the `ui` facade, then the READ-ONLY tint and help tail land in that module. Lens labels change only in `diff/lens.lua`'s pure `label_for`. Sidebar diffstat is a change to one pure local function. The audit is a docs deliverable plus a triage of the recorded deferred-minors pool.

**Tech Stack:** Neovim Lua plugin. Tests run headless via `make test` (suites: `make unit`, `make integration`, `make architecture`); a single file filters with `make test SUITE=unit FILTER='^winbar_'` (FILTER matches test NAMES, not filenames).

**Spec:** `docs/superpowers/specs/2026-07-31-readonly-ux-and-architecture-audit-design.md`

## Global Constraints

- One vocabulary for one fact: user-visible copy about a range lens always says **READ-ONLY** (exactly that spelling, capitals, hyphen).
- Range labels render as `READ-ONLY  A → B` — capital READ-ONLY, **two spaces**, refs joined by ` → ` (space, U+2192, space). Two-dot and three-dot look identical; lens `id` keeps the operator.
- Editable lens labels are unchanged: `HEAD → WORKTREE`, `INDEX → WORKTREE (unstaged)`, `HEAD → INDEX (staged)`, `<ref> → WORKTREE`.
- All new highlight groups are `default = true` so colorschemes win.
- Every commit leaves `make test` green (full suite, all intent directories).
- Architecture rules are executable: cross-domain requires go through facades only (`test/architecture/rules.lua`). `ui` may import `canvas`, `config`, `diff`, `input`, `os` — nothing else.
- The test suite forbids duplicate test-file basenames across suite directories.
- Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: READ-ONLY range labels

**Files:**
- Modify: `lua/canvasdiff/diff/lens.lua:81-86` (the range branch of `label_for`)
- Test: `test/unit/test_model.lua:10-25` (existing range-label expectations)
- Test: `test/integration/test_lens.lua:155`
- Test: `test/integration/test_root.lua:2608-2609`

**Interfaces:**
- Produces: `lens.normalize`/`lens.of` now yield `label = "READ-ONLY  main → topic"` for both `..` and `...` ranges. Task 3's winbar test and Task 4's README copy rely on this exact string.

- [ ] **Step 1: Update the unit expectations to the new labels**

In `test/unit/test_model.lua`, the two range fixtures near the top assert today's labels. Change them:

```lua
-- was: label = "main → topic",
      label = "READ-ONLY  main → topic",
```

```lua
-- was: label = "merge-base(main, topic) → topic",
      label = "READ-ONLY  main → topic",
```

(Keep everything else in those fixtures — ids `range:main..topic` / `range:main...topic` are unchanged.)

In `test/integration/test_lens.lua:155` replace the expected string `"merge-base(main, topic) → topic"` with `"READ-ONLY  main → topic"`.

In `test/integration/test_root.lua:2608-2609` replace:

```lua
      "merge-base(main, topic) → topic · %<a.txt", 1, true),
      "three-dot comparisons retain their merge-base source")
```

with:

```lua
      "READ-ONLY  main → topic · %<a.txt", 1, true),
      "a three-dot comparison names the refs the user asked for, marked READ-ONLY")
```

- [ ] **Step 2: Run the touched suites to verify they fail**

Run: `make unit` and `make integration`
Expected: the changed assertions FAIL (labels still render the old strings).

- [ ] **Step 3: Change `label_for`'s range branch**

In `lua/canvasdiff/diff/lens.lua`, replace lines 81-86:

```lua
  if range_shape(l) then
    if l.operator == "..." then
      return ("merge-base(%s, %s) → %s"):format(l.old, l.new, l.new)
    end
    return ("%s → %s"):format(l.old, l.new)
  end
```

with:

```lua
  if range_shape(l) then
    -- Both operators show the refs the user asked for. Three-dot still
    -- collects from the merge base (source/collect.lua) -- the label hides
    -- the plumbing, the same presentation choice GitHub makes for PR diffs.
    -- READ-ONLY is the mode vocabulary; the winbar tint says it in colour.
    return ("READ-ONLY  %s → %s"):format(l.old, l.new)
  end
```

- [ ] **Step 4: Run the full suite**

Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test`
Expected: PASS everywhere. If any other test asserts the old label, update it to the new string — the Global Constraints spelling is the source of truth.

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/diff/lens.lua test/unit/test_model.lua test/integration/test_lens.lua test/integration/test_root.lua
git commit -m "feat: label range comparisons READ-ONLY with the requested refs"
```

---

### Task 2: Extract `ui/winbar.lua` (pure move, no behavior change)

**Files:**
- Create: `lua/canvasdiff/ui/winbar.lua`
- Modify: `lua/canvasdiff/ui.lua` (facade: add `winbar = winbar`)
- Modify: `lua/canvasdiff/App.lua:773-831` (`winbar_escape`, `comparison_breadcrumb`, `set_winbar`, `clear_winbar`)
- Test: `test/unit/test_winbar.lua` (new file; basename must be unique across suites — it is)

**Interfaces:**
- Consumes: `diff.lens.of/is_range` (facade), `canvas.format.escape_path` (facade), `config.options`.
- Produces (Tasks 3 and 5 build here):
  - `W.escape(text) -> string` — `%`-escapes a statusline fragment.
  - `W.text(st, path) -> string` — the full winbar string for canvas state `st` with section path `path` (or nil).
  - `W.apply(st, win, text)` — cached window-option write (owns `st.winbar_text_by_win`).
  - `W.clear(st, win)` — releases the option only if we still own the current value.

- [ ] **Step 1: Write failing unit tests for the extracted text builder**

Create `test/unit/test_winbar.lua`:

```lua
local H = require("helpers")
local winbar = require("canvasdiff.ui").winbar
local lens = require("canvasdiff.diff").lens

local T = {}

T["winbar_ text renders label alone when no path is under the top"] = function()
  local st = { lens = lens.get("all") }
  H.eq(winbar.text(st, nil), "HEAD → WORKTREE")
end

T["winbar_ text appends the truncatable path after a separator"] = function()
  local st = { lens = lens.get("all") }
  H.eq(winbar.text(st, "a.txt"), "HEAD → WORKTREE · %<a.txt")
end

T["winbar_ text escapes percent signs in refs and paths"] = function()
  local st = { lens = lens.range("a%b", "topic", "..") }
  H.eq(winbar.text(st, "100%.txt"),
    "READ-ONLY  a%%b → topic · %<100%%.txt")
end

return T
```

(The third test's expected string starts with `READ-ONLY  ` because Task 1 already landed. `st` needs only a valid `lens` field — `lens.of` falls back from `state.base` otherwise.)

- [ ] **Step 2: Run to verify failure**

Run: `make test SUITE=unit FILTER='^winbar_'`
Expected: FAIL — `require("canvasdiff.ui").winbar` is nil.

- [ ] **Step 3: Create the module and rewire App**

Create `lua/canvasdiff/ui/winbar.lua`:

```lua
-- The canvas winbar: breadcrumb text and the window-option bookkeeping that
-- applies and releases it.
--
-- Presentation only. App resolves WHICH path sits under a window's topline
-- (that is orchestration over live canvas state); this module owns everything
-- about how the answer is shown. Extracted from App.lua so the largest
-- stateful owner keeps orchestration and the ui domain keeps presentation.

local canvas = require("canvasdiff.canvas")
local diff = require("canvasdiff.diff")

local lens = diff.lens

local W = {}

--- The text is a statusline expression, so `%` in a branch ref or path has to
--- be escaped before Neovim evaluates it.
function W.escape(text)
  return tostring(text or ""):gsub("%%", "%%%%")
end

--- The breadcrumb: comparison on the left, the file under the topline after
--- it. `%<` truncates the path, never the comparison.
function W.text(st, path)
  local label = W.escape(lens.of(st).label)
  if not path then
    return label
  end
  return label .. " · %<" .. W.escape(canvas.format.escape_path(path))
end

--- Cached write. Runs on every WinScrolled, and writing 'winbar' forces a
--- window redraw, so identical text is skipped -- comparing the resolved
--- string also covers scrolling WITHIN one file, where only the path lookup's
--- work was wasted. The cache lives on the canvas state so a rebuilt state
--- starts clean.
function W.apply(st, win, text)
  if not (st and win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  st.winbar_text_by_win = st.winbar_text_by_win or {}
  if st.winbar_text_by_win[win] == text then
    local ok, actual = pcall(
      vim.api.nvim_get_option_value, "winbar", { win = win })
    if ok and actual == text then
      return
    end
  end
  st.winbar_text_by_win[win] = text
  pcall(vim.api.nvim_set_option_value, "winbar", text, { win = win, scope = "local" })
end

--- Release the option only while we still own the current value -- a leftover
--- winbar on a restored window would claim the file you are editing is a diff
--- canvas, but a value someone else wrote since is theirs to keep.
function W.clear(st, win)
  if not (st and win) then
    return
  end
  local owned_text = st.winbar_text_by_win and st.winbar_text_by_win[win] or nil
  if st.winbar_text_by_win then
    st.winbar_text_by_win[win] = nil
  end
  if not vim.api.nvim_win_is_valid(win) or owned_text == nil then
    return
  end
  local ok, actual = pcall(
    vim.api.nvim_get_option_value, "winbar", { win = win })
  if ok and actual == owned_text then
    pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win, scope = "local" })
  end
end

return W
```

In `lua/canvasdiff/ui.lua`, add the require and the facade entry (alphabetical with its neighbors):

```lua
local winbar = require("canvasdiff.ui.winbar")
```

```lua
  winbar = winbar,
```

In `lua/canvasdiff/App.lua`, delete `winbar_escape` (773-775), `comparison_breadcrumb` (777-783), and the bodies of `set_winbar`/`clear_winbar` (785-831), replacing the latter two with thin delegates so all ~15 call sites stay untouched (`ui` is already imported at the top of App):

```lua
local function set_winbar(st, text, win, path)
  win = win or (st and st.win)
  if not (st and win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if text == nil then
    -- The STICKY part, and the reason this recomputes on scroll: a file
    -- header scrolls out of view a screen into its diff, and from then on
    -- nothing IN the canvas says which block you are reading. Resolving the
    -- topline path is orchestration; how it is shown belongs to ui.winbar.
    text = ui.winbar.text(st, path or path_under_top(st, win))
  end
  ui.winbar.apply(st, win, text)
end

local function clear_winbar(st, win)
  ui.winbar.clear(st, win)
end
```

Keep `path_under_top` in App exactly as it is (it needs `canvas_showing`, which is App state logic). Keep the doc comment block above the old `set_winbar` region that explains why the winbar exists (741-758) — it now introduces `path_under_top` + the delegates.

- [ ] **Step 4: Run the new tests, then the full suite**

Run: `make test SUITE=unit FILTER='^winbar_'` — expected PASS.
Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` — expected PASS, including `make architecture` (the new edge `ui -> canvas`/`ui -> diff` is already allowed; the new file sits inside the ui domain so no rules change).

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/ui/winbar.lua lua/canvasdiff/ui.lua lua/canvasdiff/App.lua test/unit/test_winbar.lua
git commit -m "refactor: move winbar presentation behind the ui facade"
```

---

### Task 3: READ-ONLY winbar tint

**Files:**
- Modify: `lua/canvasdiff/ui/winbar.lua` (from Task 2)
- Test: `test/unit/test_winbar.lua`
- Test: `test/integration/test_root.lua:2608` (winbar assertion gains the group prefix)
- Scratch (not committed): a luminance measurement script

**Interfaces:**
- Consumes: `W.text` from Task 2; `lens.is_range` from the diff facade.
- Produces: `W.text` output now starts with `%#CanvasDiffWinbar#` (editable lenses) or `%#CanvasDiffWinbarReadOnly#` (range lenses); `W.ensure_hl_groups()` defines both groups. Task 5 appends after this prefix.

- [ ] **Step 1: Measure the tint candidates**

Write to your scratchpad (do not commit) `lum.lua`:

```lua
local function lum(rgb)
  if not rgb then return nil end
  local r = math.floor(rgb / 65536) % 256
  local g = math.floor(rgb / 256) % 256
  local b = rgb % 256
  return math.floor(0.2126 * r + 0.7152 * g + 0.0722 * b + 0.5)
end
local function bg(name)
  local h = vim.api.nvim_get_hl(0, { name = name, link = false })
  return lum(h.bg)
end
for _, scheme in ipairs({ "default", "tokyonight-moon" }) do
  local ok = pcall(vim.cmd.colorscheme, scheme)
  print(scheme .. (ok and "" or " (unavailable, skipped)"))
  if ok then
    for _, g in ipairs({ "Normal", "WinBar", "DiffDelete", "Visual", "StatusLine" }) do
      print(("  %-12s bg-lum=%s"):format(g, tostring(bg(g))))
    end
  end
end
```

Run: `nvim --headless -l <scratchpad>/lum.lua` (NOT `--clean` — tokyonight must be on the runtimepath; if it still reports unavailable, decide from `default` alone).
Decision rule: `CanvasDiffWinbarReadOnly` links to the candidate (`DiffDelete`, `Visual`, `StatusLine`) whose background-luminance gap against `WinBar`'s background (fall back to `Normal`'s when `WinBar` has none) has the largest MINIMUM across the measured schemes; ties break toward `DiffDelete` (red = locked is the semantic fit). Record the numbers — they go in the commit message.

- [ ] **Step 2: Extend the unit tests (failing)**

Update `test/unit/test_winbar.lua` — the three existing expectations gain the editable prefix, and a range case asserts the read-only group:

```lua
T["winbar_ text renders label alone when no path is under the top"] = function()
  local st = { lens = lens.get("all") }
  H.eq(winbar.text(st, nil), "%#CanvasDiffWinbar#HEAD → WORKTREE")
end

T["winbar_ text appends the truncatable path after a separator"] = function()
  local st = { lens = lens.get("all") }
  H.eq(winbar.text(st, "a.txt"), "%#CanvasDiffWinbar#HEAD → WORKTREE · %<a.txt")
end

T["winbar_ text escapes percent signs in refs and paths"] = function()
  local st = { lens = lens.range("a%b", "topic", "..") }
  H.eq(winbar.text(st, "100%.txt"),
    "%#CanvasDiffWinbarReadOnly#READ-ONLY  a%%b → topic · %<100%%.txt")
end

T["winbar_ a range lens tints the whole bar read-only"] = function()
  local st = { lens = lens.range("main", "topic", "...") }
  H.eq(winbar.text(st, nil), "%#CanvasDiffWinbarReadOnly#READ-ONLY  main → topic")
end

T["winbar_ ensure_hl_groups defines both groups as defaults"] = function()
  winbar.ensure_hl_groups()
  local base = vim.api.nvim_get_hl(0, { name = "CanvasDiffWinbar" })
  local ro = vim.api.nvim_get_hl(0, { name = "CanvasDiffWinbarReadOnly" })
  H.eq(base.link, "WinBar")
  H.eq(type(ro.link), "string")
end
```

In `test/integration/test_root.lua:2608`, prefix the expected string:

```lua
      "%#CanvasDiffWinbarReadOnly#READ-ONLY  main → topic · %<a.txt", 1, true),
```

Run: `make test SUITE=unit FILTER='^winbar_'` — expected FAIL.

- [ ] **Step 3: Implement the tint**

In `lua/canvasdiff/ui/winbar.lua`, add (below `W.escape`; replace `<WINNER>` with the measured Step-1 winner, e.g. `DiffDelete`):

```lua
--- A coloured bar is a mode indicator, like macro-recording: the READ-ONLY
--- tint says "this comparison cannot be edited" in peripheral vision, before
--- the label is read. Groups are `default = true` so colourschemes win; the
--- read-only default was chosen by luminance measurement against the builtin
--- scheme and tokyonight-moon (numbers in the introducing commit), the same
--- method as CanvasDiffFileBar.
function W.ensure_hl_groups()
  vim.api.nvim_set_hl(0, "CanvasDiffWinbar", { link = "WinBar", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffWinbarReadOnly", { link = "<WINNER>", default = true })
end
```

Change `W.text` to open with the group:

```lua
function W.text(st, path)
  local l = lens.of(st)
  local group = lens.is_range(l) and "CanvasDiffWinbarReadOnly" or "CanvasDiffWinbar"
  local out = "%#" .. group .. "#" .. W.escape(l.label)
  if not path then
    return out
  end
  return out .. " · %<" .. W.escape(canvas.format.escape_path(path))
end
```

In `W.apply`, ensure the groups exist before the first real write (after the cache-hit early return, before the option write):

```lua
  W.ensure_hl_groups()
```

- [ ] **Step 4: Run the full suite**

Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test`
Expected: PASS. If another integration test asserts a raw winbar string, give it the same `%#CanvasDiffWinbar...#` prefix treatment (grep: `grep -rn '· %<' test/`).

- [ ] **Step 5: Commit (measurement numbers in the body)**

```bash
git add lua/canvasdiff/ui/winbar.lua test/unit/test_winbar.lua test/integration/test_root.lua
git commit -m "feat: tint the winbar for READ-ONLY comparisons" -m "<paste the lum.lua output and the decision here>"
```

---

### Task 4: Hints audit — one READ-ONLY vocabulary

**Files:**
- Modify: `lua/canvasdiff/input/jump.lua:95,109-117`
- Modify: `lua/canvasdiff/input/keys.lua:36-37` (lens descs)
- Modify: `lua/canvasdiff/App.lua:2282` (range stage refusal)
- Modify: `README.md` (breadcrumb examples, range section)
- Test: `test/integration/test_lens.lua` or wherever the refusal strings are asserted (grep below)

**Interfaces:**
- Consumes: Task 1's label spelling.
- Produces: user-visible refusal copy quoted below; Task 7's audit doc references this vocabulary rule.

- [ ] **Step 1: Find every assertion on the strings being changed**

Run: `grep -rn "press B\|not editable\|committed ranges cannot" test/ lua/`
Update the expectations in whatever tests these greps hit to the new strings from Step 3, run the touched suites, and confirm they FAIL before implementing.

- [ ] **Step 2: Fix the stale fallback while in jump.lua**

`lua/canvasdiff/input/jump.lua:95` still defaults to the retired return key:

```lua
  local back_keys = opts.back_keys or { "<M-CR>" }
```

becomes:

```lua
  local back_keys = opts.back_keys or { "<C-Space>" }
```

(Config always passes the real keys; only the fallback was stale.)

- [ ] **Step 3: Split the jump refusal by lens kind**

Replace `lua/canvasdiff/input/jump.lua:109-117`:

```lua
  -- The staged lens's new side is the index, which is not a file you can open --
  -- editing the worktree copy instead would silently put you in a buffer whose
  -- content is NOT what the canvas is showing. Name the way out rather than just
  -- refusing: unstaging moves that content back into the worktree, where it is
  -- editable again.
  if not lens.editable(lens.of(state)) then
    return declined("warn",
      "staged view is not editable — unstage it to edit, or press B for the worktree")
  end
```

with:

```lua
  -- Two different refusals for two different facts. The staged lens's new side
  -- is the index, which is not a file you can open -- editing the worktree copy
  -- instead would silently put you in a buffer whose content is NOT what the
  -- canvas is showing; unstaging moves that content back where it is editable.
  -- A committed range has no editable side at all. Both name the way out
  -- rather than just refusing, in the breadcrumb's own vocabulary.
  local l = lens.of(state)
  if not lens.editable(l) then
    if lens.is_range(l) then
      return declined("warn",
        "READ-ONLY comparison — press Tab to return to HEAD → WORKTREE and edit")
    end
    return declined("warn",
      "staged view is not editable — unstage it (s) to edit, or press Tab for the worktree")
  end
```

- [ ] **Step 4: Align the stage refusal**

`lua/canvasdiff/App.lua:2282`:

```lua
    local err = "committed ranges cannot be staged or unstaged"
```

becomes:

```lua
    local err = "READ-ONLY comparison — staging needs a worktree lens (press Tab)"
```

- [ ] **Step 5: Make the lens descs say what happens from a range**

`lua/canvasdiff/input/keys.lua:36-37`:

```lua
  { ctx = "canvas", action = "lens_next",  group = "View",     desc = "Next lens: all / unstaged / staged" },
  { ctx = "canvas", action = "lens_prev",  group = "View",     desc = "Previous lens" },
```

becomes:

```lua
  { ctx = "canvas", action = "lens_next",  group = "View",     desc = "Next lens: all / unstaged / staged (exits a READ-ONLY range)" },
  { ctx = "canvas", action = "lens_prev",  group = "View",     desc = "Previous lens (exits a READ-ONLY range)" },
```

- [ ] **Step 6: README pass**

In `README.md`:
- The ranges bullet list (~lines 330-336): after the `A...B` merge-base explanation, add one sentence: "Either way the breadcrumb shows the refs you asked for, marked `READ-ONLY`, and the whole winbar is tinted (`CanvasDiffWinbarReadOnly`, default measured the same way as `CanvasDiffFileBar`)."
- The "Knowing where you are" winbar bullet (~line 98-100): the example breadcrumb stays `HEAD → WORKTREE · src/canvas.lua`; append: "A branch comparison reads `READ-ONLY  main → topic` instead — read-only mode also tints the bar."
- Search the README for `merge-base(` — if any example renders it as breadcrumb text, replace with the READ-ONLY form (the *explanation* of three-dot semantics stays).
- The lens table/notes: where `<Tab>`/`<S-Tab>` leaving a range is described (~line 337), keep — it already matches the new descs.

- [ ] **Step 7: Run the full suite, then commit**

Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` — expected PASS (cheatsheet layout tests exercise the longer descs; they compute widths from content so no fixture should break — if one asserts an exact width, update it).

```bash
git add lua/canvasdiff/input/jump.lua lua/canvasdiff/input/keys.lua lua/canvasdiff/App.lua README.md test/
git commit -m "fix: retire stale hints and speak READ-ONLY everywhere a range refuses"
```

---

### Task 5: Help tail on the canvas winbar

**Files:**
- Modify: `lua/canvasdiff/ui/winbar.lua`
- Test: `test/unit/test_winbar.lua`
- Modify: `README.md` (one sentence, see Step 4)

**Interfaces:**
- Consumes: `input.keys.resolved(ctx, keymaps)` — returns `{ { action, lhs, desc, ... }, ... }` (see `ui/cheatsheet.lua:close_keys` for the same usage); `config.options.keymaps`.
- Produces: `W.text` may end with `%=<lhs> help` — right-aligned via `%=`, where `<lhs>` is the first configured canvas `help` key, `%`-escaped. Absent entirely when `help` is unbound.

- [ ] **Step 1: Write failing tests**

Append to `test/unit/test_winbar.lua`:

```lua
T["winbar_ text ends with a right-aligned help tail when help is bound"] = function()
  local st = { lens = lens.get("all") }
  local km = { canvas = { help = "<leader>lh" } }
  H.eq(winbar.text(st, "a.txt", km),
    "%#CanvasDiffWinbar#HEAD → WORKTREE · %<a.txt%=<leader>lh help")
end

T["winbar_ text has no tail when help is disabled"] = function()
  local st = { lens = lens.get("all") }
  local km = { canvas = { help = false } }
  H.eq(winbar.text(st, "a.txt", km), "%#CanvasDiffWinbar#HEAD → WORKTREE · %<a.txt")
end

T["winbar_ a multi-bound help shows only its first key"] = function()
  local st = { lens = lens.get("all") }
  local km = { canvas = { help = { "?", "<leader>lh" } } }
  H.eq(winbar.text(st, nil, km), "%#CanvasDiffWinbar#HEAD → WORKTREE%=? help")
end
```

Caution: if `keys.resolved("canvas", km)` turns out to require a complete keymaps table (check its reading of absent contexts), build the fixtures with `vim.tbl_deep_extend("force", vim.deepcopy(require("canvasdiff.config").options.keymaps), { canvas = { help = ... } })` instead of the bare tables shown — the expected strings stay the same.

Note the new third parameter. Existing `winbar.text(st, path)` calls must keep working — the tail then resolves from `config.options.keymaps`, so tests that pass no `km` still get the *default* tail; update the four existing Task-2/3 expectations to end with `%=<leader>lh help` (the default help binding). Example:

```lua
  H.eq(winbar.text(st, nil), "%#CanvasDiffWinbar#HEAD → WORKTREE%=<leader>lh help")
```

(Apply the same suffix to the other three, and to the integration assertion at `test/integration/test_root.lua:2608` — it becomes `"%#CanvasDiffWinbarReadOnly#READ-ONLY  main → topic · %<a.txt%=<leader>lh help"`.)

Run: `make test SUITE=unit FILTER='^winbar_'` — expected FAIL.

- [ ] **Step 2: Implement the tail**

In `lua/canvasdiff/ui/winbar.lua`, add `local config = require("canvasdiff.config")` and `local input = require("canvasdiff.input")` to the requires, then:

```lua
--- hunk keeps a persistent menu bar; the canvas equivalent is one small,
--- right-aligned reminder that a cheatsheet exists at all. It shows the key
--- actually configured (the first, when several), and disappears with the
--- binding -- a hint for a key you removed would be worse than none.
local function help_tail(keymaps)
  for _, m in ipairs(input.keys.resolved("canvas", keymaps)) do
    if m.action == "help" then
      return "%=" .. W.escape(m.lhs) .. " help"
    end
  end
  return ""
end
```

and extend `W.text`:

```lua
function W.text(st, path, keymaps)
  local l = lens.of(st)
  local group = lens.is_range(l) and "CanvasDiffWinbarReadOnly" or "CanvasDiffWinbar"
  local out = "%#" .. group .. "#" .. W.escape(l.label)
  if path then
    out = out .. " · %<" .. W.escape(canvas.format.escape_path(path))
  end
  return out .. help_tail(keymaps or config.options.keymaps)
end
```

(`keys.resolved` preserves configuration order, so "the first key" is the first the user listed. The `%<` truncation point sits before the path, so a narrow window truncates the path, never the comparison or the tail.)

- [ ] **Step 3: Run the full suite**

Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test`
Expected: PASS. Any other test asserting a full winbar string gains the `%=<lhs> help` suffix (same grep as Task 3: `grep -rn '· %<' test/`).

- [ ] **Step 4: README sentence + commit**

In `README.md`, "Knowing where you are", canvas-winbar bullet, append: "Its right edge names the cheatsheet key (`<leader>lh help` by default); rebinding or disabling `help` moves or removes the reminder."

```bash
git add lua/canvasdiff/ui/winbar.lua test/unit/test_winbar.lua test/integration/test_root.lua README.md
git commit -m "feat: name the cheatsheet key at the winbar's right edge"
```

---

### Task 6: Sidebar diffstat title

**Files:**
- Modify: `lua/canvasdiff/ui/sidebar.lua:142-144` (`sidebar_title`)
- Test: `test/integration/test_sidebar.lua:274,357,359,487,502` (title expectations)
- Modify: `README.md` (sidebar winbar bullet)

**Interfaces:**
- Consumes: `state.sections[i].adds` / `.dels` (every section carries integer counts; `diff/model.lua` initializes them to 0), `render.glyphs.minus` — `render` in sidebar.lua is the canvas facade's `format` table, whose `glyphs` field is the live config glyph table (`canvas.lua:18`), so the ASCII glyph set is honored automatically.
- Produces: title format `Files changed (N)  +A −D` (two spaces before `+`, `−` is `glyphs.minus`); stats omitted when there are no sections.

- [ ] **Step 1: Update the five title expectations (failing)**

The integration fixtures at the listed lines assert bare `Files changed (N)`. Look at each fixture's sections to sum their `adds`/`dels`, then extend the expected strings, e.g. a three-file fixture totalling +9 −4 becomes:

```lua
    "Files changed (3)  +9 −4")
```

(Compute per fixture — do not guess; the fixture builders state their hunks. A fixture with zero sections stays `Files changed (0)` with no stats.)

Run: `make integration` — expected FAIL on exactly those assertions.

- [ ] **Step 2: Implement**

Replace `sidebar_title` (`lua/canvasdiff/ui/sidebar.lua:142-144`):

```lua
--- The collection title, now carrying the changeset's size in the same
--- vocabulary as each file header: how many files, and how much churn. The
--- stats ride the count (hunk shows stream-level stats for the same reason);
--- they vanish with the sections rather than asserting "+0 −0" about nothing.
local function sidebar_title(state)
  local sections = (state and state.sections) or {}
  local title = ("Files changed (%d)"):format(#sections)
  if #sections == 0 then
    return title
  end
  local adds, dels = 0, 0
  for _, s in ipairs(sections) do
    adds = adds + (s.adds or 0)
    dels = dels + (s.dels or 0)
  end
  return title .. ("  +%d %s%d"):format(adds, render.glyphs.minus, dels)
end
```

(Format check: this matches the file headers' spelling — `format.lua` renders `(+%d ' .. GLYPHS.minus .. '%d)` → `+9 −4`, space before the minus glyph, none after. The title reuses exactly that shape.)

- [ ] **Step 3: Run the full suite**

Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test`
Expected: PASS. The title reaches the winbar through the existing `update_winbar` calls on open and reconcile, so live updates need no new wiring; if an e2e test snapshots the sidebar winbar, extend it the same way as Step 1.

- [ ] **Step 4: README + commit**

README "Knowing where you are", sidebar-winbar bullet: change to "**The sidebar winbar** is a collection title such as `Files changed (12)  +340 −128` — the count is files (even when directories are folded), the stats are the whole changeset's."

```bash
git add lua/canvasdiff/ui/sidebar.lua test/integration/test_sidebar.lua README.md
git commit -m "feat: carry the changeset diffstat in the sidebar title"
```

---

### Task 7: Ghostty-pattern audit + deferred-minors triage

**Files:**
- Create: `docs/research/2026-07-31-ghostty-architecture-audit.md`
- Possibly modify: `lua/canvasdiff/canvas.lua` + `lua/canvasdiff/App.lua` (only if the `canvas_showing` dedup lands — Step 2 decides)

**Interfaces:**
- Consumes: the winbar extraction (Task 2) as the audit's worked exemplar; the deferred pool at the end of `.superpowers/sdd/progress.md`.
- Produces: the audit document; future PR/commit-mode work cites its "mode seam contract" section.

- [ ] **Step 1: Write the audit document**

Create `docs/research/2026-07-31-ghostty-architecture-audit.md` with these sections, each grounded in this repo's files (cite paths) — not ghostty tourism:

1. **Pattern map** — a table of ghostty disciplines against ours:
   - subsystem directories (`src/font`, `src/renderer`, `src/terminal`, `src/apprt`) ↔ our nine domains under `lua/canvasdiff/` (`docs/architecture.md` table);
   - `libghostty`'s deliberately small C API ↔ our facades being "the domain's exact public surface" (`canvas.lua`, `diff.lua`, `ui.lua`);
   - ghostty's one-owner-per-resource / explicit lifetimes ↔ the lease system (`docs/architecture.md` "Ownership: leases");
   - ghostty's cross-platform seam (apprt implementations behind one interface) ↔ our `os/` domain isolating process/fs/timer effects;
   - ghostty's enforced style/layout checks ↔ `test/architecture/` executable rules.
   Verdict per row: MATCH / DIVERGES / ADOPT. Expected honest outcome: mostly MATCH — say so plainly.
2. **Debt found and what this pass did** — `App.lua` was 3,077 lines with presentation mixed into orchestration; the winbar extraction (Task 2) is the worked exemplar. List the remaining App.lua concerns worth the same treatment later, each with its line-count share (measure with `grep -c` while writing, don't estimate): empty-message presentation (`show_empty_message`), notification phrasing, picker presentation for compare/checkout. Explicitly rank them and say why none blocks today.
3. **The mode seam contract** — the "lego" section. Document how a new comparison mode (PR, commit) plugs in *additively*: a lens identity (`diff/lens.lua`: shape predicate + `label_for` + `editable`), a collector branch (`source/collect.lua` resolves sides), and nothing else — winbar, sidebar, folds, session, and refusals all read the lens through `lens.of`/`lens.editable`/`lens.is_range`. State what a new mode must NOT do (no new state fields read outside the lens; no UI branching on mode id).
4. **Deferred-minors triage** — reproduce the pool from `.superpowers/sdd/progress.md:103` as a table with a decision per item: DONE-NOW (only `canvas_showing` dedup, Step 2, if it lands), or DEFERRED with the concrete trigger that would promote it (e.g. statuscol memoization ← "a 1000+-file changeset shows measured statuscolumn lag").

- [ ] **Step 2: The one candidate dedup — decide by looking**

The pool names "canvas_showing duplicated x4; export canvas.win_showing_canvas". Check: `grep -n "canvas_showing" lua/canvasdiff/App.lua`. If the four copies are textually identical checks of "is this window showing the canvas buffer", add to the canvas facade:

```lua
  win_showing_canvas = Canvas.win_showing_canvas,
```

implement it in `canvas/Canvas.lua` beside `is_canvas_buf` (same shape: take `st, win`, return boolean), replace the four inline copies in App with calls, and run the full suite. If the copies turn out to differ semantically (e.g. one also checks tab visibility), record that finding in the audit's triage table as the reason it stays deferred, and change nothing.

- [ ] **Step 3: Run the full suite**

Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test`
Expected: PASS (architecture suite covers the facade addition if Step 2 landed).

- [ ] **Step 4: Commit**

```bash
git add docs/research/2026-07-31-ghostty-architecture-audit.md lua/ test/
git commit -m "docs: ghostty-pattern architecture audit with deferred-minors triage"
```

---

## Final verification (after Task 7)

- [ ] `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` — every suite green.
- [ ] `grep -rn "merge-base(" README.md` — no breadcrumb *examples* left (semantic explanations fine).
- [ ] Open the canvas manually on this repo (`:CanvasDiff main..HEAD`): tinted winbar reading `READ-ONLY  main → HEAD`, help tail at the right edge, sidebar title with diffstat.
