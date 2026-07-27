# Million-row paged-engine acceptance lane

This lane is the performance *gate* for the paged canvas, not a report. A
measurement outside its budget fails the lane; nothing here is advisory.

It is deliberately separate from `benchmark/run.lua`, which freezes the eager
small-canvas baseline. That lane answers "did the ordinary review get slower";
this one answers "does a million rows work at all".

## What is measured

```text
corpus iterator -> canvas.paginate_stream -> canvas.project -> viewport
```

The measured path is the engine, not the diff canvas. No step materializes a
million rows: the corpus is a pure function of the row index, ingestion is a
pull stream, and the projection renders a blank skeleton buffer whose text is
supplied by an ephemeral decoration provider.

Four deterministic corpora, each 1,000,000 rows:

| Corpus | Shape | Why |
| --- | --- | --- |
| `repetitive` | 32 recurring lines | compaction's best case |
| `unique` | every row differs | the honest upper bound |
| `long-line` | 240–256 byte rows | per-row byte cost, not row count |
| `mixed` | interleaved shapes | no page is uniformly one shape |

## Running it

```sh
nvim --headless --clean -n -i NONE \
  -l benchmark/paged/run.lua \
  /tmp/canvasdiff-paged-lane.json \
  3
```

The output path must resolve outside the checkout; the coordinator rejects a
destination that lands back inside through any symlink or `/proc` alias, and
chooses a safe temporary path when the argument is omitted. Repetitions default
to three and are bounded to 1–10.

Each measurement is a separate `nvim --headless --clean` worker with a cleared
environment and isolated XDG directories. The worker measures, publishes JSON,
and judges nothing; the coordinator validates that untrusted JSON and owns
every gate, so a worker cannot pass itself.

## The gates

| Metric | Required |
| --- | ---: |
| Logical rows | exactly 1,000,000 |
| First viewport | <= 1,000 ms |
| Sequential scroll p95 / max | <= 16 ms / 50 ms |
| Random jump p95 / max | <= 16 ms / 50 ms |
| Heartbeat gap | <= 50 ms |
| Persistent row extmarks | exactly 0 |
| Skeleton rows | exactly the logical row count |
| Resident pages / bytes | within the configured cap |
| Compaction | settled (`phase == "complete"`) |
| Random-jump plateau | last-quarter p95 <= 2x first-quarter + 4 ms |
| Repeated open/close plateau | <= 32 MiB growth across 6 cycles |
| `repetitive` RSS delta | <= 96 MiB |
| `unique` RSS delta | <= 256 MiB |
| `repetitive` / `unique` Lua heap delta | <= 128 MiB |

Two corpora carry memory budgets because the journey states two, and they
bracket the range deliberately: text that compacts hard against text where
every row differs. `long-line` and `mixed` are measured and reported without a
memory gate — see below.

### Why `long-line` and `mixed` are not memory-gated

Their resident plateau is roughly the raw corpus size even after every page is
compacted and the store's own accounting has dropped to single-digit megabytes:
one store's worth of ingestion memory stays resident for the life of the
process. That was measured flat across twenty consecutive
build/compact/discard cycles at 50,000 and 200,000 rows, so it is a bounded
one-time plateau rather than an accumulation. Gating on it would gate the
allocator rather than the engine.

What actually proves the invariant is gated instead, and directly: the resident
page and byte caps, zero persistent per-row extmarks, and the repeated
open/close plateau.

## Heartbeat, and why it is armed late

A timer ticking every 10 ms records the longest gap between its own ticks,
which is how long the editor was unresponsive *while being used* — something no
wall-clock timing of our own operations reveals. It is armed only once the
canvas is on screen. Ingestion is one synchronous burst by construction and
`first_viewport_ms` is the gate that measures it; folding ingestion into the
heartbeat would report one number for two different questions.

## Skeleton versus materialized rows

Reported separately, never conflated:

- **skeleton** — one blank line per logical row. This is what Neovim scrolls
  over, which is why native scrolling, marks and search positions stay exact.
- **decoration window** — viewport height plus overscan on both sides. These
  are the only rows whose text exists anywhere at that instant.
- **resident pages/bytes** — the bounded decoded cache behind that window.

A representative run: 1,000,000 logical rows, 1,000,000 skeleton rows, a
151-row decoration window, and 16 resident pages.

## Small-canvas regression

Speeding up a million rows must not slow the ordinary review down. Compare a
fresh eager aggregate against a recorded baseline:

```sh
nvim --headless --clean -n -i NONE \
  -l benchmark/regression.lua \
  docs/verification/eager-baseline.json \
  /tmp/canvasdiff-eager-current.json \
  10
```

It fails if median open wall time, close wall time, retained RSS or retained
Lua heap regressed by more than the tolerance, and refuses outright to compare
two runs whose fixture digests differ.

## The chaos campaign

`benchmark/chaos/` runs the Phase 7 deliberate-breakage campaign: 10,000
deterministic actions across at least three seeds, with every invariant
asserted after every action.

```sh
nvim --headless --clean -n -i NONE \
  -l benchmark/chaos/run.lua \
  /tmp/canvasdiff-chaos.json \
  10000
```

The same seams run on every `make test` as a 250-action campaign in
`test/fault/test_chaos.lua`, so a regression is caught immediately rather than
only when the long lane is next run.
