# CanvasDiff continuation checkpoint

Date: 2026-07-27

Implementation checkpoint: `c7be8e3`

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

At `c7be8e3`, the implementation tree was clean and the full suite passed
`630/630`. The final two implementation commits before this handoff are:

- `5534b90 refactor(canvas): make page-list layout fully opaque`
- `c7be8e3 refactor(ui): give scrollbar an exact surface lease`

The recent boundary sequence also includes:

- `21f18f3` — session persistence is private behind its facade.
- `cb39923` — watch and virtualization use independent runtime leases.
- `1b3aadb` — keys and motions are private behind the input facade.
- `4ce5511` and `ce47f8b` — source collection and repository access are private
  behind the source facade.
- `a2bc4d0` — bounded idle compaction scheduling.
- `2985487`, `56a9559`, and `73a5a0f` — lease-backed projection, bounded
  resident cache, and effect-free provider callbacks.
- `65b428f` — isolated eager small-canvas benchmark baseline.

Identity migration is done. Config, diff, OS, source, canvas, runtime, and
session boundaries are established. Input currently owns keys and motions. UI
currently owns notifications and the scrollbar. The page engine, projection,
raw/compact storage, cache, and scheduler have substantial coverage, but this
does **not** certify every Phase 4/5 journey gate yet.

Important interim constraints remain:

- The root facade owns one App and App owns only `app.surface`.
- Production still enters the eager `canvas.open` path. `Canvas.lua` owns one
  module-global `canvas_buf` named `canvasdiff://canvas`.
- The current lifecycle suite deliberately shares that buffer and Surface
  across tabs. This is useful interim coverage, not satisfaction of the final
  independent-buffer/independent-Surface contract.
- Projection and Scheduler are exposed by the canvas facade and heavily tested,
  but App/Surface do not yet own them in the production open path.
- Source collection and model building still synchronously materialize whole
  section texts. Streaming patch ingestion is not yet the production path.

The active flat-module debt ledger is exactly:

```text
lua/canvasdiff/cmd.lua
lua/canvasdiff/hl.lua
lua/canvasdiff/jump.lua
lua/canvasdiff/sidebar.lua
lua/canvasdiff/statuscol.lua
lua/canvasdiff/util.lua
```

The executable source of truth is `test/architecture/rules.lua`. Never add to
that list or broaden `legacy_ceiling`.

## First safe continuation slice

Start with the highlighter, because `lua/canvasdiff/hl.lua` still has a
module-global `current` lease even though `Surface.controllers.hl` already
holds the exact returned lease.

1. Replace `current` with non-owning, unforgeable exact authentication so two
   independent highlighter leases can remain active concurrently.
2. Preserve per-lease timers, hooks, extmark ownership, unique augroups,
   stale-callback fencing, and exact idempotent detach.
3. Add concurrent-Surface, forged-shell, stale callback, reentrant replacement,
   partial resource creation, and exact teardown tests. Existing hostile
   extmark and deletion-failure tests must remain green.
4. Then move the owner to `ui/highlight.lua`, expose only the curated
   `require("canvasdiff.ui").highlight` surface, update all consumers, delete
   `canvasdiff.hl`, assert the old import fails, and remove only that ledger
   entry.

Keeping lease independence and the path move as two green commits is reasonable
if that makes review sharper. Do not merely relocate the existing singleton.

## Remaining implementation order

### 1. Empty the architecture ledger

After the highlighter:

1. Move the already lease-oriented sidebar behind `ui/sidebar.lua` and the UI
   facade. Audit its per-tab views and callbacks for exact Surface isolation;
   delete the flat path without a shim.
2. Redesign the status-column singleton. Dispatch the status expression through
   exact per-window ownership, permit concurrent Surfaces, restore only options
   the exact lease still owns, then move it to `ui/status_column.lua`.
3. Move command parsing/execution behind `input/command.lua`. Input must not
   depend on UI or call the root facade cyclically; return outcomes for App to
   execute/present. The plugin is allowed to import only the root facade, so
   route plugin -> root/App -> input rather than plugin -> input.
4. Move jump/excursion behavior behind `input/jump.lua`. Put `excursion` and
   `last_buf` under the owning Surface, route live-buffer/disk reads through the
   source/OS boundaries, and return user-facing outcomes to App instead of
   importing UI.
5. Delete `util.lua`. Its byte-exact buffer reconstruction overlaps
   `source/buffer.lua`; `list_slice` and `clamp` have no production caller.

For every owner, test simultaneous Surfaces, shared-buffer splits, exact
teardown, disposal during resource creation, stale scheduled callbacks,
reentrant replacement, forged handles, and resource-ID reuse. Run the
architecture gate in the same commit as every path move.

Before declaring Phase 2 complete, also group tests by unit, integration, e2e,
architecture, performance, and fault intent as their owners settle, and add
contributor-facing architecture/dependency documentation.

### 2. Make the production owner graph multi-Surface

After the controller ledger is empty, remove the one-App/one-buffer bottleneck:

1. Let App index live Surfaces by exact canvas-buffer identity instead of one
   `app.surface`.
2. Make Canvas create/own distinct buffers rather than finding one process-wide
   `canvasdiff://canvas`. Give every buffer a unique stable internal name.
3. Preserve the intended sharing rule: splits/tabs showing the same canvas
   buffer share one Surface; distinct canvas buffers have distinct models,
   controllers, generations, sessions, and teardown.
4. Replace fixed `canvasdiff.session`, `canvasdiff.close`, and
   `canvasdiff.winbar` groups with unique Surface-owned resources and exact
   deletion. A stale Surface must not clear a peer's group.
5. Add production-reachable tests that open two reviews concurrently, mutate
   each independently, close them in both orders, and prove no state, callback,
   option, buffer, or controller crosses ownership.

Do not reinterpret the current cross-tab shared-buffer lifecycle tests as this
gate; retain them alongside the new distinct-buffer cases.

### 3. Put paging and streaming on the production path

Replace eager `canvas.open` ownership in App/Surface with the logical page
store, Projection, and Scheduler. Surface must own and dispose the exact
projection/scheduler instances, activity must reset the bounded idle scheduler,
and small canvases may use eager rendering only as a measured optimization
behind the same logical-text contract.

Before attempting million-row acceptance, make patch ingestion incremental.
The current source/model path holds whole old/new texts and synchronously builds
the complete section list, so page-backed display alone cannot meet the
end-to-end memory and responsiveness goal.

### 4. Close the logical-text and compaction gates

Re-audit Phases 4 and 5 line by line rather than inferring completion from the
presence of Page/Projection classes. In particular, prove the eager/paged
oracle for random inserts, deletes, replacements, folds, lens pivots, and
viewport restoration, plus cross-page search, yank, range export, selection,
cursor-column behavior, jump, and session restore.

Keep compaction cold, complete-page-only, unpinned, generation-fenced, and
bounded to one candidate per scheduler step with at most eight inspected
candidates. Decode/CRC/codec failure must never publish partial or stale state.

### 5. Build the million-row performance lane

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

### 6. Deliberately break it

Implement the named Phase 7 seams across Git/process, refs, patch streaming,
codec/CRC/offsets, compaction mutation, projection reentry, timers/scheduling,
filesystem/session writes, text encodings, UI geometry, navigation, and memory.

Then run 10,000 deterministic actions for at least three seeds. After every
action, assert page/anchor invariants, cache bounds, exact Surface ownership,
and that disposed Surfaces own no callbacks. Record the seed and enough action
history for exact replay.

The scrollbar still needs the broad Phase 7 creation-return/ID-reuse matrix
(augroup/buffer/window creation returning after reentrant disposal). Its
current focused lease checkpoint has no known blocker, but those chaos seams
remain part of final completion.

### 7. Live acceptance and publication audit

Run every Phase 8 interaction in a real Git fixture and check commands, seeds,
logs, benchmark JSON, and observed behavior into `docs/verification/`. Finally
rerun the current ecosystem-name search immediately before publication, prove
the legacy identity is absent, rerun every unit/integration/e2e/performance/
fault gate, write the missing final user help (`doc/canvasdiff.txt`), and leave
the tree clean.

## Commands and hygiene

Always redirect Neovim's log outside the checkout:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-full.log make test
NVIM_LOG_FILE=/tmp/canvasdiff-architecture.log make test FILTER='^architecture_'
NVIM_LOG_FILE=/tmp/canvasdiff-highlight.log make test FILTER='^hl_'
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

An independent prospective owner audited the repository and this handoff at
the checkpoint and returned **READY**. Its chosen first command was the
documented `^hl_` focused gate; its chosen first code slice was failure-first
concurrent-Surface and forged-lease coverage followed by removal of
`hl.lua`'s `current` selector, without moving the path in that first commit.
