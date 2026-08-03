# Color Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `setup({ profile = "quiet" | "classic" | "mono" })` selects the default
color vocabulary for the eleven diff-row highlight groups, colors only.

**Architecture:** The profile name flows config → App → appearance manager →
`groups.definitions(profile)`. Every profile output remains a `default = true`
definition, so the existing ownership chain (profile defaults → colorscheme →
explicit `setup().highlights`) is untouched. Validation and quiet-fallback live
in the appearance manager; config only carries the string.

**Tech Stack:** Lua (LuaJIT, Neovim 0.12 floor), repo test harness
(`make test SUITE=<dir> FILTER=<lua-pattern>`).

## Global Constraints

- Neovim 0.12 is the version floor; no APIs newer than it.
- Profiles change highlight defaults ONLY — never what is drawn, never glyphs.
- Valid names: exactly `"quiet"`, `"classic"`, `"mono"`. Anything else:
  one diagnostic, quiet derivation.
- The eleven profile-owned groups: `CanvasDiffAdd`, `CanvasDiffDel`,
  `CanvasDiffGhost`, `CanvasDiffHunkDel`, `CanvasDiffPrefixAdd`,
  `CanvasDiffPrefixDel`, `CanvasDiffGutterAdd`, `CanvasDiffGutterDel`,
  `CanvasDiffScrollAdd`, `CanvasDiffScrollDel`, `CanvasDiffScrollChanged`.
  All other groups are profile-independent.
- `docs/` is mostly gitignored but `docs/design.md` is tracked; commit it
  normally (it is already in the index).
- Comment style: explain constraints and measured rationale, wrap ~80 cols,
  match the density of the file you are editing.
- Test files clean up after themselves: restore any highlight group or
  option they change, then re-run `appearance.setup({})` +
  `nvim_exec_autocmds("ColorScheme", ...)` as existing tests do.

---

### Task 1: Profile plumbing + the classic profile

**Files:**
- Modify: `lua/canvasdiff/appearance/groups.lua` (definitions ~line 166+,
  registry top of file)
- Modify: `lua/canvasdiff/appearance/manager.lua` (setup/audit/ensure,
  apply_defaults ~line 109)
- Test: `test/fault/test_palette.lua` (append near the other `hl_` tests)
- Test: `test/unit/test_appearance.lua` (append)

**Interfaces:**
- Consumes: existing `groups.definitions()`, `manager.setup(raw)`,
  `manager.audit(raw)`.
- Produces (later tasks rely on these exact signatures):
  - `groups.known_profile(name: any) -> boolean` — true only for the three
    valid strings.
  - `groups.definitions(profile: string|nil) -> table` — `nil` or invalid
    behaves as `"quiet"`.
  - `manager.setup(raw: table|nil, profile: any) -> string[]` — diagnostics;
    invalid profile appends one message containing the word `profile` and
    derives quiet.
  - `manager.audit(raw: any, profile: any) -> string[]` — same message,
    no global mutation.
  - The `canvasdiff.appearance` facade re-exports these unchanged
    (`setup`/`audit` already point at the manager functions).

- [ ] **Step 1: Write the failing fault tests (classic links + override wins)**

Append to `test/fault/test_palette.lua` (after the elevation-escape tests;
`appearance`, `H`, `reset_diff_groups`, `recover_colorscheme` already exist
in the file):

```lua
-- Profiles select the DEFAULT vocabulary for the diff-row groups and nothing
-- else. classic is the traditional wash: whole-row DiffAdd/DiffDelete links,
-- which the ownership chain must still let a colorscheme or an explicit
-- override displace.
T["hl_profile classic links the row field to the scheme's diff wash"] = function()
  reset_diff_groups()
  local ok, err = xpcall(function()
    appearance.setup({}, "classic")
    local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = true })
    H.eq(add.link, "DiffAdd")
    local del = vim.api.nvim_get_hl(0, { name = "CanvasDiffDel", link = true })
    H.eq(del.link, "DiffDelete")
    local ghost = vim.api.nvim_get_hl(0, { name = "CanvasDiffGhost", link = true })
    H.eq(ghost.link, "DiffDelete")
    -- The margin already carries the scheme's diff hue under quiet; classic
    -- must not disturb it.
    local prefix = vim.api.nvim_get_hl(0, { name = "CanvasDiffPrefixAdd", link = false })
    assert(prefix.fg ~= nil, "the + prefix keeps its derived foreground")
  end, debug.traceback)
  appearance.setup({})
  recover_colorscheme()
  assert(ok, err)
end

T["hl_profile classic yields to an explicit override"] = function()
  reset_diff_groups()
  local ok, err = xpcall(function()
    appearance.setup({ CanvasDiffAdd = { bg = "#123456" } }, "classic")
    H.eq(vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = false }).bg,
      0x123456, "explicit highlights win over any profile")
  end, debug.traceback)
  appearance.setup({})
  recover_colorscheme()
  assert(ok, err)
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test SUITE=fault FILTER='hl_profile'`
Expected: both FAIL — `add.link` is nil because `manager.setup` ignores its
second argument today (quiet bg derivation, no link).

- [ ] **Step 3: Implement the plumbing and classic in groups.lua + manager.lua**

In `lua/canvasdiff/appearance/groups.lua`, below the `KNOWN` table setup:

```lua
-- The color profiles: named DEFAULT vocabularies for the eleven diff-row
-- groups (rows, ghosts, prefixes, gutter, minimap marks). Colors only --
-- a profile never changes what is drawn. Everything a profile emits stays
-- a `default = true` definition, so a colorscheme or an explicit override
-- outranks it exactly as it outranks the quiet derivation today.
local PROFILES = { quiet = true, classic = true, mono = true }

function G.known_profile(name)
  return PROFILES[name] == true
end
```

Change the `definitions` signature and add the classic branch just before
`return out`:

```lua
function G.definitions(profile)
  profile = G.known_profile(profile) and profile or "quiet"
```

```lua
  if profile == "classic" then
    -- The traditional whole-row wash, as links so the scheme's own diff
    -- colours flow through live. No collision guard here: if a scheme's
    -- DiffAdd sits on its Visual, that is the scheme's own vocabulary.
    out.CanvasDiffAdd = { link = "DiffAdd" }
    out.CanvasDiffDel = { link = "DiffDelete" }
    out.CanvasDiffGhost = { link = "DiffDelete" }
  end
  return out
end
```

In `lua/canvasdiff/appearance/manager.lua`:

Add near the other state locals (below `local underlay_known = {}`):

```lua
-- The active colour profile: which default vocabulary groups.definitions
-- derives. Validated on the way in; every reload (ensure, ColorScheme)
-- rederives under this name.
local active_profile = "quiet"

local function validate_profile(profile)
  if profile == nil then return "quiet", nil end
  if type(profile) == "string" and groups.known_profile(profile) then
    return profile, nil
  end
  return "quiet",
    ('profile must be "quiet", "classic" or "mono"; got %s -- using quiet')
      :format(safe_text(profile))
end
```

Change `apply_defaults` to derive under the active profile:

```lua
local function apply_defaults(recover_cleared)
  local definitions = groups.definitions(active_profile)
```

Change `M.audit` and `M.setup` signatures:

```lua
function M.audit(raw, profile)
  local _, diagnostics = validate(raw)
  local _, profile_diagnostic = validate_profile(profile)
  if profile_diagnostic then
    diagnostics[#diagnostics + 1] = profile_diagnostic
  end
  return diagnostics
end

function M.setup(raw, profile)
  local accepted, diagnostics = validate(raw)
  local profile_diagnostic
  active_profile, profile_diagnostic = validate_profile(profile)
  if profile_diagnostic then
    diagnostics[#diagnostics + 1] = profile_diagnostic
  end
```

(the remainder of `M.setup` is unchanged; `apply_defaults` picks up
`active_profile` on this and every later `ensure`.)

- [ ] **Step 4: Run the fault tests to verify they pass**

Run: `make test SUITE=fault FILTER='hl_profile'`
Expected: 2/2 PASS

- [ ] **Step 5: Write the failing unit tests (bad name diagnoses + falls back; audit is pure)**

Append to `test/unit/test_appearance.lua`:

```lua
T["appearance setup diagnoses an unknown profile and derives quiet"] = function()
  appearance.setup({})
  local ok, err = xpcall(function()
    local diagnostics = appearance.setup({}, "solarized")
    H.eq(#diagnostics, 1, vim.inspect(diagnostics))
    assert(diagnostics[1]:find("profile", 1, true), diagnostics[1])
    local add = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = true })
    H.eq(add.link, nil, "fell back to the quiet derivation, not classic")
    assert(add.bg ~= nil, "and the quiet elevation is present")
  end, debug.traceback)
  appearance.setup({})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(ok, err)
end

T["appearance audit reports a bad profile without changing state"] = function()
  appearance.setup({})
  local ok, err = xpcall(function()
    appearance.setup({}, "classic")
    local before = vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = true })
    local diagnostics = appearance.audit({}, 42)
    H.eq(#diagnostics, 1, vim.inspect(diagnostics))
    assert(diagnostics[1]:find("profile", 1, true), diagnostics[1])
    H.eq(appearance.audit({}, "mono"), {}, "a valid name is silent")
    H.eq(vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = true }), before,
      "audit never mutates highlight state")
  end, debug.traceback)
  appearance.setup({})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(ok, err)
end
```

- [ ] **Step 6: Run unit tests — the setup-fallback test should already pass, the audit test exercises the new path**

Run: `make test SUITE=unit FILTER='profile'`
Expected: 2/2 PASS (if either fails, fix manager.lua, not the tests —
likely a missed `safe_text` or a diagnostic string mismatch)

Then the full suites:

Run: `make test SUITE=fault && make test SUITE=unit && make test SUITE=architecture`
Expected: all pass — in particular every pre-existing appearance test still
passes with the implicit-quiet default.

- [ ] **Step 7: Commit**

```bash
git add lua/canvasdiff/appearance/groups.lua lua/canvasdiff/appearance/manager.lua \
  test/fault/test_palette.lua test/unit/test_appearance.lua
git commit -m "appearance: profile plumbing and the classic profile

profile selects the default vocabulary for the diff-row groups; classic
links the field to the scheme's own DiffAdd/DiffDelete wash. Unknown
names diagnose and fall back to quiet. Ownership precedence unchanged."
```

---

### Task 2: The mono profile

**Files:**
- Modify: `lua/canvasdiff/appearance/groups.lua` (the profile branch added
  in Task 1)
- Test: `test/fault/test_palette.lua`

**Interfaces:**
- Consumes: `groups.definitions(profile)` and `manager.setup(raw, profile)`
  from Task 1, plus the file-local `luma`/`chroma`/`blend` helpers and
  `reset_diff_groups`/`recover_colorscheme` already in the test file.
- Produces: `definitions("mono")` — zero-chroma defaults for all eleven
  groups (given achromatic Normal), per the spec's mono section.

- [ ] **Step 1: Write the failing fault test**

Append to `test/fault/test_palette.lua`:

```lua
-- mono removes hue from the entire diff vocabulary: rows and ghosts keep
-- quiet's neutral derivations, the + margin takes Normal's own foreground,
-- the - margin takes the ghost dim (dimming already says "removed"), and
-- the minimap's three marks collapse to the one neutral elevation. Normal
-- is pinned to pure greys here so "no chroma" is exact rather than
-- "no more chroma than the scheme's own text".
T["hl_profile mono spends no chroma anywhere in the diff vocabulary"] = function()
  local real_normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local real_add = vim.api.nvim_get_hl(0, { name = "DiffAdd", link = false })
  local real_del = vim.api.nvim_get_hl(0, { name = "DiffDelete", link = false })
  vim.api.nvim_set_hl(0, "Normal", { fg = 0xd0d0d0, bg = 0x1e1e1e })
  vim.api.nvim_set_hl(0, "DiffAdd", { fg = 0x2ea043, bg = 0x14261c })
  vim.api.nvim_set_hl(0, "DiffDelete", { fg = 0xdb4444, bg = 0x2d1215 })
  local ok, err = xpcall(function()
    reset_diff_groups()
    appearance.setup({}, "mono")
    local vocabulary = {
      "CanvasDiffAdd", "CanvasDiffDel", "CanvasDiffGhost", "CanvasDiffHunkDel",
      "CanvasDiffPrefixAdd", "CanvasDiffPrefixDel",
      "CanvasDiffGutterAdd", "CanvasDiffGutterDel",
      "CanvasDiffScrollAdd", "CanvasDiffScrollDel", "CanvasDiffScrollChanged",
    }
    for _, name in ipairs(vocabulary) do
      local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
      assert(next(hl) ~= nil, name .. " must still be defined")
      for _, channel in ipairs({ "fg", "bg", "sp" }) do
        local colour = hl[channel]
        assert(colour == nil or chroma(colour) == 0,
          ("%s.%s carries hue (#%06x) under mono"):format(name, channel, colour or 0))
      end
    end
    -- Direction still reads: the + margin is brighter than the - margin.
    local plus = vim.api.nvim_get_hl(0, { name = "CanvasDiffPrefixAdd", link = false })
    local minus = vim.api.nvim_get_hl(0, { name = "CanvasDiffPrefixDel", link = false })
    assert(luma(plus.fg) > luma(minus.fg),
      "the + prefix reads at full contrast, the - prefix reads dimmed")
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "Normal", real_normal)
  vim.api.nvim_set_hl(0, "DiffAdd", real_add)
  vim.api.nvim_set_hl(0, "DiffDelete", real_del)
  appearance.setup({})
  recover_colorscheme()
  assert(ok, err)
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test SUITE=fault FILTER='mono spends no chroma'`
Expected: FAIL — `CanvasDiffPrefixAdd.fg` is DiffAdd's green `#2ea043`
(chroma 116) because mono currently behaves as quiet.

- [ ] **Step 3: Implement mono in groups.lua**

Extend the profile branch from Task 1 (`elseif` on the same `if`):

```lua
  elseif profile == "mono" then
    -- Zero chroma anywhere in the diff vocabulary: rows and ghosts already
    -- derive neutral above; the margin drops the borrowed diff hue. The
    -- `+` reads at Normal's own full contrast and the `-` reads at the
    -- ghost dim, so direction survives on the luminance channel the ghost
    -- rows already taught. The minimap's three marks share the elevation:
    -- density stays visible, direction comes from position in the review.
    out.CanvasDiffPrefixAdd = { fg = normal.fg or pole }
    out.CanvasDiffGutterAdd = { fg = normal.fg or pole }
    out.CanvasDiffPrefixDel = { fg = ghost_fg }
    out.CanvasDiffGutterDel = { fg = ghost_fg }
    out.CanvasDiffScrollAdd = { bg = elevation }
    out.CanvasDiffScrollDel = { bg = elevation }
    out.CanvasDiffScrollChanged = { bg = elevation }
  end
```

(`normal`, `pole`, `ghost_fg`, `elevation` are already in scope at that
point in `definitions`.)

- [ ] **Step 4: Run the test to verify it passes, then the suites**

Run: `make test SUITE=fault FILTER='hl_profile'`
Expected: all profile tests PASS

Run: `make test SUITE=fault && make test SUITE=unit`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add lua/canvasdiff/appearance/groups.lua test/fault/test_palette.lua
git commit -m "appearance: mono profile -- zero chroma, shape and luminance only"
```

---

### Task 3: Config, App, and checkhealth wiring

**Files:**
- Modify: `lua/canvasdiff/config/settings.lua` (defaults table, ~line 211,
  next to `highlights = {}`)
- Modify: `lua/canvasdiff/App.lua:58` (`App.new`) and `lua/canvasdiff/App.lua:687`
  (`App:setup`)
- Modify: `lua/canvasdiff/health.lua:34`
- Test: `test/unit/test_config.lua`
- Test: `test/fault/test_palette.lua`

**Interfaces:**
- Consumes: `manager.setup(raw, profile)` / `manager.audit(raw, profile)`
  via the `canvasdiff.appearance` facade (Task 1).
- Produces: `config.defaults.profile == "quiet"`;
  `config.options.profile` carries the user's string; App passes it on
  both appearance.setup call sites; checkhealth reports a bad value.

- [ ] **Step 1: Write the failing config unit test**

Append to `test/unit/test_config.lua` (it already requires the config
module; match the file's local name for it — check its header first):

```lua
T["config profile defaults to quiet and passes through unvalidated"] = function()
  config.setup({})
  H.eq(config.options.profile, "quiet")
  local _, diagnostics = config.setup({ profile = "classic" })
  H.eq(diagnostics, {}, "config carries the string; appearance validates it")
  H.eq(config.options.profile, "classic")
  H.eq(config.health().unknown, {},
    "profile is schema, not an unknown path")
  config.setup({})
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test SUITE=unit FILTER='profile defaults to quiet'`
Expected: FAIL — `config.options.profile` is nil (not in defaults), and
`config.health().unknown` contains `"profile"`.

- [ ] **Step 3: Add the default**

In `lua/canvasdiff/config/settings.lua`, directly below
`highlights = {},` in `M.defaults`:

```lua
  -- Which default colour vocabulary the diff rows derive: "quiet" (neutral
  -- elevation, hue on the margin only), "classic" (DiffAdd/DiffDelete row
  -- washes), or "mono" (no hue anywhere). Colors only -- element toggles
  -- like statuscolumn and scrollbar are independent. The appearance manager
  -- validates the name; config just carries it.
  profile = "quiet",
```

- [ ] **Step 4: Run the config test to verify it passes**

Run: `make test SUITE=unit FILTER='profile defaults to quiet'`
Expected: PASS

- [ ] **Step 5: Write the failing end-to-end wiring test**

Append to `test/fault/test_palette.lua`:

```lua
T["hl_profile the configured profile reaches the appearance manager"] = function()
  local ok, err = xpcall(function()
    require("canvasdiff").setup({ profile = "classic" })
    H.eq(vim.api.nvim_get_hl(0, { name = "CanvasDiffAdd", link = true }).link,
      "DiffAdd", "setup({ profile = ... }) must flow through App")
  end, debug.traceback)
  require("canvasdiff").setup({})
  recover_colorscheme()
  assert(ok, err)
end
```

Run: `make test SUITE=fault FILTER='reaches the appearance manager'`
Expected: FAIL — App does not pass the profile yet, so the quiet bg
derivation wins and `.link` is nil.

- [ ] **Step 6: Wire App and health**

`lua/canvasdiff/App.lua` line 58, in `App.new`:

```lua
  local appearance_diagnostics =
    appearance.setup(config.options.highlights, config.options.profile)
```

`lua/canvasdiff/App.lua` line 687, in `App:setup`:

```lua
  vim.list_extend(diagnostics,
    appearance.setup(options.highlights, options.profile))
```

`lua/canvasdiff/health.lua` line 34 (report what the user actually wrote,
so a bad value keeps showing in :checkhealth even after the fallback):

```lua
  local appearance_diagnostics = require("canvasdiff.appearance")
    .audit(config.user_opts.highlights, config.user_opts.profile)
```

- [ ] **Step 7: Run the wiring test, then every suite**

Run: `make test SUITE=fault FILTER='reaches the appearance manager'`
Expected: PASS

Run: `NVIM_LOG_FILE=/tmp/canvasdiff-test.log make test`
Expected: full suite passes.

- [ ] **Step 8: Commit**

```bash
git add lua/canvasdiff/config/settings.lua lua/canvasdiff/App.lua \
  lua/canvasdiff/health.lua test/unit/test_config.lua test/fault/test_palette.lua
git commit -m "config: profile option wired through App and checkhealth"
```

---

### Task 4: Documentation

**Files:**
- Modify: `README.md` ("Change appearance" section and the configuration
  reference block)
- Modify: `doc/canvasdiff.txt` (configuration section; find it with
  `grep -n "highlights" doc/canvasdiff.txt`)
- Modify: `docs/design.md` (after the palette-factor section)

**Interfaces:**
- Consumes: the shipped behavior from Tasks 1–3. No code.
- Produces: user-facing docs; no other task depends on this.

- [ ] **Step 1: README — replace the recipe intro with the profile option**

In the "Change appearance" section, the paragraph that begins "The default
palette is deliberately quiet" currently ends with the three-link recipe.
Rewrite that passage to:

```markdown
The default palette is deliberately quiet: added and changed rows carry a
neutral elevation derived from your colorscheme, and the green/red lives only
on the `+`/`-` prefix and the gutter, so syntax highlighting stays readable
inside hunks. `profile` selects a different default vocabulary for the diff
rows — colors only, element toggles are independent:

```lua
require("canvasdiff").setup({
  profile = "classic", -- "quiet" (default) | "classic" | "mono"
})
```

- `quiet` — neutral row elevation; hue only on the prefix and gutter.
- `classic` — traditional `DiffAdd`/`DiffDelete` row washes.
- `mono` — no hue anywhere: elevation, dimming, and `+`/`-` shapes carry
  everything (colorblind-safe, monochrome-terminal-safe).

Explicit `highlights` overrides win over any profile, so the equivalent of
`classic` can also be rolled by hand — or partially, for one group:

```lua
require("canvasdiff").setup({
  highlights = {
    CanvasDiffAdd = { link = "DiffAdd" },
    CanvasDiffDel = { link = "DiffDelete" },
    CanvasDiffGhost = { link = "DiffDelete" },
  },
})
```
```

Also add `profile = "quiet",` to the complete configuration reference block
(next to `highlights = {}`), and a sentence to the prose after the block:
`profile` selects the diff-row color vocabulary; unknown names are
diagnosed and fall back to quiet.

- [ ] **Step 2: vimdoc**

In `doc/canvasdiff.txt`, add an option entry alongside `highlights`
(follow the file's existing option-entry format exactly — read two
neighbouring entries first):

```
profile                                               *canvasdiff-profile*
    Which default colour vocabulary the diff rows derive. One of:
        "quiet"    neutral row elevation; green/red only on the +/- margin
                   (the default)
        "classic"  traditional DiffAdd/DiffDelete row washes
        "mono"     no hue anywhere; luminance and +/- shapes carry direction
    Colors only: element toggles (statuscolumn, scrollbar) are independent,
    and explicit |canvasdiff-highlights| overrides win over any profile.
    Unknown names are reported and fall back to "quiet".
```

- [ ] **Step 3: design.md**

Append a short section after the palette-factor material in
`docs/design.md`:

```markdown
## Profiles are colors only

`profile` swaps which *defaults* the eleven diff-row groups derive — quiet
(the measured palette above), classic (`DiffAdd`/`DiffDelete` links, the
scheme's own vocabulary, deliberately unguarded), and mono (zero chroma;
the `+` margin at `Normal`'s foreground, the `-` margin at the ghost dim,
minimap marks collapsed to the shared elevation). Profiles never change
what is drawn, and every profile output stays a `default = true`
definition beneath colorschemes and explicit overrides. A `tinted` profile
(diff hue blended into the elevation, the file bar's chroma-over-luma
trick applied to rows) is deferred until its factors are measured under
the builtin dark scheme and tokyonight-moon with the same rigor as the
budgets above.
```

- [ ] **Step 4: Verify docs render and nothing broke**

Run: `make test SUITE=architecture` (the help/architecture tests parse the
vimdoc; fix any tag or width complaints they raise)
Run: `nvim --headless --clean -c "helptags doc/" -c q` — expected: no error.

- [ ] **Step 5: Commit**

```bash
git add README.md doc/canvasdiff.txt docs/design.md
git commit -m "docs: profile option (quiet/classic/mono)"
```
