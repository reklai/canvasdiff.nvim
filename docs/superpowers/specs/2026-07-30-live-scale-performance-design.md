# Live Git Scale Performance — design

Date: 2026-07-30
Status: approved by continuation of the recommended design

## Purpose

CanvasDiff already has two complementary performance proofs: a synthetic
million-row paged-canvas gate and a real-Git 30,000-row acceptance journey.
Neither proves the complete Git-to-screen lifecycle at the requested
`1 → 1,000 → 10,000 → 100,000 → 1,000,000` line scale, and the live journey
does not attribute enough time to identify the layer responsible for a
regression.

The new campaign measures the real plugin at every requested size, repeatedly
tears down and rebuilds its state, and replays supported user actions and
failure paths. It must expose actionable latency, responsiveness, memory, and
correctness evidence without adding measurement overhead to ordinary plugin
use.

## Requirements

- **R1 — exact scale ladder.** Run deterministic real-Git fixtures whose
  primary diff contains exactly 1, 1,000, 10,000, 100,000, and 1,000,000
  added content lines. Report the plugin's actual logical-row count separately
  because canvas metadata adds rows around file content.
- **R2 — process isolation.** Run every size/repetition in a fresh headless
  Neovim worker and create its fixture in a unique temporary directory. A
  failed worker must become a structured failed sample without contaminating
  later sizes. The coordinator owns cleanup and writes results atomically.
- **R3 — two measured profiles.**
  - The core profile measures repository discovery, source collection/model
    construction, canvas opening/first viewport, sequential paging, random
    jumps, close, reopen, and cleanup.
  - The lifecycle profile replays search, bounded cross-page yank, fold/unfold,
    lens cycling, manual refresh after a write, watcher-driven refresh,
    file/hunk navigation, jump/back, stage/unstage, branch comparison,
    committed-range comparison, injected Git failure, close orders, and
    repeated close/reopen.
- **R4 — representative mutation.** Keep the million-line primary file present
  throughout scale testing. Exercise reversible stage/unstage on small sidecar
  files so the campaign measures CanvasDiff's lifecycle rather than repeatedly
  rewriting a million-line Git index entry. Branch/range fixtures include
  add/modify/delete/rename identities.
- **R5 — deterministic replay.** Seed every generated choice, record the seed
  and action trace, use bounded action counts at every size, and validate model
  invariants after each action. A failed action records its index, name, error,
  and the preceding trace needed to reproduce it.
- **R6 — sound metrics.** Record monotonic wall time for fixture creation
  (excluded from plugin latency), source collection, open-to-first-view,
  sequential and random navigation, each lifecycle action, close/reopen, and
  total worker time. Summaries contain sample count, p50, p95, and maximum.
  Also record lines/second, maximum heartbeat gap, Lua heap before/peak/after
  collection, current/peak RSS when supported, page/cache residency, extmark
  count, and retained memory after garbage collection.
- **R7 — benchmark-owned instrumentation.** Phase attribution uses worker-local
  wrappers installed before the App loads. Production modules gain no clock,
  telemetry sink, conditional branch, environment-variable check, or default
  runtime allocation solely for this campaign.
- **R8 — correctness before speed.** Every sample verifies exact content
  digests, first/last logical rows, search and yank bytes, collapse restoration,
  lens/branch/range identity, stage/unstage index state, source jump path,
  watcher convergence, close cleanup, reopen equivalence, and absence of
  leaked timers/autocmds/windows. A latency sample is invalid if its correctness
  checks fail.
- **R9 — two-tier acceptance.**
  - Portable hard gates cover correctness, bounded completion, heartbeat
    responsiveness, cleanup, finite metrics, page/cache bounds, and absence of
    crashes or unhandled errors.
  - Same-host comparisons cover latency and memory regression using matching
    environment, fixture, config, seed, source-tree identity, and sample count.
  - The existing absolute million-row paged-engine gates remain authoritative.
    The first live baseline is observational for machine-dependent latency; it
    does not invent universal timing promises from one host.
- **R10 — actionable output.** Emit one versioned JSON artifact containing the
  environment/capability record, thresholds, per-sample raw observations,
  aggregate ladder summaries, action traces, failures, and an overall verdict.
  Emit a compact terminal table ordered by scale. Refuse incompatible baseline
  comparisons rather than silently comparing unlike runs.
- **R11 — bounded optimization.** Capture the unmodified baseline first.
  Optimize only bottlenecks demonstrated by phase and resource evidence.
  Preserve public behavior and trust/platform boundaries. Each optimization
  must have a failing regression or benchmark assertion, a focused correctness
  suite, and before/after evidence.
- **R12 — authoritative finish.** After optimization, run the exact five-size
  live ladder, the existing million-row paged campaign, the chaos campaign,
  and one fresh full test suite. Apply the repository's bounded adversarial
  review: no unsupported-platform expansion, no reopening accepted areas
  without a concrete supported-behavior regression, and no more than five
  repair rounds per task.

## Architecture

### Coordinator

`benchmark/live_scale/run.lua` is the only process that aggregates or publishes
results. It parses sizes, repetitions, seed, output path, and optional compatible
baseline; launches one `worker.lua` process per sample; validates each worker
record; computes quantiles and scale ratios; and atomically publishes the final
artifact. It continues after a worker failure so the artifact shows the whole
ladder, then exits nonzero.

The default sizes are fixed to the requested ladder. A `SIZES` override exists
only for focused development and is recorded as non-authoritative. The
authoritative target rejects a missing, duplicate, reordered, or substituted
size.

### Fixture

`benchmark/live_scale/fixture.lua` creates a repository using streaming writes,
not a million-element Lua table. The base commit contains a header-only primary
file plus sidecars. The worktree adds exactly `N` deterministic primary-file
content lines and includes small staged, unstaged, untracked, deleted, and
rename cases. Two refs provide branch and committed-range comparisons.

Fixture construction is measured and reported but excluded from CanvasDiff
latency. All Git subprocess failures include argv, exit code, signal, and
bounded stderr.

### Worker and action replay

`benchmark/live_scale/worker.lua` boots CanvasDiff with deterministic paging,
watch, session, and highlight settings; installs timing adapters before loading
the App; opens the live fixture; and delegates action sequencing to
`benchmark/live_scale/actions.lua`.

Actions are named records with `run`, `assert`, and cleanup behavior. Expensive
actions use bounded spans or sidecars, but no requested size skips semantic
coverage. Size-dependent iteration counts are explicit in the artifact. Teardown
runs through a protected finalizer even after an assertion or injected fault.

### Metrics and comparison

`benchmark/live_scale/metrics.lua` owns clocks, samples, finite-number checks,
quantiles, RSS/peak-RSS capability probing, Lua heap sampling, heartbeat
sampling, and compatible-baseline comparison. It shares the established
environment fingerprint contract used by existing benchmarks rather than
creating a weaker identity.

Relative regressions are reported per size and operation. A baseline comparison
requires identical schema version, authoritative sizes, repetitions, seed,
fixture digest, relevant CanvasDiff config, Neovim/LuaJIT/Git platform identity,
and capability sources. The comparator reports improvement/regression ratios
and rejects mismatches with a precise reason.

## Performance investigation policy

The baseline decides what production work follows. Candidate areas include
source-side materialization, diff-section construction, first-view projection,
refresh reconciliation, and teardown retention, but none is presumed guilty.
Profiling begins with the highest absolute or superlinear phase. Changes that
only improve synthetic numbers while weakening user-visible semantics,
correctness checks, or cleanup are rejected.

Optimizations should prefer bounded work, streaming, reuse with explicit
ownership, and removal of redundant passes. Caches require measured benefit,
bounded lifetime, and teardown assertions. Large-input work must not make the
1–10,000-line path meaningfully slower.

## Failure containment

- Every worker has a coordinator-enforced timeout and process termination path.
- Temporary repositories are explicit validated paths under the benchmark
  temp root and are removed by a finalizer.
- Injected Git failure is confined to the worker's command adapter and restored
  before teardown.
- Watcher callbacks, timers, sessions, buffers, and windows are checked after
  every rebuild loop and at process end.
- Unsupported operating systems or missing RSS/HWM capabilities are reported
  as capabilities, not approximated. Linux is the authoritative memory-gate
  platform documented by the existing benchmark suite.

## Deliverables

- `make bench-live-scale` for the exact ladder.
- Focused coordinator/fixture/metrics/action tests in `test/performance/`.
- A checked-in post-optimization artifact at
  `docs/verification/live-scale.json`.
- Documentation describing authoritative and development commands, artifact
  interpretation, compatible comparisons, and expected runtime/disk needs.
- Evidence-backed production changes only where the baseline demonstrates a
  worthwhile bottleneck.

## Out of scope

- Benchmarking network fetch, remote hosting latency, repository corruption,
  hostile local Git configuration outside the existing command sanitization
  boundary, unsupported platforms, or operating-system OOM behavior.
- Universal millisecond promises derived from one development machine.
- Repeatedly staging the million-line primary file.
- New public telemetry APIs, background daemons, dependencies, or upload of
  benchmark data.
- Hunk staging or other new product behavior unrelated to performance and
  stability of the existing supported actions.
