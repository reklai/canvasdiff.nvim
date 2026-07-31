# Lens-lifecycle chaos campaign findings

Date: 2026-08-01

Result: **ZERO failures** across 140,000 recorded actions (52 campaign runs),
after verifying the harness detects planted bugs. Two mutation checks confirm
the invariants have teeth; the clean run is earned, not assumed.

The campaign exercises the surface-level chaos harness added for the
lens-lifecycle hardening work (`test/fault/chaos_surface.lua`, commit
d3898e1): real Git fixture, real `:CanvasDiff` entry points, deterministic
seeded action stream, invariants checked after every single action.

## Campaign parameters

| Run set | Seeds | Actions/seed | Total actions | Failures |
| --- | --- | --- | --- | --- |
| Required set | 1, 2, 3, 5, 8 | 2,000 | 10,000 | 0 |
| Extended sweep | 4, 6, 7, 9–50 | 2,000 | 90,000 | 0 |
| Deep runs | 13, 101 | 20,000 | 40,000 | 0 |

- One `nvim --headless --clean` process per seed, so a replay is exactly one
  command and no state leaks between seeds.
- `NVIM_LOG_FILE` redirected to `/tmp/canvasdiff-campaign-seed<N>.log` per the
  Makefile's convention: artifacts never land in the checkout.
- `XDG_STATE_HOME` redirected per process, so session persistence never
  touches the real state directory.
- Runtime: ~7s per 2,000-action seed; ~152s per 20,000-action deep run.

## Action mix

The harness draws uniformly (seeded LCG, high bits) from its 19 actions:

`close`, `close_window`, `cycle_lens`, `git_branch`, `git_branch_delete`,
`git_commit`, `git_fails`, `jump_back`, `open`, `refresh`, `session_reopen`,
`session_unwritable`, `set_branch`, `set_lens`, `set_range`, `split_window`,
`stage_cycle`, `toggle`, `write_file`.

Representative distribution (seed 1, 2,000 actions): every action landed
85–122 times except `split_window` (57 — it refuses above four windows).
Injected hostility per 2,000 actions: ~100 forced Git failures
(`git_fails`), ~100 forced session-write failures (`session_unwritable`),
~100 branch deletions against a pool that lenses and ranges still name, ~95
close-and-reopen restarts through the saved session, ~95 range pivots whose
endpoints regularly name deleted branches.

## Invariants checked (after every action)

1. Every `canvasdiff.{session,close,winbar}.<id>` augroup belongs to a live
   Surface — a leaked group is a callback that will fire against a review
   that no longer exists.
2. No two live Surfaces claim one canvas buffer.
3. A disposed Surface holds no render hooks.
4. Canvas buffers do not accumulate beyond baseline + peak reviews + 1.
5. `return_lens`, when set, satisfies `lens.valid` and is never a range.
6. A live Surface whose primary window exists is showing its own canvas
   buffer there (a refused pivot left the review on screen).
7. After `session_reopen`: either the restored review is actually showing, or
   the refusal left no live Surface and no Surface-owned augroups behind.

Plus per-action assertions: injected Git and session failures must be
contained (never escape as a throw); `jump_back`, `set_range`, `set_branch`
and `stage_cycle` must refuse rather than throw.

## Failures and triage

None. All 52 runs completed their full action budget with every invariant
holding at every step.

## Mutation checks (verifying the harness can fail)

A campaign that cannot detect a planted bug proves nothing, so two bugs were
deliberately planted (and reverted) before trusting the clean result:

| Planted bug | Detected | Invariant that fired |
| --- | --- | --- |
| Surface disposal skips deleting its owned augroups (`Surface.lua`) | seed 1, action 6 | `augroup canvasdiff.session.1 outlived the Surface that owned it` |
| Entering a range records the range itself as `return_lens` (`App.lua`) | seed 1, action 29 | `return_lens is a range, so leaving a comparison could never finish` |

Both were caught within 30 actions of a 2,000-action budget, at the first
action sequence that exercised the mutated path. The working tree was
verified clean (`git status`, `git diff`) and seed 1 re-run green after each
revert.

## Observed refusals (expected behavior, not failures)

The headless runs surface the plugin's own notification lines; all are the
designed refusals the harness exists to provoke:

- `revision 'chaos-N' does not resolve to a commit` — pivot onto a deleted
  pool branch, refused, prior review stayed on screen.
- `git status failed: injected git failure` / `not inside a git repository` —
  `git_fails` injection, contained.
- `no live diff canvas`, `no active review excursion`, `no file under the
  cursor` — entry points refusing when their preconditions are gone.
- `showing READ-ONLY <ref> → <ref>` — range comparisons opening read-only.

## Rerun instructions

The driver is a scratch script (deliberately uncommitted, per the harness
brief). Recreate it anywhere outside the repo as `chaos_campaign.lua`:

```lua
-- Run: NVIM_LOG_FILE=/tmp/... nvim --headless --clean \
--        -l chaos_campaign.lua <repo_root> <seed> <actions>
local root = assert(_G.arg and _G.arg[1], "pass the repo root")
local seed = tonumber((assert(_G.arg and _G.arg[2], "pass a seed")))
local actions = tonumber(_G.arg and _G.arg[3]) or 2000

local test_root = vim.fs.joinpath(root, "test")
vim.opt.runtimepath:prepend(root)
package.path = test_root .. "/?.lua;" .. test_root .. "/?/init.lua;"
  .. package.path
vim.env.XDG_STATE_HOME = vim.fs.joinpath(vim.uv.os_tmpdir(),
  "canvasdiff_campaign_state_" .. seed .. "_" .. vim.uv.hrtime())

local Chaos = require("fault.chaos_surface")
local ok, result = pcall(Chaos.run, { seed = seed, actions = actions })
if not ok then
  io.write("CRASHED: " .. tostring(result) .. "\n")
  os.exit(2)
end
if result.status ~= "ok" then
  io.write(("seed %d FAILED at action %d (%s)\n")
    :format(seed, result.failed_at, result.failed_action))
  for index, entry in ipairs(result.history or {}) do
    io.write(("  %4d  %s\n"):format(index, entry))
  end
  io.write(tostring(result.error) .. "\n")
  os.exit(1)
end
io.write(("seed %d ok: %d actions\n"):format(seed, result.actions))
```

Rerun any seed from this campaign:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-campaign-seed1.log nvim --headless --clean \
  -l chaos_campaign.lua /path/to/canvasdiff 1 2000
# required set: seeds 1 2 3 5 8 at 2000
# extended sweep: seeds 4..50 at 2000
# deep runs: seeds 13 and 101 at 20000
```

On failure the driver prints the recorded action trace (up to the harness's
256-entry window) and the invariant error; the seed replays the identical
stream, so minimization is truncating the action budget to the failing step.

## Disposition

No plugin bugs, no harness bugs, no open findings. The lens-lifecycle
surfaces hardened in this branch — session-lens fallback (3734683),
`return_lens` for `<Tab>` (a216779), branch deletion under saved and
remembered lenses (d3898e1) — survived 140,000 hostile actions with the
ownership, refusal and degradation contracts intact.
