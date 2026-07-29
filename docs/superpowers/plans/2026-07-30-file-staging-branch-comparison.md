# File Staging and Branch Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reversible file-level staging and native read-only branch comparison without checking out refs or losing the canvas position.

**Architecture:** Extend the existing lens and source pipelines. The source domain owns Git inspection and index mutation; `App` owns user interaction, lifecycle fencing, lens selection, and reconciliation; UI modules report selected paths through owner callbacks.

**Tech Stack:** Lua, Neovim 0.10+, Git CLI, the existing custom Lua test runner.

## Global Constraints

- Keep the fixed lens cycle exactly `all → unstaged → staged → all`.
- Stage and unstage whole files only; hunk staging is out of scope.
- Branch comparison never fetches, checks out, merges, writes the worktree, or mutates either branch.
- `:CanvasDiff A..B` is tip-to-tip; `:CanvasDiff A...B` is merge-base-to-`B`; an omitted endpoint means `HEAD`.
- Preserve existing bare-ref behavior: `:CanvasDiff main` remains worktree-versus-`main`.
- Never stage a disk version while a loaded buffer for that path has unsaved changes.
- Add no runtime dependency and no Git-version floor.
- Preserve domain/facade boundaries and exact Surface ownership across asynchronous picker callbacks.

---

### Task 1: Committed-range lens and Git collection

**Files:**
- Modify: `lua/canvasdiff/diff/lens.lua`
- Modify: `lua/canvasdiff/source/repository.lua`
- Modify: `lua/canvasdiff/source/collect.lua`
- Modify: `lua/canvasdiff/source.lua`
- Test: `test/unit/test_model.lua`
- Test: `test/integration/test_git.lua`
- Test: `test/integration/test_lens.lua`

**Interfaces:**
- Produce `lens.range(left, right, operator)` and `lens.is_range(lens)`.
- Produce source operations for branch enumeration, merge-base resolution, and committed old/new-side collection.
- Range-built sections carry both `old_rev` and `new_rev`.

- [ ] Add failing unit/integration tests for range construction, validity, equality, two-dot collection, three-dot merge-base collection, invalid refs, committed A/M/D/R changes, and option-looking/whitespace paths.
- [ ] Run focused tests and confirm they fail because committed ranges are unsupported.
- [ ] Implement the minimal lens and source changes.
- [ ] Run the focused tests and architecture suite until green.
- [ ] Commit the task.

### Task 2: Commands, completion, comparison picker, and range lifecycle

**Files:**
- Modify: `lua/canvasdiff/input/command.lua`
- Modify: `lua/canvasdiff/App.lua`
- Modify: `lua/canvasdiff.lua`
- Modify: `plugin/canvasdiff.lua`
- Test: `test/unit/test_cmd.lua`
- Test: `test/integration/test_root.lua`
- Test: `test/integration/test_lens.lua`
- Test: `test/integration/test_session.lua`

**Interfaces:**
- Produce public `compare()` and `set_range(spec)`.
- Add `:CanvasDiff compare`, direct range commands, and context-aware ref completion.
- The picker uses two `vim.ui.select` calls and retains the exact originating Surface/window through a monotonic request token.

- [ ] Add failing tests for range parsing/planning, omitted `HEAD`, completion after range operators, picker ordering/cancellation/re-entry, exact Surface ownership, read-only range behavior, and range session restoration.
- [ ] Run focused tests and confirm expected failures.
- [ ] Implement command, picker, public API, lifecycle fencing, range labels, and committed-side highlighting.
- [ ] Run focused tests, lifecycle/fault tests, and architecture tests until green.
- [ ] Commit the task.

### Task 3: File-level stage/unstage cycle

**Files:**
- Modify: `lua/canvasdiff/source/buffer.lua`
- Modify: `lua/canvasdiff/source/repository.lua`
- Modify: `lua/canvasdiff/source.lua`
- Modify: `lua/canvasdiff/App.lua`
- Modify: `lua/canvasdiff/ui/sidebar.lua`
- Modify: `lua/canvasdiff/input/keys.lua`
- Modify: `lua/canvasdiff/config/settings.lua`
- Test: `test/integration/test_git.lua`
- Test: `test/integration/test_lens.lua`
- Test: `test/integration/test_sidebar.lua`
- Test: `test/unit/test_keys.lua`

**Interfaces:**
- Produce public `toggle_stage()`.
- Add configurable `keymaps.canvas.stage_cycle = "s"` and `keymaps.sidebar.stage_cycle = "s"`.
- Stage with path-scoped `git add -A`; unstage with path-scoped `git reset HEAD`, falling back to `git rm --cached` on unborn repositories.

- [ ] Add failing tests for every state transition, mixed/clean-after-stage behavior, add/delete/rename/untracked/unborn files, unsaved-buffer refusal, Git failures, canvas/sidebar actions, automatic lens following, and semantic/rename position restoration.
- [ ] Run focused tests and confirm expected failures.
- [ ] Implement source mutations and App-owned orchestration.
- [ ] Run focused, watcher, lifecycle, concurrent-review, and architecture tests until green.
- [ ] Commit the task.

### Task 4: Default compare mapping, documentation, and authoritative verification

**Files:**
- Modify: `lua/canvasdiff/config/settings.lua`
- Modify: `lua/canvasdiff/input/keys.lua`
- Modify: `lua/canvasdiff/App.lua`
- Modify: `README.md`
- Modify: `doc/canvasdiff.txt`
- Modify: `docs/architecture.md`
- Test: `test/unit/test_config.lua`
- Test: `test/unit/test_keys.lua`
- Test: `test/integration/test_cheatsheet_float.lua`

**Interfaces:**
- Add `keymaps.global.compare = "<leader>lb"`.
- Install the mapping without overwriting a foreign global mapping; `false` disables it and setup rebinds only mappings CanvasDiff still owns.

- [ ] Add failing tests for installation, collision handling, disabling/rebinding, key metadata, and cheatsheet/help visibility.
- [ ] Run focused tests and confirm expected failures.
- [ ] Implement the mapping ownership and update user/contributor documentation.
- [ ] Run focused tests, then `NVIM_LOG_FILE=/tmp/canvasdiff.log make test`.
- [ ] Commit the task.
