# Task 2 report: commands, completion, comparison picker, and range lifecycle

Status: DONE

## Files changed

- `lua/canvasdiff.lua`
- `lua/canvasdiff/App.lua`
- `lua/canvasdiff/input/command.lua`
- `lua/canvasdiff/source/repository.lua`
- `plugin/canvasdiff.lua`
- `test/unit/test_cmd.lua`
- `test/integration/test_git.lua`
- `test/integration/test_root.lua`
- `test/integration/test_session.lua`

## Test-first failures

- `NVIM_LOG_FILE=/tmp/canvasdiff-task2-red-cmd.log make test SUITE=unit FILTER='^cmd_'`
  - `12/18 passed`.
  - Missing `compare`, range normalization/planning, ref completion, and
    range-prefix completion failed at their intended boundaries.
- `NVIM_LOG_FILE=/tmp/canvasdiff-task2-red-branches.log make test SUITE=integration FILTER='^git: branches'`
  - `0/1 passed`.
  - The old source interface returned ambiguous short strings and omitted
    remote symbolic defaults instead of full-ref metadata.
- `NVIM_LOG_FILE=/tmp/canvasdiff-task2-red-picker.log make test SUITE=integration FILTER='^root_'`
  - `7/12 passed`.
  - The public `compare`/`set_range` operations and picker did not exist.
- `NVIM_LOG_FILE=/tmp/canvasdiff-task2-red-context-complete.log make test SUITE=integration FILTER='^root_ compare picker orders'`
  - `0/1 passed`.
  - App completion did not inspect repository branch metadata.
- `NVIM_LOG_FILE=/tmp/canvasdiff-task2-red-range-session.log make test SUITE=integration FILTER='^session_ committed range'`
  - `0/1 passed`.
  - The public string range API rejected `topic..` rather than normalizing the
    omitted right side to `HEAD`.
- `NVIM_LOG_FILE=/tmp/canvasdiff-task2-red-buffer-complete.log make test SUITE=integration FILTER='^root_ resolves from the current buffer'`
  - `0/1 passed`.
  - Buffer-repository completion exposed an early local-scope error.
- `NVIM_LOG_FILE=/tmp/canvasdiff-task2-red-early-token.log make test SUITE=integration FILTER='^root_ compare invalidates its predecessor'`
  - `0/1 passed`.
  - A prior picker could reenter during newer-request repository inspection
    because invalidation happened too late.
- Reviewer repair reds:
  - Unowned-origin and cwd-drift routes each failed `0/1` before exact
    Surface/window/root targeting.
  - A real jump-excursion route failed `0/1` because the hidden Surface was
    pivoted without visibly reopening.
  - Owned and unowned post-collection re-entry each failed before a guard was
    threaded through the final transaction; stale-error variants then failed
    because the obsolete errors were presented.
  - Colliding local/remote `origin/topic` refs failed until Git's disambiguated
    short names were preserved.
  - A tag colliding with local `main` failed with `master` ordered first until
    conventional bases were classified by full ref identity.

## Passing verification

- Focused command: `18/18 passed`.
- Focused picker/root after review repairs: `20/20 passed`.
- Focused range session: `1/1 passed`.
- Focused branch metadata: `1/1 passed`.
- `NVIM_LOG_FILE=/tmp/canvasdiff-task2-unit.log make unit`: `285/285 passed`.
- Post-review integration:
  `NVIM_LOG_FILE=/tmp/canvasdiff-task2-integration-review-fixes.log make integration`:
  `331/331 passed` before the final re-entry/collision regressions.
- `NVIM_LOG_FILE=/tmp/canvasdiff-task2-fault.log make fault`: `92/92 passed`.
- `NVIM_LOG_FILE=/tmp/canvasdiff-task2-architecture.log make architecture`: `30/30 passed`.
- `git diff --check`: exited 0 with no output.
- Final authoritative command:
  `NVIM_LOG_FILE=/tmp/canvasdiff-task2-final.log make test`
  - Exact summary: `760/760 passed`.

## Implementation notes

- Direct `..` and `...` commands normalize either omitted endpoint to `HEAD`;
  bare refs retain their existing worktree-versus-ref meaning.
- Repository branch enumeration returns full execution refs plus display
  metadata, including current-local and remote-default classification.
- Picker base and comparison lists follow their separate deterministic orders.
  Picker selections execute only full refs and always construct a three-dot
  range.
- Each picker request invalidates its predecessor at method entry and captures
  the exact originating window, Surface identity, and Surface generation.
  Cancellation is silent; delayed, replaced, focused-elsewhere, and reentrant
  callbacks cannot redirect the result.
- Range sessions restore before collection/rendering, remain uneditable, and
  do not alter the index, worktree, or checked-out ref.

## Independent review

- Reviewer A found two Important exact-target regressions:
  - unowned windows could redirect through `active_surface` or drift to a new
    cwd;
  - the first repair pivoted a hidden jump-excursion Surface without reopening.
  Both findings were repaired with red/green tests and scoped re-review returned
  `ADDRESSED` with no new Critical/Important breakage.
- Reviewer B found three Important classes:
  - stale final transactions could publish after collection re-entry;
  - colliding local/remote short names collapsed completion identity;
  - a tag collision could hide local `main` from conventional-base priority.
  All were repaired with red/green tests. Scoped re-reviews returned
  `ADDRESSED` for every attack.

## Commit

- `5f2b7d8` — `feat: add read-only branch comparison picker`

## Self-review

- Full refs are used only for execution; short names remain display/completion
  values and local/remote ambiguity remains visible in picker labels.
- The request token increments before repository inspection so even injected
  reentry during source lookup observes the old request as stale.
- Range behavior reuses Task 1's committed-side collection/highlighting and
  keeps the named lens cycle unchanged.
- No unresolved Critical, Important, or Minor review findings.

## Controller fix round 1

### Clean-room findings

The controller supplied these initial findings verbatim:

```text
FINDING: Important | lifecycle/re-entry correctness | lua/canvasdiff/App.lua:1541 | Repository discovery can re-enter compare(), yet the stale invocation may still present its picker or error without rechecking the token/owner. | Recheck after discovery and add a regression proving the older request presents nothing.

FINDING: Important | lifecycle/re-entry correctness | lua/canvasdiff/App.lua:1268 | After the post-collection guard, pivot/open perform re-entrant Neovim mutations without further fencing, allowing an invalidated request to publish range state or construct a Surface. | Fence post-collection publication transactionally and test re-entry from reconcile/open callbacks.

ATTACK: Important | reentry/stale publication | lua/canvasdiff/App.lua:1541 | Inject source.branches so an older compare() reenters app:compare() during branch enumeration, then returns its old list or error. The outer call never rechecks its token, so it can publish an obsolete picker or stale warning. | Create the request guard before enumeration and recheck it after repository/root lookups and before errors or picker publication.

ATTACK: Important | multi-window excursion ownership | lua/canvasdiff/App.lua:1583 | With two canvas hosts for one Surface, enter an excursion in window A while B still shows the canvas, invoke compare from A, and select both refs. Global surface:is_showing() is true because of B, so A remains on the excursion file instead of showing the chosen comparison. | Decide using whether the originating window displays the canvas; reopen through that exact window when it is in an excursion.

ATTACK: Important | cross-App Surface replacement | lua/canvasdiff/App.lua:1517 | Start App A’s picker from an unowned window, then let App B open a Surface there. App A cannot see B’s registry, so owner == nil passes and A overwrites B’s canvas, leaving B’s Surface/controllers alive but displaced. | Bind unowned requests to the originating buffer or ownership epoch and invalidate them when the window is repurposed, including by another App.
```

Scoped review then exposed the following additional failure paths:

```text
OPEN: Finding 2 | App.lua:1305 reconciles sections before the stale check, with no rollback. A reconciler that re-enters and then performs the real reconciliation leaves stale range contents under the old lens. The regression at test_root.lua:583 stubs reconciliation without mutating state, so it misses this failure. Later pivot/open publication boundaries also remain unfenced.

NEW FINDING: Important | range/fold correctness | App.lua:1305 | Moving st.lens assignment after reconciliation makes lens-dependent folded rendering and folded_seen records use the previous lens (Canvas.lua:255, Canvas.lua:811, Canvas.lua:914). This corrupts stale-fold semantics even without re-entry. | Reconcile transactionally against the candidate lens while retaining rollback capability, and add folded-range pivot coverage.

OPEN: multi-window excursion ownership | App.lua:1639-1650 | The originating host is shown, but canvas.show() bypasses jump.back() and leaves surface.excursion plus its buffer-local return mapping active. Revisiting that file and invoking the mapping rebuilds a worktree section into the committed-range canvas, violating range read-only correctness. | Consume or explicitly cancel the excursion and remove its mappings before presenting the range.

OPEN: Finding 2 | App.lua:1347 | Real stale reconciliation is now rolled back, but rollback blindly restores the older snapshot. If a re-entrant newer picker completes synchronously before the older callback returns, rollback_pivot() overwrites that newer committed result. The regression starts a newer picker but leaves it pending, so it does not cover newest-request publication. The unowned open path also has no token checks after open_canvas() succeeds and Surface/controller publication begins.

OPEN: lens-scoped fold/rollback transaction | App.lua:1306-1325 | rollback_pivot() mutates the live state and calls reentrant canvas.render_all() without guarding rollback itself. If a newer request completes during rollback, obsolete rollback resumes over the newer comparison.

OPEN: Finding 2 | App.lua:1534 | Checkpoints preserve a newer different lens, but a nested newer picker selecting the same lens as the outer provisional lens takes the idempotent early return without creating a transaction/checkpoint. The stale outer rollback then restores the older snapshot, losing the newer selection. | Bypass the early return while a provisional compare transaction is active, or explicitly checkpoint the newer same-lens commit; add synchronous same-selection coverage.

NEW FINDING: Important | stale persistence | App.lua:721 | The unpublished stale Surface is torn down through normal Surface:dispose(), which calls Surface:save() and persists its invalidated range session. Although no Surface is published and the window is restored, a later open can restore the stale comparison. | Add an unpublished-abort teardown that skips session persistence, and verify session.load(root) remains unchanged after Surface.new re-entry.
```

### Test-first evidence

- Initial regressions produced `20/26 passed` in the focused root suite:
  stale branch list and error, real reconcile/open re-entry, exact multi-window
  excursion return, and cross-App buffer replacement all failed at their
  intended assertions.
- Mutation-realistic reconcile and folded-range regressions produced
  `25/27 passed`: stale range content remained in the model/buffer and
  `folded_seen.lens` recorded `all` instead of `range:main...topic`.
- The stale excursion regression failed with the excursion store and
  `<M-CR>` buffer mapping still active after committed-range selection.
- Synchronous nested publication plus post-`open_canvas` Surface construction
  produced `27/29 passed`: the old rollback restored `all`, and one stale
  Surface was registered.
- Re-entry from `canvas.render_all` during rollback produced `1/2 passed` in
  the synchronous-newer filter: the latest lens survived but its empty model
  was overwritten by the obsolete checkpoint.
- Same-lens nested selection ended at `all` before the provisional idempotence
  fix.
- Unpublished Surface abort replaced an existing `unstaged` session sentinel
  with the invalidated range before the no-persistence abort path.

### Repair

- Request identity now exists before repository discovery and is checked after
  every root/branch lookup before any error or picker publication.
- Unowned requests bind exact window plus buffer identity, including
  replacement by another App; an internal unpublished canvas buffer is the only
  temporary identity exception during guarded construction.
- Open construction is checked after canvas creation and after `Surface.new`.
  Stale canvases restore the original buffer and unpublished Surfaces abort
  through cleanup that deliberately skips session persistence.
- Pivot publication is transactional. The candidate lens is visible during
  reconciliation for correct fold semantics, while snapshots retain model,
  fold state, lens, and per-window views for rollback.
- Nested transactions publish monotonic committed checkpoints. Stale rollback
  restores the newest committed checkpoint, restarts if rendering or view
  restoration synchronously commits another request, and forces same-lens
  nested selections through reconciliation while a provisional transaction is
  active.
- A committed-range pivot consumes the Surface excursion only after the pivot
  commits, removes its buffer-local return mappings, and then shows the exact
  originating host. No later return can inject worktree content.

### Verification and review

- Focused input facade: `3/3 passed`.
- Final focused root: `31/31 passed`.
- Final fault suite: `92/92 passed`.
- Final architecture suite: `30/30 passed`.
- Final authoritative full suite:
  `NVIM_LOG_FILE=/tmp/canvasdiff-task2-round1-full-final3.log make test`
  — `771/771 passed`.
- `git diff --check` exited 0 with no output.
- Reviewer A returned `ADDRESSED` for repository enumeration, transactional
  reconciliation/open, fold correctness, nested newer/different and same-lens
  publication, and stale-session persistence, with no new Critical/Important
  breakage.
- Reviewer B returned `PASS` after exact excursion cancellation and
  epoch-ordered rollback fencing, including re-entry during rollback itself.
- No unresolved Critical, Important, or Minor findings remain.

### Fix commit

- `0cb8236` — `fix: fence reentrant comparison publication`

## Whole-change repair

### Controller findings

The controller supplied these findings verbatim:

```text
Important | ownership/lifecycle | lua/canvasdiff/App.lua compare publication (review line ~2552 before later commits) | Invoking global compare mapping from fixed sidebar resolves its Surface, commits selected range, then tries canvas.show(..., request.win) on sidebar winfixbuf. This throws E1513 after announcing new lens, leaving partial success/error. | Classify picker origin when request is created. Sidebar origin must retain sidebar and use the same Surface’s canvas host window, not treat sidebar as excursion. Guard canvas.show/publish failure transactionally. Regression: invoke global callback with sidebar current, complete both selects, assert no error, same sidebar survives, canvas host shows range, exact Surface/lens committed once.

Important | concurrency/model integrity | watcher claims model_epoch only in on_change after runtime/watch has collected/published | Watch collects all lens, reentrant set_lens(staged) commits newer staged content, stale watcher resumes/publishes old sections. State lens says staged but text is worktree/all; can also overwrite stage/compare continuation. | Claim/capture model publication token before watch collection, verify surface/lens/token before and after reconciliation, discard stale publication transactionally. Prefer route through guarded pivot or extend watch runtime contract so collection cannot publish without current owner token. Regression must reproduce reentrant lens change during watch collection and assert staged lens/content stay consistent; also cover close/reopen and stage/compare ownership if relevant.
```

### Test-first evidence

- Fixed-sidebar comparison failed `0/1` with `E1513: Cannot switch buffer.
  'winfixbuf' is enabled` after the range lens had already been selected.
- Injected `canvas.show()` refusal failed `0/1`: the state retained
  `range:refs/heads/main...refs/heads/zeta` instead of restoring `all`, proving
  publication was outside the pivot transaction.
- Reentrant watch collection failed `0/1`: an all-lens snapshot reached
  `canvas.reconcile_sections` after `set_lens(staged)` had committed.
- Extending the exact excursion regression failed `0/1` when selecting an
  already-active range from an owned non-canvas host, catching a provisional
  idempotence regression before final verification.

### Repair

- Comparison requests now classify their origin as canvas, sidebar, or
  excursion while capturing the exact Surface generation and host. A sidebar
  request authenticates its exact sidebar-to-canvas pairing and never attempts
  to replace the fixed sidebar buffer.
- Excursion publication is now part of the guarded pivot transaction.
  `canvas.show`, host adoption, view capture, winbar publication, and sidebar
  reconciliation must succeed before excursion cancellation or the success
  diagnostic. Failure restores the prior visible buffer, primary window,
  winbar, lens, sections, folds, and views.
- Idempotent same-lens comparison still executes required host publication,
  while remaining silent about an unchanged lens.
- Each watcher pass claims the shared Surface `model_epoch` before collecting,
  captures the exact lens, and validates generation/lens/epoch before and after
  collection and reconciliation. App-owned watch publication routes through
  the same snapshot/checkpoint/rollback pivot as refresh, stage, and compare,
  so reentry both during collection and inside reconciliation cannot overwrite
  the newer staged model.
- Direct runtime watch reconciliation retains its existing standalone
  behavior; the token and transactional-publisher callbacks are optional owner
  contracts.

### Scoped review repair

Reviewer B found one additional Important failure path:

```text
ATTACK: Important | transactional rollback | lua/canvasdiff/App.lua:1931 | With two owned windows, start compare from an excursion in A while B still displays the canvas. The provisional pivot updates B’s winbar at line 1965; if publication back into A then fails at `canvas.show`, rollback restores lens/model/buffer but never restores B’s window-local label, leaving it advertising the failed committed range. The existing failure test has no second canvas window, so it cannot detect this residue. | Snapshot and restore affected winbars/controllers during rollback, or transactionally resync all consumers from the restored checkpoint; add a multi-window publication-failure regression checking B’s winbar and consumer state.
```

The extended two-host regression failed `0/1`, observing the peer winbar still
labelled `refs/heads/zeta vs merge-base(refs/heads/main)` instead of
`worktree vs HEAD`. Rollback now resynchronizes winbars and all live
highlight/sidebar/scrollbar/virtualizer consumers from the restored checkpoint.
The regression then passed `1/1`.

### Verification and review

- Focused fixed-sidebar publication: `1/1 passed`.
- Focused publication-failure rollback: `1/1 passed`.
- Focused pre-collection and post-reconcile watcher fencing: `1/1 passed`.
- Exact excursion/idempotent publication regression: `1/1 passed`.
- Root integration: `56/56 passed`.
- Watch integration: `22/22 passed`.
- Fault suite: `92/92 passed`.
- Final authoritative full suite:
  `NVIM_LOG_FILE=/tmp/canvasdiff-task2-whole-full-final.log make test`
  — `831/831 passed`.
- `git diff --check` exited 0 with no output.
- Reviewer A returned `PASS` on requirement coverage and correctness.
- Reviewer B's sole Important peer-winbar finding was repaired test-first.
  Both independent scoped re-reviews returned `ADDRESSED`, with no new Critical
  or Important breakage.
