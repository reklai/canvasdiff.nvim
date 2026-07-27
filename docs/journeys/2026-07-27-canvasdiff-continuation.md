# CanvasDiff continuation checkpoint

Date: 2026-07-27

Implementation checkpoint: `64d8504`

This is a stopping-point handoff, not a completion claim. The original goal
remains the full [CanvasDiff migration and million-line journey](2026-07-26-canvasdiff-migration.md),
including its performance, deliberate-breakage, live-acceptance, and final
publication gates.

## Resume contract

Keep these decisions fixed unless the product direction is explicitly changed:

1. CanvasDiff is the only public identity. Do not add retired-name aliases,
   compatibility modules, or old-path shims.
2. Cross-domain imports enter through the domain facade. Internals are private,
   the architecture ledger may only shrink, and a moved flat module is deleted
   in the same commit that updates its consumers.
3. `Surface` owns every live controller. Splits of one canvas buffer share one
   Surface; independent canvas buffers have independent leases and teardown.
4. A lease is authenticated by exact private identity, not copyable public
   fields. It owns unique resources, invalidates before external teardown, and
   rechecks identity after every callback that can reenter.
5. No module-global live-controller singleton may choose which Surface wins.
   Process-wide namespaces, monotonic IDs, and non-owning lookup registries are
   acceptable; live state and cleanup authority are not.
6. Million-row text stays page-backed and bounded. The projection keeps blank
   native scroll coordinates, emits only ephemeral visible decoration, and
   creates no persistent extmark per logical row.
7. Performance limits are correctness gates. Fault injection and deterministic
   chaos are required evidence, not optional polish.

## Exact checkpoint state

At `0c78532`, the implementation tree is clean and the full suite passes
`677/677`.

- Sections 1 and 2 are **done**.
- Section 3's ingestion half is done, its logical-text seam is in place,
  production readers go through it, and the page-backed **display now
  exists**: `canvas.paged` renders the same text at the same logical rows as
  the eager canvas, with the same highlight groups and the same deletion
  ghosts, and holds no persistent extmark. What remains is the switchover --
  `App:open` still builds the eager canvas, and `Surface` still owns no
  Projection or Scheduler.
- Section 4 is partly closed -- the eager/paged oracle is pinned, the
  compaction bounds the journey names (one candidate per scheduler step, at
  most eight inspected) are the Scheduler's own constants, and cross-page
  search, yank and range export are built and proven on the paged canvas.
  Lens pivots, selection, cursor-column behaviour and session restore against
  a paged canvas are not yet covered.
- Section 5 is **done**. Every hard gate passes at 1,000,000 rows, three
  repetitions across four corpora, plus the small-canvas regression gate.
- Section 6 is partly done. The engine campaign runs 10,000 actions across
  three seeds, clean, with every invariant asserted after every action. The
  Git/process, refs, patch-streaming, session-write and Surface-ownership
  seams need a second harness above the engine.
- Section 7 is partly done: the help file exists, the identity and
  ecosystem-name audits pass, `make verify` runs every gate, and the evidence
  is in `docs/verification/`. Phase 8's live acceptance is **not** recorded,
  because six of its eight interactions need the paged display first.

Commits since the previous checkpoint:

- `dafa45a`, `24e5a5c` -- highlighter leases are independent, and the owner
  moves to `canvasdiff.ui.highlight`.
- `2d869a2` -- the sidebar moves to `canvasdiff.ui.sidebar` with unforgeable
  lease identity.
- `801bb25` -- the status column dispatches per window and moves to
  `canvasdiff.ui.status_column`. Three real concurrency defects fixed.
- `8e3b1bd` -- `canvasdiff.input.command` returns plans App executes.
- `f41da90` -- `canvasdiff.input.jump` owns excursions per Surface;
  `util.lua` deleted; the architecture ledger is empty.
- `1d1ece1` -- tests grouped by intent; `docs/architecture.md` written.
- `0ec79e8` -- two reviews can be open at once, through the production path.
- `50d3cac` -- fault tests build second reviews with `canvas.open`.
- `851d2c0` -- collection streams one file at a time.
- `55e7be9` -- a section can release both file sides and still fingerprint
  and render.
- `64d8504` -- `canvas.logical` states the logical-text contract, and the
  eager/paged oracle is pinned against it.
- `57c99b3` -- the million-row acceptance lane, and the production restore
  adapter it needed. Nothing in production had ever built one, so every
  compaction attempt failed with "adapter is not configured" and the whole
  compaction tier was unreachable outside tests.
- `bf44bcb` -- the Phase 7 deliberate-breakage campaign, with an oracle so
  that correctness is compared rather than assumed.
- `70f7866` -- `doc/canvasdiff.txt`, and `make verify`.
- `0c78532` -- production highlighting reads canvas text through the logical
  seam rather than the buffer.

The architecture ledger is empty and that is a gate, not a milestone:
nothing classifies as legacy any more, so a new flat module under
`lua/canvasdiff/` fails the scan for having no architectural owner.

Interim constraints that REMAIN:

- Production still enters the eager `canvas.open` path. Nothing calls
  `diff.release_text` yet, and Surface owns no Projection or Scheduler.
- Projection and Scheduler are exposed by the canvas facade and heavily
  tested, but no production code creates one.
- `canvas.logical` exists and is proven equivalent to a Projection, but no
  production caller reads through it yet -- App, the sidebar, the status
  column and the scrollbar still read buffer lines directly.
- The root facade owns one App; App now indexes many Surfaces, one per
  canvas buffer.

The executable source of truth is `test/architecture/rules.lua`. Never add to
`R.legacy_paths` or broaden `legacy_ceiling`.

## Remaining implementation order

### 1. Empty the architecture ledger -- DONE at `1d1ece1`

Every module reached its owning domain, the ledger is empty, tests are grouped
by intent, and `docs/architecture.md` states the boundary rules. Four findings
from this section are worth carrying forward, because they are the shape of
what the remaining sections will hit:

- Removing a module-global selector does not merely relocate state; it exposes
  the concurrency defects the selector was hiding. The status column had three.
- Neovim remembers a window-local option per displayed buffer. Restoring after
  the real buffer lands is too late; the write-back has to happen while the
  canvas is still on screen.
- A lease that loses a shared resource to a peer must release its own
  bookkeeping for it, or its own teardown later restores over the new owner.
- Attach reads one synchronous snapshot. When it runs inside another window's
  creation event that snapshot can already be stale, and nothing will say so.

### 2. Make the production owner graph multi-Surface -- DONE at `0ec79e8`

App indexes reviews by their own canvas buffer, `Canvas.open` creates a
distinct `canvasdiff://canvas/<n>` per review, and the session/close/winbar
groups carry the Surface id. Which review a command acts on is answered by
the window you are in, falling back to the most recently opened live review.
`test/integration/test_concurrent_reviews.lua` drives two repositories, two
windows, independent mutation, per-repo session files, and closing in both
orders through `require("canvasdiff")` alone.

Two findings worth carrying forward:

- A replacement review has its own buffer, so inheriting a host window is no
  longer enough to keep the review visible in it. Hosts showing the retired
  canvas must be moved onto the new one.
- Window adoption was wrong in a way one review could never reveal. A window
  being CREATED beside a canvas view transiently displays that canvas, and
  stays on it across WinNew, BufWinEnter, WinEnter and WinResized. Adoption
  is now provisional until the event loop turns -- a second synchronous
  sighting is NOT enough, and that was tried first.

### 3. Put paging and streaming on the production path -- PARTLY DONE (the keystone)

The ingestion half is done at `851d2c0` and `55e7be9`:

- `source.file_stream` and `source.section_stream` read one file's two sides
  at a time. Planning (ref resolution, the ref-relative diff, the porcelain
  status merge, path ordering) is one bounded round of git plumbing that
  reads no content at all. `files` and `sections` are the eager consumers.
- `diff.release_text` drops a section's two sides. Its fingerprint is taken
  at build time and stored, so "did this file change" outlives the text.
  Highlighting asks its owner for a released side; App answers through the
  source boundary, and a missing, throwing or non-string answer yields no
  treesitter marks rather than a wrong highlight.

What REMAINS, and what makes it large:

1. Nothing calls `release_text` in production, because nothing yet consumes
   sections incrementally -- `App:open` still collects the whole list.
2. Surface owns no Projection or Scheduler. It must own and dispose exact
   instances, and activity must call `Scheduler:touch()`.
3. The real work: `Projection` renders a BLANK skeleton buffer and emits
   ephemeral decoration through a decoration provider. The entire existing
   display stack -- section anchors as extmarks, `section_rows`, fold and
   collapse splices, `replace_section`, the highlighter's per-section
   extmarks, the sidebar's row mapping, the status column, the scrollbar,
   session view restore, and hunk/file motions -- assumes real buffer text at
   real buffer rows. A page-backed canvas needs a counterpart for each of
   those against LOGICAL rows.

   The seam itself now exists: `canvas.logical(state)` answers `row_count`,
   `row`, `rows` and `export` with the same shape and the same validation
   `Projection` does, and `test/integration/test_logical_text.lua` proves a
   paged view of the same rows agrees byte for byte across folds, splices,
   re-renders and every range boundary. Production readers are routed through
   it as of `0c78532`.

   **This estimate was too pessimistic, and the correction matters.** The
   skeleton buffer holds exactly one blank line per logical row -- that is
   what keeps native scrolling, marks and search positions exact. So extmark
   ROW ADDRESSING keeps working unchanged. Section anchors, fold splices, the
   sidebar's row mapping, the status column, the scrollbar, session view
   restore and hunk/file motions therefore do NOT each need a logical-row
   counterpart. They need one thing: the text they read to come from the
   store instead of the buffer, which is what the seam above is for.

   The one genuine rewrite is per-section highlighting. It currently places
   persistent extmarks per section, and at a million rows that violates the
   resume contract's zero-persistent-extmark-per-row invariant directly. It
   has to become ephemeral decoration emitted by the projection's provider
   for visible rows only. Start there: everything else is a read that already
   has a seam.

4. `PageList.from_iterator` is the ingestion entry point for step 3 -- it
   takes exactly the `next_row` shape `section_stream` can be adapted into.

### 4. Close the logical-text and compaction gates

Re-audit Phases 4 and 5 line by line rather than inferring completion from the
presence of Page/Projection classes. In particular, prove the eager/paged
oracle for random inserts, deletes, replacements, folds, lens pivots, and
viewport restoration, plus cross-page search, yank, range export, selection,
cursor-column behavior, jump, and session restore.

Keep compaction cold, complete-page-only, unpinned, generation-fenced, and
bounded to one candidate per scheduler step with at most eight inspected
candidates. Decode/CRC/codec failure must never publish partial or stale state.

### 5. Build the million-row performance lane -- DONE

The existing `benchmark/run.lua` is the isolated eager small-canvas baseline,
not the million-row acceptance lane. Preserve it and add a separate
coordinator/worker with deterministic `repetitive`, `unique`, `long-line`, and
`mixed` corpora plus machine-readable environment and revision metadata.

Hard gates from the journey:

| Metric | Required |
| --- | ---: |
| Logical rows | exactly 1,000,000 |
| First viewport | <= 1,000 ms |
| Sequential scroll p95 / max | <= 16 ms / 50 ms |
| Random jump p95 / max | <= 16 ms / 50 ms |
| Repetitive RSS delta | <= 96 MiB |
| Unique RSS delta | <= 256 MiB |
| Lua heap delta | <= 128 MiB |
| Persistent row extmarks | 0 |
| Heartbeat gap | <= 50 ms |
| Small eager regression | <= 10% |

Also prove resident-cache bounds, repeated open/close and random-jump plateaus,
and separately report skeleton versus rich/materialized row counts.

### 6. Deliberately break it -- PARTLY DONE

Implement the named Phase 7 seams across Git/process, refs, patch streaming,
codec/CRC/offsets, compaction mutation, projection reentry, timers/scheduling,
filesystem/session writes, text encodings, UI geometry, navigation, and memory.

Then run 10,000 deterministic actions for at least three seeds. After every
action, assert page/anchor invariants, cache bounds, exact Surface ownership,
and that disposed Surfaces own no callbacks. Record the seed and enough action
history for exact replay.

**Done at `bf44bcb`, for the engine seams.** `test/fault/chaos.lua` is the
harness; `test/fault/test_chaos.lua` runs 250 actions across three fixed seeds
on every `make test`, and `benchmark/chaos/run.lua` runs the full 10,000 across
three seeds. It carries an oracle -- a plain Lua array beside the store -- so
correctness is compared rather than assumed, and injected failure is expected
to be REFUSED rather than survived.

Covered seams: codec/CRC/offsets (a hostile codec that corrupts blocks, lies
about checksums, refuses to encode, or returns short), compaction mutation
(splices against a live compactor), projection reentry, timers and scheduling
(dispose and rebuild under a live store), text encodings (empty rows, NUL
bytes, invalid UTF-8, CR, wide characters, rows larger than a page budget), UI
geometry, navigation, and memory (resident caps asserted after every action).

**Not yet covered**, and still required: Git/process failure, refs, patch
streaming, and filesystem/session writes -- these live above the engine, in the
source and session domains, and need a second harness over `App`/`Surface`.
That harness is also where the journey's "exact Surface ownership, and disposed
Surfaces own no callbacks" assertions belong; the engine campaign cannot make
them because it never builds a Surface.

The scrollbar still needs the broad Phase 7 creation-return/ID-reuse matrix
(augroup/buffer/window creation returning after reentrant disposal). Its
current focused lease checkpoint has no known blocker, but those chaos seams
remain part of final completion.

### 7. Live acceptance and publication audit -- PARTLY DONE

Run every Phase 8 interaction in a real Git fixture and check commands, seeds,
logs, benchmark JSON, and observed behavior into `docs/verification/`. Finally
rerun the current ecosystem-name search immediately before publication, prove
the legacy identity is absent, rerun every unit/integration/e2e/performance/
fault gate, write the missing final user help (`doc/canvasdiff.txt`), and leave
the tree clean.

Done: `doc/canvasdiff.txt` exists (`:help canvasdiff-mappings`, which
`config.settings` already told users to read, now resolves). `make verify` runs
the suite, the regression gate, the million-row lane and the chaos campaign in
one command. The retired-identity gate passes -- the pre-rename name survives
only in the historical journey record. The ecosystem-name audit was rerun on
2026-07-28: no Neovim plugin uses the name, and the similarly-named projects
are unrelated to editors. Evidence is in `docs/verification/`.

Not done: **Phase 8 live acceptance**. Six of its eight interactions -- a
million rows in the real canvas, search and yank across page boundaries,
folding while watching the heartbeat, lens pivots during writes, and session
restore against it -- require section 3's paged display, because `App:open`
still renders the eager canvas. Recording anything else as Phase 8 evidence
would be recording a session that did not test what Phase 8 names.

## Commands and hygiene

Always redirect Neovim's log outside the checkout:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-full.log make test
NVIM_LOG_FILE=/tmp/canvasdiff-architecture.log make architecture
NVIM_LOG_FILE=/tmp/canvasdiff-fault.log make fault
NVIM_LOG_FILE=/tmp/canvasdiff-highlight.log make test SUITE=fault FILTER='^hl_'
git diff --check
git status --short
```

The eager baseline is:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-benchmark-nvim.log \
  nvim --headless --clean -n -i NONE \
  -l benchmark/run.lua /tmp/canvasdiff-eager-baseline.json 5
```

Do not commit `nvim.log`, generated corpora, or ad hoc benchmark output.
Preserve the ignored user-owned `.claude/` and `.superpowers/` directories.
Stage exact paths only, keep commits independently green, and retain the backup
branch until the whole journey is accepted.

## Failure traps already discovered

- A weak-key registry is authentication only. Its values must not own the key
  or the retained resource graph.
- Any `alive`, `claim`, `release`, timer, autocmd, codec, checksum, or Neovim
  API wrapper can reenter and dispose/replace the owner. Check exact identity
  both before and after it returns.
- Teardown must unlink/invalidate the lease before closing timers, windows,
  buffers, groups, hooks, or extmarks.
- PageList rollback must restore hostile mutations to the public handle,
  protected metatable/private layout slot, weak handle reference and its
  metatable, and registry mapping.
- Retired and discarded page nodes must sever `node.page`; otherwise decoded
  pages survive through dead structural nodes.
- LuaJIT traces can retain dead local slots in GC tests. Run disposable worker
  coroutines and call `jit.flush()` only after the worker completes; do not
  disable production JIT behavior to make a lifetime test pass.
- Provider callbacks must not mutate buffers, start jobs, schedule work, or
  throw across Neovim. `on_win` may synchronously pin and restore only its
  bounded visible/overscan pages; `on_range` reads only already pinned resident
  pages and emits ephemeral marks. Compaction and asynchronous scheduling stay
  outside both callbacks, and stale generations fail closed.
- Never trust a left-gravity boundary anchor at the exact end of a splice;
  explicitly replace the following boundary anchor.

## Takeover criterion

A new agent should be able to start from this file and the canonical journey,
confirm `git status --short` is empty, run the full suite, and begin the
highlighter independence slice without any private conversation context. If a
fact here disagrees with executable tests or `test/architecture/rules.lua`,
the executable contract wins and this handoff should be corrected in the same
commit as the discovery.

The next slice is to route production readers through `canvas.logical`, so
that swapping in a paged canvas is a change of implementation rather than a
change of every caller. Then Surface's ownership of an exact Projection and
Scheduler, with activity calling `Scheduler:touch()`, and only then the
paged canvas itself.

Sections 4 to 7 remain, and each is substantial: the logical-text and
compaction oracles, a million-row performance lane with measured RSS and
latency budgets, 10,000 deterministic chaos actions across at least three
seeds, and live acceptance evidence checked into `docs/verification/`.
