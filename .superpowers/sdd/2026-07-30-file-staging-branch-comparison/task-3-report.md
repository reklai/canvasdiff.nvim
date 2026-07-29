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

## Repair round 1

Independent review identified nine Important failure paths across pathspec
scope, rename atomicity, clean reconciliation, unborn error classification,
exact sidebar routing, stale XY state, aliased modified buffers, and reentrant
latest-intent ownership.

Repairs:

- All stage, reset, and cached-remove mutations use Git's literal-pathspec mode.
  Scope-isolation tests use a real `:(glob)*.txt` filename beside a victim file.
- Mixed rename staging is now one atomic `git add -A -- <destination>`
  mutation. The rename's old-side deletion is already represented in the
  index; a destination-only add updates or removes its current disk result
  without the destructive reset/add composite. An injected add failure proves
  the cached diff and staged blob remain byte-exact.
- Successful reset returns immediately. Only reset failure followed by
  `rev-parse --verify --quiet HEAD` exit 1 selects the unborn
  `rm --cached` fallback. Probe and fallback failures propagate without
  claiming success.
- Stage-cycle claims a shared per-Surface model epoch before status preflight,
  re-reads porcelain status for the exact selected `section.path`, and derives
  stage versus unstage from that fresh identity. Exact action lookup is
  separate from old/new rename fallback used only for cursor restoration.
- Modified-buffer refusal compares normalized paths, real paths, and
  device/inode identity, covering symlink and hard-link aliases.
- Clean post-stage results reconcile the preserved lens before notification.
- Lens changes, manual refresh, compare publication, watcher reconciliation,
  and stage-cycle share the model epoch, so a newer same-Surface intent
  supersedes an older continuation.

Additional red evidence observed before repair:

- `FILTER='pathspec%-magic'`: stage and unstage both changed the victim entry.
- `FILTER='successful unstage'`: reset success still probed HEAD.
- `FILTER='HEAD probe'`: a transient probe failure selected cached removal.
- `FILTER='failed mixed%-rename'`: injected add failure exposed the prior reset.
- `FILTER='toggle_stage'`: stale XY reversed mutation direction, stale clean
  state ran Git, and clean success retained its obsolete section.
- `FILTER='recreated rename%-source'`: selecting recreated `old.txt` unstaged
  the `new.txt` rename.
- `FILTER='symlink%-alias'`: a modified alias buffer did not block staging.
- `FILTER='newer lens intent'`: an older stage continuation overwrote the newer
  all-lens selection.

Repair verification:

- `make test SUITE=integration FILTER='git:'` — 21/21 passed.
- `make test SUITE=integration FILTER='root_'` — 45/45 passed.
- `make test SUITE=integration FILTER='concurrent_'` — 7/7 passed.
- `make test SUITE=integration` — 373/373 passed.
- `NVIM_LOG_FILE=/tmp/canvasdiff-task3-repair-full.log make test`
  — 800/800 passed.
- `git diff --check` — clean.
- Fresh scoped adversarial re-review — all nine original findings addressed;
  no new Critical or Important regression found.

Residual concern from the original implementation is closed: rename staging is
no longer a two-command mutation, so an add failure cannot discard index-only
content.
