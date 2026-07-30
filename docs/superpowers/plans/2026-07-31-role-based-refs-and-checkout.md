# Role-Based Refs and Safe Checkout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ambiguous local/remote comparison language with directional role labels and add conservative local checkout and remote-tracking creation workflows.

**Architecture:** Keep full Git refs as execution identities, move pure ref presentation/filtering into a focused source-domain helper, and expose only non-forcing switch operations through the source facade. `App` owns picker request fencing and the post-switch Canvas lifecycle; Git remains authoritative for saved worktree/index overwrite safety while the buffer source domain protects unsaved Neovim content.

**Tech Stack:** Lua 5.1/LuaJIT, Neovim Lua API, synchronous `vim.system` through `canvasdiff.os`, real isolated Git repositories, the existing MiniTest-style Lua suite.

## Global Constraints

- Comparison is always presented as `OLD → NEW`; “local” and “remote” are ref provenance, never diff-side roles.
- Existing lens IDs and `old`/`new` values remain compatible; restored labels are regenerated from identity.
- `checkout` selects only `refs/heads/*`; `track` selects only concrete, non-symbolic `refs/remotes/*`.
- Full refs are authoritative: local switch derives a branch name only from a
  validated `refs/heads/*` identity and uses `--no-guess`; track passes the
  exact full remote ref.
- No fetch, pull, push, force, merge, detach, stash, delete, rename, or network operation.
- Modified loaded buffers inside the repository block checkout and track before Git runs.
- Saved worktree/index overwrite safety is delegated to non-forcing `git switch`; its refusal is preserved.
- A successful Git mutation is never automatically reversed if Canvas rebuilding fails.
- A visible Canvas is rebuilt at `HEAD → WORKTREE`; a hidden or absent Canvas remains hidden.
- Picker callbacks are fenced against cancellation, reentry, closure, replacement, and repository drift.
- No OpenTUI dependency or adapter is added.
- Tests follow strict RED → GREEN → REFACTOR and use real Git repositories at the mutation boundary.
- Review scope is the documented Neovim/Git trust and platform boundary, with at most five repair rounds per task and one final whole-change repair wave.

---

### Task 1: Directional lenses and pure ref semantics

**Files:**
- Create: `lua/canvasdiff/source/ref.lua`
- Modify: `lua/canvasdiff/source.lua`
- Modify: `lua/canvasdiff/diff/lens.lua`
- Modify: `lua/canvasdiff/session/codec.lua`
- Modify: `lua/canvasdiff/App.lua`
- Test: `test/integration/test_lens.lua`
- Test: `test/integration/test_session.lua`
- Test: `test/integration/test_root.lua`
- Create: `test/unit/test_ref.lua`

**Interfaces:**
- Consumes: branch records from `source.branches(root)` with `ref`, `name`, `kind`, `current`, and `remote_default`.
- Produces:
  - `ref.format(item) -> string`
  - `ref.local_branches(items) -> table[]`
  - `ref.remote_tracking(items) -> table[]`
  - `ref.tracking_name(item) -> string|nil, string|nil`
  - `ref.remote_name(item) -> string|nil`
  - source facade aliases `format_ref`, `local_branches`,
    `remote_tracking_branches`, `tracking_branch_name`, and
    `remote_name`.
  - regenerated directional `CanvasDiffLens.label` values.

- [ ] **Step 1: Write failing directional-lens and restoration tests**

Add literal expectations to `test/integration/test_lens.lua`:

```lua
H.eq(lens.get("all").label, "HEAD → WORKTREE")
H.eq(lens.get("unstaged").label, "INDEX → WORKTREE (unstaged)")
H.eq(lens.get("staged").label, "HEAD → INDEX (staged)")
H.eq(lens.branch("refs/heads/main").label, "refs/heads/main → WORKTREE")
H.eq(
  lens.range("main", "topic", "..").label,
  "main → topic")
H.eq(
  lens.range("main", "topic", "...").label,
  "merge-base(main, topic) → topic")
```

Add a session test that restores a valid lens carrying
`label = "worktree vs main"` and asserts the live lens/winbar uses
`main → WORKTREE`, proving labels are derived rather than trusted.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
make test SUITE=integration FILTER='^lens_'
make test SUITE=integration FILTER='^session_'
```

Expected: failures show the old `vs` labels and persisted label reuse.

- [ ] **Step 3: Implement identity-derived lens normalization**

In `lua/canvasdiff/diff/lens.lua`, add a single label derivation path:

```lua
local function label_for(l)
  if l.id == "all" then return "HEAD → WORKTREE" end
  if l.id == "unstaged" then return "INDEX → WORKTREE (unstaged)" end
  if l.id == "staged" then return "HEAD → INDEX (staged)" end
  if range_shape(l) then
    if l.operator == "..." then
      return ("merge-base(%s, %s) → %s"):format(l.old, l.new, l.new)
    end
    return ("%s → %s"):format(l.old, l.new)
  end
  if branch_shape(l) then
    return ("%s → WORKTREE"):format(l.old)
  end
end

function L.normalize(l)
  if not L.valid(l) then return nil end
  local out = {
    id = l.id,
    old = l.old,
    new = l.new,
    operator = l.operator,
  }
  out.label = label_for(l)
  return out
end
```

`L.get`, `L.branch`, `L.range`, and `L.of` must return normalized copies.
Session decoding must validate identity and normalize the lens before
publishing it. Do not change IDs or side fields.

- [ ] **Step 4: Write failing pure ref tests**

Create `test/unit/test_ref.lua` with hand-authored records proving:

```lua
H.eq(ref.format({
  ref = "refs/heads/main", name = "main", kind = "local", current = true,
}), "main [checked out]")
H.eq(ref.format({
  ref = "refs/remotes/origin/HEAD", name = "origin/HEAD",
  kind = "remote", remote_default = true,
}), "origin/HEAD [default for origin]")
H.eq(ref.format({
  ref = "refs/remotes/upstream/topic", name = "upstream/topic",
  kind = "remote",
}), "upstream/topic [remote-tracking ref]")
H.eq(ref.format({
  ref = "refs/heads/topic", name = "topic", kind = "local",
}), "topic")
```

Also assert:

- local filtering excludes every remote ref;
- remote filtering excludes symbolic defaults;
- `origin/feature/api` derives `feature/api`;
- malformed/non-remote records and `origin/HEAD` return `nil` plus a bounded
  diagnostic;
- returned filter lists are copies and preserve input order.

- [ ] **Step 5: Run the pure ref test and verify RED**

Run:

```bash
make test SUITE=unit FILTER='^ref_'
```

Expected: module-not-found failure for `canvasdiff.source.ref`.

- [ ] **Step 6: Implement the pure ref helper and route picker formatting**

Implement `source/ref.lua` without Git or UI dependencies. Export its methods
through `source.lua` as `format_ref`, `local_branches`,
`remote_tracking_branches`, `tracking_branch_name`, and `remote_name`.
Replace `App`'s private `format_branch` body with `source.format_ref`, while
retaining existing base/target ordering.

The remote name must be derived only from the full ref:

```lua
local remote = item.ref:match("^refs/remotes/([^/]+)/HEAD$")
```

Tracking names must derive only from:

```lua
local name = item.ref:match("^refs/remotes/[^/]+/(.+)$")
```

- [ ] **Step 7: Update picker prompt tests and run focused GREEN verification**

Update `test/integration/test_root.lua` to assert:

```lua
H.eq(calls[1].opts.prompt, "CanvasDiff compare from (base):")
H.eq(
  calls[2].opts.prompt,
  "CanvasDiff compare to (merge-base(origin/HEAD, target) → target):")
H.eq(calls[1].opts.format_item(calls[1].items[1]),
  "origin/HEAD [default for origin]")
H.eq(calls[2].opts.format_item(calls[2].items[1]),
  "zeta [checked out]")
```

Run:

```bash
make test SUITE=unit FILTER='^ref_'
make test SUITE=integration FILTER='^lens_'
make test SUITE=integration FILTER='^session_'
make test SUITE=integration FILTER='^root_ compare'
```

Expected: all selected tests pass.

- [ ] **Step 8: Commit Task 1**

```bash
git add lua/canvasdiff/source/ref.lua lua/canvasdiff/source.lua \
  lua/canvasdiff/diff/lens.lua lua/canvasdiff/session/codec.lua \
  lua/canvasdiff/App.lua test/unit/test_ref.lua \
  test/integration/test_lens.lua test/integration/test_session.lua \
  test/integration/test_root.lua
git commit -m "feat: clarify comparison ref roles"
```

---

### Task 2: Safe Git switch primitives and command surface

**Files:**
- Modify: `lua/canvasdiff/source/repository.lua`
- Modify: `lua/canvasdiff/source/buffer.lua`
- Modify: `lua/canvasdiff/source.lua`
- Modify: `lua/canvasdiff/input/command.lua`
- Modify: `lua/canvasdiff.lua`
- Modify: `plugin/canvasdiff.lua`
- Test: `test/integration/test_git.lua`
- Test: `test/unit/test_cmd.lua`

**Interfaces:**
- Consumes: exact full refs selected from `source.branches`.
- Produces:
  - `source.modified_buffer_in_root(root) -> string|nil`
  - `source.switch_branch(root, full_local_ref) -> true|nil, string|nil`
  - `source.track_branch(root, local_name, full_remote_ref) -> true|nil, string|nil`
  - command plans `checkout` and `track`.

- [ ] **Step 1: Write failing command grammar tests**

Extend `test/unit/test_cmd.lua` so `checkout` and `track`:

- parse as reserved actions rather than revisions;
- appear in completion in this order after `compare`;
- plan calls named `checkout` and `track`;
- correspond to functions on the root facade.

The exact candidate order becomes:

```lua
{
  "open", "close", "toggle", "refresh", "compare", "checkout", "track",
  "all", "unstaged", "staged",
}
```

- [ ] **Step 2: Run command tests and verify RED**

Run:

```bash
make test SUITE=unit FILTER='^cmd_'
```

Expected: `checkout` and `track` parse as revisions and are absent from
completion/facade.

- [ ] **Step 3: Add command words, facade methods, and help text**

Add `{ action = "checkout" }` and `{ action = "track" }` before revision
parsing. Export facade methods that delegate to `app:checkout()` and
`app:track()`. Update the user-command description to list both reserved
words. The `App` methods may remain unavailable until Task 3, so focused
grammar tests should use facade functions added in this step.

- [ ] **Step 4: Write failing real-Git mutation tests**

Extend `test/integration/test_git.lua` with isolated repositories proving:

1. `switch_branch(root, "refs/heads/topic")` changes symbolic `HEAD` to
   `topic`.
2. A non-conflicting saved modification survives the switch byte-for-byte.
3. A conflicting saved modification makes the operation return `nil, err`,
   leaves `HEAD` and bytes unchanged, and the diagnostic contains Git's
   refusal.
4. An option-looking or non-local ref is rejected before Git.
5. `track_branch(root, "feature/api",
   "refs/remotes/origin/feature/api")` creates and checks out the local branch,
   and `@{upstream}` resolves to the exact remote ref.
6. A local-name collision and symbolic `refs/remotes/origin/HEAD` are rejected
   without changing `HEAD`.
7. A same-named local and remote ref cannot redirect either operation.

Do not mock process execution; inspect symbolic refs, upstreams, worktree
bytes, and status through real Git.

- [ ] **Step 5: Write failing modified-buffer root test**

Add a real Neovim-buffer test:

```lua
local buf = vim.fn.bufadd(vim.fs.joinpath(root, "nested", "a.txt"))
vim.fn.bufload(buf)
vim.api.nvim_set_option_value("modified", true, { buf = buf })
H.eq(source.modified_buffer_in_root(root),
  vim.fs.joinpath(root, "nested", "a.txt"))
```

Also prove modified buffers in a sibling repository, unnamed buffers, special
buffers, and merely loaded unmodified buffers do not block.

- [ ] **Step 6: Run Git tests and verify RED**

Run:

```bash
make test SUITE=integration FILTER='^git:'
make test SUITE=integration FILTER='^source:'
```

Expected: missing source facade operations.

- [ ] **Step 7: Implement validated non-forcing Git operations**

Add repository validators that require:

```lua
full_ref:match("^refs/heads/.+$")
full_remote_ref:match("^refs/remotes/[^/]+/.+$")
```

and reject `.../HEAD` for tracking. For local checkout, derive `topic` only
from a successfully validated `refs/heads/topic` identity. Git rejects a
fully-qualified local head as the branch argument, so disable its fallback
remote guessing explicitly. Operations must contain only the equivalent of:

```text
git -C <root> switch --no-guess -- <derived-local-name>
git -C <root> switch --no-guess --track -c <local-name> -- <full-remote-ref>
```

No fallback or retry is permitted. Reuse `command_error` for bounded errors.
Check local branch collision through exact ref resolution before track, and
validate the derived local name with `git check-ref-format --branch` before
using it.

Implement `buffer.modified_in_root(root)` using normalized and real paths with
a directory-boundary check, returning the first deterministic sorted absolute
path. Export all operations through `source.lua`.

- [ ] **Step 8: Run focused GREEN verification**

Run:

```bash
make test SUITE=unit FILTER='^cmd_'
make test SUITE=integration FILTER='^git:'
make test SUITE=integration FILTER='^source:'
```

Expected: all selected tests pass and leave no fixture repositories.

- [ ] **Step 9: Commit Task 2**

```bash
git add lua/canvasdiff/source/repository.lua \
  lua/canvasdiff/source/buffer.lua lua/canvasdiff/source.lua \
  lua/canvasdiff/input/command.lua lua/canvasdiff.lua plugin/canvasdiff.lua \
  test/integration/test_git.lua test/unit/test_cmd.lua
git commit -m "feat: add safe branch switch primitives"
```

---

### Task 3: Picker-fenced checkout and tracking lifecycle

**Files:**
- Modify: `lua/canvasdiff/App.lua`
- Modify: `lua/canvasdiff/Surface.lua`
- Test: `test/integration/test_root.lua`
- Test: `test/integration/test_concurrent_reviews.lua`
- Test: `test/e2e/test_e2e.lua`

**Interfaces:**
- Consumes:
  - Task 1 ref filtering/formatting helpers;
  - Task 2 modified-buffer and Git switch operations.
- Produces:
  - `App:checkout() -> true|nil, string|nil`
  - `App:track() -> true|nil, string|nil`
  - exact request fencing and post-switch Canvas rebuilding.

- [ ] **Step 1: Write failing checkout-picker tests**

In `test/integration/test_root.lua`, use real branch metadata and a controlled
`vim.ui.select` to prove:

- the prompt is `CanvasDiff switch local branch:`;
- only local branches appear;
- the current item formats as `[checked out]`;
- cancellation is silent and does not mutate `HEAD`;
- selecting current is a successful no-op;
- selecting another local branch changes `HEAD`;
- no active canvas remains closed after switching.

Assert observable Git state and windows, not fake call counts alone.

- [ ] **Step 2: Write failing tracking-picker tests**

Prove:

- prompt `CanvasDiff create tracking branch:`;
- remote defaults and local branches are absent;
- item label is `[remote-tracking ref]`;
- selecting `origin/feature/api` creates and checks out `feature/api`;
- a derived-name collision warns to use `:CanvasDiff checkout`;
- cancellation and empty-ref cases do not mutate Git.

- [ ] **Step 3: Write failing safety and lifecycle tests**

Add tests covering:

1. A modified loaded repository buffer blocks checkout and track before Git,
   naming the path.
2. A visible Canvas switches, discards the old source state, reopens at
   `HEAD → WORKTREE`, and retains a semantic path/hunk when it exists.
3. A hidden Canvas remains hidden but its obsolete Surface is disposed.
4. A successful Git switch followed by injected collection failure reports
   `branch changed, but Canvas refresh failed:` and remains on the new branch.
5. A picker callback after its origin window closes, Surface is replaced,
   a newer picker starts, or cwd changes cannot mutate Git.
6. Concurrent reviews in different repositories cannot switch one another.

Use real Git for mutation. Inject only picker timing and the narrow source
collection failure needed to reach the post-mutation error branch.

- [ ] **Step 4: Run focused application tests and verify RED**

Run:

```bash
make test SUITE=integration FILTER='^root_'
make test SUITE=integration FILTER='^concurrent_'
make test SUITE=e2e FILTER='^e2e: branch'
```

Expected: missing `App:checkout`/`App:track` behavior.

- [ ] **Step 5: Implement one shared branch-mutation request**

Add an App-owned helper with a monotonic token distinct from comparison
requests:

```lua
local request = begin_ref_request(self, "checkout" or "track")
```

It captures exact origin window, buffer, Surface identity/generation, root,
and visibility. The guard must revalidate all identities after every picker
callback and immediately before Git.

The shared mutation path:

```lua
local modified = source.modified_buffer_in_root(request.root)
if modified then
  return nil, "cannot switch branches: modified buffer " .. modified
end
local changed, err = mutate_exact_ref(...)
if not changed then return nil, err end
return rebuild_after_ref_change(request)
```

Do not share compare's token: starting a checkout invalidates older checkout
or track requests and comparison requests, but ordinary comparison reentry
must not revive a mutation request.

- [ ] **Step 6: Implement post-switch Surface replacement**

On success:

- invalidate the old Surface before any recollection;
- capture semantic session/view data through existing Surface/session APIs;
- dispose old controllers and the old paged store exactly once;
- collect with `lens.get("all")`;
- if previously visible, publish a fresh Canvas in the same valid host window
  and restore semantic position;
- if hidden, leave it hidden and retain no live obsolete Surface;
- if absent, return after Git success without opening;
- report rebuild failure without reverse switching.

Any new Surface helper must express an ownership operation used in production;
do not add test-only lifecycle methods.

- [ ] **Step 7: Run focused GREEN verification**

Run:

```bash
make test SUITE=integration FILTER='^root_'
make test SUITE=integration FILTER='^concurrent_'
make test SUITE=e2e FILTER='^e2e: branch'
make test SUITE=fault
```

Expected: all selected suites pass with no leaked windows, buffers, timers,
autocommands, or fixture repositories.

- [ ] **Step 8: Commit Task 3**

```bash
git add lua/canvasdiff/App.lua lua/canvasdiff/Surface.lua \
  test/integration/test_root.lua \
  test/integration/test_concurrent_reviews.lua test/e2e/test_e2e.lua
git commit -m "feat: add safe branch checkout workflow"
```

---

### Task 4: User documentation and authoritative verification

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/verification/README.md`
- Test: existing repository suites and campaigns

**Interfaces:**
- Consumes: completed public commands and exact labels from Tasks 1–3.
- Produces: user-facing command, safety, and terminology documentation plus
  authoritative verification evidence.

- [ ] **Step 1: Update command and lens documentation**

Document:

```vim
:CanvasDiff compare
:CanvasDiff checkout
:CanvasDiff track
```

Replace `vs` examples with directional labels. State explicitly:

- `origin/main` is a local remote-tracking ref from the last fetch;
- compare never fetches or checks out;
- checkout lists local branches only;
- track creates a local tracking branch without fetching;
- unsaved repository buffers block both mutations;
- Git may refuse saved changes that would be overwritten;
- neither command exposes force, stash, detach, or deletion.

- [ ] **Step 2: Update architecture and verification guidance**

Record the boundary:

```text
ref metadata → role-based picker → exact full-ref Git operation
              → invalidated Surface → HEAD → WORKTREE recollection
```

Add the checkout/track journey to the supported lifecycle checklist without
changing performance thresholds.

- [ ] **Step 3: Run static and focused verification**

Run:

```bash
git diff --check
make test SUITE=unit FILTER='^ref_'
make test SUITE=unit FILTER='^cmd_'
make test SUITE=integration FILTER='^git:'
make test SUITE=integration FILTER='^source:'
make test SUITE=integration FILTER='^lens_'
make test SUITE=integration FILTER='^session_'
make test SUITE=integration FILTER='^root_'
make test SUITE=integration FILTER='^concurrent_'
make test SUITE=e2e FILTER='^e2e: branch'
```

Expected: all commands exit 0.

- [ ] **Step 4: Run authoritative repository verification**

Run exactly one fresh full suite:

```bash
make test
```

Then run the relevant existing campaigns without expanding their threat model:

```bash
make test SUITE=performance
make bench-chaos OUT=/tmp/canvasdiff-ref-checkout-chaos ACTIONS=10000
```

Expected: full suite, performance suite, and 30,600-action chaos campaign pass.
Do not rerun the million-row live-scale campaign because this change does not
alter the paged store, projection, compression, or benchmark schema.

- [ ] **Step 5: Commit Task 4**

```bash
git add README.md docs/architecture.md docs/verification/README.md
git commit -m "docs: explain comparison and checkout roles"
```

Record all verification commands and exact results in the SDD ledger and
adversarial receipt.
