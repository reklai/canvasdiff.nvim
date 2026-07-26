# CanvasDiff migration and million-line journey

Date: 2026-07-26

Status: executable plan

## Outcome

Turn Galley into CanvasDiff through a behavior-preserving architectural
migration, then replace whole-document rendering with a paged logical canvas
that can review and vertically scroll one million logical rows without event
loop stalls or unbounded resident state.

Completion means every gate in this document is evidenced by a command,
benchmark artifact, or fault-injection test. A successful rename alone is not
completion.

## Decisions that should not drift mid-migration

1. Refactor package boundaries while the namespace is still `galley`.
2. Perform one atomic identity rename after those boundaries are green.
3. Do not ship Galley compatibility modules, commands, highlights, session
   names, or forwarding aliases.
4. Introduce the page engine under the final CanvasDiff identity.
5. Keep pure diff/model/page code independent from `vim`, filesystem, process,
   time, and UI state.
6. Keep one root facade and one facade per domain. Cross-domain imports target
   facades, not another domain's internals.
7. Use PascalCase only for concrete stateful types. Avoid `main.lua`,
   `util.lua`, and catch-all helper directories.
8. Treat performance limits as correctness constraints, with automated gates.

The identity decision is supported by
[the name audit](../research/2026-07-26-canvasdiff-name-audit.md). The page
design is supported by
[the Ghostty study](../research/2026-07-26-ghostty-scrollback-study.md).

## Target repository shape

```text
plugin/canvasdiff.lua
lua/canvasdiff.lua
lua/canvasdiff/
  App.lua
  Surface.lua
  config.lua
  config/{defaults,validate}.lua
  diff.lua
  diff/{differ,lens,model,text,word_diff}.lua
  source.lua
  source/{buffer,collect,git,patch_stream}.lua
  canvas.lua
  canvas/{Canvas,Page,PageList,Projection,anchors,fold,render,viewport}.lua
  canvas/compression/{codec,compact,spool}.lua
  input.lua
  input/{command,jump,keys,motions}.lua
  ui.lua
  ui/{highlight,notify,scrollbar,sidebar,status_column}.lua
  runtime.lua
  runtime/{scheduler,watch}.lua
  session.lua
  session/codec.lua
  os.lua
  os/{clock,fs,process}.lua
  benchmark.lua
  benchmark/{corpus,metrics}.lua
  testing.lua
  testing/tripwire.lua
test/
  run.lua
  helpers.lua
  architecture/
  unit/
  integration/
  e2e/
  performance/
  fault/
benchmark/
docs/
doc/canvasdiff.txt
```

The target is a direction, not permission to create empty taxonomy. A
directory or facade lands only with its first real owner and an architecture
test.

## Dependency direction

```text
plugin -> canvasdiff facade -> App -> Surface
                                 |
        +------------------------+------------------------+
        v                        v                        v
      input                    runtime                   ui
        |                        |                        |
        +-----------+------------+------------+-----------+
                    v                         v
                  source                    canvas
                    |                         |
                    +------------+------------+
                                 v
                                diff
                                 |
                                 v
                                os
```

`session` is a codec/storage boundary used by `App` and `Surface`; it does not
own a live surface. `benchmark` and `testing` may observe public facades but
production domains never depend on them.

An architecture test must parse every tracked Lua `require`, reject cycles,
reject forbidden reverse edges, and reject cross-domain internal imports.

## Commit and verification protocol

Every commit:

1. Has one user-visible behavior or one named architectural invariant.
2. Runs the smallest relevant test file first.
3. Runs `make test`.
4. Runs `git diff --check`.
5. Leaves no debugging output, generated benchmark corpus, or accidental log.

Moves that cannot be made green independently may share a commit with their
exact import updates. Identity changes belong to the single rename commit, not
to surrounding refactors.

## Phase 0 — freeze and record the baseline

Already satisfied:

- Existing uncommitted work was reconstructed into 16 coherent commits.
- The final reconstructed tree is byte-identical to
  `backup/pre-canvasdiff-checkpoint`.
- `324/324` baseline tests pass.
- `git diff --check` is clean.

Keep the backup branch until the entire journey is accepted.

## Phase 1 — close baseline correctness gaps

### Branch-lens contract

The baseline explicit-ref lens enumerated only worktree status. Consequences
reproduced before the fix:

- A clean checkout compared with an older ref reports zero changed files.
- A nonexistent ref plus a dirty file can fabricate an empty old side.

This was closed as four regression-first commits before moving modules:

1. Resolve explicit refs to commit OIDs before mutating lens or surface state.
2. Enumerate committed `A/C/D/M/R/T` changes against that OID with
   NUL-delimited Git output.
3. Merge those paths with worktree/index status and untracked files.
4. Preserve both `path` and `old_path` for renames.
5. Carry `old_rev` and rename metadata through collection and the model.
6. Represent a pure rename as a header-only section rather than dropping it.
7. Jump to the new path; rebuild the old side from the old path and commit.
8. On initial invalid ref, open nothing and retain the previous lens.
9. If a watched ref disappears, retain the existing canvas and report the
   refresh failure once.

Required fixtures include clean committed add/delete/modify/rename versus an
older base, an untracked file, invalid ref with a dirty file, live ref deletion,
rename jump/back, and filenames containing tabs/newlines.

### Lifecycle contract

Before extracting owners, characterize the existing close, wipe, split,
session-save, and subsystem-stop behavior with integration tests. Then enforce
the stronger ownership properties while `App` and `Surface` are introduced:

- Closing or wiping any canvas/sidebar window cancels owned work exactly once.
- A late timer, watcher callback, or jump-back callback becomes a no-op after
  surface disposal.
- Two splits displaying the same review buffer share one Surface and model;
  closing one split does not dispose it while another split remains.
- Independent review buffers in different tabs have different Surfaces,
  controllers, folds, lenses, and teardown effects.

The stronger ownership and isolation guarantees are Phase 2 outcomes, not
prerequisites for creating the owner that makes them possible.

Phase 1 gate: every branch-lens fixture passes, collection failures are
transactional, and the full behavior suite is green.

## Phase 2 — establish Ghostty-style boundaries under `galley`

Move in dependency order so each commit stays green:

1. Move `tests/` to singular `test/` without changing execution order.
2. Add a transitional layout/dependency guard whose exact legacy allowlist can
   only shrink.
3. Pin the application lifecycle and same-buffer split contract.
4. Add `lua/galley.lua` as the sole public facade, with `App` as composition
   and `Surface` as one review buffer's lifetime owner.
5. Move all live module state, controllers, timers, handles, callbacks, and
   augroups under their owning Surface. Guard queued callbacks by exact Surface
   identity and generation.
6. Support independent Surfaces per review buffer/tab while deliberately
   sharing one Surface across splits of the same buffer.
7. Extract `os` process/filesystem/time adapters from Git, session, and watch.
8. Establish pure `diff` and `source` facades.
9. Establish `canvas` and `ui` facades; move rendering state into a concrete
   `Canvas` owner.
10. Establish `input`, `runtime`, and `session` boundaries.
11. Group tests by unit, integration, e2e, architecture, performance, and fault
    intent as their owning domains move.
12. Delete `util.lua` by moving each function to its natural owner.
13. Add contributor architecture documentation and the final dependency test.

No forwarding modules are allowed. A move and all of its callers change
together.

Gate:

- `require("galley")` is the only supported public import.
- No module-global live Surface/controller singleton remains.
- Queued callbacks from a disposed/replaced Surface cannot act on its
  replacement.
- Independent Surfaces pass isolation and exactly-once teardown tests.
- Domain-cycle and forbidden-edge tests pass.
- Pure-domain tests run under plain Lua semantics with a minimal `vim` stub or
  none.
- Full behavior suite remains green.

## Phase 3 — atomic identity migration

In one behavior-neutral commit:

1. Rename plugin entrypoint, root facade, and module tree.
2. Rename `:Galley` to `:CanvasDiff`.
3. Rename highlight groups, augroups, namespaces, buffer names/filetypes,
   user messages, health identifiers, session filenames/versions, and test
   fixtures.
4. Rename documentation, examples, benchmark labels, environment variables,
   and repository-local metadata.
5. Update every `require`, command assertion, and runtime guard.

Required negative gates:

```sh
git grep -In -i galley -- ':!docs/journeys/2026-07-26-canvasdiff-migration.md'
```

The command must find no legacy production, test, or documentation token
outside this historical journey file. In a clean headless Neovim:

- `require("canvasdiff")` succeeds.
- `:CanvasDiff` exists and opens a fixture.
- `require("galley")` fails.
- `:Galley` does not exist.
- No `Galley*` highlight group or runtime namespace is created.

Do not add a deprecation alias. Git history is the migration path.

## Phase 4 — separate logical text from its projection

Introduce the page engine without compression first:

1. `Page` owns encoded logical rows and validates offset monotonicity.
2. `PageList` owns ordered page metadata, prefix row counts, binary lookup,
   mutation generations, and pin counts.
3. `Projection` owns the skeleton buffer and visible-row overlay.
4. Existing canvas anchors refer to stable logical row/section identities,
   never raw buffer rows alone.
5. Search, yank, range export, cursor column, selection, jump, and session
   restore use a `LogicalText` contract.
6. Small canvases and million-line canvases share the same correctness model;
   the eager renderer may remain an optimization below a measured threshold.

Provider rules:

- One decoration provider is registered and dispatches by buffer.
- `on_win` computes and restores the bounded visible page set.
- `on_range` only reads resident pages and emits ephemeral virtual text.
- Provider callbacks do not mutate buffers, start jobs, schedule callbacks, or
  throw across the Neovim boundary.
- Backing rows remain blank in overlay mode.
- No persistent extmark exists per logical row.

Correctness gate: a model oracle compares eager and paged output across random
inserts, deletes, replacements, folds, lens pivots, and viewport restoration.

## Phase 5 — add bounded compaction

Add compression behind the page accessor:

1. Encode pages as row offsets plus concatenated bytes.
2. Add raw and optional LZ4 codecs with an explicit codec tag.
3. Store expected decoded length, row count, and checksum in resident metadata.
4. Compact only complete, cold, unpinned, non-visible pages.
5. Attempt at most one page per scheduler step after a 250 ms activity-token
   debounce.
6. Inspect at most eight candidates per step and reschedule pending work after
   1 ms.
7. Skip work on lock/reentrancy contention.
8. Keep compressed data only when the entire representation is smaller.
9. Restore to a bounded LRU, atomically publishing a page only after all
   validation passes.
10. Restart traversal after generation changes and finish with a verification
    pass.

The raw codec is always supported. Missing LZ4 is a reported capability, not a
startup failure.

## Phase 6 — million-line performance gates

Ship deterministic benchmark corpora:

- `repetitive`: realistic repeated diff/context structure.
- `unique`: incompressible path and source-like content.
- `long-line`: byte cap stress with multibyte and very long rows.
- `mixed`: additions, deletions, binary notices, folds, and rename headers.

Run benchmarks in a clean headless process and save machine-readable JSON with
Neovim version, Lua engine, codec, CPU, corpus seed, and Git revision.

Minimum acceptance on the development machine:

| Metric | Gate |
| --- | ---: |
| Logical rows | exactly 1,000,000 |
| First visible viewport | <= 1,000 ms |
| Sequential-scroll p95 / max | <= 16 ms / 50 ms |
| Random-jump p95 / max | <= 16 ms / 50 ms |
| Repetitive-corpus RSS delta | <= 96 MiB |
| Unique-corpus RSS delta | <= 256 MiB |
| Lua heap delta | <= 128 MiB |
| Resident restored cache | configured bound, zero unbounded growth |
| Persistent row extmarks | 0 |
| Event-loop heartbeat gap | <= 50 ms during steady interaction |
| Small-canvas regression | <= 10% against the frozen baseline |

The one-million blank skeleton rows are native scroll coordinates, not
materialized logical text. Report both skeleton row count and rich/materialized
row count so the metric cannot be gamed.

Repeated open/close and random-jump runs must plateau. Because allocator RSS is
a high-water measurement, cleanup gates use live page/cache counts, Lua heap
after collection, and per-cycle growth slope rather than demanding that RSS
return to its initial number.

## Phase 7 — deliberate breakage

Every fault is injected through a named seam and asserts both the error result
and cleanup:

| Area | Injected failure | Required outcome |
| --- | --- | --- |
| Git | spawn failure, nonzero exit, missing executable | old surface retained; one actionable error |
| refs | invalid initially, deleted while watched, ref moves mid-read | no fabricated empty side; generation retry |
| stream | chunk split at every byte, cancellation, stale generation | exact parser output; stale result discarded |
| patch | malformed header, truncated hunk, NUL, binary marker | bounded diagnostic; no partial publication |
| rename | tab/newline path, add/delete/rename collision | correct old/new ownership and jump target |
| page codec | bad tag, checksum, size, offsets, truncated LZ4 | page quarantined; renderer survives |
| compactor | mutation during encode/decode, pinned page, cache eviction | restart/skip; never publish stale bytes |
| projection | buffer wiped, provider reentry, draw after dispose | safe no-op and complete teardown |
| scheduler | timer fires after close, watcher storm, lock contention | coalesced bounded work; no resurrection |
| storage | read-only dir, full disk, short write, corrupt session | current session survives; atomic replacement |
| text | empty, no-EOL, CRLF, invalid UTF-8, huge line, NUL | byte-correct logical operations |
| UI | missing Tree-sitter parser, narrow window, ambiwidth double | readable fallback; no render exception |
| navigation | cross-page search/yank/selection and fold boundaries | same result as eager oracle |
| memory | incompressible million rows, forced cache churn | stays under hard limits or fails before publish |

Add a deterministic chaos test that executes 10,000 seeded actions across lens
switches, folds, edits, writes, refreshes, jumps, window closure, and injected
failures. After each action, assert page invariants, anchor monotonicity,
surface ownership, cache bounds, and lack of callbacks owned by disposed
surfaces.

## Phase 8 — live acceptance

Run interactive smoke sessions in a real Git fixture:

1. Open one million mixed logical rows and drag, wheel, page, and jump from
   first to last row.
2. Search across page boundaries, yank a multi-page range, and compare bytes
   with the source oracle.
3. Fold/unfold far directories while watching memory and event-loop heartbeat.
4. Pivot worktree/index/HEAD/explicit-ref lenses during file writes.
5. Jump into a rename, edit, return, and verify old/new paths and position.
6. Close canvas, sidebar, origin, and excursion windows in every order.
7. Kill Git operations, corrupt a cold page, remove LZ4, and make the session
   directory unwritable during the session.
8. Reopen the session and verify semantic cursor/fold restoration.

Capture commands, corpus seed, logs, benchmark JSON, and observed UI behavior
in `docs/verification/`. A smoke session without recorded evidence does not
satisfy a gate.

## Final completion audit

The journey is complete only when all of the following are true:

- The ecosystem-name audit was rerun immediately before publication.
- No tracked legacy identity or compatibility alias remains.
- Architecture tests prove the intended dependency graph.
- The complete unit, integration, e2e, performance, and fault suites pass.
- Million-line metrics meet every hard gate on both repetitive and unique
  corpora.
- The 10,000-action chaos run is deterministic and clean under at least three
  seeds.
- Live acceptance evidence is checked in.
- Working tree and index are clean.
- Documentation describes the final behavior rather than a planned behavior.

If a gate fails, record the evidence and keep the journey open. Do not relabel
the failure as an accepted limitation without an explicit product decision.
