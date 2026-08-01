# One-Look Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three-mode `highlight.diff` with one always-on rendering — neutral elevated field, green/red only in the margin, derived header bar, a focus-stable winbar band shared with the sidebar, and a sticky file-header float.

**Architecture:** All derived colours are authored in `canvas/format.lua` through the existing `set_diff_default` authorship machinery so user/scheme overrides always win. The statuscolumn bar and the row field render unconditionally (zero modes). The winbar loses the breadcrumb; a new `ui/sticky_header.lua` float (modeled on `ui/scrollbar.lua`'s lease pattern) pins the file header under the winbar.

**Tech Stack:** Neovim Lua plugin (`lua/canvasdiff/`), custom headless test harness (`make test`), no external dependencies.

**Spec:** `docs/superpowers/specs/2026-08-02-one-look-design.md` (amended version, commit 2c4cd2a).

## Global Constraints

- Run tests with `make test SUITE=<unit|integration|e2e|fault|architecture|performance> FILTER='<lua pattern against test names>'`; full suite is `make test`. Suite was 981/981 green at plan time (plus a known artifact: two tests fail under narrow FILTER slices but pass in the full suite — verify suspicious failures against the full suite before debugging).
- `WinScrolled`/`WinResized` NEVER fire headlessly. Tests drive update functions and autocmd callbacks by hand (existing scrollbar/winbar tests show the pattern).
- The test harness forbids duplicate test-file basenames across suite directories (architecture rule).
- Every `CanvasDiff*` group is defined with `default = true`; every COMPUTED default goes through `set_diff_default` in `lua/canvasdiff/canvas/format.lua` (authorship tracking — never raw `nvim_set_hl` for derived values).
- Glyphs are read live from `config.glyphs` and user-overridable; never hardcode a glyph or its byte length in spans — always `#config.glyphs.<name>` at render time.
- Measured constants: record the measurement numbers and the decision rule outcome in the commit body of the task that introduces them.
- Anti-reflow invariant: floats overlay content; they never push it.
- Commit messages end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Zero modes — delete `highlight.diff`, bars always on

**Files:**
- Modify: `lua/canvasdiff/config/settings.lua` (defaults ~line 178-188, `DIFF_MODES`/`diff_mode()`/latch lines 231-264, validation lines 349-353)
- Modify: `lua/canvasdiff/config.lua` (facade line 9: remove `diff_mode` export)
- Modify: `lua/canvasdiff/canvas/format.lua` (`row_group` lines 65-77, `ensure_diff_hl` lines 285-316)
- Modify: `lua/canvasdiff/ui/status_column.lua` (`M.render` lines 708-749)
- Test: `test/unit/test_config.lua`, `test/fault/test_status_column.lua`, `test/fault/test_highlight.lua`

**Interfaces:**
- Consumes: existing `config.setup(opts) -> options, diagnostics`, `REMOVED_ACTIONS` diagnostic pattern (settings.lua lines 279-301).
- Produces: `config.options.highlight` WITHOUT `diff`; `config.diff_mode` no longer exists anywhere; `settings.lua` gains a `REMOVED_OPTIONS` table + `removed_options(opts)` reporter; `format.row_group(kind)` always returns `HL_GROUP[kind]`; `status_column.render` always draws the bar cell. Later tasks rely on: bars render whenever the statuscolumn renders, and `ensure_diff_hl()` takes no mode branch.

- [ ] **Step 1: Write the failing tests**

In `test/unit/test_config.lua`, DELETE these tests (they pin the removed feature): `"config_ highlight.diff defaults to quiet"`, `"config_ highlight.diff rejects an unknown mode and falls back to quiet"`, `"config_ diff_mode downgrades gutter to quiet without the statuscolumn, warning once"`, `"config_ diff_mode reflects the configured mode"` (lines 213-263). Remove `"diff_mode"` from the facade-surface list at line 22. Keep `"config_ the gutter glyph ships in both glyph sets"`. Add:

```lua
T["config_ highlight.diff no longer exists as an option"] = function()
  H.eq(config.defaults.highlight.diff, nil)
  local options = config.setup({})
  H.eq(options.highlight.diff, nil)
end

T["config_ setting highlight.diff reports the removed option with its replacement"] = function()
  local options, diagnostics = config.setup({ highlight = { diff = "quiet" } })
  H.eq(#diagnostics, 1)
  assert(diagnostics[1]:match("highlight%.diff was removed"),
    "diagnostic must name the removed option, got: " .. diagnostics[1])
  assert(diagnostics[1]:match("override the CanvasDiff highlight groups"),
    "diagnostic must point at the replacement, got: " .. diagnostics[1])
  -- The stale key must not leak into the merged options either.
  H.eq(options.highlight.diff, nil)
  config.setup({})
end
```

In `test/fault/test_status_column.lua`, rewrite `"statuscol_ gutter mode carries a coloured bar on add and del rows"` (line 1656): delete the `config.setup({ highlight = { diff = "gutter" } })` call — the same assertions (`%%#CanvasDiffGutterAdd#▎%%*` etc., lines 1687-1706) must now hold under a plain default `config.setup({})`. Rename it `"statuscol_ the bar column renders on add, del and ghost rows by default"`. Any sibling test asserting the bar is ABSENT outside gutter mode gets deleted.

In `test/fault/test_highlight.lua` (mode tests around lines 1300-1440): delete the tests that pin `"classic"` restoring raw links and `"gutter"` dropping row tints. Keep `"hl_rows quiet default derives tints distinct from both DiffAdd and Normal"` — it still passes in this task (the quiet derivation becomes the unconditional branch here; Task 2 replaces its values).

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `make test SUITE=unit FILTER='config_'` and `make test SUITE=fault FILTER='statuscol_'`
Expected: the two new config tests FAIL (`highlight.diff` still defaults to `"quiet"`); the renamed statuscolumn test FAILS (no bar without gutter mode).

- [ ] **Step 3: Implement**

`lua/canvasdiff/config/settings.lua`:
- Delete `diff = "quiet"` (and its comment) from `M.defaults.highlight`.
- Delete `DIFF_MODES`, `warned_gutter_downgrade`, the whole `M.diff_mode()` function, the `warned_gutter_downgrade = false` reset in `setup()`, and the invalid-mode validation block (lines 346-353).
- Beside `REMOVED_ACTIONS`, add the option twin and its reporter, and call it from `setup()` right after the `removed_keymaps` loop:

```lua
-- Options that once existed and were removed, path -> replacement hint. Same
-- failure mode as REMOVED_ACTIONS: the override merges into an unused corner
-- of the options table and silently does nothing.
local REMOVED_OPTIONS = {
  ["highlight.diff"] = "the canvas now has one rendering; override the"
    .. ' CanvasDiff highlight groups instead -- see README "How diff rows'
    .. ' are coloured"',
}

--- One message per removed option present in `opts`, or nil.
local function removed_options(opts)
  local found = {}
  for path, hint in pairs(REMOVED_OPTIONS) do
    local node = opts
    for key in path:gmatch("[^.]+") do
      node = type(node) == "table" and node[key] or nil
    end
    if node ~= nil then
      found[#found + 1] = ("%s was removed -- %s"):format(path, hint)
    end
  end
  table.sort(found)
  return #found > 0 and found or nil
end
```

In `setup()`, after the removed-keymaps report and BEFORE the merge: report each removed-options message, then strip the key so it never lands in `M.options` (`if type(opts.highlight) == "table" then opts.highlight = vim.deepcopy(opts.highlight); opts.highlight.diff = nil end` — deepcopy first because `opts` belongs to the caller; note `M.user_opts` is captured BEFORE the strip so `:checkhealth` still sees what the user actually wrote).

`lua/canvasdiff/config.lua`: remove the `diff_mode = settings.diff_mode,` line.

`lua/canvasdiff/canvas/format.lua`: `row_group(kind)` becomes `return HL_GROUP[kind]` (delete the gutter branch and rewrite its comment: the bar and the field are two channels of one rendering now, not alternatives). In `ensure_diff_hl()`, delete the `local mode = config.diff_mode()` line and the `if mode == "classic"` branch — keep only the derive branch (unconditional) and the gutter-pair definitions. Update the doc comment: no modes; quiet derivation pending Task 2's palette.

`lua/canvasdiff/ui/status_column.lua` `M.render`: replace `local gutter = config.diff_mode() == "gutter"` with `local gutter = true` — then simplify: delete the variable and the `if gutter then` conditionals so the bar cell (`glyph`/`pad`) is always built and the bar branch is the only path. Update the function's doc comment (lines 704-707) and the module comment at line 20 of `config/settings.lua`'s glyph table (`-- the statuscolumn bar drawn beside add/del rows`).

- [ ] **Step 4: Run the touched suites, then the full suite**

Run: `make test SUITE=unit FILTER='config_'`, `make test SUITE=fault FILTER='statuscol_'`, `make test SUITE=fault FILTER='hl_'`, then `make test`
Expected: all PASS. Full suite catches stragglers still calling `config.diff_mode` (grep to be sure: `grep -rn "diff_mode" lua/ test/` must return nothing).

- [ ] **Step 5: Commit**

```bash
git add -A lua test
git commit -m "feat!: delete highlight.diff -- one rendering, bars always on"
```

---

### Task 2: The neutral field — derived palette values

**Files:**
- Modify: `lua/canvasdiff/canvas/format.lua` (constants lines 205-221, `ensure_diff_hl` — after Task 1 it is branch-free)
- Modify: `lua/canvasdiff/canvas/Canvas.lua` (`ensure_hl_groups` line ~57: delete the `CanvasDiffGhost` default — format authors it now)
- Test: `test/fault/test_highlight.lua`

**Interfaces:**
- Consumes: `R.blend(bg_a, bg_b, factor)` (format.lua line 190 — channelwise RGB lerp, nil-tolerant), `set_diff_default(group, spec)` (line 253).
- Produces: `ensure_diff_hl()` defines, all via `set_diff_default`: `CanvasDiffAdd` = `{ bg = <elevation> }`; `CanvasDiffDel` = `{ bg = <elevation>, fg = <ghost dim fg> }` (the dimmed fg is what a wholly-deleted file's real `-` rows read with — the only rows that resolve `CanvasDiffDel`); `CanvasDiffGhost` = `{ fg = <ghost dim fg> }` (NO bg, no longer linked to `CanvasDiffDel`); `CanvasDiffPrefixAdd`/`CanvasDiffPrefixDel` = `{ fg = <hue fg> }`; `CanvasDiffGutterAdd`/`CanvasDiffGutterDel` = `{ fg = <same hue fg> }` (replacing the `Added`/`Removed` links). Module-level constants `ELEVATION_FACTOR`, `ELEVATION_FALLBACK_BG`, `GHOST_DIM_FACTOR`, `HUE_FALLBACK_FG = { add = 0x2ea043, del = 0xdb4444 }`. Task 3 puts the Prefix groups on cells; Task 4 reuses the derive helper for the bar.

- [ ] **Step 1: Measure the factors**

Write `/tmp/claude-1000/-home-reklai-coding-personal-neovim-finding-myself/2153b68e-d7e3-4bc2-ae55-0d8ce7098467/scratchpad/measure_palette.lua` (scratch, not committed):

```lua
-- Rec.709 luma over live highlight groups, per candidate factor.
local function luma(rgb)
  if not rgb then return nil end
  local r = math.floor(rgb / 65536) % 256
  local g = math.floor(rgb / 256) % 256
  local b = rgb % 256
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end
local function hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end
local function blend(a, b, f)
  local function ch(shift)
    local x = math.floor(a / shift) % 256
    local y = math.floor(b / shift) % 256
    return math.floor(x + (y - x) * f + 0.5)
  end
  return ch(65536) * 65536 + ch(256) * 256 + ch(1)
end
local function report(scheme)
  local normal = hl("Normal")
  local dark = vim.o.background == "dark"
  local pole = dark and 0xffffff or 0x000000
  local nb = normal.bg or (dark and 0x000000 or 0xffffff)
  local base = luma(nb)
  print(("== %s (background=%s) Normal bg L=%.1f fg L=%.1f"):format(
    scheme, vim.o.background, base, luma(normal.fg or pole)))
  print(("CursorLine dL=%.1f  Folded dL=%.1f  Visual dL=%.1f"):format(
    (luma(hl("CursorLine").bg or nb) or base) - base,
    (luma(hl("Folded").bg or nb) or base) - base,
    (luma(hl("Visual").bg or nb) or base) - base))
  -- Yesterday's quiet tint, for the "must land below it" ceiling.
  local da = hl("DiffAdd").bg or 0x2ea043
  print(("quiet-tint dL=%.1f"):format(luma(blend(da, nb, 0.6)) - base))
  for _, f in ipairs({ 0.06, 0.08, 0.10, 0.12, 0.16, 0.20, 0.24 }) do
    print(("factor %.2f  elevation dL=%+.1f"):format(
      f, luma(blend(nb, pole, f)) - base))
  end
  -- Ghost dim candidates vs the @comment readability floor.
  local comment = hl("@comment").fg or hl("Comment").fg
  print(("@comment dL=%.1f"):format(luma(comment) - base))
  local nf = normal.fg or pole
  for _, f in ipairs({ 0.30, 0.35, 0.40, 0.45, 0.50 }) do
    print(("dim %.2f  ghost-fg dL=%.1f"):format(f, luma(blend(nf, nb, f)) - base))
  end
  -- Syntax-token budget probe (QUIET_FACTOR's method): token contrast ON the
  -- elevation vs on Normal, for the elevation candidate you pick.
  for _, tok in ipairs({ "@comment", "Function", "String" }) do
    local fg = hl(tok).fg or hl("Comment").fg
    print(("%s fg L=%.1f"):format(tok, luma(fg)))
  end
end
report("current")
```

Run it under the builtin scheme and tokyonight-moon (`nvim --headless` WITHOUT `--clean` so the user's plugins are on the packpath; `pcall(vim.cmd.colorscheme, "tokyonight-moon")` between reports — if unavailable, record builtin-only and say so in the commit body):

```bash
nvim --headless "+lua vim.cmd('colorscheme default')" "+luafile <scratchpad>/measure_palette.lua" "+lua pcall(vim.cmd.colorscheme, 'tokyonight-moon')" "+luafile <scratchpad>/measure_palette.lua" +q
```

Decision rules (apply to BOTH schemes; a candidate must satisfy every rule under both):
- `ELEVATION_FACTOR` (amended 2026-08-02, user ruling — the original "between CursorLine and the quiet tints" interval measured EMPTY): the LARGEST candidate on the grid 0.03-0.10 step 0.01 such that, under EACH measured scheme, the worst probed token's (`@comment`, `Function`, `String`) contrast loss on the elevated bg is ≤ that scheme's OLD quiet-tint worst-token loss (compute the old quiet tint per scheme with the pre-Task-2 formula: DiffAdd/DiffDelete bg blended 0.6 toward Normal; contrast loss = relative change in `|luma(tok) - luma(bg)|`). No CursorLine clause. For tokyonight-moon, measure the STOCK scheme (transparency disabled) — the user's transparent setup has no Normal bg and exercises the fallback constant instead.
- `GHOST_DIM_FACTOR`: the LARGEST candidate whose ghost-fg `|dL|` against Normal bg is still ≥ `@comment`'s `|dL|` (a ghost must never read dimmer than a comment).
- Record every number and the chosen factors in this task's commit body.

- [ ] **Step 2: Write the failing tests**

In `test/fault/test_highlight.lua`, replace the remaining quiet-derivation test (`"hl_rows quiet default derives tints distinct from both DiffAdd and Normal"`) with the neutral-field pins. Add a file-local luma helper (same 6-line function as the script). New tests:

```lua
T["hl_rows the field is one neutral elevation shared by add and del"] = function()
  reset_diff_groups()  -- see note below
  render.ensure_diff_hl()
  local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false })
  local del = vim.api.nvim_get_hl(0, { name = "CanvasDiffDel", link = false })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  H.eq(add.bg, del.bg, "one elevation, not two hues")
  assert(add.bg ~= normal.bg, "the elevation must differ from Normal")
  local diff_add = vim.api.nvim_get_hl(0, { name = "DiffAdd", link = false })
  assert(add.bg ~= diff_add.bg, "the elevation is not the scheme's diff wash")
  assert(add.fg == nil, "add rows keep full-contrast syntax")
  assert(del.fg ~= nil, "a deleted file's real rows read dimmed")
end

T["hl_rows ghosts have no background and a dimmed foreground"] = function()
  reset_diff_groups()
  render.ensure_diff_hl()
  local ghost = vim.api.nvim_get_hl(0, { name = "CanvasDiffGhost", link = false })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  H.eq(ghost.bg, nil)
  assert(ghost.fg and ghost.fg ~= normal.fg, "dimmed, not Normal's own fg")
end

T["hl_rows margin hue lives on the prefix and gutter groups, identically"] = function()
  reset_diff_groups()
  render.ensure_diff_hl()
  for _, pair in ipairs({
    { "CanvasDiffPrefixAdd", "CanvasDiffGutterAdd" },
    { "CanvasDiffPrefixDel", "CanvasDiffGutterDel" },
  }) do
    local prefix = vim.api.nvim_get_hl(0, { name = pair[1], link = false })
    local gutter = vim.api.nvim_get_hl(0, { name = pair[2], link = false })
    assert(prefix.fg, pair[1] .. " must carry a foreground")
    H.eq(prefix.fg, gutter.fg, "prefix and bar are the same statement")
    H.eq(prefix.bg, nil)
  end
  local ga = vim.api.nvim_get_hl(0, { name = "CanvasDiffGutterAdd", link = true })
  H.eq(ga.link, nil, "no longer a link to Added")
end

T["hl_rows a user's pre-defined group survives the derivation"] = function()
  reset_diff_groups()
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", { bg = 0x123456 })
  render.ensure_diff_hl()
  local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false })
  H.eq(add.bg, 0x123456, "an explicit override always wins")
  reset_diff_groups()
end
```

`reset_diff_groups()`: a file-local helper that clears every group this file probes (`for _, g in ipairs({...}) do vim.api.nvim_set_hl(0, g, {}) end`) — the singleton `applied_diff_hl` record means earlier tests' definitions would otherwise satisfy `set_diff_default` and mask a broken derive. If the file already has such a helper, reuse it.

- [ ] **Step 3: Run tests to verify they fail**

Run: `make test SUITE=fault FILTER='hl_rows'`
Expected: FAIL — `CanvasDiffAdd`/`Del` still carry the hued quiet tints; the Prefix groups don't exist.

- [ ] **Step 4: Implement in `format.lua`**

Replace `QUIET_FACTOR` and `QUIET_FALLBACK_BG` (lines 205-221) with the measured constants (comments must state the decision rule and the measured numbers, in the style of the existing `QUIET_FACTOR` comment):

```lua
-- <measured, from Step 1 — replace 0.08/0.40 with the chosen values>
local ELEVATION_FACTOR = 0.08
local GHOST_DIM_FACTOR = 0.40
-- When a transparent scheme gives Normal no background there is nothing to
-- elevate from; a fixed near-Normal pair keeps the field visible.
local ELEVATION_FALLBACK_BG = { dark = 0x2c2c2c, light = 0xe4e4e4 }
-- The margin's green/red when the scheme's DiffAdd/DiffDelete carry no
-- foreground (bg-only diff groups are the common case). Never derived from
-- their bg: those are bg-tuned colours and read as mud when used as fg.
local HUE_FALLBACK_FG = { add = 0x2ea043, del = 0xdb4444 }
```

Rewrite `ensure_diff_hl()` (keep the name; keep every definition going through `set_diff_default`; keep the readback-shaped specs — numeric `bg`/`fg`, `default = true`):

```lua
function R.ensure_diff_hl()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local dark = vim.o.background == "dark"
  local pole = dark and 0xffffff or 0x000000
  local anti_pole = dark and 0x000000 or 0xffffff
  local normal_bg = normal.bg
    or ELEVATION_FALLBACK_BG[dark and "dark" or "light"]
  local elevation = tonumber(
    R.blend(normal_bg, pole, ELEVATION_FACTOR):sub(2), 16)
  local ghost_fg = tonumber(
    R.blend(normal.fg or pole, normal.bg or anti_pole, GHOST_DIM_FACTOR)
      :sub(2), 16)

  set_diff_default("CanvasDiffAdd", { bg = elevation, default = true })
  set_diff_default("CanvasDiffDel",
    { bg = elevation, fg = ghost_fg, default = true })
  set_diff_default("CanvasDiffGhost", { fg = ghost_fg, default = true })

  for kind, groups in pairs({
    add = { "CanvasDiffPrefixAdd", "CanvasDiffGutterAdd" },
    del = { "CanvasDiffPrefixDel", "CanvasDiffGutterDel" },
  }) do
    local source = vim.api.nvim_get_hl(0, {
      name = kind == "add" and "DiffAdd" or "DiffDelete",
      link = false,
    })
    local hue = source.fg or HUE_FALLBACK_FG[kind]
    for _, group in ipairs(groups) do
      set_diff_default(group,
        { fg = hue, ctermfg = source.ctermfg, default = true })
    end
  end
end
```

Carry a doc comment explaining the three channels (elevation = changed, dimming = removed, margin hue = direction) and why `CanvasDiffDel` carries the dim fg (it only ever resolves on a wholly-deleted file's real rows — every other deletion is a ghost). In `lua/canvasdiff/canvas/Canvas.lua` `ensure_hl_groups`, delete the `CanvasDiffGhost` default (line ~57) and its comment — format authors the group now; keep the `render.ensure_diff_hl()` call.

- [ ] **Step 5: Run tests to verify they pass, then the full suite**

Run: `make test SUITE=fault FILTER='hl_rows'`, then `make test`
Expected: PASS. Full-suite watchpoints: any test pinning `CanvasDiffGhost`'s link to `CanvasDiffDel`, or pinning the old gutter links (`Added`/`Removed`) — update those pins to the new derived shapes.

- [ ] **Step 6: Commit (measurement numbers in the body)**

```bash
git add -A lua test
git commit -m "feat: neutral field palette -- elevation, dimmed ghosts, margin hue"
```

---

### Task 3: Prefix-cell spans and two-chunk ghosts

**Files:**
- Modify: `lua/canvasdiff/canvas/format.lua` (`R.section_hl` line 416, `R.ghost_lines` line 404)
- Modify: `lua/canvasdiff/canvas/Canvas.lua` (mark-drawing loop lines 219-226)
- Modify: `lua/canvasdiff/canvas/paged.lua` (`style_for` lines 68-79)
- Modify: `lua/canvasdiff/canvas/Projection.lua` (decorator consumption lines 626-656)
- Test: `test/unit/test_model.lua`, `test/integration/test_projection.lua`

**Interfaces:**
- Consumes: Task 2's `CanvasDiffPrefixAdd`/`CanvasDiffPrefixDel` groups; `PREFIX = GLYPHS` (format.lua line 9, so `PREFIX.add`/`PREFIX.del` are the live glyphs).
- Produces: `R.section_hl(section)` marks gain an optional span form `{ row, group, end_col }` (present ⇒ highlight bytes `[0, end_col)` instead of the whole row); paged `style_for` answers gain optional `prefix_hl` (string) + `prefix_len` (byte count); `R.ghost_lines` chunks become `{ { prefix, "CanvasDiffPrefixDel" }, { content, "CanvasDiffGhost" } }`.

- [ ] **Step 1: Write the failing tests**

`test/unit/test_model.lua` — update the ghost pin at line 279 and the section_hl pin at line 287, and add prefix-span coverage (adapt the surrounding tests' fixture `s`; the shapes below are the contract):

```lua
-- ghost_lines: prefix and content are separate chunks so the margin hue
-- reaches ghosts too.
H.eq(render.ghost_lines(s.entries[4]),
  { { { "-", "CanvasDiffPrefixDel" }, { "b", "CanvasDiffGhost" } } })

-- section_hl: each add/del row yields its field mark AND a prefix span.
-- (Exact indices depend on the fixture; assert the SHAPE like this:)
local hl = render.section_hl(s)
local row_marks, prefix_marks = {}, {}
for _, m in ipairs(hl) do
  if m.end_col then prefix_marks[#prefix_marks + 1] = m
  else row_marks[#row_marks + 1] = m end
end
H.eq(prefix_marks[1].group, "CanvasDiffPrefixAdd")
H.eq(prefix_marks[1].end_col, #"+")
H.eq(prefix_marks[1].row, row_marks[1].row,
  "the prefix span sits on its own row's field mark")
```

`test/integration/test_projection.lua` — find the existing decorator test (grep `decorate` in that file) and add one that answers a style with `prefix_hl = "CanvasDiffPrefixAdd", prefix_len = 1` and asserts the drawn ephemeral extmark's `virt_text` is two chunks: `{ { "+", "CanvasDiffPrefixAdd" }, { rest, text_hl } }` (follow that file's existing pattern for capturing what the provider draws — it already asserts `virt_text` shapes).

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test SUITE=unit FILTER='model'` and `make test SUITE=integration FILTER='projection'`
Expected: FAIL — single-chunk ghosts, no `end_col` marks, single-chunk overlay.

- [ ] **Step 3: Implement**

`format.lua` `R.ghost_lines`: build each line as two chunks — `{ PREFIX.del, "CanvasDiffPrefixDel" }, { g.content or "", "CanvasDiffGhost" }`. Update its doc comment (the prefix keeps column alignment AND now carries the margin hue).

`format.lua`: one exported resolver so the group table and glyph lengths live in this module only, used by BOTH canvases:

```lua
local PREFIX_GROUP = { add = "CanvasDiffPrefixAdd", del = "CanvasDiffPrefixDel" }

--- The margin-hue group and byte length of an entry's prefix cell, or nil
--- for kinds whose prefix carries no hue (context, headers, binary).
function R.prefix_hl(entry)
  local group = entry and PREFIX_GROUP[entry.kind] or nil
  if not group then
    return nil
  end
  return group, #PREFIX[entry.kind]
end
```

`R.section_hl`: after appending an add/del row's field mark, append the prefix span:

```lua
-- inside the loop, alongside the existing row mark:
local prefix_group, prefix_len = R.prefix_hl(e)
if prefix_group then
  marks[#marks + 1] = { row = i - 1, group = prefix_group, end_col = prefix_len }
end
```

`Canvas.lua` draw loop (lines 219-226): when `m.end_col` is present, place the mark with `end_col = m.end_col` on the SAME row (not `end_row = row + 1`) and `priority = 110` (above the field's 100 so the hue wins the cell); otherwise unchanged.

`paged.lua` `style_for`: for entries where `render.prefix_hl(entry)` answers, set `style.prefix_hl, style.prefix_len` from its two return values.

`Projection.lua` (lines 636-656): read `prefix_hl` (string) and `prefix_len` (number, `1 <= prefix_len <= #row-text`, else ignore — decorator answers are contained per row, matching the file's defensive style, and an out-of-range length falls back to the single chunk). (Amended 2026-08-02: originally strict `<`, which dropped the hue on prefix-only rows — added blank lines are routine, and the spec's margin-hue rule has no blank-line exception; `nvim_buf_set_extmark` accepts an empty-string second chunk, verified.) When valid:

```lua
virt_text = {
  { STRING_SUB(rows[index], 1, prefix_len), prefix_hl },
  { STRING_SUB(rows[index], prefix_len + 1), text_hl },
},
```

(Match the file's upvalued-builtins style — it upcases its imports like `RAWGET`/`SET_EXTMARK`; add `STRING_SUB` beside them.)

- [ ] **Step 4: Run tests, then the full suite**

Run: `make test SUITE=unit FILTER='model'`, `make test SUITE=integration FILTER='projection'`, then `make test`
Expected: PASS. Watchpoint: any test pinning `ghost_lines`' one-chunk shape or counting extmarks per row (the eager canvas now places one more mark per add/del row).

- [ ] **Step 5: Commit**

```bash
git add -A lua test
git commit -m "feat: margin hue on prefix cells and ghost prefixes, both canvases"
```

---

### Task 4: Derived file-header bar

**Files:**
- Modify: `lua/canvasdiff/canvas/format.lua` (`ensure_diff_hl` — add the bar derivation; a new `BAR_FACTOR` constant)
- Modify: `lua/canvasdiff/canvas/Canvas.lua` (`ensure_hl_groups` line 45: delete the `Folded` link + rewrite the comment)
- Test: `test/fault/test_highlight.lua`

**Interfaces:**
- Consumes: Task 2's derive helpers/constants and the measurement script.
- Produces: `CanvasDiffFileBar` authored by `ensure_diff_hl` as `{ bg = <bar elevation> }` where the bar's luma delta clears the row elevation's by a measured margin. `CanvasDiffFileHeader` (fg, `Title` link) unchanged. Paged `FILE_BAR_GROUP` name unchanged. Task 7's sticky row inherits this bar automatically.

- [ ] **Step 1: Extend the measurement**

Re-run the Step-1 script from Task 2 (it already prints elevation candidates at 0.12-0.24 and CursorLine/Folded/Visual deltas). Decision rules, both schemes:
- `BAR_FACTOR`: the smallest candidate where `|bar dL| ≥ |elevation dL| + 10` (the bar must clear the FIELD, not just Normal).
- Title-tint decision: if the chosen bar's luma lands within 8 of CursorLine's or Visual's bg luma under either scheme (it would read as "just another cursor line"), blend the bar 15% toward `Title`'s fg and re-check; record the decision either way.
- Stage markers: record `|luma(marker fg) - luma(bar bg)|` for `CanvasDiffStaged` (`Added` fg), `CanvasDiffUnstaged` (`DiagnosticWarn` fg), `CanvasDiffStale` (`DiagnosticError` fg). No code change expected — the pair that matters is staged-vs-stale LUMA SEPARATION (was 138 vs `Folded`); flag in the commit body if the new bar collapses any gap below what `Folded` gave.

- [ ] **Step 2: Write the failing tests**

In `test/fault/test_highlight.lua`:

```lua
T["hl_bar the header bar is derived, not Folded's luck"] = function()
  reset_diff_groups()  -- include CanvasDiffFileBar in the helper's group list
  render.ensure_diff_hl()
  local bar = vim.api.nvim_get_hl(0, { name = "CanvasDiffFileBar", link = true })
  H.eq(bar.link, nil, "no longer linked to Folded")
  assert(bar.bg, "the bar is a background statement")
end

T["hl_bar the bar clears the row elevation, which clears Normal"] = function()
  reset_diff_groups()
  render.ensure_diff_hl()
  local normal = luma(vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg or 0)
  local field = luma(vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false }).bg)
  local bar = luma(vim.api.nvim_get_hl(0, { name = "CanvasDiffFileBar", link = false }).bg)
  assert(math.abs(field - normal) > 0, "sanity: the field is elevated")
  assert(math.abs(bar - normal) > math.abs(field - normal),
    "the bar must clear the field, not just Normal")
end
```

(Assert the RELATIONSHIP, never raw numbers — the spec's test rule.)

- [ ] **Step 3: Run tests to verify they fail**

Run: `make test SUITE=fault FILTER='hl_bar'`
Expected: FAIL — `CanvasDiffFileBar` still links `Folded`.

- [ ] **Step 4: Implement**

`format.lua`: add `local BAR_FACTOR = <measured>` beside `ELEVATION_FACTOR` (comment: the rule and numbers; if the Title tint was taken, the extra `R.blend(bar, title_fg, 0.15)` step and why). In `ensure_diff_hl()` add, after the field groups:

```lua
  local bar = tonumber(R.blend(normal_bg, pole, BAR_FACTOR):sub(2), 16)
  set_diff_default("CanvasDiffFileBar", { bg = bar, default = true })
```

`Canvas.lua` `ensure_hl_groups`: delete the `CanvasDiffFileBar` `Folded` link (line 45) and fold its measurement story into a pointer comment ("authored in render.ensure_diff_hl with the other derived values").

- [ ] **Step 5: Run tests, then the full suite**

Run: `make test SUITE=fault FILTER='hl_bar'`, then `make test`
Expected: PASS. Watchpoint: any test pinning the `Folded` link.

- [ ] **Step 6: Commit (numbers + Title-tint and marker-gap decisions in the body)**

```bash
git add -A lua test
git commit -m "feat: derive the file-header bar instead of borrowing Folded"
```

---

### Task 5: The unified top band

**Files:**
- Modify: `lua/canvasdiff/ui/winbar.lua` (`W.text` lines 35-43)
- Modify: `lua/canvasdiff/ui/sidebar.lua` (`sidebar_title` line 146, `update_winbar` line 242)
- Modify: `lua/canvasdiff/App.lua` (`path_under_top` lines 761-773 — DELETE; `set_winbar` lines 775-788; call sites at lines 964, 1069, 1081, 1404, 1411)
- Test: `test/unit/test_winbar.lua`, `test/integration/test_sidebar.lua`, `test/e2e/test_e2e.lua`

**Interfaces:**
- Consumes: existing `CanvasDiffWinbar`/`CanvasDiffWinbarReadOnly` groups (winbar.lua lines 28-31 — unchanged), `W.apply`/`W.clear` bookkeeping (unchanged).
- Produces: `W.text(st)` — ONE parameter, returns `"%#CanvasDiffWinbar#<label>"` (or the ReadOnly group for a range lens), never a path. Sidebar winbar becomes `"%#CanvasDiffWinbar#" .. title`. App's `set_winbar(st, text, win)` loses its `path` parameter; `path_under_top` is gone (Task 7's sticky module owns topline resolution). Callers of `W.text` with a second argument do not exist after this task.

- [ ] **Step 1: Write the failing tests**

`test/unit/test_winbar.lua`: delete the two path tests (`"winbar_ text appends the truncatable path…"`, and the path half of the escape test); update the rest:

```lua
T["winbar_ text is the comparison label alone, band-tinted"] = function()
  local st = { lens = lens.get("all") }
  H.eq(winbar.text(st), "%#CanvasDiffWinbar#HEAD → WORKTREE")
end

T["winbar_ text escapes percent signs in refs"] = function()
  local st = { lens = lens.range("a%b", "topic", "..") }
  H.eq(winbar.text(st), "%#CanvasDiffWinbarReadOnly#READ-ONLY  a%%b → topic")
end
```

(Keep the range-tint and ensure_hl_groups tests as they are — they already pass a nil path / no path.)

`test/integration/test_sidebar.lua`: every `sidebar_winbar(lease)` pin (lines 274, 357-359, 487, 502) gains the prefix, e.g. `"%#CanvasDiffWinbar#Files changed (3)  +18 −18"`.

`test/e2e/test_e2e.lua` (lines 658, 674): the winbar no longer changes when scrolling between files — both pins become `"%#CanvasDiffWinbar#HEAD → WORKTREE"`. If the surrounding test's point was the path swap, repoint the test at the label's stability (the sticky row's swap is Task 7's test).

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test SUITE=unit FILTER='winbar_'`, `make test SUITE=integration FILTER='sidebar'`
Expected: FAIL — the path separator is still appended; the sidebar title has no group.

- [ ] **Step 3: Implement**

`winbar.lua` `W.text(st)`: drop the `path` parameter, the `if not path` branch and the `" · %<"` tail — return the tinted label only. Rewrite the doc comment: the winbar is the app half of the top band; the file half lives on the sticky header row (ui/sticky_header.lua). Module header comment (lines 1-7) updates too — no more "breadcrumb".

`sidebar.lua` `update_winbar`: `local title = "%#CanvasDiffWinbar#" .. sidebar_title(lease.state)` and call `require("canvasdiff.ui.winbar").ensure_hl_groups()` first (domain-internal import, the sidebar→notifications precedent; require at module top, not per call). Note beside it: the group paints the bar identically whether or not the window has focus — that is the point; and `sidebar_title` produces no `%`, so no escaping is needed (counts and a fixed prefix only).

`App.lua`: delete `path_under_top`; `set_winbar(st, text, win)` drops `path or path_under_top(...)` (just `text = ui.winbar.text(st)` when nil); fix the call sites — line 1081 currently passes a 4th `path` argument, drop it; the others pass nil-path already. KEEP the `WinScrolled` autocmd block (lines 1563-1578) — its `capture_view` is load-bearing for session state even though the winbar text no longer varies with scroll; update its comment (lines 1551-1562): the sticky filename now lives on the sticky header row; this hook remains for view capture and winbar refresh on window changes.

- [ ] **Step 4: Run tests, then the full suite**

Run: `make test SUITE=unit FILTER='winbar_'`, `make test SUITE=integration FILTER='sidebar'`, `make test SUITE=e2e`, then `make test`
Expected: PASS. Watchpoints: `test/fault/chaos_surface.lua` and `test/integration/test_lifecycle.lua` reference winbars — update any full-string pins to the new label-only text.

- [ ] **Step 5: Commit**

```bash
git add -A lua test
git commit -m "feat: one focus-stable top band across sidebar and canvas winbars"
```

---

### Task 6: Sticky header content (pure core)

**Files:**
- Create: `lua/canvasdiff/ui/sticky_header.lua`
- Modify: `lua/canvasdiff/ui.lua` (facade: add `sticky_header`)
- Test: `test/unit/test_sticky_content.lua` (new — basename is unique across suites)

**Interfaces:**
- Consumes: `canvas.locate(st, row0) -> index, offset` (1-based section index, 1-based entry offset), `fold.hidden(st, path)`, `render.section_line(section, 1)` (the file_hdr line), `render.marker_spans(line, staged, unstaged, stale)` (format.lua line 334).
- Produces: `SH.content(st, top0) -> nil | { line = string, spans = { {start_col, end_col, group}, ... } }` — nil means "show nothing" (empty canvas, header row itself at the top, folded placeholder at the top, or nothing resolvable). Task 7 renders exactly this answer.

- [ ] **Step 1: Write the failing tests**

`test/unit/test_sticky_content.lua` (build states with `model.build_section` + `canvas` the way `test/unit/test_model.lua` does; the essential cases):

```lua
local H = require("helpers")
local sticky = require("canvasdiff.ui").sticky_header
local canvas = require("canvasdiff.canvas")
local render = canvas.format
local model = require("canvasdiff.diff").model

local function two_file_state()
  -- Two small sections; section 1 occupies rows 0..N-1, section 2 starts at N.
  -- Build the state exactly the way an existing canvas.locate consumer's tests
  -- do: test/fault/test_status_column.lua and test/integration/test_scrollbar.lua
  -- both construct real canvas states (model.build_section + the canvas open
  -- helper) and then resolve rows through canvas.locate -- copy that fixture
  -- shape rather than inventing a hand-rolled st table, so locate/fold see the
  -- invariants they expect.
end

T["sticky_ content mid-file answers that file's own header line and spans"] = function()
  local st = two_file_state()
  local got = sticky.content(st, 2)  -- topline two rows into section 1
  local section = st.sections[1]
  H.eq(got.line, render.section_line(section, 1))
  H.eq(got.spans,
    render.marker_spans(got.line, section.staged, section.unstaged, false))
end

T["sticky_ content is nil when the header row itself is the topline"] = function()
  local st = two_file_state()
  H.eq(sticky.content(st, 0), nil)
end

T["sticky_ content swaps at the section boundary"] = function()
  local st = two_file_state()
  local boundary = st.section_rows or nil -- resolve section 2's start row from the fixture
  H.eq(sticky.content(st, boundary + 1).line,
    render.section_line(st.sections[2], 1))
end

T["sticky_ content is nil on an empty canvas and off the end"] = function()
  H.eq(sticky.content({ sections = {} }, 0), nil)
end

T["sticky_ content is nil when the section under the top is folded"] = function()
  local st = two_file_state()
  -- collapse section 1 via canvas.set_collapsed, then its placeholder row IS
  -- the header: nothing to pin.
  H.eq(sticky.content(st, 0), nil)
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test SUITE=unit FILTER='sticky_'`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement the pure core**

`lua/canvasdiff/ui/sticky_header.lua`:

```lua
-- The sticky file-header row: a one-row float pinned under the winbar that
-- mirrors the in-buffer header of the section under the topline. This half
-- is pure: given a state and a 0-based topline, what (if anything) should
-- the row show. The float half arrives with open/update/close below.
local canvas = require("canvasdiff.canvas")
local render = canvas.format
local fold = require("canvasdiff.diff").fold

local SH = {}

--- nil = show nothing: empty canvas, nothing resolvable, a folded
--- placeholder (that single row IS the header), or the real header row
--- sitting exactly at the top -- pinning a copy over the original would
--- double it.
function SH.content(st, top0)
  if type(st) ~= "table" or type(st.sections) ~= "table"
      or #st.sections == 0 then
    return nil
  end
  local index, offset = canvas.locate(st, top0)
  local section = index and st.sections[index] or nil
  if not section then
    return nil
  end
  if fold.hidden(st, section.path) or offset == 1 then
    return nil
  end
  local line = render.section_line(section, 1)
  if not line then
    return nil
  end
  return {
    line = line,
    -- Never a stale span: the pinned section is on screen, and fold.stale
    -- is false by construction for anything you can see (the same reason
    -- the expanded in-buffer header carries none).
    spans = render.marker_spans(line, section.staged, section.unstaged, false),
  }
end

return SH
```

Add `sticky_header = require("canvasdiff.ui.sticky_header")` to the `ui.lua` facade (alphabetical slot, matching the file's style).

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test SUITE=unit FILTER='sticky_'` and `make test SUITE=architecture` (the facade change must satisfy the architecture suite's import rules)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A lua test
git commit -m "feat: sticky header content resolution (pure core)"
```

---

### Task 7: Sticky header float, lease, and wiring

**Files:**
- Modify: `lua/canvasdiff/ui/sticky_header.lua` (add the float lifecycle)
- Modify: `lua/canvasdiff/App.lua` (open wiring after the scrollbar block ~line 1550; `refresh_winbars` line 794; `sync_after_collapse` line 829)
- Modify: `lua/canvasdiff/Surface.lua` (teardown list ~line 423: add `sticky.close` beside `scrollbar.close`)
- Test: `test/integration/test_sticky_header.lua` (new — basename unique: the unit file is `test_sticky_content.lua`)

**Interfaces:**
- Consumes: `SH.content` (Task 6); the scrollbar lease pattern (`ui/scrollbar.lua`: `LEASE_AUTH`, `exact`/`active`, `text_geometry`, `install_autocmds`, `S.open(state, opts, callbacks)` with `claim`/`alive`/`release` — lines 134-230 and 591-741 are the template); `canvas.win_showing_canvas`.
- Produces: `SH.open(state, opts, callbacks) -> lease|nil`, `SH.update(lease, state?) -> boolean`, `SH.close(lease) -> boolean`, `SH.is_open(lease) -> boolean` — the exact shape scrollbar exposes, so App/Surface wire it identically under `surface.controllers.sticky`.

- [ ] **Step 1: Write the failing tests**

`test/integration/test_sticky_header.lua`, following `test/integration/test_scrollbar.lua`'s structure (its helpers for opening a real canvas state, moving the view with `vim.api.nvim_win_call(win, function() vim.fn.winrestview({ topline = N }) end)`, then calling `update` by hand — WinScrolled never fires headlessly):

```lua
T["sticky_win hidden while the first header is the topline"] = function()
  -- open canvas + lease; topline 1 (row0 0) is section 1's header
  H.eq(sticky.is_open(lease), false)
end

T["sticky_win appears once the header scrolls off, mirroring it exactly"] = function()
  -- winrestview two rows into section 1, sticky.update(lease)
  H.eq(sticky.is_open(lease), true)
  local fbuf = vim.api.nvim_win_get_buf(lease.win)
  local shown = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)[1]
  H.eq(shown, render.section_line(st.sections[1], 1))
  -- float geometry: 1 row tall, canvas-wide, under the winbar, below the minimap
  local cfg = vim.api.nvim_win_get_config(lease.win)
  H.eq(cfg.height, 1)
  H.eq(cfg.width, vim.api.nvim_win_get_width(st.win))
  H.eq(cfg.relative, "win")
  assert(cfg.zindex < 40, "the minimap owns the shared top-right cell")
  H.eq(vim.api.nvim_win_get_config(lease.win).focusable, false)
end

T["sticky_win swaps at a section boundary"] = function()
  -- winrestview into section 2, update; the shown line is section 2's header
end

T["sticky_win row carries the bar tint and the marker spans"] = function()
  -- assert extmarks on the float buffer: a line_hl_group CanvasDiffFileBar
  -- mark, and one mark per span from render.marker_spans at matching cols
end

T["sticky_win a reconcile's new counts reach the pinned row"] = function()
  -- mutate the section's adds/dels (the way test_scrollbar simulates a
  -- reconcile), update, assert the shown counts changed
end

T["sticky_win hides on excursion and dies with the canvas window"] = function()
  -- BufWinLeave path: swap the canvas window's buffer, drive the deferred
  -- update, is_open false; then close the canvas window, drive the
  -- scheduled WinClosed teardown, assert the float window is gone and a
  -- second SH.close(lease) returns false (idempotent, exact)
end

T["sticky_win claim refusal allocates nothing"] = function()
  -- SH.open with claim = function() return false end -> nil, no float
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test SUITE=integration FILTER='sticky_win'`
Expected: FAIL — `SH.open` does not exist.

- [ ] **Step 3: Implement the float half**

In `ui/sticky_header.lua`, port the scrollbar lease skeleton (KEEP the ported comments' substance; this is deliberate duplication of a proven pattern, not shared abstraction — the two floats' update logic diverges completely):

- `LEASE_AUTH` weak-key auth table, `exact`, `active`, `valid_win`/`valid_buf`, `owned_window` — verbatim pattern from scrollbar.lua lines 140-190.
- `text_geometry(win)` — same `getwininfo` note as scrollbar.lua lines 194-209 (the float must sit UNDER the winbar: `row = info.winbar`).
- `float_config(state)`:

```lua
local function float_config(state)
  local geo = text_geometry(state.win)
  return {
    relative = "win",
    win = state.win,
    row = geo.row,
    col = 0,
    width = math.max(vim.api.nvim_win_get_width(state.win), 1),
    height = 1,
    focusable = false,
    style = "minimal",
    -- Below the minimap's 40: where the two floats share the top-right
    -- cell, the minimap wins. Clicks fall through to the covered canvas
    -- row either way (non-focusable floats are mouse-transparent).
    zindex = 30,
  }
end
```

- `SH.update(lease, state?)`: the scrollbar's `S.update` shape (lines 421-529) with the drawing middle replaced: compute `top0 = line("w0") - 1` in the canvas window; `local content = SH.content(state, top0)`; `content == nil` ⇒ `hide(lease)` and return false; else ensure buffer (`canvasdiff://sticky/%d`, nofile/hide/noswap) + window (open or `nvim_win_set_config` reposition), set the single line, clear the namespace (`canvasdiff.sticky` namespace), then extmarks: `line_hl_group = "CanvasDiffFileBar"` at priority 99; `hl_group = "CanvasDiffFileHeader"` over `[0, #line)` (`end_col`) at priority 100; one mark per span `{ start_col, end_col, group }` (same shape Canvas.lua line 149 places). Re-check `active(lease)` after every external call, exactly as scrollbar.update does.
- `hide`, `SH.close`, `defer_update`, `create_autocmd`, `install_autocmds` (WinScrolled/WinResized → update; BufWinEnter(buffer=canvas) → update; BufWinLeave(buffer=canvas) → defer_update; WinClosed(canvas win) → scheduled `SH.close`), `SH.open(state, opts, callbacks)` with claim/alive/release — all the scrollbar shape (lines 400-741) minus the mouse block; `SH.is_open = owned_window`.

`App.lua`, directly after the scrollbar block (~line 1550), unconditional (the band and its file half are part of the one look — no option):

```lua
  local sticky_lease = sticky.open(st, {}, {
    claim = function(lease)
      if not surface:guard(generation)
          or surface.controllers.sticky ~= nil then
        return false
      end
      surface.controllers.sticky = lease
      return true
    end,
    alive = function(lease)
      return surface:guard(generation)
        and surface.controllers.sticky == lease
    end,
    release = function(lease)
      if surface.controllers.sticky ~= lease then
        return false
      end
      surface.controllers.sticky = nil
      return true
    end,
  })
  if sticky_lease then
    assert(surface.controllers.sticky == sticky_lease,
      "sticky claim must publish its returned exact lease")
  end
```

(`local sticky = ui.sticky_header` beside `local scrollbar = ui.scrollbar` at App.lua line 14.) Then keep the pinned row honest on the non-scroll refresh paths: in `refresh_winbars(surface)` add `local pin = surface.controllers.sticky; if pin then sticky.update(pin) end` (reconciles route through it at lines 1069-1071/1404-1406), and in `sync_after_collapse` (line 829) mirror the `scrollbar.update` call with the sticky equivalent.

`Surface.lua` teardown (after the `scrollbar.close` attempt, same shape):

```lua
  attempt("sticky.close", function()
    local lease = self.controllers.sticky
    self.controllers.sticky = nil
    if lease then
      sticky_header.close(lease)
    end
  end)
```

(with the matching `local sticky_header = require("canvasdiff.ui.sticky_header")` import following Surface.lua's existing import style).

- [ ] **Step 4: Run tests, then the full suite**

Run: `make test SUITE=integration FILTER='sticky_win'`, then `make test`
Expected: PASS. Watchpoints: `test/integration/test_scrollbar.lua`'s geometry tests (the sticky float shares the win-relative space — they assert on THEIR float only, but confirm); `test/fault/chaos_surface.lua` invariants that enumerate `surface.controllers` keys; lifecycle tests counting floats after close.

- [ ] **Step 5: Manual smoke (the spec's verification)**

In a real terminal session on this repo: open the canvas on a 20-file changeset; scroll and watch the pinned header swap at each boundary and vanish when a real header row reaches the top; check the top band reads as one bar whichever window has focus; `:CanvasDiff main..topic` shows the READ-ONLY tint on the canvas half only; a deleted file reads dimmed with a red margin. Record "smoke: pass" (or what broke) in the commit body.

- [ ] **Step 6: Commit**

```bash
git add -A lua test
git commit -m "feat: sticky file-header row pinned under the top band"
```

---

### Task 8: Documentation and the final gate

**Files:**
- Modify: `README.md` (§"How diff rows are coloured" line 684; the ghost-group paragraph ~line 680; any winbar/breadcrumb mentions — grep `winbar\|breadcrumb\|highlight.diff` across the README)
- Modify: `doc/canvasdiff.txt` (setup example line ~332; `*canvasdiff-highlight-diff*` section lines 372-390; winbar mentions)
- Test: full suite + helptags

**Interfaces:**
- Consumes: everything shipped in Tasks 1-7.
- Produces: docs that describe only the shipped rendering.

- [ ] **Step 1: Rewrite README §"How diff rows are coloured"**

Replace the three-mode bullets with the three channels — elevation (one neutral raised background = "this row changed"), dimming (removed content: ghost lines and a deleted file's rows) and margin hue (green/red on the `+`/`-` prefix cell and the statuscolumn bar = direction). State that all values are derived from the live colorscheme, list what each derivation reads, and that `highlight.diff` was removed (one sentence, pointing at overrides). Update the groups table:

| Group | Default | Marks |
| --- | --- | --- |
| `CanvasDiffAdd` | derived neutral elevation | an added row's background |
| `CanvasDiffDel` | elevation + dimmed fg | a deleted file's real rows |
| `CanvasDiffGhost` | dimmed fg, no bg | ghost deletion lines |
| `CanvasDiffPrefixAdd` / `CanvasDiffPrefixDel` | derived green/red fg | the `+`/`-` prefix cell |
| `CanvasDiffGutterAdd` / `CanvasDiffGutterDel` | same green/red | the statuscolumn bar |
| `CanvasDiffWordAdd` / `CanvasDiffWordDel` | **bold + underline** | the changed span (unchanged) |
| `CanvasDiffFileBar` | derived bar elevation | the file header row + sticky row |
| `CanvasDiffWinbar` / `CanvasDiffWinbarReadOnly` | `WinBar` / `Visual` | the top band / read-only mode |

Keep the existing measured-choice paragraphs that still hold (hl_eol removal, word-diff attributes, shape-channel prefixes) and update the ghost paragraph: `CanvasDiffGhost` no longer defaults to `CanvasDiffDel`. Add a short "The top band and the pinned header" paragraph where the winbar was described: comparison label on a focus-stable band shared with the sidebar; the file's own header pinned beneath it, covering (not pushing) the top row; quieting/overriding examples updated to the new group names.

- [ ] **Step 2: Rewrite the vimdoc**

`doc/canvasdiff.txt`: drop `diff = "quiet"` from the setup example; replace `*canvasdiff-highlight-diff*`'s mode list with the three-channel description + the removed-option note (what a leftover `highlight.diff = ...` in a config now does: one diagnostic, then ignored); document the new groups and the sticky header row's behaviour (hidden when the real header is at the top; covers the first canvas row; clicks fall through). Regenerate tags: `nvim --headless "+helptags doc" +q` and commit the `doc/tags` change.

- [ ] **Step 3: Full-suite gate**

Run: `make test`
Expected: everything green. Then `grep -rn "highlight%.diff\|diff_mode\|quiet\|classic" lua/ README.md doc/canvasdiff.txt` — every remaining hit must be intentional (the removed-option diagnostic, historical notes) — and `grep -rn "breadcrumb" lua/` must be empty.

- [ ] **Step 4: Commit**

```bash
git add -A README.md doc
git commit -m "docs: describe the one-look rendering, band and pinned header"
```
