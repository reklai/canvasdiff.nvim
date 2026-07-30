# Live Git Scale Performance Campaign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an authoritative real-Git benchmark that measures and stress-tests CanvasDiff at exactly 1, 1,000, 10,000, 100,000, and 1,000,000 changed content lines.

**Architecture:** A coordinator launches one isolated headless Neovim worker per size and repetition, validates worker JSON, applies portable correctness/stability gates, and publishes one atomic aggregate. Workers use a streaming fixture builder, benchmark-owned timing adapters, and a deterministic action plan; pure metric, fixture, and plan contracts are covered by the existing Lua test runner.

**Tech Stack:** LuaJIT, Neovim 0.10+, Git CLI, libuv, the existing custom Lua test runner and Make acceptance lanes.

## Global Constraints

- The authoritative size order is exactly `1, 1000, 10000, 100000, 1000000`.
- Every size/repetition runs in a fresh headless Neovim process and unique temporary Git repository.
- Fixture creation time is reported but excluded from plugin latency.
- Timing instrumentation is installed in the worker before `canvasdiff.App` loads; production modules receive no benchmark hooks.
- The large primary file is never staged during the action loop; stage/unstage uses bounded sidecars.
- Correctness failure invalidates the associated latency sample.
- Development size overrides are recorded as non-authoritative and cannot publish the checked-in verification artifact.
- The first machine-dependent live baseline is observational; portable correctness/stability gates and existing million-row paged-engine budgets remain hard gates.
- Baseline comparison refuses mismatched schema, sizes, repetitions, seed, fixture/config digest, host fingerprint, or measurement capabilities.
- Linux is the authoritative RSS/HWM gate platform; unsupported platforms remain outside the documented boundary.
- Add no runtime dependency, public telemetry API, background daemon, Git fetch, checkout, merge, or network operation.

---

### Task 1: Metric summaries and compatible-baseline contract

**Files:**
- Create: `benchmark/live_scale/metrics.lua`
- Create: `test/performance/test_live_scale_metrics.lua`

**Interfaces:**
- Produces `metrics.finite(value) -> boolean`.
- Produces `metrics.summary(values) -> { count, p50, p95, max }`.
- Produces `metrics.compatible(current, baseline) -> true | nil, string[]`.
- Produces `metrics.compare(current, baseline) -> comparison | nil, string[]`.
- Comparison rows contain `{ size, operation, current, baseline, ratio, percent }`.

- [ ] **Step 1: Write failing tests for quantiles, invalid input, compatibility, and ratios**

  Use literal samples `{ 9, 1, 5, 3, 7 }` and assert:

  ```lua
  H.eq(metrics.summary({ 9, 1, 5, 3, 7 }), {
    count = 5, p50 = 5, p95 = 9, max = 9,
  })
  ```

  Assert empty, NaN, and infinite samples are rejected. Build two literal
  aggregates and prove every binding identity field is checked independently;
  then assert `10 / 8` becomes `ratio = 1.25` and `percent = 25`.

- [ ] **Step 2: Run the focused test and observe the missing-module failure**

  Run:

  ```bash
  make test SUITE=performance FILTER='^live_scale_metrics_'
  ```

  Expected: FAIL because `benchmark.live_scale.metrics` does not exist.

- [ ] **Step 3: Implement the minimal pure metric module**

  Use nearest-rank quantiles:

  ```lua
  local rank = math.max(1, math.ceil(percentile * #sorted))
  ```

  Sort a copy, never the caller's table. Reject non-finite and empty input.
  Compare these exact identity paths: schema/profile, authoritative sizes,
  repetitions, seed, fixture digest/schema, config digest, host fingerprint,
  RSS source, and HWM source. Return all mismatch reasons in deterministic path
  order.

- [ ] **Step 4: Run focused and complete performance suites**

  Run:

  ```bash
  make test SUITE=performance FILTER='^live_scale_metrics_'
  make test SUITE=performance
  ```

  Expected: all pass with pristine output.

- [ ] **Step 5: Commit the task**

  ```bash
  git add benchmark/live_scale/metrics.lua test/performance/test_live_scale_metrics.lua
  git commit -m "test: define live scale metric contract"
  ```

### Task 2: Streaming real-Git fixture

**Files:**
- Create: `benchmark/live_scale/fixture.lua`
- Create: `test/performance/test_live_scale_fixture.lua`

**Interfaces:**
- Consumes a writable empty root, positive integer line count, and integer seed.
- Produces `fixture.build(root, rows, seed) -> manifest | nil, error`.
- Produces `fixture.cleanup(root) -> true | nil, error`.
- Manifest contains schema, root, seed, requested content rows, primary path,
  first/last line, SHA-256 content digest, base/branch/range refs, and sidecar
  paths.

- [ ] **Step 1: Write failing real-Git fixture tests**

  Build 1-row and 1,000-row fixtures in unique `/tmp` roots. Assert literal
  first/last lines, `git diff --numstat -- primary.txt` reports exactly
  `N\t0`, `git diff --check` succeeds, status exposes staged/unstaged/untracked/
  delete/rename cases, branch and range refs resolve, and cleanup removes only
  the exact fixture root.

  Include rejection tests for zero, negative, fractional, nonempty target, and
  a cleanup target that was not created by this module.

- [ ] **Step 2: Run the focused test and observe the missing-module failure**

  Run:

  ```bash
  make test SUITE=performance FILTER='^live_scale_fixture_'
  ```

  Expected: FAIL because `benchmark.live_scale.fixture` does not exist.

- [ ] **Step 3: Implement streaming writes and bounded Git execution**

  Write `primary.txt` line-by-line:

  ```lua
  for index = 1, rows do
    file:write(("scale %d seed %d\n"):format(index, seed))
  end
  ```

  Hash the completed file with `vim.fn.sha256`. Use `git init -q -b main`,
  local fixture identity config, explicit argv arrays, and bounded stderr.
  Create refs `scale-base`, `scale-branch`, and `scale-range`; restore `main`
  before applying the measured worktree state. Place an ownership marker in the
  root and require its exact schema before recursive cleanup.

- [ ] **Step 4: Run fixture, integration Git, and architecture suites**

  Run:

  ```bash
  make test SUITE=performance FILTER='^live_scale_fixture_'
  make test SUITE=integration FILTER='git_'
  make architecture
  ```

  Expected: all pass.

- [ ] **Step 5: Commit the task**

  ```bash
  git add benchmark/live_scale/fixture.lua test/performance/test_live_scale_fixture.lua
  git commit -m "test: build deterministic live scale fixtures"
  ```

### Task 3: Deterministic lifecycle action plan

**Files:**
- Create: `benchmark/live_scale/actions.lua`
- Create: `test/performance/test_live_scale_actions.lua`

**Interfaces:**
- Produces `actions.plan(rows, seed) -> action[]`.
- Each action is `{ name, class, arguments }`; the plan contains no closures or
  live Neovim handles and is JSON-serializable.
- Produces `actions.required_names() -> string[]`.

- [ ] **Step 1: Write failing plan tests**

  Prove identical `(rows, seed)` inputs produce byte-identical JSON, a different
  seed changes randomized jump rows, every jump remains in `[1, rows]`, yank
  spans never exceed 2,000 rows, and every size includes this literal semantic
  set:

  ```lua
  {
    "open", "sequential_scroll", "random_jump", "search", "yank",
    "fold", "unfold", "cycle_all", "cycle_staged", "cycle_unstaged",
    "manual_refresh", "watch_refresh", "file_next", "file_prev",
    "hunk_next", "hunk_prev", "jump", "back", "stage", "unstage",
    "branch_compare", "range_compare", "git_failure", "close_reopen",
    "close_orders", "final_close",
  }
  ```

  Assert action counts are bounded independently of `rows`.

- [ ] **Step 2: Run the focused test and observe the missing-module failure**

  Run:

  ```bash
  make test SUITE=performance FILTER='^live_scale_actions_'
  ```

  Expected: FAIL because `benchmark.live_scale.actions` does not exist.

- [ ] **Step 3: Implement the serializable seeded plan**

  Use a local integer LCG and explicit per-action arguments. Sequential scroll
  samples at most 200 evenly spaced viewports; random navigation uses 200
  seeded rows; rebuild cycles are exactly 3; every remaining semantic action
  occurs once per sample.

- [ ] **Step 4: Run action and existing chaos-plan suites**

  Run:

  ```bash
  make test SUITE=performance FILTER='^live_scale_actions_'
  make test SUITE=fault FILTER='chaos_'
  ```

  Expected: all pass.

- [ ] **Step 5: Commit the task**

  ```bash
  git add benchmark/live_scale/actions.lua test/performance/test_live_scale_actions.lua
  git commit -m "test: define deterministic live scale actions"
  ```

### Task 4: Isolated worker, phase timing, replay, and invariant checks

**Files:**
- Create: `benchmark/live_scale/worker.lua`
- Create: `test/performance/test_live_scale_worker.lua`

**Interfaces:**
- Worker argv is `OUTPUT FIXTURE_ROOT ROWS SEED RUN_INDEX`.
- Worker publishes schema `canvasdiff.live_scale.worker/v1`.
- Worker result contains status/error, manifest identity, phase samples,
  action trace, correctness observations, heartbeat, memory/capabilities,
  paging/cache/extmark observations, and cleanup observations.

- [ ] **Step 1: Write a failing 1-row worker integration test**

  Launch the real worker in a fresh headless Neovim against a fixture and assert
  it exits zero, publishes valid JSON, executes every required action, records
  finite phase/action timings, preserves content/lens/index identities, catches
  the injected Git failure, and ends with no CanvasDiff windows, timers, or
  owned autocmd groups. Delete one required observation in a copied payload and
  assert the validator rejects it.

- [ ] **Step 2: Run the focused test and observe the missing-worker failure**

  Run:

  ```bash
  make test SUITE=performance FILTER='^live_scale_worker_'
  ```

  Expected: FAIL because the worker entry point does not exist.

- [ ] **Step 3: Implement benchmark-owned timing adapters before App load**

  Require and wrap `canvasdiff.os.run` before any source/App module. Record
  monotonic duration and Git argv category while preserving all return values
  and errors. Require and wrap the `canvasdiff.source` facade next, timing
  `root`, `sections`, `changed_files`, `stage`, and `unstage`; only then require
  `canvasdiff`.

  Install a 10ms repeating libuv heartbeat, sample heap/RSS/HWM, and restore
  every wrapper in a protected finalizer.

- [ ] **Step 4: Implement real action execution and correctness oracles**

  Execute the serialized plan against public CanvasDiff operations and existing
  canvas paging APIs. Derive expected primary bytes from the fixture manifest,
  query Git directly for index/ref truth, and check Surface-owned resources by
  the public/runtime ownership groups already used in E2E tests. Each trace
  record contains index, name, arguments, elapsed time, status, and observations.
  On failure, preserve the preceding trace, then always close, stop heartbeat,
  restore adapters, collect garbage twice, and publish.

- [ ] **Step 5: Run worker, E2E, watcher, staging, and branch suites**

  Run:

  ```bash
  make test SUITE=performance FILTER='^live_scale_worker_'
  make test SUITE=e2e
  make test SUITE=integration FILTER='root_|lens_|sidebar_integration stage'
  ```

  Expected: all pass.

- [ ] **Step 6: Commit the task**

  ```bash
  git add benchmark/live_scale/worker.lua test/performance/test_live_scale_worker.lua
  git commit -m "test: replay live scale lifecycle"
  ```

### Task 5: Coordinator, validation, gates, atomic aggregate, and baseline comparison

**Files:**
- Create: `benchmark/live_scale/coordinator.lua`
- Create: `benchmark/live_scale/run.lua`
- Create: `test/performance/test_live_scale_coordinator.lua`

**Interfaces:**
- Produces `coordinator.execute(options) -> aggregate`; `options.launch` is the
  worker-launch function and defaults to the real isolated Neovim launcher.
- Produces `coordinator.validate_worker(payload, expected) -> true | nil, string[]`.
- Coordinator argv is `OUTPUT REPS [SIZES] [BASELINE]`.
- Default sizes are authoritative; `SIZES` is a comma-separated development
  override.
- Aggregate schema is `canvasdiff.live_scale/v1`.
- A failure at one size is recorded while remaining sizes still execute.

- [ ] **Step 1: Write failing coordinator contract tests**

  Run the coordinator with `SIZES=1,1000` and one repetition. Assert ordered
  samples, aggregates for both sizes, non-authoritative status, action/phase
  p50/p95/max summaries, environment and capability identity, thresholds,
  failures, and atomic output. Call `coordinator.execute` with literal injected
  `options.launch` functions that return malformed JSON, timeout results, and
  incompatible baseline identities; assert precise structured failures without
  suppressing later samples. Do not assert on the fake launcher itself.

- [ ] **Step 2: Run the focused test and observe the missing-coordinator failure**

  Run:

  ```bash
  make test SUITE=performance FILTER='^live_scale_coordinator_'
  ```

  Expected: FAIL because the coordinator does not exist.

- [ ] **Step 3: Implement strict arguments, isolated launch, validation, and aggregation**

  Reuse the existing benchmark contracts for output-outside-repository checks,
  XDG/HOME isolation, source-tree digest, host fingerprint, atomic rename, and
  bounded logs. Set a 15-minute worker timeout. Validate every claimed number
  as finite and every required correctness field before summarizing it.

  Portable gates are: successful cleanup, exact requested content rows,
  correctness observations all true, heartbeat ticks ≥ 1 and max gap ≤ 100ms,
  zero row extmarks, resident pages/bytes within the configured paging caps,
  and no unhandled worker error. Report latency/memory without a universal hard
  ceiling in the first baseline.

- [ ] **Step 4: Implement compatible comparison and terminal table**

  Use `metrics.compatible` before computing ratios. Print one row per size with
  source/open/first-view/action p95, heartbeat max, peak RSS, retained heap, and
  verdict. Refuse a checked-in output path for non-authoritative size overrides.

- [ ] **Step 5: Run coordinator and complete performance suites**

  Run:

  ```bash
  make test SUITE=performance FILTER='^live_scale_coordinator_'
  make test SUITE=performance
  ```

  Expected: all pass.

- [ ] **Step 6: Commit the task**

  ```bash
  git add benchmark/live_scale/coordinator.lua benchmark/live_scale/run.lua test/performance/test_live_scale_coordinator.lua
  git commit -m "test: coordinate live scale campaign"
  ```

### Task 6: Make target, operator documentation, and untouched baseline

**Files:**
- Modify: `Makefile`
- Modify: `benchmark/README.md`
- Modify: `docs/verification/README.md`
- Create after authoritative run: `docs/verification/live-scale.json`

**Interfaces:**
- Produces `make bench-live-scale`.
- `REPS` defaults to 1 for the expensive live ladder.
- `SIZES`, `BASELINE`, and `OUT` are optional development/comparison inputs.

- [ ] **Step 1: Add the Make target and document exact commands**

  The target invokes:

  ```make
  bench-live-scale:
  	NVIM_LOG_FILE=$(OUT)-live-scale.log $(NVIM_BENCH) \
  		-l benchmark/live_scale/run.lua $(OUT)-live-scale.json \
  		$(LIVE_REPS) "$(SIZES)" "$(BASELINE)"
  ```

  Add `LIVE_REPS ?= 1`. Document authoritative, focused development, and
  compatible comparison commands; artifact fields; expected disk/runtime
  cost; Linux memory boundary; and the prohibition on treating fixture time as
  plugin latency.

- [ ] **Step 2: Run documentation/static checks and focused ladder**

  Run:

  ```bash
  git diff --check
  make test SUITE=performance
  make bench-live-scale OUT=/tmp/canvasdiff-live-dev SIZES=1,1000 LIVE_REPS=1
  ```

  Expected: all pass; the focused artifact is explicitly non-authoritative.

- [ ] **Step 3: Commit target and documentation before measuring baseline**

  ```bash
  git add Makefile benchmark/README.md docs/verification/README.md
  git commit -m "docs: expose live scale campaign"
  ```

- [ ] **Step 4: Run and preserve the untouched authoritative baseline**

  Run:

  ```bash
  make bench-live-scale OUT=/tmp/canvasdiff-live-baseline LIVE_REPS=1
  cp /tmp/canvasdiff-live-baseline-live-scale.json \
    docs/verification/live-scale.json
  ```

  Expected: exact five-size ladder completes and reports portable gates.
  The validated aggregate is copied byte-for-byte to
  `docs/verification/live-scale.json`.

- [ ] **Step 5: Analyze evidence and write the optimization follow-up plan**

  Rank phase time, growth ratio, peak RSS, retained heap, heartbeat gap, and
  rebuild slope. Select only reproduced, supported bottlenecks. Write a second
  TDD plan naming the exact production files and before/after acceptance
  thresholds supported by this baseline.

- [ ] **Step 6: Commit the baseline evidence and optimization plan**

  ```bash
  git add docs/verification/live-scale.json docs/superpowers/plans/
  git commit -m "perf: record live scale baseline"
  ```

---

## Plan self-review

- Spec coverage: R1–R10 are implemented by Tasks 1–6; R11 becomes the
  evidence-specific follow-up plan produced by Task 6; R12 remains the final
  completion gate after that follow-up executes.
- Placeholder scan: no deferred behavior, unspecified handler, or generic
  error-handling step remains.
- Interface consistency: metrics, fixture, action, worker, and coordinator
  schemas are introduced before their consumers and use one schema generation.
