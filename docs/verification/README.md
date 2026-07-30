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
| `chaos-campaign.json` | the Phase 7 deliberate-breakage campaigns, both harnesses |
| `live-acceptance.json` | the Phase 8 live acceptance session |
| `live-scale.json` | the untouched real-Git five-size baseline for compatible optimization comparisons |

The million-row lane's artifact is not checked in: it is machine-specific by
construction (RSS budgets against the host allocator), so a committed copy
would read as a promise about hardware it was never measured on. Reproduce it
with `make bench-paged` and compare against the gates in
`benchmark/paged/README.md`.

The live-scale artifact is also host-specific, but is checked in as
observational evidence and a compatible same-host comparison input rather than
a universal latency or memory promise. Its portable gates cover exact content
and action correctness, heartbeat responsiveness, paging bounds, cleanup, and
the absence of crashes or unhandled worker errors.

Run the authoritative five-size ladder:

```sh
make bench-live-scale OUT=/tmp/canvasdiff-live-baseline LIVE_REPS=1
```

Use a short, explicitly non-authoritative ladder while developing:

```sh
make bench-live-scale \
  OUT=/tmp/canvasdiff-live-dev \
  SIZES=1,1000 \
  LIVE_REPS=1
```

Compare an authoritative run only with a compatible baseline:

```sh
make bench-live-scale \
  OUT=/tmp/canvasdiff-live-current \
  LIVE_REPS=1 \
  BASELINE=docs/verification/live-scale.json
```

The JSON records environment, host and capability identity; fixture/config
identity; portable thresholds; raw samples with phases, actions, observations,
correctness, heartbeat, memory, paging and cleanup evidence; per-size
p50/p95/max aggregates; structured failures; and optional comparison ratios.
Fixture construction time is reported separately and excluded from plugin
latency. Do not present fixture-build or total-process time as CanvasDiff
latency.

Allow minutes of runtime, at least 1 GiB of free temporary disk, and a
worst-case 15-minute timeout per sequential worker. Linux is the authoritative
RSS/HWM boundary; the initial latency and memory values are observational and
must not be generalized into cross-host budgets.

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

**Phase 8 live acceptance** — all eight interactions, in a real Git fixture,
through the real entry points, with what was observed recorded rather than
asserted and discarded.

```sh
make bench-acceptance
```

From the recorded session: a 30,011-row review opens page-backed over 118
pages with 30,011 skeleton rows; paging from the first row to the last takes
1,365 steps with a worst step of 1.1 ms; the canvas finds a needle at row
17,782 where Neovim's own `search()` returns 0 and the buffer line is the
empty string; a 2,000-row yank produces 85,512 bytes matching the store byte
for byte; folding and unfolding a 30,000-row file restores it exactly and
moves the heap by 124 KB; every lens applies (`staged` correctly shows one
section, the others three); a jump into a rename lands in `renamed_to.txt`
with `old_path` `renamed_from.txt` and returns to the canvas; both window
close orders leave one window; and injected Git and session failures are
contained.

## Not yet satisfied

Nothing in the journey's gate list is outstanding. Two things inside the work
are deliberate, recorded choices rather than completed items:

- **Treesitter highlighting on a paged canvas** is not attached. It is
  viewport-bounded at SECTION granularity, and one 24,000-row section produced
  8,000 persistent extmarks. Making it row-granular means driving treesitter
  from the projection's decorator.
- **`long-line` and `mixed` carry no memory gate**, for the reason given
  above: their plateau is the allocator's, not the engine's.
