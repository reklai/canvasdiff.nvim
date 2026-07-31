# Stage Verbs, q Back-Out, Sidebar Toggle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `s`/`u` become plain stage/unstage verbs on canvas and sidebar; `q` on the canvas backs out of a stacked comparison before closing; the sidebar becomes toggleable via `o`, `:CanvasDiff sidebar`, and `.sidebar()`.

**Architecture:** The stage split threads an explicit direction through `App:toggle_stage`'s existing machinery (guards, XY reads, lens retargeting all unchanged) and renames the key actions and public API. The q back-out is a branch in the canvas `close` key action only — command and API close stay pure. The sidebar toggle reuses the sidebar's existing open/close lease paths behind one new App method exposed as key, subcommand, and API.

**Tech Stack:** Neovim Lua plugin; `make test`; fixtures via `H.git_fixture` + `vim.system`.

**Spec:** `docs/superpowers/specs/2026-08-01-stage-verbs-q-backout-sidebar-toggle-design.md`

## Global Constraints

- Pre-alpha clean removals, no aliases: keymap action `stage_cycle`, config keys `keymaps.canvas.stage_cycle` / `keymaps.sidebar.stage_cycle`, public API `toggle_stage()` all disappear; overrides naming them get the existing unknown-name report.
- Notify copy exactly: `already staged` (s with nothing unstaged), `nothing staged` (u with index == HEAD), info level, no change performed.
- `q` back-out fires ONLY via the canvas `close` KEY action; `:CanvasDiff close` and `App:close()` always close.
- READ-ONLY refusal vocabulary unchanged for ranges.
- Every commit leaves `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` green (full suite).
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `s` = stage, `u` = unstage

**Files:**
- Modify: `lua/canvasdiff/App.lua` — `App:toggle_stage` (:2273-2400 region; the direction decision is at ~:2341 `local action = file.unstaged and "stage" or "unstage"`), the canvas action table entry `stage_cycle` (:967-968), the sidebar callback `on_stage_cycle` (:1453-1460)
- Modify: `lua/canvasdiff.lua:37-39` (`toggle_stage` export → `stage`/`unstage`)
- Modify: `lua/canvasdiff/input/keys.lua:41,45` (action specs)
- Modify: `lua/canvasdiff/config/settings.lua:114,143` (defaults) and the valid-action list (:218 region)
- Modify: `lua/canvasdiff/ui/sidebar.lua` (its keymap wiring for the renamed actions — grep `stage_cycle` in the file)
- Modify: `test/fault/chaos_surface.lua:464-476` (`stage_cycle` action → `stage` + `unstage` actions driving the new API)
- Test: `test/integration/test_root.lua` (existing stage tests — grep `toggle_stage\|stage_cycle` across test/ and update), plus new no-op notify tests
- Modify: `README.md`, `doc/canvasdiff.txt` (keymap tables, stage bullet, `s` cycle wording)

**Interfaces:**
- Consumes: existing `App:toggle_stage` internals.
- Produces: `App:stage(path?, surface?, generation?)` and `App:unstage(...)` (thin over one internal `stage_file(direction, ...)`); public `require("canvasdiff").stage()` / `.unstage()`; key actions `stage` / `unstage` in both contexts. Task 3's chaos edits and later docs rely on these exact names.

- [ ] **Step 1: Update existing tests, add the new ones (failing)**

`grep -rn "toggle_stage\|stage_cycle" test/` — update every hit to the new names/semantics. The existing cycle test (a mixed file: stage → unstage on repeated press) becomes two tests: `s` then `s` again → second press notifies `already staged` and the XY state is unchanged; `u` on that staged file → unstaged. Add:

```lua
T["stage_ s on a fully staged file notifies and changes nothing"] = function()
  -- fixture: file staged, worktree clean vs index
  -- press s (or call app:stage(path)); capture vim.notify
  -- assert: one info notification "already staged"; git XY unchanged
end

T["stage_ u on an unstaged-only file notifies and changes nothing"] = function()
  -- fixture: file modified, nothing staged
  -- press u; assert one info notification "nothing staged"; XY unchanged
end
```

Write real bodies following the file's existing stage-test pattern (fixtures with `vim.system` git calls; XY read via `git status --porcelain`). Run the touched suites; confirm the updated/new expectations FAIL.

- [ ] **Step 2: Implement the split**

In `App.lua`: rename the guts to take a direction. Minimal shape — keep the existing function and add the parameter:

```lua
--- direction: "stage" | "unstage". The old auto-cycle decided this from the
--- file's XY state; two explicit verbs mean a keypress never surprises by
--- picking the other direction on a mixed file.
function App:stage_file(direction, path, owned_surface, generation)
  -- body of today's toggle_stage, with the ~:2341 decision replaced by:
  if direction == "stage" and not file.unstaged then
    ui.notify("already staged")
    return false
  end
  if direction == "unstage" and not file.staged then
    ui.notify("nothing staged")
    return false
  end
  local action = direction
  -- everything else (guards, retargeting) unchanged
end

function App:stage(path, owned_surface, generation)
  return self:stage_file("stage", path, owned_surface, generation)
end

function App:unstage(path, owned_surface, generation)
  return self:stage_file("unstage", path, owned_surface, generation)
end
```

Keep the existing `if not file.staged and not file.unstaged then` clean-file refusal (:2335) before the direction checks. Canvas action table: replace the `stage_cycle` entry with `stage` and `unstage` entries calling `app:stage(nil, surface, generation)` / `app:unstage(...)`. Sidebar callback: `on_stage_cycle` becomes `on_stage`/`on_unstage` (or one `on_stage(direction, ...)` — match how sidebar.lua consumes it; read that wiring first). `lua/canvasdiff.lua`: export `stage`/`unstage`, delete `toggle_stage`. keys.lua/settings.lua per the spec's exact names, descs, and defaults. Chaos: `ACTIONS.stage_cycle` becomes `ACTIONS.stage` + `ACTIONS.unstage` (each pcall-refusal style, `world.plugin.stage()` / `.unstage()`).

- [ ] **Step 3: Full suite**

Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` — expected PASS. `grep -rn "stage_cycle\|toggle_stage" lua/ test/` — zero hits.

- [ ] **Step 4: Docs**

README: canvas + sidebar keymap table rows (`s` Stage this file's changes / `u` Unstage this file); the "Press s ... predictable stage → unstage cycle" usage bullet rewritten for two verbs; "Stage cycling is file-level..." paragraph reworded (drop "cycle"). vimdoc: matching rows/sentences (grep `stage` in doc/canvasdiff.txt).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: split staging into explicit s/u verbs"
```

---

### Task 2: `q` backs out of a stacked comparison

**Files:**
- Modify: `lua/canvasdiff/App.lua` — canvas action table `close` entry (:964) plus a small `App:back_out()` or local helper; `input/keys.lua:42` desc
- Test: `test/integration/test_lens.lua` (new tests beside the Task-2-hardening return-lens tests)
- Modify: `README.md`, `doc/canvasdiff.txt`

**Interfaces:**
- Consumes: `lens.of`, `lens.is_range`, `lens.valid`, `state.return_lens` (recorded by `pivot`), `App:set_lens` (returns `true` / bare nil for STALE / `nil, err` for real errors — same contract `cycle_lens` uses), `App:close`.
- Produces: the canvas `close` key action now runs back-out-or-close. No new public API.

- [ ] **Step 1: Failing tests**

Beside the existing `lens_` return-lens tests (same driving helpers):

```lua
T["lens_ q pops a stacked comparison back to the recorded lens"] = function()
  -- open, set_lens("staged"), set_range main..topic
  -- feed the canvas close key (or invoke the close ACTION the way the
  --   keymap does; do NOT call app:close() directly — that must still close)
  -- assert: canvas still showing, winbar HEAD → INDEX (staged)
  -- feed q again → canvas closed, original buffer restored
end

T["lens_ q closes immediately when the comparison was opened directly"] = function()
  -- open({ lens = range main..topic }) with no prior canvas
  -- q → canvas closed (no intermediate pivot)
end

T["lens_ CanvasDiff close always closes, even stacked"] = function()
  -- open, set_lens("staged"), set_range main..topic
  -- :CanvasDiff close (or app:close())
  -- assert canvas closed in one step
end
```

Real bodies; to "feed q", reuse however the suite invokes canvas key actions elsewhere (grep `close` usage in tests, or `nvim_feedkeys` on the canvas window like the e2e tests do — pick the file's convention). Verify tests 1 fails (q closes today), 2 and 3 pass as pins — mark them as pins in comments.

- [ ] **Step 2: Implement**

In the canvas action table (App.lua:964):

```lua
    close      = owned_action(surface, generation, function()
      app:back_out_or_close(surface)
    end),
```

and the method beside `cycle_lens`:

```lua
--- The canvas q: back out of the thing you are in. A comparison stacked on a
--- working view this session pops back to that view (same landing as <Tab>,
--- same clear-on-real-error rule); anything else closes the review. Only the
--- KEY behaves this way -- :CanvasDiff close and App:close stay pure close,
--- so scripts that say close get close.
function App:back_out_or_close(surface)
  surface = surface or active_surface(self)
  local st = surface and surface.state
  if st and lens.is_range(lens.of(st)) then
    local back = st.return_lens
    if back and lens.valid(back) then
      local ok, err = self:set_lens(back)
      if ok then
        return ok
      end
      if err ~= nil then
        st.return_lens = nil
      end
      return
    end
  end
  return self:close()
end
```

keys.lua canvas `close` desc → `Back out: leave a stacked comparison, else close the canvas`. (Sidebar `close` desc unchanged.)

- [ ] **Step 3: Full suite**

Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` — expected PASS. If any existing test feeds `q` on a canvas in a range lens and expects a close, it will fail — inspect each: if it stacked the range from a prior lens, the new behavior is the spec; update the expectation and say so in the report.

- [ ] **Step 4: Docs**

README: the "two exits mean different things" bullet and the `q` keymap row get the back-out rule; the ranges section's `q closes the review` sentence becomes the two-step story. vimdoc: the matching ranges sentence (`q` closes the review …) updated the same way.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: q backs out of a stacked comparison before closing"
```

---

### Task 3: Sidebar toggle (`o`, `:CanvasDiff sidebar`, `.sidebar()`)

**Files:**
- Modify: `lua/canvasdiff/App.lua` (new `App:toggle_sidebar()`, canvas action table entry)
- Modify: `lua/canvasdiff.lua` (export `sidebar`)
- Modify: `lua/canvasdiff/input/command.lua` (subcommand + completion; read the grammar's action list and `C.complete` first)
- Modify: `lua/canvasdiff/input/keys.lua` (canvas action `sidebar`, desc `Toggle the sidebar`), `lua/canvasdiff/config/settings.lua` (default `sidebar = "o"` under `keymaps.canvas`, valid-action list)
- Read first: `lua/canvasdiff/ui/sidebar.lua` — `S.is_open(lease, tab)` (:1335) and however App currently opens/closes the sidebar (grep `sidebar.` in App.lua and Surface.lua for the open call and the lease owner)
- Test: `test/integration/test_sidebar.lua`
- Modify: `README.md`, `doc/canvasdiff.txt`
- Modify: `test/fault/chaos_surface.lua` (new `sidebar_toggle` action)

**Interfaces:**
- Consumes: the sidebar's existing open/close/lease functions — REUSE them; if the existing open path is inseparable from canvas open, stop and report NEEDS_CONTEXT rather than inventing a second lifecycle.
- Produces: `App:toggle_sidebar()`; `require("canvasdiff").sidebar()`; `:CanvasDiff sidebar`; canvas key `o`.

- [ ] **Step 1: Failing tests**

In `test/integration/test_sidebar.lua` (its fixtures already open canvas+sidebar):

```lua
T["sidebar_ o closes and reopens the sidebar without touching the canvas"] = function()
  -- open canvas (sidebar auto-opens); assert sidebar window exists
  -- toggle via the API (fm.sidebar()); assert sidebar window gone, canvas untouched
  -- toggle again; assert sidebar back, tracking the same canvas (active row present)
end

T["sidebar_ the command toggles and warns without a canvas"] = function()
  -- no canvas: :CanvasDiff sidebar → one warn "no live diff canvas", nothing opens
  -- with canvas: :CanvasDiff sidebar twice → closed then reopened
end

T["sidebar_ toggle works when sidebar.enabled = false"] = function()
  -- setup({ sidebar = { enabled = false } }); open canvas; assert no sidebar
  -- fm.sidebar() → sidebar opens
end
```

Real bodies per the file's conventions (it has `sidebar_winbar(lease)` helpers etc.). Verify all three FAIL (`fm.sidebar` is nil / command unknown).

- [ ] **Step 2: Implement**

`App:toggle_sidebar()`: find the showing surface (reuse the same `active_surface` + `is_showing` guard `cycle_lens` uses, warning `no live diff canvas` otherwise); if `sidebar.is_open(...)` for the surface's tab → run the existing close path; else run the existing open path (the one canvas open uses when `sidebar.enabled`), bypassing the `enabled` config check deliberately. Wire: canvas action `sidebar` → `app:toggle_sidebar()`; facade export; command grammar (`sidebar` joins the exact-match subcommands so a branch literally named "sidebar" is shadowed — consistent with how `close`/`refresh` already shadow, note it in the docs the way the grammar's comment at command.lua:15 describes); completion list.

- [ ] **Step 3: Chaos action**

```lua
ACTIONS.sidebar_toggle = function(world)
  local ok = pcall(function() world.plugin.sidebar() end)
  record(world, "sidebar_toggle")
  assert(ok, "sidebar_toggle threw instead of refusing")
end
```

Run: `make test SUITE=fault FILTER='chaos_surface'` — green.

- [ ] **Step 4: Full suite**

Run: `NVIM_LOG_FILE=/tmp/canvasdiff.log make test` — expected PASS.

- [ ] **Step 5: Docs**

README: keymap table `o` row; sidebar section sentence "**q** closes just the sidebar (the canvas stays open)" gains "— **o** on the canvas, or `:CanvasDiff sidebar`, brings it back"; Commands block gains `:CanvasDiff sidebar   " toggle the file-tree sidebar`. vimdoc: command entry + the sidebar paragraph sentence.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: make the sidebar toggleable (o, :CanvasDiff sidebar, .sidebar())"
```

---

## Final verification

- [ ] Full suite green at head; `grep -rn "stage_cycle\|toggle_stage" lua/ test/ README.md doc/` — zero hits.
- [ ] Manual smoke: mixed file — `s` stages, second `s` notifies `already staged`, `u` unstages, second `u` notifies `nothing staged`; `staged` lens → compare → `q` lands on staged → `q` closes; `o` closes/reopens the sidebar; `:CanvasDiff sidebar` completes with Tab.
