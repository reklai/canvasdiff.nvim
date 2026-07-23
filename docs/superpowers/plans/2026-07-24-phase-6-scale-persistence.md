# Phase 6 — Scale + Persistence Implementation Plan (final phase)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The last roadmap phase: section collapse (user `<Tab>`/`za` + Tier-1 auto-virtualization for huge changesets), `]f [f ]h [h` motions, a statuscolumn showing new-file line numbers, a worktree-vs-HEAD / worktree-vs-index base toggle, and session persistence (semantic view + folds + collapse, never raw line numbers).

**Architecture:** Collapse is a canvas primitive (`set_collapsed`) using the same splice-plus-same-tick-view-correction discipline as `replace_section`: a collapsed section renders as one placeholder line; `state.collapsed[path]` is the single source of truth read by every renderer (canvas line/hl building, scrollbar kinds, hl skip). Tier-1 virtualization (`virt.lua`) is a pure policy on top of that primitive: when thresholds trip, sections outside viewport±margin are auto-collapsed (tracked separately from user intent, LRU-bounded expansion). Motions and the statuscolumn are read-only consumers of `canvas.locate`. The base toggle threads a `state.base` (`"HEAD"`|`"index"`) through git/collect/jump/watch. `session.lua` saves semantic anchors + user collapse + sidebar folds to `stdpath("state")` and restores through the existing resolution chain.

**Tech Stack:** Lua, Neovim ≥0.10, `vim.json`, `vim.fn.sha256`, bespoke headless runner.

## Global Constraints

- Neovim ≥0.10; no external deps; `make test` (FILTER by NAME); suite currently 105/105 and every task ends green.
- **Niri invariant is law:** every collapse/expand splice classifies against the live viewport and corrects the view in the same synchronous tick; content changes outside the viewport never move what the user reads.
- **Boundary-anchor landmine:** every splice recreates the following boundary anchor via `replace_boundary_extmark` (never trust a left-gravity mark at a splice's end row).
- Position identity is ALWAYS `{path, new_lnum, content}` resolved via `viewport.resolve` — persistence stores ONLY semantic anchors, never canvas line numbers.
- `state.collapsed` = `{ [path] = true }`, owned by canvas state (created in `canvas.open`, preserved by `render_all`); it is the ONLY collapse predicate renderers may read. virt.lua's auto-set is separate bookkeeping (module-level) so user intent is never auto-expanded and only user intent persists.
- Collapsed placeholder line: `"▸ " .. path .. ("  (%d hunks, +%d −%d)"):format(nhunks, adds, dels)` (U+2212), highlighted `FmFileHeader`, exactly 1 row.
- `canvas.locate` on a collapsed section returns `(i, 1)`; consumers must treat offset 1 of a collapsed section as the placeholder (jump `<CR>` expands instead of jumping).
- Keymap defaults (all configurable under `config.keymaps`): `collapse = "<Tab>"` (plus a fixed extra `za` mapping to the same fn), `next_file = "]f"`, `prev_file = "[f"`, `next_hunk = "]h"`, `prev_hunk = "[h"`. Motions clamp (no wrap), honor `vim.v.count1`, move only the cursor.
- Config additions: `statuscolumn = { enabled = true }`; `virt = { enabled = true, max_files = 200, max_lines = 100000, margin = 100, max_expanded = 20 }`; `base = "HEAD"`.
- The statuscolumn must never leak into a real file buffer: window-local `statuscolumn` is set when the canvas shows in a window and cleared when it leaves (the scrollbar's BufWinEnter/BufWinLeave scheduled pattern), and the eval function pcall-guards and returns "" for non-canvas buffers.
- Base semantics: `"HEAD"` = worktree vs HEAD (current behavior); `"index"` = worktree vs index (`git show :0:path`) — unstaged-only review. `state.base` threads through collect/jump/watch; `:FindingMyself base` toggles + refreshes + notifies.
- Session file: `stdpath("state") .. "/finding_myself/" .. vim.fn.sha256(root) .. ".json"`; contents `{version=1, base, collapsed=[paths...], folds=[dirpaths...], view={path,new_lnum,content,screen_offset}, cursor={path,new_lnum,content}}`; written on canvas close + `VimLeavePre`; restore skips silently on any resolution failure or version mismatch.
- Phase 4/5 singleton discipline for anything with autocmds: callbacks resolve live module state, liveness guards everywhere, close-safe-always, augroups cleared on rebind.
- Require graph stays acyclic: `virt` → {canvas}; `motions` → {canvas}; `statuscol` → {canvas}; `session` → {canvas, viewport, sidebar (fold accessors)}; init/watch/jump may require any of them; canvas requires none of them.
- Commit per green cycle; trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

- `lua/finding_myself/render.lua` — MODIFY: `placeholder(section)`.
- `lua/finding_myself/canvas.lua` — MODIFY: collapse-aware line/hl building, `set_collapsed`, `state.collapsed`.
- `lua/finding_myself/scrollbar.lua` — MODIFY: `line_kinds(sections, collapsed)`.
- `lua/finding_myself/hl.lua` — MODIFY: skip collapsed sections in `apply_now`.
- `lua/finding_myself/virt.lua` — NEW: Tier-1 auto-virtualization policy.
- `lua/finding_myself/motions.lua` — NEW: `]f [f ]h [h`.
- `lua/finding_myself/statuscol.lua` — NEW: statuscolumn text + attach/detach autocmds.
- `lua/finding_myself/git.lua` — MODIFY: `show(root, rev, path)` generalization.
- `lua/finding_myself/collect.lua` — MODIFY: `files(root, base)`.
- `lua/finding_myself/session.lua` — NEW: save/restore.
- `lua/finding_myself/sidebar.lua` — MODIFY: `get_folds()`/`set_folds(folds, state)` accessors.
- `lua/finding_myself/{config,init,jump,watch}.lua`, `plugin/finding_myself.lua`, `README.md` — MODIFY (wiring).
- Tests: `tests/test_collapse.lua`, `tests/test_virt.lua`, `tests/test_motions_statuscol.lua`, `tests/test_base.lua`, `tests/test_session.lua` — NEW.

---

### Task 1: Collapse primitive (Tier 2)

**Files:** Modify `render.lua`, `canvas.lua`, `scrollbar.lua`, `hl.lua`, `init.lua`, `config.lua`. Test: `tests/test_collapse.lua`.

**Interfaces:**
- Consumes: existing canvas internals (`section_rows`, `replace_boundary_extmark`, `win_showing_canvas`, `win_view_info`, `apply_section_hl`, hooks).
- Produces:
  - `render.placeholder(section) -> line` (format per Global Constraints).
  - `canvas.open` initializes `state.collapsed = {}`; `render_all`/`replace_section`/`insert_section` render a section as `{ render.placeholder(sec) }` with a single `FmFileHeader` hl mark when `state.collapsed[sec.path]`, else as before. (Introduce two small locals in canvas.lua — `section_lines_for(state, sec)` and a collapsed flag threaded into `apply_section_hl(buf, start_row, sec, collapsed)` — and use them at ALL THREE render sites.)
  - `canvas.set_collapsed(state, i, collapsed)` — no-op when unchanged or section missing; updates `state.collapsed`, splices section i in place (same-tick view correction: below→nothing; above→topline/lnum shift by delta; intersect: when `top0 < start_row` preserve the captured view (clamp lnum to the new line count), else `topline = start_row + 1`, `lnum = topline`); recreates boundary anchor; deletes old hl-mark ids and applies the collapse-aware ones; fires `state.hooks.on_section_replaced(path)` (hl/ts invalidation) after the splice; `"none"` branch when the canvas isn't showing.
  - `scrollbar.line_kinds(sections, collapsed)` — a collapsed section contributes exactly one `"hdr"`; `S.update` passes `state.collapsed`.
  - `hl.apply_now` — never applies TS/word marks to a collapsed section (skip like "not in window"; eviction of previously-applied marks happens via the `on_section_replaced` hook at collapse time).
  - init: `config.keymaps.collapse = "<Tab>"`; `set_canvas_keymaps` maps `<Tab>` AND `za` to toggle collapse of the section under the cursor (`canvas.locate` → `set_collapsed(st, i, not st.collapsed[path])`); the `<CR>` jump handler first checks `st.collapsed[path]` and expands instead of jumping.

- [ ] **Step 1: failing tests** — create `tests/test_collapse.lua` with (reuse the big-section fixture idiom from test_sidebar.lua: `bigtext(60)` + change every 10th line ⇒ ~55-row sections; three sections a/b/c):
  1. `collapse_ renders one placeholder row and restores on expand`: collapse section 2 → `section_rows(st,2)` spans exactly 1 row; buffer line at that row equals `render.placeholder(sec)`; rows stay contiguous (walk 1..3); expand → original row span and first/last body lines back.
  2. `collapse_ above viewport keeps visible text pinned`: viewport inside section 3; collapse section 1 → `getline(line("w0"))` unchanged; expand → still unchanged.
  3. `collapse_ locate maps the placeholder to offset 1`: collapse section 2; `canvas.locate(st, placeholder_row)` == (2, 1).
  4. `collapse_ scrollbar kinds shrink to one hdr`: `#scrollbar.line_kinds(st.sections, st.collapsed)` == (full total − (rows of sec2 − 1)); the placeholder position is `"hdr"`.
  5. `collapse_ hl never marks a collapsed section`: attach hl (margin large), collapse section 1, `hl.apply_now(st)` → no TS-namespace marks within section 1's rows; `ids_by_path` has no entry for it.
  6. `collapse_ replace_section keeps a collapsed section collapsed`: collapse section 2; `canvas.replace_section(st, 2, model.build_section(same path, old, different new, "M"))` → still 1 row, placeholder text reflects the NEW counts.
- [ ] **Step 2:** `make test FILTER=collapse_` → FAIL (`set_collapsed` nil).
- [ ] **Step 3:** implement per the Produces block. `set_collapsed` core (adapt to canvas.lua's existing locals):

```lua
function M.set_collapsed(state, i, collapsed)
  local sec = state.sections[i]
  if not sec then return end
  collapsed = collapsed and true or false
  if (state.collapsed[sec.path] or false) == collapsed then return end

  local start_row, end_row_exclusive = M.section_rows(state, i)
  local win_ok = win_showing_canvas(state)
  local branch, top0, view
  if win_ok then
    local info = win_view_info(state.win)
    top0 = info.top - 1
    view = info.view
    local bot0 = info.bot - 1
    if start_row > bot0 then branch = "below"
    elseif end_row_exclusive <= top0 then branch = "above"
    else branch = "intersect" end
  else
    branch = "none"
  end

  state.collapsed[sec.path] = collapsed or nil
  local new_lines = section_lines_for(state, sec)

  set_modifiable(state.buf, true)
  vim.api.nvim_buf_set_lines(state.buf, start_row, end_row_exclusive, false, new_lines)
  replace_boundary_extmark(state, i + 1, start_row + #new_lines)
  for _, id in ipairs(state.hl_ids[i] or {}) do
    pcall(vim.api.nvim_buf_del_extmark, state.buf, HL_NS, id)
  end
  state.hl_ids[i] = apply_section_hl(state.buf, start_row, sec, collapsed)
  set_modifiable(state.buf, false)

  if state.hooks and state.hooks.on_section_replaced then
    state.hooks.on_section_replaced(sec.path)
  end

  if branch == "above" then
    local delta = #new_lines - (end_row_exclusive - start_row)
    view.topline = math.max(1, view.topline + delta)
    view.lnum = math.max(1, view.lnum + delta)
    vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
  elseif branch == "intersect" then
    if top0 < start_row then
      view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(state.buf))
      vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
    else
      local topline = start_row + 1
      view.topline = topline
      view.lnum = topline
      vim.api.nvim_win_call(state.win, function() vim.fn.winrestview(view) end)
    end
  end
end
```

  Also: `render_all` must NOT reset `state.collapsed` (initialize only in `canvas.open` via `state.collapsed = state.collapsed or {}` before render). `replace_section`/`insert_section`/`render_all` switch to `section_lines_for` + collapse-aware `apply_section_hl` (collapsed ⇒ one `{row=0, group="FmFileHeader"}` mark). `replace_section`'s intersect anchor-capture must short-circuit like `preserve_view` when the section is collapsed (entries don't map to rows): treat collapsed-replace as `topline = start_row + 1` when `top0 >= start_row`, preserve otherwise.
- [ ] **Step 4:** `make test FILTER=collapse_` green, then full suite (existing scrollbar `line_kinds` tests: keep the old 1-arg call working — `collapsed = collapsed or {}`).
- [ ] **Step 5:** commit `feat: section collapse with placeholder splice (tier 2)`.

---

### Task 2: Tier-1 auto-virtualization (`virt.lua`)

**Files:** Create `lua/finding_myself/virt.lua`. Modify `init.lua`, `watch.lua`, `config.lua`. Test: `tests/test_virt.lua`.

**Interfaces:**
- Consumes: `canvas.set_collapsed`, `canvas.section_rows`, `state.collapsed`.
- Produces:
  - `virt.apply(state, opts)` — `opts = config.options.virt` (`{enabled, max_files, max_lines, margin, max_expanded}`). Inactive (disabled, or `#sections <= max_files` AND buffer lines `<= max_lines`): auto-expand everything in the module's auto-set and return. Active: sections intersecting `[top0 - margin, bot0 + margin]` that are in the auto-set get expanded (never touches user-collapsed ones — those aren't in the auto-set); sections fully outside get auto-collapsed (added to the auto-set) when the number of currently-expanded sections exceeds `max_expanded`, evicting least-recently-visible first (tick = last time the section intersected the window). No-op when the canvas isn't showing.
  - `virt.auto_set() -> { [path]=true }` — snapshot for session.lua (auto-collapsed paths are NOT persisted as user intent).
  - `virt.attach(state, opts)` — installs a debounced (50ms) WinScrolled trigger (augroup `finding_myself.virt`, singleton discipline: callback resolves module `live` state, timer stopped on re-attach) + runs one immediate `apply`. `virt.detach()` clears augroup/timer/auto-set.
  - init: attach after scrollbar when `config.options.virt.enabled`; detach in close; `virt.apply(state, config.options.virt)` at the end of `M.refresh`. watch: `virt.apply(state, config.options.virt)` after each of the three `scrollbar.update(state)` sites.
- [ ] **Step 1: failing tests** — `tests/test_virt.lua` (drive `virt.apply` directly with tiny thresholds; 6 sections of ~55 rows each):
  1. `virt_ inactive under thresholds leaves everything expanded` (max_files 100).
  2. `virt_ active collapses far sections beyond max_expanded and keeps near ones` (max_files 3, margin 10, max_expanded 2; viewport at top → sections 1-2 expanded (or all intersecting), far ones 1-row).
  3. `virt_ scroll then apply expands newly-near and collapses newly-far` (normal! G → apply → last sections expanded, first ones collapsed; `getline(line("w0"))` unchanged across the apply — zero motion).
  4. `virt_ never auto-expands a user-collapsed section` (user-collapse a section inside the viewport via `canvas.set_collapsed`, apply → still collapsed; auto_set() doesn't contain it).
  5. `virt_ deactivation auto-expands only the auto set` (apply active, then apply with huge thresholds → auto-collapsed back to full, user-collapsed still collapsed).
- [ ] **Step 2:** RED. **Step 3:** implement (module: `local live, auto, tick_of, timer` + augroup; `apply` computes expansion via `canvas.section_rows` per section — 1-row + in auto ⇒ auto-collapsed). **Step 4:** green + full suite. **Step 5:** commit `feat: tier-1 auto-virtualization`.

---

### Task 3: Motions + statuscolumn

**Files:** Create `lua/finding_myself/motions.lua`, `lua/finding_myself/statuscol.lua`. Modify `init.lua`, `config.lua`. Test: `tests/test_motions_statuscol.lua`.

**Interfaces:**
- `motions.goto_file(state, dir)` — cursor's section via `canvas.locate`, target `clamp(i + dir * vim.v.count1, 1, n)`, cursor to the target's start row+1 (col 0). `motions.goto_hunk(state, dir)` — collect absolute rows of `hunk_hdr` entries across NON-collapsed sections (section start_row + entry_index − 1), pick the count-th strictly after (dir=1) / before (dir=−1) the cursor row, clamp at the ends; no-op when none.
- `statuscol.text()` — for `%!v:lua.require'finding_myself.statuscol'.text()`: pcall-guarded; `""` unless the current buffer is the canvas and a state is attached; per `vim.v.lnum`: entry `new_lnum` ⇒ `"%4d "`, del ⇒ `"   · "`, headers/collapsed/missing ⇒ 5 spaces. `statuscol.attach(state)` — stores the state, sets window-local `statuscolumn` on `state.win`, installs BufWinEnter (set on entering window, update stored win) / BufWinLeave (scheduled clear from `state.win` when the canvas left it) autocmds in augroup `finding_myself.statuscol` (singleton discipline). `statuscol.detach()` — clears option (liveness-guarded), augroup, state.
- init: keymaps `next_file/prev_file/next_hunk/prev_hunk` (canvas-local, from config defaults `]f [f ]h [h`); `statuscol.attach(st)` when `config.options.statuscolumn.enabled`; `statuscol.detach()` in close. config: `statuscolumn = { enabled = true }` + the four keymap defaults.
- [ ] **Step 1: failing tests** (three ~55-row sections):
  1. `motions_ ]f [f move between section starts and clamp` (cursor mid section 2 → goto_file(+1) lands on section 3 start; three more +1 stay clamped at 3; goto_file(−1)×5 clamps at 1).
  2. `motions_ ]h steps hunk headers across sections and skips collapsed` (collapse section 2; from a hunk in section 1, repeated goto_hunk(+1) reaches section 3's first hunk without touching section 2's rows).
  3. `motions_ count is honored` (set `vim.cmd("normal! 2")`? — v:count can't be set directly; instead call with a wrapped `feedkeys('2]f', 'x')` through the real mapping after init-level setup OR make goto_file accept an explicit count parameter defaulting to `vim.v.count1` and test the parameter path; choose the parameter approach and document it).
  4. `statuscol_ text maps rows to new-file numbers` (attach state; set canvas buffer current; for a ctx row assert `text()` with `vim.v.lnum` — v:lnum is read-only outside statuscolumn evaluation, so factor the core as `statuscol.text_for(lnum)` (tested directly) with `text()` a thin `text_for(vim.v.lnum)` wrapper).
  5. `statuscol_ never leaks into a foreign buffer` (win shows another buffer → `text_for` returns ""; after `:edit`-style buffer swap the window's statuscolumn option is cleared within `vim.wait(300)`; re-showing the canvas restores it).
- [ ] **Step 2:** RED. **Step 3:** implement. **Step 4:** green + full suite. **Step 5:** commit `feat: file/hunk motions and new-file statuscolumn`.

---

### Task 4: Base toggle (worktree vs HEAD / index)

**Files:** Modify `git.lua`, `collect.lua`, `init.lua`, `jump.lua`, `watch.lua`, `config.lua`, `plugin/finding_myself.lua`. Test: `tests/test_base.lua`.

**Interfaces:**
- `git.show(root, rev, path)` — `rev ∈ {"HEAD", ":0"}` ⇒ `git show <rev>:<path>` (for `":0"` the object spec is `":0:" .. path`); returns content or nil (keep `git.show_head` as a one-line delegate for compatibility).
- `collect.files(root, base)` — `base` `"HEAD"` (default when nil) or `"index"`; old side from `git.show(root, base == "index" and ":0" or "HEAD", path)`.
- init: `state.base = config.options.base` at open; both `collect.files` call sites pass `state.base`/`st.base`; `M.toggle_base()` — no state ⇒ notify+return; flips `state.base`, calls `M.refresh()`, notifies `"finding_myself: diff base = worktree vs " .. (base == "index" and "index (unstaged)" or "HEAD")`.
- jump.back: `git.show(state.root, state.base == "index" and ":0" or "HEAD", ex.path)` instead of `show_head`. watch.reconcile: `collect.files(state.root, state.base)`.
- plugin command: add `"base"` to SUBCOMMANDS → `require("finding_myself").toggle_base()`. config: `base = "HEAD"`.
- [ ] **Step 1: failing tests** — `tests/test_base.lua` with a fixture that has BOTH staged and unstaged edits to one file (git_fixture, then `git add` via `vim.system`, then edit the worktree again):
  1. `base_ git.show reads HEAD and index objects` (HEAD content ≠ index content ≠ worktree; assert both `git.show` revs).
  2. `base_ index mode diffs worktree against the index` (collect.files(root, "index") old_text == staged content; "HEAD"/nil == committed content).
  3. `base_ fully-staged file disappears in index mode` (file whose worktree == index but ≠ HEAD: present in HEAD mode sections, absent (build_section nil) in index mode).
  4. `base_ toggle_base refreshes sections` (drive init headless like test_e2e.lua: open in fixture cwd, toggle_base(), assert the canvas sections changed accordingly; restore cwd).
- [ ] **Step 2:** RED. **Step 3:** implement. **Step 4:** green + full suite. **Step 5:** commit `feat: worktree-vs-index base toggle`.

---

### Task 5: Session persistence (`session.lua`)

**Files:** Create `lua/finding_myself/session.lua`. Modify `sidebar.lua` (fold accessors), `init.lua`, `config.lua` (`session = { enabled = true }`). Test: `tests/test_session.lua`.

**Interfaces:**
- `sidebar.get_folds() -> {dirpath,...}` (sorted array; `{}` when closed) and `sidebar.set_folds(folds, state)` (no-op when closed; replaces `side.folded`, refreshes).
- `session.path_for(root)` — `stdpath("state") .. "/finding_myself/" .. vim.fn.sha256(root) .. ".json"`.
- `session.save(state)` — nil-safe; captures: `base = state.base`; `collapsed` = keys of `state.collapsed` MINUS `virt.auto_set()`; `folds = sidebar.get_folds()`; `view`/`cursor` semantic anchors ONLY when the canvas is showing in `state.win`: topline section via `canvas.locate(state, top0)`, `view = viewport.capture_from_entries(entries, top_offset)` + `view.path`; cursor entry's `{path, new_lnum, content}` (skip both when the topline section is collapsed). `vim.fn.mkdir(dir, "p")`, `vim.json.encode`, write; errors swallowed (pcall) — persistence must never break closing.
- `session.load(root) -> data|nil` — nil on missing/undecodable/`version ~= 1`.
- `session.restore(state, data)` — apply collapsed (paths that still exist: `set_collapsed` by index), folds (`sidebar.set_folds`), then view: find section by `data.view.path`; if found and not collapsed, `resolved = viewport.resolve(data.view, entries)`, `topline = start_row + resolved - data.view.screen_offset` (≥1), cursor via `viewport.resolve(data.cursor, cursor-section entries)`; one `winrestview`; every step pcall/nil-guarded — any failure skips just that step.
- init: in `M.open`, load ONCE before collect (`local sess = config.options.session.enabled and session.load(root) or nil`); `st.base = (sess and sess.base) or config.options.base`; after all attach blocks: `if sess then session.restore(st, sess) end`. In `M.close` (the branch that really closes): `session.save(state)` BEFORE teardown calls. A `VimLeavePre` autocmd (augroup `finding_myself.session`, installed at open, cleared at close) saves too.
- [ ] **Step 1: failing tests** — `tests/test_session.lua` (fixture repos; drive canvas/module APIs directly plus one init-level round trip; point `stdpath("state")` writes at a temp dir by testing `session.path_for` separately and passing through the real path — the suite may write real state files; use unique tmp roots so hashes never collide):
  1. `session_ save and load round-trip the payload` (build state, collapse one section, scroll mid-canvas, save; load → base/collapsed/view.path/cursor fields as expected; view.new_lnum is a number, never a canvas row).
  2. `session_ restore reapplies collapse and view semantically` (fresh `canvas.open` of the SAME sections, restore → collapsed section is 1 row; `line("w0")` content matches the pre-save topline content).
  3. `session_ restore survives a changed diff` (regenerate sections from edited worktree content so exact lines moved; restore → no error; topline lands within ±3 rows of the anchor content's new location — assert via searching the buffer for the anchor content).
  4. `session_ auto-collapsed sections are not persisted` (virt-collapse + user-collapse different sections; save; loaded collapsed contains only the user one).
  5. `session_ init round trip` (init.open in fixture cwd → collapse a section via `<Tab>` handler equivalent (`canvas.set_collapsed`), close → reopen → still collapsed; restore cwd).
- [ ] **Step 2:** RED. **Step 3:** implement. **Step 4:** green + full suite TWICE. **Step 5:** commit `feat: session persistence of view, collapse, and folds`.
- [ ] **Step 6 (phase wrap):** README — document collapse (`<Tab>`/`za`, `<CR>` expands), virtualization thresholds, motions, statuscolumn, `:FindingMyself base`, session persistence (+ `session = { enabled = false }` opt-out). Commit `docs: phase 6 README`.

---

## Self-Review Notes

- Concept coverage §1 tiers + §7 + Phase 6 list: Tier-2 collapse ✓ (Task 1), Tier-1 auto ✓ (Task 2, thresholds configurable), persistence ✓ (Task 5, semantic-only), staged toggle ✓ (Task 4, `:0:` index base), `]f [f ]h [h` ✓, statuscolumn ✓ (Task 3). The coroutine render pump remains deferred (documented): collapse makes huge canvases cheap enough without it at this scale.
- Cross-task type consistency: `state.collapsed` read by canvas/scrollbar/hl/virt/session; `set_collapsed(state, i, bool)` used by init keymaps, virt, session.restore; `line_kinds(sections, collapsed)` second arg optional (old tests unchanged).
- Known interplay risks flagged for reviewers: collapse under an active hl viewport (hook ordering), virt vs user intent separation, statuscolumn window-option leakage (mirrors scrollbar's solved pattern), session restore racing watch's first reconcile (restore runs before watch's first debounced tick — watch triggers only on events, so no race at open).
