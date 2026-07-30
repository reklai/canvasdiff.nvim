# Global Checkout Keymap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe process-wide `<leader>lc` checkout mapping, make global
mapping reconciliation action-aware, clarify refresh wording, and document the
two ways out of a read-only branch comparison.

**Architecture:** Extend the existing key registry and authenticated global-map
reconciler rather than creating a second installation path. Desired and owned
mapping records carry an allowlisted action, so each callback routes to the
correct `App` method and reconfiguration cannot retain a callback for the old
action. Comparison exit behavior stays in the existing lens and Surface
landing models; this change pins and documents those contracts.

**Tech Stack:** Lua, Neovim global and buffer-local keymap APIs, CanvasDiff's
custom headless test harness, Git fixtures, Markdown, Vim help.

## Global Constraints

- `keymaps.global.compare` defaults to `<leader>lb`.
- `keymaps.global.checkout` defaults to `<leader>lc`.
- Compare calls `App:compare()` and checkout calls `App:checkout()`.
- Each global action independently accepts a string, dense list, `false`, `""`,
  or `{}`.
- Existing foreign mappings win and are never overwritten or deleted.
- CanvasDiff removes only mappings authenticated by exact callback, behavior,
  and complete observable Neovim keymap identity.
- A duplicate effective lhs across compare and checkout is rejected before any
  mapping mutation.
- A configured action can dispatch only an allowlisted CanvasDiff method.
- Checkout remains strict-local-branch-only and retains its current safety
  guards and Surface rebuild lifecycle.
- The `r` action description is exactly `Refresh the current diff`.
- `<Tab>` and `<Shift-Tab>` leave a committed comparison at
  `HEAD → WORKTREE`.
- `q` closes the review and restores its captured landing buffer.
- No dedicated comparison-exit mapping is added.
- Review accepts a scoped lifecycle review with no Critical or Important
  finding, rejects scenarios outside the documented Neovim/Git trust and
  platform boundary, does not reopen accepted areas without a concrete
  supported-behavior regression, and stops after five repair rounds.
- Verification ends with one fresh authoritative full-suite run. Performance,
  live-scale, and chaos campaigns are out of scope because this change does
  not alter collection, rendering, paging, compression, or controller costs.

---

### Task 1: Make authenticated global mappings action-aware

**Files:**
- Modify: `lua/canvasdiff/config/settings.lua:63-132`
- Modify: `lua/canvasdiff/input/keys.lua:19-42`
- Modify: `lua/canvasdiff/App.lua:145-520`
- Modify: `test/unit/test_config.lua:28-70`
- Modify: `test/unit/test_keys.lua:190-710`

**Interfaces:**
- Consumes:
  - `keys.resolved("global", keymaps) -> { action, lhs, desc, group }[]`
  - `App:compare()`
  - `App:checkout()`
  - `vim.api.nvim_get_keymap("n")`
  - injected `global_keymap_effects.get/set/del`
- Produces:
  - `config.defaults.keymaps.global.checkout = "<leader>lc"`
  - authenticated mapping records with `action = "compare" | "checkout"`
  - callbacks dispatched only through the allowlisted global action table
  - atomic validation of all configured effective global keys

- [ ] **Step 1: Add failing default and key-registry tests**

In `test/unit/test_config.lua`, extend the default and independent-override
assertions:

```lua
H.eq(config.options.keymaps.global.compare, "<leader>lb")
H.eq(config.options.keymaps.global.checkout, "<leader>lc")

with_setup({
  keymaps = { global = { compare = false } },
}, function(opts)
  H.eq(opts.keymaps.global.compare, false)
  H.eq(opts.keymaps.global.checkout, "<leader>lc",
    "disabling compare leaves checkout at its default")
end)

with_setup({
  keymaps = { global = { checkout = false } },
}, function(opts)
  H.eq(opts.keymaps.global.compare, "<leader>lb")
  H.eq(opts.keymaps.global.checkout, false,
    "disabling checkout leaves compare at its default")
end)
```

In `test/unit/test_keys.lua`, replace the compare-only registry test with:

```lua
T["keys_global actions are described and independently configurable"] = function()
  local km = defaults()
  H.eq(find(keys.resolved("global", km), "compare"), { "<leader>lb" })
  H.eq(find(keys.resolved("global", km), "checkout"), { "<leader>lc" })

  local by_action = {}
  for _, mapping in ipairs(keys.resolved("global", km)) do
    by_action[mapping.action] = mapping
  end
  H.eq(by_action.compare.desc, "Compare two branches or revisions")
  H.eq(by_action.checkout.desc, "Checkout a local branch")
  H.eq(by_action.compare.group, "Global")
  H.eq(by_action.checkout.group, "Global")

  km.global.compare = { "gb", "gB" }
  km.global.checkout = false
  H.eq(find(keys.resolved("global", km), "compare"), { "gb", "gB" })
  H.eq(find(keys.resolved("global", km), "checkout"), {})
end
```

Extend `keys_collisions` coverage:

```lua
local km = defaults()
km.global.compare = "<leader>lx"
km.global.checkout = "<leader>lx"
local collision = keys.collisions("global", km)
H.eq(collision[1].lhs, "<leader>lx")
H.eq(collision[1].actions, { "compare", "checkout" })
```

- [ ] **Step 2: Run the registry tests and verify RED**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-global-keymap-config-red.log \
  make test SUITE=unit FILTER='^config_'
NVIM_LOG_FILE=/tmp/canvasdiff-global-keymap-keys-red.log \
  make test SUITE=unit FILTER='^keys_'
```

Expected: the checkout default and registry assertions fail because only
`global.compare` exists. Existing compare lifecycle tests may remain green.

- [ ] **Step 3: Add failing routing and reconfiguration tests**

First add a helper that prevents a test concerned with one global action from
leaking the other default:

```lua
local function no_global_maps()
  return { compare = false, checkout = false }
end
```

Update compare-only lifecycle setups and cleanup calls to explicitly disable
checkout when the test needs a clean global namespace. Do not globally disable
checkout in tests whose purpose is independent configuration.

Replace the default callback test with one that patches and restores both
methods:

```lua
T["keys_global defaults route compare and checkout to the current App"] = function()
  delete_global("<leader>lb")
  delete_global("<leader>lc")
  package.loaded["canvasdiff"] = nil

  local App = require("canvasdiff.App")
  local real_compare, real_checkout = App.compare, App.checkout
  local calls = { compare = 0, checkout = 0 }
  App.compare = function(self)
    calls.compare = calls.compare + 1
    return self
  end
  App.checkout = function(self)
    calls.checkout = calls.checkout + 1
    return self
  end

  local fm = require("canvasdiff")
  assert(global_map("<leader>lb")).callback()
  assert(global_map("<leader>lc")).callback()
  H.eq(calls, { compare = 1, checkout = 1 })

  fm.setup({ keymaps = { global = no_global_maps() } })
  App.compare, App.checkout = real_compare, real_checkout
  delete_global("<leader>lb")
  delete_global("<leader>lc")
  config.setup({})
end
```

Add independent-list/disable coverage:

```lua
T["keys_global actions rebind and disable independently"] = function()
  local compare_lhs, checkout_a, checkout_b = "gAa", "gAb", "gAc"
  local fm = require("canvasdiff")
  fm.setup({ keymaps = { global = {
    compare = compare_lhs,
    checkout = { checkout_a, checkout_b },
  } } })
  assert(global_map(compare_lhs))
  assert(global_map(checkout_a))
  assert(global_map(checkout_b))

  fm.setup({ keymaps = { global = {
    compare = false,
    checkout = checkout_b,
  } } })
  H.eq(global_map(compare_lhs), nil)
  H.eq(global_map(checkout_a), nil)
  assert(global_map(checkout_b),
    "disabling compare cannot remove the retained checkout mapping")

  fm.setup({ keymaps = { global = no_global_maps() } })
end
```

Add the stale-callback regression:

```lua
T["keys_global changing an owned lhs action replaces its callback"] = function()
  local lhs = "gAd"
  local fm = require("canvasdiff")
  local App = require("canvasdiff.App")
  local real_compare, real_checkout = App.compare, App.checkout
  local calls = { compare = 0, checkout = 0 }
  App.compare = function() calls.compare = calls.compare + 1 end
  App.checkout = function() calls.checkout = calls.checkout + 1 end

  fm.setup({ keymaps = { global = {
    compare = lhs, checkout = false,
  } } })
  local compare_callback = assert(global_map(lhs)).callback
  compare_callback()

  fm.setup({ keymaps = { global = {
    compare = false, checkout = lhs,
  } } })
  local checkout_callback = assert(global_map(lhs)).callback
  assert(not rawequal(compare_callback, checkout_callback),
    "the old action callback cannot be retained")
  checkout_callback()
  H.eq(calls, { compare = 1, checkout = 1 })

  fm.setup({ keymaps = { global = no_global_maps() } })
  App.compare, App.checkout = real_compare, real_checkout
  delete_global(lhs)
  config.setup({})
end
```

Add post-termcode collision atomicity:

```lua
T["keys_global rejects cross-action effective collisions before mutation"] = function()
  local old_leader = vim.g.mapleader
  vim.g.mapleader = " "
  local old_compare, old_checkout = "gAe", "gAf"
  local collided = "<Space>lx"
  local fm = require("canvasdiff")

  fm.setup({ keymaps = { global = {
    compare = old_compare, checkout = old_checkout,
  } } })
  local messages = capture_notifications(function()
    fm.setup({ keymaps = { global = {
      compare = "<leader>lx", checkout = collided,
    } } })
  end)
  assert(global_map(old_compare) and global_map(old_checkout),
    "invalid desired state cannot remove the prior valid state")
  H.eq(global_map(collided), nil)
  assert(messages[1].level == vim.log.levels.ERROR)
  assert(messages[1].message:find("same lhs", 1, true))

  fm.setup({ keymaps = { global = no_global_maps() } })
  vim.g.mapleader = old_leader
end
```

Run the existing foreign-collision, takeover, module-reload, API-fault, and
notification-reentry cases for both defaults by leaving their ownership
assertions intact and making their setup tables explicitly name the action
under test. Add one checkout foreign-collision case so action routing cannot
bypass the established ownership policy.

- [ ] **Step 4: Run global lifecycle tests and verify RED**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-global-keymap-lifecycle-red.log \
  make test SUITE=unit FILTER='^keys_global'
```

Expected: checkout routes to compare, independent setup leaves incorrect
records, an owned lhs cannot safely change action, and canonical cross-action
collision diagnostics still use compare-only assumptions.

- [ ] **Step 5: Add checkout and refresh metadata**

In `lua/canvasdiff/config/settings.lua`, change the global defaults to:

```lua
global = {
  -- Process-wide defaults. App installs each conservatively: an existing
  -- user/plugin mapping wins, and setup removes only authenticated ownership.
  compare = "<leader>lb",
  checkout = "<leader>lc",
},
```

In `lua/canvasdiff/input/keys.lua`, declare both global actions and replace the
refresh copy:

```lua
{ ctx = "global", action = "compare", group = "Global",
  desc = "Compare two branches or revisions" },
{ ctx = "global", action = "checkout", group = "Global",
  desc = "Checkout a local branch" },

{ ctx = "canvas", action = "refresh", group = "Canvas",
  desc = "Refresh the current diff" },
```

- [ ] **Step 6: Generalize complete desired-state validation**

In `lua/canvasdiff/App.lua`, add a closed dispatch table:

```lua
local GLOBAL_ACTION_ORDER = { "compare", "checkout" }
local GLOBAL_ACTIONS = {
  compare = function(app) return app:compare() end,
  checkout = function(app) return app:checkout() end,
}
```

Extract the compare-only raw-shape validation into:

```lua
local function validate_global_action(action, raw)
  if raw == nil or raw == false or raw == "" then
    return
  end
  if native_type(raw) ~= "string" and native_type(raw) ~= "table" then
    return ("global %s mapping must be a string or list, got %s")
      :format(action, native_type(raw))
  end
  if native_type(raw) == "table" then
    local max_index, count = 0, 0
    local index = native_next(raw)
    while index ~= nil do
      if native_type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
        return ("global %s mapping must be a dense list of lhs strings")
          :format(action)
      end
      max_index = math.max(max_index, index)
      count = count + 1
      index = native_next(raw, index)
    end
    if max_index ~= count then
      return ("global %s mapping must be a dense list of lhs strings")
        :format(action)
    end
  end
end
```

At the start of `desired_global_maps()`, validate every allowlisted action
before resolving any lhs:

```lua
for _, action in native_ipairs(GLOBAL_ACTION_ORDER) do
  local err = validate_global_action(action, global_config[action])
  if err then return nil, nil, err end
end
```

For every resolved mapping, require `GLOBAL_ACTIONS[mapping.action]`, use the
action name in type/empty/length diagnostics, store
`action = mapping.action` in the desired request, and reject a canonical
duplicate with both action names:

```lua
if desired[lhs] then
  return nil, nil,
    ("global mappings %s %q and %s %q resolve to the same lhs")
      :format(
        desired[lhs].action,
        desired[lhs].configured_lhs,
        mapping.action,
        mapping.lhs)
end
desired[lhs] = {
  action = mapping.action,
  configured_lhs = mapping.lhs,
  desc = mapping.desc,
}
```

This validation must finish before `reconcile_global_keymaps()` copies,
installs, or removes ledger entries.

- [ ] **Step 7: Carry action identity through ownership reconciliation**

Add `action = request.action` in `expected_record()` and retain it in
`record_from_map()`:

```lua
local function record_from_map(record, map)
  return {
    lhs = record.lhs,
    action = record.action,
    installed_lhs = map.lhs or record.installed_lhs,
    callback = record.callback,
    identity = map_identity(map),
  }
end
```

Keep an existing record only when both ownership and desired action match:

```lua
local request = desired[record.lhs]
if request
    and record.action == request.action
    and owns_global_map(record, map) then
  kept[record.lhs] = record_from_map(record, map)
end
```

When a desired lhs is occupied, distinguish a foreign collision from the
authenticated old action on that exact lhs:

```lua
local prior_owned
for _, record in native_ipairs(app.global_maps) do
  if record.lhs == lhs and owns_global_map(record, occupied) then
    prior_owned = record
    break
  end
end

if occupied and not prior_owned then
  collisions[#collisions + 1] = {
    kind = "collision",
    request = request,
    lhs = lhs,
    occupied = occupied,
  }
else
  -- Install the desired callback; nvim_set_keymap replaces only the
  -- authenticated old action when `prior_owned` is present.
end
```

Build callbacks only through the allowlist:

```lua
local dispatch = GLOBAL_ACTIONS[request.action]
local callback = function()
  return dispatch(app)
end
```

Do not append the tentative replacement to `candidates` until the setter
returns successfully. If a same-lhs setter throws before writing, settling the
unchanged candidates must preserve authority over the old mapping. If it
writes and then throws, subsequent inspection must conservatively treat the
new observable mapping as foreign. After successful verification, append
`record_from_map(tentative, installed)` so `compact_candidates()` selects the
new action record for that lhs.

Do not weaken `map_identity`, `owns_global_map`, captured native API use,
install-before-delete for different lhs values, pending/reentry coalescing, or
collision notification deduplication.

- [ ] **Step 8: Run focused GREEN verification**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-global-keymap-config-green.log \
  make test SUITE=unit FILTER='^config_'
NVIM_LOG_FILE=/tmp/canvasdiff-global-keymap-keys-green.log \
  make test SUITE=unit FILTER='^keys_'
```

Expected: all configuration, registry, callback routing, independent override,
effective-collision, takeover, reload, reentry, and injected-fault tests pass.

- [ ] **Step 9: Commit the action-aware mapping behavior**

```bash
git add \
  lua/canvasdiff/config/settings.lua \
  lua/canvasdiff/input/keys.lua \
  lua/canvasdiff/App.lua \
  test/unit/test_config.lua \
  test/unit/test_keys.lua
git commit -m "feat: add global checkout keymap"
```

---

### Task 2: Pin comparison exits and update discoverability

**Files:**
- Modify: `test/integration/test_lens.lua:658-668`
- Modify: `test/integration/test_root.lua:1466-1600`
- Modify: `test/unit/test_cheatsheet.lua:35-75,155-175`
- Modify: `test/integration/test_cheatsheet_float.lua:7-30`
- Modify: `README.md:20-55,270-355,370-405,455-580,680-695`
- Modify: `doc/canvasdiff.txt:100-190,230-295,405-420`
- Modify: `docs/architecture.md:84-112,185-195`

**Interfaces:**
- Consumes:
  - `lens.step(CanvasDiffLens, delta) -> CanvasDiffLens`
  - existing canvas `q` mapping to `App:close()`
  - `Surface:landing_buffer(win)`
  - `keys.grouped()` and `cheatsheet.model()`
- Produces:
  - regression coverage for both comparison exits
  - cheatsheet rows for compare and checkout
  - exact displayed refresh copy
  - matching README, Vim help, and architecture descriptions

- [ ] **Step 1: Add comparison-exit characterization tests**

Extend `lens_step cycles the three named lenses` in
`test/integration/test_lens.lua`:

```lua
local range = assert(lens.range("main", "topic", "..."))
H.eq(lens.step(range, 1).id, "all",
  "Tab leaves a committed comparison at HEAD → WORKTREE")
H.eq(lens.step(range, -1).id, "all",
  "Shift-Tab leaves a committed comparison at HEAD → WORKTREE")
```

In `test/integration/test_root.lua`, add a real picker/canvas regression using
the existing `picker_fixture()`, `item_named()`, and cleanup helpers. Cover two
phases:

```lua
-- Phase 1: comparison opened from a normal buffer.
local origin = vim.api.nvim_get_current_buf()
app:compare()
calls[1].callback(item_named(calls[1].items, "main"))
calls[2].callback(item_named(calls[2].items, "zeta"))
local surface = assert(app.opened[#app.opened])
local q = assert(mapping_for(surface.state.buf, "q"))
q.callback()
H.eq(vim.api.nvim_get_current_buf(), origin,
  "q restores the buffer that initiated a newly opened comparison")

-- Phase 2: comparison replaces the lens of an existing canvas.
local state = assert(app:open())
local original_landing = origin
app:compare()
calls[3].callback(item_named(calls[3].items, "main"))
calls[4].callback(item_named(calls[4].items, "zeta"))
local q_again = assert(mapping_for(state.buf, "q"))
q_again.callback()
H.eq(vim.api.nvim_get_current_buf(), original_landing,
  "q retains the canvas's original landing rather than landing on itself")
```

Define `mapping_for(buf, lhs)` in the test file by scanning
`vim.api.nvim_buf_get_keymap(buf, "n")`. Invoke the installed `q` callback, not
`app:close()` directly, so the assertion covers the user gesture.

- [ ] **Step 2: Run comparison-exit tests**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-comparison-exits.log \
  make test SUITE=integration FILTER='^lens_step'
NVIM_LOG_FILE=/tmp/canvasdiff-comparison-landings.log \
  make test SUITE=integration FILTER='comparison exits'
```

Expected: both tests pass without production changes. They pin behavior already
provided by `lens.step()` and Surface landing ownership so the new global entry
point cannot regress it.

- [ ] **Step 3: Update cheatsheet assertions**

In `test/unit/test_cheatsheet.lua`, require both global actions and exact
refresh copy:

```lua
H.eq(where.compare, "Global")
H.eq(where.checkout, "Global")

-- While scanning Global rows:
H.eq(rows.compare.keys, { "<leader>lb" })
H.eq(rows.compare.desc, "Compare two branches or revisions")
H.eq(rows.checkout.keys, { "<leader>lc" })
H.eq(rows.checkout.desc, "Checkout a local branch")

-- In the rendered lines:
assert(joined:find("Refresh the current diff", 1, true))
assert(not joined:find("Re-scan", 1, true))
```

In `test/integration/test_cheatsheet_float.lua`, extend the overlay test:

```lua
assert(joined:find("<leader>lb", 1, true))
assert(joined:find("<leader>lc", 1, true))
assert(joined:find("Refresh the current diff", 1, true))
```

When constructing an all-disabled keymap in that file, include:

```lua
global = { compare = false, checkout = false },
```

- [ ] **Step 4: Run cheatsheet verification**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-checkout-cheatsheet-unit.log \
  make test SUITE=unit FILTER='^cheatsheet_'
NVIM_LOG_FILE=/tmp/canvasdiff-checkout-cheatsheet-integration.log \
  make test SUITE=integration FILTER='^cheatsheet_'
```

Expected: every model, rendering, override, disabled-state, and float test
passes with both global actions and the exact refresh description.

- [ ] **Step 5: Update README behavior and configuration**

In `README.md`:

- introduce both startup defaults: `<leader>lb` compares local branches and
  `<leader>lc` checks out a local branch;
- show both values under `keymaps.global`;
- describe independent string/list/disabled configuration;
- retain the rule that an occupied foreign lhs wins;
- state that compare/checkout effective-key collisions are rejected before
  global mapping mutation;
- replace action-table and cheatsheet refresh text with exactly
  `Refresh the current diff`;
- keep implementation details about recollection and position preservation in
  prose rather than the key description;
- state that `<Tab>` or `<Shift-Tab>` leaves a read-only range at
  `HEAD → WORKTREE`, while `q` closes the review and restores the buffer from
  which its canvas was entered;
- keep `:CanvasDiff all` and `:CanvasDiff close` as command equivalents;
- correct the stale manual-refresh example from uppercase `R` to lowercase
  `r`.

Use this configuration example:

```lua
keymaps = {
  global = {
    compare = "<leader>lb",
    checkout = "<leader>lc",
  },
}
```

- [ ] **Step 6: Update Vim help and architecture**

In `doc/canvasdiff.txt`:

- list `<leader>lb` as local-branch comparison and `<leader>lc` as local
  checkout under `Global`;
- replace “only process-wide default” with the two-default contract;
- remove stale claims that the picker prioritizes remote defaults or detached
  `HEAD`;
- show `global.checkout` in the configuration table;
- describe ownership for global actions, not only `global.compare`;
- document the `<Tab>`/`<Shift-Tab>` and `q` comparison exits;
- use `Refresh the current diff` for the `r` mapping;
- mention both global action names in the collision troubleshooting entry.

In `docs/architecture.md`, update the keymap ownership section:

```text
The process-wide compare and checkout keymaps follow the same identity rule.
Each desired and owned record carries its allowlisted action. Reconciliation
retains a mapping only when its effective lhs, action, callback, behavior, and
complete observable Neovim identity still match.
```

Also state that canonical cross-action collisions are rejected before mutation
and that an authenticated same-lhs action change replaces only CanvasDiff's
own prior callback. Do not change the documented pre-initialization trust
boundary.

- [ ] **Step 7: Run focused documentation-adjacent suites**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-global-docs-unit.log \
  make test SUITE=unit FILTER='^keys_'
NVIM_LOG_FILE=/tmp/canvasdiff-global-docs-cheatsheet.log \
  make test SUITE=unit FILTER='^cheatsheet_'
NVIM_LOG_FILE=/tmp/canvasdiff-global-docs-integration.log \
  make test SUITE=integration FILTER='comparison exits'
NVIM_LOG_FILE=/tmp/canvasdiff-global-docs-architecture.log \
  make architecture
```

Expected: all selected tests and architecture boundaries pass.

- [ ] **Step 8: Commit comparison exit and documentation coverage**

```bash
git add \
  test/integration/test_lens.lua \
  test/integration/test_root.lua \
  test/unit/test_cheatsheet.lua \
  test/integration/test_cheatsheet_float.lua \
  README.md \
  doc/canvasdiff.txt \
  docs/architecture.md
git commit -m "docs: clarify global mappings and comparison exits"
```

---

### Task 3: Run bounded adversarial review and authoritative verification

**Files:**
- Create: `.superpowers/adversarial/global-checkout-keymap-20260731/receipt.json`
- Modify only if a supported-behavior regression is found:
  - `lua/canvasdiff/config/settings.lua`
  - `lua/canvasdiff/input/keys.lua`
  - `lua/canvasdiff/App.lua`
  - relevant tests and documentation from Tasks 1-2

**Interfaces:**
- Consumes:
  - the committed Task 1 and Task 2 diffs
  - repository `AGENTS.md` adversarial-development policy
  - the approved design specification
- Produces:
  - independent review decisions
  - at most five evidence-based repair rounds
  - one fresh authoritative full-suite result
  - finalized adversarial receipt

- [ ] **Step 1: Initialize the adversarial receipt and review scope**

Use the adversarial-development skill to initialize:

```text
.superpowers/adversarial/global-checkout-keymap-20260731/receipt.json
```

Record the supported scope as:

```text
Neovim normal-mode global mappings, CanvasDiff configuration and App
lifecycle, strict local-branch checkout, authenticated ownership under the
documented post-initialization native-API trust boundary, cheatsheet/help/docs,
and comparison exit behavior.
```

Record explicit exclusions:

```text
pre-compromised Neovim API tables, arbitrary hostile Lua already executing
before App initialization, unsupported platforms, network/fetch behavior,
force/stash/detach semantics, renderer scale, paging, compression, and
performance campaigns.
```

- [ ] **Step 2: Run focused pre-review verification**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-global-checkout-focused.log \
  make test SUITE=unit FILTER='^config_'
NVIM_LOG_FILE=/tmp/canvasdiff-global-checkout-keys.log \
  make test SUITE=unit FILTER='^keys_'
NVIM_LOG_FILE=/tmp/canvasdiff-global-checkout-cheatsheet.log \
  make test SUITE=unit FILTER='^cheatsheet_'
NVIM_LOG_FILE=/tmp/canvasdiff-global-checkout-checkout.log \
  make test SUITE=integration FILTER='checkout'
NVIM_LOG_FILE=/tmp/canvasdiff-global-checkout-compare.log \
  make test SUITE=integration FILTER='compare'
NVIM_LOG_FILE=/tmp/canvasdiff-global-checkout-exits.log \
  make test SUITE=integration FILTER='comparison exits'
NVIM_LOG_FILE=/tmp/canvasdiff-global-checkout-architecture.log \
  make architecture
```

Expected: zero failures before independent review.

- [ ] **Step 3: Dispatch independent implementation and lifecycle reviewers**

Give reviewers the design, plan, committed diff, focused test evidence, and
the exact supported/excluded boundary. Require findings to identify:

```text
severity, supported observable behavior, reproduction or concrete failing
test, affected ownership invariant, and smallest repair.
```

Reviewer A checks public configuration, callback routing, atomic collision
validation, exact action identity, docs, and tests. Reviewer B independently
checks same-lhs action replacement, foreign takeover, module reload, reentry,
write-then-throw/delete/get failures, and landing-buffer behavior.

Accept the scoped review immediately when neither reviewer reports a
Critical or Important supported-behavior issue. Minor copy or style
observations may be parked in the receipt and do not trigger scope expansion.

- [ ] **Step 4: Repair only concrete supported regressions**

For each accepted Critical or Important finding:

1. add or identify a failing focused regression test;
2. run it and capture RED evidence;
3. implement the smallest in-scope repair;
4. run the focused lane and capture GREEN evidence;
5. request a scoped re-review of that finding only.

Stop after five total repair rounds. Do not reopen an accepted area without a
new concrete regression in supported behavior. Reject hypothetical attacks
that require crossing the documented trust/platform boundary.

- [ ] **Step 5: Run one fresh authoritative full suite**

After the scoped review is accepted, run exactly one fresh authoritative
suite:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-global-checkout-full.log make test
```

Expected: every discovered test passes with zero failures. Do not run
`make verify`, benchmarks, chaos, or live-scale campaigns for this task.

- [ ] **Step 6: Finalize and validate the receipt**

Record:

- implementation and documentation commit SHAs;
- reviewer identities and dispositions;
- every repair round, capped at five;
- parked Minor observations;
- rejected out-of-boundary scenarios and why they are outside the documented
  contract;
- focused verification commands and outcomes;
- the authoritative full-suite command, test count, exit code, and timestamp;
- final disposition `accepted` only if no Critical or Important issue remains.

Validate the receipt using the adversarial-development skill's required
validator, then inspect:

```bash
git status --short
git diff --check
```

Expected: only the finalized receipt is uncommitted and no whitespace error is
reported.

- [ ] **Step 7: Commit the finalized evidence**

```bash
git add .superpowers/adversarial/global-checkout-keymap-20260731/receipt.json
git commit -m "chore: record global checkout keymap verification"
```
