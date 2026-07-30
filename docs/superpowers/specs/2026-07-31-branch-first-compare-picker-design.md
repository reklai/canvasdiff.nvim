# Branch-First Compare Picker Design

## Goal

Make `:CanvasDiff compare` present the workflow users actually perform:
choose one local branch as the base and another local branch as the target.
Git's broader ref model remains an internal execution detail rather than the
primary comparison vocabulary.

## Product model

The interactive comparison picker is strictly local-branch-only:

- choices come only from `refs/heads/*`;
- remote-tracking refs under `refs/remotes/*` are not shown;
- symbolic remote defaults such as `origin/HEAD` are not shown;
- detached `HEAD` is not synthesized as a choice;
- each visible item is a branch name, with `[checked out]` on the current
  branch;
- full local-ref identities remain attached to picker records and are used for
  execution.

This is a presentation and selection change, not a change to Git's comparison
semantics. The resulting comparison remains:

```text
merge-base(base_branch, target_branch) → target_branch
```

## Picker behavior

The first picker uses:

```text
CanvasDiff compare from branch:
```

Its order is:

1. local `main`, when present;
2. local `master`, when present;
3. every remaining local branch in the repository adapter's deterministic
   order.

The second picker uses:

```text
CanvasDiff compare to branch:
```

Its order is:

1. the checked-out local branch, when `HEAD` names one;
2. every remaining local branch in deterministic repository order.

When `HEAD` is detached, no special choice is inserted. The second picker still
contains the repository's local branches.

Selecting the same local branch on both sides remains valid and produces Git's
ordinary empty comparison. This design does not add special-case filtering or
new warnings for that existing behavior.

Cancellation at either picker is silent and observationally inert. If the
repository contains no local branches, comparison reports:

```text
no local branches found
```

The existing comparison-request fencing remains unchanged: a callback whose
origin window, buffer, Surface generation, repository, cwd, or request token is
stale cannot publish a comparison.

## Compatibility boundary

The local-only rule applies to the interactive `:CanvasDiff compare` picker.
It does not narrow the explicit revision grammar.

These existing advanced forms remain supported:

```vim
:CanvasDiff origin/main...feature
:CanvasDiff v1.0..main
:CanvasDiff <commit>...<branch>
```

Command-line completion for explicitly typed revisions also remains unchanged.
Users who intentionally name a remote-tracking ref, tag, or commit retain that
capability without making those objects primary picker choices.

The following commands are unchanged:

- `:CanvasDiff checkout` lists and switches exact local branches;
- `:CanvasDiff track` lists remote-tracking refs and creates a local tracking
  branch;
- bare revision lenses continue comparing that revision to the worktree.

No compare path fetches, pulls, checks out, creates, or mutates a branch.

## Architecture

The repository adapter continues returning role-classified branch records.
The pure ref helper remains the owner of filtering and copying those records.
`App:compare()` consumes only the local-branch projection for both pickers:

```text
repository branch metadata
  → local branch filter
  → base/target ordering
  → branch-name picker
  → exact refs/heads/* range lens
```

Remote-tracking metadata remains available to `track` and explicit revision
completion. It is not deleted or weakened merely because compare no longer
offers it interactively.

## Documentation

The README must describe `:CanvasDiff compare` as choosing two local branches.
It must clearly separate that default workflow from explicitly typed advanced
revision ranges. Examples that claim the picker prioritizes `origin/HEAD` or
offers remote-tracking refs must be removed.

Architecture documentation must state that the branch-first picker filters
repository metadata to local branches while exact full refs remain internal.

## Verification

Tests must prove:

1. both pickers contain only local branches;
2. local `main` and `master` lead the base picker;
3. the checked-out local branch leads the target picker;
4. remote defaults and remote-tracking branches never appear;
5. detached `HEAD` is never synthesized;
6. exact `refs/heads/*` identities reach the range lens;
7. cancellation and stale callbacks remain non-mutating;
8. explicit remote-tracking, tag, and commit range commands remain supported;
9. checkout and track behavior is unchanged;
10. help and architecture copy match the implemented contract.

Focused integration, input, ref-helper, lifecycle, and end-to-end tests precede
one fresh authoritative full-suite run. Existing performance and chaos
campaigns are sufficient because this change only reduces picker records; it
does not modify collection, rendering, paging, compression, mutation, or
Surface ownership.

## Non-goals

- removing remote-tracking refs from Git metadata;
- removing `:CanvasDiff track`;
- fetching before comparison;
- adding an “include remote” toggle;
- changing two-dot or three-dot diff semantics;
- changing typed revision grammar or completion;
- changing checkout, tracking, staging, paging, or rendering behavior.
