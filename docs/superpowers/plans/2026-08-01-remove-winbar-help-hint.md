# Remove the Winbar Help Hint — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the right-aligned `%=<help-key> help` tail from the canvas winbar, reverting `W.text` to its two-parameter form, with tests and docs restored to their pre-tail shapes.

**Architecture:** A surgical revert of one feature inside `ui/winbar.lua` plus suffix-strips in three test files, one sentence removed from each of README and vimdoc, and two triage rows in the audit doc marked closed. No new code.

**Tech Stack:** Neovim Lua plugin; tests via `make test` (`make test SUITE=unit FILTER='^winbar_'` for the focused loop).

**Spec:** `docs/superpowers/specs/2026-08-01-remove-winbar-help-hint-design.md`

## Global Constraints

- The winbar keeps everything else from the read-only pass: the `%#CanvasDiffWinbar#`/`%#CanvasDiffWinbarReadOnly#` prefix and the `READ-ONLY  A → B` label (two spaces, ` → ` = space U+2192 space).
- The commit leaves `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` green (full suite).
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Remove the tail everywhere

**Files:**
- Modify: `lua/canvasdiff/ui/winbar.lua:9-58` (requires, `help_tail`, `W.text`)
- Test: `test/unit/test_winbar.lua` (delete 3 tests, strip 4 expectations)
- Test: `test/integration/test_root.lua:2608`
- Test: `test/e2e/test_e2e.lua:658,674`
- Modify: `README.md:103-104`
- Modify: `doc/canvasdiff.txt:136-138`
- Modify: `docs/research/2026-07-31-ghostty-architecture-audit.md:165-166`

**Interfaces:**
- Produces: `W.text(st, path) -> string` — two parameters again; output ends after the (optional) path, no `%=` section.

- [ ] **Step 1: Restore the pre-tail test expectations (failing first)**

In `test/unit/test_winbar.lua`:
- Delete the three tail tests entirely (names: `"winbar_ text ends with a right-aligned help tail when help is bound"`, `"winbar_ text has no tail when help is disabled"`, `"winbar_ a multi-bound help shows only its first key"`).
- Strip the suffix `%=<leader>lh help` from the four remaining expectations, leaving exactly:

```lua
  H.eq(winbar.text(st, nil), "%#CanvasDiffWinbar#HEAD → WORKTREE")
```
```lua
    "%#CanvasDiffWinbar#HEAD → WORKTREE · %<a.txt")
```
```lua
    "%#CanvasDiffWinbarReadOnly#READ-ONLY  a%%b → topic · %<100%%.txt")
```
```lua
    "%#CanvasDiffWinbarReadOnly#READ-ONLY  main → topic")
```

In `test/integration/test_root.lua:2608` the expected substring becomes:

```lua
      "%#CanvasDiffWinbarReadOnly#READ-ONLY  main → topic · %<a.txt", 1, true),
```

In `test/e2e/test_e2e.lua:658` and `:674` the expected strings become:

```lua
    H.eq(wb(), "%#CanvasDiffWinbar#HEAD → WORKTREE · %<aaa.txt",
```
```lua
    H.eq(wb(), "%#CanvasDiffWinbar#HEAD → WORKTREE · %<zzz.txt",
```

- [ ] **Step 2: Run to verify the strips fail against current code**

Run: `make test SUITE=unit FILTER='^winbar_'`
Expected: the four kept unit tests FAIL (actual output still carries `%=<leader>lh help`).

- [ ] **Step 3: Remove the tail from the module**

In `lua/canvasdiff/ui/winbar.lua`:
- Delete lines 10 and 12 (`local config = ...` and `local input = ...`) — only the tail used them.
- Delete the `help_tail` function and its doc comment (lines 35-46).
- Revert `W.text` to:

```lua
--- The breadcrumb: comparison on the left, the file under the topline after
--- it. `%<` truncates the path, never the comparison.
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

- [ ] **Step 4: Run the focused suite, then the full suite**

Run: `make test SUITE=unit FILTER='^winbar_'` — expected PASS (5 tests: 4 text + ensure_hl_groups).
Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` — expected PASS. If anything else still asserts the tail, `grep -rn '%=' test/` finds it.

- [ ] **Step 5: Docs**

- `README.md:103-104`: delete the sentence "Its right edge names the cheatsheet key (`<leader>lh help` by default); rebinding or disabling `help` moves or removes the reminder." (both lines; the bullet ends at "…also tints the bar.").
- `doc/canvasdiff.txt:136-138`: delete "The right edge names the cheatsheet key, `<leader>lh help` by default; it follows the configured `help` key and is absent when that key is disabled." — the paragraph ends at "…before the label is read." Re-wrap if needed to keep ≤78 columns.
- `docs/research/2026-07-31-ghostty-architecture-audit.md:165-166`: change both rows' decision from `DEFERRED` to `CLOSED` and the rationale to `Feature removed 2026-08-01 (help tail deleted); moot.` — keep the rows.

- [ ] **Step 6: Commit**

```bash
git add lua/canvasdiff/ui/winbar.lua test/unit/test_winbar.lua test/integration/test_root.lua test/e2e/test_e2e.lua README.md doc/canvasdiff.txt docs/research/2026-07-31-ghostty-architecture-audit.md
git commit -m "revert: drop the winbar help hint"
```

---

## Final verification

- [ ] `grep -rn 'help_tail\|%=.*help' lua/ test/ README.md doc/` — zero hits.
- [ ] Full suite green at the commit.
