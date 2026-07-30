# Branch-First Compare Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the interactive comparison workflow choose two strict local
branches while preserving explicitly typed advanced revision ranges.

**Architecture:** Keep repository metadata and explicit revision parsing
unchanged. `App:compare()` projects repository records through the existing
`source.local_branches()` helper, orders those local records for the base and
target pickers, and continues constructing a three-dot range from their exact
`refs/heads/*` identities. Documentation presents branches as the default
product model and keeps remote-tracking refs only in the explicit advanced
range and tracking workflows.

**Tech Stack:** Lua, Neovim `vim.ui.select`, Git refs, the repository's custom
headless Lua test harness, Markdown.

## Global Constraints

- The interactive `:CanvasDiff compare` picker contains only `refs/heads/*`.
- Remote-tracking refs, symbolic remote defaults, and detached `HEAD` never
  appear in either interactive picker.
- The base order is local `main`, local `master`, then remaining local branches
  in deterministic repository order.
- The target order is the checked-out local branch, then remaining local
  branches in deterministic repository order.
- Visible picker text uses branch names; `[checked out]` remains the only
  branch-role suffix.
- Range execution uses the selected records' exact full local refs.
- Explicit typed revisions and their completion remain backward compatible,
  including remote-tracking refs, tags, and commits.
- Checkout, track, mutation, comparison fencing, Surface ownership, and Git
  diff semantics do not change.
- Detached `HEAD` is not an interactive comparison choice.
- No fetch or other network operation is introduced.
- The supported boundary remains local Git and Neovim on the repository's
  documented platforms.

---

### Task 1: Restrict interactive comparison to local branches

**Files:**
- Modify: `lua/canvasdiff/App.lua`
- Modify: `test/integration/test_root.lua`
- Modify: `README.md`
- Modify: `docs/architecture.md`

**Interfaces:**
- Consumes:
  - `source.branches(root) -> table[]|nil, string|nil`
  - `source.local_branches(items) -> table[]`
  - `source.format_ref(item) -> string`
  - `lens.range(left, right, "...") -> CanvasDiffLens`
- Produces:
  - `App:compare()` with two local-branch-only pickers
  - prompt strings `CanvasDiff compare from branch:` and
    `CanvasDiff compare to branch:`
  - unchanged explicit range grammar and command completion

- [ ] **Step 1: Rewrite the picker contract test for strict local branches**

In `test/integration/test_root.lua`, change
`root_ compare picker orders metadata choices and cancels silently` so its
fixture still contains local branches, remote defaults, and remote-tracking
branches, but asserts:

```lua
H.eq(names(calls[1].items), {
  "main", "master", "zeta",
}, "the base picker contains local branches only")
H.eq(names(calls[2].items), {
  "zeta", "main", "master",
}, "the target picker puts the checked-out local branch first")
H.eq(calls[1].items[1].ref, "refs/heads/main",
  "picker execution keeps the exact full local ref")
H.eq(calls[1].opts.prompt, "CanvasDiff compare from branch:")
H.eq(calls[2].opts.prompt, "CanvasDiff compare to branch:")
H.eq(calls[1].opts.format_item(calls[1].items[1]), "main")
H.eq(calls[2].opts.format_item(calls[2].items[1]),
  "zeta [checked out]")
```

Keep the existing `command_complete("origin/")` and range-completion
assertions. They prove explicit advanced completion remains unchanged.
Keep both cancellation assertions and their buffer/message invariants.

- [ ] **Step 2: Rewrite collision and detached-HEAD tests**

Change the tag-collision test to expect:

```lua
H.eq(names(calls[1].items), {
  "heads/main", "master", "zeta",
})
H.eq(calls[1].items[1].ref, "refs/heads/main")
```

Rename the detached test to
`root_ detached compare picker still lists strict local branches`. After
detaching, select local `main` as the base, cancel the target picker, and
assert:

```lua
H.eq(names(calls[2].items), { "main", "master", "zeta" })
for _, item in ipairs(calls[2].items) do
  assert(item.ref ~= "HEAD", "detached HEAD is not a branch choice")
  H.eq(item.kind, "local")
end
```

- [ ] **Step 3: Add the no-local-branches error regression**

Create a fixture commit, detach `HEAD`, delete every `refs/heads/*` branch, and
leave at least one remote-tracking ref. Invoke `fm.compare()` with a controlled
`vim.ui.select` and assert:

```lua
H.eq(#calls, 0, "remote-tracking refs cannot keep the branch picker alive")
assert(msgs[#msgs].msg:find("no local branches found", 1, true),
  vim.inspect(msgs))
```

Also assert that the current window and buffer are unchanged.

- [ ] **Step 4: Run the focused comparison test and verify RED**

Run:

```bash
make test SUITE=integration FILTER='compare'
make test SUITE=integration FILTER='base priority'
make test SUITE=integration FILTER='no local branches'
```

Expected: the new branch-only ordering, prompts, detached exclusion, and
no-local-branch diagnostic fail against the current mixed-ref picker. The
existing fixed-sidebar exact-range test remains green and demonstrates the
unmodified publication path.

- [ ] **Step 5: Implement the local-branch projection and ordering**

In `lua/canvasdiff/App.lua`, make `base_choices()` operate only on local
records:

```lua
local function base_choices(branches)
  local main
  local master
  local remaining = {}
  for _, item in ipairs(branches) do
    if item.ref == "refs/heads/main" then
      main = item
    elseif item.ref == "refs/heads/master" then
      master = item
    else
      remaining[#remaining + 1] = item
    end
  end
  remaining = sorted_copy(remaining)
  local out = {}
  if main then out[#out + 1] = main end
  if master then out[#out + 1] = master end
  vim.list_extend(out, remaining)
  return out
end
```

Make `comparison_choices()` return the current local record first when one
exists, without synthesizing detached `HEAD`:

```lua
local function comparison_choices(branches)
  local current
  local remaining = {}
  for _, item in ipairs(branches) do
    if item.current then
      current = item
    else
      remaining[#remaining + 1] = item
    end
  end
  remaining = sorted_copy(remaining)
  local out = {}
  if current then out[#out + 1] = current end
  vim.list_extend(out, remaining)
  return out
end
```

Immediately after `source.branches(root)` succeeds in `App:compare()`, project
the records once:

```lua
local local_branches = source.local_branches(branches)
local bases = base_choices(local_branches)
if #bases == 0 then
  local no_branches = "no local branches found"
  ui.warn(no_branches)
  return nil, no_branches
end
local comparisons = comparison_choices(local_branches)
```

Use the approved static prompts:

```lua
prompt = "CanvasDiff compare from branch:"
prompt = "CanvasDiff compare to branch:"
```

Do not change request fencing, range construction, publication, source
collection, or Surface lifecycle code.

- [ ] **Step 6: Run focused GREEN verification**

Run:

```bash
make test SUITE=integration FILTER='compare'
make test SUITE=integration FILTER='base priority'
make test SUITE=integration FILTER='no local branches'
make test SUITE=integration FILTER='^root_ delayed picker'
make test SUITE=unit FILTER='^ref_'
make test SUITE=unit FILTER='^cmd_'
```

Expected: every selected test passes. The delayed-picker lane proves request
fencing was not weakened; ref and command lanes prove track formatting and
explicit completion/parser contracts remain intact.

- [ ] **Step 7: Update user and architecture documentation**

In `README.md`:

- change the command summary to `choose two local branches and compare them`;
- describe the two local-branch-only pickers and their ordering;
- state that remote-tracking snapshots are available only when explicitly
  typed as revision ranges;
- keep checkout/track safety documentation unchanged;
- change the keymap comment to `choose two local branches`.

In `docs/architecture.md`, replace the mixed-ref comparison statement with:

```text
The interactive comparison picker projects repository metadata to local
branches only. Branch names are presentation; exact refs/heads/* identities
build the read-only range lens. Explicit typed ranges retain the broader Git
revision grammar.
```

Do not edit the prior historical design/plan documents.

- [ ] **Step 8: Run static and authoritative verification**

Run:

```bash
git diff --check
make test SUITE=integration FILTER='compare'
make test SUITE=integration FILTER='base priority'
make test SUITE=integration FILTER='no local branches'
make test SUITE=integration FILTER='^root_ delayed picker'
make test SUITE=unit FILTER='^ref_'
make test SUITE=unit FILTER='^cmd_'
make test
```

Expected: static checks, focused tests, and one fresh full suite pass. Do not
run live-scale, performance, or chaos campaigns: this change only removes
picker records and does not touch collection, rendering, paging, compression,
mutation, or lifecycle ownership.

- [ ] **Step 9: Commit the implementation**

```bash
git add lua/canvasdiff/App.lua test/integration/test_root.lua \
  README.md docs/architecture.md
git commit -m "fix: make comparison picker branch-first"
```

The commit must contain only the four files above.
