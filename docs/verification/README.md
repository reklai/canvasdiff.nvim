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

**Chaos campaigns** — two harnesses, three seeds each, every invariant asserted
after every action.

The *engine* campaign runs 10,000 actions per seed over the codec/CRC/offset,
compaction-mutation, projection-reentry, timer/scheduling, text-encoding,
UI-geometry, navigation and memory seams.

The *Surface* campaign drives the real entry points against a real Git fixture
— open, close, toggle, refresh, lens pivots, window splits and closes, worktree
writes — injecting Git-process and session-write failure, and asserts that no
augroup outlives the Surface that owned it and that no two live Surfaces claim
one canvas buffer. It found a real disposal bug on its first campaign.

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

**Phase 8 live acceptance** is not recorded, and cannot honestly be, because
six of its eight interactions require the paged canvas to be on the production
*display* path — it now exists, but nothing routes to it yet — opening a million logical rows in the real canvas, searching
and yanking across page boundaries, folding while watching the heartbeat, and
reopening a session against it. `App:open` still renders the eager canvas.

What exists today is the layer beneath: the page store, projection and
scheduler are proven at a million rows by the lane above, `canvas.logical`
gives the display stack a text seam with the same shape and validation the
projection uses, `test/integration/test_logical_text.lua` proves an eager and a
paged view agree byte for byte across folds, splices, re-renders and every
range boundary, and production highlighting now reads through that seam rather
than the buffer.

The display itself is built. `canvas.paged` renders the same text at the same
logical rows as the eager canvas, byte for byte, expanded and collapsed; it
carries the same highlight groups on the same rows, emitted per visible row by
the projection's decoration provider; it draws deletion ghosts as marks bounded
by the window rather than by the canvas; it folds by splicing only the affected
section; and `section_rows`, `locate` and `set_collapsed` dispatch to it when a
state is paged, so the rest of the display stack needs no change — the skeleton
holds one blank line per logical row, so buffer rows and logical rows are the
same number.

It also has what a blank skeleton takes away. Measured rather than inferred: a
needle at logical row 6 leaves buffer line 6 as the empty string, Neovim's own
`search()` returns 0, and yanking a nine-row canvas produced nine bytes and
none of its text. So the paged canvas carries its own chunked search and its
own linewise yank, reading through the store — which is exactly the capability
Phase 8 item 2 checks.

The switchover is live. `App:open` chooses by canvas rows -- exactly, from the
model, since a section's entries are its rendered rows -- `Surface` releases
the store and projection it owns, and CursorMoved defers the idle compactor.
An e2e test opens a real repository through `:CanvasDiff`, asserts the large
review is paged and the small one is not, and checks the paged canvas carries
zero persistent extmarks.

One deliberate gap remains inside it: treesitter highlighting is not attached
to a paged canvas. It is viewport-bounded but at SECTION granularity, and a
single 24,000-row section produced 8,000 persistent extmarks -- marks that
scale with the review, which is what the paged canvas exists to prevent.
Making it row-granular means driving treesitter from the projection's
decorator. Until then a large review keeps its diff tints, file bars and
ghosts and loses syntax colour inside hunks.
