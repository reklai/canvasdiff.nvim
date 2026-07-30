# Benchmark operators

## Live Git scale campaign

The live-scale lane replays CanvasDiff against fresh, deterministic real-Git
fixtures with exactly 1, 1,000, 10,000, 100,000, and 1,000,000 changed content
lines. Each size and repetition gets a fresh headless Neovim worker and an
isolated temporary repository.

Run the authoritative five-size ladder with its default single repetition:

```sh
make bench-live-scale OUT=/tmp/canvasdiff-live-baseline
```

`LIVE_REPS` defaults to `1`. More repetitions multiply both runtime and work.
For a non-authoritative development run, override the ordered sizes explicitly:

```sh
make bench-live-scale \
  OUT=/tmp/canvasdiff-live-dev \
  SIZES=1,1000 \
  LIVE_REPS=1
```

A `SIZES` override is always recorded as non-authoritative and cannot publish
`docs/verification/live-scale.json`. Compare a new authoritative run with the
checked-in baseline only on the same compatible host and measurement setup:

```sh
make bench-live-scale \
  OUT=/tmp/canvasdiff-live-current \
  LIVE_REPS=1 \
  BASELINE=docs/verification/live-scale.json
```

Comparison refuses mismatched schema/profile, authoritative sizes, repetition
count, seed, fixture/config identity, host fingerprint, or RSS/HWM capability
sources. Source revisions and tree digests are provenance, so they may differ
between the baseline and an optimization.

The aggregate uses schema `canvasdiff.live_scale/v1`. Its top level records the
overall status/verdict, authoritative flag and size ladder, repetitions and
seed, environment/host/provenance identity, capability and fixture identity,
portable thresholds, configuration digest, raw `samples`, per-size
`aggregates`, structured `failures`, cleanup evidence, and output path. Each
successful sample retains the worker's phase timings, Git/source adapter
timings, action trace and observations, correctness evidence, heartbeat,
memory checkpoints, paging/extmark state, cleanup, and process diagnostics.
Per-size summaries report sample count plus p50, p95, and maximum phase,
operation, source, first-view, heartbeat-gap, peak-RSS, and retained-heap
metrics. A requested baseline adds either compatible ratio rows or precise
incompatibility reasons.

This is an expensive lane. Expect minutes rather than seconds and reserve at
least 1 GiB of free temporary disk for the largest worktree, Git objects, and
diagnostic output. Workers run sequentially and each has a 15-minute timeout,
so one default ladder has a 75-minute failure-path ceiling. Temporary fixture
directories are removed after each worker; failed cleanup is itself a gate.

Fixture construction is deliberately timed as `fixture_build`, but it starts
before the heartbeat and is excluded from CanvasDiff plugin latency. Do not
quote fixture time, total process time, or Git repository creation time as
plugin latency. Use source, open/first-view, and operation metrics for plugin
claims.

RSS and HWM are observational in this first machine-dependent baseline.
Linux, with supported current-RSS and peak-RSS sources, is the authoritative
memory boundary. Other platforms may report capabilities, but they do not
create or relax a Linux memory gate. Portable correctness, responsiveness,
paging, cleanup, finite-metric, and no-unhandled-error gates still apply
everywhere they are supported.

The live lifecycle reports 100 ms as its responsiveness target and attributes
the worst heartbeat gap to an exact action. Its hard gate is a 2 second
bounded-completion ceiling: the campaign deliberately includes synchronous
million-row collection and reconciliation, so treating 100 ms as a universal
pass/fail promise would reject correct baseline evidence instead of measuring
it. Watch convergence remains finite and scales from 1.5 to at most 5 seconds
with the requested content rows.

## Isolated eager-canvas baseline

This lane freezes the ordinary-project performance of CanvasDiff's current
eager renderer before the paged `Projection` replaces it.

Each measurement starts a fresh `nvim --headless --clean` worker with a
cleared environment. The coordinator supplies only an explicit executable
path, locale, Git configuration policy, `NVIM_LOG_FILE`, and isolated
`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, and
0700 `XDG_RUNTIME_DIR`. Inherited Git identity, date, template, hook, and
`GIT_CONFIG_COUNT` variables therefore cannot perturb the fixture.

Workers build the same small Git fixture, invoke the real `:CanvasDiff open`
command, verify the resulting eager canvas, and measure command wall time,
RSS, and Lua heap. The fixture commit, content digest, complete eager-render
digest, and source-tree digest must agree across every worker.

Optional controllers are disabled for this profile. The measured path is:

```text
:CanvasDiff open -> Git collect -> diff/model build -> eager canvas render
```

Run five isolated repetitions:

```sh
nvim --headless --clean -n -i NONE \
  -l benchmark/run.lua \
  /tmp/canvasdiff-eager-baseline.json \
  5
```

The output path is required to resolve outside the repository. Because atomic
rename replaces the final path component, the coordinator canonicalizes the
destination parent (or its nearest existing ancestor) and then appends the
basename. This rejects parent-directory symlink and `/proc/self/cwd` aliases
back into the checkout, including a repo-local output symlink whose target is
outside. If omitted, it chooses a unique JSON path under a canonical temporary
directory outside the checkout.

The isolated worker root is subject to the same repository-containment check;
an inherited `TMPDIR` that resolves into the checkout is ignored in favor of a
safe system temporary directory.

Repetitions default to five and are bounded to 1–20. A malformed repetition
value or any third/additional argument is rejected instead of being ignored or
silently replaced with the default.

The aggregate artifact has schema version 1:

```text
schema_version, benchmark, profile, status, repetitions
environment  -- Git dirty state plus revision and exact source-tree digest
capabilities -- selected RSS/HWM source and whether HWM is sampled fallback
corpus       -- deterministic fixture shape, object ID, and content digest
runs[]       -- correctness evidence, raw metrics, worker exit diagnostics
aggregate    -- min/median/max for each metric
```

The source digest covers tracked and nonignored untracked worktree paths,
including explicit records for tracked paths that are currently missing.

Any command failure, missing section, wrong anchor count, invalid buffer
option, leaked canvas view, malformed schema/metric, cross-run inconsistency,
timeout, nonzero signal, or nonzero worker exit makes the coordinator fail
after publishing diagnostic JSON and retaining its isolated worker directory.

RSS uses `vim.uv.resident_set_memory()` with `/proc/self/status` `VmRSS` as a
fallback. High-water RSS uses `VmHWM` when present and otherwise reports the
maximum sampled RSS explicitly as a fallback capability. The lane fails
before measurement if neither current-RSS source is available.

Allocation-heavy row and extmark verification happens only after immediate,
post-GC retained, close, and post-close metrics have been captured. The eager
buffer remains valid but hidden after close, allowing exact verification
without contaminating those measurements.
