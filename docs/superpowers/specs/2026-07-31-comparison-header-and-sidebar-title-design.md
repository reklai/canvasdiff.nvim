# Comparison Header and Sidebar Title Design

## Goal

Make the persistent comparison context immediately recognizable by using the
same compact conventions people already see in editors and code-review tools.
Remove product-oriented wording from the canvas header and give the sidebar a
plain, count-bearing title.

## Approved presentation

The canvas winbar is a breadcrumb:

```text
main → feature/login · src/auth.lua
```

The sidebar winbar is a collection title:

```text
Files changed (12)
```

Together they divide responsibility:

- The canvas says what is being compared and which file is currently visible.
- The sidebar says what its tree contains and how many changed files exist.
- The sidebar does not repeat branch names, which are often too long for its
  narrow fixed-width window.

## Canvas behavior

The canvas winbar uses:

```text
source → destination · current/file
```

The comparison label continues to come from the normalized lens identity, so
working-tree and staged views retain their precise existing names:

```text
HEAD → WORKTREE · src/auth.lua
INDEX → WORKTREE (unstaged) · src/auth.lua
HEAD → INDEX (staged) · src/auth.lua
```

Committed branch comparisons use the same direction already established by the
lens:

```text
main → feature/login · src/auth.lua
```

Three-dot comparisons retain their merge-base semantics rather than presenting
the requested left branch as the actual source:

```text
merge-base(main, feature/login) → feature/login · src/auth.lua
```

The current path follows the section under the canvas topline, as it does now.
When there is no current section, only the comparison label is shown. Literal
percent signs and control bytes remain escaped for safe winbar rendering. The
redundant `CanvasDiff:` prefix and the heavier `│` separator are removed.

## Sidebar behavior

The sidebar gets its own window-local winbar:

```text
Files changed (N)
```

`N` is the number of changed file sections in the current lens, not the number
of visible tree rows. Directory rows and user-folded directories therefore do
not inflate or reduce the count.

The title updates whenever the sidebar refreshes after a manual refresh, watch
reconciliation, stage/unstage transition, or lens change. Multiple sidebar
views owned by the same review show the same count.

The title is presentation only. It does not become a selectable buffer row, so
existing row indices, keyboard behavior, folding, cursor tracking, and
virtualization remain unchanged.

Because a split can inherit window-local options, sidebar ownership includes
the exact winbar value it applies. If a sidebar window must survive teardown,
CanvasDiff restores the prior winbar only when the live value is still the one
CanvasDiff installed; a foreign replacement is preserved.

## Narrow windows and long names

The sidebar title is deliberately short enough for the default width. The
canvas keeps the comparison at the left and puts Neovim's `%<` truncation marker
immediately before the current path. When space is limited, Neovim therefore
clips the trailing path while preserving the comparison identity as the
highest-priority context. The `%<` is formatting syntax and is not displayed.

No additional badges, key hints, icons, or read-only labels are added.

## Documentation

The README and Vim help examples will show the new canvas breadcrumb and
sidebar title. Existing explanations of lens direction and sidebar navigation
remain authoritative.

## Verification

Tests must cover:

- Canvas winbars no longer contain `CanvasDiff:` and use ` · ` before a path.
- Long canvas paths truncate after the comparison identity.
- Working-tree, staged, branch, and committed-range labels keep their existing
  direction and semantic meaning.
- The sidebar title is `Files changed (N)` for flat and folded trees.
- The count changes after reconciliation and lens changes.
- Sidebar buffer rows and active-row tracking are not shifted by the title.
- Teardown restores an inherited winbar but preserves a foreign replacement.
- Percent signs and unusual paths cannot become winbar expressions.
