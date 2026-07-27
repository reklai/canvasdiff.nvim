# Verification evidence

Recorded evidence for the CanvasDiff completion audit. A gate without an
artifact here does not count as passed.

Regenerate everything with:

```sh
make verify
```

Every lane writes its JSON and its Neovim log outside the checkout, so running
one never dirties the tree.

## What is recorded here

| Artifact | Gate |
| --- | --- |
| `eager-baseline.json` | the frozen small-canvas baseline the regression gate compares against |
| `chaos-campaign.json` | the Phase 7 deliberate-breakage campaign |

The million-row lane's artifact is not checked in: it is machine-specific by
construction (RSS budgets against the host allocator), so a committed copy
would read as a promise about hardware it was never measured on. Reproduce it
with `make bench-paged` and compare against the gates in
`benchmark/paged/README.md`.

## Status

### Passing

**Suite** — 677/677 across unit, integration, e2e, fault and architecture.

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-full.log make test
```

**Architecture** — 30/30, including the dependency graph, the legacy ledger,
and the retired-identity gate that proves no tracked file or path outside the
historical journey record mentions the pre-rename name.

**Million-row lane** — every gate, three repetitions across four corpora.
At 1,000,000 logical rows: first viewport 135–507 ms against a 1,000 ms budget,
sequential scroll and random jump p95 under 1.5 ms against 16 ms, heartbeat gap
~12 ms against 50 ms, **zero** persistent row extmarks, 16 resident pages and a
151-row decoration window over 1,000,000 skeleton rows. Repetitive RSS delta
26 MB against 96 MiB; unique 103 MB against 256 MiB.

```sh
make bench-paged
```

**Chaos campaign (engine seams)** — 10,000 actions across three seeds (30,000
actions total), every invariant asserted after every action, clean. Covers the
codec/CRC/offset, compaction-mutation, projection-reentry, timer/scheduling,
text-encoding, UI-geometry, navigation and memory seams.

```sh
make bench-chaos
```

**Small-canvas regression** — 1.9% on median open wall time against a 10%
budget; close time, retained RSS and retained Lua heap all inside it.

```sh
make bench-regression
```

**Ecosystem name audit** — rerun 2026-07-28. No Neovim plugin uses the name
CanvasDiff. The only similarly-named projects are unrelated to editors:
`jonathanolson/canvas-diff` (browser canvas rendering differences) and
`HumbleSoftware/js-imagediff` (canvas image diffing). Nearest neighbours in the
same problem space are `diffview.nvim` and `codediff.nvim`, both differently
named. Rerun immediately before publication.

### Not yet satisfied

**Chaos above the engine.** The campaign builds stores, projections and
schedulers, never a `Surface`, so it cannot assert the journey's "exact Surface
ownership, and disposed Surfaces own no callbacks". The Git/process, refs,
patch-streaming and filesystem/session-write seams are likewise above it. Those
need a second harness over `App`/`Surface`.

**Phase 8 live acceptance** is not recorded, and cannot honestly be, because
six of its eight interactions require the paged canvas to be on the production
*display* path — opening a million logical rows in the real canvas, searching
and yanking across page boundaries, folding while watching the heartbeat, and
reopening a session against it. `App:open` still renders the eager canvas.

What exists today is the layer beneath: the page store, projection and
scheduler are proven at a million rows by the lane above, `canvas.logical`
gives the display stack a text seam with the same shape and validation the
projection uses, `test/integration/test_logical_text.lua` proves an eager and a
paged view agree byte for byte across folds, splices, re-renders and every
range boundary, and production highlighting now reads through that seam rather
than the buffer.

The remaining work is the display itself. It is smaller than the original
handoff assumed: because the skeleton buffer holds exactly one blank line per
logical row, extmark row addressing keeps working unchanged, so section
anchors, fold splices, the sidebar's row mapping, the status column, the
scrollbar, session view restore and hunk/file motions do not need logical-row
counterparts — they need the text they read to come from the store. The one
genuine rewrite is per-section highlighting, which must become ephemeral
decoration rather than persistent extmarks to honour the zero-per-row-extmark
invariant at a million rows.
