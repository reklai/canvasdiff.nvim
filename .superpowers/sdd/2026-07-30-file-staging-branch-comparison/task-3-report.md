# Task 3 report: file-level stage/unstage cycle

## Status

Implemented the file-level stage/unstage cycle through the source facade,
App-owned orchestration, the public root facade, and configurable canvas and
sidebar actions.

## Behavior delivered

- `toggle_stage()` stages whenever the selected file has an unstaged status
  column (including mixed staged/unstaged state), and otherwise unstages a
  fully staged file.
- Staging captures the current disk state with path-scoped
  `git add -A --`; rename identities explicitly include old and new paths.
- Unstaging uses path-scoped `git reset HEAD --`, with an explicit
  `git rm --cached --ignore-unmatch --` fallback for unborn repositories while
  preserving worktree bytes.
- Loaded modified buffers block staging but not unstaging.
- Unstaged and staged lenses follow the operation; all and arbitrary-ref lenses
  stay in place; committed ranges and missing XY status decline without Git.
- A post-stage clean file reports clean without pivoting into an empty lens.
- Canvas and sidebar use the configurable `stage_cycle = "s"` action.
  Directory rows decline.
- Reconciliation is fenced by exact Surface identity, generation, and a
  per-Surface stage epoch. Git mutations are never rolled back; post-Git
  ownership or reconciliation failures say the index changed and refresh
  failed.
- Cursor restoration uses semantic line anchors and destination/source rename
  fallback.

## TDD evidence

Red examples observed before production changes:

- `make test SUITE=integration FILTER='stage captures'`
  failed because `source.stage` was absent.
- `make test SUITE=unit FILTER='stage_cycle'`
  failed because the default action did not resolve.
- `make test SUITE=integration FILTER='toggle_stage'`
  failed because the public root operation was absent.
- `make test SUITE=unit FILTER='keys_install'`
  failed because the canvas had no installed `s` callback.
- `make test SUITE=integration FILTER='stage_cycle declines'`
  failed because the sidebar had no action and attempted normal-mode editing.
- `make test SUITE=integration FILTER='unborn unstage'`
  failed because unstage checked HEAD before attempting the required reset.
- `make test SUITE=integration FILTER='prerequisite reset'`
  failed because a failed rename add did not disclose the successful index
  reset.

Focused green evidence:

- `make test SUITE=integration FILTER='git:'` — 16/16 passed.
- `make test SUITE=integration FILTER='toggle_stage'` — 9/9 passed.
- `make test SUITE=integration FILTER='stage_cycle declines'` — 1/1 passed.
- `make test SUITE=integration FILTER='stage_cycle and both'` — 1/1 passed.
- `make test SUITE=integration FILTER='preserves nearest line'` — 1/1 passed.
- `make unit` — 286/286 passed.
- `make test SUITE=integration` — 362/362 passed at that checkpoint.
- `make test SUITE=architecture` — 30/30 passed.
- `make fault` — 92/92 passed.

Authoritative final verification:

- `NVIM_LOG_FILE=/tmp/canvasdiff-task3-full.log make test`
  — 790/790 passed.
- `git diff --check` — clean.

## Coverage added

The new coverage exercises mixed state, additions, deletions, renames,
untracked files, unusual and option-looking paths, unborn repositories,
modified buffers, Git failures and partial composite mutations, clean results,
canvas/sidebar callbacks, directory decline, lens policy, public API, semantic
rename restoration, lifecycle invalidation, watcher coexistence, and concurrent
review isolation.

## Concerns

Rename staging is necessarily a two-command composite when Git has already
removed the old path from the index: the path pair is reset to HEAD before the
required `git add -A -- old new`. If the add fails after that successful reset,
the index is partially changed. The source API and App explicitly surface that
fact instead of claiming atomic failure or attempting a Git rollback.
