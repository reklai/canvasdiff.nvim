# Lens Lifecycle Hardening

Approved 2026-08-01. Three deliverables: the session-lens fallback (bug fix),
the return-lens exit for `<Tab>`, and a git-lifecycle chaos campaign meant to
break CanvasDiff meaningfully — with regression fixes for what it finds.

## 1. Session-lens fallback (the bug)

**Defect:** `App.open` takes the session's saved lens after a shape-only
validity check (`App.lua:1080-1084`). A saved range or branch lens whose ref
was deleted fails collection (`source/collect.lua`), and open treats every
collection error as fatal (`App.lua:1138-1141`) — warn, abort, no canvas.

**Fix:** when collection fails AND the lens came from the session (neither
`opts.lens` nor `opts.base` was passed), fall back once to the configured
default lens (`lens.from_base(config.options.base)`) and re-collect:

- Notify (warn level):
  `saved comparison <old label> no longer resolves — showing <fallback label> (<git error>)`.
- Re-check `opts._guard` after the re-collect, mirroring the first attempt.
- If the fallback lens equals the failed lens, or the re-collect also fails,
  abort exactly as today.
- An explicitly passed lens (`:CanvasDiff main..deleted`) still errors —
  that is feedback for a typo, not a stale session.
- Self-healing needs no extra code: the next session save writes the
  fallback lens.

The same fallback covers a saved **branch** lens whose ref is gone — any
session lens whose collection fails, not just ranges. (Named lenses always
resolve.)

## 2. `<Tab>` returns to the pre-comparison lens

**Today:** leaving a range via `<Tab>`/`<S-Tab>` always lands on
`HEAD → WORKTREE` (`lens.step` returns the cycle head for any lens outside
the cycle).

**New behavior:** the canvas remembers the lens you were looking through when
you entered a comparison, and `<Tab>`/`<S-Tab>` from a range returns there.

- **Record** in `pivot` (the single commit point for every lens change):
  after a successful pivot, if the new lens is a range and the prior lens was
  not, set `state.return_lens = <prior normalized lens>`; if the new lens is
  not a range, clear `state.return_lens`. Range→range pivots keep the
  original recorded lens.
- **Exit** in `App:cycle_lens`: when the current lens is a range, the target
  is `state.return_lens` when set and valid, else `lens.step(current, delta)`
  (today's behavior, landing on `all`). If the return pivot fails (e.g. a
  branch lens whose ref was deleted meanwhile), clear `state.return_lens` so
  the next `<Tab>` takes the default exit; the failure warning already
  explains itself.
- `return_lens` is in-memory only — never persisted. A session-restored range
  exits to the default, as today.
- `q` and `:q` are unchanged: `q` closes the review, `:q` stays Vim's
  window-close. One key, one meaning.

## 3. Docs

- README: the line "`<Tab>` or `<Shift-Tab>` leaves a read-only range at
  `HEAD → WORKTREE`" becomes "…returns to the comparison you were looking
  through when you entered the range (or `HEAD → WORKTREE` when the canvas
  opened straight into it)". One added sentence nearby: `:q` is Vim's
  window-close and is deliberately left alone; `q` is the review's close.
- vimdoc: the matching sentence ("Press <Tab> or <S-Tab> to leave a range at
  HEAD vs WORKTREE") updated the same way; one sentence on the session
  fallback in the session section.
- Lens-desc strings (`input/keys.lua`) stay as-is — "(exits a READ-ONLY
  range)" remains true.

## 4. Git-lifecycle chaos campaign

`test/fault/chaos_surface.lua` already drives real `:CanvasDiff` entry points
against a real git fixture with a seeded, replayable generator — but its
action set has no git lifecycle: no branch create/delete, no range/branch
lenses, no staging, no cross-"restart" session reopen. Extend it:

**New actions** (same recorded-seed discipline, each expected to be REFUSED
or SURVIVED, never absorbed silently):

- `git_branch` — create a branch at HEAD (bounded pool of names).
- `git_branch_delete` — force-delete a branch from the pool, including one
  currently named by the active lens.
- `git_commit` — commit current worktree changes (enables real ranges).
- `set_range` — pivot to `A..B` / `A...B` over pool branches (some deleted).
- `set_branch` — worktree-vs-ref lens over pool branches.
- `stage_cycle` — file-level stage/unstage through the plugin entry point.
- `session_reopen` — close, wipe in-memory state as a restart would,
  reopen (exercises §1's fallback under fire).

**Invariants added** to the existing after-every-action set: a failed lens
pivot leaves the previous canvas intact and showing; `state.return_lens` is
never a range; after `session_reopen` a canvas is showing (fallback worked)
or the open refused cleanly with no leaked windows/augroups/buffers.

**Campaign:** the short in-suite campaign (`test_chaos_surface.lua`) picks up
the new actions automatically; additionally run the long campaign at ≥2,000
actions across ≥5 seeds during this work and triage every failure. Real bugs
found get a minimal regression test plus a fix in this branch when small, or
a written finding when not.

## Verification

Full suite green; long campaign seeds recorded in the findings report
(`docs/research/2026-08-01-lens-lifecycle-chaos-findings.md` — created even
if empty of bugs, recording seeds/actions/invariants so the campaign is
repeatable).
