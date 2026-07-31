# Lens Lifecycle Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A session-restored comparison whose ref was deleted falls back to the default lens instead of aborting the open; `<Tab>` from a range returns to the pre-comparison lens; a git-lifecycle chaos campaign tries to break CanvasDiff and its findings are triaged.

**Architecture:** The fallback is a retry tier inside `App.open`'s collection failure path, gated on the lens having come from the session. The return lens is one field on canvas state, recorded at `pivot`'s single commit point and consumed by `App:cycle_lens`. The chaos work extends the existing seeded, replayable `test/fault/chaos_surface.lua` harness with git-lifecycle actions and new invariants.

**Tech Stack:** Neovim Lua plugin; `make test` suites; `H.git_fixture` + `vim.system` for real-git fixtures; the fault harness's LCG generator.

**Spec:** `docs/superpowers/specs/2026-08-01-lens-lifecycle-hardening-design.md`

## Global Constraints

- User-visible copy about a range lens says READ-ONLY (exact spelling).
- `return_lens` is in-memory only — never serialized by `session/codec.lua`.
- An explicitly passed lens (`opts.lens` / `opts.base`) that fails collection still errors; only a session-derived lens falls back.
- Chaos actions must use the harness's own generator (`world.rng`), never `math.random`, and every action ends with the shared invariant check (the harness does this; don't bypass `record`).
- Every commit leaves `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` green (full suite).
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Session-lens fallback

**Files:**
- Modify: `lua/canvasdiff/App.lua:1078-1141` (lens selection + collection failure path; line numbers may drift a few lines — anchors: the precedence chain comment "Load any saved session BEFORE collection" and the failure branch `if not sections then`)
- Test: `test/integration/test_session.lua` (new test; reuse its local `in_repo` helper at :121 and `H.git_fixture`)
- Modify: `doc/canvasdiff.txt` (one sentence in the session section)

**Interfaces:**
- Consumes: `lens.from_base`, `lens.same`, `lens.valid`, `source.sections`, `ui.warn` — all already imported in App.
- Produces: no new public API. Behavior: open with a dead session lens yields a canvas showing the default lens plus one warn notification.

- [ ] **Step 1: Write the failing integration test**

Add to `test/integration/test_session.lua` (below the other `in_repo`-based tests, following their style):

```lua
T["session_ a saved comparison whose ref is gone falls back to the default lens"] =
function()
  local root = H.git_fixture({ committed = { ["a.txt"] = "one\n" } })
  local function sh(c) assert(vim.system(c, { cwd = root }):wait().code == 0) end
  sh({ "git", "branch", "topic" })

  -- Save a session that points at a range over `topic`, as a real close would.
  local saved = {
    root = root,
    lens = model.lens.range("main", "topic", ".."),
  }
  session.activate(saved)
  assert(session.save(saved))
  assert(session.load(root), "sanity: the range lens reached disk")

  sh({ "git", "branch", "-D", "topic" })

  local warnings = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level) warnings[#warnings + 1] = { msg = msg, level = level } end
  local ok, err = pcall(function()
    in_repo(root, {}, function(fm)
      assert(fm.open(), "open must succeed via the fallback lens")
      local st = fm._surface_state and fm._surface_state() or nil
      -- Read the live lens through the same door every test uses: the winbar.
      local win = vim.api.nvim_get_current_win()
      local wb = vim.api.nvim_get_option_value("winbar", { win = win })
      assert(wb:find("HEAD → WORKTREE", 1, true),
        "fallback landed on the default lens, got: " .. wb)
      assert(not wb:find("READ%-ONLY"),
        "the dead range must not be shown")
    end)
  end)
  vim.notify = orig_notify
  assert(ok, err)

  local saw_fallback = false
  for _, w in ipairs(warnings) do
    if w.msg:find("no longer resolves", 1, true) then saw_fallback = true end
  end
  assert(saw_fallback, "the fallback explains itself with a warning")
  vim.fn.delete(root, "rf")
end
```

Notes for the implementer: `model` and `session` are already required at the top of this test file (`model.lens.branch(...)` is used at :~140); if `H.git_fixture` initializes a default branch other than `main`, read the fixture helper and use the branch name it creates (`git symbolic-ref --short HEAD` in the fixture is acceptable inside the test). If `fm.open()` returns nothing on success, assert via the winbar alone. Adapt mechanically; the assertions (open succeeds, winbar shows default lens, warning mentions "no longer resolves") are the requirements.

- [ ] **Step 2: Run to verify it fails**

Run: `make test SUITE=integration FILTER='falls back'`
Expected: FAIL — today open aborts, `fm.open()` returns nil.

- [ ] **Step 3: Implement the fallback**

In `lua/canvasdiff/App.lua`, at the lens precedence chain, record the provenance:

```lua
  local l = opts.lens
    or (opts.base and lens.from_base(opts.base))
    or (sess and lens.valid(sess.lens) and sess.lens)
    or (sess and sess.base and lens.from_base(sess.base))
    or lens.from_base(config.options.base)
  -- The session's lens passed a SHAPE check only; whether its refs still
  -- resolve is decided by collection below. Remember where it came from, so
  -- a saved comparison over a deleted branch degrades to the default lens
  -- instead of failing the open -- same posture as the paged fallback: a
  -- saved lens that cannot be collected is a reason to fall back, not to
  -- fail the review. An EXPLICIT lens still errors; that is typo feedback.
  local lens_from_session = opts.lens == nil and opts.base == nil
    and sess ~= nil and lens.valid(sess.lens) or false
```

At the collection failure branch, insert the retry tier between the `_guard` check and the abort:

```lua
  local sections, collect_err = source.sections(root, l, config.options.context)
  if opts._guard and not opts._guard() then
    return nil, STALE_COMPARE
  end
  if not sections and lens_from_session then
    local fallback = lens.from_base(config.options.base)
    if not lens.same(fallback, l) then
      ui.warn(("saved comparison %s no longer resolves — showing %s (%s)")
        :format(l.label, fallback.label, collect_err))
      l = fallback
      sections, collect_err = source.sections(root, l, config.options.context)
      if opts._guard and not opts._guard() then
        return nil, STALE_COMPARE
      end
    end
  end
  if not sections then
    ui.warn(collect_err)
    return nil, collect_err
  end
```

- [ ] **Step 4: Run the test, then the full suite**

Run: `make test SUITE=integration FILTER='falls back'` — expected PASS.
Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` — expected PASS.

- [ ] **Step 5: vimdoc sentence**

In `doc/canvasdiff.txt`'s session section (search for the paragraph about the saved JSON under `stdpath("state")`), append one sentence in the file's voice: "A saved comparison whose branch no longer exists falls back to the default lens on open, with a message saying so."

- [ ] **Step 6: Commit**

```bash
git add lua/canvasdiff/App.lua test/integration/test_session.lua doc/canvasdiff.txt
git commit -m "fix: fall back to the default lens when a saved comparison no longer resolves"
```

---

### Task 2: `<Tab>` returns to the pre-comparison lens

**Files:**
- Modify: `lua/canvasdiff/App.lua` — `pivot` (defined near :1905) and `App:cycle_lens` (near :2459)
- Test: `test/integration/test_lens.lua` (new tests)
- Modify: `README.md` (the `<Tab>` range-exit line, ~:337, plus one `:q` sentence)
- Modify: `doc/canvasdiff.txt` (the matching `<Tab>` sentence, ~:129)

**Interfaces:**
- Consumes: `lens.is_range`, `lens.valid`, `lens.step`, `lens.of` (diff facade), the `pivot` function's existing success path.
- Produces: `state.return_lens` — a normalized non-range lens or nil; never serialized (codec ignores unknown state fields — verify with the grep in Step 3).

- [ ] **Step 1: Write the failing tests**

Add to `test/integration/test_lens.lua` (this file already opens canvases via the plugin — follow the pattern of its existing range test near :150; the exact driving helpers may differ from the sketch, adapt mechanically, the assertions are the requirements):

```lua
T["lens_ tab from a range returns to the pre-comparison lens"] = function()
  -- Fixture: a repo where `staged` is a meaningful lens, plus a topic branch.
  -- 1. open, set_lens("staged")
  -- 2. set_range main..topic     (winbar shows READ-ONLY)
  -- 3. cycle_lens(1)             (Tab)
  -- assert: winbar shows "HEAD → INDEX (staged)", not "HEAD → WORKTREE"
end

T["lens_ a canvas opened straight into a range exits to the default"] = function()
  -- 1. open with lens = range main..topic (no prior lens on this state)
  -- 2. cycle_lens(1)
  -- assert: winbar shows "HEAD → WORKTREE"
end

T["lens_ range to range keeps the original return lens"] = function()
  -- 1. open, set_lens("unstaged"); set_range main..topic; set_range main...topic
  -- 2. cycle_lens(-1)             (Shift-Tab)
  -- assert: winbar shows "INDEX → WORKTREE (unstaged)"
end
```

Write the three bodies for real using the file's existing canvas-driving helpers (whatever its range test at :150 uses to open and read the winbar). Each must currently FAIL on the first assertion (today every exit lands on `HEAD → WORKTREE`) — except test 2, which passes today and pins the unchanged default; note that in its comment.

- [ ] **Step 2: Run to verify the two new behaviors fail**

Run: `make test SUITE=integration FILTER='^lens_ '`
Expected: tests 1 and 3 FAIL (exit lands on `HEAD → WORKTREE`); test 2 PASSES (pin).

- [ ] **Step 3: Implement**

In `pivot` (App.lua ~:1905), after the pivot has succeeded and the state's lens is updated (find the point where `surface.state` reflects the new lens — read the function top to bottom first), record:

```lua
  -- Where <Tab> goes when it leaves a comparison. Recorded at the single
  -- commit point every lens change funnels through, so no caller can forget
  -- it: entering a range remembers the lens you were looking through, leaving
  -- one forgets it. Range→range keeps the ORIGINAL — the comparison you came
  -- from is where "back" goes, however many ranges you visited meanwhile.
  -- In-memory only: a restored session exits to the default, as before.
  if lens.is_range(target_lens) then
    if not lens.is_range(prior_lens) then
      surface.state.return_lens = prior_lens
    end
  else
    surface.state.return_lens = nil
  end
```

where `prior_lens` is `lens.of(surface.state)` captured at the TOP of `pivot`, before anything mutates the state. Use the actual parameter name for the target lens (the signature is `pivot(surface, target_lens, guard, collected, publish)`).

In `App:cycle_lens`:

```lua
function App:cycle_lens(delta)
  local surface = active_surface(self)
  if not (surface and surface:is_showing()) then
    ui.warn("no live diff canvas")
    return
  end
  local current = lens.of(surface.state)
  -- Leaving a comparison goes back to the lens you entered it from; the
  -- cycle only ever steps between the three named lenses. A return lens
  -- that no longer pivots (its branch was deleted meanwhile) is cleared, so
  -- the next press takes the default exit instead of failing forever.
  if lens.is_range(current) then
    local back = surface.state.return_lens
    if back and lens.valid(back) then
      local ok = self:set_lens(back)
      if ok then
        return ok
      end
      surface.state.return_lens = nil
      return
    end
  end
  return self:set_lens(lens.step(current, delta or 1))
end
```

Confirm the codec cannot leak the field: `grep -n "return_lens" lua/canvasdiff/session/` must be empty, and read `session/codec.lua`'s capture function to confirm it whitelists fields (it builds `data` explicitly) rather than serializing the whole state. If it serializes wholesale, add the field to its exclusion — and say so in the report.

- [ ] **Step 4: Run the tests, then the full suite**

Run: `make test SUITE=integration FILTER='^lens_ '` — expected PASS (all three).
Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` — expected PASS.

- [ ] **Step 5: Docs**

- `README.md` ~:337: "`<Tab>` or `<Shift-Tab>` leaves a read-only range at `HEAD → WORKTREE`." becomes "`<Tab>` or `<Shift-Tab>` leaves a read-only range and returns to the comparison you were looking through when you entered it — `HEAD → WORKTREE` when the canvas opened straight into the range."
- Same paragraph, append: "`:q` is deliberately left alone — it stays Vim's window-close; `q` is the review's close."
- `doc/canvasdiff.txt` ~:129: "Press <Tab> or <S-Tab> to leave a range at HEAD vs WORKTREE." updated to match the README's new sentence, in vimdoc voice, ≤78 columns.

- [ ] **Step 6: Commit**

```bash
git add lua/canvasdiff/App.lua test/integration/test_lens.lua README.md doc/canvasdiff.txt
git commit -m "feat: return to the pre-comparison lens when leaving a range"
```

---

### Task 3: Git-lifecycle chaos actions

**Files:**
- Modify: `test/fault/chaos_surface.lua` (new actions + invariants + fixture branch pool)
- Modify: `test/fault/test_chaos_surface.lua` (only if its campaign config enumerates actions explicitly — read it first; the harness auto-derives `ACTION_NAMES` from the `ACTIONS` table, so likely no change)

**Interfaces:**
- Consumes: the harness's `world` (with `world.rng`, `world.plugin`, `world.root`, `record`), `generator`, and its existing invariant runner. Task 1's fallback and Task 2's `return_lens` are the code under attack.
- Produces: actions named `git_branch`, `git_branch_delete`, `git_commit`, `set_range`, `set_branch`, `stage_cycle`, `session_reopen`; invariants `return_lens is never a range` and `a canvas is showing or the open refused cleanly` after `session_reopen`.

- [ ] **Step 1: Read the harness end to end**

Read `test/fault/chaos_surface.lua` completely (~400 lines) before writing anything: how `world` is built, how the fixture repo is created, how `record` and the invariant runner work, how `git_fails` injects failure, and how `test_chaos_surface.lua` configures the short campaign. The new actions must be indistinguishable in style from the existing ones.

- [ ] **Step 2: Add the branch pool and actions**

Fixture: give `world` a `branches` list seeded with 2 branch names created at setup (real `git branch` via `vim.system` in the fixture root), plus the default branch name read from the repo. Then (exact shapes to adapt to the harness's local conventions — `sh`/`record` naming per the file):

```lua
ACTIONS.git_branch = function(world)
  local name = "chaos-" .. world.rng.next(4)  -- bounded pool: chaos-0..chaos-3
  world.sh({ "git", "branch", "-f", name })
  world.branches[name] = true
  record(world, "git_branch", name)
end

ACTIONS.git_branch_delete = function(world)
  local names = vim.tbl_keys(world.branches)
  if #names == 0 then return record(world, "git_branch_delete", "noop") end
  local name = world.rng.pick(names)
  world.sh({ "git", "branch", "-D", name })
  world.branches[name] = nil
  record(world, "git_branch_delete", name)
end

ACTIONS.git_commit = function(world)
  -- touch a pooled file, add, commit; ranges need real history
end

ACTIONS.set_range = function(world)
  -- pick two names from: pool branches (SOME DELETED — deliberately keep
  -- deleted names as candidates), the default branch, "HEAD".
  -- world.plugin.set_range(("%s%s%s"):format(a, world.rng.chance(50) and ".." or "...", b))
end

ACTIONS.set_branch = function(world)
  -- world.plugin.set_branch(pick)   -- again including deleted candidates
end

ACTIONS.stage_cycle = function(world)
  -- drive the plugin's stage entry point (find it: grep "stage_cycle" lua/canvasdiff.lua App.lua)
end

ACTIONS.session_reopen = function(world)
  -- close, session.invalidate?? NO — a real restart KEEPS the session file.
  -- close (which saves), then reopen via world.plugin.open(); the point is
  -- that a session whose lens references a deleted branch must fall back.
end
```

Fill in every `--` body for real, matching the harness's existing action style. Where an action drives an entry point that may legitimately refuse (`set_range` over a deleted branch), the refusal is the expected outcome — the invariant check after the action is what matters; do not assert success inside the action.

- [ ] **Step 3: Add the invariants**

In the harness's after-every-action invariant function, add:

- `state.return_lens`, when present on the live state, satisfies `lens.valid` and is NOT a range (`not lens.is_range(...)`).
- After a failed pivot the canvas buffer is still showing in its window (the previous review survived) — implementable as: if the plugin reports a live surface, its window is valid and shows its buffer.
- After `session_reopen`: either a canvas is showing, or no canvasdiff augroups/buffers/windows leaked (reuse the harness's existing leak checks).

- [ ] **Step 4: Run the short campaign**

Run: `make test SUITE=fault FILTER='chaos_surface'`
Expected: PASS. If a new action trips an invariant, that is a FINDING — record seed + action trace (the harness prints them), do not weaken the invariant. A finding here moves to Task 4 triage; only fix it in this task if it is a defect in the new action code itself.

- [ ] **Step 5: Full suite + commit**

Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` — expected PASS.

```bash
git add test/fault/chaos_surface.lua test/fault/test_chaos_surface.lua
git commit -m "test: teach the surface chaos harness git branch lifecycle"
```

---

### Task 4: Long campaign + findings report

**Files:**
- Create: `docs/research/2026-08-01-lens-lifecycle-chaos-findings.md`
- Possibly modify: source files, one minimal regression test per confirmed bug (each bug = its own commit)

**Interfaces:**
- Consumes: Task 3's extended harness; the long-campaign entry point (read how `benchmark/chaos/run.lua` drives the engine harness long-form; if no surface-level long runner exists, drive `Chaos.run` from `test/fault/chaos_surface.lua` directly with a headless `nvim -l` script kept in the scratchpad, not committed).
- Produces: the findings report; regression tests + fixes for small confirmed bugs.

- [ ] **Step 1: Run ≥5 seeds × ≥2,000 actions**

For each seed in at least `{1, 2, 3, 5, 8}` run the surface campaign at ≥2,000 actions, capturing: seed, action count, failures (invariant name, action trace tail, error text). Redirect logs outside the repo (`NVIM_LOG_FILE=/tmp/...`), per the Makefile's convention.

- [ ] **Step 2: Triage every failure**

For each failure: replay the seed to confirm determinism, minimize (the harness records the action trace — find the shortest prefix that reproduces), classify:
- **Bug in CanvasDiff** → write the minimal regression test (failing), fix, full suite, one commit per bug: `fix: <what> (chaos seed <N>)`.
- **Bug in the harness/action code** → fix the harness, rerun that seed.
- **Real but too large to fix here** → findings report entry with the seed, trace, and a severity call. Do not start a redesign inside this task.

- [ ] **Step 3: Write the findings report**

`docs/research/2026-08-01-lens-lifecycle-chaos-findings.md`: campaign parameters (seeds, action counts, action mix), invariants checked, every failure with its classification and disposition (fixed-in `<sha>` / harness bug / open finding), and the exact command to rerun each seed. Written even if zero bugs: the report is what makes the campaign repeatable.

- [ ] **Step 4: Full suite + commit**

Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` — expected PASS.

```bash
git add docs/research/2026-08-01-lens-lifecycle-chaos-findings.md
git commit -m "docs: lens-lifecycle chaos campaign findings"
```

---

## Final verification

- [ ] Full suite green at head.
- [ ] Manual smoke: in a scratch repo, save a session in a range lens, delete the branch, reopen — canvas opens on `HEAD → WORKTREE` with the warning; `staged` → compare → `<Tab>` lands back on `staged`.
