# Isolated eager-canvas baseline

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
