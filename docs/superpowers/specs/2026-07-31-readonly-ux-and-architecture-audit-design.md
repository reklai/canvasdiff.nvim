# Read-only UX, Hints Audit, and Targeted Architecture Audit

Five goals in implementation order, approved 2026-07-31. Sections 1–3 are
presentation and copy; section 4 adopts two ideas from modem-dev/hunk and
records what we deliberately do not adopt; section 5 is a targeted,
evidence-first architecture audit against ghostty's patterns.

> **Supersedes in part**
> `2026-07-31-comparison-header-and-sidebar-title-design.md`: that spec kept
> `merge-base(main, feature/login) → feature/login` as the three-dot label.
> The user found `merge-base(...)` opaque; this spec replaces the range labels
> (section 1). Everything else in that spec stands.

## 1. Read-only breadcrumb wording

`diff/lens.lua` `label_for` changes **only its range branch**. Both operators
render the refs the user asked for, prefixed with the mode:

```text
READ-ONLY  main → topic · src/canvas.lua     (main..topic and main...topic)
```

- Two-dot and three-dot look the same. Three-dot still collects from the
  merge base (`source/collect.lua` unchanged) — only the label hides the
  plumbing, the same presentation choice GitHub makes for PR diffs.
- The lens `id` (`range:A..B` / `range:A...B`) is untouched, so sessions,
  bookkeeping, and tests keyed by identity are unaffected.
- Editable lenses keep their exact current labels: `HEAD → WORKTREE`,
  `INDEX → WORKTREE (unstaged)`, `HEAD → INDEX (staged)`,
  `<ref> → WORKTREE` for branch lenses. READ-ONLY appears if and only if
  `lens.editable()` is false for a range — one vocabulary for one fact.

## 2. Breadcrumb placement and the mode tint

The breadcrumb **stays in the canvas winbar** — it already renders below the
tabline ("topbar"), which satisfies the placement goal; what was actually weak
is that read-only mode didn't *look* different.

New highlight groups, both `default = true` so colorschemes win:

| Group | Default | Used |
| --- | --- | --- |
| `CanvasDiffWinbar` | link `WinBar` | canvas winbar, editable lenses |
| `CanvasDiffWinbarReadOnly` | measured (below) | the whole canvas winbar while a range lens is active |

- The winbar string gains a leading `%#CanvasDiffWinbarReadOnly#` (or
  `%#CanvasDiffWinbar#`) so the entire bar is tinted, not just the label —
  a colored bar reads as a mode indicator, like macro-recording.
- The read-only default is chosen by **luminance measurement** against
  tokyonight-moon and Neovim's builtin scheme, the same method as
  `CanvasDiffFileBar` (README documents that precedent). Candidate links to
  measure: `DiffDelete`, `Visual`, `StatusLine`; pick the one with a
  consistent, visible gap against `WinBar`/`Normal` under both schemes.
- Existing winbar caching in `App.set_winbar` compares resolved strings; the
  `%#...#` prefix is part of the string, so no cache change is needed.
- The sidebar winbar is unchanged (narrow window; the earlier spec's division
  of responsibility stands).

## 3. Hints audit

The cheatsheet renders from the keymap registry, so it cannot go stale by
itself. What can: `desc` strings in `input/keys.lua`, README tables, and
user-facing messages. One pass over all three with one rule — anywhere the
plugin refuses or explains because a comparison is read-only, it says
**READ-ONLY** in the breadcrumb's vocabulary:

- `lens_next`/`lens_prev` descs say what happens *from* a read-only range
  (exits to `HEAD → WORKTREE`).
- Jump and stage refusals on a range lens name the reason as the read-only
  comparison, not a generic decline.
- README keymap tables and the lens section re-checked against shipped
  behavior; anything stale fixed in the same pass.
- Cheatsheet code itself: no change expected; verify the new descs lay out
  within its existing column model.

## 4. hunk-inspired adoptions — filtered through what is uniquely ours

Adopt (both cheap, both discoverability wins hunk gets from its persistent
menu bar):

1. **Help hint in the canvas winbar tail**: right-aligned
   `%=` section showing the *actual configured* help key (e.g. `<leader>lh help`),
   omitted when `help` is unbound. `<leader>lh` is currently invisible until
   known.
2. **Changeset diffstat in the sidebar title**:
   `Files changed (12)  +340 −128`, summed from per-file counts the model
   already carries. Count semantics unchanged (files, regardless of folds).

Explicitly **not** adopted, recorded so it isn't re-pitched later:

- **Split/stack layout toggle** — stack-only was settled 2026-07-28;
  opinionated stack is the design.
- **Theme tables / Shiki scopes** — CanvasDiff links highlight groups to the
  user's colorscheme; in-editor that is strictly stronger (the user's theme,
  treesitter queries, and accessibility choices come free — this is part of
  the moat, not a gap).
- **Inline agent-note column** — a real parity feature (hunk, doubt.nvim,
  review.nvim all ship agent feedback), but a separate feature with its own
  design, not part of this pass. Backlog.

## 5. ghostty-inspired targeted architecture audit

Not a restructure. The codebase already has the ghostty disciplines: domains
behind facades ≈ ghostty's subsystem directories, the lease system ≈ its
ownership rules, `test/architecture/` ≈ its enforced boundaries. The
deliverables:

1. **An audit document** (`docs/research/2026-07-31-ghostty-architecture-audit.md`)
   mapping ghostty patterns → where CanvasDiff already matches → where it
   diverges and whether adopting pays. Honest about "already done".
2. **Debt actually worked now**, each item justified by a concrete pain:
   - Presentation code in `App.lua` (winbar building/formatting,
     `comparison_breadcrumb`, `path_under_top` presentation halves) moves
     behind the `ui` facade; `App` keeps orchestration only. `App.lua` is the
     largest non-domain file and this is its clearest foreign concern.
   - Triage of the deferred-minors pool (`.superpowers/sdd/progress.md`):
     items that this pass touches anyway (e.g. `canvas_showing` dedup) come
     in; the rest stay deferred with reasons.
3. **Named seams only where a planned feature needs them**: the PR /
   commit-range modes ride the existing lens + `source/collect` seam; the
   audit documents that seam's contract so a new mode is additive
   ("lego") rather than invasive. No speculative registries.

Architecture tests are updated for any moved edges; the full suite stays
green at every commit.

## Testing

- Sections 1–2: unit tests on `label_for`/`normalize` outputs and on the
  winbar string builder (prefix group choice per lens); existing comparison
  header verification doc re-checked.
- Section 3: cheatsheet layout test still passes with longer descs.
- Section 4: sidebar title test extended for the diffstat; winbar tail
  behavior covered where the help binding is present, multi-bound, disabled.
- Section 5: `make architecture` green after the `App.lua` split; no
  behavioral tests change meaning.

## Implementation order

1 → 2 → 3 → 4 → 5, each landing as its own commit(s); every commit leaves the
full suite green.
