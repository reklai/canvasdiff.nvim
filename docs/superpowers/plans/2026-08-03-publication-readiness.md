# CanvasDiff Publication Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CanvasDiff zero-config installable, natively customizable through lazy.nvim/LazyVim, contributor-oriented, and publication-ready under deterministic hostile testing.

**Architecture:** A new `appearance` domain becomes the only owner of `CanvasDiff*` highlight definitions, derived palette logic, explicit overrides, validation, and colorscheme recovery. Existing renderers only select group names; configuration passes a native-shaped `highlights` table into appearance, while the Tree-sitter UI owner is renamed from the ambiguous `highlight` to `syntax`.

**Tech Stack:** Lua 5.1/LuaJIT, Neovim 0.12 APIs, lazy.nvim/LazyVim plugin specs, Git, the repository's headless Lua test runner, deterministic fault campaigns, and Make targets.

**Design Spec:** `docs/superpowers/specs/2026-08-03-publication-readiness-design.md`

## Global Constraints

- Neovim 0.12+ remains the tested and asserted floor.
- `require("canvasdiff").setup()` remains optional; an empty `opts = {}` is a complete installation.
- Public highlight values use `nvim_set_hl` fields directly; do not add a semantic palette or theme preset layer.
- Highlight precedence is colorscheme, then CanvasDiff defaults, then `setup().highlights`.
- `default` and `force` are appearance-manager fields and are invalid in user highlight specifications.
- A `false` highlight value and an omitted value on a later setup both release a manager-owned override back to its default.
- Invalid configuration is diagnosed without throwing or dismantling a live review.
- Direct foreign highlight definitions are preserved unless the same group is explicitly present in `setup().highlights`.
- Keep refactoring bounded to configuration, appearance, contributor orientation, documentation, and the hostile test surface touched by this pass.
- Comments explain ownership, invariants, public behavior, measured facts, or rejected alternatives; never narrate obvious Lua.
- Preserve the unrelated untracked `from` file exactly as found.
- Use `apply_patch` for edits and stage only task-owned paths.

---

## File Structure

### New production files

- `lua/canvasdiff/appearance.lua` — cross-domain facade exposing only `audit`, `ensure`, `names`, and `setup`.
- `lua/canvasdiff/appearance/groups.lua` — canonical ordered highlight registry, static specifications, and measured live palette derivation.
- `lua/canvasdiff/appearance/manager.lua` — validation, authored-definition tracking, override replacement, and one process-wide `ColorScheme` owner.
- `lua/canvasdiff/ui/syntax.lua` — renamed Tree-sitter diff-content highlighter, retaining its lease implementation.

### New test and documentation files

- `test/unit/test_appearance.lua` — registry, validation, precedence, and override authorship.
- `test/integration/test_appearance.lua` — root setup, colorscheme recovery, repeated setup, and autocmd ownership.
- `test/architecture/test_documentation.lua` — registry-to-README/help completeness and public installation/configuration markers.
- `CONTRIBUTING.md` — contributor entry path, architecture rules, comment policy, test lanes, and chaos replay.

### Existing files with focused changes

- `lua/canvasdiff/config/settings.lua`, `lua/canvasdiff/config.lua` — store the open `highlights` table and retain the original user table for health.
- `lua/canvasdiff/App.lua`, `lua/canvasdiff/Surface.lua`, `lua/canvasdiff.lua` — wire appearance setup and use the renamed syntax facade.
- `lua/canvasdiff/canvas/format.lua`, `lua/canvasdiff/canvas/Canvas.lua`, `lua/canvasdiff/canvas.lua` — surrender highlight-definition ownership while keeping text/span formatting.
- `lua/canvasdiff/ui.lua`, `lua/canvasdiff/ui/sidebar.lua`, `lua/canvasdiff/ui/scrollbar.lua`, `lua/canvasdiff/ui/sticky_header.lua`, `lua/canvasdiff/ui/status_column.lua`, `lua/canvasdiff/ui/winbar.lua` — use appearance and the renamed syntax owner without defining groups locally.
- `lua/canvasdiff/health.lua` — render appearance audit findings alongside existing config findings.
- `test/architecture/rules.lua`, `test/architecture/test_dependencies.lua`, `test/architecture/test_layout.lua` — own and enforce the new domain and renamed UI owner.
- `test/fault/test_highlight.lua` — retain/move palette assertions through the appearance facade, then rename syntax-specific coverage.
- `test/unit/test_config.lua`, `test/unit/test_health.lua`, `test/unit/test_ui.lua`, relevant integration/e2e/performance files — update the public contract and internal owner name.
- `test/fault/chaos_surface.lua`, `test/fault/test_chaos_surface.lua`, `benchmark/chaos/run.lua` — add configuration/colorscheme actions and invariants without losing replayability.
- `README.md`, `doc/canvasdiff.txt`, `docs/architecture.md` — publish the implemented contract and contributor seam.

---

### Task 0: Initialize adversarial execution guardrails

**Files:**
- Create outside product paths as directed by `$adversarial-development`: task receipt and clean-tree snapshot metadata
- Preserve: untracked `from`

**Interfaces:**
- Consumes: the committed design, this plan, branch `final_stretch`, and the current dirty-tree observation (`from` only).
- Produces: initialized adversarial receipt, recorded requested/observed routing, workspace snapshot, and per-task reviewer briefs.

- [ ] **Step 1: Read the execution skills before any product edit**

Read completely:

```text
superpowers:test-driven-development
superpowers:subagent-driven-development
adversarial-development/references/reviewer-contracts.md
superpowers:verification-before-completion
```

- [ ] **Step 2: Record the exact baseline**

```sh
git status --short --branch
git rev-parse HEAD
git branch --show-current
```

Expected: `final_stretch`, design commit `5558d31` plus the plan commit, and
only `?? from` outside committed work.

- [ ] **Step 3: Initialize the receipt and dirty-worktree snapshot**

Use `scripts/adversarial-workspace` and `scripts/snapshot-tree` from the
adversarial skill because the user-owned untracked file makes the checkout
dirty. Initialize `receipt.json` with triggers `public contract`, `>5
production files`, `>300 changed lines`, `lifecycle`, and `release behavior`;
record requested Sol-high implementation/reviewer routing and observed routing
as unverified unless the platform reports it.

- [ ] **Step 4: Start task-by-task execution**

Use one cross-cutting Sol-high writer per task, then controller-dispatched
independent reviewers under the adversarial reviewer contracts. Writers do not
spawn verdict reviewers. Keep accepted task areas closed unless a concrete
regression is reproduced.

---

### Task 1: Centralize every highlight definition in the appearance domain

**Files:**
- Create: `lua/canvasdiff/appearance.lua`
- Create: `lua/canvasdiff/appearance/groups.lua`
- Create: `lua/canvasdiff/appearance/manager.lua`
- Create: `test/unit/test_appearance.lua`
- Modify: `lua/canvasdiff/canvas/format.lua`
- Modify: `lua/canvasdiff/canvas/Canvas.lua`
- Modify: `lua/canvasdiff/canvas.lua`
- Modify: `lua/canvasdiff/ui/sidebar.lua`
- Modify: `lua/canvasdiff/ui/scrollbar.lua`
- Modify: `lua/canvasdiff/ui/sticky_header.lua`
- Modify: `lua/canvasdiff/ui/status_column.lua`
- Modify: `lua/canvasdiff/ui/winbar.lua`
- Modify: `test/fault/test_highlight.lua`
- Modify: `test/integration/test_canvas.lua`
- Modify: `test/integration/test_sticky_header.lua`
- Modify: `test/architecture/rules.lua`
- Modify: `test/architecture/test_dependencies.lua`

**Interfaces:**
- Consumes: live Neovim highlight state through `nvim_get_hl` and `nvim_set_hl`.
- Produces: `appearance.names() -> string[]`, `appearance.ensure() -> nil`, plus `appearance.audit` and `appearance.setup` stubs completed in Task 2.
- Registry names, in stable order: `CanvasDiffAdd`, `CanvasDiffDel`, `CanvasDiffGhost`, `CanvasDiffPrefixAdd`, `CanvasDiffPrefixDel`, `CanvasDiffGutterAdd`, `CanvasDiffGutterDel`, `CanvasDiffFileBar`, `CanvasDiffFileHeader`, `CanvasDiffHunkHeader`, `CanvasDiffBinary`, `CanvasDiffWinbar`, `CanvasDiffWinbarReadOnly`, `CanvasDiffStaged`, `CanvasDiffUnstaged`, `CanvasDiffStale`, `CanvasDiffStaleEmphasis`, `CanvasDiffSidebarDir`, `CanvasDiffSidebarActive`, `CanvasDiffSidebarHunk`, `CanvasDiffHunkDel`, `CanvasDiffCrumb`, `CanvasDiffScrollFile`, `CanvasDiffScrollAdd`, `CanvasDiffScrollDel`, `CanvasDiffScrollChanged`, `CanvasDiffScrollThumb`.

- [ ] **Step 1: Write the failing registry and ownership tests**

Add the exact public registry assertion to `test/unit/test_appearance.lua`:

```lua
local H = require("helpers")
local appearance = require("canvasdiff.appearance")

local T = {}

local GROUPS = {
  "CanvasDiffAdd", "CanvasDiffDel", "CanvasDiffGhost",
  "CanvasDiffPrefixAdd", "CanvasDiffPrefixDel",
  "CanvasDiffGutterAdd", "CanvasDiffGutterDel", "CanvasDiffFileBar",
  "CanvasDiffFileHeader", "CanvasDiffHunkHeader", "CanvasDiffBinary",
  "CanvasDiffWinbar", "CanvasDiffWinbarReadOnly",
  "CanvasDiffStaged", "CanvasDiffUnstaged", "CanvasDiffStale",
  "CanvasDiffStaleEmphasis", "CanvasDiffSidebarDir",
  "CanvasDiffSidebarActive", "CanvasDiffSidebarHunk",
  "CanvasDiffHunkDel", "CanvasDiffCrumb", "CanvasDiffScrollFile",
  "CanvasDiffScrollAdd", "CanvasDiffScrollDel",
  "CanvasDiffScrollChanged", "CanvasDiffScrollThumb",
}

T["appearance registry is the exact public highlight surface"] = function()
  local facade = vim.tbl_keys(appearance)
  table.sort(facade)
  H.eq(facade, { "audit", "ensure", "names", "setup" })
  H.eq(appearance.names(), GROUPS)
  local second = appearance.names()
  second[1] = "mutated"
  H.eq(appearance.names(), GROUPS, "callers receive a copy")
end

T["appearance ensure defines every registered group"] = function()
  for _, name in ipairs(GROUPS) do
    vim.api.nvim_set_hl(0, name, {})
  end
  appearance.ensure()
  for _, name in ipairs(GROUPS) do
    local value = vim.api.nvim_get_hl(0, { name = name, link = true })
    assert(next(value) ~= nil, name .. " was not defined")
  end
end

return T
```

Add an architecture assertion that production `nvim_set_hl` calls occur only
under `lua/canvasdiff/appearance/` after the migration:

```lua
T.architecture_dependencies_appearance_owns_highlight_definitions = function()
  local violations = {}
  for _, file in ipairs(graph.source_files(graph.root)) do
    if file.rel:match("^lua/canvasdiff/")
        and not file.rel:match("^lua/canvasdiff/appearance/") then
      local handle = assert(io.open(file.abs, "rb"))
      local source = handle:read("*a")
      handle:close()
      if source:find("nvim_set_hl", 1, true) then
        violations[#violations + 1] = file.rel
      end
    end
  end
  assert_no_errors(violations,
    "highlight definitions must enter through canvasdiff.appearance")
end
```

- [ ] **Step 2: Run the tests and prove the boundary is absent**

Run:

```sh
make test SUITE=unit FILTER='^appearance'
make architecture
```

Expected: unit loading fails because `canvasdiff.appearance` does not exist;
architecture reports current `nvim_set_hl` owners outside the new domain.

- [ ] **Step 3: Create the canonical registry and facade**

Implement `appearance/groups.lua` with one ordered registry and copy-returning
names function:

```lua
local G = {}

local ORDER = {
  "CanvasDiffAdd", "CanvasDiffDel", "CanvasDiffGhost",
  "CanvasDiffPrefixAdd", "CanvasDiffPrefixDel",
  "CanvasDiffGutterAdd", "CanvasDiffGutterDel", "CanvasDiffFileBar",
  "CanvasDiffFileHeader", "CanvasDiffHunkHeader", "CanvasDiffBinary",
  "CanvasDiffWinbar", "CanvasDiffWinbarReadOnly",
  "CanvasDiffStaged", "CanvasDiffUnstaged", "CanvasDiffStale",
  "CanvasDiffStaleEmphasis", "CanvasDiffSidebarDir",
  "CanvasDiffSidebarActive", "CanvasDiffSidebarHunk",
  "CanvasDiffHunkDel", "CanvasDiffCrumb", "CanvasDiffScrollFile",
  "CanvasDiffScrollAdd", "CanvasDiffScrollDel",
  "CanvasDiffScrollChanged", "CanvasDiffScrollThumb",
}
local KNOWN = {}
for _, name in ipairs(ORDER) do KNOWN[name] = true end

function G.names()
  return vim.deepcopy(ORDER)
end

function G.known(name)
  return KNOWN[name] == true
end

function G.definitions()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local dark = vim.o.background == "dark"
  local pole = dark and 0xffffff or 0x000000
  local anti_pole = dark and 0x000000 or 0xffffff
  local normal_bg = normal.bg
    or ELEVATION_FALLBACK_BG[dark and "dark" or "light"]
  local elevation = tonumber(blend(normal_bg, pole, ELEVATION_FACTOR):sub(2), 16)
  local ghost_fg = tonumber(
    blend(normal.fg or pole, normal.bg or anti_pole, GHOST_DIM_FACTOR):sub(2), 16)
  local bar = tonumber(blend(normal_bg, pole, BAR_FACTOR):sub(2), 16)
  local directory = vim.api.nvim_get_hl(0, { name = "Directory", link = false })
  if directory.fg and chroma(directory.fg) >= BAR_TINT_MIN_CHROMA then
    bar = tonumber(blend(normal_bg, directory.fg, BAR_TINT_FACTOR):sub(2), 16)
  end

  local out = vim.deepcopy(STATIC)
  out.CanvasDiffAdd = { bg = elevation }
  out.CanvasDiffDel = { bg = elevation, fg = ghost_fg }
  out.CanvasDiffGhost = { fg = ghost_fg }
  out.CanvasDiffFileBar = { bg = bar }
  for kind, pair in pairs({
    add = { "CanvasDiffPrefixAdd", "CanvasDiffGutterAdd" },
    del = { "CanvasDiffPrefixDel", "CanvasDiffGutterDel" },
  }) do
    local source = vim.api.nvim_get_hl(0, {
      name = kind == "add" and "DiffAdd" or "DiffDelete",
      link = false,
    })
    local hue = source.fg or HUE_FALLBACK_FG[kind]
    for _, name in ipairs(pair) do
      out[name] = { fg = hue, ctermfg = source.ctermfg }
    end
  end
  return out
end

return G
```

Implement the facade with a deliberately exact surface:

```lua
local groups = require("canvasdiff.appearance.groups")
local manager = require("canvasdiff.appearance.manager")

return {
  audit = manager.audit,
  ensure = manager.ensure,
  names = groups.names,
  setup = manager.setup,
}
```

Create `appearance/manager.lua` with `ensure()` and temporary no-op
`audit()`/`setup()` signatures so later tasks do not rename the interface:

```lua
local groups = require("canvasdiff.appearance.groups")
local M = {}
local authored = {}

local function shape(definition)
  local out = {}
  for key, value in pairs(definition or {}) do
    if key ~= "default" and key ~= "force" then out[key] = value end
  end
  return out
end

local function readback(name)
  return shape(vim.api.nvim_get_hl(0, { name = name, link = true }))
end

local function set_default(name, value)
  local current = readback(name)
  local spec = vim.tbl_extend("force", vim.deepcopy(value), { default = true })
  if next(current) ~= nil then
    if not vim.deep_equal(current, authored[name]) then return end
    if vim.deep_equal(current, shape(spec)) then return end
    spec.force = true
  end
  vim.api.nvim_set_hl(0, name, spec)
  authored[name] = readback(name)
end

function M.ensure()
  local definitions = groups.definitions()
  for _, name in ipairs(groups.names()) do
    set_default(name, assert(definitions[name], "missing definition: " .. name))
  end
end

function M.audit(_) return {} end
function M.setup(_) M.ensure(); return {} end

return M
```

- [ ] **Step 4: Move static and derived definitions without changing visuals**

Move these existing definitions verbatim in meaning:

```lua
local STATIC = {
  CanvasDiffFileHeader = { link = "Title" },
  CanvasDiffHunkHeader = { link = "Comment" },
  CanvasDiffBinary = { link = "Comment" },
  CanvasDiffWinbar = { link = "WinBar" },
  CanvasDiffWinbarReadOnly = { link = "Visual" },
  CanvasDiffStaged = { link = "Added" },
  CanvasDiffUnstaged = { link = "DiagnosticWarn" },
  CanvasDiffStale = { link = "DiagnosticError" },
  CanvasDiffStaleEmphasis = { bold = true },
  CanvasDiffSidebarDir = { link = "Directory" },
  CanvasDiffSidebarActive = { link = "Visual" },
  CanvasDiffSidebarHunk = { link = "Comment" },
  CanvasDiffHunkDel = { link = "CanvasDiffGhost" },
  CanvasDiffCrumb = {},
  CanvasDiffScrollFile = { link = "Title" },
  CanvasDiffScrollAdd = { link = "DiffAdd" },
  CanvasDiffScrollDel = { link = "DiffDelete" },
  CanvasDiffScrollChanged = { link = "DiffChange" },
  CanvasDiffScrollThumb = { link = "PmenuThumb" },
}

local ELEVATION_FACTOR = 0.04
local BAR_FACTOR = 0.16
local BAR_TINT_FACTOR = 0.10
local BAR_TINT_MIN_CHROMA = 60
local GHOST_DIM_FACTOR = 0.20
local ELEVATION_FALLBACK_BG = { dark = 0x2c2c2c, light = 0xe4e4e4 }
local HUE_FALLBACK_FG = { add = 0x2ea043, del = 0xdb4444 }

local function chroma(colour)
  if not colour then return 0 end
  local r = math.floor(colour / 65536) % 256
  local g = math.floor(colour / 256) % 256
  local b = colour % 256
  return math.max(r, g, b) - math.min(r, g, b)
end

local function blend(a, b, factor)
  if a == nil and b == nil then return nil end
  if a == nil or b == nil then return ("#%06x"):format(a or b) end
  local function channel(shift)
    local av = math.floor(a / shift) % 256
    local bv = math.floor(b / shift) % 256
    return math.floor(av + (bv - av) * factor + 0.5)
  end
  return ("#%02x%02x%02x"):format(
    channel(65536), channel(256), channel(1))
end
```

Move the surrounding measurement/rationale comments with these values and the
derived definitions for add/del/ghost/prefix/gutter/file-bar into `groups.lua`.
Keep the existing authored-default comparison in `manager.lua`; it must still:

```lua
if next(current) ~= nil and not vim.deep_equal(current, authored[name]) then
  return -- colorscheme or direct user definition owns it
end
```

Replace local definition functions in canvas/UI render boundaries with:

```lua
local appearance = require("canvasdiff.appearance")
appearance.ensure()
```

Remove `ensure_hunk_hl`, `ensure_marker_hl`, `ensure_diff_hl`, `blend`, and
`chroma` from `canvas/format.lua` and from the canvas facade. Rendering keeps
literal group selection and marker span construction.

- [ ] **Step 5: Update architecture ownership**

Add `appearance = true` to `R.domains`; allow `app`, `canvas`, `ui`, `health`,
`testing`, and benchmark harnesses that inspect public groups to depend on the
appearance facade; and give appearance no outgoing cross-domain edges:

```lua
appearance = {},
canvas = { appearance = true, config = true, diff = true, os = true },
ui = { appearance = true, canvas = true, config = true, diff = true,
  input = true, os = true },
testing = { appearance = true, canvas = true, config = true, diff = true,
  input = true, os = true, root = true, runtime = true, session = true,
  source = true, ui = true },
```

Update exact facade assertions and sticky-header tests to observe
`appearance.ensure` rather than monkey-patching a removed canvas formatter.

- [ ] **Step 6: Run focused visual and architecture tests**

Run:

```sh
make test SUITE=unit FILTER='^appearance'
make test SUITE=fault FILTER='^hl_'
make test SUITE=integration FILTER='sticky'
make architecture
```

Expected: all pass, including the pre-existing measured palette and foreign
definition preservation assertions.

- [ ] **Step 7: Commit the appearance ownership seam**

```sh
git add lua/canvasdiff/appearance.lua lua/canvasdiff/appearance/groups.lua \
  lua/canvasdiff/appearance/manager.lua \
  lua/canvasdiff/canvas.lua lua/canvasdiff/canvas/Canvas.lua \
  lua/canvasdiff/canvas/format.lua lua/canvasdiff/ui/sidebar.lua \
  lua/canvasdiff/ui/scrollbar.lua lua/canvasdiff/ui/sticky_header.lua \
  lua/canvasdiff/ui/status_column.lua lua/canvasdiff/ui/winbar.lua \
  test/unit/test_appearance.lua test/fault/test_highlight.lua \
  test/integration/test_canvas.lua test/integration/test_sticky_header.lua \
  test/architecture/rules.lua test/architecture/test_dependencies.lua
git commit -m "refactor: give appearance one owner"
```

---

### Task 2: Add native LazyVim highlight configuration and lifecycle recovery

**Files:**
- Modify: `lua/canvasdiff/appearance/manager.lua`
- Modify: `lua/canvasdiff/config/settings.lua`
- Modify: `lua/canvasdiff/config.lua`
- Modify: `lua/canvasdiff/App.lua`
- Modify: `lua/canvasdiff/health.lua`
- Modify: `test/unit/test_appearance.lua`
- Create: `test/integration/test_appearance.lua`
- Modify: `test/unit/test_config.lua`
- Modify: `test/unit/test_health.lua`
- Modify: `test/integration/test_root.lua`

**Interfaces:**
- Consumes: `appearance.setup(overrides)` where overrides is `nil` or a table of known group name to native highlight table or `false`.
- Produces: `appearance.audit(overrides) -> string[]`; `appearance.setup(overrides) -> string[]`; `config.options.highlights -> table`; `config.user_opts.highlights` retained verbatim for health.

- [ ] **Step 1: Write failing validation and precedence tests**

Wrap every mutating appearance case so a failure cannot leak configuration to
the next test:

```lua
local function with_appearance(overrides, fn)
  appearance.setup({})
  local ok, err = xpcall(function()
    local diagnostics = appearance.setup(overrides)
    fn(diagnostics)
  end, debug.traceback)
  appearance.setup({})
  assert(ok, err)
end
```

Add focused cases (using `with_appearance` or an equivalent `xpcall` cleanup
when the case performs multiple setup calls):

```lua
T["appearance accepts native highlight fields"] = function()
  local diagnostics = appearance.setup({
    CanvasDiffFileBar = { fg = "#112233", bg = "#445566", bold = true },
  })
  H.eq(diagnostics, {})
  local value = vim.api.nvim_get_hl(0,
    { name = "CanvasDiffFileBar", link = false })
  H.eq(value.fg, 0x112233)
  H.eq(value.bg, 0x445566)
  H.eq(value.bold, true)
end

T["appearance diagnoses unknown malformed and manager fields"] = function()
  local diagnostics = appearance.audit({
    CanvasDiffFyleBar = { bg = "#000000" },
    CanvasDiffGhost = "Comment",
    CanvasDiffFileBar = { default = true },
  })
  local text = table.concat(diagnostics, "\n")
  assert(text:find("CanvasDiffFyleBar", 1, true))
  assert(text:find("must be a table or false", 1, true))
  assert(text:find("default", 1, true))
end

T["appearance replacement releases only its own old override"] = function()
  appearance.setup({ CanvasDiffFileBar = { bg = "#112233" } })
  appearance.setup({})
  assert(vim.api.nvim_get_hl(0,
    { name = "CanvasDiffFileBar", link = false }).bg ~= 0x112233)

  appearance.setup({ CanvasDiffFileBar = { bg = "#112233" } })
  vim.api.nvim_set_hl(0, "CanvasDiffFileBar", { bg = "#abcdef" })
  appearance.setup({})
  H.eq(vim.api.nvim_get_hl(0,
    { name = "CanvasDiffFileBar", link = false }).bg, 0xabcdef)
end
```

In integration coverage, call setup, run `colorscheme default`, and assert the
explicit group returns. Count `ColorScheme` autocmds in group
`canvasdiff.appearance` after repeated setup and require exactly one.

- [ ] **Step 2: Prove current configuration and lifecycle fail**

Run:

```sh
make test SUITE=unit FILTER='^appearance'
make test SUITE=unit FILTER='^config_'
make test SUITE=integration FILTER='^appearance'
```

Expected: failures show that overrides are not validated/applied and custom
groups disappear after the colorscheme reset.

- [ ] **Step 3: Implement validation without observable global mutation**

Use one private validation namespace and normalize accepted entries:

```lua
local VALIDATE_NS = vim.api.nvim_create_namespace("canvasdiff.appearance.validate")

local function validate(raw)
  local accepted, diagnostics = {}, {}
  if raw == nil then return accepted, diagnostics end
  if type(raw) ~= "table" then
    return accepted, { "highlights must be a table, got " .. type(raw) }
  end
  for name, spec in pairs(raw) do
    if not groups.known(name) then
      diagnostics[#diagnostics + 1] = "unknown highlight group: " .. tostring(name)
    elseif spec ~= false and type(spec) ~= "table" then
      diagnostics[#diagnostics + 1] =
        ("highlights.%s must be a table or false, got %s"):format(name, type(spec))
    elseif spec ~= false and (spec.default ~= nil or spec.force ~= nil) then
      diagnostics[#diagnostics + 1] =
        ("highlights.%s cannot set default or force"):format(name)
    elseif spec ~= false then
      local copy = vim.deepcopy(spec)
      local ok, err = pcall(vim.api.nvim_set_hl, VALIDATE_NS, name, copy)
      if ok then accepted[name] = copy
      else diagnostics[#diagnostics + 1] =
        ("highlights.%s is invalid: %s"):format(name, tostring(err)) end
    end
  end
  table.sort(diagnostics)
  return accepted, diagnostics
end
```

`audit` returns diagnostics only. `setup` validates, releases omitted/false
manager-owned overrides, stores the accepted set, ensures defaults, applies
accepted overrides, and returns diagnostics.

- [ ] **Step 4: Implement exact override authorship and colorscheme recovery**

Track the readback after each explicit override. Release only an exact match:

```lua
if vim.deep_equal(readback(name), override_authored[name]) then
  vim.api.nvim_set_hl(0, name, {})
end
override_authored[name] = nil
```

Install one fixed autocmd owner:

```lua
local group = vim.api.nvim_create_augroup("canvasdiff.appearance", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  desc = "Reapply CanvasDiff defaults and explicit overrides",
  callback = function() M.ensure() end,
})
```

`M.ensure()` must always apply derived/static defaults first and accepted
overrides second.

- [ ] **Step 5: Add `highlights` to setup and health**

In config defaults:

```lua
highlights = {}, -- exact CanvasDiff group -> nvim_set_hl spec; false resets
```

Teach `unknown_paths` not to descend into top-level `highlights`; appearance
owns that extension schema. Preserve the original table in `user_opts` as
today. In `App.new`, initialize appearance from `config.options.highlights`.
In `App:setup`:

```lua
local options, diagnostics = config.setup(opts)
vim.list_extend(diagnostics, appearance.setup(options.highlights))
```

Render each appearance diagnostic through the existing `ui.err`. In health,
append `appearance.audit(config.user_opts.highlights)` warnings and include
them in the clean-config condition.

- [ ] **Step 6: Run configuration, health, root, and lifecycle tests**

Run:

```sh
make test SUITE=unit FILTER='^appearance'
make test SUITE=unit FILTER='^config_'
make test SUITE=unit FILTER='^health_'
make test SUITE=integration FILTER='^appearance'
make test SUITE=integration FILTER='setup'
```

Expected: all pass; invalid siblings are diagnosed while valid siblings apply,
setup replacement is ownership-safe, and colorscheme recovery has one callback.

- [ ] **Step 7: Commit the public configuration contract**

```sh
git add lua/canvasdiff/appearance/manager.lua lua/canvasdiff/config.lua \
  lua/canvasdiff/config/settings.lua lua/canvasdiff/App.lua \
  lua/canvasdiff/health.lua test/unit/test_appearance.lua \
  test/integration/test_appearance.lua test/unit/test_config.lua \
  test/unit/test_health.lua test/integration/test_root.lua
git commit -m "feat: configure CanvasDiff highlight groups"
```

---

### Task 3: Rename the Tree-sitter highlighter to its actual syntax responsibility

**Files:**
- Move: `lua/canvasdiff/ui/highlight.lua` to `lua/canvasdiff/ui/syntax.lua`
- Move: `test/fault/test_highlight.lua` to `test/fault/test_syntax.lua` after palette cases have moved to appearance tests
- Modify: `lua/canvasdiff/ui.lua`
- Modify: `lua/canvasdiff/App.lua`
- Modify: `lua/canvasdiff/Surface.lua`
- Modify: all tests and benchmark label lists returned by `rg -n 'ui\.highlight|canvasdiff\.highlight' lua test benchmark`
- Modify: `test/unit/test_ui.lua`
- Modify: `test/architecture/test_dependencies.lua`

**Interfaces:**
- Consumes: the unchanged syntax lease API (`attach`, `detach`, `apply_now`, `invalidate`, `lang_for`, `section_ts_marks`).
- Produces: `require("canvasdiff.ui").syntax`; augroups named `canvasdiff.syntax.<id>`.

- [ ] **Step 1: Change contract tests first**

Update the UI facade expectation and owner assertions:

```lua
H.eq(names, { "cheatsheet", "err", "notify", "scrollbar", "sidebar",
  "status_column", "sticky_header", "syntax", "warn", "winbar" })

for _, name in ipairs({
  "attach", "detach", "apply_now", "invalidate", "lang_for", "section_ts_marks",
}) do
  H.eq(type(ui.syntax[name]), "function", "ui.syntax." .. name .. " is callable")
end
```

Set `SYNTAX_OWNER = "canvasdiff.ui.syntax"` in architecture tests and require
the old `canvasdiff.ui.highlight` path not to resolve.

- [ ] **Step 2: Run the renamed contract and prove it fails**

```sh
make test SUITE=unit FILTER='^ui_'
make architecture
```

Expected: `ui.syntax` is absent and the expected owner path does not exist.

- [ ] **Step 3: Move the owner and update all consumers atomically**

Use an `apply_patch` move, then update the facade:

```lua
local syntax = require("canvasdiff.ui.syntax")
-- facade key:
syntax = syntax,
```

Use `local syntax = ui.syntax` in App/Surface and replace `hl_lease` only where
the name now obscures ownership (`syntax_lease`). Rename augroups and expected
benchmark/test labels from `canvasdiff.highlight` to `canvasdiff.syntax`.

Do not leave a forwarding module. The architecture's “one meaning per name”
rule requires the old owner path to disappear.

- [ ] **Step 4: Run all syntax, lifecycle, performance-contract, and architecture tests**

```sh
make test SUITE=fault FILTER='^hl_'
make test SUITE=integration FILTER='lifecycle'
make test SUITE=integration FILTER='concurrent'
make test SUITE=performance FILTER='live_scale'
make architecture
```

Expected: all pass with the new module and augroup identity.

- [ ] **Step 5: Commit the responsibility rename**

```sh
git add lua/canvasdiff/App.lua lua/canvasdiff/Surface.lua lua/canvasdiff/ui.lua \
  lua/canvasdiff/ui/highlight.lua lua/canvasdiff/ui/syntax.lua \
  test/fault/test_highlight.lua test/fault/test_syntax.lua \
  test/architecture/test_dependencies.lua test/e2e/test_e2e.lua \
  test/integration/test_collapse.lua test/integration/test_concurrent_reviews.lua \
  test/integration/test_lens.lua test/integration/test_lifecycle.lua \
  test/integration/test_root.lua test/integration/test_virt.lua \
  test/performance/test_live_scale_coordinator.lua \
  test/performance/test_live_scale_worker.lua test/unit/test_ui.lua \
  benchmark/live_scale/coordinator.lua benchmark/live_scale/worker.lua
git commit -m "refactor: name the syntax highlighter precisely"
```

---

### Task 4: Add contributor orientation and executable architecture guidance

**Files:**
- Modify: `lua/canvasdiff/App.lua`
- Modify: `lua/canvasdiff/Surface.lua`
- Modify: `lua/canvasdiff/canvas/Page.lua`
- Modify: `lua/canvasdiff/canvas/PageList.lua`
- Modify: `lua/canvasdiff/canvas/Projection.lua`
- Modify: `lua/canvasdiff/canvas/Scheduler.lua`
- Modify: `lua/canvasdiff/ui/syntax.lua`
- Modify: `lua/canvasdiff/appearance.lua`
- Modify: `lua/canvasdiff/appearance/groups.lua`
- Modify: `lua/canvasdiff/appearance/manager.lua`
- Modify: `docs/architecture.md`
- Create: `CONTRIBUTING.md`
- Modify: `test/architecture/test_layout.lua`

**Interfaces:**
- Consumes: the implemented domain graph and repository Make targets.
- Produces: contributor-readable ownership/lifetime headers and one accurate development entry path.

- [ ] **Step 1: Add a failing architecture-document contract**

Add assertions that `docs/architecture.md` names the new domain, its facade,
and its no-cycle direction, and that `CONTRIBUTING.md` contains the authoritative
commands:

```lua
local architecture = H.read_file("docs/architecture.md")
assert(architecture:find("canvasdiff.appearance", 1, true))
assert(architecture:find("colorscheme", 1, true))

local contributing = H.read_file("CONTRIBUTING.md")
for _, command in ipairs({ "make unit", "make architecture", "make verify",
  "make bench-chaos" }) do
  assert(contributing:find(command, 1, true), "missing " .. command)
end
```

If `H.read_file` does not exist, add the small read-only helper in the test:

```lua
local function read(relative)
  local file = assert(io.open(vim.fs.joinpath(graph.root, relative), "rb"))
  local text = file:read("*a")
  file:close()
  return text
end
```

- [ ] **Step 2: Run the architecture contract and verify it fails**

```sh
make architecture
```

Expected: missing contributor guide and appearance architecture prose.

- [ ] **Step 3: Add Ghostty-style owner headers, not narration**

Each major owner gets a concise header in this shape, specialized to its real
responsibility:

```lua
-- One live review's process-level orchestrator. App chooses a Surface and
-- sequences domains; it does not own repository parsing, rendered rows, or
-- controller resources. Those lifetimes remain behind their domain facades.
```

For Page/PageList/Projection/Scheduler, state the representation, caller-visible
contract, invalidation/lifetime boundary, and what must remain bounded. Do not
comment local aliases, loops, or obvious return values. Preserve existing
load-bearing comments verbatim unless the ownership move makes one false.

- [ ] **Step 4: Write the architecture and contributor guides**

Add an appearance row to the domain table and describe:

```text
renderers choose group names -> appearance defines them
App passes setup options -> appearance manager applies them
ColorScheme -> one appearance callback -> defaults -> explicit overrides
```

`CONTRIBUTING.md` must include:

```markdown
## Before changing code
Read `docs/architecture.md`; cross-domain imports target only facades.

## Comments
Explain ownership, invariants, measured behavior, or why a tempting simpler
alternative is wrong. Do not translate the next line of Lua into English.

## Verification
`make unit`, `make integration`, `make fault`, `make architecture`, and
`make verify`, plus exact chaos replay from a reported seed.
```

- [ ] **Step 5: Verify architecture and comment scope**

```sh
make architecture
git diff --check
git diff --stat
```

Expected: architecture passes; changes are limited to named owner headers and
the two contributor documents.

- [ ] **Step 6: Commit contributor orientation**

```sh
git add CONTRIBUTING.md docs/architecture.md lua/canvasdiff/App.lua \
  lua/canvasdiff/Surface.lua lua/canvasdiff/canvas/Page.lua \
  lua/canvasdiff/canvas/PageList.lua lua/canvasdiff/canvas/Projection.lua \
  lua/canvasdiff/canvas/Scheduler.lua lua/canvasdiff/ui/syntax.lua \
  lua/canvasdiff/appearance.lua lua/canvasdiff/appearance/groups.lua \
  lua/canvasdiff/appearance/manager.lua test/architecture/test_layout.lua
git commit -m "docs: orient new CanvasDiff contributors"
```

---

### Task 5: Publish the README, Vim help, and LazyVim configuration path

**Files:**
- Create: `test/architecture/test_documentation.lua`
- Modify: `README.md`
- Modify: `doc/canvasdiff.txt`
- Modify: `test/integration/test_root.lua`

**Interfaces:**
- Consumes: `appearance.names()` and the actual `setup().highlights` contract.
- Produces: copy-pastable eager and lazy specs, common recipes, full option/highlight reference, and a drift guard.

- [ ] **Step 1: Write failing documentation completeness tests**

```lua
local appearance = require("canvasdiff.appearance")
local graph = require("architecture.graph")
local T = {}

local function read(path)
  local file = assert(io.open(vim.fs.joinpath(graph.root, path), "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

T.architecture_documentation_names_every_public_highlight = function()
  local readme, help = read("README.md"), read("doc/canvasdiff.txt")
  for _, name in ipairs(appearance.names()) do
    assert(readme:find(name, 1, true), "README omits " .. name)
    assert(help:find(name, 1, true), "Vim help omits " .. name)
  end
end

T.architecture_documentation_has_install_config_and_health_paths = function()
  local readme = read("README.md")
  for _, needle in ipairs({
    '"reklai/canvasdiff.nvim"', "opts =", "cmd = \"CanvasDiff\"",
    "CanvasDiffFileBar", ":checkhealth canvasdiff", "CONTRIBUTING.md",
  }) do
    assert(readme:find(needle, 1, true), "README omits " .. needle)
  end
  assert(not readme:find("TODO: demo", 1, true), "demo placeholder remains")
end

return T
```

Add a root integration test that passes the exact README-shaped partial opts
and observes the result:

```lua
T["README LazyVim opts apply through the root setup"] = function()
  local plugin = require("canvasdiff")
  plugin.setup({ highlights = {
    CanvasDiffFileBar = { fg = "#112233", bg = "#445566" },
  } })
  local value = vim.api.nvim_get_hl(0,
    { name = "CanvasDiffFileBar", link = false })
  H.eq(value.fg, 0x112233)
  H.eq(value.bg, 0x445566)
  plugin.setup({})
end
```

- [ ] **Step 2: Run the docs and install-shape tests to prove omissions**

```sh
make architecture
make test SUITE=integration FILTER='README'
```

Expected: Vim help omits the full group reference, README still has the demo
placeholder, and the new integration name is absent until added.

- [ ] **Step 3: Restructure the README for first-use flow**

Keep the current technical truth but order it as:

```markdown
# canvasdiff.nvim
value proposition, pre-alpha status, text preview
## Features
## Requirements
## Installation
### lazy.nvim and LazyVim
### Lazy-loading correctly
## Quick start
## Configuration recipes
### Change one behavior
### Change appearance
### Replace or disable keys
## Complete configuration reference
## Usage
## Troubleshooting
## Documentation
## Contributing
## License
```

Include these exact supported examples:

```lua
-- LazyVim: lua/plugins/canvasdiff.lua
return {
  {
    "reklai/canvasdiff.nvim",
    opts = {
      sidebar = { width = 40 },
      highlights = {
        CanvasDiffFileBar = { fg = "#c6d0f5", bg = "#303446" },
      },
    },
  },
}
```

```lua
-- Correct command/key lazy loading: the startup keys cause the load.
{
  "reklai/canvasdiff.nvim",
  cmd = "CanvasDiff",
  keys = {
    { "<leader><leader>", function() require("canvasdiff").toggle() end,
      desc = "CanvasDiff: toggle canvas" },
    { "<leader>lb", function() require("canvasdiff").compare() end,
      desc = "CanvasDiff: compare branches" },
    { "<leader>lc", function() require("canvasdiff").checkout() end,
      desc = "CanvasDiff: checkout branch" },
  },
  opts = { keymaps = { global = { compare = false, checkout = false } } },
}
```

Explain that native specs support `fg`, `bg`, `sp`, links, blend, bold,
italic, undercurl, and other Neovim-supported attributes; show `false` reset
and direct `nvim_set_hl` as the colorscheme-author path. Remove the historical
“Changed behaviour” section and demo placeholder.

- [ ] **Step 4: Update Vim help with the same contract**

Add `*canvasdiff-highlights*`, the precedence chain, reset semantics,
colorscheme recovery, and every registry group. Keep help terse and searchable;
do not copy the README's onboarding prose.

- [ ] **Step 5: Run docs, root smoke, and formatting checks**

```sh
make architecture
make test SUITE=integration FILTER='README'
make test SUITE=unit FILTER='^health_'
git diff --check
```

Expected: all registered groups are documented in both places and the copied
LazyVim options apply through the real root setup.

- [ ] **Step 6: Commit public documentation**

```sh
git add README.md doc/canvasdiff.txt test/architecture/test_documentation.lua \
  test/integration/test_root.lua
git commit -m "docs: publish CanvasDiff setup and customization"
```

---

### Task 6: Extend deterministic smoke simulation across configuration and colorscheme churn

**Files:**
- Modify: `test/fault/chaos_surface.lua`
- Modify: `test/fault/test_chaos_surface.lua`
- Modify: `benchmark/chaos/run.lua` only if coverage gates need a new minimum/action label
- Modify: production/test files implicated by reproduced findings

**Interfaces:**
- Consumes: `plugin.setup`, `appearance.names`, current live Surface invariants, seeded generator.
- Produces: replayable actions `configure_appearance`, `configure_invalid`, `reset_config`, `change_colorscheme`, and `toggle_glyph_set`; post-action appearance invariants.

- [ ] **Step 1: Add failing action-coverage assertions**

Extend the short campaign test to require real visits:

```lua
for _, action in ipairs({
  "configure_appearance", "configure_invalid", "reset_config",
  "change_colorscheme", "toggle_glyph_set",
}) do
  assert((result.counts[action] or 0) > 0,
    action .. " never ran: " .. vim.inspect(result.counts))
end
```

Use a fixed seed/action count that reaches all five; if the current seed does
not, select a fixed replacement by running the harness, record it in the test,
and retain deterministic replay.

- [ ] **Step 2: Run the short Surface campaign and prove actions are absent**

```sh
make test SUITE=fault FILTER='^chaos_surface'
```

Expected: coverage assertions fail because the new actions do not exist.

- [ ] **Step 3: Add deterministic actions and expected state**

Track only accepted explicit overrides in the campaign world:

```lua
ACTIONS.configure_appearance = function(world)
  local colors = { 0x112233, 0x334455, 0x667788, 0xaabbcc }
  local color = colors[world.rng.next(#colors) + 1]
  local hex = ("#%06x"):format(color)
  world.plugin.setup({ highlights = {
    CanvasDiffFileBar = { bg = hex },
  } })
  world.expected_file_bar = color
  record(world, "configure_appearance", hex)
end


ACTIONS.configure_invalid = function(world)
  world.plugin.setup({ highlights = {
    CanvasDiffFyleBar = { bg = "#000000" },
    CanvasDiffGhost = 42,
  } })
  world.expected_file_bar = nil
  record(world, "configure_invalid")
end

ACTIONS.reset_config = function(world)
  world.plugin.setup({})
  world.expected_file_bar = nil
  record(world, "reset_config")
end

ACTIONS.change_colorscheme = function(world)
  vim.cmd.colorscheme("default")
  record(world, "change_colorscheme")
end

ACTIONS.toggle_glyph_set = function(world)
  world.ascii = not world.ascii
  world.plugin.setup({ glyphs = world.ascii and "ascii" or nil })
  world.expected_file_bar = nil
  record(world, "toggle_glyph_set", world.ascii and "ascii" or "default")
end
```

Capture notifications around invalid setup if campaign output would otherwise
be noisy, but assert that at least one actionable diagnostic names the bad
group.

- [ ] **Step 4: Add post-action appearance and lifecycle invariants**

Inside `check(world)`:

```lua
local appearance = require("canvasdiff.appearance")
for _, name in ipairs(appearance.names()) do
  local definition = vim.api.nvim_get_hl(0, { name = name, link = true })
  assert(next(definition) ~= nil, name .. " disappeared during chaos")
end
if world.expected_file_bar then
  local bar = vim.api.nvim_get_hl(0,
    { name = "CanvasDiffFileBar", link = false })
  assert(bar.bg == world.expected_file_bar,
    "configured file bar did not survive the last action")
end
local commands = vim.api.nvim_get_autocmds({ group = "canvasdiff.appearance" })
assert(#commands == 1,
  ("appearance autocmd count grew to %d"):format(#commands))
```

Keep all pre-existing Surface, augroup, canvas-buffer, lens, refusal, and index
byte-equality invariants intact.

- [ ] **Step 5: Run short campaigns, repair only reproduced findings, and pin regressions**

```sh
make test SUITE=fault FILTER='^chaos_surface'
make test SUITE=fault FILTER='^chaos_'
```

For every failure, retain its seed/history, write the smallest focused
regression before changing production, and rerun that focused test plus the
exact seed. Do not weaken an invariant to make a campaign pass.

- [ ] **Step 6: Run the full deliberate-breakage lane**

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-final-chaos.log \
  make bench-chaos OUT=/tmp/canvasdiff-final ACTIONS=10000
```

Expected: three engine seeds complete 10,000 actions each, three Surface seeds
complete their configured campaigns, distinct-action gates pass, injected
refusals are observed, and JSON status is `ok`.

- [ ] **Step 7: Commit the campaign and any evidence-backed repairs**

```sh
git add test/fault/chaos_surface.lua test/fault/test_chaos_surface.lua \
  benchmark/chaos/run.lua
git commit -m "test: break configuration and appearance deliberately"
```

If production repairs were needed, use separate `fix:` commits with their
focused regression rather than hiding them inside the campaign commit.

---

### Task 7: Run authoritative verification and repair change-caused failures

**Files:**
- Modify: only files implicated by an authoritative failing test or verifier
- Record: adversarial receipt verification and guardrail fields

**Interfaces:**
- Consumes: all prior task commits and repository Make targets.
- Produces: clean authoritative command output and regression guardrails for every repaired finding.

- [ ] **Step 1: Run the complete ordinary suite from a clean process**

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-final-test.log make test
```

Expected: every unit, integration, e2e, fault, performance, and architecture
test passes.

- [ ] **Step 2: Run the complete publication verifier**

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-final-verify.log \
  make verify OUT=/tmp/canvasdiff-final-verify
```

Expected: ordinary suite, eager regression, million-row paged lane, full chaos,
and live acceptance all pass and write artifacts outside the checkout.

- [ ] **Step 3: Classify and repair failures without broadening scope**

For a clear failure, reproduce with the smallest named command, add a focused
regression, fix, and rerun both the focused command and its parent lane. For
large/noisy multi-suite output, dispatch the adversarial read-only triage role;
the controller performs authoritative reruns.

Use one receipt object per failure. For example, a colorscheme regression would
be recorded as:

```json
{
  "classification": "change-caused",
  "command": "make test SUITE=integration FILTER='^appearance'",
  "guardrail": "test/integration/test_appearance.lua colorscheme recovery",
  "rerun": "make test SUITE=integration FILTER='^appearance'"
}
```

- [ ] **Step 4: Inspect the current tree for publication residue**

```sh
git status --short --branch
git diff --check main...HEAD
git diff --stat main...HEAD
rg -n 'TODO: demo|TBD|FIXME|canvasdiff\.ui\.highlight|canvasdiff\.highlight' \
  README.md doc docs CONTRIBUTING.md lua test benchmark
```

Expected: branch is `final_stretch`; no whitespace errors, retired owner names,
or publication placeholders; only the pre-existing untracked `from` remains
outside task commits. If a verifier exposed a defect, insert a focused TDD
repair task with its now-known paths and command before continuing to Task 8;
do not use a broad catch-all verification commit.

---

### Task 8: Complete adversarial reviews, receipt finalization, and requirement audit

**Files:**
- Modify: only files required by admitted review findings
- Finalize: adversarial `receipt.json` and workspace guardrails per skill

**Interfaces:**
- Consumes: the entire `main...final_stretch` change and authoritative verification evidence.
- Produces: no unresolved admitted Critical/Important findings and a requirement-by-requirement completion record.

- [ ] **Step 1: Dispatch independent whole-change reviewers**

Reviewer A receives only the spec, plan, diff, and verification commands. Use
Sol-high and the implementation-review contract. Reviewer B is mandatory
because this pass changes a public schema, colorscheme lifecycle, more than five
production files, and likely more than 300 lines; use Sol-high and dispatch it
independently/concurrently with A.

- [ ] **Step 2: Admit findings against the closed scope**

Admit only reproduced supported-behavior defects introduced or exposed by this
change. Return Critical/Important findings verbatim to the writer. Reject
unrelated redesign requests, unsupported-platform speculation, and concerns
already disproved by an executable invariant.

- [ ] **Step 3: Apply at most the allowed whole-change fix wave**

For each admitted finding:

```text
reproduce -> add regression/guardrail -> minimal fix -> focused rerun -> parent rerun
```

Dispatch one scoped re-review over the fix diff. Do not start a second
whole-change fix wave; adjudicate residuals once as required by the adversarial
workflow.

- [ ] **Step 4: Rerun repository-authoritative verification after review fixes**

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-final-authoritative.log \
  make verify OUT=/tmp/canvasdiff-final-authoritative
```

Expected: all gates pass on the exact reviewed tree.

- [ ] **Step 5: Audit every explicit objective against current evidence**

Record evidence for:

```text
final_stretch branch
local Ghostty comment principles applied
Ghostty zero-config/override principles applied
native LazyVim opts and CanvasDiffFileBar fg/bg customization
simple defaults and fork-friendly source boundaries
publication-standard README and Vim help
contributor comments, architecture, and CONTRIBUTING.md
deterministic randomized simulation with repairs guarded
full test/benchmark/acceptance verification
no unresolved independent-review finding
```

Anything missing or indirectly supported keeps the goal active.

- [ ] **Step 6: Finalize the adversarial receipt and workspace**

Run the adversarial receipt finalizer and workspace finalizer with verdict
`pass` only after the audit and authoritative rerun are complete. Confirm the
untracked `from` file was never staged, edited, or deleted.
