# Visual Polish and Last-Lens Tier — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage markers on canvas file headers; a `highlight.diff` option (quiet derived tints / classic / gutter); scrollbar thumb dragging with a routing spike first; the in-memory last lens as a deliberate open-precedence tier.

**Architecture:** Markers reuse the sidebar's `stage_mark`/glyph/highlight machinery at the header render site in `canvas/format.lua`. The tint option lives in `ui/highlight.lua`'s group definitions plus a statuscolumn branch for gutter mode. Thumb dragging is hit-tested with `getmousepos()` from buffer-local mouse mappings whose home the spike decides; drag state lives on the scrollbar lease. The last-lens tier is a per-root table on App written at close and consulted in `App.open`'s precedence chain, replacing whatever leak produces today's accidental behavior.

**Tech Stack:** Neovim Lua; `make test`; the repo's luminance-measurement convention for all colour decisions.

**Spec:** `docs/superpowers/specs/2026-08-01-visual-polish-and-lens-tier-design.md`

## Global Constraints

- Every colour decision is measured under the builtin scheme and tokyonight-moon, numbers recorded in the commit body (repo convention; `--cmd 'set rtp+=~/.local/share/nvim/lazy/tokyonight.nvim'` gets tokyonight onto a `-l` runtimepath).
- All new/changed highlight groups stay `default = true`.
- Glyphs come from the live config glyph table (ASCII set must stay coherent).
- Ranges (READ-ONLY) never show stage state anywhere.
- Every commit leaves `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` green (full suite).
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Stage markers on file header bars

**Files:**
- Modify: `lua/canvasdiff/canvas/format.lua` — the expanded header builder (~:213, `("  (%d hunks, +%d …)")`), the folded placeholder builder (~:205), `marker_spans` (~:153, currently sidebar-shaped — read it fully; headers need the same byte-span discipline), `section_hl` (headers' highlight assembly)
- Read first: how the sidebar consumes `stage_mark` + `marker_spans` and how header highlights (CanvasDiffFileBar + CanvasDiffFileHeader) are applied — the marker groups must compose OVER the bar tint
- Test: `test/unit/test_model.lua` or the format-level test file that pins header strings (find it: `grep -rn '"▎' test/` and `grep -rn "hunks, +" test/`), plus a marker-span byte test mirroring the sidebar's
- Modify: `README.md` (the header-bar section + the marker table's "shows on the file's sidebar row too" sentence), `doc/canvasdiff.txt` (matching sentence)

**Interfaces:**
- Consumes: `R.stage_mark(staged, unstaged)` (format.lua:107), `GLYPHS.staged/unstaged/stale`, groups `CanvasDiffStaged/Unstaged/Stale/StaleEmphasis`, `section.staged`/`section.unstaged`/stale state (the folded placeholder already reads stale — follow its source for the expanded case).
- Produces: expanded headers `▎ path  (3 hunks, +12 −4) ●○` and folded placeholders `▸ path  (…) ●○ ●` (stage marks before the stale mark; stale stays last). Range lenses: no marks (mirror the sidebar's range behavior exactly — check what it does first and cite it in your report).

- [ ] **Step 1: Failing tests** — extend the header-string pins for staged-only, unstaged-only, mixed, and none; add a byte-span test for header marker highlights (model the sidebar's span test); add a range-lens no-marks test. Run; confirm failures.
- [ ] **Step 2: Implement** — thread the marks through both header builders and their highlight spans. Measure marker-vs-`Folded`-bg separation under both schemes (scratchpad lum script per repo convention); if any gap collapses below the sidebar's accepted floor, apply bold emphasis (attributes compose), not a new colour; record numbers in the commit body.
- [ ] **Step 3: Full suite**, README/vimdoc sentences, commit:
```bash
git add -A && git commit -m "feat: carry stage markers on canvas file headers"
```

---

### Task 2: `highlight.diff` — quiet / classic / gutter

**Files:**
- Modify: `lua/canvasdiff/ui/highlight.lua` (`ensure_hl_groups` and wherever `CanvasDiffAdd`/`CanvasDiffDel` defaults are defined — find them: `grep -rn "CanvasDiffAdd" lua/`)
- Modify: `lua/canvasdiff/config/settings.lua` (option `highlight.diff = "quiet"`, validation of the three values)
- Modify: `lua/canvasdiff/ui/status_column.lua` (gutter mode: per-row bar glyph in add/del foreground; read its expression builder first)
- Test: `test/unit/test_ui.lua` or the highlight test home (`grep -rn "CanvasDiffAdd" test/`), plus a statuscolumn test for gutter mode and a config-validation test for a bad value
- Modify: `README.md` ("How diff rows are coloured"), `doc/canvasdiff.txt`

**Interfaces:**
- Consumes: `nvim_get_hl` live values; the statuscolumn's existing per-line kind knowledge (it already distinguishes deletions — `·` handling).
- Produces: `config.options.highlight.diff` ∈ {quiet, classic, gutter}; a pure `blend(bg_a, bg_b, factor) -> hex` helper (unit-tested); gutter glyph from `GLYPHS` (add a `gutter` glyph slot defaulting to `▎`, ASCII `|` — extend the glyph table + its README block).

- [ ] **Step 1: Failing tests** — blend() unit cases (0%, 100%, mid, nil-bg fallbacks); quiet default produces a bg ≠ raw DiffAdd bg and ≠ Normal bg; classic links raw; gutter: statuscolumn string carries the glyph+group and NO CanvasDiffAdd row extmarks; invalid value reported via the settings diagnostics convention; gutter with `statuscolumn.enabled=false` warns once and behaves as quiet.
- [ ] **Step 2: Implement** — blend factor measurement per the spec (start 60% toward Normal; record token-luminance deltas for `@comment` and one bright token on tinted rows, both schemes, in the commit body). nil-bg edge: when DiffAdd/DiffDelete carries no bg under a scheme (builtin's DiffDelete case from the winbar work!), derive from a fixed fallback pair (green/red blended toward Normal) so quiet never renders invisible.
- [ ] **Step 3: Full suite**, docs, commit:
```bash
git add -A && git commit -m "feat: quiet derived diff tints with classic and gutter modes"
```

---

### Task 3: Spike — mouse routing over the non-focusable minimap

**Files:**
- Create: `spikes/2026-08-01-minimap-click-routing/` (README.md + minimal script), following the existing spikes' format (read one first)

**Interfaces:**
- Produces: a written answer Task 4 reads: which window receives `<LeftMouse>` when the pointer is over the non-focusable scrollbar float — the float or the canvas beneath — and therefore where Task 4's mappings live. Also: what `getmousepos()` reports over the float (winid, wincol), and whether `<LeftDrag>` keeps firing when the pointer leaves the original window during a drag.

- [ ] **Step 1:** Script: open a real canvas with the minimap in a headed-capable harness; register `<LeftMouse>`/`<LeftDrag>` mappings on BOTH the canvas and scrollbar buffers that log `getmousepos()`; use `nvim_input_mouse` (which CAN synthesize positional clicks headlessly — grid/row/col args) to click the bar column, the thumb, and a canvas column; record which mapping fired and every getmousepos payload.
- [ ] **Step 2:** Write the spike README: the routing answer, the getmousepos payloads, the `nvim_input_mouse` recipe Task 4's tests will reuse, and any surprises (e.g. clicks focusing the float despite focusable=false). Note explicitly what headless synthesis could NOT prove.
- [ ] **Step 3:** Commit:
```bash
git add spikes/ && git commit -m "spike: minimap click routing for thumb dragging"
```

---

### Task 4: Thumb dragging + track jumps

**Files:**
- Read FIRST: the Task 3 spike README — it decides where the mappings live.
- Modify: `lua/canvasdiff/ui/scrollbar.lua` (thumb geometry already computed for rendering — reuse it; drag state on the lease; the pure row→topline function), plus the mapping site the spike names
- Test: new `test/unit/test_scrollbar_drag.lua` (pure proportional function; unique basename) + integration tests in the scrollbar's existing test home using the spike's `nvim_input_mouse` recipe
- Modify: `README.md` (scrollbar paragraph), `doc/canvasdiff.txt`

**Interfaces:**
- Consumes: scrollbar lease + rendered thumb geometry; `vim.fn.getmousepos()`; `nvim_input_mouse` for tests.
- Produces: `S.locate(bar_row, bar_height, total_lines) -> topline` (pure, clamped); press-on-thumb arms drag, `<LeftDrag>` scrubs live, `<LeftRelease>` disarms; press-on-track jumps once; off-bar clicks fall through untouched (cursor placement + `<2-LeftMouse>` jump must keep working — pin both).

- [ ] **Step 1: Failing tests** — `S.locate` unit cases (top, bottom, mid, clamp both ends, 1-line canvas); integration: track click jumps viewport; drag sequence (press thumb, drag +N, release) moves topline proportionally; off-bar click leaves cursor placement working; double-click jump still works; a far scrub on a virtualized canvas lands on an auto-expanded section.
- [ ] **Step 2: Implement** per the spike's routing answer. Fall-through discipline: the mouse handlers return the key/behave as untouched for any position off the bar column (getmousepos hit-test first, always).
- [ ] **Step 3: Full suite**, docs, commit:
```bash
git add -A && git commit -m "feat: drag the minimap thumb to scrub the canvas"
```

---

### Task 5: The last-lens tier

**Files:**
- Modify: `lua/canvasdiff/App.lua` — the open precedence chain (anchor: "Load any saved session BEFORE collection") and `App:close` (record the lens); FIND AND REMOVE the existing leak (start from the test_root.lua pin added during the q-back-out work — its comment names the singleton behavior; trace where the reopened canvas's lens actually comes from today when session is disabled)
- Test: `test/integration/test_root.lua` (the pin becomes a rule test), `test/integration/test_lens.lua` or session tests for the tier ordering
- Modify: `README.md` (session section paragraph), `doc/canvasdiff.txt`

**Interfaces:**
- Consumes: `lens.normalize/valid`, the session precedence chain from the lens-lifecycle branch (including its `lens_from_session` fallback flag — the new tier must set/clear that flag correctly: a lens from tier 3 should ALSO fall back on dead refs, same as tier 4; decide and test).
- Produces: `App.last_lens_by_root[root]` written at close, read at open between explicit and session tiers. New chain: `opts.lens` > `opts.base` > in-memory last > session lens > session base > config default.

- [ ] **Step 1: Failing tests** — session disabled: close in `staged`, reopen → `staged`; explicit lens beats the memory; fresh App instance (no memory) with a session file → file wins; in-memory RANGE lens whose branch was deleted between close and reopen → falls back to default with the existing "no longer resolves" warning (extends the fallback flag to tier 3); update the test_root pin to assert the rule.
- [ ] **Step 2: Implement** — record in `App:close` (normalized copy), consult in the chain, extend the fallback gate (`lens_from_session` becomes "lens came from memory or session"), remove the old leak so exactly one mechanism exists (report what the leak was).
- [ ] **Step 3: Full suite**, docs, commit:
```bash
git add -A && git commit -m "feat: reopening a canvas returns to the lens it last showed"
```

---

## Final verification

- [ ] Full suite green at head.
- [ ] Manual smoke: headers show `●`/`○` matching the sidebar; `highlight.diff = "gutter"` shows bars and clean rows; thumb drag scrubs a 50-file canvas; close in `unstaged` + reopen (session off) lands in `unstaged`.
